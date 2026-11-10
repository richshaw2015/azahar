import { common } from '@kit.AbilityKit';
import { SelectSettingItem } from '../SelectSettingItem';
import { SliderSettingItem } from '../SliderSettingItem';
import { ToggleSettingItem } from '../ToggleSettingItem';
import { SettingsList, settingsGroupDivider, menuGroupMargin, menuGroupPadding } from '../SettingsList';
import { KEY_DELAY_START_FOR_LLE_MODULES, KEY_DETERMINISTIC_ASYNC_OPERATIONS, KEY_ENABLE_RPC_SERVER, KEY_DEBUG_LOG, KEY_RENDERER_DEBUG, KEY_SIMULATE_3DS_GPU_TIMINGS, KEY_TOGGLE_UNIQUE_DATA_CONSOLE_TYPE, KEY_USE_VIRTUAL_SD, KEY_USE_HW_SHADER, KEY_USE_SHADER_JIT, SettingOption } from '../../../types/SettingsTypes';
import { TEXT_DANGER, ICON_SIZE_ROW } from '../../../types/UIConstants';

import { AzaharNative } from '../../../types/AzaharNative';
import { DeviceProfile } from '../../../utils/DeviceProfile';
import { I18n } from '../../../utils/I18nManager';
import { SettingsManager } from '../../../utils/SettingsManager';
import { SoundEffectManager } from '../../../utils/SoundEffectManager';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';
import { AzaharThemeColors } from '../../../types/ThemeTypes';

// 对齐 Android 端 Settings → Debug 分区（SettingsFragmentPresenter.addDebugSettings）：
// 警告头、CPU 时钟、CPU JIT/快速解释器（合并为 cpu_core_mode 单选）、硬件着色器、
// 着色器 JIT、垂直同步、3DS GPU 时序、调试渲染器、调试日志、RPC 服务器、
// 固件数据类型、LLE 延迟启动、确定性异步操作。
@Component
export struct DebugSettingsContent {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  scroller?: Scroller;
  @State cpuJitCapable: boolean = false;
  @State cpuCoreMode: number = 1;
  @State hwShader: boolean = true;
  @State shaderJit: boolean = true;
  @State simulate3dsGpuTimings: boolean = false;
  @State useVirtualSd: boolean = true;
  @State rendererDebug: boolean = false;
  @State debugLog: boolean = false;
  @State enableRpcServer: boolean = false;
  @State deterministicAsyncOperations: boolean = false;
  @State toggleUniqueDataConsoleType: boolean = false;
  @State delayStartForLleModules: boolean = true;

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private settingsManager: SettingsManager = SettingsManager.getInstance();
  private deviceType: string = 'phone';

  async aboutToAppear(): Promise<void> {
    await this.settingsManager.initialize(this.context);
    this.deviceType = DeviceProfile.getDeviceType();
    this.loadSettings();
  }

  private loadSettings(): void {
    this.refreshJitPolicy();
    this.cpuCoreMode = this.settingsManager.getCpuCoreMode(this.deviceType);
    this.hwShader = this.settingsManager.getBoolean(KEY_USE_HW_SHADER);
    this.shaderJit = this.settingsManager.getBoolean(KEY_USE_SHADER_JIT);
    this.simulate3dsGpuTimings = this.settingsManager.getBoolean(KEY_SIMULATE_3DS_GPU_TIMINGS);
    this.useVirtualSd = this.settingsManager.getBoolean(KEY_USE_VIRTUAL_SD);
    this.rendererDebug = this.settingsManager.getBoolean(KEY_RENDERER_DEBUG);
    this.debugLog = this.settingsManager.getBoolean(KEY_DEBUG_LOG);
    this.enableRpcServer = this.settingsManager.getBoolean(KEY_ENABLE_RPC_SERVER);
    this.deterministicAsyncOperations = this.settingsManager.getBoolean(KEY_DETERMINISTIC_ASYNC_OPERATIONS);
    this.toggleUniqueDataConsoleType = this.settingsManager.getBoolean(KEY_TOGGLE_UNIQUE_DATA_CONSOLE_TYPE);
    this.delayStartForLleModules = this.settingsManager.getBoolean(KEY_DELAY_START_FOR_LLE_MODULES);
  }

  private refreshJitPolicy(): void {
    // JIT 能力统一读启动应用时一次性探测的缓存结果（与 initEmulator 链路同源）
    this.cpuJitCapable = AzaharNative.isJitSupported(this.deviceType);
  }

  private async applyCpuCoreMode(mode: number): Promise<void> {
    this.cpuCoreMode = mode;
    await this.settingsManager.setCpuCoreMode(mode);
    this.settingsManager.syncCpuCoreMode(this.deviceType);
  }

  private async updateBoolean(key: string, value: boolean): Promise<void> {
    await this.settingsManager.setBoolean(key, value);
    AzaharNative.applyConfig();
  }

  private async updateNumber(key: string, value: number): Promise<void> {
    await this.settingsManager.setNumber(key, value);
    AzaharNative.applyConfig();
  }

  // cpu_core_mode：0=动态重编译(JIT) 1=快速解释器 3=普通解释器
  private cpuCoreModeOptions(): SettingOption[] {
    const modes: number[] = this.cpuJitCapable ? [0, 1, 3] : [1, 3];
    const labels: Record<number, string> = {
      0: I18n.t('cpu_mode_jit'), 1: I18n.t('cpu_mode_fastinterp'), 3: I18n.t('cpu_mode_interpreter')
    };
    return modes.map((mode: number): SettingOption => ({ value: mode, label: labels[mode] }));
  }

  private cpuCoreModeIndex(): number {
    const modes: number[] = this.cpuJitCapable ? [0, 1, 3] : [1, 3];
    const index = modes.indexOf(this.cpuCoreMode);
    return index >= 0 ? index : 0;
  }

  build() {
    SettingsList({ scroller: this.scroller }) {
      // Android: HeaderSetting(R.string.debug_warning)
      ListItem() {
        Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
            .fontSize(ICON_SIZE_ROW)
            .fontColor([TEXT_DANGER])
          Text(I18n.t('debug_warning'))
            .fontSize($r('sys.float.ohos_id_text_size_body2'))
            .fontWeight(FontWeight.Bold)
            .fontColor(TEXT_DANGER)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({
          left: $r('sys.float.ohos_id_max_padding_start'),
          right: $r('sys.float.ohos_id_default_padding_end'),
          top: $r('sys.float.ohos_id_elements_margin_vertical_m'),
          bottom: $r('sys.float.ohos_id_elements_margin_vertical_m')
        })
      }

      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          SelectSettingItem({
            title: I18n.t('settings_cpu_core_mode'),
            description: this.cpuJitCapable ? I18n.t('cpu_core_mode_desc') : I18n.t('cpu_core_mode_no_jit'),
            options: this.cpuCoreModeOptions(),
            selectedIndex: this.cpuCoreModeIndex(),
            requiresRestart: true,
            onSelect: (index: number, value: string | number) => {
              this.applyCpuCoreMode(value as number);
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_hw_shader'),
            description: I18n.t('settings_hw_shader_desc'),
            isOn: this.hwShader,
            requiresRestart: true,
            onToggle: (value: boolean) => {
              this.hwShader = value;
              this.updateBoolean(KEY_USE_HW_SHADER, value);
            }
          })
        }
        if (this.cpuJitCapable) {
          ListItem() {
            ToggleSettingItem({
              title: I18n.t('settings_shader_jit'),
              description: I18n.t('settings_shader_jit_desc'),
              isOn: this.shaderJit,
              requiresRestart: true,
              onToggle: (value: boolean) => {
                this.shaderJit = value;
                this.updateBoolean(KEY_USE_SHADER_JIT, value);
              }
            })
          }
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_simulate_3ds_gpu_timings'),
            description: I18n.t('settings_simulate_3ds_gpu_timings_desc'),
            isOn: this.simulate3dsGpuTimings,
            requiresRestart: true,
            onToggle: (value: boolean) => {
              this.simulate3dsGpuTimings = value;
              this.updateBoolean(KEY_SIMULATE_3DS_GPU_TIMINGS, value);
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_virtual_sd'),
            description: I18n.t('settings_virtual_sd_desc'),
            isOn: this.useVirtualSd,
            requiresRestart: true,
            onToggle: (value: boolean) => {
              this.useVirtualSd = value;
              this.updateBoolean(KEY_USE_VIRTUAL_SD, value);
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_renderer_debug'),
            description: I18n.t('settings_renderer_debug_desc'),
            isOn: this.rendererDebug,
            requiresRestart: true,
            onToggle: (value: boolean) => {
              this.rendererDebug = value;
              this.updateBoolean(KEY_RENDERER_DEBUG, value);
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_debug_log'),
            description: I18n.t('settings_debug_log_desc'),
            isOn: this.debugLog,
            onToggle: (value: boolean) => {
              this.debugLog = value;
              this.updateBoolean(KEY_DEBUG_LOG, value);
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_rpc_server'),
            description: I18n.t('settings_rpc_server_desc'),
            isOn: this.enableRpcServer,
            requiresRestart: true,
            onToggle: (value: boolean) => {
              this.enableRpcServer = value;
              this.updateBoolean(KEY_ENABLE_RPC_SERVER, value);
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_unique_data_console'),
            description: I18n.t('settings_unique_data_console_desc'),
            isOn: this.toggleUniqueDataConsoleType,
            requiresRestart: true,
            onToggle: (value: boolean) => {
              this.toggleUniqueDataConsoleType = value;
              this.updateBoolean(KEY_TOGGLE_UNIQUE_DATA_CONSOLE_TYPE, value);
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_lle_module_delay_start'),
            description: I18n.t('settings_lle_module_delay_start_desc'),
            isOn: this.delayStartForLleModules,
            requiresRestart: true,
            onToggle: (value: boolean) => {
              this.delayStartForLleModules = value;
              this.updateBoolean(KEY_DELAY_START_FOR_LLE_MODULES, value);
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_deterministic_async'),
            description: I18n.t('settings_deterministic_async_desc'),
            isOn: this.deterministicAsyncOperations,
            requiresRestart: true,
            onToggle: (value: boolean) => {
              this.deterministicAsyncOperations = value;
              this.updateBoolean(KEY_DETERMINISTIC_ASYNC_OPERATIONS, value);
            }
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())
    }
  }
}
