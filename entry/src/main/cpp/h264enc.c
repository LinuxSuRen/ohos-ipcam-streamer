/*
 * h264enc.c - NAPI shim for OH_VideoEncoder (buffer-input H.264 encoder
 * with pre-encode NV12 rotation), MULTI-CAMERA instances.
 *
 * Exposes to ArkTS (cam = camera index, 0..3):
 *   setCallback(cb: (frame, keyframe, cam) => void)
 *   createCapture(cam, rotateDeg): string           // surfaceId
 *   setCameraFormat(cam, w, h, rotateDeg): void     // actual preview dims, before camera start
 *   destroyCapture(cam): void
 *   startEncoder(cam, outW, outH, fps, bitrate): number
 *   stopEncoder(cam): void
 *   snapshotWidth(cam) / snapshotHeight(cam): number
 *   takeSnapshotRgba(cam): ArrayBuffer | null
 *
 * Pipeline per camera: camera Preview -> OH_NativeImage -> de-stride(+NV21 swap)
 * -> rotate (0/90/180/270, output width cropped to 32-aligned - fixes chroma
 * corruption on 720-wide HW encode) -> OH_VideoEncoder buffer input.
 */
#include "napi/native_api.h"

#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avcodec_audioencoder.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avmemory.h>
#include <native_image/native_image.h>
#include <native_buffer/native_buffer.h>
#include <ohaudio/native_audiocapturer.h>
#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiostreambuilder.h>
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

#define MAX_CAMS 4

/* free input buffers delivered by on_need_input (index + buffer pair) */
#define IQ_CAP 64
typedef struct {
    uint32_t index;
    OH_AVBuffer *buffer;
} in_slot_t;

typedef struct {
    int cam;
    /* capture */
    OH_NativeImage *cap;
    int cam_w;      /* actual preview dims (from setCameraFormat) */
    int cam_h;
    int rotate;
    int plane_dumped;
    /* scratch: dst = de-strided compact input; rot = rotated output; snap = snapshot copy */
    uint8_t *rot, *dst, *snap;
    size_t rot_cap, dst_cap, snap_cap;
    pthread_mutex_t snap_lock;
    int snap_seq;
    /* encoder */
    OH_AVCodec *enc;
    in_slot_t iq[IQ_CAP];
    int iq_head, iq_tail, iq_count;
    pthread_mutex_t iq_lock;
    /* counters */
    int out_frames, in_frames, push_ok, need_calls, push_enter;
} cam_ctx_t;

static cam_ctx_t *g_cams[MAX_CAMS];
static napi_threadsafe_function g_tsfn = NULL;
/* snapshot RGBA scratch: only touched from the JS thread, no lock needed */
static uint8_t *g_rgba = NULL;
static size_t g_rgba_cap = 0;

typedef struct {
    uint8_t *data;
    int32_t size;
    bool keyframe;
    int cam;
} frame_msg_t;

static cam_ctx_t *find_cam(int idx)
{
    if (idx < 0 || idx >= MAX_CAMS) {
        return NULL;
    }
    return g_cams[idx];
}

/* output dims after rotation with 32-aligned width crop */
static void rot_out_dims(const cam_ctx_t *c, int *w, int *h)
{
    if (c->rotate == 90 || c->rotate == 270) {
        *w = c->cam_h & ~31;
        *h = c->cam_w;
    } else {
        *w = c->cam_w & ~31;
        *h = c->cam_h;
    }
}

/* effective (cropped) source dims used by rotate */
static void rot_src_eff(const cam_ctx_t *c, int *w, int *h)
{
    if (c->rotate == 90 || c->rotate == 270) {
        *w = c->cam_w;          /* crop source height -> out width aligned */
        *h = c->cam_h & ~31;
    } else {
        *w = c->cam_w & ~31;    /* crop source width */
        *h = c->cam_h;
    }
}

/* ---------- NV12 rotation (clockwise), cropped region ----------
 * src: compact NV12 srcW x srcH. Effective area effW x effH anchored so the
 * crop is centered. rotate in {0,90,180,270}; 90/270 produce effH x effW. */
static void rotate_nv12_crop(const uint8_t *src, int srcW, int srcH,
                             int effW, int effH, int rotate, uint8_t *dst)
{
    const int offX = (srcW - effW) / 2;
    const int offY = (srcH - effH) / 2;
    const int ySrcStride = srcW;
    const uint8_t *y0 = src + (size_t)offY * ySrcStride + offX;
    const uint8_t *uv0 = src + (size_t)srcW * srcH + (size_t)(offY / 2) * srcW + offX;

    if (rotate == 0) {
        for (int r = 0; r < effH; r++) {
            memcpy(dst + (size_t)r * effW, y0 + (size_t)r * ySrcStride, (size_t)effW);
        }
        uint8_t *dUV = dst + (size_t)effW * effH;
        for (int r = 0; r < effH / 2; r++) {
            memcpy(dUV + (size_t)r * effW, uv0 + (size_t)r * srcW, (size_t)effW);
        }
        return;
    }
    if (rotate == 180) {
        for (int y = 0; y < effH; y++) {
            const uint8_t *row = y0 + (size_t)(effH - 1 - y) * ySrcStride;
            for (int x = 0; x < effW; x++) {
                dst[(size_t)y * effW + x] = row[effW - 1 - x];
            }
        }
        uint8_t *dUV = dst + (size_t)effW * effH;
        const int cw = effW / 2, ch = effH / 2;
        for (int y = 0; y < ch; y++) {
            const uint8_t *row = uv0 + (size_t)(ch - 1 - y) * srcW;
            for (int x = 0; x < cw; x++) {
                dUV[(size_t)(y * cw + x) * 2] = row[(cw - 1 - x) * 2];
                dUV[(size_t)(y * cw + x) * 2 + 1] = row[(cw - 1 - x) * 2 + 1];
            }
        }
        return;
    }
    /* 90 clockwise: new(x2,y2) = old(w-1-y2, x2), new size effH x effW.
     * 270 clockwise: new(x2,y2) = old(y2, h-1-x2), new size effH x effW. */
    const int nw = effH, nh = effW;
    for (int y2 = 0; y2 < nh; y2++) {
        for (int x2 = 0; x2 < nw; x2++) {
            int sx, sy;
            if (rotate == 90) {
                sx = effW - 1 - y2;
                sy = x2;
            } else {
                sx = y2;
                sy = effH - 1 - x2;
            }
            dst[(size_t)y2 * nw + x2] = y0[(size_t)sy * ySrcStride + sx];
        }
    }
    const int ncw = nw / 2, nch = nh / 2;
    const int cw = effW / 2, ch = effH / 2;
    uint8_t *dUV = dst + (size_t)nw * nh;
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
            dUV[(size_t)(y2 * ncw + x2) * 2] = uv0[(size_t)sy * srcW + sx * 2];
            dUV[(size_t)(y2 * ncw + x2) * 2 + 1] = uv0[(size_t)sy * srcW + sx * 2 + 1];
        }
    }
}

static void push_into_encoder(cam_ctx_t *c, const uint8_t *nv12, int w, int h)
{
    c->push_enter++;
    if (c->push_enter == 1 || c->push_enter % 100 == 0) {
        LOGI("cam%{public}d push-enter #%{public}d have=%{public}d enc=%{public}d",
             c->cam, c->push_enter, c->iq_count, c->enc != NULL ? 1 : 0);
    }
    pthread_mutex_lock(&c->iq_lock);
    if (c->iq_count == 0) {
        pthread_mutex_unlock(&c->iq_lock);
        return;
    }
    size_t size = (size_t)w * h * 3 / 2;
    uint32_t index = c->iq[c->iq_head].index;
    OH_AVBuffer *in = c->iq[c->iq_head].buffer;
    c->iq_head = (c->iq_head + 1) % IQ_CAP;
    c->iq_count--;
    pthread_mutex_unlock(&c->iq_lock);

    if (in == NULL) {
        LOGE("cam%{public}d queued input buffer is null", c->cam);
        return;
    }
    if (OH_AVBuffer_GetCapacity(in) < (int)size) {
        LOGE("cam%{public}d input buffer too small", c->cam);
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
    if (OH_VideoEncoder_PushInputBuffer(c->enc, index) != AV_ERR_OK) {
        LOGE("cam%{public}d push input buffer failed", c->cam);
    } else {
        c->push_ok++;
    }
}

static void on_frame_available(void *ctx)
{
    cam_ctx_t *c = (cam_ctx_t *)ctx;
    c->in_frames++;
    if (c->in_frames == 1 || c->in_frames % 100 == 0) {
        LOGI("cam%{public}d frame-available #%{public}d pushed=%{public}d",
             c->cam, c->in_frames, c->push_ok);
    }
    if (c->cap == NULL || c->enc == NULL) {
        return;
    }
    /* drop stale buffers, keep the latest */
    OHNativeWindowBuffer *nwb = NULL;
    OHNativeWindowBuffer *last = NULL;
    int fence = -1;
    while (OH_NativeImage_AcquireNativeWindowBuffer(c->cap, &nwb, &fence) == 0) {
        if (last != NULL) {
            OH_NativeImage_ReleaseNativeWindowBuffer(c->cap, last, -1);
        }
        last = nwb;
        nwb = NULL;
    }
    if (last == NULL) {
        return;
    }

    OH_NativeBuffer *nb = NULL;
    if (OH_NativeBuffer_FromNativeWindowBuffer(last, &nb) != 0 || nb == NULL) {
        OH_NativeImage_ReleaseNativeWindowBuffer(c->cap, last, -1);
        return;
    }
    void *addr = NULL;
    OH_NativeBuffer_Planes planes;
    memset(&planes, 0, sizeof(planes));
    if (OH_NativeBuffer_MapPlanes(nb, &addr, &planes) != 0 || addr == NULL) {
        LOGE("cam%{public}d map planes failed", c->cam);
        OH_NativeBuffer_Unmap(nb);
        OH_NativeImage_ReleaseNativeWindowBuffer(c->cap, last, -1);
        return;
    }
    const int w = c->cam_w;
    const int h = c->cam_h;
    int outW = 0, outH = 0;
    rot_out_dims(c, &outW, &outH);
    const size_t rotNeed = (size_t)outW * outH * 3 / 2;
    if (w > 0 && h > 0 && c->rot_cap >= rotNeed && c->dst_cap >= (size_t)w * h * 3 / 2) {
        const uint8_t *y = (const uint8_t *)addr + planes.planes[0].offset;
        if (c->plane_dumped == 0) {
            c->plane_dumped = 1;
            LOGI("cam%{public}d planeCount=%{public}u", c->cam, planes.planeCount);
        }
        if (planes.planeCount >= 2) {
            /* 实测布局(API 24 真机):rowStride=字节/样本,colStride=行字节宽。
             * planeCount=3 且 plane[1](U).offset > plane[2](V).offset 时为 NV21
             * (VU 交错),拷贝时交换为 NV12。planeCount=2 视作 NV12。 */
            const int yRowBytes = planes.planes[0].columnStride > 0
                                  ? (int)planes.planes[0].columnStride : w;
            for (int r = 0; r < h; r++) {
                memcpy(c->dst + (size_t)r * w, y + (size_t)r * yRowBytes, (size_t)w);
            }
            const uint32_t uvOff = (planes.planeCount >= 3 &&
                                    planes.planes[1].offset > planes.planes[2].offset)
                                   ? planes.planes[2].offset : planes.planes[1].offset;
            const int uvRowBytes = planes.planes[1].columnStride > 0
                                   ? (int)planes.planes[1].columnStride : w;
            const uint8_t *uv = (const uint8_t *)addr + uvOff;
            uint8_t *dstUV = c->dst + (size_t)w * h;
            const int swapUV = (planes.planeCount >= 3 &&
                                planes.planes[1].offset > planes.planes[2].offset) ? 1 : 0;
            for (int r = 0; r < h / 2; r++) {
                const uint8_t *src = uv + (size_t)r * uvRowBytes;
                uint8_t *dst = dstUV + (size_t)r * w;
                if (swapUV) {
                    for (int col = 0; col < w; col += 2) {
                        dst[col] = src[col + 1];      /* U */
                        dst[col + 1] = src[col];      /* V */
                    }
                } else {
                    memcpy(dst, src, (size_t)w);
                }
            }
            int effW = 0, effH = 0;
            rot_src_eff(c, &effW, &effH);
            rotate_nv12_crop(c->dst, w, h, effW, effH, c->rotate, c->rot);
            /* cache rotated frame for snapshot consumers */
            pthread_mutex_lock(&c->snap_lock);
            if (c->snap != NULL && c->snap_cap >= rotNeed) {
                memcpy(c->snap, c->rot, rotNeed);
                c->snap_seq++;
                if (c->snap_seq == 1) {
                    LOGI("cam%{public}d first snapshot cached (%{public}d bytes)", c->cam, (int)rotNeed);
                }
            } else if (c->snap_seq == 0) {
                LOGE("cam%{public}d snap skip: snap=%{public}d cap=%{public}d need=%{public}d",
                     c->cam, c->snap != NULL ? 1 : 0, (int)c->snap_cap, (int)rotNeed);
            }
            pthread_mutex_unlock(&c->snap_lock);
            push_into_encoder(c, c->rot, outW, outH);
        }
    }
    OH_NativeBuffer_Unmap(nb);
    OH_NativeImage_ReleaseNativeWindowBuffer(c->cap, last, -1);
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
        napi_value cam = NULL;
        if (napi_create_arraybuffer(env, msg->size, &ab_data, &ab) == napi_ok) {
            memcpy(ab_data, msg->data, msg->size);
            napi_get_boolean(env, msg->keyframe, &key);
            napi_create_int32(env, msg->cam, &cam);
            napi_value argv[3] = {ab, key, cam};
            napi_call_function(env, undefined, js_cb, 3, argv, NULL);
        }
    }
    free(msg->data);
    free(msg);
}

static void on_error(OH_AVCodec *codec, int32_t error_code, void *user_data)
{
    cam_ctx_t *c = (cam_ctx_t *)user_data;
    LOGE("cam%{public}d encoder error: %{public}d", c ? c->cam : -1, error_code);
}

static void on_stream_changed(OH_AVCodec *codec, OH_AVFormat *format, void *user_data)
{
}

static void on_need_input(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *user_data)
{
    cam_ctx_t *c = (cam_ctx_t *)user_data;
    c->need_calls++;
    if (c->need_calls == 1 || c->need_calls % 100 == 0) {
        LOGI("cam%{public}d need-input #%{public}d idx=%{public}u", c->cam, c->need_calls, index);
    }
    pthread_mutex_lock(&c->iq_lock);
    if (c->iq_count < IQ_CAP) {
        c->iq[c->iq_tail].index = index;
        c->iq[c->iq_tail].buffer = buffer;
        c->iq_tail = (c->iq_tail + 1) % IQ_CAP;
        c->iq_count++;
    }
    pthread_mutex_unlock(&c->iq_lock);
}

static void on_new_output(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *user_data)
{
    cam_ctx_t *c = (cam_ctx_t *)user_data;
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
    msg->cam = c->cam;
    if (msg->data != NULL) {
        memcpy(msg->data, src, (size_t)attr.size);
        c->out_frames++;
        if (c->out_frames <= 3 || c->out_frames % 200 == 0) {
            LOGI("cam%{public}d encoded frame #%{public}d size=%{public}d key=%{public}d",
                 c->cam, c->out_frames, attr.size, (int)key);
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

/* ---------- snapshot: rotated NV12 -> RGBA (BT.601 limited range) ---------- */
static void nv12_to_rgba(const uint8_t *nv12, int w, int h, uint8_t *rgba)
{
    const uint8_t *yp = nv12;
    const uint8_t *uvp = nv12 + (size_t)w * h;
    for (int r = 0; r < h; r++) {
        const uint8_t *yrow = yp + (size_t)r * w;
        const uint8_t *uvrow = uvp + (size_t)(r >> 1) * w;
        uint8_t *out = rgba + (size_t)r * w * 4;
        for (int col = 0; col < w; col++) {
            const int cy = yrow[col] - 16;
            const int u = (int)uvrow[(col >> 1) * 2] - 128;
            const int v = (int)uvrow[(col >> 1) * 2 + 1] - 128;
            int rr = (298 * cy + 409 * v + 128) >> 8;
            int gg = (298 * cy - 100 * u - 208 * v + 128) >> 8;
            int bb = (298 * cy + 516 * u + 128) >> 8;
            out[col * 4] = (uint8_t)(rr < 0 ? 0 : (rr > 255 ? 255 : rr));
            out[col * 4 + 1] = (uint8_t)(gg < 0 ? 0 : (gg > 255 ? 255 : gg));
            out[col * 4 + 2] = (uint8_t)(bb < 0 ? 0 : (bb > 255 ? 255 : bb));
            out[col * 4 + 3] = 255;
        }
    }
}

/* ---------- audio: mic → AAC-LC(可选,客户端经 RTSP SETUP 协商是否接收) ---------- */
static OH_AudioCapturer *g_mic = NULL;
static OH_AVCodec *g_aenc = NULL;
static napi_threadsafe_function g_audio_tsfn = NULL;
static pthread_mutex_t g_aiq_lock = PTHREAD_MUTEX_INITIALIZER;
typedef struct {
    uint32_t index;
    OH_AVMemory *mem;
} audio_in_slot_t;
static audio_in_slot_t g_aiq[IQ_CAP];
static int g_aiq_head = 0, g_aiq_tail = 0, g_aiq_count = 0;
static volatile int g_audio_ok = 0;

typedef struct {
    uint8_t *data;
    int32_t size;
    int type; /* 0 = AAC 裸帧, 1 = G.711 PCMA 帧(160 字节 = 20ms) */
} audio_msg_t;

/* G.711 状态:48k 立体声 → 单声道 → 6:1 抽取到 8k → 160 样本一包 */
#define G711_SAMPLES_PER_PKT 160
#define G711_DECIM 6
#define G711_FIR_TAPS 33
static int g_g711_phase = 0;
static int16_t g_g711_pcm[G711_SAMPLES_PER_PKT];
static int g_g711_count = 0;
static int16_t g_g711_hist[G711_FIR_TAPS]; /* 最近 33 个单声道 48k 样本(循环写) */
static int g_g711_hist_pos = 0;
/* 33 阶 Hamming 窗 sinc 低通,截止 3.4kHz @48k,DC 增益 1。
 * 裸均值抽取无抗混叠:4kHz 以上能量折叠回语音频段,听感沙哑浑浊。 */
static const float g_g711_fir[G711_FIR_TAPS] = {
    +0.001178f, +0.000719f, -0.000136f, -0.001833f, -0.004591f, -0.008062f,
    -0.011148f, -0.012063f, -0.008706f, +0.000747f, +0.017180f, +0.040029f,
    +0.067096f, +0.094813f, +0.118903f, +0.135310f, +0.141130f, +0.135310f,
    +0.118903f, +0.094813f, +0.067096f, +0.040029f, +0.017180f, +0.000747f,
    -0.008706f, -0.012063f, -0.011148f, -0.008062f, -0.004591f, -0.001833f,
    -0.000136f, +0.000719f, +0.001178f,
};

/* ITU-T G.711 A-law 编码(13 段折线) */
static uint8_t linear2alaw(int16_t pcm_val)
{
    static const int16_t seg_end[8] = {0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF, 0x3FFF, 0x7FFF};
    const int16_t mask = 0xD5;
    int16_t seg;
    uint8_t aval;
    pcm_val = (int16_t)(pcm_val >> 3); /* 16 -> 13 bit */
    if (pcm_val >= 0) {
        /* 正数直接分段 */
    } else {
        pcm_val = (int16_t)(-pcm_val - 1);
    }
    for (seg = 0; seg < 8; seg++) {
        if (pcm_val <= seg_end[seg]) {
            break;
        }
    }
    if (seg >= 8) {
        return (uint8_t)(0x7F ^ mask);
    }
    aval = (uint8_t)(seg << 4);
    if (seg < 2) {
        aval |= (uint8_t)((pcm_val >> 1) & 0x0F);
    } else {
        aval |= (uint8_t)((pcm_val >> seg) & 0x0F);
    }
    return (uint8_t)(aval ^ mask);
}

/* 48k 立体声 PCM → 下采样 → PCMA 帧;每凑满 160 样本经 tsfn 发一帧 */
static void g711_feed(const int16_t *pcm, int32_t samples /* 每通道样本数 */)
{
    for (int32_t i = 0; i < samples; i++) {
        const int32_t mono = ((int32_t)pcm[i * 2] + pcm[i * 2 + 1]) / 2;
        /* 入 FIR 历史,每 6 个样本卷积输出一个 8k 样本(带内无混叠) */
        g_g711_hist[g_g711_hist_pos] = (int16_t)mono;
        g_g711_hist_pos = (g_g711_hist_pos + 1) % G711_FIR_TAPS;
        if (++g_g711_phase == G711_DECIM) {
            float acc = 0.0f;
            int idx = g_g711_hist_pos; /* 从最旧样本开始 */
            for (int k = 0; k < G711_FIR_TAPS; k++) {
                acc += g_g711_fir[k] * (float)g_g711_hist[idx];
                idx = (idx + 1) % G711_FIR_TAPS;
            }
            int32_t v = (int32_t)acc;
            if (v > 32767) {
                v = 32767;
            }
            if (v < -32768) {
                v = -32768;
            }
            g_g711_pcm[g_g711_count++] = (int16_t)v;
            g_g711_phase = 0;
            if (g_g711_count == G711_SAMPLES_PER_PKT) {
                if (g_audio_tsfn != NULL) {
                    audio_msg_t *msg = (audio_msg_t *)malloc(sizeof(audio_msg_t));
                    if (msg != NULL) {
                        msg->data = (uint8_t *)malloc(G711_SAMPLES_PER_PKT);
                        msg->size = G711_SAMPLES_PER_PKT;
                        msg->type = 1;
                        if (msg->data != NULL) {
                            for (int j = 0; j < G711_SAMPLES_PER_PKT; j++) {
                                msg->data[j] = linear2alaw(g_g711_pcm[j]);
                            }
                            napi_call_threadsafe_function(g_audio_tsfn, msg, napi_tsfn_blocking);
                        } else {
                            free(msg);
                        }
                    }
                }
                g_g711_count = 0;
            }
        }
    }
}

/* ---------- speaker:对讲回传(RTP PCMA → A-law 解码 → 扬声器) ---------- */
static OH_AudioRenderer *g_spk = NULL;

/* ITU-T G.711 A-law 解码(段基+符号位重建线性 PCM) */
static int16_t alaw2linear(uint8_t a_val)
{
    int16_t t, seg;
    a_val ^= 0x55;
    t = (a_val & 0x0F) << 4;
    seg = ((unsigned)a_val & 0x70) >> 4;
    switch (seg) {
    case 0: t += 8; break;
    case 1: t += 0x108; break;
    default: t += 0x108; t <<= seg - 1;
    }
    return (a_val & 0x80) ? t : -t;
}

/* 回传 PCMA 环形缓冲(字节);renderer 实时回调从其中取数据 */
#define SPK_RING (16 * 1024)
static uint8_t g_spk_ring[SPK_RING];
static volatile int g_spk_head = 0; /* 写入位置 */
static volatile int g_spk_tail = 0; /* 读取位置 */

static OH_AudioData_Callback_Result spk_on_write(OH_AudioRenderer *renderer, void *userData,
                                                 void *audioData, int32_t audioDataSize)
{
    (void)renderer;
    (void)userData;
    int16_t *out = (int16_t *)audioData;
    const int want = audioDataSize / 2; /* 样本数(单声道) */
    for (int i = 0; i < want; i++) {
        if (g_spk_head == g_spk_tail) {
            /* 无数据:输出静音 */
            out[i] = 0;
        } else {
            out[i] = alaw2linear(g_spk_ring[g_spk_tail]);
            g_spk_tail = (g_spk_tail + 1) % SPK_RING;
        }
    }
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

static napi_value native_start_speaker(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_spk != NULL) {
        napi_value r;
        napi_create_int32(env, 1, &r);
        return r;
    }
    OH_AudioStreamBuilder *builder = NULL;
    if (OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER) != AUDIOSTREAM_SUCCESS) {
        napi_throw_error(env, NULL, "speaker builder failed");
        return NULL;
    }
    OH_AudioStreamBuilder_SetSamplingRate(builder, 8000);
    OH_AudioStreamBuilder_SetChannelCount(builder, 1);
    OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
    OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder, spk_on_write, NULL);
    OH_AudioRenderer *spk = NULL;
    if (OH_AudioStreamBuilder_GenerateRenderer(builder, &spk) != AUDIOSTREAM_SUCCESS || spk == NULL) {
        OH_AudioStreamBuilder_Destroy(builder);
        napi_throw_error(env, NULL, "speaker generate failed");
        return NULL;
    }
    OH_AudioStreamBuilder_Destroy(builder);
    if (OH_AudioRenderer_Start(spk) != AUDIOSTREAM_SUCCESS) {
        OH_AudioRenderer_Release(spk);
        napi_throw_error(env, NULL, "speaker start failed");
        return NULL;
    }
    g_spk_head = g_spk_tail = 0;
    g_spk = spk;
    LOGI("speaker started (8000/1ch, backchannel)");
    napi_value r;
    napi_create_int32(env, 1, &r);
    return r;
}

static napi_value native_stop_speaker(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_spk != NULL) {
        OH_AudioRenderer_Stop(g_spk);
        OH_AudioRenderer_Release(g_spk);
        g_spk = NULL;
        LOGI("speaker stopped");
    }
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/** 对讲回传:写入一段 PCMA 字节(RTP 载荷),A-law 解码后播放。 */
static napi_value native_speaker_write_pcma(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (argc < 1 || g_spk == NULL) {
        napi_value result;
        napi_get_undefined(env, &result);
        return result;
    }
    void *data = NULL;
    size_t len = 0;
    if (napi_get_arraybuffer_info(env, argv[0], &data, &len) != napi_ok || data == NULL || len == 0) {
        napi_value result;
        napi_get_undefined(env, &result);
        return result;
    }
    static int spk_pkts = 0;
    spk_pkts++;
    if (spk_pkts == 1 || spk_pkts % 250 == 0) {
        LOGI("speaker pcma pkt #%{public}d (%{public}d bytes)", spk_pkts, (int)len);
    }
    const uint8_t *src = (const uint8_t *)data;
    for (size_t i = 0; i < len; i++) {
        const int next = (g_spk_head + 1) % SPK_RING;
        if (next == g_spk_tail) {
            /* 缓冲满:丢最旧,保证实时性 */
            g_spk_tail = (g_spk_tail + 1) % SPK_RING;
        }
        g_spk_ring[g_spk_head] = src[i];
        g_spk_head = next;
    }
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static void audio_call_js(napi_env env, napi_value js_cb, void *context, void *data)
{
    audio_msg_t *msg = (audio_msg_t *)data;
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    if (msg->size > 0 && msg->data != NULL) {
        void *ab_data = NULL;
        napi_value ab = NULL;
        napi_value type = NULL;
        if (napi_create_arraybuffer(env, msg->size, &ab_data, &ab) == napi_ok) {
            memcpy(ab_data, msg->data, msg->size);
            napi_create_int32(env, msg->type, &type);
            napi_value argv[2] = {ab, type};
            napi_call_function(env, undefined, js_cb, 2, argv, NULL);
        }
    }
    free(msg->data);
    free(msg);
}

static void audio_on_error(OH_AVCodec *codec, int32_t error_code, void *user_data)
{
    LOGE("aac encoder error: %{public}d", error_code);
}

static void audio_on_stream_changed(OH_AVCodec *codec, OH_AVFormat *format, void *user_data)
{
}

static void audio_on_need_input(OH_AVCodec *codec, uint32_t index, OH_AVMemory *data, void *user_data)
{
    pthread_mutex_lock(&g_aiq_lock);
    if (g_aiq_count < IQ_CAP) {
        g_aiq[g_aiq_tail].index = index;
        g_aiq[g_aiq_tail].mem = data;
        g_aiq_tail = (g_aiq_tail + 1) % IQ_CAP;
        g_aiq_count++;
    }
    pthread_mutex_unlock(&g_aiq_lock);
}

static void audio_on_new_output(OH_AVCodec *codec, uint32_t index, OH_AVMemory *data,
                                OH_AVCodecBufferAttr *attr, void *user_data)
{
    if (attr == NULL || attr->size <= 0 || data == NULL) {
        OH_AudioEncoder_FreeOutputData(codec, index);
        return;
    }
    uint8_t *src = OH_AVMemory_GetAddr(data);
    audio_msg_t *msg = (audio_msg_t *)malloc(sizeof(audio_msg_t));
    if (msg != NULL) {
        msg->data = (uint8_t *)malloc((size_t)attr->size);
        msg->size = attr->size;
        msg->type = 0;
        if (msg->data != NULL && src != NULL) {
            memcpy(msg->data, src, (size_t)attr->size);
            if (g_audio_tsfn != NULL) {
                napi_call_threadsafe_function(g_audio_tsfn, msg, napi_tsfn_blocking);
            } else {
                free(msg->data);
                free(msg);
            }
        } else {
            free(msg);
        }
    }
    OH_AudioEncoder_FreeOutputData(codec, index);
}

/* OHAudio 实时读回调:PCM 拷入编码器输入缓冲(不可阻塞) */
static int32_t audio_on_read(OH_AudioCapturer *capturer, void *userData, void *buffer, int32_t size)
{
    if (!g_audio_ok) {
        return 0;
    }
    if (g_audio_ok) {
        g711_feed((const int16_t *)buffer, size / 4 /* 立体声 16bit */);
    }
    pthread_mutex_lock(&g_aiq_lock);
    if (g_aiq_count > 0 && g_aenc != NULL) {
        uint32_t index = g_aiq[g_aiq_head].index;
        OH_AVMemory *in = g_aiq[g_aiq_head].mem;
        g_aiq_head = (g_aiq_head + 1) % IQ_CAP;
        g_aiq_count--;
        pthread_mutex_unlock(&g_aiq_lock);
        uint8_t *dst = in != NULL ? OH_AVMemory_GetAddr(in) : NULL;
        int32_t cap = in != NULL ? OH_AVMemory_GetSize(in) : 0;
        if (dst != NULL && cap >= size) {
            memcpy(dst, buffer, (size_t)size);
            OH_AVCodecBufferAttr attr = {
                .pts = 0,
                .size = size,
                .offset = 0,
                .flags = AVCODEC_BUFFER_FLAGS_NONE,
            };
            OH_AudioEncoder_PushInputData(g_aenc, index, attr);
        }
        return 0;
    }
    pthread_mutex_unlock(&g_aiq_lock);
    return 0;
}

static napi_value native_set_audio_callback(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (argc < 1) {
        napi_throw_error(env, NULL, "callback required");
        return NULL;
    }
    napi_value resource_name;
    napi_create_string_utf8(env, "h264enc_acb", NAPI_AUTO_LENGTH, &resource_name);
    if (g_audio_tsfn != NULL) {
        napi_release_threadsafe_function(g_audio_tsfn, napi_tsfn_release);
        g_audio_tsfn = NULL;
    }
    napi_create_threadsafe_function(env, argv[0], NULL, resource_name, 0, 1,
                                    NULL, NULL, NULL, audio_call_js, &g_audio_tsfn);
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static void audio_teardown(void)
{
    g_audio_ok = 0;
    if (g_mic != NULL) {
        OH_AudioCapturer_Stop(g_mic);
        OH_AudioCapturer_Release(g_mic);
        g_mic = NULL;
    }
    if (g_aenc != NULL) {
        OH_AudioEncoder_Stop(g_aenc);
        OH_AudioEncoder_Destroy(g_aenc);
        g_aenc = NULL;
    }
    pthread_mutex_lock(&g_aiq_lock);
    g_aiq_head = g_aiq_tail = g_aiq_count = 0;
    pthread_mutex_unlock(&g_aiq_lock);
    g_g711_phase = 0;
    g_g711_count = 0;
    g_g711_hist_pos = 0;
    memset(g_g711_hist, 0, sizeof(g_g711_hist));
}

/** 启动麦克风采集 + AAC-LC 编码(44100/立体声/64kbps)。
 *  失败返回 0(视频照常,SDP/ONVIF 不带音频)。 */
static napi_value native_start_audio(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_audio_ok) {
        napi_value r;
        napi_create_int32(env, g_aenc != NULL ? 2 : 1, &r);
        return r;
    }
    int aac_ok = 0;
    do {
        OH_AudioStreamBuilder *builder = NULL;
        if (OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_CAPTURER) != AUDIOSTREAM_SUCCESS) {
            LOGE("audio builder create failed");
            break;
        }
        OH_AudioStreamBuilder_SetSamplingRate(builder, 48000);
        OH_AudioStreamBuilder_SetChannelCount(builder, 2);
        OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
        struct OH_AudioCapturer_Callbacks_Struct cbs;
        memset(&cbs, 0, sizeof(cbs));
        cbs.OH_AudioCapturer_OnReadData = audio_on_read;
        OH_AudioStreamBuilder_SetCapturerCallback(builder, cbs, NULL);
        OH_AudioCapturer *mic = NULL;
        if (OH_AudioStreamBuilder_GenerateCapturer(builder, &mic) != AUDIOSTREAM_SUCCESS || mic == NULL) {
            LOGE("generate capturer failed");
            OH_AudioStreamBuilder_Destroy(builder);
            break;
        }
        OH_AudioStreamBuilder_Destroy(builder);
        g_mic = mic;

        OH_AVCodec *enc = OH_AudioEncoder_CreateByMime("audio/aac");
        if (enc == NULL) {
            LOGE("aac CreateByMime failed, try CreateByName(avenc_aac)");
            enc = OH_AudioEncoder_CreateByName("avenc_aac");
        }
        if (enc == NULL) {
            /* AAC 不可用:仅 G.711(纯软件)继续 */
            LOGE("aac encoder unavailable, G.711 only");
            break;
        }
        aac_ok = 1;
        /* 音频编码器仅提供 legacy 回调(AVMemory 型),写入用 OH_AVMemory_GetAddr,
         * 提交用新式 PushInputData(index+attr),两者混用为官方示例做法 */
        OH_AVCodecAsyncCallback cb = {
            .onError = audio_on_error,
            .onStreamChanged = audio_on_stream_changed,
            .onNeedInputData = audio_on_need_input,
            .onNeedOutputData = audio_on_new_output,
        };
        if (OH_AudioEncoder_SetCallback(enc, cb, NULL) != AV_ERR_OK) {
            OH_AudioEncoder_Destroy(enc);
            break;
        }
        OH_AVFormat *fmt = OH_AVFormat_CreateAudioFormat("audio/aac", 48000, 2);
        OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE);
        OH_AVFormat_SetLongValue(fmt, OH_MD_KEY_BITRATE, 64000);
        OH_AVErrCode rc = OH_AudioEncoder_Configure(enc, fmt);
        OH_AVFormat_Destroy(fmt);
        if (rc != AV_ERR_OK) {
            LOGE("aac configure failed rc=%{public}d", rc);
            OH_AudioEncoder_Destroy(enc);
            break;
        }
        if (OH_AudioEncoder_Start(enc) != AV_ERR_OK) {
            LOGE("aac start failed");
            OH_AudioEncoder_Destroy(enc);
            break;
        }
        g_aenc = enc;
        if (OH_AudioCapturer_Start(g_mic) != AUDIOSTREAM_SUCCESS) {
            LOGE("mic start failed");
            break;
        }
        g_audio_ok = 1;
        LOGI("audio pipeline started (48000/2ch, %{public}s)", aac_ok ? "aac+g711" : "g711 only");
    } while (0);
    if (!g_audio_ok) {
        audio_teardown();
    }
    napi_value r;
    napi_create_int32(env, g_audio_ok ? (g_aenc != NULL ? 2 : 1) : 0, &r);
    return r;
}

static napi_value native_stop_audio(napi_env env, napi_callback_info info)
{
    (void)info;
    audio_teardown();
    if (g_audio_tsfn != NULL) {
        napi_release_threadsafe_function(g_audio_tsfn, napi_tsfn_release);
        g_audio_tsfn = NULL;
    }
    LOGI("audio pipeline stopped");
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/* ---------- napi wrappers ---------- */
static napi_value native_create_capture(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    int32_t cam = 0, rot = 0;
    if (argc >= 2) {
        napi_get_value_int32(env, argv[0], &cam);
        napi_get_value_int32(env, argv[1], &rot);
    }
    if (find_cam(cam) != NULL) {
        napi_throw_error(env, NULL, "capture already created");
        return NULL;
    }
    cam_ctx_t *c = (cam_ctx_t *)calloc(1, sizeof(cam_ctx_t));
    if (c == NULL) {
        napi_throw_error(env, NULL, "oom");
        return NULL;
    }
    c->cam = cam;
    c->rotate = rot;
    pthread_mutex_init(&c->snap_lock, NULL);
    pthread_mutex_init(&c->iq_lock, NULL);
    OH_NativeImage *cap = OH_NativeImage_Create(0, 0);
    if (cap == NULL) {
        free(c);
        napi_throw_error(env, NULL, "create native image failed");
        return NULL;
    }
    /* CPU 读取 usage:默认 GPU 纹理 usage 无法 MapPlanes */
    uint64_t usage = (1ULL << 0) | (1ULL << 16); /* CPU_READ | CPU_READ_OFTEN */
    OH_ConsumerSurface_SetDefaultUsage(cap, usage);
    OH_OnFrameAvailableListener listener = { .context = c, .onFrameAvailable = on_frame_available };
    if (OH_NativeImage_SetOnFrameAvailableListener(cap, listener) != 0) {
        OH_NativeImage_Destroy(&cap);
        free(c);
        napi_throw_error(env, NULL, "set frame listener failed");
        return NULL;
    }
    uint64_t sid = 0;
    if (OH_NativeImage_GetSurfaceId(cap, &sid) != 0 || sid == 0) {
        OH_NativeImage_Destroy(&cap);
        free(c);
        napi_throw_error(env, NULL, "get capture surface id failed");
        return NULL;
    }
    c->cap = cap;
    g_cams[cam] = c;
    LOGI("cam%{public}d capture created rot=%{public}d", cam, rot);
    char sidbuf[32];
    snprintf(sidbuf, sizeof(sidbuf), "%llu", (unsigned long long)sid);
    napi_value result;
    napi_create_string_utf8(env, sidbuf, NAPI_AUTO_LENGTH, &result);
    return result;
}

/** 实际相机 preview 尺寸(session 配置前调用);分配旋转/快照缓冲。 */
static napi_value native_set_camera_format(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    int32_t cam = 0, w = 0, hh = 0, rot = 0;
    if (argc >= 4) {
        napi_get_value_int32(env, argv[0], &cam);
        napi_get_value_int32(env, argv[1], &w);
        napi_get_value_int32(env, argv[2], &hh);
        napi_get_value_int32(env, argv[3], &rot);
    }
    cam_ctx_t *c = find_cam(cam);
    if (c == NULL) {
        napi_throw_error(env, NULL, "no such capture");
        return NULL;
    }
    c->cam_w = w;
    c->cam_h = hh;
    c->rotate = rot;
    c->plane_dumped = 0;
    int outW = 0, outH = 0;
    rot_out_dims(c, &outW, &outH);
    const size_t srcNeed = (size_t)w * hh * 3 / 2;
    const size_t rotNeed = (size_t)outW * outH * 3 / 2;
    free(c->rot);
    c->rot = (uint8_t *)malloc(rotNeed);
    c->rot_cap = c->rot != NULL ? rotNeed : 0;
    free(c->dst);
    c->dst = (uint8_t *)malloc(srcNeed);
    c->dst_cap = c->dst != NULL ? srcNeed : 0;
    pthread_mutex_lock(&c->snap_lock);
    free(c->snap);
    c->snap = (uint8_t *)malloc(rotNeed);
    c->snap_cap = c->snap != NULL ? rotNeed : 0;
    c->snap_seq = 0;
    pthread_mutex_unlock(&c->snap_lock);
    LOGI("cam%{public}d format %{public}dx%{public}d rot=%{public}d -> out %{public}dx%{public}d",
         cam, w, hh, rot, outW, outH);
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value native_destroy_capture(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    int32_t cam = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &cam);
    }
    cam_ctx_t *c = find_cam(cam);
    if (c == NULL) {
        napi_value result;
        napi_get_undefined(env, &result);
        return result;
    }
    if (c->cap != NULL) {
        OH_NativeImage_Destroy(&c->cap);
    }
    if (c->enc != NULL) {
        OH_VideoEncoder_Stop(c->enc);
        OH_VideoEncoder_Destroy(c->enc);
    }
    free(c->rot);
    free(c->dst);
    free(c->snap);
    pthread_mutex_destroy(&c->snap_lock);
    pthread_mutex_destroy(&c->iq_lock);
    free(c);
    g_cams[cam] = NULL;
    LOGI("cam%{public}d capture destroyed", cam);
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
    size_t argc = 5;
    napi_value argv[5];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    int32_t cam = 0, width = 1280, height = 720, fps = 25, bitrate = 4000000;
    if (argc >= 5) {
        napi_get_value_int32(env, argv[0], &cam);
        napi_get_value_int32(env, argv[1], &width);
        napi_get_value_int32(env, argv[2], &height);
        napi_get_value_int32(env, argv[3], &fps);
        napi_get_value_int32(env, argv[4], &bitrate);
    }
    cam_ctx_t *c = find_cam(cam);
    if (c == NULL) {
        napi_throw_error(env, NULL, "no such capture");
        return NULL;
    }
    if (c->enc != NULL) {
        OH_VideoEncoder_NotifyEndOfStream(c->enc);
        OH_VideoEncoder_Stop(c->enc);
        OH_VideoEncoder_Destroy(c->enc);
        c->enc = NULL;
        usleep(300000);
        pthread_mutex_lock(&c->iq_lock);
        c->iq_head = c->iq_tail = c->iq_count = 0;
        pthread_mutex_unlock(&c->iq_lock);
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
        if (OH_VideoEncoder_RegisterCallback(codec, cb, c) != AV_ERR_OK) {
            OH_VideoEncoder_Destroy(codec);
            napi_throw_error(env, NULL, "register callback failed");
            return NULL;
        }
        c->enc = codec;
    }
    OH_AVCodec *codec = c->enc;

    OH_AVFormat *fmt = OH_AVFormat_CreateVideoFormat("video/avc", width, height);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_FRAME_RATE, fps);
    /* OH_MD_KEY_BITRATE 是 int64 键:必须用 SetLongValue,
     * 否则编码器读不到码率(实测 720p 冲到 14Mbps)。 */
    OH_AVFormat_SetLongValue(fmt, OH_MD_KEY_BITRATE, bitrate);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE, BITRATE_MODE_CBR);
    OH_AVErrCode rc = OH_VideoEncoder_Configure(codec, fmt);
    OH_AVFormat_Destroy(fmt);
    if (rc != AV_ERR_OK) {
        char m[48];
        snprintf(m, sizeof(m), "configure failed rc=%d", rc);
        OH_VideoEncoder_Destroy(codec);
        c->enc = NULL;
        napi_throw_error(env, NULL, m);
        return NULL;
    }

    if (OH_VideoEncoder_Start(codec) != AV_ERR_OK) {
        OH_VideoEncoder_Destroy(codec);
        c->enc = NULL;
        napi_throw_error(env, NULL, "start encoder failed");
        return NULL;
    }
    /* 注意:此处不可清空输入队列。Start 后 codec 立即投递 need-input 缓冲,
     * 清空会"泄漏"已投递缓冲(codec 视为未归还,不再继续投递),实测导致
     * 该路编码器永久饿死(cam1 need-input 停止、pushed=0)。
     * 重建编码器路径的队列清理已在上方销毁分支完成。 */
    c->out_frames = 0;
    c->in_frames = 0;
    c->push_ok = 0;
    c->need_calls = 0;
    c->push_enter = 0;
    LOGI("cam%{public}d encoder started %{public}dx%{public}d@%{public}d br=%{public}d",
         cam, width, height, fps, bitrate);

    napi_value result;
    napi_create_int32(env, 1, &result);
    return result;
}

static napi_value native_stop(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    int32_t cam = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &cam);
    }
    cam_ctx_t *c = find_cam(cam);
    if (c != NULL && c->enc != NULL) {
        OH_VideoEncoder_NotifyEndOfStream(c->enc);
        OH_VideoEncoder_Stop(c->enc);
        OH_VideoEncoder_Destroy(c->enc);
        c->enc = NULL;
        LOGI("cam%{public}d encoder stopped, frames=%{public}d", cam, c->out_frames);
    }
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static int snap_dims_of(cam_ctx_t *c, int *w, int *h)
{
    int ok = 0;
    pthread_mutex_lock(&c->snap_lock);
    if (c->snap_seq > 0 && c->snap != NULL) {
        rot_out_dims(c, w, h);
        ok = 1;
    }
    pthread_mutex_unlock(&c->snap_lock);
    if (!ok) {
        LOGE("cam%{public}d snapshot not ready: seq=%{public}d snap=%{public}d w=%{public}d h=%{public}d rot=%{public}d",
             c->cam, c->snap_seq, c->snap != NULL ? 1 : 0, c->cam_w, c->cam_h, c->rotate);
    }
    return ok;
}

static napi_value native_snapshot_width(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    int32_t cam = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &cam);
    }
    int w = 0, h = 0;
    cam_ctx_t *c = find_cam(cam);
    if (c != NULL) {
        (void)snap_dims_of(c, &w, &h);
    }
    napi_value result;
    napi_create_int32(env, w, &result);
    return result;
}

static napi_value native_snapshot_height(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    int32_t cam = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &cam);
    }
    int w = 0, h = 0;
    cam_ctx_t *c = find_cam(cam);
    if (c != NULL) {
        (void)snap_dims_of(c, &w, &h);
    }
    napi_value result;
    napi_create_int32(env, h, &result);
    return result;
}

static napi_value native_take_snapshot_rgba(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    int32_t cam = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &cam);
    }
    napi_value result;
    cam_ctx_t *c = find_cam(cam);
    int w = 0, h = 0;
    if (c == NULL || !snap_dims_of(c, &w, &h)) {
        napi_get_null(env, &result);
        return result;
    }
    const size_t need = (size_t)w * h * 4;
    if (g_rgba == NULL || g_rgba_cap < need) {
        free(g_rgba);
        g_rgba = (uint8_t *)malloc(need);
        g_rgba_cap = g_rgba != NULL ? need : 0;
    }
    if (g_rgba == NULL) {
        napi_get_null(env, &result);
        return result;
    }
    pthread_mutex_lock(&c->snap_lock);
    nv12_to_rgba(c->snap, w, h, g_rgba);
    pthread_mutex_unlock(&c->snap_lock);
    void *data = NULL;
    napi_value ab = NULL;
    if (napi_create_arraybuffer(env, need, &data, &ab) == napi_ok && data != NULL) {
        memcpy(data, g_rgba, need);
        return ab;
    }
    napi_get_null(env, &result);
    return result;
}

EXTERN_C_START
static napi_value init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"createCapture", NULL, native_create_capture, NULL, NULL, NULL, napi_default, NULL},
        {"setCameraFormat", NULL, native_set_camera_format, NULL, NULL, NULL, napi_default, NULL},
        {"destroyCapture", NULL, native_destroy_capture, NULL, NULL, NULL, napi_default, NULL},
        {"setCallback", NULL, native_set_callback, NULL, NULL, NULL, napi_default, NULL},
        {"start", NULL, native_start, NULL, NULL, NULL, napi_default, NULL},
        {"stop", NULL, native_stop, NULL, NULL, NULL, napi_default, NULL},
        {"snapshotWidth", NULL, native_snapshot_width, NULL, NULL, NULL, napi_default, NULL},
        {"snapshotHeight", NULL, native_snapshot_height, NULL, NULL, NULL, napi_default, NULL},
        {"takeSnapshotRgba", NULL, native_take_snapshot_rgba, NULL, NULL, NULL, napi_default, NULL},
        {"setAudioCallback", NULL, native_set_audio_callback, NULL, NULL, NULL, napi_default, NULL},
        {"startAudio", NULL, native_start_audio, NULL, NULL, NULL, napi_default, NULL},
        {"stopAudio", NULL, native_stop_audio, NULL, NULL, NULL, napi_default, NULL},
        {"startSpeaker", NULL, native_start_speaker, NULL, NULL, NULL, napi_default, NULL},
        {"stopSpeaker", NULL, native_stop_speaker, NULL, NULL, NULL, napi_default, NULL},
        {"speakerWritePCMA", NULL, native_speaker_write_pcma, NULL, NULL, NULL, napi_default, NULL},
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
