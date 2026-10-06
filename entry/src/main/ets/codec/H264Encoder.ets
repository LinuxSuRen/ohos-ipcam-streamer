import { setCallback, start, stop, createCapture, setCameraFormat, destroyCapture } from 'libh264enc.so';
import hilog from '@ohos.hilog';

const DOMAIN = 0x0802;
const TAG = 'ipcam.H264Encoder';

export interface EncodedFrame {
  data: ArrayBuffer;
  keyframe: boolean;
  cam: number;
}

type FrameListener = (f: EncodedFrame) => void;

let listener: FrameListener | null = null;

/**
 * H.264 硬编封装(buffer 输入模式,多摄像头多实例):
 * ArkTS 注册回调 ← C 层(de-stride+旋转+编码)逐帧回调,帧带相机编号。
 * outW/outH 必须与旋转+32对齐裁剪后的尺寸一致。
 */
export class H264Encoder {
  static setListener(cb: FrameListener): void {
    listener = cb;
    setCallback((data: ArrayBuffer, keyframe: boolean, cam: number) => {
      if (listener !== null) {
        listener({ data: data, keyframe: keyframe, cam: cam });
      }
    });
  }

  /** 旋转后的编码输出尺寸(与 C 层 rot_out_dims 一致:宽度 32 对齐)。 */
  static outDims(srcW: number, srcH: number, rotateDeg: number): number[] {
    if (rotateDeg === 90 || rotateDeg === 270) {
      return [srcH & ~31, srcW];
    }
    return [srcW & ~31, srcH];
  }

  /** 创建 native 采集 surface:相机 PreviewOutput 直连,帧在 C 层处理。 */
  static createCapture(cam: number, rotateDeg: number): string {
    return createCapture(cam, rotateDeg);
  }

  /** 相机实际 preview 尺寸(session 启动前告知 C 层,分配缓冲)。 */
  static setCameraFormat(cam: number, w: number, h: number, rotateDeg: number): void {
    setCameraFormat(cam, w, h, rotateDeg);
  }

  static destroyCapture(cam: number): void {
    destroyCapture(cam);
  }

  /** 启动指定相机的编码器。 */
  static startEncoder(cam: number, outW: number, outH: number, fps: number, bitrate: number): boolean {
    start(cam, outW, outH, fps, bitrate);
    hilog.info(DOMAIN, TAG, 'cam%{public}d encoder started', cam);
    return true;
  }

  static stopEncoder(cam: number): void {
    stop(cam);
    hilog.info(DOMAIN, TAG, 'cam%{public}d encoder stopped', cam);
  }
}
