import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';
import { setParameterSets, resetParameterSets } from '../rtsp/RtspServer';
import { splitAnnexB } from '../rtsp/RtpPacketizer';

const DOMAIN = 0x0804;
const TAG = 'ipcam.FrameHub';

export interface FrameSink {
  onFrame(frame: ArrayBuffer, keyframe: boolean): void;
}

let fd: number = -1;
let frames = 0;
let keyframes = 0;
let bytes = 0;
let spsRaw: Uint8Array | null = null;
let ppsRaw: Uint8Array | null = null;
let sinks: FrameSink[] = [];

/**
 * 编码帧汇合点:dump(调试)+ 多 sink 分发(RTSP/后续消费者)。
 */
export class FrameHub {
  static addSink(s: FrameSink): void {
    if (sinks.indexOf(s) < 0) {
      sinks.push(s);
    }
  }

  static removeSink(s: FrameSink): void {
    const i = sinks.indexOf(s);
    if (i >= 0) {
      sinks.splice(i, 1);
    }
  }

  static beginDump(path: string): void {
    FrameHub.endDump();
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fd = file.fd;
      hilog.info(DOMAIN, TAG, 'dump to %{public}s fd=%{public}d', path, file.fd);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'open dump failed: %{public}s', JSON.stringify(e));
    }
  }

  static endDump(): void {
    if (fd >= 0) {
      try {
        fs.closeSync(fd);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'close dump');
      }
      fd = -1;
    }
  }

  static publish(frame: ArrayBuffer, keyframe: boolean): void {
    FrameHub.captureParameterSets(frame);
    if (fd >= 0) {
      try {
        fs.writeSync(fd, frame);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'write dump failed');
      }
    }
    for (const s of sinks) {
      s.onFrame(frame, keyframe);
    }
    frames++;
    bytes += frame.byteLength;
    if (keyframe) {
      keyframes++;
    }
  }

  /** 拆出裸 SPS(7)/PPS(8) NALU,喂给 RTSP 的 sprop-parameter-sets。 */
  static captureParameterSets(frame: ArrayBuffer): void {
    if (spsRaw !== null && ppsRaw !== null) {
      return;
    }
    try {
      const nalus = splitAnnexB(new Uint8Array(frame));
      for (const nalu of nalus) {
        const type = nalu[0] & 0x1f;
        if (type === 7 && spsRaw === null) {
          spsRaw = nalu;
          hilog.info(DOMAIN, TAG, 'SPS captured, %{public}d bytes', nalu.length);
        } else if (type === 8 && ppsRaw === null) {
          ppsRaw = nalu;
          hilog.info(DOMAIN, TAG, 'PPS captured, %{public}d bytes', nalu.length);
        }
      }
      setParameterSets(spsRaw, ppsRaw);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'split ps failed');
    }
  }

  static stats(): string {
    const kb = Math.round(bytes / 1024);
    return `frames=${frames} keyframes=${keyframes} size=${kb}KB`;
  }

  static reset(): void {
    frames = 0;
    keyframes = 0;
    bytes = 0;
    spsRaw = null;
    ppsRaw = null;
    resetParameterSets();
  }
}
