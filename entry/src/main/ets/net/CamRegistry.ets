/**
 * 当前推流中的相机注册表(启动时由 UI 写入):
 * index 全局相机编号(RTSP /camN 与之对应),ONVIF Profile token 为 profile_{N+1}。
 */
export interface CamInfo {
  index: number;
  label: string;
  outW: number;
  outH: number;
  fps: number;
  bitrate: number;
}

export class CamRegistry {
  private static cams: CamInfo[] = [];

  static set(list: CamInfo[]): void {
    CamRegistry.cams = list;
  }

  static list(): CamInfo[] {
    return CamRegistry.cams;
  }

  static get(cam: number): CamInfo | null {
    for (const c of CamRegistry.cams) {
      if (c.index === cam) {
        return c;
      }
    }
    return null;
  }
}
