import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { GlobalWallpaper } from '../common/GlobalWallpaper';
import { AzaharNavMenuItem, AzaharNavPage } from '../common/AzaharNavPage';
import { FloatTilesBackground } from '../theme/FloatTilesBackground';
import { AzaharTheme, AzaharThemeColors } from '../../types/ThemeTypes';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { ThemeManager } from '../../utils/ThemeManager';
import { initToastHelper } from '../../utils/ToastHelper';

@Component
export struct SettingsContentPage {
  @Prop title: string = '';
  @Prop subtitle: ResourceStr = '';
  @Prop backgroundAnimationEnabled: boolean = false;
  scrollers: Scroller[] = [];
  menuItems: AzaharNavMenuItem[] = [];
  bottomBuilder?: () => void;
  bottomBuilderHeight: number = 0;
  @BuilderParam content: () => void;

  @State themeColors: AzaharThemeColors = ThemeManager.getInstance().getCurrentColors();
  @StorageLink('globalWallpaperUri') wallpaperUri: string = '';
  @StorageLink('safeAreaBottomVp') safeAreaBottomVp: number = 0;

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private themeManager: ThemeManager = ThemeManager.getInstance();
  private soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  private themeChangeListener: ((theme: AzaharTheme) => void) | null = null;

  async aboutToAppear(): Promise<void> {
    initToastHelper(this.getUIContext());
    await this.soundEffectManager.initialize(this.context);
    await this.themeManager.initialize(this.context);
    this.themeColors = this.themeManager.getCurrentColors();
    if (!this.themeChangeListener) {
      this.themeChangeListener = (_theme: AzaharTheme) => {
        this.themeColors = this.themeManager.getCurrentColors();
      };
      this.themeManager.addListener(this.themeChangeListener);
    }
  }

  aboutToDisappear(): void {
    if (this.themeChangeListener) {
      this.themeManager.removeListener(this.themeChangeListener);
      this.themeChangeListener = null;
    }
  }

  build() {
    Stack() {
      if (this.wallpaperUri) {
        GlobalWallpaper()
      } else {
        FloatTilesBackground({
          themeColors: this.themeColors,
          isPlaying: this.backgroundAnimationEnabled
        })
      }

      AzaharNavPage({
        title: this.title,
        subtitle: this.subtitle,
        menuItems: this.menuItems,
        scrollers: this.scrollers,
        bottomBuilder: this.bottomBuilder,
        bottomBuilderHeight: this.bottomBuilderHeight,
        onBack: () => {
          this.soundEffectManager.play(SoundEffect.BACK);
          router.back();
        }
      }) {
        this.content()
      }
    }
    .width('100%')
    .height('100%')
  }
}
