import cryptoFramework from '@ohos.security.cryptoFramework';
import util from '@ohos.util';
import hilog from '@ohos.hilog';

const DOMAIN = 0x080D;
const TAG = 'ipcam.Auth';

/** RTSP/HTTP 401 挑战与 ONVIF 设备域名 */
export const AUTH_REALM = 'ohos-ipcam';
/** WS-UsernameToken Created 时间窗(±5 分钟,ONVIF 惯例) */
const CREATED_WINDOW_MS = 300000;

/**
 * 共享凭证:单一账号同时服务 RTSP(:8554)/HTTP(:8090)/ONVIF(:8000)。
 * 由设置页在推流启动前注入;默认关闭(向后兼容,升级不断流)。
 * 口令必须明文保存于应用沙箱——RTSP Digest 与 WS-PasswordDigest
 * 的服务端校验都需要以明文参与哈希,无法只存摘要。
 */
export class AuthConfig {
  private static enabled = false;
  private static user = '';
  private static pass = '';

  static configure(enabled: boolean, user: string, pass: string): void {
    /* 开启认证必须有用户名与口令,否则视为关闭并告警 */
    if (enabled && (user === '' || pass === '')) {
      hilog.warn(DOMAIN, TAG, 'auth enabled without credentials, fallback to disabled');
      enabled = false;
    }
    AuthConfig.enabled = enabled;
    AuthConfig.user = user;
    AuthConfig.pass = pass;
    hilog.info(DOMAIN, TAG, 'auth %{public}s', enabled ? 'enabled' : 'disabled');
  }

  static isEnabled(): boolean {
    return AuthConfig.enabled;
  }

  static getUser(): string {
    return AuthConfig.user;
  }

  /** 口令仅限本模块摘要计算使用,不对网络层透出 */
  static getPass(): string {
    return AuthConfig.pass;
  }

  /** 校验明文账号口令(Basic 与 WS-PasswordText 共用);比较走逐字节异或,不短路。 */
  static checkUserPass(user: string, pass: string): boolean {
    if (!AuthConfig.enabled || user === '' || pass === '') {
      return false;
    }
    let diff = 0;
    diff |= AuthConfig.user.length ^ user.length;
    diff |= AuthConfig.pass.length ^ pass.length;
    const n = Math.max(AuthConfig.user.length, user.length);
    const m = Math.max(AuthConfig.pass.length, pass.length);
    for (let i = 0; i < n; i++) {
      const a = i < AuthConfig.user.length ? AuthConfig.user.charCodeAt(i) : 0;
      const b = i < user.length ? user.charCodeAt(i) : 0;
      diff |= a ^ b;
    }
    for (let i = 0; i < m; i++) {
      const a = i < AuthConfig.pass.length ? AuthConfig.pass.charCodeAt(i) : 0;
      const b = i < pass.length ? pass.charCodeAt(i) : 0;
      diff |= a ^ b;
    }
    return diff === 0;
  }
}

/* ---------------- 基础编码/摘要工具 ---------------- */

function utf8Bytes(s: string): Uint8Array {
  const enc = new util.TextEncoder();
  return enc.encodeInto(s);
}

function b64Encode(bytes: Uint8Array): string {
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(bytes);
}

function b64Decode(s: string): Uint8Array {
  const helper = new util.Base64Helper();
  return helper.decodeSync(s);
}

function toHex(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += (bytes[i] >> 4).toString(16) + (bytes[i] & 0xf).toString(16);
  }
  return out;
}

/** MD5 摘要(RTSP Digest 认证,RFC 2617) */
function md5Hex(input: string): string {
  const md = cryptoFramework.createMd('MD5');
  md.updateSync({ data: utf8Bytes(input) } as cryptoFramework.DataBlob);
  return toHex(md.digestSync().data);
}

/** SHA1 摘要(WS-UsernameToken PasswordDigest,OASIS Profile) */
function sha1(data: Uint8Array): Uint8Array {
  const md = cryptoFramework.createMd('SHA1');
  md.updateSync({ data: data } as cryptoFramework.DataBlob);
  return md.digestSync().data;
}

/** 摘要输入 = nonce 原始字节 + Created + 口令 的字节拼接 */
function concat3(a: Uint8Array, b: Uint8Array, c: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length + c.length);
  out.set(a, 0);
  out.set(b, a.length);
  out.set(c, a.length + b.length);
  return out;
}

/** RTSP Digest 挑战 nonce(随机 16 字节 hex) */
export function randomNonce(): string {
  const rand = cryptoFramework.createRandom();
  return toHex(rand.generateRandomSync(16).data);
}

/** 解码 base64 为字符串(Basic 认证凭据) */
function b64DecodeText(s: string): string {
  const dec = new util.TextDecoder('utf-8');
  return dec.decodeToString(b64Decode(s));
}

/* ---------------- RTSP / HTTP Authorization 校验 ---------------- */

interface AuthParams {
  scheme: string;
  cred: string; /* Basic:base64 凭据;Digest 留空 */
  user: string;
  realm: string;
  nonce: string;
  uri: string;
  response: string;
}

/** 解析 Authorization 头:Basic 或 Digest(引号/无引号参数都兼容) */
function parseAuthorization(value: string): AuthParams | null {
  if (value === '') {
    return null;
  }
  const sp = value.indexOf(' ');
  if (sp < 0) {
    return null;
  }
  const p: AuthParams = {
    scheme: value.substring(0, sp).toLowerCase(), cred: '', user: '',
    realm: '', nonce: '', uri: '', response: ''
  };
  if (p.scheme === 'basic') {
    p.cred = value.substring(sp + 1).trim();
    return p;
  }
  if (p.scheme !== 'digest') {
    return null;
  }
  const re = /([A-Za-z]+)=("([^"]*)"|[^,]+)/g;
  let m = re.exec(value);
  while (m !== null) {
    const key = m[1].toLowerCase();
    const raw = m[2];
    const v = raw.startsWith('"') ? raw.substring(1, raw.length - 1) : raw;
    if (key === 'username') {
      p.user = v;
    } else if (key === 'realm') {
      p.realm = v;
    } else if (key === 'nonce') {
      p.nonce = v;
    } else if (key === 'uri') {
      p.uri = v;
    } else if (key === 'response') {
      p.response = v.toLowerCase();
    }
    m = re.exec(value);
  }
  return p;
}

function verifyBasic(p: AuthParams): boolean {
  if (p.cred === '') {
    return false;
  }
  try {
    const decoded = b64DecodeText(p.cred);
    const colon = decoded.indexOf(':');
    if (colon < 0) {
      return false;
    }
    return AuthConfig.checkUserPass(decoded.substring(0, colon), decoded.substring(colon + 1));
  } catch (e) {
    return false;
  }
}

/**
 * RTSP 请求认证校验(RFC 2326 §10 / RFC 2617):
 * - Basic:base64(user:pass)
 * - Digest MD5:response == MD5(MD5(user:realm:pass):nonce:MD5(method:uri))
 *   HA2 的 uri 取客户端 Authorization 头内的 uri 字段(与客户端计算口径
 *   一致,避免 SETUP 轨道地址与请求 URL 写法差异)。
 * issuedNonce 为本连接最近签发的 nonce,不匹配即视为过期重挑战。
 */
export function verifyRtspAuthorization(method: string, headerValue: string,
  issuedNonce: string): boolean {
  if (!AuthConfig.isEnabled()) {
    return false;
  }
  const p = parseAuthorization(headerValue);
  if (p === null) {
    return false;
  }
  if (p.scheme === 'basic') {
    return verifyBasic(p);
  }
  /* Digest MD5(无 qop 的 RFC 2617 兼容形态,IP 摄像机事实标准) */
  if (p.user === '' || p.nonce === '' || p.response === '' || p.uri === '') {
    return false;
  }
  if (issuedNonce !== '' && p.nonce !== issuedNonce) {
    return false;
  }
  const ha1 = md5Hex(`${p.user}:${p.realm}:${AuthConfig.getPass()}`);
  const ha2 = md5Hex(`${method}:${p.uri}`);
  const expect = md5Hex(`${ha1}:${p.nonce}:${ha2}`);
  return expect === p.response;
}

/** HTTP Basic 认证校验(状态页/快照/MJPEG 共用) */
export function verifyHttpBasic(headerValue: string): boolean {
  if (!AuthConfig.isEnabled()) {
    return false;
  }
  const p = parseAuthorization(headerValue);
  if (p === null || p.scheme !== 'basic') {
    return false;
  }
  return verifyBasic(p);
}

/* ---------------- ONVIF WS-UsernameToken 校验 ---------------- */

function xmlUnescape(s: string): string {
  return s.replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&amp;/g, '&');
}

/** 命名空间前缀无关的 SOAP 元素文本提取(与 OnvifServer 现有 tag 级匹配同法) */
function xmlElement(xml: string, local: string): string {
  const re = new RegExp(`<([A-Za-z0-9]+:)?${local}([^>]*)>([^<]*)<`);
  const m = re.exec(xml);
  return m !== null ? m[3] : '';
}

/** 元素开标签属性串(小写化,用于判别 Password 的 Type) */
function xmlElementAttrs(xml: string, local: string): string {
  const re = new RegExp(`<([A-Za-z0-9]+:)?${local}([^>]*)>`);
  const m = re.exec(xml);
  return m !== null ? m[2].toLowerCase() : '';
}

/**
 * ONVIF WS-Security UsernameToken 校验(SOAP 信封内 s:Header/wsse:Security):
 * - PasswordDigest:Base64(SHA1(nonce原始字节 + Created + 口令)) 比对,
 *   Created 须落在 ±5 分钟窗口内(重放的主要时间界);
 * - PasswordText:明文比对(兼容能力较弱的客户端);
 * 缺任一字段或超窗即拒绝。
 */
export function verifyWsUsernameToken(envelope: string): boolean {
  if (!AuthConfig.isEnabled()) {
    return false;
  }
  const user = xmlUnescape(xmlElement(envelope, 'Username'));
  if (user === '' || user !== AuthConfig.getUser()) {
    return false;
  }
  const passElem = xmlElement(envelope, 'Password');
  const passAttrs = xmlElementAttrs(envelope, 'Password');
  if (passElem === '') {
    return false;
  }
  const nonce = xmlElement(envelope, 'Nonce').trim();
  const created = xmlElement(envelope, 'Created').trim();
  if (passAttrs.indexOf('passworddigest') >= 0) {
    if (nonce === '' || created === '') {
      return false;
    }
    const t = Date.parse(created);
    if (isNaN(t) || Math.abs(Date.now() - t) > CREATED_WINDOW_MS) {
      hilog.warn(DOMAIN, TAG, 'ws token created out of window');
      return false;
    }
    try {
      const expect = b64Encode(sha1(concat3(b64Decode(nonce), utf8Bytes(created),
        utf8Bytes(AuthConfig.getPass()))));
      if (expect !== passElem) {
        hilog.warn(DOMAIN, TAG, 'digest mismatch: expect=%{public}s got=%{public}s nonceB64Len=%{public}d created=%{public}s',
          expect, passElem, nonce.length, created);
      }
      return expect === passElem;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'digest compute failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }
  /* PasswordText */
  return AuthConfig.checkUserPass(user, xmlUnescape(passElem));
}
