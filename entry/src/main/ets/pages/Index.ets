import { CameraSource, CamPipeline } from '../camera/CameraSource';
import { OrientationSensor } from '../camera/OrientationSensor';
import { H264Encoder } from '../codec/H264Encoder';
import { startSpeaker, stopSpeaker } from 'libh264enc.so';
import { FrameHub, FrameSink } from '../net/FrameHub';
import { CamRegistry, CamInfo } from '../net/CamRegistry';
import { JpegSource } from '../net/JpegSource';
import { HttpServer } from '../http/HttpServer';
import { RtspServer } from '../rtsp/RtspServer';
import { OnvifServer } from '../onvif/OnvifServer';
import { BackgroundKeeper } from '../background/BackgroundKeeper';
import { CrashGuard } from '../entryability/CrashGuard';
import { getAbilityContext, isCameraGranted, isMicGranted, isAppForeground } from '../entryability/GlobalContext';
import { loadSettings, saveSettings, Settings } from '../entryability/PersistStore';
import { AuthConfig } from '../auth/Auth';
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
  @State audioText: string = '';
  @State resolutions: string[] = [];
  @State authEnabled: boolean = false;
  private authUser: string = '';
  private authPass: string = '';
  private curResolution: string = '1280x720';
  private audioOn: boolean = false;
  private timerId: number = -1;
  private curRotate: number = 0;
  private camInfos: CamInfo[] = [];
  private lastFrames: number[] = [0, 0, 0, 0];
  private lastAdvanceAt: number[] = [0, 0, 0, 0];
  private stallCount: number[] = [0, 0, 0, 0];
  private recovering: boolean = false;

  aboutToAppear(): void {
    const st = loadSettings(getAbilityContext()!);
    this.curRotate = st.rotate;
    this.curResolution = st.resolution;
    this.authEnabled = st.authEnabled;
    this.authUser = st.authUser;
    this.authPass = st.authPass;
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

  /** 统一持久化入口:认证字段随所有保存路径一起落盘,避免遗漏。 */
  private persist(autoStart: boolean): void {
    const s: Settings = {
      rotate: this.curRotate,
      cam: -1,
      autoStart: autoStart,
      resolution: this.curResolution,
      authEnabled: this.authEnabled,
      authUser: this.authUser,
      authPass: this.authPass
    };
    saveSettings(getAbilityContext()!, s);
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
      this.persist(true);
      await getAbilityContext()!.terminateSelf();
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      this.status = `切换失败: ${msg}`;
    }
  }

  /** 当前选择分辨率解析出的期望宽高。 */
  private wantDims(): number[] {
    const want = this.curResolution.split('x').map((v: string): number => parseInt(v));
    if (want.length === 2 && want[0] > 0 && want[1] > 0) {
      return want;
    }
    return [WANT_WIDTH, WANT_HEIGHT];
  }

  /** 码率随分辨率面积缩放(720p 基准 4Mbps,上限 8Mbps),防止高分辨率低码率色度劣化。 */
  private wantBitrate(): number {
    const w = this.wantDims()[0];
    const h = this.wantDims()[1];
    return Math.min(8000000, Math.max(WANT_BITRATE,
      Math.round(WANT_BITRATE * w * h / (WANT_WIDTH * WANT_HEIGHT))));
  }

  /**
   * 分辨率切换:与方向切换同一模式(编码器不支持进程内二次配置),
   * 保存配置 → 退出应用,重开后按新分辨率自动恢复推流。
   */
  private async switchResolution(res: string): Promise<void> {
    if (!this.running || res === this.curResolution) {
      return;
    }
    try {
      this.persist(true);
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
    const wantW = this.wantDims()[0];
    const wantH = this.wantDims()[1];
    const bitrate = this.wantBitrate();
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
        getAbilityContext()!, this.curRotate, wantW, wantH);
      this.resolutions = CameraSource.resolutions();
      if (pipelines.length === 0) {
        throw new Error('no camera available');
      }

      /* 服务器先行:拉流端可立即连接;认证凭证注入三服务 */
      this.status = '启动 RTSP / ONVIF / HTTP';
      AuthConfig.configure(this.authEnabled, this.authUser, this.authPass);
      await RtspServer.start(WANT_FPS);
      await OnvifServer.start(getAbilityContext()!);
      await HttpServer.start();

      /* 音频管线(可选):麦克风 → AAC + G.711 双编码,失败仅降级为纯视频 */
      H264Encoder.setAudioListener((frame, type) => {
        if (type === 1) {
          RtspServer.broadcastG711(frame);
        } else {
          RtspServer.broadcastAudio(frame);
        }
      });
      const audioLevel = isMicGranted() ? H264Encoder.startAudioPipeline() : 0;
      /* 对讲回传扬声器(8kHz):随推流开启,回传 RTP 到达即播放 */
      try {
        startSpeaker();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'speaker unavailable');
      }
      const audioOk = audioLevel >= 2;
      RtspServer.setAudioEnabled(audioOk);
      RtspServer.setG711Enabled(audioLevel >= 1);
      this.audioOn = audioLevel >= 1;
      this.audioText = audioLevel >= 2 ? 'AAC 48kHz 立体声 + G.711 + 对讲' :
        (audioLevel === 1 ? 'G.711(AAC 不可用)' :
          (isMicGranted() ? '不可用(启动失败,已降级纯视频)' : '未授权麦克风'));

      /* 阶段二:全部编码器实例常驻启动,再尽量并发打开全部相机 */
      this.status = '启动编码器';
      const encPipelines = CameraSource.startEncoders(WANT_FPS, bitrate);
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
            fps: WANT_FPS, bitrate: bitrate
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
      this.persist(false);
      this.timerId = setInterval(() => {
        const parts = this.camInfos.map((c) => `${c.label}=${FrameHub.fps(c.index)}fps`);
        this.stats = `${parts.join(' ')} RTSP客户端=${RtspServer.sessionCount()}`;
        /* 后台时系统拒绝相机会话(实测),不做无谓重试,避免 7400201 空转
         * 与设备半开状态;回前台后由 foregroundJustNow 立即触发恢复 */
        if (!isAppForeground()) {
          if (this.status === '推流中') {
            this.status = '后台暂停(回前台自动恢复)';
          }
          return;
        }
        if (this.status === '后台暂停(回前台自动恢复)') {
          this.status = '推流中';
          this.recoverCameras();
        }
        /* 帧停滞自愈分级:单次停滞仅重开该路会话;连续 3 次(≈18s)
         * 仍无帧则全量重建相机管线(深度休眠后半开状态仅靠重开无法恢复) */
        const now = Date.now();
        for (const c of this.camInfos) {
          const fc = FrameHub.frameCount(c.index);
          if (fc > this.lastFrames[c.index]) {
            this.lastFrames[c.index] = fc;
            this.lastAdvanceAt[c.index] = now;
            this.stallCount[c.index] = 0;
          } else if (now - this.lastAdvanceAt[c.index] > 6000 && this.lastAdvanceAt[c.index] > 0) {
            this.lastAdvanceAt[c.index] = now;
            this.stallCount[c.index]++;
            if (this.stallCount[c.index] >= 3) {
              this.stallCount[c.index] = 0;
              hilog.warn(DOMAIN, TAG, 'cam%{public}d repeated stall, full camera restart', c.index);
              this.recoverCameras();
            } else {
              hilog.warn(DOMAIN, TAG, 'cam%{public}d frame stall, reopening', c.index);
              CameraSource.reopen(getAbilityContext()!, c.index);
            }
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
    RtspServer.setAudioEnabled(false);
    RtspServer.setG711Enabled(false);
    H264Encoder.stopAudioPipeline();
    try {
      stopSpeaker();
    } catch (e) {
    }
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
    this.audioOn = false;
    this.audioText = '';
    this.status = '已停止';
  }

  /**
   * 全量重建相机管线(采集面+编码器+会话):用于深度休眠后重开无效的场景。
   * 与停止/再启动走同一套调用(实测该路径可多次重复执行)。
   */
  private async recoverCameras(): Promise<void> {
    if (this.recovering || !this.running) {
      return;
    }
    this.recovering = true;
    const prevStatus = this.status;
    this.status = '相机管线恢复中';
    try {
      await CameraSource.stop();
      const prepared = CameraSource.prepare(
        getAbilityContext()!, this.curRotate, this.wantDims()[0], this.wantDims()[1]);
      if (prepared.length === 0) {
        throw new Error('prepare empty');
      }
      const encPipelines = CameraSource.startEncoders(WANT_FPS, this.wantBitrate());
      if (encPipelines.length === 0) {
        throw new Error('no encoder started');
      }
      const started: number[] = await CameraSource.openAll(getAbilityContext()!);
      this.camInfos = [];
      for (const idx of started) {
        const p = encPipelines.find((c) => c.index === idx);
        if (p !== undefined) {
          const info: CamInfo = {
            index: p.index, label: p.label, outW: p.outW, outH: p.outH,
            fps: WANT_FPS, bitrate: this.wantBitrate()
          };
          this.camInfos.push(info);
        }
      }
      CamRegistry.set(this.camInfos);
      this.profileText = this.camInfos.map((c) => `${c.label} ${c.outW}x${c.outH}`).join(' / ');
      this.lastFrames = [0, 0, 0, 0];
      this.lastAdvanceAt = [0, 0, 0, 0];
      this.stallCount = [0, 0, 0, 0];
      this.status = '推流中';
      hilog.info(DOMAIN, TAG, 'camera pipeline recovered');
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'recover failed: %{public}s', msg);
      this.status = `相机恢复失败: ${msg}`;
      /* 下个停滞周期会再次尝试 */
    } finally {
      this.status = this.status === '相机管线恢复中' ? prevStatus : this.status;
      this.recovering = false;
    }
  }

  /**
   * 「关闭」按钮:停止推流、结束长时任务(常驻通知消失)并退出应用。
   * 这是唯一的退出入口;系统返回键只进后台,推流不中断。
   */
  private async doClose(): Promise<void> {
    hilog.info(DOMAIN, TAG, 'user close');
    if (this.running) {
      await this.doStop();
    }
    try {
      await BackgroundKeeper.stop(getAbilityContext()!);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'stop background');
    }
    await getAbilityContext()!.terminateSelf();
  }

  /**
   * 系统返回键:不退出,仅移入后台继续推流(返回 true 拦截默认行为)。
   */
  onBackPress(): boolean {
    hilog.info(DOMAIN, TAG, 'back pressed, move to background');
    try {
      getAbilityContext()!.moveAbilityToBackground();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'moveAbilityToBackground failed: %{public}s', JSON.stringify(e));
    }
    return true;
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
        if (this.running) {
          Text(`音频: ${this.audioOn ? this.audioText : '关'}`)
            .fontSize(13).fontColor(this.audioOn ? '#9FD8A0' : '#888888')
          Text(`认证: ${this.authEnabled ? `开启(${this.authUser})` : '关'}`)
            .fontSize(13).fontColor(this.authEnabled ? '#9FD8A0' : '#888888')
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
          ForEach(this.resolutions, (res: string) => {
            Text(res)
              .fontSize(13)
              .fontColor(this.curResolution === res ? '#0B1220' : '#C9A8FF')
              .backgroundColor(this.curResolution === res ? '#C9A8FF' : '#1A2940')
              .borderRadius(14)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .margin(4)
              .onClick(() => {
                this.switchResolution(res);
              })
          }, (res: string) => res)
        }
        .width('100%')
      }

      if (!this.running) {
        Column({ space: 8 }) {
          Row({ space: 10 }) {
            Toggle({ type: ToggleType.Switch, isOn: this.authEnabled })
              .onChange((on: boolean) => {
                this.authEnabled = on;
              })
            Text('访问认证(RTSP/HTTP/ONVIF 共用一账号)')
              .fontSize(14).fontColor('#E6E6E6')
          }
          if (this.authEnabled) {
            TextInput({ placeholder: '用户名', text: this.authUser })
              .fontSize(14)
              .onChange((v: string) => {
                this.authUser = v;
              })
            TextInput({ placeholder: '密码', text: this.authPass })
              .type(InputType.Password)
              .fontSize(14)
              .onChange((v: string) => {
                this.authPass = v;
              })
            Text('拉流地址形如 rtsp://用户名:密码@手机IP:8554/cam0;口令仅存本机沙箱')
              .fontSize(12).fontColor('#888888')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(12)
      }

      Row({ space: 16 }) {
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
        Button('关闭')
          .width(88)
          .fontSize(16)
          .backgroundColor('#5C2A35')
          .onClick(() => {
            this.doClose();
          })
      }

      Column({ space: 4 }) {
        Text('同一局域网内可接入:').fontSize(13).fontColor('#AAAAAA')
        Text('VLC / ffmpeg: rtsp://手机IP:8554/camN(每颗摄像头一路)').fontSize(12).fontColor('#888888')
        Text('NVR / Frigate: 通过 ONVIF 自动发现添加(多 Profile)').fontSize(12).fontColor('#888888')
        Text('浏览器: http://手机IP:8090/ 快照与 MJPEG').fontSize(12).fontColor('#888888')
        Text('熄屏与后台可持续推流;系统返回=进后台,点「关闭」才退出').fontSize(12).fontColor('#888888')
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
