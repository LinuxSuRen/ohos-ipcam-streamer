import sensor from '@ohos.sensor';
import hilog from '@ohos.hilog';

const DOMAIN = 0x080B;
const TAG = 'ipcam.Orientation';

/**
 * 加速度传感器判断手机摆放,给出建议的画面旋转角(顺时针):
 * 横放 0°/180°,竖放 90°/270°。平放时保持上次建议。
 * 角度与画面正立的对应关系以后摄 orientation=90 实测校准。
 */
export class OrientationSensor {
  private static on = false;
  private static suggestDeg = 0;

  static getSuggest(): number {
    return OrientationSensor.suggestDeg;
  }

  static start(cb: (suggestDeg: number) => void): void {
    if (OrientationSensor.on) {
      return;
    }
    try {
      sensor.on(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
        const x = data.x;
        const y = data.y;
        const z = data.z;
        const ax = Math.abs(x);
        const ay = Math.abs(y);
        const az = Math.abs(z);
        if (az > ay && az > ax) {
          return; /* 平放:保持 */
        }
        let deg = OrientationSensor.suggestDeg;
        if (ax > ay * 2 && ax > 4) {
          deg = x < 0 ? 0 : 180;   /* 横放 */
        } else if (ay > ax * 2 && ay > 4) {
          deg = y > 0 ? 90 : 270;  /* 竖放 */
        }
        if (deg !== OrientationSensor.suggestDeg) {
          OrientationSensor.suggestDeg = deg;
          hilog.info(DOMAIN, TAG, 'suggest rotate %{public}d', deg);
          cb(deg);
        }
      }, { interval: 500000000 } as sensor.Options);
      OrientationSensor.on = true;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'sensor start failed: %{public}s', JSON.stringify(e));
    }
  }

  static stop(): void {
    if (!OrientationSensor.on) {
      return;
    }
    try {
      sensor.off(sensor.SensorId.ACCELEROMETER);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'sensor off failed');
    }
    OrientationSensor.on = false;
  }
}
