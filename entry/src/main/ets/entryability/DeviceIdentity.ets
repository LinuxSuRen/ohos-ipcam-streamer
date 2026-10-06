import fs from '@ohos.file.fs';
import util from '@ohos.util';
import common from '@ohos.app.ability.common';
import deviceInfo from '@ohos.deviceInfo';

/** 设备展示名(营销名优先,如 SGT-AL50)。 */
export function deviceModel(): string {
  const m = deviceInfo.marketName !== undefined && deviceInfo.marketName !== ''
    ? deviceInfo.marketName : deviceInfo.productModel;
  return m !== undefined && m !== '' ? m : 'unknown';
}

/** 系统版本描述,如 HarmonyOS x.x.x。 */
export function deviceOs(): string {
  return `${deviceInfo.osFullName} ${deviceInfo.displayVersion}`;
}

/** Scopes/展示用的无空格标识。 */
export function deviceLabel(): string {
  return deviceModel().replace(/\s+/g, '_');
}

/** 硬件型号(ONVIF HardwareId)。 */
export function deviceHardware(): string {
  const hw = deviceInfo.hardwareModel;
  return hw !== undefined && hw !== '' ? hw : deviceModel();
}

/**
 * 稳定设备序列号:首次生成本机 UUID 并持久化到沙箱。
 * (系统 serial/UDID 需系统权限,普通应用不可读)
 */
export function ensureDeviceId(context: common.Context): string {
  const p = `${context.filesDir}/device_id.txt`;
  try {
    if (fs.accessSync(p)) {
      const id = fs.readTextSync(p).trim();
      if (id !== '') {
        return id;
      }
    }
    const id = util.generateRandomUUID(true);
    const file = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, id);
    fs.closeSync(file.fd);
    return id;
  } catch (e) {
    return 'unknown';
  }
}
