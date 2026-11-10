import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { fileShare, fileUri } from '@kit.CoreFileKit';

const PREFERENCES_NAME: string = 'azahar_persisted_uris';
const KEY_FILE_URIS: string = 'file_uris';

export interface PersistedUri {
  uri: string;
  path: string;
  displayName: string;
  addTime: number;
}

export class PersistedUriManager {
  private static instance: PersistedUriManager | null = null;
  private prefs: preferences.Preferences | null = null;
  private fileUris: PersistedUri[] = [];
  private initialized: boolean = false;

  static getInstance(): PersistedUriManager {
    if (!PersistedUriManager.instance) {
      PersistedUriManager.instance = new PersistedUriManager();
    }
    return PersistedUriManager.instance;
  }

  async initialize(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) {
      return;
    }

    this.prefs = await preferences.getPreferences(context, PREFERENCES_NAME);
    await this.loadPersistedUris();
    await this.activateAllPermissions();
    this.initialized = true;
  }

  static isSupported(): boolean {
    return canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization');
  }

  async persistFilePermission(uri: string): Promise<PersistedUri | null> {
    if (!uri || !uri.startsWith('file://') || !PersistedUriManager.isSupported()) {
      return null;
    }

    const existing = this.fileUris.find((item: PersistedUri) => item.uri === uri);
    if (existing) {
      if (await this.activatePermissionForUri(uri)) {
        return existing;
      }

      this.removeUri(uri);
      await this.savePersistedUris();
    }

    const policy: fileShare.PolicyInfo = {
      uri,
      operationMode: fileShare.OperationMode.READ_MODE
    };

    try {
      await fileShare.persistPermission([policy]);
      await fileShare.activatePermission([policy]);

      const path = this.uriToPath(uri);
      const persistedUri: PersistedUri = {
        uri,
        path,
        displayName: this.getDisplayName(uri, path),
        addTime: Date.now()
      };

      this.fileUris.push(persistedUri);
      await this.savePersistedUris();
      return persistedUri;
    } catch (error) {
      const businessError = error as BusinessError<Array<fileShare.PolicyErrorResult>>;
      console.error(`[AzaharUri] persistFilePermission failed: ${businessError.message}, code=${businessError.code}`);
      return null;
    }
  }

  async activatePermissionForPath(path: string): Promise<boolean> {
    const uri = this.getUriForPath(path);
    return uri ? this.activatePermissionForUri(uri) : false;
  }

  async activatePermissionForUri(uri: string): Promise<boolean> {
    if (!uri || !uri.startsWith('file://') || !PersistedUriManager.isSupported()) {
      return false;
    }

    const policy: fileShare.PolicyInfo = {
      uri,
      operationMode: fileShare.OperationMode.READ_MODE
    };

    try {
      await fileShare.activatePermission([policy]);
      return true;
    } catch (error) {
      const businessError = error as BusinessError<Array<fileShare.PolicyErrorResult>>;
      console.error(`[AzaharUri] activatePermissionForUri failed: ${businessError.message}, code=${businessError.code}`);
      if (businessError.code === 13900001 && businessError.data) {
        for (let i = 0; i < businessError.data.length; i++) {
          const result = businessError.data[i];
          console.error(`[AzaharUri] activatePermissionForUri failed uri=${result.uri}, reason=${result.message}, code=${result.code}`);
        }
      }
      return false;
    }
  }

  uriToPath(uri: string): string {
    try {
      return new fileUri.FileUri(uri).path;
    } catch (error) {
      console.error(`[AzaharUri] uriToPath failed: ${(error as Error).message}`);
      return this.parseUriToPath(uri);
    }
  }

  getUriForPath(path: string): string | null {
    const item = this.fileUris.find((persistedUri: PersistedUri) => persistedUri.path === path);
    return item ? item.uri : null;
  }

  private async loadPersistedUris(): Promise<void> {
    if (!this.prefs) {
      return;
    }

    try {
      const json = await this.prefs.get(KEY_FILE_URIS, '[]') as string;
      this.fileUris = JSON.parse(json) as PersistedUri[];
    } catch (error) {
      console.error(`[AzaharUri] loadPersistedUris failed: ${(error as Error).message}`);
      this.fileUris = [];
    }
  }

  private async savePersistedUris(): Promise<void> {
    if (!this.prefs) {
      return;
    }

    await this.prefs.put(KEY_FILE_URIS, JSON.stringify(this.fileUris));
    await this.prefs.flush();
  }

  private removeUri(uri: string): void {
    this.fileUris = this.fileUris.filter((item: PersistedUri) => item.uri !== uri);
  }

  private async activateAllPermissions(): Promise<void> {
    if (this.fileUris.length === 0 || !PersistedUriManager.isSupported()) {
      return;
    }

    const invalidUris: string[] = [];
    for (let i = 0; i < this.fileUris.length; i++) {
      const uri = this.fileUris[i].uri;
      if (!(await this.activatePermissionForUri(uri))) {
        invalidUris.push(uri);
      }
    }

    if (invalidUris.length > 0) {
      this.fileUris = this.fileUris.filter((item: PersistedUri) => !invalidUris.includes(item.uri));
      await this.savePersistedUris();
    }
  }

  private parseUriToPath(uri: string): string {
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

  private getDisplayName(uri: string, path: string): string {
    const pathParts = path.split('/').filter((part: string) => part.length > 0);
    if (pathParts.length > 0) {
      return pathParts[pathParts.length - 1];
    }
    return uri;
  }
}
