// utils/LayoutBackupManager.ets
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

const LAYOUTS_FILE = 'layouts.json';
const INTERNAL_LAYOUT_FILE = 'internal_layout.json';

interface LayoutEntry {
  target: string;
  name?: string;
  data?: Object;
}

export class LayoutBackupManager {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /**
   * 备份内部布局到指定目录
   * 从 layouts.json 中过滤 target="INTERNAL" 的布局并导出
   * Requirements: 5.3
   */
  async backupInternalLayout(destDirUri: string): Promise<void> {
    await this.backupFilteredLayout(destDirUri, INTERNAL_LAYOUT_FILE, 'INTERNAL');
  }

  /**
   * 恢复内部布局从指定目录
   * 读取备份文件，与现有布局合并（替换 INTERNAL target 布局）
   * Requirements: 6.3
   */
  async restoreInternalLayout(srcDirUri: string): Promise<void> {
    await this.restoreFilteredLayout(srcDirUri, INTERNAL_LAYOUT_FILE, 'INTERNAL');
  }

  private async backupFilteredLayout(destDirUri: string, fileName: string, target: string): Promise<void> {
    const layoutsPath = this.context.filesDir + '/' + LAYOUTS_FILE;

    // 检查 layouts.json 是否存在
    try {
      fileIo.accessSync(layoutsPath);
    } catch {
      throw new Error('No layouts file found');
    }

    // 读取并过滤布局
    const file = fileIo.openSync(layoutsPath, fileIo.OpenMode.READ_ONLY);
    try {
      const stat = fileIo.statSync(file.fd);
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      const content = String.fromCharCode(...new Uint8Array(buffer));
      const allLayouts: LayoutEntry[] = JSON.parse(content);
      const filtered = allLayouts.filter(layout => layout.target === target);

      // 写入目标文件
      const destPath = destDirUri.endsWith('/') ? destDirUri + fileName : destDirUri + '/' + fileName;
      const destFile = fileIo.openSync(destPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(destFile.fd, JSON.stringify(filtered, null, 2));
      } finally {
        fileIo.closeSync(destFile);
      }
    } finally {
      fileIo.closeSync(file);
    }
  }

  private async restoreFilteredLayout(srcDirUri: string, fileName: string, target: string): Promise<void> {
    const srcPath = srcDirUri.endsWith('/') ? srcDirUri + fileName : srcDirUri + '/' + fileName;
    const layoutsPath = this.context.filesDir + '/' + LAYOUTS_FILE;

    // 读取备份文件
    const srcFile = fileIo.openSync(srcPath, fileIo.OpenMode.READ_ONLY);
    let backupLayouts: LayoutEntry[];
    try {
      const stat = fileIo.statSync(srcFile.fd);
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(srcFile.fd, buffer);
      const content = String.fromCharCode(...new Uint8Array(buffer));
      backupLayouts = JSON.parse(content);
    } finally {
      fileIo.closeSync(srcFile);
    }

    // 读取现有布局（如果存在）
    let existingLayouts: LayoutEntry[] = [];
    try {
      fileIo.accessSync(layoutsPath);
      const existFile = fileIo.openSync(layoutsPath, fileIo.OpenMode.READ_ONLY);
      try {
        const stat = fileIo.statSync(existFile.fd);
        const buffer = new ArrayBuffer(stat.size);
        fileIo.readSync(existFile.fd, buffer);
        const content = String.fromCharCode(...new Uint8Array(buffer));
        existingLayouts = JSON.parse(content);
      } finally {
        fileIo.closeSync(existFile);
      }
    } catch {
      // 文件不存在，使用空数组
    }

    // 合并：移除现有的同 target 布局，加入备份的布局
    const merged = existingLayouts.filter(layout => layout.target !== target);
    merged.push(...backupLayouts);

    // 写回
    const destFile = fileIo.openSync(layoutsPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(destFile.fd, JSON.stringify(merged, null, 2));
    } finally {
      fileIo.closeSync(destFile);
    }
  }
}