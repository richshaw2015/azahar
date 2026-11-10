import { ThemeManager } from '../../utils/ThemeManager';
import {
  FONT_SIZE_MIN,
  FONT_SIZE_SETTING_DESC
} from '../../types/UIConstants';

let formStorage = new LocalStorage();

interface WidgetRouterParams {
  gamePath?: string;
}

interface WidgetRouterAction {
  action: string;
  abilityName: string;
  params: WidgetRouterParams;
}

@Entry(formStorage)
@Component
struct RecentGamesCard {
  @LocalStorageProp('cardType') cardType: string = 'small';
  @LocalStorageProp('gameCount') gameCount: number = 0;

  @LocalStorageProp('game0Name') game0Name: string = '';
  @LocalStorageProp('game0Path') game0Path: string = '';
  @LocalStorageProp('game0Cover') game0Cover: string = '';
  @LocalStorageProp('game0PlayTime') game0PlayTime: string = '';

  @LocalStorageProp('game1Name') game1Name: string = '';
  @LocalStorageProp('game1Path') game1Path: string = '';
  @LocalStorageProp('game1Cover') game1Cover: string = '';
  @LocalStorageProp('game1PlayTime') game1PlayTime: string = '';

  @LocalStorageProp('game2Name') game2Name: string = '';
  @LocalStorageProp('game2Path') game2Path: string = '';
  @LocalStorageProp('game2Cover') game2Cover: string = '';
  @LocalStorageProp('game2PlayTime') game2PlayTime: string = '';

  @LocalStorageProp('gradientStart') gradientStart: string = ThemeManager.getInstance().getCurrentColors().gradientStart;
  @LocalStorageProp('gradientEnd') gradientEnd: string = ThemeManager.getInstance().getCurrentColors().gradientEnd;

  // Cover Flow 进场动画状态：侧封面从外侧滑入、中封面轻微放大归位
  @State sideShift: number = 40;
  @State frontScale: number = 0.9;

  build() {
    if (this.gameCount <= 0) {
      this.EmptyState()
    } else if (this.cardType === 'large') {
      this.LargeCard()
    } else {
      this.SmallCard()
    }
  }

  @Builder
  SmallCard() {
    Stack() {
      if (this.game0Cover) {
        Image(this.game0Cover)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        this.ThemeBackground()
      }

      Column() {
        Text(this.game0Name)
          .fontSize(FONT_SIZE_MIN)
          .fontColor($r('app.color.text_on_accent'))
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textShadow({ offsetX: 1, offsetY: 1, radius: 1, color: $r('app.color.widget_text_shadow') })
        if (this.game0PlayTime) {
          Text(this.game0PlayTime)
            .fontSize($r('sys.float.ohos_id_text_size_caption1'))
            .fontColor($r('app.color.widget_subtitle'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 2 })
            .textShadow({ offsetX: 1, offsetY: 1, radius: 1, color: $r('app.color.widget_text_shadow') })
        }
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })
      .linearGradient({
        angle: 180,
        colors: [[$r('app.color.widget_fade_clear'), 0.0], [$r('app.color.widget_fade_dark'), 1.0]]
      })
      .position({ x: 0, y: '100%' })
      .markAnchor({ x: 0, y: '100%' })
    }
    .width('100%')
    .height('100%')
    .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
    .clip(true)
    .onClick(() => {
      this.openGame(this.game0Path);
    })
  }

  // Cover Flow 风格：最新游戏居中正对，两侧封面从暗色舞台后探出；
  // 卡片渲染管线不支持 3D 变换，用偏移 + 阴影模拟层叠纵深
  @Builder
  LargeCard() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[$r('app.color.widget_stage_start'), 0.0], [$r('app.color.widget_stage_end'), 1.0]]
        })
      this.Game1Cell()
      this.Game2Cell()
      this.Game0Cell()
    }
    .width('100%')
    .height('100%')
    .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
    .clip(true)
    .onAppear(() => {
      // 卡片不支持 animateTo/getUIContext，改 @State 由各 cell 的 .animation 属性动画接管
      this.sideShift = 0
      this.frontScale = 1
    })
  }

  // 三个 cell 必须分别直接引用 this.gameNCover/Name/Path —— 卡片(form widget)中
  // @Builder 按值传参不会建立状态订阅，会导致 LocalStorageProp 更新时不刷新
  @Builder
  Game0Cell() {
    Stack() {
      if (this.game0Cover) {
        Image(this.game0Cover)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        this.ThemeBackground()
      }

      // 中卡左右投影条：超出 cell 边界的部分压在两侧封面上，
      // 模拟中卡盖在上层投下的阴影，渐隐过渡无生硬分界
      Column()
        .width('12%')
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: [[$r('app.color.widget_fade_clear'), 0.0], [$r('app.color.widget_cell_shadow'), 1.0]]
        })
        .position({ x: '-12%', y: 0 })
      Column()
        .width('12%')
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: [[$r('app.color.widget_cell_shadow'), 0.0], [$r('app.color.widget_fade_clear'), 1.0]]
        })
        .position({ x: '100%', y: 0 })

      if (this.game0Name) {
        Column() {
          Text(this.game0Name)
            .fontSize(FONT_SIZE_MIN)
            .fontColor($r('app.color.text_on_accent'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Center)
            .textShadow({ offsetX: 1, offsetY: 1, radius: 1, color: $r('app.color.widget_text_shadow') })
          if (this.game0PlayTime) {
            Text(this.game0PlayTime)
              .fontSize($r('sys.float.ohos_id_text_size_caption1'))
              .fontColor($r('app.color.widget_subtitle'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 2 })
              .textShadow({ offsetX: 1, offsetY: 1, radius: 1, color: $r('app.color.widget_text_shadow') })
          }
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 8, bottom: 16 })
        .linearGradient({
          angle: 180,
          colors: [[$r('app.color.widget_fade_clear'), 0.0], [$r('app.color.widget_fade_dark'), 1.0]]
        })
        .position({ x: 0, y: '100%' })
        .markAnchor({ x: 0, y: '100%' })
      }
    }
    .width('38%')
    .height('100%')
    .scale({ x: this.frontScale, y: this.frontScale })
    .animation({ duration: 650, curve: Curve.EaseOut })
    .shadow({ radius: 18, color: $r('app.color.widget_card_shadow'), offsetX: 0, offsetY: 6 })
    .onClick(() => {
      this.openGame(this.game0Path);
    })
  }

  @Builder
  Game1Cell() {
    Stack() {
      if (this.game1Cover) {
        Image(this.game1Cover)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        this.ThemeBackground()
      }

      if (this.game1Name) {
        Column() {
          Text(this.game1Name)
            .fontSize(FONT_SIZE_MIN)
            .fontColor($r('app.color.text_on_accent'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
            .textShadow({ offsetX: 1, offsetY: 1, radius: 1, color: $r('app.color.widget_text_shadow') })
          if (this.game1PlayTime) {
            Text(this.game1PlayTime)
              .fontSize($r('sys.float.ohos_id_text_size_caption1'))
              .fontColor($r('app.color.widget_subtitle'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Start)
              .margin({ top: 2 })
              .textShadow({ offsetX: 1, offsetY: 1, radius: 1, color: $r('app.color.widget_text_shadow') })
          }
        }
        .width('100%')
        .padding({ left: '24%', right: 8, top: 8, bottom: 8 })
        .linearGradient({
          angle: 180,
          colors: [[$r('app.color.widget_fade_clear'), 0.0], [$r('app.color.widget_fade_dark'), 1.0]]
        })
        .position({ x: 0, y: '100%' })
        .markAnchor({ x: 0, y: '100%' })
      }
    }
    .width('38%')
    .height('100%')
    .position({ x: '-7%', y: 0 })
    .translate({ x: -this.sideShift })
    .animation({ duration: 650, curve: Curve.EaseOut })
    .onClick(() => {
      this.openGame(this.game1Path);
    })
  }

  @Builder
  Game2Cell() {
    Stack() {
      if (this.game2Cover) {
        Image(this.game2Cover)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        this.ThemeBackground()
      }

      if (this.game2Name) {
        Column() {
          Text(this.game2Name)
            .fontSize(FONT_SIZE_MIN)
            .fontColor($r('app.color.text_on_accent'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
            .textShadow({ offsetX: 1, offsetY: 1, radius: 1, color: $r('app.color.widget_text_shadow') })
          if (this.game2PlayTime) {
            Text(this.game2PlayTime)
              .fontSize($r('sys.float.ohos_id_text_size_caption1'))
              .fontColor($r('app.color.widget_subtitle'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Start)
              .margin({ top: 2 })
              .textShadow({ offsetX: 1, offsetY: 1, radius: 1, color: $r('app.color.widget_text_shadow') })
          }
        }
        .width('100%')
        .padding({ left: 8, right: '18%', top: 8, bottom: 8 })
        .linearGradient({
          angle: 180,
          colors: [[$r('app.color.widget_fade_clear'), 0.0], [$r('app.color.widget_fade_dark'), 1.0]]
        })
        .position({ x: 0, y: '100%' })
        .markAnchor({ x: 0, y: '100%' })
      }
    }
    .width('38%')
    .height('100%')
    .position({ x: '69%', y: 0 })
    .translate({ x: this.sideShift })
    .animation({ duration: 650, curve: Curve.EaseOut })
    .onClick(() => {
      this.openGame(this.game2Path);
    })
  }

  @Builder
  EmptyState() {
    Column() {
      Image($r('app.media.startIcon'))
        .width(this.cardType === 'large' ? 88 : 72)
        .height(this.cardType === 'large' ? 88 : 72)
        .objectFit(ImageFit.Contain)
      Text($r('app.string.no_recent_games'))
        .fontSize(FONT_SIZE_SETTING_DESC)
        .fontColor($r('app.color.text_on_accent'))
        .fontWeight(FontWeight.Medium)
        .margin({ top: 8 })
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.cardType === 'large') {
        Text($r('app.string.widget_tap_to_open'))
          .fontSize(FONT_SIZE_MIN)
          .fontColor($r('app.color.widget_subtitle'))
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 12, right: 12 })
    .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
    .clip(true)
    .linearGradient({
      angle: 135,
      colors: [[this.gradientStart, 0.0], [this.gradientEnd, 1.0]]
    })
    .onClick(() => {
      this.openGame('');
    })
  }

  @Builder
  ThemeBackground() {
    Column()
      .width('100%')
      .height('100%')
      .linearGradient({
        angle: 135,
        colors: [[this.gradientStart, 0.0], [this.gradientEnd, 1.0]]
      })
  }

  private openGame(path: string): void {
    const params: WidgetRouterParams = {};
    if (path) {
      params.gamePath = path;
    }
    const action: WidgetRouterAction = {
      action: 'router',
      abilityName: 'EntryAbility',
      params: params
    };
    postCardAction(this, action);
  }
}
