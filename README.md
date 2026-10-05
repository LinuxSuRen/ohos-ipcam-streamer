# 手机IP摄像头(ohos-ipcam-streamer)

鸿蒙(HarmonyOS / OpenHarmony)手机内置摄像头转 IP 摄像头网关,姊妹项目 [tv-uvc-streamer](https://github.com/linuxsuren/tv-uvc-streamer)(Android / UVC USB 摄像头)。手机插电即成为局域网内标准网络摄像机,供 NVR / Frigate / OpenCV / ffmpeg / VLC / onvif-ai 直接接入。

## 架构

```
手机内置摄像头(可选 前置/后置/多摄)
  └─ Camera Kit (CameraInput + VideoOutput, 1280x720, surface 直连)
      └─ H.264 硬编 (NDK OH_VideoEncoder, CBR 2Mbps, napi 垫片 libh264enc.so)
          └─ FrameHub 帧分发
              ├─ RTSP :8554  /cam  H.264 over RTP (RFC 6184, TCP interleaved)
              │         每个关键帧前补发 SPS/PPS,新客户端从关键帧起播
              └─ ONVIF :8000  WS-Discovery 组播自动发现 + GetProfiles / GetStreamUri
  └─ 长时任务 (DATA_TRANSFER) 后台/熄屏持续推流
```

## 功能

- 一键开始/停止推流,RTSP 与 ONVIF 同启
- **摄像头选择**:界面切换 前置/后置/多摄,切换后自动重启推流
- 多客户端同时拉流(TCP interleaved)
- 后台常驻 + 熄屏持续推流(状态栏常驻通知)
- 纯 ArkTS 主体 + 单个 napi C 垫片(仅封装编码器,~260 行)

## 画面方向

界面提供 横向(0°)/ 竖向(90°)/ 倒横(180°)/ 倒竖(270°) 四档,加速度传感器实时检测摆放并提示建议档位。选 90°/270° 时输出 720x1280 竖画面(C 层 NV12 旋转后编码),0°/180° 输出 1280x720。

采集管线:Camera Kit PreviewOutput → NDK OH_NativeImage(CPU 读取)→ de-stride + NV21→NV12 → 旋转 → OH_VideoEncoder buffer 输入。

**切换方向/摄像头会自动退出应用**(系统 HCODEC 不支持进程内二次配置编码器),重新打开图标即按新配置自动恢复推流。

拉流端:

```bash
ffplay -rtsp_transport tcp rtsp://<手机IP>:8554/cam
# OpenCV(需指定 TCP):
#   os.environ['OPENCV_FFMPEG_CAPTURE_OPTIONS'] = 'rtsp_transport;tcp'
#   cv2.VideoCapture('rtsp://<手机IP>:8554/cam')
```

本服务仅支持 TCP interleaved 传输(RFC 2326 §12.39);UDP SETUP 请求会收到 461 应答。

## 使用

1. DevEco Studio(或 `hdc install`)安装,授予相机权限
2. 打开应用点「开始推流」;需要时点摄像头标签切换
3. 同一局域网接入:

| 协议 | 地址 |
|---|---|
| RTSP | `rtsp://<手机IP>:8554/cam`(VLC / ffmpeg / OpenCV / Frigate)|
| ONVIF 自动发现 | 组播 239.255.255.250:3702(WS-Discovery,NetworkVideoTransmitter)|
| ONVIF SOAP | `http://<手机IP>:8000/onvif/device_service`(GetProfiles / GetStreamUri)|
| ONVIF 添加 | NVR 中按 ONVIF 设备添加,流地址由 GetStreamUri 返回 |

4. 长时间推流建议插电并允许电池优化豁免

## 构建

依赖:华为 Command Line Tools(hvigor 6.x,含 HarmonyOS SDK)。

```bash
hvigorw assembleHap --no-daemon
# 产物: entry/build/default/outputs/default/entry-default-unsigned.hap
# 签名: .signing/sign.sh <unsigned.hap>(AGC 调试证书,材料不入库)
```

API 基线 5.0.0 (API 12);已实测 HarmonyOS 6.1.1 (API 24) 真机(SGT-AL50)。

## 已验证

- ffmpeg / ffprobe 拉流:H.264 High,横(1280x720)与竖(720x1280)均 20 秒零解码错误
- 方向四档切换(退出重开自动恢复)
- ONVIF GetStreamUri 返回正确 RTSP 地址;WS-Discovery 组播应答
- 熄屏 + 退后台持续推流(长时任务)

## 调试

- dump 模式:`FrameHub.beginDump()` 可将码流写入沙箱 `capture.h264` 供 `ffplay` 验证
- 日志:`hilog | grep ipcam`(分模块 EntryAbility/CameraSource/H264Encoder/FrameHub/RtspServer/OnvifServer)

## License

MIT
