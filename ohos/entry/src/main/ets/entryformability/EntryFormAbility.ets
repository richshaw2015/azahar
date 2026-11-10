import { formBindingData, FormExtensionAbility, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  getDefaultWidgetGradient,
  WidgetBindingData,
  WidgetService
} from '../utils/WidgetService';

const DOMAIN = 0x0000;
const TAG = 'Azahar_EntryFormAbility';

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId = want.parameters?.['ohos.extra.param.key.form_identity'] as string;
    const dimensionRaw = want.parameters?.['ohos.extra.param.key.form_dimension'];
    const dimension = typeof dimensionRaw === 'number' ? dimensionRaw :
      (typeof dimensionRaw === 'string' ? parseInt(dimensionRaw) : 2);
    hilog.info(DOMAIN, TAG, 'onAddForm: %{public}s, dimension=%{public}d', formId, dimension);

    if (formId) {
      this.saveFormId(formId, dimension);
    }

    // 同步读取并直接返回当前数据，readWidgetData 全部使用 sync I/O
    const widgetData = WidgetService.readWidgetData(this.context.filesDir);
    const binding = widgetData ?
      WidgetService.buildBindingObject(widgetData, dimension) :
      this.buildEmptyData(dimension);
    return formBindingData.createFormBindingData(binding);
  }

  onCastToNormalForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'onCastToNormalForm: %{public}s', formId);
  }

  onUpdateForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'onUpdateForm: %{public}s', formId);
    const formIds = WidgetService.readFormIds(this.context.filesDir);
    const dimension = formIds.dimensions[formId] ?? 2;
    const widgetData = WidgetService.readWidgetData(this.context.filesDir);
    const binding = widgetData ?
      WidgetService.buildBindingObject(widgetData, dimension) :
      this.buildEmptyData(dimension);
    formProvider.updateForm(formId, formBindingData.createFormBindingData(binding)).catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'onUpdateForm updateForm failed: %{public}s', error.message);
    });
  }

  onChangeFormVisibility(newStatus: Record<string, number>): void {
    hilog.info(DOMAIN, TAG, 'onChangeFormVisibility: %{public}s', JSON.stringify(newStatus));
  }

  onFormEvent(formId: string, message: string): void {
    hilog.info(DOMAIN, TAG, 'onFormEvent: %{public}s, %{public}s', formId, message);
  }

  onRemoveForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'onRemoveForm: %{public}s', formId);
    const data = WidgetService.readFormIds(this.context.filesDir);
    WidgetService.removeFormIdData(data, formId);
    WidgetService.writeFormIds(this.context.filesDir, data);
  }

  onAcquireFormState(_want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  private saveFormId(formId: string, dimension: number): void {
    const data = WidgetService.readFormIds(this.context.filesDir);
    if (!data.formIds.includes(formId)) {
      data.formIds.push(formId);
    }
    data.dimensions[formId] = dimension;
    WidgetService.writeFormIds(this.context.filesDir, data);
  }

  private buildEmptyData(dimension: number): WidgetBindingData {
    return {
      cardType: dimension === 3 ? 'large' : 'small',
      gameCount: 0,
      game0Name: '',
      game0Path: '',
      game0Cover: '',
      game0PlayTime: '',
      game1Name: '',
      game1Path: '',
      game1Cover: '',
      game1PlayTime: '',
      game2Name: '',
      game2Path: '',
      game2Cover: '',
      game2PlayTime: '',
      gradientStart: getDefaultWidgetGradient().gradientStart,
      gradientEnd: getDefaultWidgetGradient().gradientEnd
    };
  }
}
