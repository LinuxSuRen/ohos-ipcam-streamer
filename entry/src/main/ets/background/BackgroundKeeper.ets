import common from '@ohos.app.ability.common';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import hilog from '@ohos.hilog';

const DOMAIN = 0x080A;
const TAG = 'ipcam.BackgroundKeeper';

/**
 * 长时任务保活(DATA_TRANSFER 类型):
 * 请求后系统挂常驻通知,应用退后台/熄屏后相机与网络继续工作。
 * 需要权限 ohos.permission.KEEP_BACKGROUND_RUNNING(module.json5 已声明)。
 */
export class BackgroundKeeper {
  private static active = false;

  static isActive(): boolean {
    return BackgroundKeeper.active;
  }

  static async start(context: common.UIAbilityContext): Promise<void> {
    if (BackgroundKeeper.active) {
      return;
    }
    try {
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      } as wantAgent.WantAgentInfo;
      const agent = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(
        context, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      BackgroundKeeper.active = true;
      hilog.info(DOMAIN, TAG, 'background long task started');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'start background failed: %{public}s', JSON.stringify(e));
    }
  }

  static async stop(context: common.UIAbilityContext): Promise<void> {
    if (!BackgroundKeeper.active) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'stop background failed: %{public}s', JSON.stringify(e));
    }
    BackgroundKeeper.active = false;
    hilog.info(DOMAIN, TAG, 'background long task stopped');
  }
}
