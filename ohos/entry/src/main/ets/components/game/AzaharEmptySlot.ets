import {
  FONT_SIZE_SETTING_DESC,
  SUBTLE_SHADOW,
  TEXT_PRIMARY,
  TEXT_SECONDARY
} from '../../types/UIConstants';

const SLOT_SIZE: number = 72;
const SLOT_INNER: number = 50;
const SLOT_RADIUS: number = 10;
const SLOT_INNER_RADIUS: number = 6;

@Component
export struct AzaharEmptySlot {
  @Prop title: string = '';
  @Prop subtitle: string = '';

  build() {
    Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_l') }) {
      // 原版 3DS 空卡槽：中灰外框 + 浅色内嵌板，内板上沿暗边、下沿亮边形成内凹
      Stack() {
        Column()
          .width(SLOT_INNER)
          .height(SLOT_INNER)
          .backgroundColor($r('app.color.slot_inner'))
          .borderRadius(SLOT_INNER_RADIUS)
          .border({
            width: { top: '1px', bottom: '1px' },
            color: {
              top: $r('app.color.slot_inner_edge_top'),
              bottom: $r('app.color.slot_inner_edge_bottom')
            }
          })
      }
      .width(SLOT_SIZE)
      .height(SLOT_SIZE)
      .backgroundColor($r('app.color.slot_outer'))
      .borderRadius(SLOT_RADIUS)
      .border({ width: '1px', color: $r('app.color.slot_outer_border') })
      .shadow(SUBTLE_SHADOW)

      Text(this.title)
        .fontSize($r('sys.float.ohos_id_text_size_body1'))
        .fontColor(TEXT_PRIMARY)
        .fontWeight(FontWeight.Medium)

      if (this.subtitle.length > 0) {
        Text(this.subtitle)
          .fontSize(FONT_SIZE_SETTING_DESC)
          .fontColor(TEXT_SECONDARY)
          .textAlign(TextAlign.Center)
          .constraintSize({ maxWidth: 260 })
      }
    }
    .alignItems(HorizontalAlign.Center)
  }
}
