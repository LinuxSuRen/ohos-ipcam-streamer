import socket from '@ohos.net.socket';
import hilog from '@ohos.hilog';
import util from '@ohos.util';
import { lanAddress } from '../net/NetUtil';
import { JpegSource } from '../net/JpegSource';
import { FrameHub } from '../net/FrameHub';
import { CamRegistry } from '../net/CamRegistry';
import { RtspServer } from '../rtsp/RtspServer';
import { CrashGuard } from '../entryability/CrashGuard';
import { deviceModel, deviceOs } from '../entryability/DeviceIdentity';

const DOMAIN = 0x080C;
const TAG = 'ipcam.HttpServer';
const HTTP_PORT = 8090;
const BOUNDARY = 'ipcamframe';
/** MJPEG 流发送间隔(每客户端)与 JPEG 复用有效期 */
const STREAM_INTERVAL_MS = 150;
const JPEG_CACHE_MS = 200;
const SNAPSHOT_CACHE_MS = 400;

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

function utf8(s: string): ArrayBuffer {
  const encoder = new util.TextEncoder();
  return encoder.encodeInto(s).buffer as ArrayBuffer;
}

/** 从 "/snapshot.jpg?cam=1" 之类路径解析相机编号(缺省 0;非法返回 -1)。 */
function cameraOfPath(path: string): number {
  const q = path.indexOf('?');
  if (q < 0) {
    return 0;
  }
  for (const kv of path.substring(q + 1).split('&')) {
    if (kv.startsWith('cam=')) {
      const n = parseInt(kv.substring(4).trim());
      if (isNaN(n) || n < 0 || n >= 4) {
        return -1;
      }
      return n;
    }
  }
  return 0;
}

/**
 * 极简 HTTP 服务(参照 tv-uvc-streamer MjpegServer,多摄像头):
 * - /            状态页(设备信息、各相机入口与统计、上次崩溃)
 * - /snapshot.jpg?cam=N 最新单帧 JPEG
 * - /stream?cam=N      multipart/x-mixed-replace MJPEG 流(浏览器直接看)
 */
export class HttpServer {
  private static server: socket.TCPSocketServer | null = null;
  private static conns: HttpConnection[] = [];

  static port(): number {
    return HTTP_PORT;
  }

  static async start(): Promise<void> {
    if (HttpServer.server !== null) {
      return;
    }
    const server = socket.constructTCPSocketServerInstance();
    server.on('connect', (client: socket.TCPSocketConnection) => {
      const conn = new HttpConnection(client);
      HttpServer.conns.push(conn);
      hilog.info(DOMAIN, TAG, 'http client connected, total=%{public}d', HttpServer.conns.length);
    });
    const listenOpt: socket.NetAddress = { address: '0.0.0.0', port: HTTP_PORT };
    await server.listen(listenOpt);
    HttpServer.server = server;
    hilog.info(DOMAIN, TAG, 'http listening on %{public}d', HTTP_PORT);
  }

  static async stop(): Promise<void> {
    for (const c of HttpServer.conns) {
      c.close();
    }
    HttpServer.conns = [];
    if (HttpServer.server !== null) {
      try {
        await HttpServer.server.close();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'server close');
      }
      HttpServer.server = null;
    }
    hilog.info(DOMAIN, TAG, 'http stopped');
  }

  static connectionCount(): number {
    let live = 0;
    for (const c of HttpServer.conns) {
      if (!c.isDead()) {
        live++;
      }
    }
    return live;
  }

  static remove(conn: HttpConnection): void {
    const i = HttpServer.conns.indexOf(conn);
    if (i >= 0) {
      HttpServer.conns.splice(i, 1);
    }
  }
}

/** 单个 HTTP 连接:解析请求行 → 路由 → 响应。 */
class HttpConnection {
  private readonly conn: socket.TCPSocketConnection;
  private buf: string = '';
  private dead: boolean = false;
  private streaming: boolean = false;
  private sendChain: Promise<void> = Promise.resolve();

  constructor(conn: socket.TCPSocketConnection) {
    this.conn = conn;
    this.conn.on('message', (info: socket.SocketMessageInfo) => {
      this.onMessage(info);
    });
    this.conn.on('close', () => {
      this.dead = true;
      HttpServer.remove(this);
    });
    this.conn.on('error', () => {
      this.dead = true;
      HttpServer.remove(this);
    });
  }

  isDead(): boolean {
    return this.dead;
  }

  private onMessage(info: socket.SocketMessageInfo): void {
    if (this.streaming) {
      return;
    }
    this.buf += ab2str(info.message);
    if (this.buf.length > 16384) {
      this.respondSimple(431, 'text/plain', 'header too large');
      this.flushClose();
      return;
    }
    const idx = this.buf.indexOf('\r\n\r\n');
    if (idx < 0) {
      return;
    }
    const head = this.buf.substring(0, idx);
    this.buf = '';
    const reqLine = head.split('\r\n')[0].split(' ');
    if (reqLine.length < 2 || reqLine[0] !== 'GET') {
      this.respondSimple(405, 'text/plain', 'method not allowed');
      this.flushClose();
      return;
    }
    const path = reqLine[1];
    const clean = path.split('?')[0];
    const cam = cameraOfPath(path);
    hilog.info(DOMAIN, TAG, 'GET %{public}s', path);
    if (cam < 0 || CamRegistry.get(cam) === null) {
      this.respondSimple(404, 'text/plain', `camera ${cam} not streaming`);
      this.flushClose();
      return;
    }
    if (clean === '/snapshot.jpg') {
      this.serveSnapshot(cam);
    } else if (clean === '/stream') {
      this.serveStream(cam);
    } else if (clean === '/' || clean === '/index.html' || clean === '') {
      this.serveStatus();
    } else {
      this.respondSimple(404, 'text/plain', 'not found');
      this.flushClose();
    }
  }

  /** 单帧快照:短缓存,多请求合流;相机刚打开时等首帧。 */
  private async serveSnapshot(cam: number): Promise<void> {
    let sent = false;
    let lastMsg = '';
    /* 相机刚启动或自愈重开后首帧需要片刻,最多等 8s */
    for (let i = 0; i < 27 && !sent && !this.dead; i++) {
      try {
        const jpeg = await JpegSource.jpeg(cam, SNAPSHOT_CACHE_MS);
        this.send(`HTTP/1.0 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.byteLength}\r\nConnection: close\r\n\r\n`);
        this.sendRaw(jpeg);
        sent = true;
      } catch (e) {
        const msg = e instanceof Error ? e.message : JSON.stringify(e);
        if (msg !== lastMsg) {
          hilog.warn(DOMAIN, TAG, 'snapshot cam%{public}d iter%{public}d: %{public}s', cam, i, msg);
          lastMsg = msg;
        }
        await this.sleep(300);
      }
    }
    if (!sent) {
      this.respondSimple(503, 'text/plain', `no frame yet: ${lastMsg}`);
    }
    this.flushClose();
  }

  /** multipart MJPEG 流:按固定间隔取 JPEG 并推送,断连即停。 */
  private async serveStream(cam: number): Promise<void> {
    this.streaming = true;
    this.send(`HTTP/1.0 200 OK\r\nContent-Type: multipart/x-mixed-replace;boundary=${BOUNDARY}\r\n\r\n`);
    while (!this.dead) {
      try {
        const jpeg = await JpegSource.jpeg(cam, JPEG_CACHE_MS);
        this.send(`--${BOUNDARY}\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.byteLength}\r\n\r\n`);
        this.sendRaw(jpeg);
        this.send('\r\n');
      } catch (e) {
        /* 帧尚未就绪:稍后重试 */
      }
      await this.sleep(STREAM_INTERVAL_MS);
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((res) => {
      setTimeout(() => {
        res();
      }, ms);
    });
  }

  /** 状态页:设备信息 + 各相机推流地址 + 实时统计 + 上次崩溃。 */
  private serveStatus(): void {
    const ip = lanAddress();
    const crash = CrashGuard.peek();
    let html = `<html><head><meta charset='utf-8'><title>ohos-ipcam-streamer</title></head>` +
      `<body style='font-family:monospace;background:#111;color:#eee;padding:2em'>` +
      `<h2>ohos-ipcam-streamer</h2>` +
      `<p>device: ${deviceModel()} (${deviceOs()})</p>` +
      `<p>rtsp clients=${RtspServer.sessionCount()}</p>` +
      `<p><a style='color:#8cf' href='http://${ip}:8000/onvif/device_service'>onvif</a></p>`;
    for (const c of CamRegistry.list()) {
      const suffix = c.index === 0 ? '' : `?cam=${c.index}`;
      html += `<h3>${c.label} (cam${c.index})</h3>` +
        `<p>${c.outW}x${c.outH}@${c.fps} | ${FrameHub.stats(c.index)} fps=${FrameHub.fps(c.index)}</p>` +
        `<p><a style='color:#8cf' href='rtsp://${ip}:8554/cam${c.index}'>rtsp://${ip}:8554/cam${c.index}</a>` +
        ` · <a style='color:#8cf' href='/stream${suffix}'>/stream${suffix}</a>` +
        ` · <a style='color:#8cf' href='/snapshot.jpg${suffix}'>/snapshot.jpg${suffix}</a></p>` +
        `<p><img src='/snapshot.jpg${suffix}' width='480'></p>`;
    }
    if (crash !== null) {
      html += `<h3 style='color:#f66'>last crash</h3><pre style='color:#f88'>${crash
        .replace(/&/g, '&amp;').replace(/</g, '&lt;')}</pre>`;
    }
    html += `</body></html>`;
    const body = utf8(html);
    this.send(`HTTP/1.0 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${body.byteLength}\r\nConnection: close\r\n\r\n`);
    this.sendRaw(body);
    this.flushClose();
  }

  private respondSimple(code: number, type: string, text: string): void {
    const body = utf8(text);
    this.send(`HTTP/1.0 ${code} \r\nContent-Type: ${type}\r\nContent-Length: ${body.byteLength}\r\nConnection: close\r\n\r\n`);
    this.sendRaw(body);
  }

  private send(s: string): void {
    this.sendRaw(str2ab(s));
  }

  /** 串行化发送(与 RtspSession 同法):保证 TCP 流内字节有序。 */
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
      HttpServer.remove(this);
    });
  }

  /** 把关闭动作挂到发送链尾:确保已入队字节全部写出后再断连。 */
  private flushClose(): void {
    const conn = this.conn;
    this.sendChain = this.sendChain.then((): Promise<void> => {
      this.dead = true;
      return conn.close();
    }).catch(() => {
      this.dead = true;
    });
  }

  close(): void {
    this.dead = true;
    try {
      this.conn.close();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'close');
    }
  }
}
