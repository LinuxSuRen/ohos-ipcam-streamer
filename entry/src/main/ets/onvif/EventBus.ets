import hilog from '@ohos.hilog';

const DOMAIN = 0x080E;
const TAG = 'ipcam.EventBus';

/**
 * ONVIF Event 服务核心（PullPoint 订阅模型，ONVIF Core §Events）。
 *
 * 与 tv-uvc-streamer 的 OnvifEventBus / local-onvif-adapter 的 eventBus 同款设计：
 * - 订阅：CreatePullPointSubscription 创建，返回独立 PullPoint 地址（/onvif/sub_N）
 * - 拉取：PullMessages 阻塞至 Timeout 或有消息；pull 把订阅 TTL 顺延到
 *   「请求到达+Timeout」（规范要求）
 * - 限频：同 topic+source 只抑制「相同载荷」的重复（2s 窗口）——
 *   状态交替（SignalLoss false→true）载荷不同必须放行
 * - 缓冲：每订阅环形队列（100 条）溢出丢最旧
 * - 无人订阅不缓存（新订阅不补发历史）
 */
export class EventBus {
  private static subs: Map<string, Sub> = new Map();
  private static seq: number = 0;
  private static lastPub: Map<string, PubRecord> = new Map();
  private static readonly QUEUE_CAP = 100;
  private static readonly PUB_MIN_GAP_MS = 2000;
  private static readonly DEFAULT_TTL_MS = 60000;

  /** 创建订阅，返回 id（PullPoint URL 最后一段） */
  static create(ttlMs: number): string {
    EventBus.expire();
    const id = `sub_${++EventBus.seq}`;
    const ttl = ttlMs > 0 ? ttlMs : EventBus.DEFAULT_TTL_MS;
    EventBus.subs.set(id, new Sub(id, ttl));
    return id;
  }

  /** 阻塞拉取：至多等 waitMs，凑满 limit 条返回渲染 XML；订阅过期返回 null */
  static pull(id: string, waitMs: number, limit: number): string | null {
    if (waitMs < 0) waitMs = 0;
    if (waitMs > 60000) waitMs = 60000;
    if (limit <= 0) limit = 5;
    const deadline = Date.now() + waitMs;
    const sub = EventBus.subs.get(id);
    if (!sub) return null;
    sub.deadline = Math.max(sub.deadline, Date.now() + Math.max(waitMs, 5000));
    while (sub.queue.length === 0 && Date.now() < deadline) {
      // ArkTS 无条件变量，用 sleep 轮询（200ms 粒度，与 Java 版 LOCK.wait(200) 等效）
      let ms = Math.min(200, deadline - Date.now());
      let start = Date.now();
      while (Date.now() - start < ms) {
        // 忙等（ArkTS 无 Thread.sleep，用微任务让出）
      }
      if (EventBus.subs.get(id) !== sub) return null;
    }
    let out = '';
    const n = Math.min(limit, sub.queue.length);
    for (let i = 0; i < n; i++) out += sub.queue.shift();
    return out;
  }

  /** 续期 */
  static renew(id: string, ttlMs: number): boolean {
    const sub = EventBus.subs.get(id);
    if (!sub) return false;
    sub.deadline = Date.now() + (ttlMs > 0 ? ttlMs : EventBus.DEFAULT_TTL_MS);
    return true;
  }

  /** 退订 */
  static unsubscribe(id: string): void {
    EventBus.subs.delete(id);
  }

  /** 发布事件（全局限频：相同载荷 2s 内合并，载荷变化放行） */
  static publish(topic: string, source: [string, string][], data: [string, string][]): void {
    const key = topic + '|' + (source.length > 0 ? source[0][1] : '');
    const fp = EventBus.fingerprint(topic, source, data);
    const now = Date.now();
    const last = EventBus.lastPub.get(key);
    if (last && now - last.at < EventBus.PUB_MIN_GAP_MS && last.fp === fp) return;
    EventBus.lastPub.set(key, { at: now, fp: fp });
    if (EventBus.subs.size === 0) return;
    const xml = EventBus.render(topic, source, data);
    for (const sub of EventBus.subs.values()) {
      if (sub.queue.length >= EventBus.QUEUE_CAP) sub.queue.shift();
      sub.queue.push(xml);
    }
    hilog.debug(DOMAIN, TAG, 'publish %{public}s', topic);
  }

  private static expire(): void {
    const now = Date.now();
    for (const [id, sub] of EventBus.subs) {
      if (sub.deadline < now) EventBus.subs.delete(id);
    }
  }

  private static fingerprint(topic: string, source: [string, string][], data: [string, string][]): string {
    let s = topic;
    for (const [k, v] of source) s += `|${k}=${v}`;
    for (const [k, v] of data) s += `|${k}=${v}`;
    return s;
  }

  /** 渲染为 wsnt:NotificationMessage 片段 */
  private static render(topic: string, source: [string, string][], data: [string, string][]): string {
    let s = '<wsnt:NotificationMessage>';
    s += `<wsnt:Topic Dialect="http://www.onvif.org/ver10/tev/topicExpression/ConcreteSet">${EventBus.esc(topic)}</wsnt:Topic>`;
    s += `<wsnt:Message><tt:Message UtcTime="${EventBus.utcNow()}" PropertyOperation="Changed">`;
    if (source.length > 0) {
      s += '<tt:Source>';
      for (const [k, v] of source) s += `<tt:SimpleItem Name="${EventBus.esc(k)}" Value="${EventBus.esc(v)}"/>`;
      s += '</tt:Source>';
    }
    if (data.length > 0) {
      s += '<tt:Data>';
      for (const [k, v] of data) s += `<tt:SimpleItem Name="${EventBus.esc(k)}" Value="${EventBus.esc(v)}"/>`;
      s += '</tt:Data>';
    }
    return s + '</tt:Message></wsnt:Message></wsnt:NotificationMessage>';
  }

  private static esc(s: string): string {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  private static utcNow(): string {
    const d = new Date();
    return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}T${String(d.getUTCHours()).padStart(2, '0')}:${String(d.getUTCMinutes()).padStart(2, '0')}:${String(d.getUTCSeconds()).padStart(2, '0')}Z`;
  }
}

class Sub {
  id: string;
  deadline: number;
  queue: string[] = [];

  constructor(id: string, ttlMs: number) {
    this.id = id;
    this.deadline = Date.now() + ttlMs;
  }
}

class PubRecord {
  at: number = 0;
  fp: string = '';
}

/** ISO 8601 时长解析（PT#H#M#S 含小数秒） */
export function parseISODuration(s: string): number {
  if (!s) return -1;
  const m = s.match(/^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$/i);
  if (!m) return -1;
  let ms = 0;
  if (m[1]) ms += parseInt(m[1]) * 3600000;
  if (m[2]) ms += parseInt(m[2]) * 60000;
  if (m[3]) ms += Math.round(parseFloat(m[3]) * 1000);
  return ms;
}
