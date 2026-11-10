import { common } from '@kit.AbilityKit';
import { ComposeListItem } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { ButtonSettingItem } from '../ButtonSettingItem';
import { DatePickerItem } from '../DatePickerItem';
import { SelectSettingItem } from '../SelectSettingItem';
import { SliderSettingItem } from '../SliderSettingItem';
import { TextInputSettingItem } from '../TextInputSettingItem';
import { ToggleSettingItem } from '../ToggleSettingItem';
import { SettingsList, SettingsSectionHeader, settingsGroupDivider, StaticInfoRow, menuGroupMargin, menuGroupPadding } from '../SettingsList';
import { KEY_APPLY_REGION_FREE_PATCH, KEY_INIT_CLOCK, KEY_INIT_TIME, KEY_REGION_VALUE, KEY_STEPS_PER_HOUR, SettingOption } from '../../../types/SettingsTypes';
import { AzaharNative, AzaharSystemProfile } from '../../../types/AzaharNative';
import { COUNTRY_ISO_CODES } from '../../../utils/CountryCodes';
import { DeviceProfile } from '../../../utils/DeviceProfile';
import { I18n } from '../../../utils/I18nManager';
import { SettingsManager } from '../../../utils/SettingsManager';
import { SoundEffect, SoundEffectManager } from '../../../utils/SoundEffectManager';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';
import { showErrorToast, showSuccessToast } from '../../../utils/ToastHelper';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';
import { AzaharThemeColors } from '../../../types/ThemeTypes';



@Component
export struct SystemProfileSettingsContent {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  scroller?: Scroller;
  @State deviceType: string = 'phone';
  @State regionValue: number = -1;
  @State applyRegionFreePatch: boolean = true;
  @State initClock: number = 0;
  @State initTime: number = 946731601;
  @State stepsPerHour: number = 0;
  @State systemProfileAvailable: boolean = false;
  @State profileUsername: string = '';
  @State profileBirthMonth: number = 1;
  @State profileBirthDay: number = 1;
  @State profileLanguage: number = 1;
  @State profileCountryCode: number = 1;
  @State profilePlayCoins: number = 0;
  @State profileMacAddress: string = '';
  @State profileConsoleIdText: string = '';

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private settingsManager: SettingsManager = SettingsManager.getInstance();
  private soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  private countryOptionsCache: SettingOption[] = [];

  async aboutToAppear(): Promise<void> {
    await this.settingsManager.initialize(this.context);
    await this.soundEffectManager.initialize(this.context);
    this.deviceType = DeviceProfile.getDeviceType();
    this.countryOptionsCache = this.buildCountryOptions();
    this.loadSettings();
    this.loadSystemProfile();
    this.checkCountryCompatibility();
  }

  private loadSettings(): void {
    this.regionValue = this.settingsManager.getNumber(KEY_REGION_VALUE);
    this.applyRegionFreePatch = this.settingsManager.getBoolean(KEY_APPLY_REGION_FREE_PATCH);
    this.initClock = this.settingsManager.getNumber(KEY_INIT_CLOCK);
    this.initTime = this.settingsManager.getNumber(KEY_INIT_TIME);
    this.stepsPerHour = this.settingsManager.getNumber(KEY_STEPS_PER_HOUR);
  }

  private async updateNumber(key: string, value: number): Promise<void> {
    await this.settingsManager.setNumber(key, value);
    AzaharNative.applyConfig();
  }

  private async updateBoolean(key: string, value: boolean): Promise<void> {
    await this.settingsManager.setBoolean(key, value);
    AzaharNative.applyConfig();
  }

  private loadSystemProfile(): void {
    try {
      this.applySystemProfile(AzaharNative.getSystemProfile());
    } catch (_error) {
      this.systemProfileAvailable = false;
    }
  }

  private applySystemProfile(profile: AzaharSystemProfile): void {
    this.systemProfileAvailable = profile.available;
    this.profileUsername = profile.username;
    this.profileBirthMonth = Math.max(1, Math.min(12, Math.trunc(profile.birthMonth)));
    this.profileBirthDay = Math.max(1, Math.min(31, Math.trunc(profile.birthDay)));
    this.profileLanguage = Math.max(0, Math.min(11, Math.trunc(profile.language)));
    this.profileCountryCode = Math.max(0, Math.min(186, Math.trunc(profile.countryCode)));
    this.profilePlayCoins = Math.max(0, Math.min(300, Math.trunc(profile.playCoins)));
    this.profileMacAddress = profile.macAddress;
    this.profileConsoleIdText = profile.consoleIdText || `${profile.consoleId}`;
  }

  // 对齐 Android checkCountryCompatibility：模拟区域 / 关联主机区域 与 CFG 国家不匹配时告警
  private checkCountryCompatibility(): void {
    let flags = 0;
    try {
      flags = AzaharNative.getCountryCompatibility(this.regionValue);
    } catch (_error) {
      return;
    }
    if (flags === 0) {
      return;
    }
    let message = '';
    if ((flags & 1) !== 0) {
      message += I18n.t('region_mismatch_emulated');
    }
    if ((flags & 2) !== 0) {
      if (message.length > 0) {
        message += '\n\n';
      }
      message += I18n.t('region_mismatch_console');
    }
    this.getUIContext().showAlertDialog({
      title: I18n.t('region_mismatch'),
      message,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      buttons: [{
        value: I18n.t('got_it'),
        style: DialogButtonStyle.HIGHLIGHT,
        fontColor: ThemeManager.getInstance().getControlAccent(),
        action: () => {
          this.soundEffectManager.play(SoundEffect.DECIDE);
        }
      }],
      cancel: () => {
        this.soundEffectManager.play(SoundEffect.BACK);
      }
    });
  }

  // 与 Android 一致：资料字段修改即写 CFG 存档，无保存按钮
  private writeProfileField(apply: (profile: AzaharSystemProfile) => void): void {
    if (!this.systemProfileAvailable) {
      return;
    }
    try {
      const profile = AzaharNative.getSystemProfile();
      if (!profile.available) {
        return;
      }
      apply(profile);
      AzaharNative.setSystemProfile(profile);
    } catch (_error) {
      console.warn(`setSystemProfile failed: ${(_error as Error)?.message}`);
    }
  }

  // Nintendo 国家码索引 → 本地化国家名（ISO 3166 alpha-2 经 i18n 翻译），
  // 选项值保留原始索引，与 Android R.array.countries 一致
  private buildCountryOptions(): SettingOption[] {
    const locale = i18n.System.getSystemLocale();
    const options: SettingOption[] = [];
    for (let index = 0; index < COUNTRY_ISO_CODES.length; index++) {
      const iso = COUNTRY_ISO_CODES[index];
      if (iso.length === 0) {
        continue;
      }
      let label = '';
      try {
        label = i18n.System.getDisplayCountry(iso, locale);
      } catch (_error) {
        label = '';
      }
      options.push({ value: index, label: label.length > 0 ? label : iso });
    }
    return options;
  }

  private countrySelectedIndex(): number {
    const index = this.countryOptionsCache.findIndex((option: SettingOption) => option.value === this.profileCountryCode);
    return index >= 0 ? index : 0;
  }

  private confirmRegenerate(title: string, message: string, onConfirm: () => void): void {
    this.getUIContext().showAlertDialog({
      title: title,
      message: message,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: I18n.t('confirm'),
        fontColor: ThemeManager.getInstance().getControlAccent(),
        action: () => {
          this.soundEffectManager.play(SoundEffect.DECIDE);
          onConfirm();
        }
      },
      secondaryButton: {
        value: I18n.t('cancel'),
        fontColor: ThemeManager.getInstance().getControlAccent(),
        action: () => {
          this.soundEffectManager.play(SoundEffect.BACK);
        }
      },
      cancel: () => {
        this.soundEffectManager.play(SoundEffect.BACK);
      }
    });
  }

  private regenerateConsoleId(): void {
    try {
      const next = AzaharNative.regenerateConsoleId();
      if (next.length > 0) {
        this.profileConsoleIdText = next;
        this.soundEffectManager.play(SoundEffect.CONFIRM);
        showSuccessToast(I18n.t('system_profile_saved'));
      } else {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(I18n.t('system_profile_save_failed'));
      }
    } catch (_error) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('system_profile_save_failed'));
    }
  }

  private regenerateMacAddress(): void {
    try {
      const next = AzaharNative.regenerateMacAddress();
      if (next.length > 0) {
        this.profileMacAddress = next;
        this.soundEffectManager.play(SoundEffect.CONFIRM);
        showSuccessToast(I18n.t('system_profile_saved'));
      } else {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(I18n.t('system_profile_save_failed'));
      }
    } catch (_error) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('system_profile_save_failed'));
    }
  }

  private openSimulatedClockPicker(): void {
    const accent: string = ThemeManager.getInstance().getControlAccent();
    this.getUIContext().showDatePickerDialog({
      start: new Date(2000, 0, 1),
      end: new Date(2100, 11, 31, 23, 59),
      selected: new Date(this.initTime * 1000),
      showTime: true,
      useMilitaryTime: true,
      selectedTextStyle: { color: accent },
      acceptButtonStyle: { fontColor: accent },
      onDateAccept: (value: Date) => {
        const next = Math.max(0, Math.trunc(value.getTime() / 1000));
        this.initTime = next;
        this.updateNumber(KEY_INIT_TIME, next);
      }
    });
  }

  private formatSimulatedClock(): string {
    const date = new Date(this.initTime * 1000);
    const pad = (n: number): string => n.toString().padStart(2, '0');
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }

  private options(keys: string[]): SettingOption[] {
    return keys.map((key: string, index: number): SettingOption => ({ value: index, label: I18n.t(key) }));
  }

  @Builder
  SectionHeader(title: string) {
    SettingsSectionHeader({ title })
  }

  @Builder
  ModuleRow(title: string, description: string, status: string) {
    // 纯信息展示行，无点击事件——用无按压态的静态行
    StaticInfoRow({ title: title, desc: description, value: status })
  }

  @Builder
  SimulatedClockRow() {
    ComposeListItem({
      contentItem: {
        primaryText: I18n.t('simulated_clock')
      },
      operateItem: {
        text: this.formatSimulatedClock(),
        arrow: {
          value: $r('sys.symbol.chevron_right')
        }
      }
    })
    .onFocus(() => {
      this.soundEffectManager.play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      this.soundEffectManager.play(SoundEffect.DECIDE);
      this.openSimulatedClockPicker();
    })
  }

  build() {
    SettingsList({ scroller: this.scroller }) {
      ListItem() {
        this.SectionHeader(I18n.t('settings_system_profile'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        if (!this.systemProfileAvailable) {
          ListItem() {
            this.ModuleRow(I18n.t('cfg_ptm'), I18n.t('settings_cfg_ptm_desc'), I18n.t('not_ready'))
          }
        } else {
          ListItem() {
            SelectSettingItem({
              title: I18n.t('settings_system_region'),
              options: this.options(['auto', 'region_japan', 'region_usa', 'region_europe',
                'region_australia', 'region_china', 'region_korea', 'region_taiwan']),
              selectedIndex: this.regionValue + 1,
              onSelect: (_index: number, value: string | number) => {
                const next = (value as number) - 1;
                this.regionValue = next;
                this.updateNumber(KEY_REGION_VALUE, next);
                this.checkCountryCompatibility();
              }
            })
          }
          ListItem() {
            ToggleSettingItem({
              title: I18n.t('settings_region_free_patch'),
              description: I18n.t('settings_region_free_patch_desc'),
              isOn: this.applyRegionFreePatch,
              onToggle: (value: boolean) => {
                this.applyRegionFreePatch = value;
                this.updateBoolean(KEY_APPLY_REGION_FREE_PATCH, value);
              }
            })
          }
          ListItem() {
            SelectSettingItem({
              title: I18n.t('settings_country_code'),
              options: this.countryOptionsCache,
              selectedIndex: this.countrySelectedIndex(),
              onSelect: (_index: number, value: string | number) => {
                this.profileCountryCode = value as number;
                this.writeProfileField((profile: AzaharSystemProfile) => {
                  profile.countryCode = this.profileCountryCode;
                });
                this.checkCountryCompatibility();
              }
            })
          }
          ListItem() {
            SelectSettingItem({
              title: I18n.t('language'),
              options: this.options(['language_japanese', 'language_english', 'language_french',
                'language_german', 'language_italian', 'language_spanish', 'language_simplified_chinese',
                'language_korean', 'language_dutch', 'language_portuguese', 'language_russian',
                'language_traditional_chinese']),
              selectedIndex: this.profileLanguage,
              onSelect: (_index: number, value: string | number) => {
                this.profileLanguage = value as number;
                this.writeProfileField((profile: AzaharSystemProfile) => {
                  profile.language = this.profileLanguage;
                });
              }
            })
          }
          ListItem() {
            TextInputSettingItem({
              title: I18n.t('username'),
              description: I18n.t('settings_username_desc'),
              value: this.profileUsername,
              placeholder: I18n.t('placeholder_username'),
              maxLength: 10,
              showCounter: false,
              onChange: (value: string) => {
                this.profileUsername = value;
                this.writeProfileField((profile: AzaharSystemProfile) => {
                  profile.username = this.profileUsername.trim();
                });
              }
            })
          }
          ListItem() {
            SliderSettingItem({
              title: I18n.t('settings_play_coins'),
              value: this.profilePlayCoins,
              min: 0,
              max: 300,
              step: 1,
              formatValue: (value: number): string => `${value}`,
              onChange: (value: number) => {
                this.profilePlayCoins = value;
                this.writeProfileField((profile: AzaharSystemProfile) => {
                  profile.playCoins = this.profilePlayCoins;
                });
              }
            })
          }
          ListItem() {
            SliderSettingItem({
              title: I18n.t('settings_steps_per_hour'),
              description: I18n.t('settings_steps_per_hour_desc'),
              value: this.stepsPerHour,
              min: 0,
              max: 65535,
              step: 100,
              formatValue: (value: number): string => `${value}`,
              onChange: (value: number) => {
                this.stepsPerHour = value;
                this.updateNumber(KEY_STEPS_PER_HOUR, value);
              }
            })
          }
          ListItem() {
            ButtonSettingItem({
              title: I18n.t('console_id'),
              description: this.profileConsoleIdText,
              buttonText: I18n.t('regenerate'),
              showArrow: false,
              onItemClick: () => {
                this.confirmRegenerate(I18n.t('regenerate_console_id'),
                  I18n.t('regenerate_console_id_desc'), () => {
                    this.regenerateConsoleId();
                  });
              }
            })
          }
          ListItem() {
            ButtonSettingItem({
              title: I18n.t('mac_address'),
              description: this.profileMacAddress,
              buttonText: I18n.t('regenerate'),
              showArrow: false,
              onItemClick: () => {
                this.confirmRegenerate(I18n.t('regenerate_mac_address'),
                  I18n.t('regenerate_mac_address_desc'), () => {
                    this.regenerateMacAddress();
                  });
              }
            })
          }
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      if (this.systemProfileAvailable) {
        ListItem() {
          this.SectionHeader(I18n.t('birthday'))
        }
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem() {
            DatePickerItem({
              title: I18n.t('birthday'),
              month: this.profileBirthMonth,
              day: this.profileBirthDay,
              onSelect: (month: number, day: number) => {
                this.profileBirthMonth = month;
                this.profileBirthDay = day;
                this.writeProfileField((profile: AzaharSystemProfile) => {
                  profile.birthMonth = month;
                  profile.birthDay = day;
                });
              }
            })
          }
        }
        .padding(menuGroupPadding())
        .backgroundColor(listCardBgOf(this.themeColors))
        .divider(settingsGroupDivider())
        .margin(menuGroupMargin())
      }

      ListItem() {
        this.SectionHeader(I18n.t('clock'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          SelectSettingItem({
            title: I18n.t('settings_3ds_clock'),
            description: I18n.t('settings_3ds_clock_desc'),
            options: this.options(['device_time', 'fixed_time']),
            selectedIndex: this.initClock,
            onSelect: (_index: number, value: string | number) => {
              const next = value as number;
              this.initClock = next;
              this.updateNumber(KEY_INIT_CLOCK, next);
            }
          })
        }
        if (this.initClock === 1) {
          ListItem() {
            this.SimulatedClockRow()
          }
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
    }
  }
}
