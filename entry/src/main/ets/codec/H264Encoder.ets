import { setCallback, start, stop, createCapture, setCameraFormat, destroyCapture,
  setAudioCallback, startAudio, stopAudio } from 'libh264enc.so';
import hilog from '@ohos.hilog';

const DOMAIN = 0x0802;
const TAG = 'ipcam.H264Encoder';

export interface EncodedFrame {
  data: ArrayBuffer;
  keyframe: boolean;
  cam: number;
}

type FrameListener = (f: EncodedFrame) => void;
type AudioFrameListener = (frame: ArrayBuffer) => void;

let listener: FrameListener | null = null;
let audioListener: AudioFrameListener | null = null;

/**
 * 媒体编码封装(buffer 输入模式,多摄像头多实例 + 可选音频):
 * - 每路相机:ArkTS ← C 层(de-stride+旋转+H264 硬编)逐帧回调,帧带相机编号
 * - 音频:麦克风采集 → AAC-LC 44100/2/64kbps,裸帧回调(每 AU 1024 样本)
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

  /** 注册音频帧回调(AAC 裸帧)。 */
  static setAudioListener(cb: AudioFrameListener): void {
    audioListener = cb;
    setAudioCallback((frame: ArrayBuffer) => {
      if (audioListener !== null) {
        audioListener(frame);
      }
    });
  }

  /** 启动音频管线(麦克风+AAC);失败返回 false,视频不受影响。 */
  static startAudioPipeline(): boolean {
    const ok = startAudio() === 1;
    hilog.info(DOMAIN, TAG, 'audio pipeline %{public}s', ok ? 'started' : 'unavailable');
    return ok;
  }

  static stopAudioPipeline(): void {
    stopAudio();
    hilog.info(DOMAIN, TAG, 'audio pipeline stopped');
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
