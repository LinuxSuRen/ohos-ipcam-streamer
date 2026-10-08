import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';
import common from '@ohos.app.ability.common';

const TAG = 'ipcam.Persist';
const FILE = 'settings.json';

export interface Settings {
  rotate: number;
  cam: number;
  autoStart: boolean;
  resolution: string; /* "宽x高",如 1280x720 */
}

const DEFAULTS: Settings = { rotate: 0, cam: -1, autoStart: false, resolution: '1280x720' };

function path(context: common.Context): string {
  return `${context.filesDir}/${FILE}`;
}

export function loadSettings(context: common.Context): Settings {
  try {
    const text = fs.readTextSync(path(context));
    const obj: Settings = JSON.parse(text) as Settings;
    if (obj.rotate !== undefined && obj.rotate >= 0) {
      if (obj.resolution === undefined || obj.resolution === '') {
        obj.resolution = DEFAULTS.resolution;
      }
      return obj;
    }
  } catch (e) {
    hilog.info(0, TAG, 'no settings, defaults');
  }
  return DEFAULTS;
}

export function saveSettings(context: common.Context, s: Settings): void {
  try {
    const file = fs.openSync(path(context),
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, JSON.stringify(s));
    fs.closeSync(file.fd);
  } catch (e) {
    hilog.warn(0, TAG, 'save failed: %{public}s', JSON.stringify(e));
  }
}
