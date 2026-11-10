/**
 * 全屏加载遮罩的弹层内容：居中大转圈。
 * 配合 bindContentCover 全屏模态使用。
 */
import { ThemeManager } from '../../utils/ThemeManager';

@Component
export struct AzaharLoadingDialog {
  @Prop text: string = '';

  build() {
    Column() {
      LoadingProgress()
        .width(100)
        .height(100)
        .color(ThemeManager.getInstance().getControlAccent())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('sys.color.ohos_id_color_mask_thin'))
  }
}
