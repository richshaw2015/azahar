/*
 * 内置金手指库：rawfile/cheats/cheats.dat
 * 布局: header 16B "AZCH"+ver+count+slots | slots×20B(titleId u64, off u32, len u32, flags u32) | payload
 * 查询: slot = titleId & (slots-1) 线性探测命中或遇空槽 → 切出文本
 * 游戏启动时若 cheats/<titleId>.txt 不存在则落盘，存在则跳过（用户改动优先）。
 */
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

const RAW_PATH: string = 'cheats/cheats.dat';
const MAGIC: number = 0x415A4348; // 'AZCH' 大端
const STRIDE: number = 20;

export class CheatsSeed {
  private static inst: CheatsSeed = new CheatsSeed();
  private db: Uint8Array | null = null;
  private count: number = 0;
  private slots: number = 0;
  private tried: boolean = false;

  static getInstance(): CheatsSeed { return CheatsSeed.inst; }

  private load(context: Context): boolean {
    if (this.tried) return this.db !== null;
    this.tried = true;
    try {
      const content: Uint8Array = context.resourceManager.getRawFileContentSync(RAW_PATH);
      if (content.length < 16) return false;
      const dv = new DataView(content.buffer, content.byteOffset);
      if (dv.getUint32(0, false) !== MAGIC || dv.getUint32(4, true) !== 1) return false;
      this.count = dv.getUint32(8, true);
      this.slots = dv.getUint32(12, true);
      this.db = content;
      return true;
    } catch (e) {
      console.warn(`[CheatsSeed] load failed: ${(e as BusinessError).message}`);
      return false;
    }
  }

  /** 按 titleId 查内置金手指文本，未收录返回 null */
  lookup(context: Context, titleId: string): string | null {
    if (!this.load(context) || !this.db || this.slots === 0) return null;
    let tid: bigint;
    try { tid = BigInt('0x' + titleId); } catch { return null; }
    const dv = new DataView(this.db.buffer, this.db.byteOffset);
    const mask = BigInt(this.slots - 1);
    for (let probe = 0; probe < this.slots; probe++) {
      const h = Number((tid + BigInt(probe)) & mask);
      const b = 16 + h * STRIDE;
      const k = dv.getBigUint64(b, true);
      if (k === 0n) return null;
      if (k === tid) {
        const off = dv.getUint32(b + 8, true);
        const len = dv.getUint32(b + 12, true);
        return new util.TextDecoder('utf-8').decodeToString(this.db.subarray(off, off + len));
      }
    }
    return null;
  }

  /** 用户目录无该游戏金手指时，把内置库内容落盘；已存在则跳过 */
  ensureSeed(context: Context, downloadDir: string, titleId: string): void {
    if (!downloadDir || !titleId) return;
    const path = `${downloadDir}/cheats/${titleId.toUpperCase()}.txt`;
    try {
      if (fileIo.accessSync(path)) return; // 已存在（含用户自定义），跳过
      const text = this.lookup(context, titleId);
      if (text === null) return;
      const dir = `${downloadDir}/cheats`;
      if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir);
      const f = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      fileIo.writeSync(f.fd, text);
      fileIo.closeSync(f);
      console.info(`[CheatsSeed] seeded ${path}`);
    } catch (e) {
      console.warn(`[CheatsSeed] seed failed ${titleId}: ${(e as BusinessError).message}`);
    }
  }
}
