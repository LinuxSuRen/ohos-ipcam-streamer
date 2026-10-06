import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';
import { setParameterSets, resetParameterSets } from '../rtsp/RtspServer';
import { splitAnnexB } from '../rtsp/RtpPacketizer';

const DOMAIN = 0x0804;
const TAG = 'ipcam.FrameHub';
const MAX_CAMS = 4;

export interface FrameSink {
  onFrame(frame: ArrayBuffer, keyframe: boolean, cam: number): void;
}

let fd: number = -1;
let sinks: FrameSink[] = [];

/* 按相机分路的统计与参数集 */
interface CamStats {
  frames: number;
  keyframes: number;
  bytes: number;
  sps: Uint8Array | null;
  pps: Uint8Array | null;
  fpsCalcAt: number;
  fpsCalcFrames: number;
  fpsVal: number;
}

function newStats(): CamStats {
  return {
    frames: 0, keyframes: 0, bytes: 0, sps: null, pps: null,
    fpsCalcAt: 0, fpsCalcFrames: 0, fpsVal: 0
  };
}

let camStats: CamStats[] = [newStats(), newStats(), newStats(), newStats()];

function st(cam: number): CamStats {
  if (cam < 0 || cam >= MAX_CAMS) {
    return camStats[0];
  }
  return camStats[cam];
}

/**
 * 编码帧汇合点:dump(调试)+ 按 cam 分路分发(RTSP/HTTP 等消费者)。
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

  static publish(frame: ArrayBuffer, keyframe: boolean, cam: number): void {
    FrameHub.captureParameterSets(frame, cam);
    if (fd >= 0) {
      try {
        fs.writeSync(fd, frame);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'write dump failed');
      }
    }
    for (const s of sinks) {
      s.onFrame(frame, keyframe, cam);
    }
    const c = st(cam);
    c.frames++;
    c.bytes += frame.byteLength;
    if (keyframe) {
      c.keyframes++;
    }
  }

  /** 拆出裸 SPS(7)/PPS(8) NALU,喂给对应相机 RTSP 的 sprop-parameter-sets。 */
  static captureParameterSets(frame: ArrayBuffer, cam: number): void {
    const c = st(cam);
    if (c.sps !== null && c.pps !== null) {
      return;
    }
    try {
      const nalus = splitAnnexB(new Uint8Array(frame));
      for (const nalu of nalus) {
        const type = nalu[0] & 0x1f;
        if (type === 7 && c.sps === null) {
          c.sps = nalu;
        } else if (type === 8 && c.pps === null) {
          c.pps = nalu;
        }
      }
      setParameterSets(cam, c.sps, c.pps);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'split ps failed');
    }
  }

  static stats(cam: number): string {
    const c = st(cam);
    const kb = Math.round(c.bytes / 1024);
    return `frames=${c.frames} keyframes=${c.keyframes} size=${kb}KB`;
  }

  static frameCount(cam: number): number {
    return st(cam).frames;
  }

  /** 差分法估算指定相机的编码帧率(秒级调用)。 */
  static fps(cam: number): number {
    const c = st(cam);
    const now = Date.now();
    if (c.fpsCalcAt > 0 && now > c.fpsCalcAt) {
      const f = Math.round((c.frames - c.fpsCalcFrames) * 1000 / (now - c.fpsCalcAt));
      c.fpsCalcAt = now;
      c.fpsCalcFrames = c.frames;
      if (f >= 0) {
        c.fpsVal = f;
      }
    } else {
      c.fpsCalcAt = now;
      c.fpsCalcFrames = c.frames;
    }
    return c.fpsVal;
  }

  static reset(): void {
    camStats = [newStats(), newStats(), newStats(), newStats()];
    resetParameterSets();
  }
}
