import socket from '@ohos.net.socket';
import { BusinessError } from '@ohos.base';
import hilog from '@ohos.hilog';
import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import { lanAddress } from '../net/NetUtil';
import { CamRegistry } from '../net/CamRegistry';
import { HttpServer } from '../http/HttpServer';
import { RtspServer } from '../rtsp/RtspServer';
import { deviceModel, deviceOs, deviceLabel, deviceHardware, ensureDeviceId } from '../entryability/DeviceIdentity';
import { PtzController } from './PtzController';
import { CameraSource } from '../camera/CameraSource';
import { AuthConfig, verifyWsUsernameToken } from '../auth/Auth';

const DOMAIN = 0x0809;
const TAG = 'ipcam.OnvifServer';
const HTTP_PORT = 8000;
const DISCOVERY_GROUP = '239.255.255.250';
const DISCOVERY_PORT = 3702;
const RTSP_PORT = 8554;

const DEVICE_UUID = 'urn:uuid:9a3f2c1e-0002-4b7a-9f0c-ipcam000001';

function ab2str(ab: ArrayBuffer): string {
  const u8 = new Uint8Array(ab);
  let s = '';
  for (let i = 0; i < u8.length; i++) {
    s += String.fromCharCode(u8[i]);
  }
  return s;
}

function str2ab(s: string): ArrayBuffer {
  const u8 = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    u8[i] = s.charCodeAt(i) & 0xff;
  }
  return u8.buffer;
}

/** XML 必须按 UTF-8 编码:中相机名经 str2ab 的 Latin-1 截断会变乱码。 */
function utf8(s: string): ArrayBuffer {
  const encoder = new util.TextEncoder();
  return encoder.encodeInto(s).buffer as ArrayBuffer;
}

function xmlEscape(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function extract(xml: string, pattern: string): string {
  const m = new RegExp(pattern).exec(xml);
  return m !== null ? m[1] : '';
}

/**
 * ONVIF(:8000):
 * - WS-Discovery 组播 239.255.255.250:3702 响应 Probe(ProbeMatches 单播回源)
 * - HTTP SOAP:GetSystemDateAndTime / GetProfiles / GetStreamUri
 * GetStreamUri 返回 rtsp://<ip>:8554/cam,与 RTSP 服务器同生命周期。
 * 直译自 Android 版 OnvifServer.java,码流 Profile 改为 H.264。
 */
export class OnvifServer {
  private static httpServer: socket.TCPSocketServer | null = null;
  private static discovery: socket.MulticastSocket | null = null;
  private static running = false;
  private static deviceId: string = '';
  private static instanceId = 0;
  private static msgNo = 0;

  static async start(context: common.Context): Promise<void> {
    if (OnvifServer.running) {
      return;
    }
    OnvifServer.deviceId = ensureDeviceId(context);
    OnvifServer.instanceId = Math.floor(Date.now() / 1000);
    OnvifServer.msgNo = 0;
    await OnvifServer.startHttp();
    OnvifServer.startDiscovery();
    OnvifServer.running = true;
    hilog.info(DOMAIN, TAG, 'onvif started');
  }

  static async stop(): Promise<void> {
    if (OnvifServer.httpServer !== null) {
      try {
        await OnvifServer.httpServer.close();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'http close');
      }
      OnvifServer.httpServer = null;
    }
    if (OnvifServer.discovery !== null) {
      /* 停止前发 Bye,通知发现客户端本设备下线 */
      try {
        const bye = OnvifServer.discoveryMessage('Bye', '');
        const sendOpt: socket.UDPSendOptions = {
          data: utf8(bye),
          address: { address: DISCOVERY_GROUP, port: DISCOVERY_PORT }
        };
        await OnvifServer.discovery.send(sendOpt);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'send bye failed');
      }
      try {
        const dropOpt: socket.NetAddress = { address: DISCOVERY_GROUP, port: 0 };
        await OnvifServer.discovery.dropMembership(dropOpt);
        OnvifServer.discovery.close();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'discovery close');
      }
      OnvifServer.discovery = null;
    }
    OnvifServer.running = false;
    hilog.info(DOMAIN, TAG, 'onvif stopped');
  }

  private static async startHttp(): Promise<void> {
    const server = socket.constructTCPSocketServerInstance();
    server.on('connect', (client: socket.TCPSocketConnection) => {
      let buf = '';
      let contentLength = -1;
      let headerDone = false;
      client.on('message', (info: socket.SocketMessageInfo) => {
        buf += ab2str(info.message);
        if (!headerDone) {
          const i = buf.indexOf('\r\n\r\n');
          if (i < 0) {
            return;
          }
          headerDone = true;
          const m = /Content-Length:\s*(\d+)/i.exec(buf.substring(0, i));
          contentLength = m !== null ? parseInt(m[1]) : 0;
          buf = buf.substring(i + 4);
        }
        if (contentLength >= 0 && buf.length >= contentLength) {
          const body = buf.substring(0, contentLength);
          const response = OnvifServer.handleSoap(body);
          const sendOpt: socket.TCPSendOptions = { data: utf8(response) };
          client.send(sendOpt).then(() => {
            client.close();
          }).catch(() => {
            client.close();
          });
          buf = '';
          headerDone = false;
          contentLength = -1;
        }
      });
      client.on('close', () => {
      });
      client.on('error', () => {
      });
    });
    const listenOpt: socket.NetAddress = { address: '0.0.0.0', port: HTTP_PORT };
    await server.listen(listenOpt);
    OnvifServer.httpServer = server;
    hilog.info(DOMAIN, TAG, 'soap listening on %{public}d', HTTP_PORT);
  }

  private static startDiscovery(): void {
    try {
      const ms = socket.constructMulticastSocketInstance();
      ms.on('message', (info: socket.SocketMessageInfo) => {
        const msg = ab2str(info.message);
        if (msg.indexOf('Probe') < 0 || msg.indexOf('discovery') < 0) {
          return;
        }
        const relatesTo = extract(msg, 'MessageID>([^<]+)<');
        if (relatesTo === '') {
          return;
        }
        const reply = OnvifServer.probeMatches(relatesTo);
        const target: socket.NetAddress = {
          address: info.remoteInfo.address,
          port: info.remoteInfo.port
        };
        const sendOpt: socket.UDPSendOptions = { data: str2ab(reply), address: target };
        ms.send(sendOpt).catch(() => {
        });
      });
      const bindOpt: socket.NetAddress = { address: '0.0.0.0', port: DISCOVERY_PORT };
      ms.bind(bindOpt, (): void => {
        const memberOpt: socket.NetAddress = { address: DISCOVERY_GROUP, port: DISCOVERY_PORT };
        ms.addMembership(memberOpt).then(() => {
          hilog.info(DOMAIN, TAG, 'ws-discovery joined %{public}s', DISCOVERY_GROUP);
          /* 入组后主动发 Hello:在线客户端无需 Probe 即可感知本设备 */
          const hello = OnvifServer.discoveryMessage('Hello', '');
          const helloOpt: socket.UDPSendOptions = {
            data: utf8(hello),
            address: { address: DISCOVERY_GROUP, port: DISCOVERY_PORT }
          };
          ms.send(helloOpt).catch(() => {
          });
        }).catch((e: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'join group failed: %{public}s', JSON.stringify(e));
        });
      });
      OnvifServer.discovery = ms;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'discovery init failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 发现消息通用模板:ProbeMatches(应答)/Hello(上线)/Bye(下线)。 */
  private static discoveryMessage(action: string, relatesTo: string): string {
    const ip = lanAddress();
    const now = Date.now();
    const inner = action === 'ProbeMatches' ? 'ProbeMatch' : action;
    const relates = relatesTo !== '' ? `<a:RelatesTo>${xmlEscape(relatesTo)}</a:RelatesTo>` : '';
    OnvifServer.msgNo++;
    return '<?xml version="1.0" encoding="UTF-8"?>' +
      '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" ' +
      'xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" ' +
      'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" ' +
      'xmlns:dn="http://www.onvif.org/ver10/network/wsdl">' +
      '<s:Header>' +
      `<a:MessageID>urn:uuid:${now}</a:MessageID>` +
      relates +
      '<a:To>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:To>' +
      `<a:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/${action}</a:Action>` +
      `<d:AppSequence InstanceId="${OnvifServer.instanceId}" MessageNumber="${OnvifServer.msgNo}"/>` +
      '</s:Header><s:Body>' +
      `<d:${action}><d:${inner}>` +
      `<a:EndpointReference><a:Address>${DEVICE_UUID}</a:Address></a:EndpointReference>` +
      '<d:Types>dn:NetworkVideoTransmitter</d:Types>' +
      `<d:Scopes>${OnvifServer.scopes()}</d:Scopes>` +
      `<d:XAddrs>http://${ip}:${HTTP_PORT}/onvif/device_service</d:XAddrs>` +
      '<d:MetadataVersion>1</d:MetadataVersion>' +
      `</d:${inner}></d:${action}></s:Body></s:Envelope>`;
  }

  /** 发现 Scopes:类型/名称/硬件/Profile,名称带宿主机型便于多设备区分。 */
  private static scopes(): string {
    return 'onvif://www.onvif.org/type/NetworkVideoTransmitter' +
      ` onvif://www.onvif.org/name/ohos-ipcam-streamer@${deviceLabel()}` +
      ` onvif://www.onvif.org/hardware/${deviceLabel()}` +
      ' onvif://www.onvif.org/Profile/Streaming';
  }

  private static probeMatches(relatesTo: string): string {
    return OnvifServer.discoveryMessage('ProbeMatches', relatesTo);
  }

  private static handleSoap(body: string): string {
    const ip = lanAddress();
    /* 认证门禁:pre-auth 白名单(GetSystemDateAndTime 对时/能力发现)放行,
     * 其余操作(GetProfiles/GetStreamUri/快照/设备信息/PTZ)要求
     * WS-Security UsernameToken;未授权按 ONVIF 惯例回 HTTP 401 */
    if (AuthConfig.isEnabled() &&
      body.indexOf('GetSystemDateAndTime') < 0 &&
      body.indexOf('GetCapabilities') < 0 &&
      body.indexOf('GetServices') < 0 &&
      !verifyWsUsernameToken(body)) {
      hilog.warn(DOMAIN, TAG, 'soap 401 unauthorized');
      return 'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n';
    }
    let inner = '';
    /* PTZ 服务:变焦(手机无云台,Pan/Tilt 忽略应答成功)。
     * 用 tag 级匹配(任意命名空间前缀),防 'Stop' 之类词干误撞其他动作 */
    const ptzOp = new RegExp('<[A-Za-z0-9]+:?(ContinuousMove|AbsoluteMove|RelativeMove|Stop|GetStatus|GetConfigurationOptions)[\\s>]').exec(body);
    if (ptzOp !== null) {
      inner = OnvifServer.handlePtz(ptzOp[1], body, ip);
    } else if (body.indexOf('GetSystemDateAndTime') >= 0) {
      const d = new Date();
      const p2 = (v: number) => v.toString().padStart(2, '0');
      inner = '<tds:GetSystemDateAndTimeResponse><tds:SystemDateTime>' +
        `<tds:DateTimeType>System</tds:DateTimeType><tds:DaylightSavings>false</tds:DaylightSavings>` +
        `<tds:UTCDateTime><tdt:Year>${d.getUTCFullYear()}</tdt:Year>` +
        `<tdt:Month>${d.getUTCMonth() + 1}</tdt:Month><tdt:Day>${d.getUTCDate()}</tdt:Day>` +
        `<tdt:Hour>${d.getUTCHours()}</tdt:Hour><tdt:Minute>${d.getUTCMinutes()}</tdt:Minute>` +
        `<tdt:Second>${d.getUTCSeconds()}</tdt:Second></tds:UTCDateTime>` +
        '</tds:SystemDateTime></tds:GetSystemDateAndTimeResponse>';
    } else if (body.indexOf('GetCapabilities') >= 0) {
      inner = '<tds:GetCapabilitiesResponse><tds:Capabilities>' +
        `<tt:Device><tt:XAddr>http://${ip}:${HTTP_PORT}/onvif/device_service</tt:XAddr></tt:Device>` +
        `<tt:PTZ><tt:XAddr>http://${ip}:${HTTP_PORT}/onvif/ptz_service</tt:XAddr></tt:PTZ>` +
        `<tt:Media><tt:XAddr>http://${ip}:${HTTP_PORT}/onvif/media_service</tt:XAddr>` +
        '<tt:StreamingCapabilities>' +
        '<tt:RTPMulticast>false</tt:RTPMulticast>' +
        '<tt:RTP_TCP>true</tt:RTP_TCP>' +
        '<tt:RTP_RTSP_TCP>true</tt:RTP_RTSP_TCP>' +
        '<tt:NonAggregateControl>true</tt:NonAggregateControl>' +
        '</tt:StreamingCapabilities></tt:Media>' +
        '</tds:Capabilities></tds:GetCapabilitiesResponse>';
    } else if (body.indexOf('GetServices') >= 0) {
      inner = '<tds:GetServicesResponse>' +
        '<tds:Service><tds:Namespace>http://www.onvif.org/ver10/device/wsdl</tds:Namespace>' +
        `<tds:XAddr>http://${ip}:${HTTP_PORT}/onvif/device_service</tds:XAddr>` +
        '<tds:Version><tt:Major>1</tt:Major><tt:Minor>0</tt:Minor></tds:Version></tds:Service>' +
        '<tds:Service><tds:Namespace>http://www.onvif.org/ver10/media/wsdl</tds:Namespace>' +
        `<tds:XAddr>http://${ip}:${HTTP_PORT}/onvif/media_service</tds:XAddr>` +
        '<tds:Version><tt:Major>1</tt:Major><tt:Minor>0</tt:Minor></tds:Version></tds:Service>' +
        '</tds:GetServicesResponse>';
    } else if (body.indexOf('GetProfiles') >= 0) {
      /* 多摄像头:每路一个 Profile(token=profile_{N+1},N 为全局相机编号),
       * 尺寸/帧率/码率与该路实际输出一致 */
      let profiles = '';
      for (const c of CamRegistry.list()) {
        const n = c.index + 1;
        const kbps = Math.round(c.bitrate / 1000);
        profiles += `<trt:Profiles fixed="true" token="profile_${n}">` +
          `<tt:Name>${xmlEscape(c.label)}</tt:Name>` +
          `<tt:VideoSourceConfiguration token="vsc_${n}">` +
          `<tt:Name>vsc_${n}</tt:Name><tt:SourceToken>src_${n}</tt:SourceToken>` +
          `<tt:Bounds x="0" y="0" width="${c.outW}" height="${c.outH}"></tt:Bounds>` +
          `</tt:VideoSourceConfiguration>` +
          `<tt:VideoEncoderConfiguration token="vec_${n}">` +
          `<tt:Name>h264_${n}</tt:Name>` +
          '<tt:UseCount>1</tt:UseCount>' +
          '<tt:Encoding>H264</tt:Encoding>' +
          `<tt:Resolution><tt:Width>${c.outW}</tt:Width><tt:Height>${c.outH}</tt:Height></tt:Resolution>` +
          '<tt:Quality>4</tt:Quality>' +
          `<tt:RateControl><tt:FrameRateLimit>${c.fps}</tt:FrameRateLimit>` +
          `<tt:BitrateLimit>${kbps}</tt:BitrateLimit></tt:RateControl>` +
          '</tt:VideoEncoderConfiguration>';
        /* PTZ 能力声明:onvif-ai 等客户端以 Profile 内 PTZConfiguration 的存在
         * 判定 PTZ 可用(进而显示变焦控制);token 与 GetConfigurationOptions 对应 */
        profiles += `<tt:PTZConfiguration token="ptz_${n}">` +
          `<tt:Name>ptz_${n}</tt:Name>` +
          '<tt:UseCount>1</tt:UseCount>' +
          `<tt:NodeToken>PTZNODE_${n}</tt:NodeToken>` +
          '</tt:PTZConfiguration>';
        if (RtspServer.isAudioEnabled()) {
          /* 音频协商:Profile 声明 AAC 能力,客户端按需拉取 */
          profiles += `<tt:AudioEncoderConfiguration token="aec_${n}">` +
            `<tt:Name>aac_${n}</tt:Name>` +
            '<tt:UseCount>1</tt:UseCount>' +
            '<tt:Encoding>AAC</tt:Encoding>' +
            '<tt:Bitrate>64</tt:Bitrate>' +
            '<tt:SampleRate>44100</tt:SampleRate>' +
            '<tt:SessionTimeout>PT60S</tt:SessionTimeout>' +
            '</tt:AudioEncoderConfiguration>';
        }
        profiles += '</trt:Profiles>';
      }
      inner = `<trt:GetProfilesResponse>${profiles}</trt:GetProfilesResponse>`;
    } else if (body.indexOf('GetStreamUri') >= 0) {
      const cam = OnvifServer.cameraOfToken(extract(body, 'ProfileToken>([^<]+)<'));
      inner = '<trt:GetStreamUriResponse><trt:MediaUri>' +
        `<tt:Uri>rtsp://${ip}:${RTSP_PORT}/cam${cam}</tt:Uri>` +
        '<tt:InvalidAfterConnect>false</tt:InvalidAfterConnect>' +
        '<tt:InvalidAfterReboot>false</tt:InvalidAfterReboot>' +
        '<tt:Timeout>60</tt:Timeout>' +
        '</trt:MediaUri></trt:GetStreamUriResponse>';
    } else if (body.indexOf('GetSnapshotUri') >= 0) {
      /* 快照通道:HTTP 单帧 JPEG,供不支持 RTSP 的客户端降级轮询 */
      const cam = OnvifServer.cameraOfToken(extract(body, 'ProfileToken>([^<]+)<'));
      const suffix = cam === 0 ? '' : `?cam=${cam}`;
      inner = '<trt:GetSnapshotUriResponse><trt:MediaUri>' +
        `<tt:Uri>http://${ip}:${HttpServer.port()}/snapshot.jpg${suffix}</tt:Uri>` +
        '<tt:InvalidAfterConnect>false</tt:InvalidAfterConnect>' +
        '<tt:InvalidAfterReboot>false</tt:InvalidAfterReboot>' +
        '<tt:Timeout>60</tt:Timeout>' +
        '</trt:MediaUri></trt:GetSnapshotUriResponse>';
    } else if (body.indexOf('GetDeviceInformation') >= 0) {
      inner = '<tds:GetDeviceInformationResponse>' +
        '<td:Manufacturer>linuxsuren</td:Manufacturer>' +
        `<td:Model>${xmlEscape(deviceModel())}</td:Model>` +
        `<td:FirmwareVersion>${xmlEscape(deviceOs())}</td:FirmwareVersion>` +
        `<td:SerialNumber>${OnvifServer.deviceId}</td:SerialNumber>` +
        `<td:HardwareId>${xmlEscape(deviceHardware())}</td:HardwareId>` +
        '</tds:GetDeviceInformationResponse>';
    }
    const soapBody = inner !== '' ? inner :
      '<tds:GetDeviceInformationResponse/>';
    return 'HTTP/1.1 200 OK\r\nContent-Type: application/soap+xml; charset=utf-8\r\n' +
      `Content-Length: ${utf8(OnvifServer.soapEnvelope(soapBody)).byteLength}\r\nConnection: close\r\n\r\n` +
      OnvifServer.soapEnvelope(soapBody);
  }

  /** PTZ 操作处理:onvif-ai/NVR 的变焦指令 → 相机 zoomRatio。 */
  private static handlePtz(op: string, body: string, ip: string): string {
    const token = extract(body, 'ProfileToken>([^<]+)<');
    const cam = OnvifServer.cameraOfToken(token);
    if (op === 'ContinuousMove') {
      const zv = parseFloat(extract(body, 'Zoom x=["\'](-?[0-9.]+)["\']'));
      const ts = parseFloat(extract(body, 'Timeout>PT([0-9.]+)S'));
      PtzController.continuousMove(cam, isNaN(zv) ? 0 : zv, isNaN(ts) ? 5 : ts);
      return '<tptz:ContinuousMoveResponse/>';
    }
    if (op === 'AbsoluteMove') {
      const pos = parseFloat(extract(body, 'Zoom x=["\'](-?[0-9.]+)["\']'));
      if (!isNaN(pos)) {
        PtzController.absoluteMove(cam, pos);
      }
      return '<tptz:AbsoluteMoveResponse/>';
    }
    if (op === 'RelativeMove') {
      /* 相对移动按全范围的百分比解释 */
      const dz = parseFloat(extract(body, 'Zoom x=["\'](-?[0-9.]+)["\']'));
      if (!isNaN(dz)) {
        const cur = PtzController.position(cam);
        if (cur >= 0) {
          PtzController.absoluteMove(cam, cur + dz);
        }
      }
      return '<tptz:RelativeMoveResponse/>';
    }
    if (op === 'Stop') {
      PtzController.stop(cam);
      return '<tptz:StopResponse/>';
    }
    if (op === 'GetStatus') {
      const pos = PtzController.position(cam);
      const zoom = pos >= 0 ? `<tt:Position><tt:Zoom x="${pos.toFixed(3)}" space="http://www.onvif.org/ver10/tptz/ZoomSpaces/PositionGenericSpace"/></tt:Position>` : '';
      return `<tptz:GetStatusResponse><tptz:PTZStatus>${zoom}<tt:MoveStatus><tt:PanTilt>IDLE</tt:PanTilt><tt:Zoom>IDLE</tt:Zoom></tt:MoveStatus><tt:Error>NO_ERROR</tt:Error></tptz:PTZStatus></tptz:GetStatusResponse>`;
    }
    if (op === 'GetConfigurationOptions') {
      /* 该命令用 ConfigurationToken(ptz_N,对应 profile_N);若请求带的是
       * ProfileToken 也能正确提取,两者都兼容 */
      const cfgToken = extract(body, 'ConfigurationToken>([^<]+)<');
      const cfgCam = OnvifServer.cameraOfToken(cfgToken);
      const cam2 = cfgToken !== '' ? cfgCam : cam;
      const has = PtzController.hasZoom(cam2);
      let zoomSpaces = '';
      if (has) {
        zoomSpaces =
        '<tt:ContinuousZoomVelocitySpace><tt:XRange><tt:Min>-1</tt:Min><tt:Max>1</tt:Max></tt:XRange><tt:URI>http://www.onvif.org/ver10/tptz/ZoomSpaces/ZoomVelocityGenericSpace</tt:URI></tt:ContinuousZoomVelocitySpace>' +
        '<tt:AbsoluteZoomPositionSpace><tt:XRange><tt:Min>0</tt:Min><tt:Max>1</tt:Max></tt:XRange><tt:URI>http://www.onvif.org/ver10/tptz/ZoomSpaces/AbsoluteZoomGenericSpace</tt:URI></tt:AbsoluteZoomPositionSpace>' +
        '<tt:RelativeZoomTranslationSpace><tt:XRange><tt:Min>-1</tt:Min><tt:Max>1</tt:Max></tt:XRange><tt:URI>http://www.onvif.org/ver10/tptz/ZoomSpaces/RelativeZoomGenericSpace</tt:URI></tt:RelativeZoomTranslationSpace>' +
        '<tt:ZoomSpeed><tt:XRange><tt:Min>-1</tt:Min><tt:Max>1</tt:Max></tt:XRange></tt:ZoomSpeed>';
        /* 自定义空间:真实倍率范围(客户端据此把归一位置换算成 "x 倍率" 展示) */
        const range = CameraSource.getZoomRange(cam2);
        zoomSpaces += '<tt:AbsoluteZoomPositionSpace>' +
          `<tt:XRange><tt:Min>${range[0]}</tt:Min><tt:Max>${range[1]}</tt:Max></tt:XRange>` +
          '<tt:URI>http://www.linuxsuren.org/onvif/zoom/ratio</tt:URI></tt:AbsoluteZoomPositionSpace>';
      }
      return `<tptz:GetConfigurationOptionsResponse><tptz:PTZConfigurationOptions><tt:PTZTimeout><tt:Min>PT1S</tt:Min><tt:Max>PT60S</tt:Max></tt:PTZTimeout><tt:Spaces>${zoomSpaces}</tt:Spaces></tptz:PTZConfigurationOptions></tptz:GetConfigurationOptionsResponse>`;
    }
    return '';
  }

  private static soapEnvelope(inner: string): string {
    return '<?xml version="1.0" encoding="UTF-8"?>' +
      '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" ' +
      'xmlns:tds="http://www.onvif.org/ver10/device/wsdl" ' +
      'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" ' +
      'xmlns:tt="http://www.onvif.org/ver10/schema" ' +
      'xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl">' +
      `<s:Body>${inner}</s:Body></s:Envelope>`;
  }

  /** profile_N → 相机编号(N-1),无法解析按 0 号处理。 */
  private static cameraOfToken(token: string): number {
    if (token === undefined || token === '') {
      return 0;
    }
    const under = token.lastIndexOf('_');
    const n = parseInt(token.substring(under + 1).trim());
    if (isNaN(n)) {
      return 0;
    }
    return Math.max(0, n - 1);
  }
}
