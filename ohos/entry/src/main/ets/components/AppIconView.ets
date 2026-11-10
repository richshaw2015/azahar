/**
 * AppIconView - 应用图标视图
 *
 * 按当前选中的图标样式渲染应用图标（背景 + 前景层叠，等同桌面分层图标效果）。
 * 通过 AppStorage 的 appIconStyle 键联动 AppIconSelector：
 * 用户在设置中切换图标后，所有使用本组件的位置自动更新。
 *
 * withBackground=false 时仅渲染前景图（透明背景 logo 形态，用于首页标题栏）。
 * pinnedStyle 传入固定样式时不再跟随当前选择（用于选择器里的样式预览）。
 */

import { AppIconStyle, resolveAppIconStyle } from '../utils/AppIconManager';

@Component
export struct AppIconView {
  /** 图标边长（vp） */
  @Prop iconSize: number = 88;
  /** 是否渲染背景层 + 图标圆角；false 时仅渲染前景图 */
  @Prop withBackground: boolean = true;
  /** 固定展示的样式；null（缺省）时跟随 AppStorage 的当前样式 */
  @Prop pinnedStyle: AppIconStyle | null = null;
  /** 当前备用图标名称（'' = 默认图标），与 AppIconSelector 联动 */
  @StorageLink('appIconStyle') private alternateName: string = '';

  private currentStyle(): AppIconStyle {
    return this.pinnedStyle ?? resolveAppIconStyle(this.alternateName);
  }

  build() {
    if (this.withBackground) {
      Stack() {
        Image(this.currentStyle().backgroundSmall)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
        Image(this.currentStyle().foregroundSmall)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .syncLoad(true)
      }
      .width(this.iconSize)
      .height(this.iconSize)
      // 0.24 是系统应用图标遮罩的圆角比例，保持与桌面图标一致的几何
      .borderRadius(Math.round(this.iconSize * 0.24))
      .clip(true)
    } else {
      // 同步解码：标题栏叠层在 Tab 切换时会随页面 build 重建，异步解码的首帧
      // 空白会让图标闪一下；挂载时同步解码保证第一帧就有像素
      Image(this.currentStyle().foregroundSmall)
        .width(this.iconSize)
        .height(this.iconSize)
        .objectFit(ImageFit.Contain)
        .syncLoad(true)
    }
  }
}
