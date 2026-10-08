import { camera } from '@kit.CameraKit';
import hilog from '@ohos.hilog';
import common from '@ohos.app.ability.common';
import { H264Encoder } from '../codec/H264Encoder';

const DOMAIN = 0x0803;
const TAG = 'ipcam.CameraSource';

/** 一路相机管线:native 采集面 + 常驻编码器实例 + (打开成功的)采集会话。 */
export interface CamPipeline {
  index: number;
  label: string;
  surfaceId: string;
  profileW: number;
  profileH: number;
  outW: number;
  outH: number;
}

interface CamRuntime {
  index: number;
  input: camera.CameraInput;
  session: camera.Session;
  preview: camera.PreviewOutput;
}

/**
 * 多摄像头采集(参照 tv-uvc-streamer 多摄像头思路):
 * - 枚举全部相机,每路创建采集面与常驻编码器实例(互不重配)
 * - 尽量并发打开全部相机(按系统并发能力类型);单路打开失败自动跳过,
 *   全部失败才算失败——并发能力不足的设备自然退化为单路
 * - 单活动相机机型不做客户端触发的切换(切换会互相打断,体验更差)
 */
export class CameraSource {
  private static pipelines: CamPipeline[] = [];
  private static runtimes: CamRuntime[] = [];
  private static curRotate: number = 0;
  /* 全部相机支持的分辨率档位(去重,"宽x高") */
  private static resOptions: string[] = [];

  /** 上次 prepare 发现的分辨率档位(供 UI 选择)。 */
  static resolutions(): string[] {
    return CameraSource.resOptions;
  }

  static setRotate(deg: number): void {
    CameraSource.curRotate = deg;
  }

  private static labelOf(cams: camera.CameraDevice[], idx: number): string {
    let back = 0;
    let front = 0;
    let other = 0;
    for (let i = 0; i <= idx; i++) {
      const pos = cams[i].cameraPosition;
      if (pos === camera.CameraPosition.CAMERA_POSITION_BACK) {
        back++;
      } else if (pos === camera.CameraPosition.CAMERA_POSITION_FRONT) {
        front++;
      } else {
        other++;
      }
    }
    if (cams[idx].cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK) {
      return back > 1 ? `后置${back}` : '后置';
    }
    if (cams[idx].cameraPosition === camera.CameraPosition.CAMERA_POSITION_FRONT) {
      return front > 1 ? `前置${front}` : '前置';
    }
    return `其他${other}`;
  }

  /**
   * 阶段一:为每颗相机创建 native 采集面并选定 preview profile(不打开相机)。
   */
  static prepare(context: common.Context, rotateDeg: number,
                 wantW: number, wantH: number): CamPipeline[] {
    const manager = camera.getCameraManager(context);
    const cams = manager.getSupportedCameras();
    const out: CamPipeline[] = [];
    const resSet: Set<string> = new Set();
    CameraSource.resOptions = [];
    for (let i = 0; i < cams.length && out.length < 4; i++) {
      try {
        const caps = manager.getSupportedOutputCapability(cams[i]);
        for (const pf of caps.previewProfiles) {
          const r = `${pf.size.width}x${pf.size.height}`;
          if (pf.size.width >= 640 && pf.size.width % 16 === 0 &&
              pf.size.height % 16 === 0 && !resSet.has(r)) {
            resSet.add(r);
          }
        }
        const profile = CameraSource.pickProfile(caps.previewProfiles, wantW, wantH);
        if (profile === null) {
          continue;
        }
        const surfaceId = H264Encoder.createCapture(i, rotateDeg);
        const outDims = H264Encoder.outDims(profile.size.width, profile.size.height, rotateDeg);
        out.push({
          index: i,
          label: CameraSource.labelOf(cams, i),
          surfaceId: surfaceId,
          profileW: profile.size.width,
          profileH: profile.size.height,
          outW: outDims[0],
          outH: outDims[1]
        });
        hilog.info(DOMAIN, TAG, 'prepare cam%{public}d %{public}dx%{public}d %{public}s -> out %{public}dx%{public}d',
          i, profile.size.width, profile.size.height, out[out.length - 1].label, outDims[0], outDims[1]);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'prepare cam%{public}d failed: %{public}s', i, JSON.stringify(e));
      }
    }
    const list: string[] = [];
    for (const r of resSet) {
      list.push(r);
    }
    list.sort((a: string, b: string): number => {
      const pa = parseInt(a.split('x')[0]) * parseInt(a.split('x')[1]);
      const pb = parseInt(b.split('x')[0]) * parseInt(b.split('x')[1]);
      return pb - pa;
    });
    CameraSource.resOptions = list;
    CameraSource.pipelines = out;
    return out;
  }

  /**
   * 阶段二:启动全部编码器实例(常驻)。编码器资源不足的路自动剔除。
   */
  static startEncoders(fps: number, bitrate: number): CamPipeline[] {
    const okList: CamPipeline[] = [];
    for (const p of CameraSource.pipelines) {
      try {
        H264Encoder.setCameraFormat(p.index, p.profileW, p.profileH, CameraSource.curRotate);
        H264Encoder.startEncoder(p.index, p.outW, p.outH, fps, bitrate);
        okList.push(p);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'cam%{public}d encoder start failed, remove: %{public}s',
          p.index, JSON.stringify(e));
        H264Encoder.destroyCapture(p.index);
      }
    }
    CameraSource.pipelines = okList;
    return okList;
  }

  private static pipelineOf(cam: number): CamPipeline | null {
    for (const p of CameraSource.pipelines) {
      if (p.index === cam) {
        return p;
      }
    }
    return null;
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((res) => {
      setTimeout(() => {
        res();
      }, ms);
    });
  }

  /** 相机 HAL 调用超时保护:个别 stop/close 会永不回调,不设超时会卡死状态机。 */
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

  /** 打开指定相机的采集会话;实测偶发 7400103,短暂等待后重试一次即成功。 */
  private static async openCamera(context: common.Context, cam: number,
                                  ctype: camera.CameraConcurrentType | undefined): Promise<CamRuntime> {
    let lastErr: Error = new Error('open failed');
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        return await CameraSource.openCameraOnce(context, cam, ctype);
      } catch (e) {
        lastErr = e instanceof Error ? e : new Error(JSON.stringify(e));
        hilog.warn(DOMAIN, TAG, 'open cam%{public}d attempt%{public}d failed: %{public}s',
          cam, attempt, JSON.stringify(e));
        await CameraSource.delay(300);
      }
    }
    throw lastErr;
  }

  private static async openCameraOnce(context: common.Context, cam: number,
                                      ctype: camera.CameraConcurrentType | undefined): Promise<CamRuntime> {
    const manager = camera.getCameraManager(context);
    const cams = manager.getSupportedCameras();
    const dev = cams[cam];
    const p = CameraSource.pipelineOf(cam);
    if (dev === undefined || p === null) {
      throw new Error(`camera ${cam} not available`);
    }
    const input = manager.createCameraInput(dev);
    if (ctype !== undefined) {
      await CameraSource.withTimeout(input.open(ctype), 5000, 'open');
    } else {
      await CameraSource.withTimeout(input.open(), 5000, 'open');
    }
    const session = manager.createSession(camera.SceneMode.NORMAL_PHOTO) as camera.Session;
    session.beginConfig();
    session.addInput(input);
    const preview = manager.createPreviewOutput(
      CameraSource.profileOf(manager, dev, p), p.surfaceId);
    session.addOutput(preview);
    await CameraSource.withTimeout(session.commitConfig(), 5000, 'commitConfig');
    await CameraSource.withTimeout(session.start(), 5000, 'start');
    const rt: CamRuntime = { index: cam, input: input, session: session, preview: preview };
    hilog.info(DOMAIN, TAG, 'cam%{public}d session started (%{public}s)', cam, p.label);
    return rt;
  }

  private static async closeRuntime(rt: CamRuntime): Promise<void> {
    const i = CameraSource.runtimes.indexOf(rt);
    if (i >= 0) {
      CameraSource.runtimes.splice(i, 1);
    }
    /* 每步都加超时:HAL 个别调用不回调会卡死。深度休眠下 HAL 响应极慢,
     * 超时太短、过早放弃会让设备停在半开状态(7400201 反复失败,
     * 实测仅进程退出才能解除),故给到 8s。 */
    try {
      await CameraSource.withTimeout(rt.session.stop(), 8000, 'session.stop');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'session stop');
    }
    try {
      await CameraSource.withTimeout(rt.session.release(), 8000, 'session.release');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'session release');
    }
    try {
      await CameraSource.withTimeout(rt.preview.release(), 8000, 'preview.release');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'preview release');
    }
    try {
      await CameraSource.withTimeout(rt.input.close(), 8000, 'input.close');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'input close');
    }
    hilog.info(DOMAIN, TAG, 'cam%{public}d session closed', rt.index);
  }

  /**
   * 阶段三:尽量并发打开全部相机。
   * 按系统报告的并发能力类型打开(全部带类型,包括首路——首路独占打开会
   * 导致后续相机 Device conflict);单路失败跳过并回收该路资源;
   * 全部失败抛错。
   */
  static async openAll(context: common.Context): Promise<number[]> {
    const manager = camera.getCameraManager(context);
    const allCams = manager.getSupportedCameras();
    let concurrentTypes: Map<string, camera.CameraConcurrentType> = new Map();
    try {
      const infos = manager.getCameraConcurrentInfos(allCams);
      for (const info of infos) {
        concurrentTypes.set(info.device.cameraId, info.type);
      }
      hilog.info(DOMAIN, TAG, 'concurrent infos=%{public}d', infos.length);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getCameraConcurrentInfos failed: %{public}s', JSON.stringify(e));
    }

    for (const p of CameraSource.pipelines.slice()) {
      const dev = allCams[p.index];
      const ctype = dev !== undefined ? concurrentTypes.get(dev.cameraId) : undefined;
      try {
        const rt = await CameraSource.openCamera(context, p.index, ctype);
        CameraSource.runtimes.push(rt);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'cam%{public}d open failed, drop: %{public}s',
          p.index, JSON.stringify(e));
        /* 该路失败:回收编码器与采集面,从管线中移除 */
        H264Encoder.stopEncoder(p.index);
        H264Encoder.destroyCapture(p.index);
        const i = CameraSource.pipelines.indexOf(p);
        if (i >= 0) {
          CameraSource.pipelines.splice(i, 1);
        }
      }
    }
    if (CameraSource.runtimes.length === 0) {
      throw new Error('no camera session started');
    }
    const started: number[] = [];
    for (const rt of CameraSource.runtimes) {
      started.push(rt.index);
    }
    hilog.info(DOMAIN, TAG, 'streaming cams: %{public}s', JSON.stringify(started));
    return started;
  }

  /** 帧停滞自愈:重开指定相机的会话(熄屏唤醒/HAL 卡死后恢复)。 */
  static async reopen(context: common.Context, cam: number): Promise<void> {
    const old: CamRuntime[] = [];
    for (const rt of CameraSource.runtimes) {
      if (rt.index === cam) {
        old.push(rt);
      }
    }
    const manager = camera.getCameraManager(context);
    const allCams = manager.getSupportedCameras();
    const dev = allCams[cam];
    let ctype: camera.CameraConcurrentType | undefined = undefined;
    try {
      const infos = manager.getCameraConcurrentInfos(allCams);
      for (const info of infos) {
        if (info.device.cameraId === (dev !== undefined ? dev.cameraId : '')) {
          ctype = info.type;
        }
      }
    } catch (e) {
    }
    for (const rt of old) {
      await CameraSource.closeRuntime(rt);
    }
    try {
      const rt = await CameraSource.openCamera(context, cam, ctype);
      CameraSource.runtimes.push(rt);
      hilog.info(DOMAIN, TAG, 'reopened cam%{public}d (stall heal)', cam);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'reopen cam%{public}d failed: %{public}s', cam, JSON.stringify(e));
    }
  }

  private static profileOf(manager: camera.CameraManager, dev: camera.CameraDevice,
                           p: CamPipeline): camera.Profile {
    const caps = manager.getSupportedOutputCapability(dev);
    const profile = CameraSource.pickProfile(caps.previewProfiles, p.profileW, p.profileH);
    if (profile !== null) {
      return profile;
    }
    return { format: 1000, size: { width: p.profileW, height: p.profileH } } as camera.Profile;
  }

  /** 指定相机的变焦倍率范围(不支持变焦时为 [1,1])。 */
  static getZoomRange(cam: number): number[] {
    for (const rt of CameraSource.runtimes) {
      if (rt.index === cam) {
        try {
          const ps = rt.session as camera.PhotoSession;
          const r = ps.getZoomRatioRange();
          if (r !== undefined && r.length === 2 && r[1] >= r[0]) {
            hilog.info(DOMAIN, TAG, 'cam%{public}d zoom range %{public}d-%{public}d/100',
              cam, Math.round(r[0] * 100), Math.round(r[1] * 100));
            return r;
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'cam%{public}d getZoomRange failed', cam);
        }
      }
    }
    return [1, 1];
  }

  /** 设置变焦倍率(钳位到支持范围);返回实际生效值,不支持返回 -1。 */
  static setZoom(cam: number, ratio: number): number {
    for (const rt of CameraSource.runtimes) {
      if (rt.index === cam) {
        try {
          const ps = rt.session as camera.PhotoSession;
          const r = ps.getZoomRatioRange();
          if (r === undefined || r.length !== 2 || r[1] <= r[0]) {
            return -1;
          }
          const v = Math.min(r[1], Math.max(r[0], ratio));
          ps.setZoomRatio(v);
          hilog.info(DOMAIN, TAG, 'cam%{public}d setZoom %{public}d/100 (range %{public}d-%{public}d/100)',
            cam, Math.round(v * 100), Math.round(r[0] * 100), Math.round(r[1] * 100));
          return v;
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'cam%{public}d setZoom failed', cam);
          return -1;
        }
      }
    }
    return -1;
  }

  /** 当前变焦倍率;未知返回 -1。 */
  static getZoom(cam: number): number {
    for (const rt of CameraSource.runtimes) {
      if (rt.index === cam) {
        try {
          return (rt.session as camera.PhotoSession).getZoomRatio();
        } catch (e) {
          return -1;
        }
      }
    }
    return -1;
  }

  static async stop(): Promise<void> {
    for (const rt of CameraSource.runtimes.slice()) {
      await CameraSource.closeRuntime(rt);
    }
    CameraSource.runtimes = [];
    for (const p of CameraSource.pipelines) {
      H264Encoder.stopEncoder(p.index);
      H264Encoder.destroyCapture(p.index);
    }
    CameraSource.pipelines = [];
    hilog.info(DOMAIN, TAG, 'all cameras stopped');
  }

  private static pickProfile(profiles: Array<camera.Profile>,
                             wantW: number, wantH: number): camera.Profile | null {
    if (profiles === undefined || profiles.length === 0) {
      return null;
    }
    let best: camera.Profile | null = null;
    let bestDist = Number.MAX_VALUE;
    for (const p of profiles) {
      const d = Math.abs(p.size.width - wantW) + Math.abs(p.size.height - wantH);
      if (d < bestDist) {
        bestDist = d;
        best = p;
      }
    }
    return best;
  }
}
