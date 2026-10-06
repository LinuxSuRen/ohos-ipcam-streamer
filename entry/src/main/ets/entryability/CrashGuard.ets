import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';
import common from '@ohos.app.ability.common';
import { errorManager } from '@kit.AbilityKit';

const TAG = 'ipcam.CrashGuard';
const FILE = 'last_crash.txt';

/**
 * 闪退防护网(参照 tv-uvc-streamer CrashGuard):
 * 未捕获异常写入沙箱文件,下次启动在应用界面与 HTTP 状态页展示。
 */
export class CrashGuard {
  private static installed = false;
  private static cached: string | null = null;

  static install(context: common.Context): void {
    if (CrashGuard.installed) {
      return;
    }
    CrashGuard.installed = true;
    CrashGuard.cached = CrashGuard.read(context);
    const write = (text: string): void => {
      try {
        const file = fs.openSync(`${context.filesDir}/${FILE}`,
          fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, text);
        fs.closeSync(file.fd);
      } catch (e) {
        hilog.warn(0, TAG, 'persist crash failed');
      }
    };
    try {
      const observer: errorManager.ErrorObserver = {
        onUnhandledException: (errMsg: string) => {
          write(`${new Date().toISOString()}\n${errMsg}`);
        },
        onException: (err: Error) => {
          write(`${new Date().toISOString()}\n${err.name}: ${err.message}\n${err.stack ?? ''}`);
        }
      };
      errorManager.on('error', observer);
    } catch (e) {
      hilog.warn(0, TAG, 'install failed: %{public}s', JSON.stringify(e));
    }
  }

  private static read(context: common.Context): string | null {
    try {
      const p = `${context.filesDir}/${FILE}`;
      if (!fs.accessSync(p)) {
        return null;
      }
      const text = fs.readTextSync(p);
      return text.trim() !== '' ? text : null;
    } catch (e) {
      return null;
    }
  }

  /** 读取并清除崩溃记录文件(应用启动时调用一次);
   * 文件已删、下次启动不再出现,但本次运行期间 HTTP 状态页仍可展示。 */
  static consume(context: common.Context): string | null {
    const text = CrashGuard.cached !== null ? CrashGuard.cached : CrashGuard.read(context);
    CrashGuard.cached = text;
    try {
      const p = `${context.filesDir}/${FILE}`;
      if (fs.accessSync(p)) {
        fs.unlinkSync(p);
      }
    } catch (e) {
    }
    return text;
  }

  /** 只读(不清除),供 HTTP 状态页展示。 */
  static peek(): string | null {
    return CrashGuard.cached;
  }

  static setPeek(text: string | null): void {
    CrashGuard.cached = text;
  }
}
