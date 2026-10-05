import UIAbility from '@ohos.app.ability.UIAbility';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import hilog from '@ohos.hilog';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { setAbilityContext, setCameraGranted, initPersisted } from './GlobalContext';

const DOMAIN = 0x0801;
const TAG = 'ipcam.EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    try {
      const p = want.parameters as Record<string, Object>;
      const rot = p !== undefined && p.rotate !== undefined ? parseInt(String(p.rotate)) : -1;
      const cam = p !== undefined && p.cam !== undefined ? parseInt(String(p.cam)) : -1;
      if (rot >= 0 || cam >= 0) {
        initPersisted(rot, cam);
        hilog.info(DOMAIN, TAG, 'persisted rot=%{public}d cam=%{public}d', rot, cam);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse want failed');
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    setAbilityContext(this.context);
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent ok');
      this.requestCameraPermission();
    });
  }

  /**
   * 权限请求必须用 UIAbility 原生 this.context：
   * 经模块边界传递的 context 对象 ATM 原生层识别失败(401)。
   */
  private async requestCameraPermission(): Promise<void> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const perms: Array<Permissions> = ['ohos.permission.CAMERA'];
      const result = await atManager.requestPermissionsFromUser(this.context, perms);
      const granted = result.authResults.length > 0 && result.authResults[0] === 0;
      setCameraGranted(granted);
      hilog.info(DOMAIN, TAG, 'camera perm granted=%{public}s', String(granted));
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'request perm failed: %{public}s', JSON.stringify(e));
    }
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
  }
}
