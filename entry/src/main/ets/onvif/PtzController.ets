import hilog from '@ohos.hilog';
import { CameraSource } from '../camera/CameraSource';

const DOMAIN = 0x080D;
const TAG = 'ipcam.PtzController';

/**
 * ONVIF PTZ 变焦控制器:把 PTZ 服务的 Zoom 语义映射到相机变焦倍率。
 * - 位置空间 [0,1] ↔ zoomRatio [min,max] 线性映射
 * - ContinuousMove 以 200ms 定时步进模拟速度,Stop/超时即停
 * - Pan/Tilt 手机无可动部件,忽略(应答成功)
 */
export class PtzController {
  private static timers: Map<number, number> = new Map();

  static hasZoom(cam: number): boolean {
    const r = CameraSource.getZoomRange(cam);
    return r[1] > r[0];
  }

  /** 位置空间归一值 [0,1];未知返回 -1。 */
  static position(cam: number): number {
    const range = CameraSource.getZoomRange(cam);
    if (range[1] <= range[0]) {
      return -1;
    }
    const cur = CameraSource.getZoom(cam);
    if (cur < 0) {
      return -1;
    }
    return (cur - range[0]) / (range[1] - range[0]);
  }

  /** 位置空间 [0,1] → zoomRatio 设置。 */
  static absoluteMove(cam: number, x: number): void {
    const range = CameraSource.getZoomRange(cam);
    if (range[1] <= range[0]) {
      return;
    }
    const cx = Math.min(1, Math.max(0, x));
    CameraSource.setZoom(cam, range[0] + cx * (range[1] - range[0]));
  }

  /** 速度空间 [-1,1];每 200ms 步进全范围的 4%×|v|,超时自动停。 */
  static continuousMove(cam: number, velocity: number, timeoutSec: number): void {
    PtzController.stop(cam);
    if (velocity === 0 || !PtzController.hasZoom(cam)) {
      return;
    }
    const range = PtzController.getZoomRatioSafe(cam);
    const step = (range[1] - range[0]) * 0.04 * velocity;
    const id = setInterval(() => {
      const cur = CameraSource.getZoom(cam);
      if (cur < 0) {
        PtzController.stop(cam);
        return;
      }
      const next = Math.min(range[1], Math.max(range[0], cur + step));
      if (next === cur) {
        PtzController.stop(cam);
        return;
      }
      CameraSource.setZoom(cam, next);
    }, 200);
    PtzController.timers.set(cam, id);
    const ms = Math.min(60, Math.max(1, timeoutSec > 0 ? timeoutSec : 5)) * 1000;
    setTimeout(() => {
      PtzController.stop(cam);
    }, ms);
    hilog.info(DOMAIN, TAG, 'cam%{public}d continuousMove v=%{public}f t=%{public}ds', cam, velocity, timeoutSec);
  }

  static stop(cam: number): void {
    const id = PtzController.timers.get(cam);
    if (id !== undefined) {
      clearInterval(id);
      PtzController.timers.delete(cam);
    }
  }

  private static getZoomRatioSafe(cam: number): number[] {
    const r = CameraSource.getZoomRange(cam);
    return r[1] > r[0] ? r : [1, 1];
  }
}
