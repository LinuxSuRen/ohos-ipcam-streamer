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
  private static audioReady: boolean = false;
  private static g711Ready: boolean = false;

  static setAudioEnabled(enabled: boolean): void {
    RtspServer.audioReady = enabled;
  }

  static isAudioEnabled(): boolean {
    return RtspServer.audioReady;
  }

  static setG711Enabled(enabled: boolean): void {
    RtspServer.g711Ready = enabled;
  }

  static isG711Enabled(): boolean {
    return RtspServer.g711Ready;
  }

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

  /** 音频帧分发(AAC 裸帧):只投给经 SETUP 协商了音频轨道(trackID=1)的会话。 */
  static broadcastAudio(frame: ArrayBuffer): void {
    if (!RtspServer.audioReady) {
      return;
    }
    for (const s of RtspServer.sessions) {
      s.onAudioFrame(frame);
    }
  }

  /** G.711 PCMA 帧分发:只投给经 SETUP trackID=2 协商的会话。 */
  static broadcastG711(frame: ArrayBuffer): void {
    if (!RtspServer.g711Ready) {
      return;
    }
    for (const s of RtspServer.sessions) {
      s.onG711Frame(frame);
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
    let sdp = `v=0\r\n` +
      `o=- 0 0 IN IP4 ${ip}\r\n` +
      `s=ohos-ipcam cam${cam}\r\n` +
      `t=0 0\r\n` +
      `m=video 0 RTP/AVP ${PAYLOAD_TYPE}\r\n` +
      `a=rtpmap:${PAYLOAD_TYPE} H264/90000\r\n` +
      `a=fmtp:${PAYLOAD_TYPE} packetization-mode=1;${sprop}profile-level-id=${profile}\r\n` +
      `a=control:trackID=0\r\n`;
    if (RtspServer.audioReady) {
      /* AAC 音轨:客户端经 SETUP trackID=1 协商接收(不 SETUP 则无音频),
       * MPEG4-GENERIC AAC-hbr,config=1190 即 AAC-LC 48000 立体声 ASC */
      sdp += `m=audio 0 RTP/AVP 97\r\n` +
        `a=rtpmap:97 MPEG4-GENERIC/48000/2\r\n` +
        `a=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;` +
        `sizelength=13;indexlength=3;indexdeltalength=3;config=1190\r\n` +
        `a=control:trackID=1\r\n`;
    }
    if (RtspServer.g711Ready) {
      /* G.711 A-law 音轨:ONVIF 生态事实标准,8kHz/单声道 20ms 一包,
       * 静态载荷类型 8(PCMA);客户端经 SETUP trackID=2 协商接收 */
      sdp += `m=audio 0 RTP/AVP 8\r\n` +
        `a=rtpmap:8 PCMA/8000/1\r\n` +
        `a=control:trackID=2\r\n`;
    }
    /* 对讲回传通道:a=sendonly(G.711 PCMA,ONVIF backchannel 惯例,
     * gortsplib 以 sendonly 识别回传轨);客户端 SETUP trackID=3 后
     * 经 interleaved 通道 6 推 RTP,本端解码后从扬声器播放 */
    sdp += `m=audio 0 RTP/AVP 8\r\n` +
      `a=sendonly\r\n` +
      `a=rtpmap:8 PCMA/8000/1\r\n` +
      `a=control:trackID=3\r\n`;
    return sdp;
  }
}
