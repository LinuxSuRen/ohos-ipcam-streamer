import { CameraSource, ActiveProfile, CameraOption } from '../camera/CameraSource';
import { OrientationSensor } from '../camera/OrientationSensor';
import { H264Encoder } from '../codec/H264Encoder';
import { FrameHub, FrameSink } from '../net/FrameHub';
import { RtspServer } from '../rtsp/RtspServer';
import { OnvifServer } from '../onvif/OnvifServer';
import { BackgroundKeeper } from '../background/BackgroundKeeper';
import { getAbilityContext, isCameraGranted } from '../entryability/GlobalContext';
import { loadSettings, saveSettings } from '../entryability/PersistStore';
import { refreshLanAddress } from '../net/NetUtil';
import hilog from '@ohos.hilog';

const DOMAIN = 0x0805;
const TAG = 'ipcam.Index';
const WANT_WIDTH = 1280;
const WANT_HEIGHT = 720;
const WANT_FPS = 25;
const WANT_BITRATE = 2000000;

class RtspSink implements FrameSink {
  onFrame(f: ArrayBuffer, k: boolean): void {
    RtspServer.broadcast(f, k);
  }
}

const rtspSink: RtspSink = new RtspSink();

const ROTATE_OPTIONS: number[] = [0, 90, 180, 270];

function rotateLabel(deg: number): string {
  if (deg === 0) {
    return '横向';
  }
  if (deg === 90) {
    return '竖向';
  }
  if (deg === 180) {
    return '倒横';
  }
  return '倒竖';
}

@Entry
@Component
struct Index {
  @State running: boolean = false;
  @State status: string = 'idle';
  @State stats: string = '';
  @State profileText: string = '';
  @State rtspUrl: string = '';
  @State onvifUrl: string = '';
  @State cameras: CameraOption[] = [];
  @State suggestDeg: number = -1;
  private timerId: number = -1;
  private curRotate: number = 0;
  private curCam: number = -1;

  aboutToAppear(): void {
    const st = loadSettings(getAbilityContext()!);
    this.curRotate = st.rotate;
    this.curCam = st.cam;
    this.cameras = CameraSource.getDevices(getAbilityContext()!);
    OrientationSensor.start((deg: number) => {
      this.suggestDeg = deg;
    });
    /* 切换后的重开:自动恢复推流 */
    if (st.autoStart && isCameraGranted()) {
      hilog.info(DOMAIN, TAG, 'auto resume streaming');
      this.doStart();
    }
  }

  /** 当前 rotate 下的输出宽高(90/270 交换)。 */
  private outSize(): number[] {
    if (this.curRotate === 90 || this.curRotate === 270) {
      return [WANT_HEIGHT, WANT_WIDTH];
    }
    return [WANT_WIDTH, WANT_HEIGHT];
  }

  private async restartIfNeeded(): Promise<void> {
    if (!this.running) {
      return;
    }
    await this.doStop();
    await new Promise<void>((res) => {
      setTimeout(() => {
        res();
      }, 800); /* 相机 HAL 释放时序 */
    });
    await this.doStart();
  }

  private async switchCamera(idx: number): Promise<void> {
    if (!this.running || idx === this.curCam) {
      return;
    }
    try {
      saveSettings(getAbilityContext()!, {
        rotate: this.curRotate,
        cam: idx,
        autoStart: true
      });
      await getAbilityContext()!.terminateSelf();
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      this.status = `切换失败: ${msg}`;
    }
  }

  /**
   * 方向切换:该系统 HCODEC 不支持进程内二次配置编码器
   * (第二实例 need-input 永不回调,实测),因此:保存配置 → 退出应用,
   * 用户重新打开后按新方向自动恢复推流。
   */
  private async switchRotate(deg: number): Promise<void> {
    if (!this.running || deg === this.curRotate) {
      return;
    }
    try {
      saveSettings(getAbilityContext()!, {
        rotate: deg,
        cam: this.curCam,
        autoStart: true
      });
      await getAbilityContext()!.terminateSelf();
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      this.status = `切换失败: ${msg}`;
    }
  }

  private async doStart(): Promise<void> {
    if (this.running) {
      return;
    }
    if (!isCameraGranted()) {
      this.status = '相机权限未授予,请到系统设置开启后重试';
      return;
    }
    try {
      await refreshLanAddress();
      H264Encoder.setListener((f) => {
        FrameHub.publish(f.data, f.keyframe);
      });
      FrameHub.addSink(rtspSink);
      FrameHub.reset();

      const out: number[] = this.outSize();
      this.status = '启动采集面';
      const surfaceId = H264Encoder.createCaptureSurface(WANT_WIDTH, WANT_HEIGHT, this.curRotate);
      this.status = `启动编码器 ${out[0]}x${out[1]}(${this.curRotate}°)`;
      H264Encoder.startEncoder(out[0], out[1], WANT_FPS, WANT_BITRATE);

      this.status = '启动 RTSP / ONVIF';
      await RtspServer.start(WANT_FPS);
      await OnvifServer.start();

      this.status = '启动相机';
      const p: ActiveProfile = await CameraSource.start(getAbilityContext()!, surfaceId,
        WANT_WIDTH, WANT_HEIGHT, this.curCam);
      this.profileText = `${out[0]}x${out[1]}(${this.curRotate}°)`;

      await BackgroundKeeper.start(getAbilityContext()!);

      const ip = await refreshLanAddress();
      this.rtspUrl = ip !== '' ? `rtsp://${ip}:8554/cam` : 'rtsp://<本机IP>:8554/cam';
      this.onvifUrl = ip !== '' ? `http://${ip}:8000/onvif/device_service` : '';
      this.running = true;
      this.status = '推流中';
      saveSettings(getAbilityContext()!, {
        rotate: this.curRotate,
        cam: this.curCam,
        autoStart: false
      });
      this.timerId = setInterval(() => {
        this.stats = `${FrameHub.stats()} 客户端=${RtspServer.sessionCount()}`;
      }, 1000);
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'start failed: %{public}s', msg);
      this.status = `启动失败: ${msg}`;
      await this.cleanup();
    }
  }

  private async cleanup(): Promise<void> {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    try {
      await CameraSource.stop();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'camera stop');
    }
    H264Encoder.stopEncoder();
    H264Encoder.destroyCaptureSurface();
    FrameHub.removeSink(rtspSink);
    FrameHub.endDump();
    await RtspServer.stop();
    await OnvifServer.stop();
    await BackgroundKeeper.stop(getAbilityContext()!);
  }

  private async doStop(): Promise<void> {
    if (!this.running) {
      return;
    }
    await this.cleanup();
    this.running = false;
    this.status = '已停止';
  }

  build() {
    Column({ space: 14 }) {
      Text('手机IP摄像头')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor('#E6E6E6')
        .margin({ top: 36 })

      Column({ space: 6 }) {
        Text(`状态: ${this.status}`).fontSize(14).fontColor('#E6E6E6')
        if (this.profileText !== '') {
          Text(`输出: ${this.profileText}`).fontSize(14).fontColor('#E6E6E6')
        }
        if (this.stats !== '') {
          Text(this.stats).fontSize(14).fontColor('#E6E6E6')
        }
        if (this.rtspUrl !== '') {
          Text(this.rtspUrl).fontSize(13).fontColor('#7EB8FF')
        }
        if (this.running && this.suggestDeg >= 0 && this.suggestDeg !== this.curRotate) {
          Text(`检测到手机${rotateLabel(this.suggestDeg)},建议点「${rotateLabel(this.suggestDeg)}」切换`)
            .fontSize(13).fontColor('#FFB86C')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(12)

      if (this.running) {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
          ForEach(ROTATE_OPTIONS, (deg: number) => {
            Text(rotateLabel(deg))
              .fontSize(13)
              .fontColor(this.curRotate === deg ? '#0B1220' : '#7EB8FF')
              .backgroundColor(this.curRotate === deg ? '#7EB8FF' : '#1A2940')
              .borderRadius(14)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .margin(4)
              .onClick(() => {
                this.switchRotate(deg);
              })
          }, (deg: number) => deg.toString())
          ForEach(this.cameras, (c: CameraOption) => {
            Text(c.label)
              .fontSize(13)
              .fontColor(this.curCam === c.index ? '#0B1220' : '#9FD8A0')
              .backgroundColor(this.curCam === c.index ? '#9FD8A0' : '#1A2940')
              .borderRadius(14)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .margin(4)
              .onClick(() => {
                this.switchCamera(c.index);
              })
          }, (c: CameraOption) => c.index.toString())
        }
        .width('100%')
      }

      Button(this.running ? '停止' : '开始推流')
        .width(200)
        .fontSize(18)
        .onClick(() => {
          if (this.running) {
            this.doStop();
          } else {
            this.doStart();
          }
        })

      Column({ space: 4 }) {
        Text('同一局域网内可接入:').fontSize(13).fontColor('#AAAAAA')
        Text('VLC / ffmpeg: rtsp://手机IP:8554/cam').fontSize(12).fontColor('#888888')
        Text('NVR / Frigate: 通过 ONVIF 自动发现添加').fontSize(12).fontColor('#888888')
        Text('熄屏与后台运行可持续推流(常驻通知)').fontSize(12).fontColor('#888888')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B1220')
  }
}
