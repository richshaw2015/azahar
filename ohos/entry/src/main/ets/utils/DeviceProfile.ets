import { common, bundleManager } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';

export class DeviceProfile {
  private static appCloneIndex: number | null = null;

  static getDeviceType(): string {
    return deviceInfo.deviceType;
  }

  /** 应用分身索引：主应用 0，分身 1..N。读取失败按主应用处理 */
  static getAppCloneIndex(context?: common.Context): number {
    if (DeviceProfile.appCloneIndex !== null) {
      return DeviceProfile.appCloneIndex;
    }
    try {
      const appContext = context?.getApplicationContext();
      DeviceProfile.appCloneIndex = appContext ? appContext.getCurrentAppCloneIndex() : 0;
    } catch (_e) {
      DeviceProfile.appCloneIndex = 0;
    }
    return DeviceProfile.appCloneIndex;
  }

  /** 分身 Download 目录首段的常见命名：{bundleName} 或带分身后缀 */
  static isOwnDownloadDirName(dirName: string): boolean {
    let bundleName = '';
    try {
      bundleName = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).name || '';
    } catch (_e) {
      return false;
    }
    // 精确匹配或带分隔符的分身后缀（如 bundleName-1/bundleName_1），
    // 防止 bundleName 是其他目录名前缀时误识别
    return bundleName.length > 0 &&
      (dirName === bundleName || dirName.startsWith(`${bundleName}-`) || dirName.startsWith(`${bundleName}_`));
  }
}
