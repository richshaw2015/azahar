import { settingsGroupDivider, menuGroupPadding } from '../SettingsList';
import { AzaharCheatFormSheet } from '../../game/AzaharCheatFormSheet';
import { AzaharCheatInfo, AzaharNative } from '../../../types/AzaharNative';
import { AzaharThemeColors } from '../../../types/ThemeTypes';
import { I18n } from '../../../utils/I18nManager';
import { SoundEffect, SoundEffectManager } from '../../../utils/SoundEffectManager';
import { showErrorToast, showSuccessToast, showWarningToast } from '../../../utils/ToastHelper';
import { ComposeListItem } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { controlAccentOf, controlThemeOf, immersiveMaterial } from '../../common/AzaharControls';
import {
  MENU_ITEM_DIVIDER,
  TEXT_DANGER,
  TEXT_PRIMARY,
  TEXT_SECONDARY
} from '../../../types/UIConstants';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';
import { PersistedUriManager } from '../../../utils/PersistedUriManager';
import { FileManagerHelper } from '../../../utils/FileManagerHelper';
import { AzaharEmptySlot } from '../../game/AzaharEmptySlot';

/**
 * 单游戏配置页 — 金手指 Tab：布局对齐 NDS（GameConfigSettings 的 CheatsTabContent）。
 * 顶部警告文案 + 工具行（启用统计 / 全部禁用 / 导入 / 新增）与金手指列表同处一个
 * 滚动容器、随内容一起滚动；列表为空时改为空态图标 + 底部导入/新增主入口。
 * 数据经 titleId 驱动刷新。
 */
@Component
export struct GameConfigCheatsTab {
  scroller: Scroller = new Scroller();
  @Prop topSpace: number = 0;
  @Prop @Watch('refreshCheats') titleId: string = '';
  @Prop themeColors: AzaharThemeColors;
  @State private cheats: AzaharCheatInfo[] = [];
  // 列表重建版本号：ComposeListItem 的 switch.isCheck 是构建期参数，
  // 数据重载后靠键变化强制整行重建，开关才能反映批量操作后的新状态
  @State private cheatsVersion: number = 0;
  @State private showCheatDetail: boolean = false;
  @State private detailCheat: AzaharCheatInfo = { index: -1, name: '', notes: '', code: '', type: '', enabled: false };
  @State private cheatDetailName: string = '';
  @State private cheatDetailCode: string = '';
  @StorageLink('safeAreaTopVp') safeAreaTopVp: number = 0;
  @StorageLink('safeAreaBottomVp') safeAreaBottomVp: number = 0;
  soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private uriManager: PersistedUriManager = PersistedUriManager.getInstance();

  aboutToAppear(): void {
    this.refreshCheats();
  }

  private refreshCheats(): void {
    let next: AzaharCheatInfo[] = [];
    if (this.titleId) {
      try {
        next = AzaharNative.getCheats(this.titleId);
      } catch (_error) {
        next = [];
      }
    }
    this.cheats = next;
    this.cheatsVersion++;
  }

  private enabledCount(): number {
    let count = 0;
    this.cheats.forEach((cheat: AzaharCheatInfo) => {
      if (cheat.enabled) {
        count += 1;
      }
    });
    return count;
  }

  // 新增与查看/编辑共用同一底部弹窗：detailCheat.index=-1 表示新增（保存时 upsert 追加）
  private beginAddCheat(): void {
    this.viewCheatDetail({ index: -1, name: '', notes: '', code: '', type: '', enabled: false });
  }

  // 对齐 NDS CheatDetailDialog：点击列表行看名称/代码详情；编辑后点底部保存显式落盘
  private viewCheatDetail(cheat: AzaharCheatInfo): void {
    this.detailCheat = cheat;
    this.cheatDetailName = cheat.name;
    this.cheatDetailCode = cheat.code;
    this.showCheatDetail = true;
  }

  // 底部保存按钮显式落盘：校验失败把错误返回给弹窗内展示，成功则关弹窗刷新列表
  private saveCheatDetail(): string {
    const name = this.cheatDetailName.trim();
    const code = this.cheatDetailCode.trim();
    let error = '';
    if (!this.titleId) {
      error = I18n.t('cheat_no_available_title_id');
    } else if (!name || !code) {
      error = I18n.t('cheat_name_code_required');
    } else {
      const invalidLine = AzaharNative.validateGatewayCheatCode(code);
      if (invalidLine !== 0) {
        error = I18n.tf1('cheat_invalid_line_fmt', 'line', invalidLine);
      } else if (!AzaharNative.upsertGatewayCheat(this.titleId, this.detailCheat.index, name,
        this.detailCheat.notes, code, this.detailCheat.enabled)) {
        error = I18n.t('save_failed');
      }
    }
    if (error) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      return error;
    }
    this.soundEffectManager.play(SoundEffect.CONFIRM);
    this.showCheatDetail = false;
    this.refreshCheats();
    showSuccessToast(I18n.t('cheat_saved'));
    return error;
  }

  private toggleCheat(cheat: AzaharCheatInfo, enabled: boolean): void {
    if (AzaharNative.setCheatEnabled(this.titleId, cheat.index, enabled)) {
      this.refreshCheats();
    } else {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('cheat_toggle_failed'));
    }
  }

  private deleteCheat(cheat: AzaharCheatInfo): void {
    this.openConfirmDialog(
      I18n.t('delete_cheat_title'),
      I18n.tf1('delete_cheat_simple_message_fmt', 'name', cheat.name || I18n.t('unnamed_cheat')),
      I18n.t('delete'),
      () => {
        if (this.performDeleteCheat(cheat)) {
          this.showCheatDetail = false;
        }
      }
    );
  }

  private performDeleteCheat(cheat: AzaharCheatInfo): boolean {
    if (AzaharNative.removeCheat(this.titleId, cheat.index)) {
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      this.refreshCheats();
      showSuccessToast(I18n.t('cheat_deleted'));
      return true;
    }
    this.soundEffectManager.play(SoundEffect.FAIL);
    showErrorToast(I18n.t('cheat_delete_failed'));
    return false;
  }

  // 对齐 NDS requestDisableAll：先弹确认，文案带当前启用统计
  private requestDisableAll(): void {
    this.openConfirmDialog(
      I18n.t('confirm_disable_all_cheats'),
      I18n.tf2('cheats_enabled_count_fmt', 'enabled', this.enabledCount(), 'total', this.cheats.length),
      I18n.t('disable_all_cheats'),
      () => {
        this.performDisableAll();
      }
    );
  }

  private performDisableAll(): void {
    let failed = false;
    this.cheats.forEach((cheat: AzaharCheatInfo) => {
      if (cheat.enabled && !AzaharNative.setCheatEnabled(this.titleId, cheat.index, false)) {
        failed = true;
      }
    });
    this.refreshCheats();
    if (failed) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('cheat_toggle_failed'));
    } else {
      this.soundEffectManager.play(SoundEffect.CONFIRM);
    }
  }

  // 对齐 NDS requestImportCheats：选 TXT → 读内容 → 核心导入（非法文件报错）
  private async importCheatFile(): Promise<void> {
    if (!this.titleId) {
      showWarningToast(I18n.t('cheat_no_available_title_id'));
      return;
    }
    let file: fileIo.File | undefined;
    try {
      await this.uriManager.initialize(this.context);
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.txt'];
      const result = await documentPicker.select(options);
      if (!result || result.length === 0) {
        return;
      }
      await this.uriManager.persistFilePermission(result[0]);
      const path = FileManagerHelper.pathFromUri(result[0]);
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      if (stat.size <= 0 || stat.size > 4 * 1024 * 1024) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(I18n.t('cheat_import_invalid_file'));
        return;
      }
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      const contents = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buffer));
      if (!AzaharNative.importCheats(this.titleId, contents)) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(I18n.t('cheat_import_invalid_file'));
        return;
      }
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      this.refreshCheats();
      showSuccessToast(I18n.t('cheat_imported'));
    } catch (error) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('cheat_import_failed_fmt', 'error', JSON.stringify(error)));
    } finally {
      if (file) {
        fileIo.closeSync(file);
      }
    }
  }

  private openConfirmDialog(title: string, message: string, confirmText: string, onConfirm: () => void): void {
    this.getUIContext().showAlertDialog({
      title: title,
      message: message,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: confirmText,
        fontColor: TEXT_DANGER,
        action: () => {
          this.soundEffectManager.play(SoundEffect.CONFIRM);
          onConfirm();
        }
      },
      secondaryButton: {
        value: I18n.t('cancel'),
        fontColor: controlAccentOf(this.themeColors),
        action: () => {
          this.soundEffectManager.play(SoundEffect.BACK);
        }
      },
      cancel: () => {
        this.soundEffectManager.play(SoundEffect.BACK);
      }
    });
  }

  // 工具行圆形图标按钮：与首页右上角/存档详情操作按钮同规格（40vp 图标热区 + 24vp
  // 标题栏菜单图标）。底色用半透明白卡色而非 button_normal——按钮浮在彩色壁纸
  // 上，半透明灰会透色发暗，白卡底更接近标题栏按钮的磨砂白观感
  @Builder
  private CircleActionButton(icon: Resource, onClick: () => void) {
    Button() {
      SymbolGlyph(icon)
        .fontSize($r('sys.float.ohos_id_navigation_bar_menu_icon_size'))
        .fontColor([TEXT_PRIMARY])
    }
    .type(ButtonType.Circle)
    .width($r('sys.float.ohos_id_textfield_icon_hot_zone_size'))
    .height($r('sys.float.ohos_id_textfield_icon_hot_zone_size'))
    .backgroundColor(listCardBgOf(this.themeColors))
    .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN, true))
    .enabled(this.titleId.length > 0)
    .opacity(this.titleId.length > 0 ? 1 : 0.6)
    .onFocus(() => {
      this.soundEffectManager.play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      this.soundEffectManager.play(SoundEffect.DECIDE);
      onClick();
    })
  }

  @Builder
  CheatMenuBuilder(cheat: AzaharCheatInfo) {
    Menu() {
      MenuItemGroup() {
        MenuItem({ content: I18n.t('delete') })
          .onClick(() => {
            this.soundEffectManager.play(SoundEffect.CONFIRM);
            this.deleteCheat(cheat);
          })
      }
    }
    .fontColor(TEXT_PRIMARY)
    .menuItemDivider(MENU_ITEM_DIVIDER)
    .menuItemGroupDivider(MENU_ITEM_DIVIDER)
  }

  @Builder
  CheatRow(cheat: AzaharCheatInfo) {
    WithTheme({ theme: controlThemeOf(this.themeColors) }) {
      ComposeListItem({
        contentItem: {
          primaryText: cheat.name || I18n.t('unnamed_cheat')
        },
        operateItem: {
          switch: {
            isCheck: cheat.enabled,
            onChange: (enabled: boolean) => {
              this.soundEffectManager.play(enabled ? SoundEffect.TOGGLE_ON : SoundEffect.TOGGLE_OFF);
              this.toggleCheat(cheat, enabled);
            }
          }
        }
      })
        .onFocus(() => {
          this.soundEffectManager.play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          this.soundEffectManager.play(SoundEffect.DECIDE);
          this.viewCheatDetail(cheat);
        })
        .bindContextMenu(() => {
          this.CheatMenuBuilder(cheat);
        }, ResponseType.LongPress)
    }
  }

  // 金手指详情/新增底部弹窗：与游戏内金手指面板共用 AzaharCheatFormSheet，交互保持一致；
  // 删除沿用长按菜单的确认弹窗流程（onConfirm 成功后才关 sheet）
  @Builder
  private CheatDetailSheet() {
    AzaharCheatFormSheet({
      title: this.detailCheat.index >= 0 ? I18n.t('cheat_detail') : I18n.t('add_cheat'),
      canDelete: this.detailCheat.index >= 0,
      name: $cheatDetailName,
      code: $cheatDetailCode,
      onClose: () => {
        this.showCheatDetail = false;
      },
      onSave: (): string => {
        return this.saveCheatDetail();
      },
      onDelete: () => {
        this.deleteCheat(this.detailCheat);
      }
    })
  }

  build() {
    Stack() {
      // 整页一个滚动容器：首个占位 ListItem 垫出浮动标题栏 + 分段控件高度
      // （与 SettingsList 约定一致），警告/工具行/列表随内容一起滚动
      List({ scroller: this.scroller }) {
        ListItem() {
          Column() {
          }
          .width('100%')
          .height(this.safeAreaTopVp + this.topSpace)
        }

        // 顶部警告（对齐 NDS CheatsTabContent 页级警告）
        ListItem() {
          Text(I18n.t('cheat_warning'))
            .fontSize($r('sys.float.ohos_id_text_size_body2'))
            .fontColor(TEXT_SECONDARY)
            .width('100%')
            .padding({
              left: $r('sys.float.ohos_id_default_padding_start'),
              right: $r('sys.float.ohos_id_default_padding_end'),
              top: $r('sys.float.ohos_id_elements_margin_vertical_m'),
              bottom: $r('sys.float.ohos_id_elements_margin_vertical_m')
            })
        }

        // 工具行：启用统计 + 全部禁用（有启用时）+ 导入 + 新增；空列表同样显示，入口不随数据有无变化
        ListItem() {
          Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
            Text(I18n.tf2('cheats_enabled_count_fmt', 'enabled', this.enabledCount(), 'total', this.cheats.length))
              .fontSize($r('sys.float.ohos_id_text_size_body2'))
              .fontColor(TEXT_SECONDARY)
              .layoutWeight(1)

            if (this.enabledCount() > 0) {
              this.CircleActionButton($r('sys.symbol.nosign'), () => {
                this.requestDisableAll();
              })
            }
            this.CircleActionButton($r('sys.symbol.square_and_arrow_down'), () => {
              this.importCheatFile();
            })
            this.CircleActionButton($r('sys.symbol.plus'), () => {
              this.beginAddCheat();
            })
          }
          .width('100%')
          .padding({
            left: $r('sys.float.ohos_id_default_padding_start'),
            right: $r('sys.float.ohos_id_default_padding_end'),
            bottom: $r('sys.float.ohos_id_elements_margin_vertical_m')
          })
        }

        if (this.cheats.length > 0) {
          ListItemGroup({ style: ListItemGroupStyle.CARD }) {
            ForEach(this.cheats, (cheat: AzaharCheatInfo) => {
              ListItem() {
                this.CheatRow(cheat)
              }
            }, (cheat: AzaharCheatInfo) => `${cheat.index}-${this.cheatsVersion}`)
          }
          .padding(menuGroupPadding())
          .backgroundColor(listCardBgOf(this.themeColors))
          .divider(settingsGroupDivider())
        }

        ListItem() {
          Column() {
          }
          .width('100%')
          .height(24 + this.safeAreaBottomVp)
        }
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)

      // 空态：与首页/联机大厅共用 AzaharEmptySlot（同一图标规格 + body1 标题 + 描述副标题）。
      // 放 Stack 层按整页高度居中（含标题栏区域），与首页 CenterEmptySlot 观感一致；
      // hitTestBehavior(None) 穿透，不拦截顶部工具行点击
      if (this.cheats.length === 0) {
        Column() {
          AzaharEmptySlot({
            title: I18n.t('no_cheats'),
            subtitle: this.titleId ? I18n.t('cheat_empty_desc') : I18n.t('cheat_no_title_id_desc')
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.None)
        .padding({
          left: $r('sys.float.ohos_id_default_padding_start'),
          right: $r('sys.float.ohos_id_default_padding_end')
        })
      }

      // 金手指详情/新增：bindSheet 底部弹窗（锚点组件不可见，与其他 sheet 同套规范）
      Column()
        .width(0)
        .height(0)
        .bindSheet($$this.showCheatDetail, this.CheatDetailSheet(), {
          height: SheetSize.FIT_CONTENT,
          showClose: false,
          systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
        })
    }
    .width('100%')
    .height('100%')
  }
}
