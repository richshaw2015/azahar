import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { GlobalWallpaper } from '../../components/common/GlobalWallpaper';
import { SelectSettingItem } from '../../components/settings/SelectSettingItem';
import { SettingsList, SettingsSectionHeader, settingsGroupDivider, menuGroupMargin, menuGroupPadding } from '../../components/settings/SettingsList';
import { FloatTilesBackground } from '../../components/theme/FloatTilesBackground';
import { AzaharCameraDeviceInfo, AzaharNative } from '../../types/AzaharNative';
import { AzaharTheme, AzaharThemeColors } from '../../types/ThemeTypes';
import { AzaharNavPage } from '../../components/common/AzaharNavPage';
import { KEY_CAMERA_INNER_CONFIG, KEY_CAMERA_INNER_FLIP, KEY_CAMERA_INNER_NAME, KEY_CAMERA_OUTER_LEFT_CONFIG, KEY_CAMERA_OUTER_LEFT_FLIP, KEY_CAMERA_OUTER_LEFT_NAME, KEY_CAMERA_OUTER_RIGHT_CONFIG, KEY_CAMERA_OUTER_RIGHT_FLIP, KEY_CAMERA_OUTER_RIGHT_NAME, SettingOption } from '../../types/SettingsTypes';
import { gamepadBackHandler } from '../../utils/GamepadUIHelper';
import { I18n } from '../../utils/I18nManager';
import { PAGE_TRANSITION_DURATION } from '../../utils/PageTransitionHelper';
import { SettingsManager } from '../../utils/SettingsManager';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { ThemeManager } from '../../utils/ThemeManager';
import { listCardBgOf } from '../../utils/ThemeSurfaces';

interface CameraSlot {
  id: string;
  title: string;
  description: string;
  nameKey: string;
  configKey: string;
  flipKey: string;
}

const CAMERA_SOURCE_SEQUENCE: string[] = ['blank', 'image', 'ohos'];
const CAMERA_SOURCE_LABEL_KEYS: string[] = ['camera_source_blank', 'camera_source_image', 'camera_source_system'];
// 与 Android cameraDeviceValues 一致：空=默认设备、_front/_back=按朝向匹配
const CAMERA_DEVICE_PLACEHOLDERS: string[] = ['', '_front', '_back'];
const CAMERA_DEVICE_PLACEHOLDER_KEYS: string[] = ['default', 'camera_any_front', 'camera_any_back'];
const CAMERA_FLIP_OPTIONS: string[] = [
  'camera_flip_none',
  'camera_flip_horizontal',
  'camera_flip_vertical',
  'camera_flip_reverse'
];

@Entry
@Component
struct CameraSettings {
  @State private outerRightName: string = 'ohos';
  @State private outerRightConfig: string = '_back';
  @State private outerRightFlip: number = 0;
  @State private innerName: string = 'ohos';
  @State private innerConfig: string = '_front';
  @State private innerFlip: number = 0;
  @State private outerLeftName: string = 'ohos';
  @State private outerLeftConfig: string = '_back';
  @State private outerLeftFlip: number = 0;
  @State private cameraDevices: AzaharCameraDeviceInfo[] = [];
  @State private themeColors: AzaharThemeColors = ThemeManager.getInstance().getCurrentColors();
  @StorageLink('globalWallpaperUri') globalWallpaperUri: string = '';
  @StorageLink('safeAreaBottomVp') safeAreaBottomVp: number = 0;

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private pageScroller: Scroller = new Scroller();
  private settingsManager: SettingsManager = SettingsManager.getInstance();
  private themeManager: ThemeManager = ThemeManager.getInstance();
  private soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  private themeChangeListener: ((theme: AzaharTheme) => void) | null = null;

  async aboutToAppear(): Promise<void> {
    await this.soundEffectManager.initialize(this.context);
    await this.initializePage();
  }

  aboutToDisappear(): void {
    if (this.themeChangeListener) {
      this.themeManager.removeListener(this.themeChangeListener);
      this.themeChangeListener = null;
    }
  }

  private async initializePage(): Promise<void> {
    await this.settingsManager.initialize(this.context);
    await this.themeManager.initialize(this.context);
    this.loadCameraSettings();
    this.cameraDevices = AzaharNative.getCameraDevices();
    this.themeColors = this.themeManager.getCurrentColors();
    this.themeChangeListener = (_theme: AzaharTheme) => {
      this.themeColors = this.themeManager.getCurrentColors();
    };
    this.themeManager.addListener(this.themeChangeListener);
  }

  private loadCameraSettings(): void {
    this.outerRightName = this.settingsManager.getString(KEY_CAMERA_OUTER_RIGHT_NAME) || 'ohos';
    this.outerRightConfig = this.settingsManager.getString(KEY_CAMERA_OUTER_RIGHT_CONFIG);
    this.outerRightFlip = this.settingsManager.getNumber(KEY_CAMERA_OUTER_RIGHT_FLIP);
    this.innerName = this.settingsManager.getString(KEY_CAMERA_INNER_NAME) || 'ohos';
    this.innerConfig = this.settingsManager.getString(KEY_CAMERA_INNER_CONFIG);
    this.innerFlip = this.settingsManager.getNumber(KEY_CAMERA_INNER_FLIP);
    this.outerLeftName = this.settingsManager.getString(KEY_CAMERA_OUTER_LEFT_NAME) || 'ohos';
    this.outerLeftConfig = this.settingsManager.getString(KEY_CAMERA_OUTER_LEFT_CONFIG);
    this.outerLeftFlip = this.settingsManager.getNumber(KEY_CAMERA_OUTER_LEFT_FLIP);
  }

  private getSlots(): CameraSlot[] {
    return [
      {
        id: 'inner',
        title: I18n.t('camera_inner'),
        description: '',
        nameKey: 'camera_inner_name',
        configKey: 'camera_inner_config',
        flipKey: 'camera_inner_flip'
      },
      {
        id: 'outer_left',
        title: I18n.t('camera_outer_left'),
        description: '',
        nameKey: 'camera_outer_left_name',
        configKey: 'camera_outer_left_config',
        flipKey: 'camera_outer_left_flip'
      },
      {
        id: 'outer_right',
        title: I18n.t('camera_outer_right'),
        description: '',
        nameKey: 'camera_outer_right_name',
        configKey: 'camera_outer_right_config',
        flipKey: 'camera_outer_right_flip'
      }
    ];
  }

  private getSlotSource(slot: CameraSlot): string {
    if (slot.id === 'outer_right') {
      return this.outerRightName;
    }
    if (slot.id === 'inner') {
      return this.innerName;
    }
    return this.outerLeftName;
  }

  private getSlotConfig(slot: CameraSlot): string {
    if (slot.id === 'outer_right') {
      return this.outerRightConfig;
    }
    if (slot.id === 'inner') {
      return this.innerConfig;
    }
    return this.outerLeftConfig;
  }

  private getSlotFlip(slot: CameraSlot): number {
    if (slot.id === 'outer_right') {
      return this.outerRightFlip;
    }
    if (slot.id === 'inner') {
      return this.innerFlip;
    }
    return this.outerLeftFlip;
  }

  private async setSlotSource(slot: CameraSlot, value: string): Promise<void> {
    if (slot.id === 'outer_right') {
      this.outerRightName = value;
    } else if (slot.id === 'inner') {
      this.innerName = value;
    } else {
      this.outerLeftName = value;
    }
    await this.settingsManager.setString(slot.nameKey, value);
    if (value === 'ohos') {
      // 与 Android camera_device 语义一致："_front"/"_back" 占位符按朝向选择物理摄像头
      await this.setSlotConfig(slot, slot.id === 'inner' ? '_front' : '_back');
      return;
    }
    AzaharNative.applyConfig();
  }

  private async setSlotConfig(slot: CameraSlot, value: string): Promise<void> {
    if (slot.id === 'outer_right') {
      this.outerRightConfig = value;
    } else if (slot.id === 'inner') {
      this.innerConfig = value;
    } else {
      this.outerLeftConfig = value;
    }
    await this.settingsManager.setString(slot.configKey, value);
    AzaharNative.applyConfig();
  }

  private async setSlotFlip(slot: CameraSlot, value: number): Promise<void> {
    if (slot.id === 'outer_right') {
      this.outerRightFlip = value;
    } else if (slot.id === 'inner') {
      this.innerFlip = value;
    } else {
      this.outerLeftFlip = value;
    }
    await this.settingsManager.setNumber(slot.flipKey, value);
    AzaharNative.applyConfig();
  }

  private sourceIndex(source: string): number {
    const index = CAMERA_SOURCE_SEQUENCE.indexOf(source);
    return index >= 0 ? index : 0;
  }

  // 与 Android Camera Device 选项一致：默认 / 任意前置 / 任意后置 + 物理设备列表
  private cameraDeviceOptions(): SettingOption[] {
    const options: SettingOption[] = CAMERA_DEVICE_PLACEHOLDERS.map(
      (value: string, index: number): SettingOption =>
        ({ value: value, label: I18n.t(CAMERA_DEVICE_PLACEHOLDER_KEYS[index]) }));
    this.cameraDevices.forEach((device: AzaharCameraDeviceInfo) => {
      options.push({ value: device.id, label: this.cameraDeviceLabel(device) });
    });
    return options;
  }

  private cameraDeviceIndex(config: string): number {
    const values: string[] = CAMERA_DEVICE_PLACEHOLDERS.concat(
      this.cameraDevices.map((device: AzaharCameraDeviceInfo) => device.id));
    const index = values.indexOf(config);
    return index >= 0 ? index : 0;
  }

  private cameraFacingKey(position: number): string {
    if (position === 2) { // CAMERA_POSITION_FRONT
      return 'camera_facing_front';
    }
    if (position === 1) { // CAMERA_POSITION_BACK
      return 'camera_facing_back';
    }
    return 'camera_facing_external';
  }

  private cameraTypeKey(type: number): string {
    switch (type) {
      case 1: // CAMERA_TYPE_WIDE_ANGLE
        return 'camera_type_wide';
      case 2: // CAMERA_TYPE_ULTRA_WIDE
        return 'camera_type_ultra_wide';
      case 3: // CAMERA_TYPE_TELEPHOTO
        return 'camera_type_telephoto';
      case 4: // CAMERA_TYPE_TRUE_DEPTH
        return 'camera_type_true_depth';
      default: // CAMERA_TYPE_DEFAULT：不附加类型标签
        return '';
    }
  }

  // Android 格式 "0 (Back)"；非默认镜头类型追加 "·超广角" 等类型标签
  private cameraDeviceLabel(device: AzaharCameraDeviceInfo): string {
    const parts: string[] = [I18n.t(this.cameraFacingKey(device.position))];
    const typeKey = this.cameraTypeKey(device.type);
    if (typeKey) {
      parts.push(I18n.t(typeKey));
    }
    return `${device.id}（${parts.join('·')}）`;
  }

  @Builder
  SectionHeader(title: string) {
    SettingsSectionHeader({ title })
  }

  @Builder
  CameraSlotSection(slot: CameraSlot) {
    ListItem() {
      this.SectionHeader(slot.title)
    }
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
      ListItem() {
        SelectSettingItem({
          title: I18n.t('camera_source'),
          description: I18n.t('camera_source_desc'),
          options: CAMERA_SOURCE_LABEL_KEYS.map((key: string, index: number): SettingOption =>
            ({ value: CAMERA_SOURCE_SEQUENCE[index], label: I18n.t(key) })),
          selectedIndex: this.sourceIndex(this.getSlotSource(slot)),
          onSelect: (_index: number, value: string | number) => {
            this.setSlotSource(slot, value as string);
          }
        })
      }
      // 与 Android 一致：设备枚举非空时始终显示 Camera 行（不限于系统相机来源）
      if (this.cameraDevices.length > 0) {
        ListItem() {
          SelectSettingItem({
            title: I18n.t('camera_device'),
            description: I18n.t('camera_device_desc'),
            options: this.cameraDeviceOptions(),
            selectedIndex: this.cameraDeviceIndex(this.getSlotConfig(slot)),
            onSelect: (_index: number, value: string | number) => {
              this.setSlotConfig(slot, value as string);
            }
          })
        }
      }
      ListItem() {
        SelectSettingItem({
          title: I18n.t('camera_flip'),
          options: CAMERA_FLIP_OPTIONS.map((key: string, index: number): SettingOption =>
            ({ value: index, label: I18n.t(key) })),
          selectedIndex: this.getSlotFlip(slot),
          onSelect: (_index: number, value: string | number) => {
            this.setSlotFlip(slot, value as number);
          }
        })
      }
    }
    .padding(menuGroupPadding())
    .backgroundColor(listCardBgOf(this.themeColors))
    .divider(settingsGroupDivider())
    .margin(menuGroupMargin())
  }

  build() {
    Stack() {
      if (this.globalWallpaperUri) {
        GlobalWallpaper()
      } else {
        FloatTilesBackground({
          themeColors: this.themeColors,
          isPlaying: false
        })
      }

      AzaharNavPage({
        title: I18n.t('settings_camera'),
        scrollers: [this.pageScroller],
        onBack: () => {
          this.soundEffectManager.play(SoundEffect.BACK);
          router.back();
        }
      }) {
        SettingsList({ scroller: this.pageScroller }) {
          ForEach(this.getSlots(), (slot: CameraSlot) => {
            this.CameraSlotSection(slot)
          }, (slot: CameraSlot) => slot.id)
        }
      }
    }
    .width('100%')
    .height('100%')
    .onKeyEvent(gamepadBackHandler())
  }

  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Right)
    PageTransitionEnter({ type: RouteType.Pop, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Push, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Pop, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Right)
  }
}
