import router from '@ohos.router';
import { loadSettings, saveSettings, Settings } from '../entryability/PersistStore';
import { AuthConfig } from '../auth/Auth';
import { getAbilityContext } from '../entryability/GlobalContext';

/**
 * 设置页:访问认证配置(右上角齿轮进入)。
 * 保存即生效——RTSP/HTTP/ONVIF 三服务按请求实时读取 AuthConfig,
 * 无需停止推流;凭证经 PersistStore.updateAuth 单一入口落盘,
 * 避免与主页面的设置保存互相覆盖。
 */
@Entry
@Component
struct SettingsPage {
  @State authEnabled: boolean = false;
  @State saved: string = '';
  private authUser: string = '';
  private authPass: string = '';

  aboutToAppear(): void {
    const st = loadSettings(getAbilityContext()!);
    this.authEnabled = st.authEnabled;
    this.authUser = st.authUser;
    this.authPass = st.authPass;
  }

  private save(): void {
    const ctx = getAbilityContext()!;
    /* load-modify-save:保留主页面维护的其它字段(方向/分辨率/自动开始) */
    const st: Settings = loadSettings(ctx);
    st.authEnabled = this.authEnabled;
    st.authUser = this.authUser;
    st.authPass = this.authPass;
    saveSettings(ctx, st);
    AuthConfig.configure(this.authEnabled, this.authUser, this.authPass);
    this.saved = '已保存并生效';
    setTimeout(() => {
      router.back();
    }, 600);
  }

  build() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Text('‹')
          .fontSize(30)
          .fontColor('#7EB8FF')
          .onClick(() => {
            router.back();
          })
        Text('设置')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#E6E6E6')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 36 })

      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Toggle({ type: ToggleType.Switch, isOn: this.authEnabled })
            .onChange((on: boolean) => {
              this.authEnabled = on;
              this.saved = '';
            })
          Text('访问认证(RTSP/HTTP/ONVIF 共用一账号)')
            .fontSize(15).fontColor('#E6E6E6')
        }
        .alignItems(VerticalAlign.Center)

        if (this.authEnabled) {
          TextInput({ placeholder: '用户名', text: this.authUser })
            .fontSize(15)
            .fontColor('#E6E6E6')
            .placeholderColor('#7A8699')
            .caretColor('#7EB8FF')
            .backgroundColor('#0E1626')
            .borderRadius(8)
            .padding(10)
            .onChange((v: string) => {
              this.authUser = v;
              this.saved = '';
            })
          TextInput({ placeholder: '密码', text: this.authPass })
            .type(InputType.Password)
            .fontSize(15)
            .fontColor('#E6E6E6')
            .placeholderColor('#7A8699')
            .caretColor('#7EB8FF')
            .showPasswordIcon(true)
            .backgroundColor('#0E1626')
            .borderRadius(8)
            .padding(10)
            .onChange((v: string) => {
              this.authPass = v;
              this.saved = '';
            })
          Text('拉流地址形如 rtsp://用户名:密码@手机IP:8554/cam0;口令仅存本机沙箱;修改保存后立即生效,无需重启推流')
            .fontSize(12).fontColor('#888888')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(14)
      .borderRadius(10)
      .backgroundColor('#141E30')

      Button('保存')
        .width(200)
        .fontSize(17)
        .onClick(() => {
          this.save();
        })

      if (this.saved !== '') {
        Text(this.saved).fontSize(14).fontColor('#9FD8A0')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B1220')
    .alignItems(HorizontalAlign.Center)
  }
}
