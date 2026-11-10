import { BusinessError } from '@kit.BasicServicesKit';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { fileUri, picker } from '@kit.CoreFileKit';
import { I18n } from './I18nManager';
import { DeviceProfile } from './DeviceProfile';

const SYSTEM_FILE_MANAGER_BUNDLE: string = 'com.huawei.hmos.filemanager';
const SYSTEM_FILE_MANAGER_ABILITY: string = 'MainAbility';

export interface OpenFolderResult {
  success: boolean;
  message: string;
  selectedUri?: string;
}

export class FileManagerHelper {
  private static instance: FileManagerHelper | null = null;
  private static appName: string = '';
  private static bundleName: string = '';

  static getInstance(): FileManagerHelper {
    if (!FileManagerHelper.instance) {
      FileManagerHelper.instance = new FileManagerHelper();
    }
    return FileManagerHelper.instance;
  }

  static initAppName(context: common.UIAbilityContext): void {
    try {
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      FileManagerHelper.bundleName = bundleInfo.name || '';
    } catch (_error) {
      FileManagerHelper.bundleName = '';
    }

    try {
      const name = context.resourceManager.getStringByNameSync('app_name');
      FileManagerHelper.appName = name || FileManagerHelper.bundleName;
    } catch (_error) {
      FileManagerHelper.appName = FileManagerHelper.bundleName;
    }
    // 顺手缓存分身索引，WebUploadServer 端口偏移与目录名匹配共用
    DeviceProfile.getAppCloneIndex(context);
  }

  static getDisplayPath(fullPath: string): string {
    if (!fullPath) {
      return I18n.t('not_set');
    }

    const downloadMatch = fullPath.match(/\/storage\/Users\/[^/]+\/Download\/?(.*)/);
    if (downloadMatch) {
      return FileManagerHelper.formatDownloadDisplayPath(downloadMatch[1]);
    }

    const downloadIndex = fullPath.indexOf('/Download/');
    if (downloadIndex >= 0) {
      return FileManagerHelper.formatDownloadDisplayPath(fullPath.substring(downloadIndex + '/Download/'.length));
    }
    return fullPath;
  }

  static pathFromUri(uri: string): string {
    try {
      return new fileUri.FileUri(uri).path;
    } catch (_error) {
      if (uri.startsWith('file://docs/')) {
        return '/' + uri.substring('file://docs/'.length);
      }
      if (uri.startsWith('file://')) {
        const parts = uri.substring('file://'.length).split('/');
        if (parts.length > 1) {
          return '/' + parts.slice(1).join('/');
        }
      }
      return uri;
    }
  }

  async openFolder(context: common.UIAbilityContext, dirUriOrPath: string, fileSuffixFilters?: string[]): Promise<OpenFolderResult> {
    if (!dirUriOrPath) {
      return { success: false, message: I18n.t('dir_not_set') };
    }

    const formattedUri = this.formatPickerUri(dirUriOrPath);
    try {
      const want: Want = {
        bundleName: SYSTEM_FILE_MANAGER_BUNDLE,
        abilityName: SYSTEM_FILE_MANAGER_ABILITY,
        parameters: { fileUri: formattedUri }
      };
      await context.startAbility(want);
      return { success: true, message: I18n.t('dir_opened') };
    } catch (_error) {
      return this.openFolderWithPicker(context, formattedUri, fileSuffixFilters);
    }
  }

  async openFolderByPath(context: common.UIAbilityContext, dirPath: string, fileSuffixFilters?: string[]): Promise<OpenFolderResult> {
    return this.openFolder(context, dirPath, fileSuffixFilters);
  }

  async selectFileInFolder(context: common.UIAbilityContext, dirUriOrPath: string, fileSuffixFilters?: string[]): Promise<OpenFolderResult> {
    if (!dirUriOrPath) {
      return { success: false, message: I18n.t('dir_not_set') };
    }
    return this.openFolderWithPicker(context, this.formatPickerUri(dirUriOrPath), fileSuffixFilters);
  }

  private async openFolderWithPicker(context: common.UIAbilityContext, dirUri: string, fileSuffixFilters?: string[]): Promise<OpenFolderResult> {
    try {
      const documentPicker = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSelectOptions();
      options.defaultFilePathUri = dirUri;
      options.maxSelectNumber = 1;
      if (fileSuffixFilters && fileSuffixFilters.length > 0) {
        options.fileSuffixFilters = fileSuffixFilters;
      }

      const result = await documentPicker.select(options);
      if (result && result.length > 0) {
        return { success: true, message: I18n.t('file_selected'), selectedUri: result[0] };
      }
      return { success: true, message: I18n.t('dir_opened') };
    } catch (error) {
      const businessError = error as BusinessError;
      return { success: false, message: I18n.tf1('open_dir_failed_fmt', 'error', businessError.message) };
    }
  }

  private formatPickerUri(uriOrPath: string): string {
    let formattedUri = uriOrPath;
    if (formattedUri.startsWith('file:///storage/Users/')) {
      formattedUri = `file://docs${formattedUri.substring('file://'.length)}`;
    } else if (formattedUri.startsWith('/storage/Users/')) {
      formattedUri = `file://docs${formattedUri}`;
    } else if (!formattedUri.startsWith('file://') && formattedUri.startsWith('/')) {
      try {
        formattedUri = fileUri.getUriFromPath(formattedUri);
      } catch (_error) {
        formattedUri = `file://${formattedUri}`;
      }
    }

    return formattedUri.endsWith('/') ? formattedUri : `${formattedUri}/`;
  }

  private static formatDownloadDisplayPath(subPath: string): string {
    const parts = subPath.split('/').filter((part: string) => part.length > 0);
    if (parts.length === 0) {
      return '~/Download';
    }
    if (FileManagerHelper.bundleName && DeviceProfile.isOwnDownloadDirName(parts[0])) {
      parts[0] = FileManagerHelper.appName || I18n.t('app_name');
    }
    return `~/Download/${parts.join('/')}`;
  }
}
