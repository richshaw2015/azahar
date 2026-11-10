import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { SliderSettingItem } from '../SliderSettingItem';
import { ToggleSettingItem } from '../ToggleSettingItem';
import { ButtonSettingItem } from '../ButtonSettingItem';
import { SelectSettingItem } from '../SelectSettingItem';
import { SettingsList, SettingsSectionHeader, settingsGroupDivider, menuGroupMargin, menuGroupPadding } from '../SettingsList';
import { DeviceProfile } from '../../../utils/DeviceProfile';
import { I18n } from '../../../utils/I18nManager';
import { SettingsManager } from '../../../utils/SettingsManager';
import { AzaharNative } from '../../../types/AzaharNative';
import { KEY_CONTROL_OPACITY, KEY_DISABLE_GESTURE_BACK_IN_GAME, KEY_INPUT_HAPTIC_ENABLED, KEY_INPUT_HAPTIC_STRENGTH, KEY_PRIVACY_MODE_IN_GAME, KEY_SOFT_INPUT_BEHAVIOUR, SettingOption } from '../../../types/SettingsTypes';
import { SoundEffectManager, SoundEffect } from '../../../utils/SoundEffectManager';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';
import { showErrorToast } from '../../../utils/ToastHelper';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';
import { AzaharThemeColors } from '../../../types/ThemeTypes';

const SOFT_INPUT_BEHAVIOUR_VALUES: string[] = [
  'always_visible',
  'hide_system_buttons_when_controller_connected',
  'always_invisible'
];

const SOFT_INPUT_BEHAVIOUR_LABEL_KEYS: string[] = [
  'opt_always_visible',
  'opt_hide_sys_btn',
  'opt_always_hidden'
];

@Component
export struct DisplaySettingsContent {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  scroller?: Scroller;
  @State inputOpacity: number = 70;
  @State softInputBehaviourIndex: number = 0;
  @State hapticEnabled: boolean = true;
  @State hapticStrength: number = 70;
  @State disableGestureBackInGame: boolean = false;
  @State privacyModeInGame: boolean = false;

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private settingsManager: SettingsManager = SettingsManager.getInstance();
  private soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  private deviceType: string = 'phone';

  async aboutToAppear(): Promise<void> {
    await this.settingsManager.initialize(this.context);
    await this.soundEffectManager.initialize(this.context);
    this.deviceType = DeviceProfile.getDeviceType();
    this.loadSettings();
  }

  private loadSettings(): void {
    this.inputOpacity = this.settingsManager.getNumber(KEY_CONTROL_OPACITY);
    const behaviour = this.settingsManager.getString(KEY_SOFT_INPUT_BEHAVIOUR);
    this.softInputBehaviourIndex = Math.max(0, SOFT_INPUT_BEHAVIOUR_VALUES.indexOf(behaviour));
    this.hapticEnabled = this.settingsManager.getBoolean(KEY_INPUT_HAPTIC_ENABLED) ?? true;
    this.hapticStrength = this.settingsManager.getNumber(KEY_INPUT_HAPTIC_STRENGTH) ?? 70;
    this.disableGestureBackInGame = this.settingsManager.getBoolean(KEY_DISABLE_GESTURE_BACK_IN_GAME) ?? false;
    this.privacyModeInGame = this.settingsManager.getBoolean(KEY_PRIVACY_MODE_IN_GAME) ?? false;
  }

  private async updateBoolean(key: string, value: boolean): Promise<void> {
    await this.settingsManager.setBoolean(key, value);
    AzaharNative.applyConfig();
  }

  private async updateNumber(key: string, value: number): Promise<void> {
    await this.settingsManager.setNumber(key, value);
    AzaharNative.applyConfig();
  }

  private softInputBehaviourOptions(): SettingOption[] {
    return SOFT_INPUT_BEHAVIOUR_VALUES.map((value: string, index: number): SettingOption => ({
      value: value,
      label: I18n.t(SOFT_INPUT_BEHAVIOUR_LABEL_KEYS[index])
    }));
  }

  @Builder
  SectionHeader(title: string) {
    SettingsSectionHeader({ title })
  }

  build() {
    SettingsList({ scroller: this.scroller }) {
      // 触屏虚拟按键布局管理
      ListItem() {
        this.SectionHeader(I18n.t('touch_section_display'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          ButtonSettingItem({
            title: I18n.t('touch_layout'),
            description: I18n.t('layout_manager_desc'),
            showArrow: true,
            onItemClick: () => {
              this.navigateToLayoutsSettings();
            }
          })
        }
        ListItem() {
          SelectSettingItem({
            title: I18n.t('soft_input_behaviour'),
            options: this.softInputBehaviourOptions(),
            selectedIndex: this.softInputBehaviourIndex,
            onSelect: (index: number, value: string | number) => {
              this.softInputBehaviourIndex = index;
              this.settingsManager.setString(KEY_SOFT_INPUT_BEHAVIOUR, value as string);
            }
          })
        }
        ListItem() {
          SliderSettingItem({
            title: I18n.t('input_opacity'),
            value: this.inputOpacity,
            min: 0,
            max: 100,
            step: 1,
            formatValue: (value: number): string => `${value}%`,
            onChange: (value: number) => {
              this.inputOpacity = value;
              this.updateNumber(KEY_CONTROL_OPACITY, value);
            }
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())
      // 按键震动反馈
      ListItem() {
        this.SectionHeader(I18n.t('touch_section_feedback'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('haptic_feedback'),
            isOn: this.hapticEnabled,
            onToggle: (value: boolean) => {
              this.hapticEnabled = value;
              this.updateBoolean(KEY_INPUT_HAPTIC_ENABLED, value);
            }
          })
        }
        ListItem() {
          SliderSettingItem({
            title: I18n.t('haptic_strength'),
            value: this.hapticStrength,
            min: 1,
            max: 100,
            step: 1,
            disabled: !this.hapticEnabled,
            formatValue: (value: number): string => `${value}%`,
            onChange: (value: number) => {
              this.hapticStrength = value;
              this.updateNumber(KEY_INPUT_HAPTIC_STRENGTH, value);
            }
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())
      // 系统手势控制
      ListItem() {
        this.SectionHeader(I18n.t('touch_section_system_gestures'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('disable_gesture_back_in_game'),
            description: I18n.t('disable_gesture_back_in_game_desc'),
            isOn: this.disableGestureBackInGame,
            onToggle: (value: boolean) => {
              this.disableGestureBackInGame = value;
              this.updateBoolean(KEY_DISABLE_GESTURE_BACK_IN_GAME, value);
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('privacy_mode_in_game'),
            description: I18n.t('privacy_mode_in_game_desc'),
            isOn: this.privacyModeInGame,
            onToggle: (value: boolean) => {
              this.onPrivacyModeInGameChange(value);
            }
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())

    }
  }

  // 仅开启时确认（关闭无需确认）；先同步为 true 与开关视觉一致，取消时回滚
  private onPrivacyModeInGameChange(isOn: boolean): void {
    if (!isOn) {
      this.privacyModeInGame = false;
      this.updateBoolean(KEY_PRIVACY_MODE_IN_GAME, false);
      return;
    }
    this.privacyModeInGame = true;
    this.getUIContext().showAlertDialog({
      title: I18n.t('privacy_mode_in_game'),
      message: I18n.t('privacy_mode_in_game_confirm'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: I18n.t('confirm'),
        fontColor: ThemeManager.getInstance().getControlAccent(),
        action: () => {
          this.soundEffectManager.play(SoundEffect.DECIDE);
          this.updateBoolean(KEY_PRIVACY_MODE_IN_GAME, true);
        }
      },
      secondaryButton: {
        value: I18n.t('cancel'),
        fontColor: ThemeManager.getInstance().getControlAccent(),
        action: () => {
          this.soundEffectManager.play(SoundEffect.BACK);
          this.privacyModeInGame = false;
        }
      },
      cancel: () => {
        this.soundEffectManager.play(SoundEffect.BACK);
        this.privacyModeInGame = false;
      }
    });
  }

  private navigateToLayoutsSettings(): void {
    SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
    router.pushUrl({
      url: 'pages/settings/LayoutsSettings'
    }).catch((err: Error) => {
      showErrorToast(I18n.tf1('open_failed_fmt', 'error', err.message));
    });
  }
}
