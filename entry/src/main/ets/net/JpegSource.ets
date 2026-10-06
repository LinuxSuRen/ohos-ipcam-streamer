import image from '@ohos.multimedia.image';
import hilog from '@ohos.hilog';
import { takeSnapshotRgba, snapshotWidth, snapshotHeight } from 'libh264enc.so';

const DOMAIN = 0x080B;
const TAG = 'ipcam.JpegSource';

interface CamCache {
  lastJpeg: ArrayBuffer | null;
  lastAt: number;
  encodeGen: number;   /* 代际:reset 后旧异步结果作废 */
}

function newCache(): CamCache {
  return { lastJpeg: null, lastAt: 0, encodeGen: 0 };
}

/**
 * 按需把指定相机最新旋转后帧(NV12,C 层缓存)编码为 JPEG。
 * - 每路相机独立缓存:快照与 MJPEG 流共享同一次编码(并发请求合流)
 * - 每次编码带超时保护:个别 createPixelMap/packing 不回调时不能卡死消费者
 * - 无消费者时不做任何编码工作
 */
export class JpegSource {
  private static caches: CamCache[] = [newCache(), newCache(), newCache(), newCache()];

  private static cache(cam: number): CamCache {
    return JpegSource.caches[cam >= 0 && cam < 4 ? cam : 0];
  }

  /** 取一帧 JPEG;age 毫秒内的重复请求直接复用上一次结果。 */
  static async jpeg(cam: number, maxAgeMs: number): Promise<ArrayBuffer> {
    const c = JpegSource.cache(cam);
    const now = Date.now();
    if (c.lastJpeg !== null && now - c.lastAt <= maxAgeMs) {
      return c.lastJpeg;
    }
    const gen = c.encodeGen;
    const data = await JpegSource.encode(cam, gen);
    /* 期间发生过 reset:结果丢弃(调用方按失败处理) */
    if (gen !== c.encodeGen) {
      throw new Error('stale encode result');
    }
    return data;
  }

  private static async encode(cam: number, gen: number): Promise<ArrayBuffer> {
    const c = JpegSource.cache(cam);
    const w = snapshotWidth(cam);
    const h = snapshotHeight(cam);
    if (w <= 0 || h <= 0) {
      throw new Error(`no frame cached yet (w=${w} h=${h})`);
    }
    const rgba = takeSnapshotRgba(cam);
    if (rgba === null) {
      throw new Error('snapshot null');
    }
    const opts: image.InitializationOptions = {
      size: { width: w, height: h },
      srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      pixelFormat: image.PixelMapFormat.RGBA_8888
    };
    let pm: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      pm = await JpegSource.withTimeout(image.createPixelMap(rgba, opts), 8000, 'createPixelMap');
      packer = image.createImagePacker();
      const packOpts: image.PackingOption = {
        format: 'image/jpeg',
        quality: 80
      };
      const data = await JpegSource.withTimeout(packer.packing(pm, packOpts), 8000, 'packing');
      c.lastJpeg = data;
      c.lastAt = Date.now();
      return data;
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.warn(DOMAIN, TAG, 'cam%{public}d encode failed: %{public}s', cam, msg);
      throw new Error(msg);
    } finally {
      try {
        if (pm !== null) {
          pm.release();
        }
      } catch (e) {
      }
      try {
        if (packer !== null) {
          packer.release();
        }
      } catch (e) {
      }
    }
  }

  private static withTimeout<T>(p: Promise<T>, ms: number, tag: string): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error(`${tag} timeout`));
      }, ms);
      p.then((v: T) => {
        clearTimeout(timer);
        resolve(v);
      }).catch((e: Object) => {
        clearTimeout(timer);
        reject(e instanceof Error ? e : new Error(`${tag}: ${JSON.stringify(e)}`));
      });
    });
  }

  static reset(): void {
    for (const c of JpegSource.caches) {
      c.encodeGen++;
      c.lastJpeg = null;
      c.lastAt = 0;
    }
    hilog.info(DOMAIN, TAG, 'reset');
  }
}
