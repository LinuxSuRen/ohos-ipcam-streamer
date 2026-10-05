import { setCallback, start, stop, createCaptureSurface, destroyCaptureSurface } from 'libh264enc.so';
import hilog from '@ohos.hilog';

const DOMAIN = 0x0802;
const TAG = 'ipcam.H264Encoder';

export interface EncodedFrame {
  data: ArrayBuffer;
  keyframe: boolean;
}

type FrameListener = (f: EncodedFrame) => void;

let listener: FrameListener | null = null;

/**
 * H.264 硬编封装(buffer 输入模式):
 * ArkTS 推 NV12 帧 → C 层旋转(0/90/180/270)→ 编码 → 回调 Annex-B NALU。
 * start 的宽高为输出(旋转后)尺寸;90°/270° 时输出宽高对调。
 */
export class H264Encoder {
  static setListener(cb: FrameListener): void {
    listener = cb;
    setCallback((data: ArrayBuffer, keyframe: boolean) => {
      if (listener !== null) {
        listener({ data: data, keyframe: keyframe });
      }
    });
  }

  /** 启动编码器。outW/outH 必须与 rotate 后的帧尺寸一致。 */
  static startEncoder(outW: number, outH: number, fps: number, bitrate: number): boolean {
    start(outW, outH, fps, bitrate);
    hilog.info(DOMAIN, TAG, 'encoder started (buffer mode)');
    return true;
  }

  /**
   * 创建 native 采集 surface:相机 PreviewOutput 直连,
   * 帧在 C 层完成 de-stride + 旋转 + 编码,不经 ArkTS。
   */
  static createCaptureSurface(w: number, h: number, rotateDeg: number): string {
    return createCaptureSurface(w, h, rotateDeg);
  }

  static destroyCaptureSurface(): void {
    destroyCaptureSurface();
  }

  static stopEncoder(): void {
    stop();
    listener = null;
    hilog.info(DOMAIN, TAG, 'encoder stopped');
  }
}
