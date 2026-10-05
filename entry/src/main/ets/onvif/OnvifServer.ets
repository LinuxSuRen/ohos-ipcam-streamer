import socket from '@ohos.net.socket';
import { BusinessError } from '@ohos.base';
import hilog from '@ohos.hilog';
import { lanAddress } from '../net/NetUtil';

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

  static async start(): Promise<void> {
    if (OnvifServer.running) {
      return;
    }
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
          const sendOpt: socket.TCPSendOptions = { data: str2ab(response) };
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
        }).catch((e: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'join group failed: %{public}s', JSON.stringify(e));
        });
      });
      OnvifServer.discovery = ms;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'discovery init failed: %{public}s', JSON.stringify(e));
    }
  }

  private static probeMatches(relatesTo: string): string {
    const ip = lanAddress();
    const now = Date.now();
    return '<?xml version="1.0" encoding="UTF-8"?>' +
      '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" ' +
      'xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" ' +
      'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" ' +
      'xmlns:dn="http://www.onvif.org/ver10/network/wsdl">' +
      '<e:Header>' +
      `<a:MessageID>urn:uuid:${now}</a:MessageID>` +
      '<a:RelatesTo>' + xmlEscape(relatesTo) + '</a:RelatesTo>' +
      '<a:To>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:To>' +
      '<a:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</a:Action>' +
      '</e:Header><e:Body>' +
      '<d:ProbeMatches>' +
      `<d:ProbeMatch><a:EndpointReference><a:Address>${DEVICE_UUID}</a:Address></a:EndpointReference>` +
      `<d:Types>dn:NetworkVideoTransmitter</d:Types>` +
      `<d:Scopes>onvif://www.onvif.org/Profile/Streaming</d:Scopes>` +
      `<d:XAddrs>http://${ip}:${HTTP_PORT}/onvif/device_service</d:XAddrs>` +
      `<d:MetadataVersion>1</d:MetadataVersion></d:ProbeMatch>` +
      '</d:ProbeMatches></e:Body></e:Envelope>';
  }

  private static handleSoap(body: string): string {
    const ip = lanAddress();
    let inner = '';
    if (body.indexOf('GetSystemDateAndTime') >= 0) {
      const d = new Date();
      const p2 = (v: number) => v.toString().padStart(2, '0');
      inner = '<tds:GetSystemDateAndTimeResponse><tds:SystemDateTime>' +
        `<tds:DateTimeType>System</tds:DateTimeType><tds:DaylightSavings>false</tds:DaylightSavings>` +
        `<tds:UTCDateTime><tdt:Year>${d.getUTCFullYear()}</tdt:Year>` +
        `<tdt:Month>${d.getUTCMonth() + 1}</tdt:Month><tdt:Day>${d.getUTCDate()}</tdt:Day>` +
        `<tdt:Hour>${d.getUTCHours()}</tdt:Hour><tdt:Minute>${d.getUTCMinutes()}</tdt:Minute>` +
        `<tdt:Second>${d.getUTCSeconds()}</tdt:Second></tds:UTCDateTime>` +
        '</tds:SystemDateTime></tds:GetSystemDateAndTimeResponse>';
    } else if (body.indexOf('GetProfiles') >= 0) {
      inner = '<trt:GetProfilesResponse>' +
        '<trt:Profiles fixed="true" token="profile_1">' +
        '<tt:Name>main</tt:Name>' +
        '<tt:VideoSourceConfiguration token="vsc_1">' +
        '<tt:Name>vsc</tt:Name><tt:SourceToken>src_1</tt:SourceToken>' +
        '<tt:Bounds x="0" y="0" width="1280" height="720"></tt:Bounds>' +
        '</tt:VideoSourceConfiguration>' +
        '<tt:VideoEncoderConfiguration token="vec_1">' +
        '<tt:Name>h264</tt:Name>' +
        '<tt:Encoding>H264</tt:Encoding>' +
        '<tt:Resolution><tt:Width>1280</tt:Width><tt:Height>720</tt:Height></tt:Resolution>' +
        '<tt:RateControl><tt:FrameRateLimit>25</tt:FrameRateLimit>' +
        '<tt:BitrateLimit>2000</tt:BitrateLimit></tt:RateControl>' +
        '</tt:VideoEncoderConfiguration>' +
        '</trt:Profiles></trt:GetProfilesResponse>';
    } else if (body.indexOf('GetStreamUri') >= 0) {
      inner = '<trt:GetStreamUriResponse><trt:MediaUri>' +
        `<tt:Uri>rtsp://${ip}:${RTSP_PORT}/cam</tt:Uri>` +
        '<tt:InvalidAfterConnect>false</tt:InvalidAfterConnect>' +
        '<tt:InvalidAfterReboot>false</tt:InvalidAfterReboot>' +
        '<tt:Timeout>60</tt:Timeout>' +
        '</trt:MediaUri></trt:GetStreamUriResponse>';
    } else if (body.indexOf('GetDeviceInformation') >= 0) {
      inner = '<tds:GetDeviceInformationResponse>' +
        '<td:Manufacturer>linuxsuren</td:Manufacturer>' +
        '<td:Model>ohos-ipcam</td:Model>' +
        '<td:FirmwareVersion>0.1.0</td:FirmwareVersion>' +
        '</tds:GetDeviceInformationResponse>';
    }
    const soapBody = inner !== '' ? inner :
      '<tds:GetDeviceInformationResponse/>';
    return 'HTTP/1.1 200 OK\r\nContent-Type: application/soap+xml; charset=utf-8\r\n' +
      `Content-Length: ${str2ab(OnvifServer.soapEnvelope(soapBody)).byteLength}\r\nConnection: close\r\n\r\n` +
      OnvifServer.soapEnvelope(soapBody);
  }

  private static soapEnvelope(inner: string): string {
    return '<?xml version="1.0" encoding="UTF-8"?>' +
      '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" ' +
      'xmlns:tds="http://www.onvif.org/ver10/device/wsdl" ' +
      'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" ' +
      'xmlns:tt="http://www.onvif.org/ver10/schema">' +
      `<s:Body>${inner}</s:Body></s:Envelope>`;
  }
}
