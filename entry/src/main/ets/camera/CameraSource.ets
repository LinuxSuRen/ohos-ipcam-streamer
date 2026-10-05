import { camera } from '@kit.CameraKit';
import hilog from '@ohos.hilog';
import common from '@ohos.app.ability.common';

const DOMAIN = 0x0803;
const TAG = 'ipcam.CameraSource';
const FORMAT_YUV = 1000; /* ImageFormat.YCBCR_422_SP,实际格式由相机 HAL 决定 */

export interface ActiveProfile {
  width: number;
  height: number;
  minFps: number;
  maxFps: number;
}

export interface CameraOption {
  index: number;
  label: string;
  orientation: number;
}

/**
 * 内置摄像头采集:PreviewOutput → ImageReceiver,输出紧凑 NV12 帧。
 * (不再使用 VideoOutput 直连编码 surface:旋转需在编码前拿到 YUV。)
 */
export class CameraSource {
  private static session: camera.Session | null = null;
  private static input: camera.CameraInput | null = null;
  private static preview: camera.PreviewOutput | null = null;
  private static activeProfile: ActiveProfile | null = null;
  private static activeIndex = -1;

  static getProfile(): ActiveProfile | null {
    return CameraSource.activeProfile;
  }

  static getActiveIndex(): number {
    return CameraSource.activeIndex;
  }

  /** 枚举可选拿头(用于 UI 选择),label 含位置提示。 */
  static getDevices(context: common.Context): CameraOption[] {
    try {
      const manager = camera.getCameraManager(context);
      const cams = manager.getSupportedCameras();
      const out: CameraOption[] = [];
      let backCount = 0;
      let frontCount = 0;
      let otherCount = 0;
      for (let i = 0; i < cams.length; i++) {
        const c = cams[i];
        let pos = '';
        if (c.cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK) {
          backCount++;
          pos = backCount > 1 ? `后置${backCount}` : '后置';
        } else if (c.cameraPosition === camera.CameraPosition.CAMERA_POSITION_FRONT) {
          frontCount++;
          pos = frontCount > 1 ? `前置${frontCount}` : '前置';
        } else {
          otherCount++;
          pos = `其他${otherCount}`;
        }
        out.push({
          index: i,
          label: `${pos}`,
          orientation: c.cameraOrientation
        });
      }
      return out;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getDevices failed: %{public}s', JSON.stringify(e));
      return [];
    }
  }

  /**
   * 启动指定摄像头(deviceIndex=-1 自动选后置)。
   * 每帧以紧凑 NV12 交给 yuvListener(已去 stride)。
   */
  static async start(context: common.Context,
                     surfaceId: string,
                     wantW: number, wantH: number,
                     deviceIndex: number): Promise<ActiveProfile> {
    if (CameraSource.session !== null) {
      return CameraSource.activeProfile!;
    }
    const manager = camera.getCameraManager(context);
    const cams = manager.getSupportedCameras();
    let device: camera.CameraDevice | undefined = undefined;
    if (deviceIndex >= 0 && deviceIndex < cams.length) {
      device = cams[deviceIndex];
    }
    if (device === undefined) {
      for (const c of cams) {
        if (c.cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK) {
          device = c;
          break;
        }
      }
    }
    if (device === undefined && cams.length > 0) {
      device = cams[0];
      hilog.warn(DOMAIN, TAG, 'back camera not found, fallback to first');
    }
    if (device === undefined) {
      throw new Error('no camera device');
    }
    CameraSource.activeIndex = cams.indexOf(device);

    const caps = manager.getSupportedOutputCapability(device);
    const profile = CameraSource.pickProfile(caps.previewProfiles, wantW, wantH);
    if (profile === null) {
      throw new Error('no preview profile');
    }
    hilog.info(DOMAIN, TAG, 'preview profile %{public}d x %{public}d',
               profile.size.width, profile.size.height);
    const width = profile.size.width;
    const height = profile.size.height;

    const input = manager.createCameraInput(device);
    await input.open();

    const session: camera.Session =
      manager.createSession(camera.SceneMode.NORMAL_PHOTO) as camera.Session;
    session.beginConfig();
    session.addInput(input);
    const preview = manager.createPreviewOutput(profile, surfaceId);
    session.addOutput(preview);
    await session.commitConfig();
    await session.start();

    CameraSource.session = session;
    CameraSource.input = input;
    CameraSource.preview = preview;
    CameraSource.activeProfile = {
      width: width,
      height: height,
      minFps: 0,
      maxFps: 0,
    };
    hilog.info(DOMAIN, TAG, 'camera started (device %{public}d)', CameraSource.activeIndex);
    return CameraSource.activeProfile;
  }

  static async stop(): Promise<void> {
    if (CameraSource.session !== null) {
      try {
        await CameraSource.session.stop();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'session stop');
      }
      try {
        CameraSource.session.release();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'session release');
      }
      CameraSource.session = null;
    }
    if (CameraSource.preview !== null) {
      try {
        CameraSource.preview.release();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'preview release');
      }
      CameraSource.preview = null;
    }
    if (CameraSource.input !== null) {
      try {
        CameraSource.input.close();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'input close');
      }
      CameraSource.input = null;
    }
    CameraSource.activeProfile = null;
    CameraSource.activeIndex = -1;
    hilog.info(DOMAIN, TAG, 'camera stopped');
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
