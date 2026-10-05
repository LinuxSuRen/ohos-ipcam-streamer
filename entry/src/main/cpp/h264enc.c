/*
 * h264enc.c - NAPI shim for OH_VideoEncoder (buffer-input H.264 encoder
 * with pre-encode NV12 rotation).
 *
 * Exposes to ArkTS:
 *   setCallback(cb: (frame: ArrayBuffer, keyframe: boolean) => void): void
 *   start(outWidth, outHeight, fps, bitrate): number   // 1 ok
 *   pushFrame(nv12: ArrayBuffer, inW, inH, rotateDeg): void
 *   stop(): void
 *
 * ArkTS feeds compact NV12 frames (from Camera Kit ImageReceiver);
 * the shim rotates (0/90/180/270) then pushes into the encoder.
 * Rotation 90/270 swaps width/height: encoder out size must match.
 */
#include "napi/native_api.h"

#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <native_image/native_image.h>
#include <native_buffer/native_buffer.h>
#include <hilog/log.h>

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/time.h>
#include <unistd.h>

#define HLOG_DOMAIN 0x0A00
#define HLOG_TAG "h264enc"
#define LOGI(...) ((void)OH_LOG_Print(LOG_APP, LOG_INFO, HLOG_DOMAIN, HLOG_TAG, __VA_ARGS__))
#define LOGE(...) ((void)OH_LOG_Print(LOG_APP, LOG_ERROR, HLOG_DOMAIN, HLOG_TAG, __VA_ARGS__))

static OH_AVCodec *g_enc = NULL;
static napi_threadsafe_function g_tsfn = NULL;

/* free input buffers delivered by on_need_input (index + buffer pair) */
#define IQ_CAP 64
typedef struct {
    uint32_t index;
    OH_AVBuffer *buffer;
} in_slot_t;
static in_slot_t g_iq[IQ_CAP];
static int g_iq_head = 0, g_iq_tail = 0, g_iq_count = 0;
static pthread_mutex_t g_iq_lock = PTHREAD_MUTEX_INITIALIZER;

/* scratch buffers: g_dst = de-strided compact input; g_rot = rotated output */
static uint8_t *g_rot = NULL;
static size_t g_rot_cap = 0;
static uint8_t *g_dst = NULL;
static size_t g_dst_cap = 0;

static int g_out_frames = 0;
static int g_push_enter = 0;

/* ---------- native capture (OH_NativeImage) ---------- */
static OH_NativeImage *g_cap = NULL;
static int g_cam_w = 0;
static int g_cam_h = 0;
static int g_rotate = 0;
static int g_plane_dumped = 0;

typedef struct {
    uint8_t *data;
    int32_t size;
    bool keyframe;
} frame_msg_t;

static void rotate_nv12(const uint8_t *src, int w, int h, int rotate, uint8_t *dst);
static void push_into_encoder(const uint8_t *nv12, int w, int h, int rotate);

static int g_in_frames = 0;
static int g_push_ok = 0;

static void on_frame_available(void *ctx)
{
    (void)ctx;
    g_in_frames++;
    if (g_in_frames == 1 || g_in_frames % 100 == 0) {
        LOGI("frame-available #%{public}d pushed=%{public}d", g_in_frames, g_push_ok);
    }
    if (g_cap == NULL || g_enc == NULL) {
        return;
    }
    /* drop stale buffers, keep the latest */
    OHNativeWindowBuffer *nwb = NULL;
    OHNativeWindowBuffer *last = NULL;
    int fence = -1;
    while (OH_NativeImage_AcquireNativeWindowBuffer(g_cap, &nwb, &fence) == 0) {
        if (last != NULL) {
            OH_NativeImage_ReleaseNativeWindowBuffer(g_cap, last, -1);
        }
        last = nwb;
        nwb = NULL;
    }
    if (last == NULL) {
        return;
    }

    OH_NativeBuffer *nb = NULL;
    if (OH_NativeBuffer_FromNativeWindowBuffer(last, &nb) != 0 || nb == NULL) {
        OH_NativeImage_ReleaseNativeWindowBuffer(g_cap, last, -1);
        return;
    }
    void *addr = NULL;
    OH_NativeBuffer_Planes planes;
    memset(&planes, 0, sizeof(planes));
    if (OH_NativeBuffer_MapPlanes(nb, &addr, &planes) != 0 || addr == NULL) {
        LOGE("map planes failed");
        OH_NativeBuffer_Unmap(nb);
        OH_NativeImage_ReleaseNativeWindowBuffer(g_cap, last, -1);
        return;
    }
    const int w = g_cam_w;
    const int h = g_cam_h;
    if (w > 0 && h > 0 && g_rot_cap >= (size_t)w * h * 3 / 2) {
        const uint8_t *y = (const uint8_t *)addr + planes.planes[0].offset;
        const int yStride = (int)planes.planes[0].rowStride;
        if (g_plane_dumped == 0) {
            g_plane_dumped = 1;
            LOGI("planeCount=%{public}u", planes.planeCount);
            for (uint32_t pi = 0; pi < planes.planeCount && pi < 4; pi++) {
                LOGI("plane[%{public}u] off=%{public}llu rowStride=%{public}u colStride=%{public}u",
                     pi, (unsigned long long)planes.planes[pi].offset,
                     planes.planes[pi].rowStride, planes.planes[pi].columnStride);
            }
            const uint8_t *yraw = (const uint8_t *)addr;
            LOGI("Y[0..7]=%{public}02x %{public}02x %{public}02x %{public}02x",
                 yraw[0], yraw[1], yraw[2], yraw[3]);
            const uint8_t *uvraw = (const uint8_t *)addr + planes.planes[1].offset - 1;
            LOGI("UV[-1..6]=%{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x",
                 uvraw[0], uvraw[1], uvraw[2], uvraw[3], uvraw[4], uvraw[5], uvraw[6], uvraw[7]);
        }
        LOGI("before de-stride");
        if (planes.planeCount >= 2) {
            /* 实测布局(API 24 真机):rowStride=字节/样本,colStride=行字节宽。
             * planeCount=3 且 plane[1](U).offset > plane[2](V).offset 时为 NV21
             * (VU 交错),拷贝时交换为 NV12。planeCount=2 视作 NV12。 */
            const int yRowBytes = planes.planes[0].columnStride > 0
                                  ? (int)planes.planes[0].columnStride : w;
            for (int r = 0; r < h; r++) {
                memcpy(g_dst + (size_t)r * w, y + (size_t)r * yRowBytes, (size_t)w);
            }
            const uint32_t uvOff = (planes.planeCount >= 3 &&
                                    planes.planes[1].offset > planes.planes[2].offset)
                                   ? planes.planes[2].offset : planes.planes[1].offset;
            const int uvRowBytes = planes.planes[1].columnStride > 0
                                   ? (int)planes.planes[1].columnStride : w;
            const uint8_t *uv = (const uint8_t *)addr + uvOff;
            uint8_t *dstUV = g_dst + (size_t)w * h;
            const int swapUV = (planes.planeCount >= 3 &&
                                planes.planes[1].offset > planes.planes[2].offset) ? 1 : 0;
            for (int r = 0; r < h / 2; r++) {
                const uint8_t *src = uv + (size_t)r * uvRowBytes;
                uint8_t *dst = dstUV + (size_t)r * w;
                if (swapUV) {
                    for (int c = 0; c < w; c += 2) {
                        dst[c] = src[c + 1];      /* U */
                        dst[c + 1] = src[c];      /* V */
                    }
                } else {
                    memcpy(dst, src, (size_t)w);
                }
            }
            LOGI("before rotate");
            /* rotate: g_dst(compact NV12 in) -> g_rot(out) */
            rotate_nv12(g_dst, w, h, g_rotate, g_rot);
            LOGI("before push");
            push_into_encoder(g_rot, w, h, g_rotate);
        }
    }
    OH_NativeBuffer_Unmap(nb);
    OH_NativeImage_ReleaseNativeWindowBuffer(g_cap, last, -1);
}

static void call_js(napi_env env, napi_value js_cb, void *context, void *data)
{
    frame_msg_t *msg = (frame_msg_t *)data;
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    if (msg->size > 0 && msg->data != NULL) {
        void *ab_data = NULL;
        napi_value ab = NULL;
        napi_value key = NULL;
        if (napi_create_arraybuffer(env, msg->size, &ab_data, &ab) == napi_ok) {
            memcpy(ab_data, msg->data, msg->size);
            napi_get_boolean(env, msg->keyframe, &key);
            napi_value argv[2] = {ab, key};
            napi_call_function(env, undefined, js_cb, 2, argv, NULL);
        }
    }
    free(msg->data);
    free(msg);
}

static void on_error(OH_AVCodec *codec, int32_t error_code, void *user_data)
{
    LOGE("encoder error: %{public}d", error_code);
}

static void on_stream_changed(OH_AVCodec *codec, OH_AVFormat *format, void *user_data)
{
}

static int g_need_calls = 0;

static void on_need_input(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *user_data)
{
    g_need_calls++;
    if (g_need_calls == 1 || g_need_calls % 100 == 0) {
        LOGI("need-input #%{public}d idx=%{public}u", g_need_calls, index);
    }
    pthread_mutex_lock(&g_iq_lock);
    if (g_iq_count < IQ_CAP) {
        g_iq[g_iq_tail].index = index;
        g_iq[g_iq_tail].buffer = buffer;
        g_iq_tail = (g_iq_tail + 1) % IQ_CAP;
        g_iq_count++;
    }
    pthread_mutex_unlock(&g_iq_lock);
}

static void on_new_output(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *user_data)
{
    OH_AVCodecBufferAttr attr;
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK || attr.size <= 0) {
        OH_VideoEncoder_FreeOutputBuffer(codec, index);
        return;
    }
    uint8_t *src = OH_AVBuffer_GetAddr(buffer) + attr.offset;
    bool key = (attr.flags & AVCODEC_BUFFER_FLAGS_SYNC_FRAME) != 0;
    frame_msg_t *msg = (frame_msg_t *)malloc(sizeof(frame_msg_t));
    if (msg == NULL) {
        OH_VideoEncoder_FreeOutputBuffer(codec, index);
        return;
    }
    msg->data = (uint8_t *)malloc((size_t)attr.size);
    msg->size = attr.size;
    msg->keyframe = key;
    if (msg->data != NULL) {
        memcpy(msg->data, src, (size_t)attr.size);
        g_out_frames++;
        if (g_out_frames <= 3 || g_out_frames % 200 == 0) {
            LOGI("encoded frame #%{public}d size=%{public}d key=%{public}d",
                 g_out_frames, attr.size, (int)key);
        }
        if (g_tsfn != NULL) {
            napi_call_threadsafe_function(g_tsfn, msg, napi_tsfn_blocking);
        } else {
            free(msg->data);
            free(msg);
        }
    } else {
        free(msg);
    }
    OH_VideoEncoder_FreeOutputBuffer(codec, index);
}

/* ---------- NV12 rotation (clockwise) ----------
 * src: W*H Y plane + (W*H)/2 interleaved UV. rotate in {0,90,180,270}.
 * 90/270 produce H*W layout. */
static void rotate_nv12(const uint8_t *src, int w, int h, int rotate, uint8_t *dst)
{
    const int ySize = w * h;
    const int cw = w / 2, ch = h / 2;

    if (rotate == 0) {
        memcpy(dst, src, (size_t)ySize * 3 / 2);
        return;
    }
    if (rotate == 180) {
        for (int y = 0; y < h; y++) {
            const uint8_t *row = src + (h - 1 - y) * w;
            for (int x = 0; x < w; x++) {
                dst[y * w + x] = row[w - 1 - x];
            }
        }
        uint8_t *dUV = dst + ySize;
        const uint8_t *sUV = src + ySize;
        for (int y = 0; y < ch; y++) {
            const uint8_t *row = sUV + (ch - 1 - y) * cw * 2;
            for (int x = 0; x < cw; x++) {
                dUV[(y * cw + x) * 2] = row[(cw - 1 - x) * 2];
                dUV[(y * cw + x) * 2 + 1] = row[(cw - 1 - x) * 2 + 1];
            }
        }
        return;
    }
    /* 90 clockwise: new(x2,y2) = old(w-1-y2, x2), new size h x w.
     * 270 clockwise: new(x2,y2) = old(y2, h-1-x2), new size h x w. */
    const int nw = h, nh = w;
    for (int y2 = 0; y2 < nh; y2++) {
        for (int x2 = 0; x2 < nw; x2++) {
            int sx, sy;
            if (rotate == 90) {
                sx = w - 1 - y2;
                sy = x2;
            } else {
                sx = y2;
                sy = h - 1 - x2;
            }
            dst[y2 * nw + x2] = src[sy * w + sx];
        }
    }
    const int ncw = nw / 2, nch = nh / 2;
    uint8_t *dUV = dst + nw * nh;
    const uint8_t *sUV = src + ySize;
    for (int y2 = 0; y2 < nch; y2++) {
        for (int x2 = 0; x2 < ncw; x2++) {
            int sx, sy;
            if (rotate == 90) {
                sx = cw - 1 - y2;
                sy = x2;
            } else {
                sx = y2;
                sy = ch - 1 - x2;
            }
            dUV[(y2 * ncw + x2) * 2] = sUV[(sy * cw + sx) * 2];
            dUV[(y2 * ncw + x2) * 2 + 1] = sUV[(sy * cw + sx) * 2 + 1];
        }
    }
}

/* ---------- capture surface napi ---------- */
static napi_value native_create_capture(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    int32_t w = 0, hh = 0, rot = 0;
    if (argc >= 3) {
        napi_get_value_int32(env, argv[0], &w);
        napi_get_value_int32(env, argv[1], &hh);
        napi_get_value_int32(env, argv[2], &rot);
    }
    if (g_cap != NULL) {
        napi_throw_error(env, NULL, "capture already created");
        return NULL;
    }
    OH_NativeImage *cap = OH_NativeImage_Create(0, 0);
    if (cap == NULL) {
        napi_throw_error(env, NULL, "create native image failed");
        return NULL;
    }
    /* CPU 读取 usage:默认 GPU 纹理 usage 无法 MapPlanes */
    uint64_t usage = (1ULL << 0) | (1ULL << 16); /* CPU_READ | CPU_READ_OFTEN */
    int32_t rusage = OH_ConsumerSurface_SetDefaultUsage(cap, usage);
    LOGI("set default usage rc=%{public}d", rusage);
    OH_OnFrameAvailableListener listener = { .context = NULL, .onFrameAvailable = on_frame_available };
    if (OH_NativeImage_SetOnFrameAvailableListener(cap, listener) != 0) {
        OH_NativeImage_Destroy(&cap);
        napi_throw_error(env, NULL, "set frame listener failed");
        return NULL;
    }
    uint64_t sid = 0;
    if (OH_NativeImage_GetSurfaceId(cap, &sid) != 0 || sid == 0) {
        OH_NativeImage_Destroy(&cap);
        napi_throw_error(env, NULL, "get capture surface id failed");
        return NULL;
    }
    g_cap = cap;
    g_cam_w = w;
    g_cam_h = hh;
    g_rotate = rot;
    g_plane_dumped = 0;
    size_t need = (size_t)w * hh * 3 / 2;
    free(g_rot);
    g_rot = (uint8_t *)malloc(need);
    g_rot_cap = g_rot != NULL ? need : 0;
    free(g_dst);
    g_dst = (uint8_t *)malloc(need);
    g_dst_cap = g_dst != NULL ? need : 0;
    LOGI("capture surface created %{public}dx%{public}d rot=%{public}d", w, hh, rot);
    char sidbuf[32];
    snprintf(sidbuf, sizeof(sidbuf), "%llu", (unsigned long long)sid);
    napi_value result;
    napi_create_string_utf8(env, sidbuf, NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value native_destroy_capture(napi_env env, napi_callback_info info)
{
    (void)env;
    (void)info;
    if (g_cap != NULL) {
        OH_NativeImage_Destroy(&g_cap);
        g_cap = NULL;
        LOGI("capture surface destroyed");
    }
    free(g_dst);
    g_dst = NULL;
    g_dst_cap = 0;
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value native_set_callback(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (argc < 1) {
        napi_throw_error(env, NULL, "callback required");
        return NULL;
    }
    napi_value resource_name;
    napi_create_string_utf8(env, "h264enc_cb", NAPI_AUTO_LENGTH, &resource_name);
    if (g_tsfn != NULL) {
        napi_release_threadsafe_function(g_tsfn, napi_tsfn_release);
        g_tsfn = NULL;
    }
    napi_create_threadsafe_function(env, argv[0], NULL, resource_name, 0, 1,
                                    NULL, NULL, NULL, call_js, &g_tsfn);
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value native_start(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    int32_t width = 1280, height = 720, fps = 25, bitrate = 2000000;
    if (argc >= 4) {
        napi_get_value_int32(env, argv[0], &width);
        napi_get_value_int32(env, argv[1], &height);
        napi_get_value_int32(env, argv[2], &fps);
        napi_get_value_int32(env, argv[3], &bitrate);
    }

    if (g_enc != NULL) {
        /* 彻底销毁旧实例并稍候,再创建新实例(HAL 释放时序) */
        OH_VideoEncoder_NotifyEndOfStream(g_enc);
        OH_VideoEncoder_Stop(g_enc);
        OH_VideoEncoder_Destroy(g_enc);
        g_enc = NULL;
        usleep(500000);
        pthread_mutex_lock(&g_iq_lock);
        g_iq_head = g_iq_tail = g_iq_count = 0;
        pthread_mutex_unlock(&g_iq_lock);
    }
    {
        OH_AVCodec *codec = OH_VideoEncoder_CreateByMime("video/avc");
        if (codec == NULL) {
            napi_throw_error(env, NULL, "create h264 encoder failed");
            return NULL;
        }
        OH_AVCodecCallback cb = {
            .onError = on_error,
            .onStreamChanged = on_stream_changed,
            .onNeedInputBuffer = on_need_input,
            .onNewOutputBuffer = on_new_output,
        };
        if (OH_VideoEncoder_RegisterCallback(codec, cb, NULL) != AV_ERR_OK) {
            OH_VideoEncoder_Destroy(codec);
            napi_throw_error(env, NULL, "register callback failed");
            return NULL;
        }
        g_enc = codec;
    }
    OH_AVCodec *codec = g_enc;

    OH_AVFormat *fmt = OH_AVFormat_CreateVideoFormat("video/avc", width, height);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_FRAME_RATE, fps);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_BITRATE, bitrate);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE, CBR);
    OH_AVErrCode rc = OH_VideoEncoder_Configure(codec, fmt);
    OH_AVFormat_Destroy(fmt);
    if (rc != AV_ERR_OK) {
        char m[48];
        snprintf(m, sizeof(m), "configure failed rc=%d", rc);
        OH_VideoEncoder_Destroy(codec);
        napi_throw_error(env, NULL, m);
        return NULL;
    }

    if (OH_VideoEncoder_Start(codec) != AV_ERR_OK) {
        napi_throw_error(env, NULL, "start encoder failed");
        return NULL;
    }
    pthread_mutex_lock(&g_iq_lock);
    g_iq_head = g_iq_tail = g_iq_count = 0;
    pthread_mutex_unlock(&g_iq_lock);
    g_out_frames = 0;
    g_in_frames = 0;
    g_push_ok = 0;
    g_need_calls = 0;
    g_push_enter = 0;
    LOGI("encoder started %{public}dx%{public}d@%{public}d (buffer mode)", width, height, fps);

    napi_value result;
    napi_create_int32(env, 1, &result);
    return result;
}

static void push_into_encoder(const uint8_t *nv12, int w, int h, int rotate)
{
    g_push_enter++;
    if (g_push_enter == 1 || g_push_enter % 100 == 0) {
        LOGI("push-enter #%{public}d have=%{public}d enc=%{public}d",
             g_push_enter, g_iq_count, g_enc != NULL ? 1 : 0);
    }
    pthread_mutex_lock(&g_iq_lock);
    bool have = g_iq_count > 0;
    pthread_mutex_unlock(&g_iq_lock);
    if (!have) {
        return;
    }
    size_t size = (size_t)w * h * 3 / 2;
    pthread_mutex_lock(&g_iq_lock);
    if (g_iq_count == 0) {
        pthread_mutex_unlock(&g_iq_lock);
        return;
    }
    uint32_t index = g_iq[g_iq_head].index;
    OH_AVBuffer *in = g_iq[g_iq_head].buffer;
    g_iq_head = (g_iq_head + 1) % IQ_CAP;
    g_iq_count--;
    pthread_mutex_unlock(&g_iq_lock);

    if (in == NULL) {
        LOGE("queued input buffer is null");
        return;
    }
    if (OH_AVBuffer_GetCapacity(in) < (int)size) {
        LOGE("input buffer too small");
        return;
    }
    memcpy(OH_AVBuffer_GetAddr(in), nv12, size);
    struct timeval tv;
    gettimeofday(&tv, NULL);
    OH_AVCodecBufferAttr attr = {
        .pts = (int64_t)tv.tv_sec * 1000000 + tv.tv_usec,
        .size = (int32_t)size,
        .offset = 0,
        .flags = AVCODEC_BUFFER_FLAGS_NONE,
    };
    OH_AVBuffer_SetBufferAttr(in, &attr);
    if (OH_VideoEncoder_PushInputBuffer(g_enc, index) != AV_ERR_OK) {
        LOGE("push input buffer failed");
    } else {
        g_push_ok++;
        if (g_push_ok == 1 || g_push_ok % 100 == 0) {
            LOGI("pushed #%{public}d", g_push_ok);
        }
    }
    (void)rotate;
}

static napi_value native_stop(napi_env env, napi_callback_info info)
{
    if (g_enc != NULL) {
        /* 只 Stop 不 Destroy:保留实例供下次 Reset 重配置 */
        OH_VideoEncoder_NotifyEndOfStream(g_enc);
        OH_VideoEncoder_Stop(g_enc);
        LOGI("encoder stopped, frames=%{public}d", g_out_frames);
    }
    free(g_rot);
    g_rot = NULL;
    g_rot_cap = 0;
    if (g_tsfn != NULL) {
        napi_release_threadsafe_function(g_tsfn, napi_tsfn_release);
        g_tsfn = NULL;
    }
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

EXTERN_C_START
static napi_value init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"createCaptureSurface", NULL, native_create_capture, NULL, NULL, NULL, napi_default, NULL},
        {"destroyCaptureSurface", NULL, native_destroy_capture, NULL, NULL, NULL, napi_default, NULL},
        {"setCallback", NULL, native_set_callback, NULL, NULL, NULL, napi_default, NULL},
        {"start", NULL, native_start, NULL, NULL, NULL, napi_default, NULL},
        {"stop", NULL, native_stop, NULL, NULL, NULL, napi_default, NULL},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = NULL,
    .nm_register_func = init,
    .nm_modname = "h264enc",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

__attribute__((constructor)) void RegisterH264EncModule(void)
{
    napi_module_register(&demoModule);
}
