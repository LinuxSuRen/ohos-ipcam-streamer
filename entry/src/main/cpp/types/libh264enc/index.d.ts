/**
 * libh264enc.so 类型声明(实现见 src/main/cpp/h264enc.c)。
 * buffer 输入模式:ArkTS 推紧凑 NV12 帧,C 层旋转后送编码器。
 */
export const createCaptureSurface: (w: number, h: number, rotateDeg: number) => string;
export const destroyCaptureSurface: () => void;
export const setCallback: (cb: (frame: ArrayBuffer, keyframe: boolean) => void) => void;
export const start: (outWidth: number, outHeight: number, fps: number, bitrate: number) => number;
export const stop: () => void;
