import { CameraSource, CamPipeline } from '../camera/CameraSource';
import { OrientationSensor } from '../camera/OrientationSensor';
import { H264Encoder } from '../codec/H264Encoder';
import { FrameHub, FrameSink } from '../net/FrameHub';
import { CamRegistry, CamInfo } from '../net/CamRegistry';
import { JpegSource } from '../net/JpegSource';
import { HttpServer } from '../http/HttpServer';
import { RtspServer } from '../rtsp/RtspServer';
import { OnvifServer } from '../onvif/OnvifServer';
import { BackgroundKeeper } from '../background/BackgroundKeeper';
import { CrashGuard } from '../entryability/CrashGuard';
import { getAbilityContext, isCameraGranted } from '../entryability/GlobalContext';
import { loadSettings, saveSettings } from '../entryability/PersistStore';
import { refreshLanAddress } from '../net/NetUtil';
import hilog from '@ohos.hilog';
const DOMAIN = 0x0805;
const TAG = 'ipcam.Index';
const WANT_WIDTH = 1280;
const WANT_HEIGHT = 720;
const WANT_FPS = 25;
/* 720x1280@30 实测:CBR 2Mbps 时编码器色度被量化清零(画面大面积绿块),
 * 提到 4Mbps 恢复正常;兼顾画质与 WiFi 带宽取 4Mbps。 */
const WANT_BITRATE = 4000000;

class RtspSink implements FrameSink {
  onFrame(f: ArrayBuffer, k: boolean, cam: number): void {
    RtspServer.broadcast(f, k, cam);
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
  @State httpUrl: string = '';
  @State suggestDeg: number = -1;
  @State crashText: string = '';
  private timerId: number = -1;
  private curRotate: number = 0;
  private camInfos: CamInfo[] = [];
  private lastFrames: number[] = [0, 0, 0, 0];
  private lastAdvanceAt: number[] = [0, 0, 0, 0];

  aboutToAppear(): void {
    const st = loadSettings(getAbilityContext()!);
    this.curRotate = st.rotate;
    const crash = CrashGuard.consume(getAbilityContext()!);
    if (crash !== null) {
      this.crashText = crash.split('\n').slice(0, 2).join('\n');
      hilog.warn(DOMAIN, TAG, 'last crash: %{public}s', this.crashText);
    }
    OrientationSensor.start((deg: number) => {
      this.suggestDeg = deg;
    });
    /* 切换方向后的重开:自动恢复推流 */
    if (st.autoStart && isCameraGranted()) {
      hilog.info(DOMAIN, TAG, 'auto resume streaming');
      this.doStart();
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
        cam: -1,
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
        FrameHub.publish(f.data, f.keyframe, f.cam);
      });
      FrameHub.addSink(rtspSink);
      FrameHub.reset();
      JpegSource.reset();
      CameraSource.setRotate(this.curRotate);

      /* 阶段一:全部相机创建采集面并选定 profile(不打开相机) */
      this.status = '准备摄像头';
      this.lastFrames = [0, 0, 0, 0];
      this.lastAdvanceAt = [0, 0, 0, 0];
      const pipelines: CamPipeline[] = CameraSource.prepare(
        getAbilityContext()!, this.curRotate, WANT_WIDTH, WANT_HEIGHT);
      if (pipelines.length === 0) {
        throw new Error('no camera available');
      }

      /* 服务器先行:拉流端可立即连接 */
      this.status = '启动 RTSP / ONVIF / HTTP';
      await RtspServer.start(WANT_FPS);
      await OnvifServer.start(getAbilityContext()!);
      await HttpServer.start();

      /* 阶段二:全部编码器实例常驻启动,再尽量并发打开全部相机 */
      this.status = '启动编码器';
      const encPipelines = CameraSource.startEncoders(WANT_FPS, WANT_BITRATE);
      if (encPipelines.length === 0) {
        throw new Error('no encoder started');
      }
      this.status = '启动相机';
      const started: number[] = await CameraSource.openAll(getAbilityContext()!);

      this.camInfos = [];
      for (const idx of started) {
        const p = encPipelines.find((c) => c.index === idx);
        if (p !== undefined) {
          const info: CamInfo = {
            index: p.index, label: p.label, outW: p.outW, outH: p.outH,
            fps: WANT_FPS, bitrate: WANT_BITRATE
          };
          this.camInfos.push(info);
        }
      }
      CamRegistry.set(this.camInfos);
      this.profileText = this.camInfos.map((c) => `${c.label} ${c.outW}x${c.outH}`).join(' / ');

      await BackgroundKeeper.start(getAbilityContext()!);

      const ip = await refreshLanAddress();
      this.rtspUrl = ip !== '' ? `rtsp://${ip}:8554/cam0 … cam${this.camInfos.length - 1}` : 'rtsp://<本机IP>:8554/camN';
      this.httpUrl = ip !== '' ? `http://${ip}:8090/ (快照/网页)` : '';
      this.running = true;
      this.status = '推流中';
      saveSettings(getAbilityContext()!, {
        rotate: this.curRotate,
        cam: -1,
        autoStart: false
      });
      this.timerId = setInterval(() => {
        const parts = this.camInfos.map((c) => `${c.label}=${FrameHub.fps(c.index)}fps`);
        this.stats = `${parts.join(' ')} RTSP客户端=${RtspServer.sessionCount()}`;
        /* 帧停滞自愈:任一在推相机 6 秒无新帧(熄屏唤醒/HAL 卡死)则重开会话 */
        const now = Date.now();
        for (const c of this.camInfos) {
          const fc = FrameHub.frameCount(c.index);
          if (fc > this.lastFrames[c.index]) {
            this.lastFrames[c.index] = fc;
            this.lastAdvanceAt[c.index] = now;
          } else if (now - this.lastAdvanceAt[c.index] > 6000 && this.lastAdvanceAt[c.index] > 0) {
            this.lastAdvanceAt[c.index] = now;
            hilog.warn(DOMAIN, TAG, 'cam%{public}d frame stall, reopening', c.index);
            CameraSource.reopen(getAbilityContext()!, c.index);
          }
        }
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
    FrameHub.removeSink(rtspSink);
    FrameHub.endDump();
    JpegSource.reset();
    await RtspServer.stop();
    await OnvifServer.stop();
    await HttpServer.stop();
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
          Text(this.stats).fontSize(13).fontColor('#E6E6E6')
        }
        if (this.rtspUrl !== '') {
          Text(this.rtspUrl).fontSize(13).fontColor('#7EB8FF')
        }
        if (this.httpUrl !== '') {
          Text(this.httpUrl).fontSize(13).fontColor('#7EB8FF')
        }
        if (this.crashText !== '') {
          Text(`上次异常:\n${this.crashText}`).fontSize(12).fontColor('#FF6B6B')
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
        Text('VLC / ffmpeg: rtsp://手机IP:8554/camN(每颗摄像头一路)').fontSize(12).fontColor('#888888')
        Text('NVR / Frigate: 通过 ONVIF 自动发现添加(多 Profile)').fontSize(12).fontColor('#888888')
        Text('浏览器: http://手机IP:8090/ 快照与 MJPEG').fontSize(12).fontColor('#888888')
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
