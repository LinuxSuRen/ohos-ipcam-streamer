import socket from '@ohos.net.socket';
import hilog from '@ohos.hilog';
import { RtpPacketizer, splitAnnexB } from './RtpPacketizer';
import { RtspServer } from './RtspServer';

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
 * PLAY 后编码帧经 RTP(RFC 6184)以 $ 帧封装回写同一 TCP 连接。
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
  private epoch: number = 0;
  private lastTs: number = -1;
  private sendChain: Promise<void> = Promise.resolve();

  constructor(conn: socket.TCPSocketConnection, fps: number) {
    this.conn = conn;
    this.fps = fps > 0 ? fps : 25;
    this.packetizer = new RtpPacketizer();
    this.sessionId = String(Math.floor(Math.random() * 900000) + 100000);
  }

  start(): void {
    this.conn.on('message', (info: socket.SocketMessageInfo) => {
      this.buf += ab2str(info.message);
      this.tryParse();
    });
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
    let idx = this.buf.indexOf('\r\n\r\n');
    while (idx >= 0) {
      const head = this.buf.substring(0, idx);
      this.buf = this.buf.substring(idx + 4);
      this.handleRequest(head);
      idx = this.buf.indexOf('\r\n\r\n');
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
      case 'DESCRIBE':
        this.send(`RTSP/1.0 200 OK\r\nCSeq: ${cseq}\r\nContent-Type: application/sdp\r\nContent-Length: ${RtspServer.sdp().length}\r\n\r\n${RtspServer.sdp()}`);
        break;
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
        this.sessionUrl = url;
        this.send(`RTSP/1.0 200 OK\r\nCSeq: ${cseq}\r\nSession: ${this.sessionId}\r\nTransport: RTP/AVP/TCP;interleaved=0-1;ssrc=1A2B3C4D\r\n\r\n`);
        break;
      }
      case 'PLAY':
        this.playing = true;
        this.epoch = Date.now();
        this.send(`RTSP/1.0 200 OK\r\nCSeq: ${cseq}\r\nSession: ${this.sessionId}\r\nRTP-Info: url=${this.sessionUrl};seq=${(this.packetizer.currentSeq() + 1) & 0xffff};rtptime=0\r\n\r\n`);
        /* 接入即给参数集,客户端解码器无需依赖 SDP sprop */
        this.sendParamSet(7);
        this.sendParamSet(8);
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

  /** FrameHub 分发入口:一帧 Annex-B → NALU 拆分 → RTP → interleaved 发送。 */
  onFrame(frame: ArrayBuffer, keyframe: boolean): void {
    if (!this.playing || this.dead) {
      return;
    }
    const nalus = splitAnnexB(new Uint8Array(frame));
    /* ts 跟随真实时钟,实际帧率与配置不符时播放速度仍正确;
     * 同毫秒多帧时强制 +1,保证单调递增 */
    let ts = ((Date.now() - this.epoch) * 90) & 0xffffffff;
    if (ts <= this.lastTs) {
      ts = (this.lastTs + 1) & 0xffffffff;
    }
    this.lastTs = ts;
    for (let i = 0; i < nalus.length; i++) {
      const type = nalus[i][0] & 0x1f;
      if (type === 7 || type === 8) {
        continue;
      }
      if (type === 5) {
        /* 每个 IDR 前必补发参数集;编码器输出的 IDR 常不带 SPS/PPS */
        this.sendParamSet(7);
        this.sendParamSet(8);
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

  private sendParamSet(naluType: number): void {
    const ps = naluType === 7 ? RtspServer.getSpsNalu() : RtspServer.getPpsNalu();
    if (ps !== null) {
      const ts = ((Date.now() - this.epoch) * 90) & 0xffffffff;
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
