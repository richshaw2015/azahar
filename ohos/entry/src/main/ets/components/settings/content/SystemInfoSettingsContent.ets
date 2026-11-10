/**
 * 系统信息内容组件
 *
 * 展示设备信息、系统与软件、显示信息（含 native 探测的 Vulkan/GLES/GPU 图形行），
 * 数据走鸿蒙 deviceInfo/display API + AzaharNative.getGraphicsInfo。
 * 渲染分辨率取窗口可绘制区域（drawableRect 优先），窗口未就绪时回退物理屏 vp；
 * 监听 windowSizeChange 实时更新（分屏/自由多窗）。
 */
import { display, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { SettingsList, SettingsSectionHeader, settingsGroupDivider, StaticInfoRow, menuGroupMargin, menuGroupPadding } from '../SettingsList';
import { I18n } from '../../../utils/I18nManager';
import { AzaharGraphicsInfo, AzaharNative } from '../../../types/AzaharNative';
import { DeviceProfile } from '../../../utils/DeviceProfile';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';
import { AzaharThemeColors } from '../../../types/ThemeTypes';

interface InfoItem {
  label: string;
  value: string;
}

@Component
export struct SystemInfoSettingsContent {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  scroller?: Scroller;
  @State private deviceItems: InfoItem[] = [];
  @State private systemItems: InfoItem[] = [];
  @State private displayItems: InfoItem[] = [];
  // 图形栈信息（native 探测，值固定），在 collectDisplayInfo 里并入显示信息组
  @State private vpDisplay: string = '';
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private windowClass: window.Window | null = null;

  aboutToAppear(): void {
    this.collectDeviceInfo();
    this.collectSystemInfo();
    this.collectGraphicsInfo();
    this.collectDisplayInfo();
    this.initWindowVpMonitoring();
  }

  aboutToDisappear(): void {
    if (this.windowClass) {
      try {
        this.windowClass.off('windowSizeChange');
      } catch (error) {
        console.error(`[SystemInfo] off windowSizeChange failed: ${(error as Error).message}`);
      }
    }
  }

  private initWindowVpMonitoring(): void {
    window.getLastWindow(this.context).then((win: window.Window) => {
      this.windowClass = win;
      this.updateVpFromWindow();
      win.on('windowSizeChange', (_size: window.Size) => {
        this.updateVpFromWindow();
      });
    }).catch((err: Error) => {
      console.error(`[SystemInfo] getLastWindow failed: ${err.message}`);
    });
  }

  private updateVpFromWindow(): void {
    if (!this.windowClass) {
      return;
    }
    try {
      const props = this.windowClass.getWindowProperties();
      const dp = display.getDefaultDisplaySync().densityPixels || 1;
      // drawableRect (API 11+) 排除窗口装饰栏（自由多窗标题栏）
      const rect = (props.drawableRect && props.drawableRect.width > 0) ? props.drawableRect : props.windowRect;
      const vpW = Math.round(rect.width / dp);
      const vpH = Math.round(rect.height / dp);
      this.vpDisplay = `${vpW} × ${vpH} vp`;
      this.collectDisplayInfo();
    } catch (error) {
      console.error(`[SystemInfo] update vp from window failed: ${(error as Error).message}`);
    }
  }

  private collectDeviceInfo(): void {
    const items: InfoItem[] = [];
    try {
      items.push({ label: I18n.t('sysinfo_brand'), value: deviceInfo.brand || '-' });
      items.push({ label: I18n.t('sysinfo_model'), value: deviceInfo.marketName || deviceInfo.productModel || '-' });
      items.push({ label: I18n.t('sysinfo_device_type'), value: deviceInfo.deviceType || '-' });
      items.push({ label: I18n.t('sysinfo_abi'), value: deviceInfo.abiList || '-' });
    } catch (error) {
      console.error(`[SystemInfo] collect device info failed: ${(error as Error).message}`);
    }
    this.deviceItems = items;
  }

  private collectSystemInfo(): void {
    const items: InfoItem[] = [];
    try {
      items.push({ label: I18n.t('sysinfo_os_name'), value: deviceInfo.osFullName || '-' });
      items.push({ label: I18n.t('sysinfo_sdk_api'), value: deviceInfo.sdkApiVersion?.toString() || '-' });
      // 应用分身索引：主应用不显示，分身显示序号便于区分实例
      const cloneIndex = DeviceProfile.getAppCloneIndex(this.context);
      if (cloneIndex > 0) {
        items.push({ label: I18n.t('sysinfo_app_clone'), value: `${cloneIndex}` });
      }
    } catch (error) {
      console.error(`[SystemInfo] collect system info failed: ${(error as Error).message}`);
    }
    this.systemItems = items;
  }

  private collectDisplayInfo(): void {
    const items: InfoItem[] = [];
    try {
      const d = display.getDefaultDisplaySync();
      const dp = d.densityPixels || 1;
      items.push({ label: I18n.t('sysinfo_resolution'), value: `${d.width} × ${d.height}` });
      // 窗口未就绪时先回退物理屏 vp，拿到窗口后由 windowSizeChange/初始化回调覆盖
      const vpW = Math.round(d.width / dp);
      const vpH = Math.round(d.height / dp);
      items.push({ label: I18n.t('sysinfo_resolution_vp'), value: this.vpDisplay || `${vpW} × ${vpH} vp` });
      items.push({ label: I18n.t('sysinfo_density'), value: `${d.densityDPI} dpi (${dp.toFixed(2)}x)` });
      items.push({ label: I18n.t('sysinfo_refresh_rate'), value: `${d.refreshRate || 60} Hz` });
    } catch (error) {
      console.error(`[SystemInfo] collect display info failed: ${(error as Error).message}`);
    }
    this.displayItems = items;
  }

  // native 侧创建临时 EGL 上下文探测（毫秒级），失败时字段为 '-'
  private collectGraphicsInfo(): void {
    const items: InfoItem[] = [];
    try {
      const info: AzaharGraphicsInfo = AzaharNative.getGraphicsInfo();
      items.push({ label: I18n.t('sysinfo_gpu_api'), value: info.vulkanVersion || '-' });
      items.push({ label: I18n.t('sysinfo_gles'), value: info.glesVersion || '-' });
      items.push({ label: I18n.t('sysinfo_gpu'), value: info.gpuName || '-' });
    } catch (error) {
      console.error(`[SystemInfo] collect graphics info failed: ${(error as Error).message}`);
    }
    this.systemItems = this.systemItems.concat(items);
  }

  @Builder
  Section(title: string, items: InfoItem[]) {
    ListItem() {
      SettingsSectionHeader({ title })
    }
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
      ForEach(items, (item: InfoItem) => {
        ListItem() {
          // 纯信息展示行，无点击事件——用无按压态的静态行
          StaticInfoRow({ title: item.label, value: item.value })
        }
      }, (item: InfoItem) => `${title}_${item.label}`)
    }
    .padding(menuGroupPadding())
    .backgroundColor(listCardBgOf(this.themeColors))
    .divider(settingsGroupDivider())
    .margin(menuGroupMargin())
  }

  build() {
    SettingsList({ scroller: this.scroller }) {
      this.Section(I18n.t('sysinfo_section_device'), this.deviceItems)
      this.Section(I18n.t('sysinfo_section_software'), this.systemItems)
      this.Section(I18n.t('sysinfo_section_display'), this.displayItems)
    }
  }
}
