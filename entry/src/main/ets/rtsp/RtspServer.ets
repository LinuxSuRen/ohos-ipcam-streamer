import socket from '@ohos.net.socket';
import hilog from '@ohos.hilog';
import { RtspSession } from './RtspSession';
import { lanAddress } from '../net/NetUtil';

const DOMAIN = 0x0807;
const TAG = 'ipcam.RtspServer';
const RTSP_PORT = 8554;
const PAYLOAD_TYPE = 96;
const MAX_CAMS = 4;

const B64_TABLE: string[] = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'.split('');

function b64(u8: Uint8Array): string {
  let out = '';
  for (let i = 0; i < u8.length; i += 3) {
    const b0 = u8[i];
    const b1 = i + 1 < u8.length ? u8[i + 1] : 0;
    const b2 = i + 2 < u8.length ? u8[i + 2] : 0;
    out += B64_TABLE[b0 >> 2] + B64_TABLE[((b0 & 3) << 4) | (b1 >> 4)];
    out += i + 1 < u8.length ? B64_TABLE[((b1 & 15) << 2) | (b2 >> 6)] : '=';
    out += i + 2 < u8.length ? B64_TABLE[b2 & 63] : '=';
  }
  return out;
}

/** 各相机裸 SPS/PPS NALU(去起始码),由 FrameHub 从码流拆出。 */
let spsNalus: Array<Uint8Array | null> = [null, null, null, null];
let ppsNalus: Array<Uint8Array | null> = [null, null, null, null];

export function setParameterSets(cam: number, sps: Uint8Array | null, pps: Uint8Array | null): void {
  if (cam < 0 || cam >= MAX_CAMS) {
    return;
  }
  if (sps !== null && spsNalus[cam] === null) {
    spsNalus[cam] = sps;
    hilog.info(DOMAIN, TAG, 'cam%{public}d SPS nalu %{public}d bytes', cam, sps.length);
  }
  if (pps !== null && ppsNalus[cam] === null) {
    ppsNalus[cam] = pps;
    hilog.info(DOMAIN, TAG, 'cam%{public}d PPS nalu %{public}d bytes', cam, pps.length);
  }
}

export function resetParameterSets(): void {
  spsNalus = [null, null, null, null];
  ppsNalus = [null, null, null, null];
}

/** 从请求 URL(rtsp://host:port/cam1 或 /cam1)解析相机编号;/cam 及未识别为 0。 */
export function cameraOfUrl(url: string): number {
  if (url === undefined || url === '') {
    return 0;
  }
  const proto = url.indexOf('://');
  let path = proto >= 0 ? url.substring(proto + 3) : url;
  const slash = path.indexOf('/');
  path = slash >= 0 ? path.substring(slash + 1) : '';
  const q = path.indexOf('?');
  if (q >= 0) {
    path = path.substring(0, q);
  }
  if (path.startsWith('cam') && path.length > 3) {
    const n = parseInt(path.substring(3));
    if (!isNaN(n) && n >= 0 && n < MAX_CAMS) {
      return n;
    }
  }
  return 0;
}

/**
 * RTSP 服务器(:8554)。多相机多会话:URL /camN 对应第 N 路,
 * /cam 兼容 0 号。DESCRIBE 的 SDP 按相机携带 sprop-parameter-sets。
 */
export class RtspServer {
  private static server: socket.TCPSocketServer | null = null;
  private static sessions: RtspSession[] = [];
  private static fps: number = 25;

  static async start(fps: number): Promise<void> {
    if (RtspServer.server !== null) {
      return;
    }
    RtspServer.fps = fps;
    const server = socket.constructTCPSocketServerInstance();
    server.on('connect', (client: socket.TCPSocketConnection) => {
      hilog.info(DOMAIN, TAG, 'client connected');
      const session = new RtspSession(client, RtspServer.fps);
      session.start();
      RtspServer.sessions.push(session);
    });
    const listenOpt: socket.NetAddress = { address: '0.0.0.0', port: RTSP_PORT };
    await server.listen(listenOpt);
    RtspServer.server = server;
    hilog.info(DOMAIN, TAG, 'rtsp listening on %{public}d', RTSP_PORT);
  }

  static async stop(): Promise<void> {
    for (const s of RtspServer.sessions) {
      s.close();
    }
    RtspServer.sessions = [];
    if (RtspServer.server !== null) {
      try {
        await RtspServer.server.close();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'server close');
      }
      RtspServer.server = null;
    }
    hilog.info(DOMAIN, TAG, 'rtsp stopped');
  }

  static sessionCount(): number {
    let live = 0;
    for (const s of RtspServer.sessions) {
      if (!s.isDead()) {
        live++;
      }
    }
    return live;
  }

  /** FrameHub 按 cam 分发入口:只投给订阅该相机的会话。 */
  static broadcast(frame: ArrayBuffer, keyframe: boolean, cam: number): void {
    for (const s of RtspServer.sessions) {
      s.onFrame(frame, keyframe, cam);
    }
    if (RtspServer.sessions.length > 16) {
      RtspServer.sessions = RtspServer.sessions.filter((s) => !s.isDead());
    }
  }

  static remove(session: RtspSession): void {
    const i = RtspServer.sessions.indexOf(session);
    if (i >= 0) {
      RtspServer.sessions.splice(i, 1);
    }
  }

  static getSpsNalu(cam: number): Uint8Array | null {
    return cam >= 0 && cam < MAX_CAMS ? spsNalus[cam] : null;
  }

  static getPpsNalu(cam: number): Uint8Array | null {
    return cam >= 0 && cam < MAX_CAMS ? ppsNalus[cam] : null;
  }

  static sdp(cam: number): string {
    const ip = lanAddress();
    const sps = RtspServer.getSpsNalu(cam);
    const pps = RtspServer.getPpsNalu(cam);
    let sprop = '';
    let profile = '42C01F';
    if (sps !== null && pps !== null) {
      sprop = `sprop-parameter-sets=${b64(sps)},${b64(pps)};`;
      if (sps.length >= 4) {
        const hex = (v: number) => v.toString(16).toUpperCase().padStart(2, '0');
        profile = hex(sps[1]) + hex(sps[2]) + hex(sps[3]);
      }
    }
    return `v=0\r\n` +
      `o=- 0 0 IN IP4 ${ip}\r\n` +
      `s=ohos-ipcam cam${cam}\r\n` +
      `t=0 0\r\n` +
      `m=video 0 RTP/AVP ${PAYLOAD_TYPE}\r\n` +
      `a=rtpmap:${PAYLOAD_TYPE} H264/90000\r\n` +
      `a=fmtp:${PAYLOAD_TYPE} packetization-mode=1;${sprop}profile-level-id=${profile}\r\n` +
      `a=control:rtsp://${ip}:${RTSP_PORT}/cam${cam}\r\n`;
  }
}
