# 手机IP摄像头(ohos-ipcam-streamer)

鸿蒙(HarmonyOS / OpenHarmony)手机内置摄像头转 IP 摄像头网关,姊妹项目 [tv-uvc-streamer](https://github.com/linuxsuren/tv-uvc-streamer)(Android / UVC USB 摄像头)。手机插电即成为局域网内标准网络摄像机,供 NVR / Frigate / OpenCV / ffmpeg / VLC / onvif-ai / 浏览器直接接入。

## 架构

```
手机内置摄像头 ×N(并发打开,全部同时推流)
  └─ Camera Kit (每路独立 CameraInput + PreviewOutput, 1280x720)
      └─ NDK OH_NativeImage(每路,CPU 读取)
          └─ de-stride + NV21→NV12 + 旋转(输出宽 32 对齐) → OH_VideoEncoder 硬编 ×N
              (CBR 4Mbps/路; napi 垫片 libh264enc.so,多实例)
              └─ FrameHub 帧分发(按相机分路)
                  ├─ RTSP :8554  /cam0 /cam1 …  H.264 over RTP (RFC 6184, TCP interleaved)
                  │         每个关键帧前补发 SPS/PPS,新客户端从关键帧起播
                  ├─ HTTP :8090  / 状态页 | /snapshot.jpg?cam=N | /stream?cam=N (MJPEG)
                  └─ ONVIF :8000  WS-Discovery 组播自动发现 + 多 Profile GetProfiles/GetStreamUri/GetSnapshotUri
  └─ 长时任务 (DATA_TRANSFER, module.json5 声明 backgroundModes) 后台/熄屏持续推流
```

并发打开失败的路自动跳过(硬件不支持并发相机的机型自然退化为单路);帧停滞 6 秒自动重开会话自愈(熄屏唤醒/HAL 卡死恢复)。

## 功能

- **音频随视频协商推送**:麦克风采集 + AAC-LC 44100 立体声 64kbps;RTSP SDP 提供
  音频轨道(trackID=1),客户端经 SETUP 协商接收——不 SETUP 则只收视频;
  ONVIF Profile 声明 AudioEncoderConfiguration(AAC)。麦克风不可用时自动降级纯视频
- **多摄像头并发推流**:前后置(及多摄)同时输出,每路独立 RTSP 地址与 ONVIF Profile
- RTSP / HTTP(MJPEG+快照) / ONVIF 三协议,ONVIF 每相机一个 Profile(token=profile_{N+1})
- HTTP 状态页:设备信息、各路统计(fps/帧数)、入口链接、内嵌预览、上次崩溃堆栈
- 多客户端同时拉流(TCP interleaved)
- **后台与退出策略**:系统返回键只进后台不退出;界面「关闭」按钮是唯一退出入口
  (停止推流、结束长时任务、进程退出)
- 崩溃防护网:未捕获异常落盘,下次启动在应用界面与状态页展示
- 纯 ArkTS 主体 + 单个 napi C 垫片(多相机多实例封装,~700 行)

## 后台运行说明(系统限制)

- **熄屏 + 应用在前台**:双路持续推流(长时任务 DATA_TRANSFER 保持不冻结,实测不断流)
- **应用退到后台**:系统拒绝后台应用持有相机会话(实测 CreateCameraInput 返回 null,
  长时任务也无法豁免,属隐私限制),推流暂停;应用不会退出,状态显示
  「后台暂停」,回到前台后看门狗自动重建相机管线并恢复推流,已连接的拉流端
  无需操作即可继续收流
- 帧停滞自愈分级:单次停滞重开该路会话;连续停滞全量重建管线;后台期间不做
  无谓重试(避免相机设备半开状态楔死,实测该状态仅进程退出可解除)

## 画面方向

界面提供 横向(0°)/ 竖向(90°)/ 倒横(180°)/ 倒竖(270°) 四档,加速度传感器实时检测摆放并提示建议档位。选 90°/270° 输出 704x1280 竖画面(C 层 NV12 旋转后编码,宽度按 32 对齐——720 宽实测硬编色度损坏,见 h264enc.c 注释),0°/180° 输出 1280x720。

采集管线:Camera Kit PreviewOutput → NDK OH_NativeImage(CPU 读取)→ de-stride + NV21→NV12 → 旋转 → OH_VideoEncoder buffer 输入。

**切换方向会自动退出应用**(系统 HCODEC 不支持进程内二次配置编码器),重新打开图标即按新配置自动恢复推流。

拉流端:

```bash
ffplay -rtsp_transport tcp rtsp://<手机IP>:8554/cam0    # 后置(含音频)
ffplay -rtsp_transport tcp rtsp://<手机IP>:8554/cam1    # 前置(含音频)
# OpenCV(需指定 TCP):
#   os.environ['OPENCV_FFMPEG_CAPTURE_OPTIONS'] = 'rtsp_transport;tcp'
#   cv2.VideoCapture('rtsp://<手机IP>:8554/cam0')
```

RTSP 仅支持 TCP interleaved 传输(RFC 2326 §12.39);UDP SETUP 请求会收到 461 应答。

## 使用

1. DevEco Studio(或 `hdc install`)安装,授予相机权限
2. 打开应用点「开始推流」,全部可用摄像头自动并发推流
3. 同一局域网接入:

| 协议 | 地址 |
|---|---|
| RTSP | `rtsp://<手机IP>:8554/camN`(VLC / ffmpeg / OpenCV / Frigate;N 为相机编号)|
| HTTP 状态页 | `http://<手机IP>:8090/`(浏览器直接看)|
| HTTP MJPEG | `http://<手机IP>:8090/stream?cam=N`(浏览器直接看)|
| 单帧快照 | `http://<手机IP>:8090/snapshot.jpg?cam=N` |
| ONVIF 自动发现 | 组播 239.255.255.250:3702(WS-Discovery,NetworkVideoTransmitter,启动发 Hello)|
| ONVIF SOAP | `http://<手机IP>:8000/onvif/device_service`(GetProfiles / GetStreamUri / GetSnapshotUri / GetCapabilities / GetServices / GetDeviceInformation)|
| ONVIF 添加 | NVR 中按 ONVIF 设备添加,每颗摄像头一个 Profile |

4. 长时间推流建议插电并允许电池优化豁免

## 构建

依赖:华为 Command Line Tools(hvigor 6.x,含 HarmonyOS SDK)。

```bash
hvigorw assembleHap --no-daemon
# 产物: entry/build/default/outputs/default/entry-default-unsigned.hap
# 签名: .signing/sign.sh <unsigned.hap>(AGC 调试证书,材料不入库)
```

注意:`entry/src/main/module.json5` 的 EntryAbility 声明了 `"backgroundModes": ["dataTransfer"]`,缺失会导致长时任务注册失败(9800005)、熄屏即冻结。

API 基线 5.0.0 (API 12);已实测 HarmonyOS 6.1.1 (API 24) 真机(SGT-AL50,前后摄并发双路)。

## 已验证

- 音频端到端:ffmpeg 拉流解出 AAC 44100 立体声;仅 SETUP 视频轨的客户端
  收不到任何音频包(协商生效);ONVIF Profile 含 AAC AudioEncoderConfiguration
- 前后摄并发双路 RTSP 同时拉流:1280x720 横屏与 704x1280 竖屏均零解码错误
- HTTP 状态页 / 每路快照 / 每路 MJPEG 流(多路并发请求合流编码)
- ONVIF:GetProfiles 多 Profile(相机名/分辨率动态)、GetStreamUri/GetSnapshotUri 按 Profile 映射、WS-Discovery Probe 应答与 Hello
- 熄屏持续推流:双路 6 秒以上不断流,进程未被冻结;帧停滞自动重开自愈
- 多客户端:双路 RTSP + MJPEG + 快照并行拉取

## 调试

- dump 模式:`FrameHub.beginDump()` 可将码流写入沙箱 `capture.h264` 供 `ffplay` 验证
- 日志:`hilog | grep ipcam`(分模块 EntryAbility/CameraSource/H264Encoder/FrameHub/RtspServer/HttpServer/OnvifServer/JpegSource)
- 码率:OH_MD_KEY_BITRATE 是 int64 键,C 层必须 `OH_AVFormat_SetLongValue`(SetIntValue 读不到会失控到 14Mbps)

## License

MIT
