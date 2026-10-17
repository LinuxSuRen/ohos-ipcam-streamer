import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';
import common from '@ohos.app.ability.common';

const TAG = 'ipcam.Presets';
const FILE = 'presets.json';

/** 预置点 = 归一变焦位置 [0,1](手机无可动云台,Pan/Tilt 恒 0)。 */
export interface Preset {
  token: string;
  name: string;
  pos: number;
}

/**
 * PTZ 预置点存储:独立文件持久化(与 settings.json 分离,
 * 避免与界面保存配置的写入互相覆盖);按相机编号分桶。
 */
export class Presets {
  private static store: Array<Array<Preset>> = [];
  private static ctx: common.Context | null = null;

  /** OnvifServer 启动时注入上下文并装载持久化数据。 */
  static init(context: common.Context): void {
    Presets.ctx = context;
    Presets.store = [];
    try {
      const text = fs.readTextSync(`${context.filesDir}/${FILE}`);
      const obj = JSON.parse(text) as Array<Array<Preset>>;
      if (obj instanceof Array) {
        Presets.store = obj;
      }
    } catch (e) {
      hilog.info(0, TAG, 'no presets file, start empty');
    }
  }

  private static persist(): void {
    if (Presets.ctx === null) {
      return;
    }
    try {
      const file = fs.openSync(`${Presets.ctx.filesDir}/${FILE}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(Presets.store));
      fs.closeSync(file.fd);
    } catch (e) {
      hilog.warn(0, TAG, 'persist failed: %{public}s', JSON.stringify(e));
    }
  }

  private static bucket(cam: number): Array<Preset> {
    while (Presets.store.length <= cam) {
      Presets.store.push([]);
    }
    return Presets.store[cam];
  }

  static list(cam: number): Preset[] {
    return cam >= 0 && cam < Presets.store.length ? Presets.store[cam] : [];
  }

  /** 保存/更新:token 缺省时按最大数字 token 自增生成;返回落库后的预置点。 */
  static set(cam: number, token: string, name: string, pos: number): Preset {
    const bucket = Presets.bucket(cam);
    if (token === '') {
      let max = 0;
      for (const p of bucket) {
        const n = parseInt(p.token);
        if (!isNaN(n) && n >= max) {
          max = n;
        }
      }
      token = String(max + 1);
    }
    if (name === '') {
      name = `Preset ${token}`;
    }
    const p: Preset = { token: token, name: name, pos: pos };
    const idx = bucket.findIndex((v) => v.token === token);
    if (idx >= 0) {
      bucket[idx] = p;
    } else {
      bucket.push(p);
    }
    Presets.persist();
    hilog.info(0, TAG, 'cam%{public}d set preset %{public}s pos=%{public}f', cam, token, pos);
    return p;
  }

  static get(cam: number, token: string): Preset | null {
    for (const p of Presets.list(cam)) {
      if (p.token === token) {
        return p;
      }
    }
    return null;
  }

  static remove(cam: number, token: string): boolean {
    const bucket = Presets.bucket(cam);
    const idx = bucket.findIndex((v) => v.token === token);
    if (idx < 0) {
      return false;
    }
    bucket.splice(idx, 1);
    Presets.persist();
    return true;
  }
}
