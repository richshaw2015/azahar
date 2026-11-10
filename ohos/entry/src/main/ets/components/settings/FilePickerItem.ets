import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { ComposeListItem } from '@kit.ArkUI';
import {
  OPACITY_DISABLED
} from '../../types/UIConstants';
import { FileManagerHelper } from '../../utils/FileManagerHelper';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';

@Component
export struct FilePickerItem {
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop currentFile: string = '';
  @Prop fileSuffixes: string[] = [];
  @Prop disabled: boolean = false;
  @Prop requiresRestart: boolean = false;
  onSelect: (path: string) => void = () => {};

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  build() {
    ComposeListItem({
      contentItem: {
        icon: $r('sys.symbol.doc'),
        primaryText: this.requiresRestart ? `${this.title} *` : this.title,
        secondaryText: this.description.length > 0 && this.currentFile.length > 0
          ? `${this.description}\n${this.displayPath(this.currentFile)}`
          : (this.currentFile.length > 0
            ? this.displayPath(this.currentFile)
            : (this.description.length > 0 ? this.description : undefined))
      },
      operateItem: {
        arrow: {
          value: $r('sys.symbol.chevron_right')
        }
      }
    })
    .opacity(this.disabled ? OPACITY_DISABLED : 1.0)
    .enabled(!this.disabled)
    .onFocus(() => {
      SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      if (!this.disabled) {
        SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
        this.openFilePicker();
      }
    })
  }

  private openFilePicker(): void {
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.selectMode = picker.DocumentSelectMode.FILE;
      if (this.fileSuffixes.length > 0) {
        options.fileSuffixFilters = this.fileSuffixes;
      }

      documentPicker.select(options).then((result: string[]) => {
        if (result && result.length > 0) {
          this.onSelect(FileManagerHelper.pathFromUri(result[0]));
        }
      }).catch((err: BusinessError) => {
        console.error(`FilePickerItem select failed: ${err.message}, code=${err.code}`);
      });
    } catch (error) {
      const err = error as BusinessError;
      console.error(`FilePickerItem open failed: ${err.message}, code=${err.code}`);
    }
  }

  private displayPath(path: string): string {
    if (!path) {
      return '';
    }
    return FileManagerHelper.getDisplayPath(path);
  }
}
