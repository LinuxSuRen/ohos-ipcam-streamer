/**
 * H.264 RTP 打包(RFC 6184):
 * - 单 NALU ≤ MTU 直接封装
 * - 超长 NALU 分片为 FU-A
 * 对应 Android 版 RtspServer 的 RFC 2435 JPEG 打包角色。
 */
const MTU = 1400;

export class RtpPacketizer {
  private seq: number;
  private readonly ssrc: number;

  constructor() {
    this.seq = Math.floor(Math.random() * 65535) & 0xffff;
    this.ssrc = Math.floor(Math.random() * 0xffffffff) >>> 0;
  }

  currentSeq(): number {
    return this.seq;
  }

  packetize(nalu: Uint8Array, ts: number, marker: boolean): Uint8Array[] {
    if (nalu.length <= MTU) {
      return [this.single(nalu, ts, marker)];
    }
    const pkts: Uint8Array[] = [];
    const maxPayload = MTU - 12 - 2;
    const indicator = (nalu[0] & 0xe0) | 28;
    let off = 1;
    let remain = nalu.length - 1;
    let first = true;
    while (remain > 0) {
      const size = Math.min(remain, maxPayload);
      const last = remain - size <= 0;
      const fuHeader = (first ? 0x80 : 0x00) | (last ? 0x40 : 0x00) | (nalu[0] & 0x1f);
      const pkt = new Uint8Array(12 + 2 + size);
      this.fillHeader(pkt, ts, marker && last);
      pkt[12] = indicator;
      pkt[13] = fuHeader;
      pkt.set(nalu.subarray(off, off + size), 14);
      pkts.push(pkt);
      off += size;
      remain -= size;
      first = false;
    }
    return pkts;
  }

  private single(nalu: Uint8Array, ts: number, marker: boolean): Uint8Array {
    const pkt = new Uint8Array(12 + nalu.length);
    this.fillHeader(pkt, ts, marker);
    pkt.set(nalu, 12);
    return pkt;
  }

  private fillHeader(pkt: Uint8Array, ts: number, marker: boolean): void {
    this.seq = (this.seq + 1) & 0xffff;
    pkt[0] = 0x80;
    pkt[1] = 96 | (marker ? 0x80 : 0x00);
    pkt[2] = (this.seq >> 8) & 0xff;
    pkt[3] = this.seq & 0xff;
    pkt[4] = (ts >>> 24) & 0xff;
    pkt[5] = (ts >>> 16) & 0xff;
    pkt[6] = (ts >>> 8) & 0xff;
    pkt[7] = ts & 0xff;
    pkt[8] = (this.ssrc >>> 24) & 0xff;
    pkt[9] = (this.ssrc >>> 16) & 0xff;
    pkt[10] = (this.ssrc >>> 8) & 0xff;
    pkt[11] = this.ssrc & 0xff;
  }

  /** 音频 RTP(MPEG4-GENERIC,PT=97,marker=1):向 pkt 前 12 字节填头。 */
  fillAudio(pkt: Uint8Array, ts: number): void {
    this.seq = (this.seq + 1) & 0xffff;
    pkt[0] = 0x80;
    pkt[1] = 97 | 0x80;
    pkt[2] = (this.seq >> 8) & 0xff;
    pkt[3] = this.seq & 0xff;
    pkt[4] = (ts >>> 24) & 0xff;
    pkt[5] = (ts >>> 16) & 0xff;
    pkt[6] = (ts >>> 8) & 0xff;
    pkt[7] = ts & 0xff;
    pkt[8] = (this.ssrc >>> 24) & 0xff;
    pkt[9] = (this.ssrc >>> 16) & 0xff;
    pkt[10] = (this.ssrc >>> 8) & 0xff;
    pkt[11] = this.ssrc & 0xff;
  }
}

/** 按起始码(00 00 01 / 00 00 00 01)把一帧 Annex-B 拆成 NALU 列表。
 * 注意:末个 NALU 必须完整吃到帧尾(无下一起始码时 end = n),
 * 否则每帧尾部丢字节导致 slice 解码损坏。 */
export function splitAnnexB(frame: Uint8Array): Uint8Array[] {
  const nalus: Uint8Array[] = [];
  const n = frame.length;
  let i = 0;
  while (i < n - 2) {
    if (frame[i] === 0 && frame[i + 1] === 0 && frame[i + 2] === 1) {
      const start = i + 3;
      let j = start;
      let found = false;
      while (j + 2 < n) {
        if (frame[j] === 0 && frame[j + 1] === 0 && frame[j + 2] === 1) {
          found = true;
          break;
        }
        j++;
      }
      const end = found ? j : n;
      if (end > start) {
        nalus.push(frame.subarray(start, end));
      }
      i = found ? j : n;
    } else {
      i++;
    }
  }
  return nalus;
}
