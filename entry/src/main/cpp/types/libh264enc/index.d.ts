/**
 * libh264enc.so 类型声明(实现见 src/main/cpp/h264enc.c)。
 * 多摄像头实例:cam 为相机编号(设备枚举序)。
 * 每路管线:相机 Preview 直连 native 采集面 → C 层 de-stride + 旋转
 * (输出宽度 32 对齐)→ OH_VideoEncoder 硬编。
 */
export const createCapture: (cam: number, rotateDeg: number) => string;
export const setCameraFormat: (cam: number, w: number, h: number, rotateDeg: number) => void;
export const destroyCapture: (cam: number) => void;
export const setCallback: (cb: (frame: ArrayBuffer, keyframe: boolean, cam: number) => void) => void;
export const start: (cam: number, outWidth: number, outHeight: number, fps: number, bitrate: number) => number;
export const stop: (cam: number) => void;
/** 指定相机最新旋转后帧的宽;尚无帧时返回 0 */
export const snapshotWidth: (cam: number) => number;
/** 指定相机最新旋转后帧的高;尚无帧时返回 0 */
export const snapshotHeight: (cam: number) => number;
/** 取指定相机最新旋转后帧的 RGBA 像素(按需 NV12→RGBA);尚无帧时返回 null */
export const takeSnapshotRgba: (cam: number) => ArrayBuffer | null;
/** 注册音频帧回调:type 0 = AAC 裸帧(48kHz,每 AU 1024 样本),1 = G.711 PCMA 帧(160 字节 = 20ms) */
export const setAudioCallback: (cb: (frame: ArrayBuffer, type: number) => void) => void;
/** 启动麦克风采集(48k)+ AAC + G.711 编码;返回 0=失败 1=仅G.711 2=AAC+G.711 */
export const startAudio: () => number;
/** 停止音频管线 */
export const stopAudio: () => void;
