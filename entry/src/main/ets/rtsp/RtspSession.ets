import socket from '@ohos.net.socket';
import hilog from '@ohos.hilog';
import { RtpPacketizer, splitAnnexB } from './RtpPacketizer';
import { RtspServer, cameraOfUrl } from './RtspServer';
import { CamRegistry } from '../net/CamRegistry';
import { speakerWritePCMA } from 'libh264enc.so';

const DOMAIN = 0x0806;
const TAG = 'ipcam.RtspSession';

function ab2str(ab: ArrayBuffer): string {
  const u8 = new Uint8Array(ab);
  let s = '';
  for (let i = 0; i < u8.length; i++) {
    s += String.fromCharCode(u8[i]);
  }
  return s;
}

function str2ab(s: string): ArrayBuffer {
  const ab = new ArrayBuffer(s.length);
  const u8 = new Uint8Array(ab);
  for (let i = 0; i < s.length; i++) {
    u8[i] = s.charCodeAt(i) & 0xff;
  }
  return ab;
}

/**
 * 单个 RTSP 连接(TCP interleaved 模式):
 * OPTIONS / DESCRIBE / SETUP / PLAY / TEARDOWN 状态机,
 * URL 决定订阅的相机(/camN);PLAY 后该相机编码帧经
 * RTP(RFC 6184)以 $ 帧封装回写同一 TCP 连接。
 */
export class RtspSession {
  private readonly conn: socket.TCPSocketConnection;
  private readonly packetizer: RtpPacketizer;
  private readonly fps: number;
  private buf: string = '';
  private playing: boolean = false;
  private sessionId: string = '';
  private sessionUrl: string = '';
  private dead: boolean = false;
  private waitKey: boolean = true;
  private camera: number = 0;
  private audioSetUp: boolean = false;
  private g711SetUp: boolean = false;
  private backSetUp: boolean = false;
  private audioPkt: RtpPacketizer;
  private g711Pkt: RtpPacketizer;
  private audioSamples: number = 0;
  private g711Samples: number = 0;
  private epoch: number = 0;
  private lastTs: number = -1;
  private sendChain: Promise<void> = Promise.resolve();

  constructor(conn: socket.TCPSocketConnection, fps: number) {
    this.conn = conn;
    this.fps = fps > 0 ? fps : 25;
    this.packetizer = new RtpPacketizer();
    this.audioPkt = new RtpPacketizer();
    this.g711Pkt = new RtpPacketizer();
    this.sessionId = String(Math.floor(Math.random() * 900000) + 100000);
  }

  start(): void {
    this.conn.on('message', (info: socket.SocketMessageInfo) => {
      this.buf += ab2str(info.message);
      this.tryParse();
    });
    // 注:对讲回传的 RTP 以二进制 $ 帧混在控制连接上,tryParse 已做字节级识别
    this.conn.on('close', () => {
      this.dead = true;
      RtspServer.remove(this);
    });
    this.conn.on('error', () => {
      this.dead = true;
      RtspServer.remove(this);
    });
  }

  private tryParse(): void {
    /* 缓冲区头部若是 '$'(0x24)则为二进制 interleaved 帧(对讲回传),
     * 字符串按 Latin-1 字节语义拼接,长度即字节数 */
    while (this.buf.length > 0 && this.buf.charCodeAt(0) === 0x24) {
      if (this.buf.length < 4) {
        return;
      }
      const ch = this.buf.charCodeAt(1);
      const len = (this.buf.charCodeAt(2) << 8) | this.buf.charCodeAt(3);
      if (this.buf.length < 4 + len) {
        return;
      }
      if (ch === 6) {
        /* 回传通道 6 的 RTP:去 12 字节头后载荷为 PCMA */
        const pkt = this.buf.substring(4, 4 + len);
        this.onBackchannelRtp(pkt);
      }
      this.buf = this.buf.substring(4 + len);
    }
    let idx = this.buf.indexOf('\r\n\r\n');
    while (idx >= 0) {
      const head = this.buf.substring(0, idx);
      this.buf = this.buf.substring(idx + 4);
      this.handleRequest(head);
      /* 文本请求间也可能夹二进制帧 */
      while (this.buf.length > 0 && this.buf.charCodeAt(0) === 0x24) {
        if (this.buf.length < 4) {
          return;
        }
        const ch2 = this.buf.charCodeAt(1);
        const len2 = (this.buf.charCodeAt(2) << 8) | this.buf.charCodeAt(3);
        if (this.buf.length < 4 + len2) {
          return;
        }
        if (ch2 === 6) {
          const pkt2 = this.buf.substring(4, 4 + len2);
          this.onBackchannelRtp(pkt2);
        }
        this.buf = this.buf.substring(4 + len2);
      }
      idx = this.buf.indexOf('\r\n\r\n');
    }
  }

  /** 对讲回传 RTP(载荷 PCMA):RTP 头最小 12 字节,取载荷送扬声器。 */
  private onBackchannelRtp(pkt: string): void {
    if (!this.backSetUp || this.dead || pkt.length <= 12) {
      return;
    }
    const cc = pkt.charCodeAt(0) & 0x0f;
    const ext = (pkt.charCodeAt(0) & 0x10) !== 0;
    let off = 12 + cc;
    if (ext) {
      if (pkt.length < off + 4) {
        return;
      }
      const extWords = ((pkt.charCodeAt(off + 2) << 8) | pkt.charCodeAt(off + 3)) & 0xffff;
      off += 4 + extWords * 4;
    }
    if (pkt.length <= off) {
      return;
    }
    const payload = pkt.substring(off);
    const ab = new ArrayBuffer(payload.length);
    const u8 = new Uint8Array(ab);
    for (let i = 0; i < payload.length; i++) {
      u8[i] = payload.charCodeAt(i) & 0xff;
    }
    try {
      speakerWritePCMA(ab);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'speaker write failed');
    }
  }

  private handleRequest(head: string): void {
    const lines = head.split('\r\n');
    if (lines.length === 0) {
      return;
    }
    const reqLine = lines[0].split(' ');
    if (reqLine.length < 2) {
      return;
    }
    const method = reqLine[0];
    const url = reqLine[1];
    let cseq = '0';
    for (let i = 1; i < lines.length; i++) {
      const kv = lines[i].split(':');
      if (kv.length >= 2 && kv[0].trim().toLowerCase() === 'cseq') {
        cseq = kv[1].trim();
      }
    }
    hilog.info(DOMAIN, TAG, '%{public}s %{public}s', method, url);
    switch (method) {
      case 'OPTIONS':
        this.send(`RTSP/1.0 200 OK\r\nCSeq: ${cseq}\r\nPublic: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN\r\n\r\n`);
        break;
      case 'DESCRIBE': {
        const cam = cameraOfUrl(url);
        if (CamRegistry.get(cam) === null) {
          this.send(`RTSP/1.0 404 Not Found\r\nCSeq: ${cseq}\r\n\r\n`);
          this.close();
          return;
        }
        this.camera = cam;
        const sdp = RtspServer.sdp(cam);
        this.send(`RTSP/1.0 200 OK\r\nCSeq: ${cseq}\r\nContent-Type: application/sdp\r\nContent-Length: ${sdp.length}\r\n\r\n${sdp}`);
        break;
      }
      case 'SETUP': {
        /* 仅支持 TCP interleaved;UDP 请求按 RFC 2326 回 461,
         * 让客户端(如 OpenCV 默认 UDP)明确知道应改用 TCP。 */
        let wantsTcp = false;
        for (let i = 1; i < lines.length; i++) {
          if (lines[i].split(':')[0].trim().toLowerCase() === 'transport') {
            wantsTcp = lines[i].indexOf('TCP') >= 0 || lines[i].indexOf('interleaved') >= 0;
            break;
          }
        }
        if (!wantsTcp) {
          this.send(`RTSP/1.0 461 Unsupported Transport\r\nCSeq: ${cseq}\r\n\r\n`);
          break;
        }
        this.camera = cameraOfUrl(url);
        this.sessionUrl = url;
        if (url.indexOf('trackID=3') >= 0) {
          /* 对讲回传轨:客户端 SETUP 后经 interleaved 6 向本端推音频 */
          this.backSetUp = true;
          this.send(`RTSP/1.0 200 OK\r\nCSeq: ${cseq}\r\nSession: ${this.sessionId}\r\nTransport: RTP/AVP/TCP;interleaved=6-7;ssrc=1A2B3C4A\r\n\r\n`);
        } else if (url.indexOf('trackID=2') >= 0) {
          /* G.711 音轨:客户端经 SETUP trackID=2 协商(interleaved 4-5) */
          this.g711SetUp = true;
          this.send(`RTSP/1.0 200 OK\r\nCSeq: ${cseq}\r\nSession: ${this.sessionId}\r\nTransport: RTP/AVP/TCP;interleaved=4-5;ssrc=1A2B3C4F\r\n\r\n`);
        } else if (url.indexOf('trackID=1') >= 0) {
          /* AAC 音轨:客户端经 SETUP 协商后才接收音频(interleaved 2-3) */
          this.audioSetUp = true;
          this.send(`RTSP/1.0 200 OK\r\nCSeq: ${cseq}\r\nSession: ${this.sessionId}\r\nTransport: RTP/AVP/TCP;interleaved=2-3;ssrc=1A2B3C4E\r\n\r\n`);
        } else {
          this.send(`RTSP/1.0 200 OK\r\nCSeq: ${cseq}\r\nSession: ${this.sessionId}\r\nTransport: RTP/AVP/TCP;interleaved=0-1;ssrc=1A2B3C4D\r\n\r\n`);
        }
        break;
      }
      case 'PLAY':
        if (CamRegistry.get(this.camera) === null) {
          this.send(`RTSP/1.0 404 Not Found\r\nCSeq: ${cseq}\r\n\r\n`);
          this.close();
          return;
        }
        this.playing = true;
        this.epoch = Date.now();
        this.lastTs = -1;
        this.send(`RTSP/1.0 200 OK\r\nCSeq: ${cseq}\r\nSession: ${this.sessionId}\r\nRTP-Info: url=${this.sessionUrl};seq=${(this.packetizer.currentSeq() + 1) & 0xffff};rtptime=0\r\n\r\n`);
        /* 接入即给参数集,客户端解码器无需依赖 SDP sprop */
        const ts0 = this.nextTs();
        this.sendParamSet(7, ts0);
        this.sendParamSet(8, ts0);
        this.waitKey = true;
        break;
      case 'TEARDOWN':
        this.playing = false;
        this.send(`RTSP/1.0 200 OK\r\nCSeq: ${cseq}\r\nSession: ${this.sessionId}\r\n\r\n`);
        this.close();
        break;
      default:
        this.send(`RTSP/1.0 501 Not Implemented\r\nCSeq: ${cseq}\r\n\r\n`);
    }
  }

  /** RtspServer 分发入口(按 cam 过滤):一帧 Annex-B → NALU 拆分 → RTP → 发送。 */
  onFrame(frame: ArrayBuffer, keyframe: boolean, cam: number): void {
    if (!this.playing || this.dead || cam !== this.camera) {
      return;
    }
    const nalus = splitAnnexB(new Uint8Array(frame));
    const ts = this.nextTs();
    for (let i = 0; i < nalus.length; i++) {
      const type = nalus[i][0] & 0x1f;
      if (type === 7 || type === 8) {
        continue;
      }
      if (type === 5) {
        /* 每个 IDR 前必补发参数集;编码器输出的 IDR 常不带 SPS/PPS。
         * 同一接入单元的 SPS/PPS/IDR 共享同一 RTP 时间戳(RFC 6184)。 */
        this.sendParamSet(7, ts);
        this.sendParamSet(8, ts);
        this.waitKey = false;
      } else if (this.waitKey) {
        continue; /* 新会话从关键帧起推,避免接入 P 参考链中间 */
      }
      const marker = i === nalus.length - 1;
      const pkts = this.packetizer.packetize(nalus[i], ts, marker);
      for (const p of pkts) {
        this.sendInterleaved(p);
      }
    }
  }

  /** 音频帧(AAC 裸帧,每 AU 1024 样本)→ RFC 3640 MPEG4-GENERIC RTP。
   * 只发给经 SETUP trackID=1 协商过音频的会话(interleaved 通道 2)。 */
  onAudioFrame(frame: ArrayBuffer): void {
    if (!this.playing || !this.audioSetUp || this.dead) {
      return;
    }
    const aac = new Uint8Array(frame);
    if (aac.length <= 0 || aac.length >= 8192) {
      return;
    }
    this.audioSamples += 1024;
    const pkt = new Uint8Array(12 + 2 + 2 + aac.length);
    /* RTP 头:PT=97,marker=1;时间戳为样本单位(44100Hz 时钟) */
    this.audioPkt.fillAudio(pkt, this.audioSamples & 0xffffffff, 97);
    /* AU-headers-length = 16(bit) */
    pkt[12] = 0x00;
    pkt[13] = 0x10;
    /* AU header:13 bit 大小 + 3 bit index = size<<3 */
    const au = aac.length << 3;
    pkt[14] = (au >> 8) & 0xff;
    pkt[15] = au & 0xff;
    pkt.set(aac, 16);
    const out = new Uint8Array(4 + pkt.length);
    out[0] = 0x24;
    out[1] = 2;
    out[2] = (pkt.length >> 8) & 0xff;
    out[3] = pkt.length & 0xff;
    out.set(pkt, 4);
    const ab: ArrayBuffer = new ArrayBuffer(out.length);
    new Uint8Array(ab).set(out);
    this.sendRaw(ab);
  }

  /** G.711 PCMA 帧(160 字节 = 20ms)→ RTP(PT 8,8kHz 样本时钟)。
   * 只发给经 SETUP trackID=2 协商过 G.711 的会话(interleaved 通道 4)。 */
  onG711Frame(frame: ArrayBuffer): void {
    if (!this.playing || !this.g711SetUp || this.dead) {
      return;
    }
    const pcma = new Uint8Array(frame);
    if (pcma.length <= 0 || pcma.length > 1024) {
      return;
    }
    this.g711Samples += pcma.length; /* 1 字节 = 1 样本(8kHz) */
    const pkt = new Uint8Array(12 + pcma.length);
    this.g711Pkt.fillAudio(pkt, this.g711Samples & 0xffffffff, 8);
    pkt.set(pcma, 12);
    const out = new Uint8Array(4 + pkt.length);
    out[0] = 0x24;
    out[1] = 4;
    out[2] = (pkt.length >> 8) & 0xff;
    out[3] = pkt.length & 0xff;
    out.set(pkt, 4);
    const ab: ArrayBuffer = new ArrayBuffer(out.length);
    new Uint8Array(ab).set(out);
    this.sendRaw(ab);
  }

  /** ts 跟随真实时钟,实际帧率与配置不符时播放速度仍正确;
   * 同毫秒多包时强制 +1,保证整个流(含参数集)严格单调递增。 */
  private nextTs(): number {
    let ts = ((Date.now() - this.epoch) * 90) & 0xffffffff;
    if (ts <= this.lastTs) {
      ts = (this.lastTs + 1) & 0xffffffff;
    }
    this.lastTs = ts;
    return ts;
  }

  private sendParamSet(naluType: number, ts: number): void {
    const ps = naluType === 7 ? RtspServer.getSpsNalu(this.camera) : RtspServer.getPpsNalu(this.camera);
    if (ps !== null) {
      const pkts = this.packetizer.packetize(ps, ts, false);
      for (const p of pkts) {
        this.sendInterleaved(p);
      }
    }
  }

  private sendInterleaved(pkt: Uint8Array): void {
    const out = new Uint8Array(4 + pkt.length);
    out[0] = 0x24;
    out[1] = 0;
    out[2] = (pkt.length >> 8) & 0xff;
    out[3] = pkt.length & 0xff;
    out.set(pkt, 4);
    const ab: ArrayBuffer = new ArrayBuffer(out.length);
    new Uint8Array(ab).set(out);
    this.sendRaw(ab);
  }

  private send(s: string): void {
    this.sendRaw(str2ab(s));
  }

  /**
   * 串行化发送:conn.send 异步且必须保序。
   * 并发调用会造成 TCP 流内 RTP 包乱序,客户端 seq 检测出现
   * "65533 packets lost" 式的回绕误报。用 promise 链保证逐包顺序。
   */
  private sendRaw(data: ArrayBuffer): void {
    if (this.dead) {
      return;
    }
    const opt: socket.TCPSendOptions = { data: data };
    this.sendChain = this.sendChain.then((): Promise<void> => {
      if (this.dead) {
        return Promise.resolve();
      }
      return this.conn.send(opt);
    }).catch(() => {
      this.dead = true;
      RtspServer.remove(this);
    });
  }

  close(): void {
    this.dead = true;
    this.playing = false;
    try {
      this.conn.close();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'close');
    }
  }

  isDead(): boolean {
    return this.dead;
  }
}
