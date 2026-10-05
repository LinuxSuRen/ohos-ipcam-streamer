import socket from '@ohos.net.socket';
import hilog from '@ohos.hilog';
import { RtspSession } from './RtspSession';
import { lanAddress } from '../net/NetUtil';

const DOMAIN = 0x0807;
const TAG = 'ipcam.RtspServer';
const RTSP_PORT = 8554;
const PAYLOAD_TYPE = 96;

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

/** 裸 SPS/PPS NALU(去起始码),由 FrameHub 从码流拆出。 */
let spsNalu: Uint8Array | null = null;
let ppsNalu: Uint8Array | null = null;

export function setParameterSets(sps: Uint8Array | null, pps: Uint8Array | null): void {
  if (sps !== null && spsNalu === null) {
    spsNalu = sps;
    hilog.info(DOMAIN, TAG, 'SPS nalu %{public}d bytes', sps.length);
  }
  if (pps !== null && ppsNalu === null) {
    ppsNalu = pps;
    hilog.info(DOMAIN, TAG, 'PPS nalu %{public}d bytes', pps.length);
  }
}

export function resetParameterSets(): void {
  spsNalu = null;
  ppsNalu = null;
}

/**
 * RTSP 服务器(:8554)。多客户端会话,帧广播。
 * DESCRIBE 的 SDP 动态携带 sprop-parameter-sets(无 SPS 时回退 profile-level-id)。
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

  /** FrameHub 广播入口。 */
  static broadcast(frame: ArrayBuffer, keyframe: boolean): void {
    for (const s of RtspServer.sessions) {
      s.onFrame(frame, keyframe);
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

  static getSpsNalu(): Uint8Array | null {
    return spsNalu;
  }

  static getPpsNalu(): Uint8Array | null {
    return ppsNalu;
  }

  static sdp(): string {
    const ip = lanAddress();
    let sprop = '';
    let profile = '42C01F';
    if (spsNalu !== null && ppsNalu !== null) {
      sprop = `sprop-parameter-sets=${b64(spsNalu)},${b64(ppsNalu)};`;
      if (spsNalu.length >= 4) {
        const hex = (v: number) => v.toString(16).toUpperCase().padStart(2, '0');
        profile = hex(spsNalu[1]) + hex(spsNalu[2]) + hex(spsNalu[3]);
      }
    }
    return `v=0\r\n` +
      `o=- 0 0 IN IP4 ${ip}\r\n` +
      `s=ohos-ipcam\r\n` +
      `t=0 0\r\n` +
      `m=video 0 RTP/AVP ${PAYLOAD_TYPE}\r\n` +
      `a=rtpmap:${PAYLOAD_TYPE} H264/90000\r\n` +
      `a=fmtp:${PAYLOAD_TYPE} packetization-mode=1;${sprop}profile-level-id=${profile}\r\n` +
      `a=control:trackID=0\r\n`;
  }
}
