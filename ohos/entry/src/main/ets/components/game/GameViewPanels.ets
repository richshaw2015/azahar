import { AzaharCheatFormSheet } from './AzaharCheatFormSheet';
import { AzaharCheatPanel } from './AzaharCheatPanel';
import { AzaharSaveStateDetailDialog } from './AzaharSaveStateDetailDialog';

import uiMaterial from '@ohos.arkui.uiMaterial';
import { immersiveMaterial } from '../common/AzaharControls';
import { I18n } from '../../utils/I18nManager';
import { AzaharCheatInfo, AzaharSaveStateInfo } from '../../types/AzaharNative';
import { AzaharThemeColors } from '../../types/ThemeTypes';

import { SoundEffectManager } from '../../utils/SoundEffectManager';

/** 游戏内详情面板：存档详情 / 金手指 */
@Component
export struct GameViewPanels {
  @Prop uiThemeColors: AzaharThemeColors;
  @Prop controlsWidth: number = 0;
  @Prop detailStateSlot: number = 0;
  getDetailSaveState: () => AzaharSaveStateInfo | undefined = () => undefined;
  hasSaveState: (slot: number) => boolean = () => false;
  @Prop gameTitle: string = '';
  @Prop gameTitleId: string = '';
  @Prop cheats: AzaharCheatInfo[] = [];
  /** 存档详情底部弹窗开关：bindSheet 手势关闭需回写父状态，必须 @Link */
  @Link showSaveStateDetail: boolean;
  @Prop showCheatPanel: boolean = false;
  /** 金手指表单底部弹窗：bindSheet 手势关闭需回写父状态，必须 @Link */
  @Link showCheatForm: boolean;
  @Prop cheatFormCheat: AzaharCheatInfo = { index: -1, name: '', notes: '', code: '', type: '', enabled: false };
  @Link cheatFormName: string;
  @Link cheatFormCode: string;
  soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  closeSaveStateDetail: () => void = () => {};
  loadStateFromSlot: (slot: number) => void = () => {};
  saveStateToSlot: (slot: number) => void = () => {};
  deleteSaveState: (slot: number) => void = () => {};
  undoSaveState: (slot: number) => void = () => {};
  closeCheatPanel: () => void = () => {};
  refreshCheats: () => void = () => {};
  beginAddCheat: () => void = () => {};
  importCheats: () => void = () => {};
  viewCheatDetail: (cheat: AzaharCheatInfo) => void = () => {};
  toggleCheat: (cheat: AzaharCheatInfo, enabled: boolean) => void = () => {};
  closeCheatForm: () => void = () => {};
  /** 校验并写盘，返回错误文案（空串=成功，父级负责关弹窗） */
  saveCheatForm: () => string = () => '';
  deleteCheatForm: () => void = () => {};

  @Builder
  SaveStateDetailSheet() {
    AzaharSaveStateDetailDialog({
      slot: this.detailStateSlot,
      saveState: this.getDetailSaveState(),
      exists: this.hasSaveState(this.detailStateSlot),
      onSave: (slot: number) => {
        this.saveStateToSlot(slot);
      },
      onLoad: (slot: number) => {
        this.loadStateFromSlot(slot);
      },
      onDelete: (slot: number) => {
        this.deleteSaveState(slot);
      },
      onUndo: (slot: number) => {
        this.undoSaveState(slot);
      },
      onDismiss: () => {
        this.closeSaveStateDetail();
      }
    })
  }

  @Builder
  CheatPanelOverlay() {
    Stack() {
      AzaharCheatPanel({
        gameTitle: this.gameTitle,
        titleId: this.gameTitleId,
        screenWidth: this.controlsWidth,
        cheats: this.cheats,
        themeColors: this.uiThemeColors,
        onBack: () => {
          this.closeCheatPanel();
        },
        onAdd: () => {
          this.beginAddCheat();
        },
        onImport: () => {
          this.importCheats();
        },
        onRefresh: () => {
          this.refreshCheats();
        },
        onToggle: (cheat: AzaharCheatInfo, enabled: boolean) => {
          this.toggleCheat(cheat, enabled);
        },
        onViewDetail: (cheat: AzaharCheatInfo) => {
          this.viewCheatDetail(cheat);
        }
      })

    }
    .width('100%')
    .height('100%')
  }

  // 金手指新增/详情底部弹窗：与游戏详情页金手指 Tab 共用 AzaharCheatFormSheet，交互一致
  @Builder
  CheatFormSheet() {
    AzaharCheatFormSheet({
      title: this.cheatFormCheat.index >= 0 ? I18n.t('cheat_detail') : I18n.t('add_cheat'),
      canDelete: this.cheatFormCheat.index >= 0,
      name: $cheatFormName,
      code: $cheatFormCode,
      onClose: () => {
        this.closeCheatForm();
      },
      onSave: (): string => {
        return this.saveCheatForm();
      },
      onDelete: () => {
        this.deleteCheatForm();
      }
    })
  }

  build() {
    Stack() {
      // 存档详情/金手指表单：bindSheet 底部弹窗（锚点组件不可见，与其他 sheet 同套规范）。
      // 本组件常驻挂载（不随暂停菜单显隐），保证游戏内面板与暂停菜单行点击都能唤起
      Column()
        .width(0)
        .height(0)
        .bindSheet($$this.showSaveStateDetail, this.SaveStateDetailSheet(), {
          height: SheetSize.FIT_CONTENT,
          showClose: false,
          systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
        })
      Column()
        .width(0)
        .height(0)
        .bindSheet($$this.showCheatForm, this.CheatFormSheet(), {
          height: SheetSize.FIT_CONTENT,
          showClose: false,
          systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
        })
      if (this.showCheatPanel) {
        this.CheatPanelOverlay()
      }
    }
    .width('100%')
    .height('100%')
    // 无面板显示时根节点为空白全屏 Stack，必须透明命中，否则会吃掉下方暂停菜单的全部触摸
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
