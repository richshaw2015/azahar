import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { ButtonSettingItem } from '../ButtonSettingItem';
import { SelectSettingItem } from '../SelectSettingItem';
import { SliderSettingItem } from '../SliderSettingItem';
import { ToggleSettingItem } from '../ToggleSettingItem';
import { SettingsList, SettingsSectionHeader, settingsGroupDivider, menuGroupMargin, menuGroupPadding } from '../SettingsList';
import { DeviceProfile } from '../../../utils/DeviceProfile';
import { I18n } from '../../../utils/I18nManager';
import { SettingsManager } from '../../../utils/SettingsManager';
import { AzaharNative } from '../../../types/AzaharNative';
import { showErrorToast } from '../../../utils/ToastHelper';
import { SoundEffect, SoundEffectManager } from '../../../utils/SoundEffectManager';
import { KEY_ALLOW_PLUGIN_LOADER, KEY_CPU_CLOCK_PERCENTAGE, KEY_ENABLE_REQUIRED_ONLINE_LLE_MODULES, KEY_FRAME_LIMIT, KEY_GAME_PERF_HACKS, KEY_IS_NEW_3DS, KEY_LLE_APPLETS, KEY_PLUGIN_LOADER, KEY_SAVE_STATE_SLOT_COUNT, KEY_USE_FRAME_LIMIT, SAVE_STATE_SLOT_COUNT_OPTIONS, SettingOption } from '../../../types/SettingsTypes';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';
import { AzaharThemeColors } from '../../../types/ThemeTypes';


@Component
export struct CoreSettingsContent {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  scroller?: Scroller;
  @State deviceType: string = 'phone';
  @State isNew3ds: boolean = true;
  @State gamePerfHacks: boolean = false;
  @State lleApplets: boolean = true;
  @State enableRequiredOnlineLleModules: boolean = false;
  @State pluginLoader: boolean = false;
  @State allowPluginLoader: boolean = true;
  // 与 Android General 一致：限速/加速上限
  @State useFrameLimit: boolean = true;
  @State frameLimit: number = 100;
  @State cpuClockPercentage: number = 100;
  @State saveStateSlotCount: number = 10;


  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private settingsManager: SettingsManager = SettingsManager.getInstance();

  async aboutToAppear(): Promise<void> {
    await this.settingsManager.initialize(this.context);
    this.deviceType = DeviceProfile.getDeviceType();
    this.loadSettings();
  }

  private loadSettings(): void {
    this.isNew3ds = this.settingsManager.getBoolean(KEY_IS_NEW_3DS);
    this.gamePerfHacks = this.settingsManager.getBoolean(KEY_GAME_PERF_HACKS);
    this.lleApplets = this.settingsManager.getBoolean(KEY_LLE_APPLETS);
    this.enableRequiredOnlineLleModules = this.settingsManager.getBoolean(KEY_ENABLE_REQUIRED_ONLINE_LLE_MODULES);
    this.pluginLoader = this.settingsManager.getBoolean(KEY_PLUGIN_LOADER);
    this.allowPluginLoader = this.settingsManager.getBoolean(KEY_ALLOW_PLUGIN_LOADER);
    this.useFrameLimit = this.settingsManager.getBoolean(KEY_USE_FRAME_LIMIT);
    this.frameLimit = this.settingsManager.getNumber(KEY_FRAME_LIMIT);
    this.cpuClockPercentage = this.settingsManager.getNumber(KEY_CPU_CLOCK_PERCENTAGE);
    this.saveStateSlotCount = this.settingsManager.getNumber(KEY_SAVE_STATE_SLOT_COUNT);
  }

  private async updateBoolean(key: string, value: boolean): Promise<void> {
    await this.settingsManager.setBoolean(key, value);
    AzaharNative.applyConfig();
  }

  private async updateNumber(key: string, value: number): Promise<void> {
    await this.settingsManager.setNumber(key, value);
    AzaharNative.applyConfig();
  }

  private findOptionIndex(options: SettingOption[], value: string | number): number {
    for (let i = 0; i < options.length; i++) {
      if (options[i].value === value) {
        return i;
      }
    }
    return 0;
  }

  private openSystemProfileSettings(): void {
    router.pushUrl({ url: 'pages/settings/SystemProfileSettings' }).catch((error: Error) => {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('open_failed_fmt', 'error', error.message));
    });
  }

  @Builder
  SectionHeader(title: string) {
    SettingsSectionHeader({ title })
  }

  build() {
    SettingsList({ scroller: this.scroller }) {
      ListItem() {
        this.SectionHeader(I18n.t('emulation_settings'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_frame_limit_enable'),
            description: I18n.t('settings_frame_limit_enable_desc'),
            isOn: this.useFrameLimit,
            onToggle: (value: boolean) => {
              this.useFrameLimit = value;
              this.updateBoolean(KEY_USE_FRAME_LIMIT, value);
            }
          })
        }
        ListItem() {
          SliderSettingItem({
            title: I18n.t('settings_speed_limit'),
            description: I18n.t('settings_speed_limit_desc'),
            value: this.frameLimit,
            disabled: !this.useFrameLimit,
            min: 1,
            max: 200,
            step: 1,
            formatValue: (value: number): string => `${value}%`,
            onChange: (value: number) => {
              this.frameLimit = value;
              this.updateNumber(KEY_FRAME_LIMIT, value);
            }
          })
        }
        ListItem() {
          SliderSettingItem({
            title: I18n.t('settings_cpu_clock'),
            description: I18n.t('settings_cpu_clock_desc'),
            value: this.cpuClockPercentage,
            min: 5,
            max: 400,
            step: 5,
            formatValue: (value: number): string => `${value}%`,
            onChange: (value: number) => {
              this.cpuClockPercentage = value;
              this.updateNumber(KEY_CPU_CLOCK_PERCENTAGE, value);
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_new_3ds_mode'),
            description: I18n.t('settings_new_3ds_mode_desc'),
            isOn: this.isNew3ds,
            onToggle: (value: boolean) => {
              this.isNew3ds = value;
              this.updateBoolean(KEY_IS_NEW_3DS, value);
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_game_perf_hacks'),
            description: I18n.t('settings_game_perf_hacks_desc'),
            isOn: this.gamePerfHacks,
            onToggle: (value: boolean) => {
              this.gamePerfHacks = value;
              this.updateBoolean(KEY_GAME_PERF_HACKS, value);
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_lle_applets'),
            description: I18n.t('settings_lle_applets_desc'),
            isOn: this.lleApplets,
            onToggle: (value: boolean) => {
              this.lleApplets = value;
              this.updateBoolean(KEY_LLE_APPLETS, value);
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_online_lle_modules'),
            description: I18n.t('settings_online_lle_modules_desc'),
            isOn: this.enableRequiredOnlineLleModules,
            onToggle: (value: boolean) => {
              this.enableRequiredOnlineLleModules = value;
              this.updateBoolean(KEY_ENABLE_REQUIRED_ONLINE_LLE_MODULES, value);
            }
          })
        }
        ListItem() {
          SelectSettingItem({
            title: I18n.t('settings_save_state_slot_count'),
            description: I18n.t('settings_save_state_slot_count_desc'),
            options: SAVE_STATE_SLOT_COUNT_OPTIONS,
            selectedIndex: this.findOptionIndex(SAVE_STATE_SLOT_COUNT_OPTIONS, this.saveStateSlotCount),
            onSelect: (_index: number, value: string | number) => {
              this.saveStateSlotCount = value as number;
              void this.settingsManager.setNumber(KEY_SAVE_STATE_SLOT_COUNT, this.saveStateSlotCount);
            }
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      ListItem() {
        this.SectionHeader(I18n.t('settings_system_profile'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          ButtonSettingItem({
            title: I18n.t('system'),
            description: I18n.t('settings_system_profile_desc'),
            buttonText: I18n.t('open'),
            onItemClick: () => {
              this.openSystemProfileSettings();
            }
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      ListItem() {
        this.SectionHeader(I18n.t('settings_3gx_plugin_loader'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_3gx_plugin_loader'),
            description: I18n.t('settings_3gx_plugin_loader_desc'),
            isOn: this.pluginLoader,
            onToggle: (value: boolean) => {
              this.pluginLoader = value;
              this.updateBoolean(KEY_PLUGIN_LOADER, value);
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_allow_plugin_loader'),
            description: I18n.t('settings_allow_plugin_loader_desc'),
            isOn: this.allowPluginLoader,
            onToggle: (value: boolean) => {
              this.allowPluginLoader = value;
              this.updateBoolean(KEY_ALLOW_PLUGIN_LOADER, value);
            }
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
    }
  }
}
