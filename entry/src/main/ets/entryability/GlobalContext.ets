import common from '@ohos.app.ability.common';

let abilityContext: common.UIAbilityContext | null = null;
let cameraGranted = false;

export function setAbilityContext(ctx: common.UIAbilityContext): void {
  abilityContext = ctx;
}

export function getAbilityContext(): common.UIAbilityContext | null {
  return abilityContext;
}

export function setCameraGranted(granted: boolean): void {
  cameraGranted = granted;
}

export function isCameraGranted(): boolean {
  return cameraGranted;
}

let persistedRotate = 0;
let persistedCam = -1;

/** 由 EntryAbility.onCreate 的 want.parameters 初始化(跨实例传递)。 */
let autoStart = false;

export function initPersisted(rotate: number, cam: number): void {
  if (rotate >= 0) {
    persistedRotate = rotate;
  }
  if (cam >= 0) {
    persistedCam = cam;
  }
  autoStart = true; /* 带参启动 = 切换重启,自动恢复推流 */
}

export function isAutoStart(): boolean {
  return autoStart;
}

export function setPersistedRotate(deg: number): void {
  persistedRotate = deg;
}

export function getPersistedRotate(): number {
  return persistedRotate;
}

export function setPersistedCam(idx: number): void {
  persistedCam = idx;
}

export function getPersistedCam(): number {
  return persistedCam;
}
