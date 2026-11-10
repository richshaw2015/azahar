import { common } from '@kit.AbilityKit';
import { SelectSettingItem } from '../SelectSettingItem';
import { SliderSettingItem } from '../SliderSettingItem';
import { ToggleSettingItem } from '../ToggleSettingItem';
import { SettingsList, SettingsSectionHeader, settingsGroupDivider, menuGroupMargin, menuGroupPadding } from '../SettingsList';
import { KEY_AUDIO_INPUT_TYPE, KEY_BGM_ENABLED, KEY_BGM_VOLUME, KEY_ENABLE_AUDIO_STRETCHING, KEY_ENABLE_REALTIME_AUDIO, KEY_SFX_ENABLED, KEY_SFX_VOLUME, KEY_SIMULATE_HEADPHONES_PLUGGED, KEY_VOLUME, SettingOption } from '../../../types/SettingsTypes';
import { AzaharNative } from '../../../types/AzaharNative';
import { BackgroundMusicManager } from '../../../utils/BackgroundMusicManager';
import { DeviceProfile } from '../../../utils/DeviceProfile';
import { I18n } from '../../../utils/I18nManager';
import { SettingsManager } from '../../../utils/SettingsManager';
import { SoundEffectManager } from '../../../utils/SoundEffectManager';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';
import { AzaharThemeColors } from '../../../types/ThemeTypes';

@Component
export struct AudioSettingsContent {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  scroller?: Scroller;
  @State enableRealtimeAudio: boolean = false;
  @State enableAudioStretching: boolean = false;
  @State simulateHeadphones: boolean = false;
  @State volume: number = 1;
  @State bgmEnabled: boolean = true;
  @State bgmVolume: number = 20;
  @State soundOutputMode: number = 1;
  @State systemProfileAvailable: boolean = false;
  @State audioInputType: number = 0;
  @State sfxEnabled: boolean = true;
  @State sfxVolume: number = 30;

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
    this.enableRealtimeAudio = this.settingsManager.getBoolean(KEY_ENABLE_REALTIME_AUDIO);
    this.enableAudioStretching = this.settingsManager.getBoolean(KEY_ENABLE_AUDIO_STRETCHING);
    this.simulateHeadphones = this.settingsManager.getBoolean(KEY_SIMULATE_HEADPHONES_PLUGGED);
    this.volume = this.settingsManager.getNumber(KEY_VOLUME);
    this.bgmEnabled = this.settingsManager.getBoolean(KEY_BGM_ENABLED);
    this.bgmVolume = this.settingsManager.getNumber(KEY_BGM_VOLUME);
    try {
      const profile = AzaharNative.getSystemProfile();
      this.systemProfileAvailable = profile.available;
      this.soundOutputMode = Math.max(0, Math.min(2, Math.trunc(profile.soundOutputMode)));
    } catch (_error) {
      this.systemProfileAvailable = false;
    }
    this.audioInputType = this.settingsManager.getNumber(KEY_AUDIO_INPUT_TYPE);
    this.sfxEnabled = this.settingsManager.getBoolean(KEY_SFX_ENABLED);
    this.sfxVolume = this.settingsManager.getNumber(KEY_SFX_VOLUME);
  }

  // Android 放在音频分区，但写的是系统档案（CFG 存档），选中即写
  private updateSoundOutputMode(value: number): void {
    try {
      const profile = AzaharNative.getSystemProfile();
      if (!profile.available) {
        return;
      }
      profile.soundOutputMode = value;
      AzaharNative.setSystemProfile(profile);
    } catch (_error) {
      console.warn(`setSystemProfile failed: ${(_error as Error)?.message}`);
    }
  }

  private async updateBoolean(key: string, value: boolean): Promise<void> {
    await this.settingsManager.setBoolean(key, value);
    AzaharNative.applyConfig();
  }

  private async updateNumber(key: string, value: number): Promise<void> {
    await this.settingsManager.setNumber(key, value);
    AzaharNative.applyConfig();
  }

  private async updateBgmEnabled(value: boolean): Promise<void> {
    await this.updateBoolean(KEY_BGM_ENABLED, value);
    await BackgroundMusicManager.getInstance().setEnabled(value);
  }

  private async updateBgmVolume(value: number): Promise<void> {
    await this.updateNumber(KEY_BGM_VOLUME, value);
    BackgroundMusicManager.getInstance().setVolume(value);
  }

  private options(keys: string[]): SettingOption[] {
    return keys.map((key: string, index: number): SettingOption => ({ value: index, label: I18n.t(key) }));
  }

  private valueOptions(values: number[], keys: string[]): SettingOption[] {
    return keys.map((key: string, index: number): SettingOption =>
      ({ value: values[index], label: I18n.t(key) }));
  }

  private indexOfValue(options: SettingOption[], value: number): number {
    for (let i = 0; i < options.length; i++) {
      if (options[i].value === value) {
        return i;
      }
    }
    return 0;
  }

  @Builder
  SectionHeader(title: string) {
    SettingsSectionHeader({ title })
  }

  build() {
    SettingsList({ scroller: this.scroller }) {
      // 声音
      ListItem() {
        this.SectionHeader(I18n.t('audio_section_sound'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
        SliderSettingItem({
          title: I18n.t('volume'),
          value: this.volume * 100,
          min: 0,
          max: 100,
          step: 1,
          formatValue: (value: number): string => `${Math.round(value)}%`,
          onChange: (value: number) => {
            this.volume = value / 100;
            this.updateNumber(KEY_VOLUME, this.volume);
          }
        })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_realtime_audio'),
            description: I18n.t('settings_realtime_audio_desc'),
            isOn: this.enableRealtimeAudio,
            onToggle: (value: boolean) => {
              this.enableRealtimeAudio = value;
              this.updateBoolean(KEY_ENABLE_REALTIME_AUDIO, value);
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_audio_stretching'),
            description: I18n.t('settings_audio_stretching_desc'),
            isOn: this.enableAudioStretching,
            onToggle: (value: boolean) => {
              this.enableAudioStretching = value;
              this.updateBoolean(KEY_ENABLE_AUDIO_STRETCHING, value);
            }
          })
        }
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_simulate_headphones'),
          description: I18n.t('settings_simulate_headphones_desc'),
          isOn: this.simulateHeadphones,
          onToggle: (value: boolean) => {
            this.simulateHeadphones = value;
            this.updateBoolean(KEY_SIMULATE_HEADPHONES_PLUGGED, value);
          }
        })
        }
        if (this.systemProfileAvailable) {
          ListItem() {
          SelectSettingItem({
            title: I18n.t('settings_sound_output'),
            options: this.options(['audio_mono', 'audio_stereo', 'audio_surround']),
            selectedIndex: this.soundOutputMode,
            onSelect: (_index: number, value: string | number) => {
              const next = value as number;
              this.soundOutputMode = next;
              this.updateSoundOutputMode(next);
            }
          })
          }
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      // 麦克风（对齐 nds 分区与文案；InputType 枚举见 AudioCore）
      ListItem() {
        this.SectionHeader(I18n.t('section_mic'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
        SelectSettingItem({
          title: I18n.t('mic_source'),
          options: this.valueOptions([1, 7, 6, 2],
            ['none', 'opt_blow', 'opt_device_mic', 'opt_noise']),
          selectedIndex: this.indexOfValue(
            this.valueOptions([1, 7, 6, 2],
              ['none', 'opt_blow', 'opt_device_mic', 'opt_noise']),
            this.audioInputType),
          onSelect: (_index: number, value: string | number) => {
            this.audioInputType = value as number;
            this.updateNumber(KEY_AUDIO_INPUT_TYPE, value as number);
          }
        })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      // UI 音效（自手柄设置页迁入）；触感反馈在触屏按键设置页
      ListItem() {
        this.SectionHeader(I18n.t('settings_ui_sfx'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_ui_sfx'),
          isOn: this.sfxEnabled,
          onToggle: (value: boolean) => {
            this.sfxEnabled = value;
            this.updateBoolean(KEY_SFX_ENABLED, value);
          }
        })
        }
        ListItem() {
        SliderSettingItem({
          title: I18n.t('settings_ui_sfx_volume'),
          value: this.sfxVolume,
          min: 0,
          max: 100,
          step: 1,
          disabled: !this.sfxEnabled,
          formatValue: (value: number): string => `${value}%`,
          onChange: (value: number) => {
            this.sfxVolume = value;
            this.updateNumber(KEY_SFX_VOLUME, value);
          }
        })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      // 背景音乐
      ListItem() {
        this.SectionHeader(I18n.t('background_music'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('background_music'),
          description: I18n.t('settings_bgm_desc'),
          isOn: this.bgmEnabled,
          onToggle: (value: boolean) => {
            this.bgmEnabled = value;
            this.updateBgmEnabled(value);
          }
        })
        }
        ListItem() {
        SliderSettingItem({
          title: I18n.t('settings_bgm_volume'),
          value: this.bgmVolume,
          min: 0,
          max: 100,
          step: 1,
          disabled: !this.bgmEnabled,
          formatValue: (value: number): string => `${value}%`,
          onChange: (value: number) => {
            this.bgmVolume = value;
            this.updateBgmVolume(value);
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
