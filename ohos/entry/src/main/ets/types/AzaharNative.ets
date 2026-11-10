import azahar from 'libazahar_ohos.so';

export type AzaharConfigValue = boolean | number | string;

export enum AzaharLoadResult {
  Success = 0,
  NotInitialized = 1,
  EmptyPath = 2,
  UnsupportedFormat = 3,
  FileNotFound = 4
}

export enum AzaharTouchAction {
  Down = 0,
  Move = 1,
  Up = 2
}

export enum AzaharKey {
  A = 0,
  B = 1,
  X = 2,
  Y = 3,
  Up = 4,
  Down = 5,
  Left = 6,
  Right = 7,
  L = 8,
  R = 9,
  Start = 10,
  Select = 11,
  ZL = 14,
  ZR = 15,
  Home = 16,
  Power = 17
}

export enum AzaharAnalog {
  CirclePad = 100,
  CStick = 101
}

export interface AzaharRuntimeInfo {
  initialized: boolean;
  state: string;
  loadedPath: string;
  deviceType: string;
  jitSupported: boolean;
  jitAvailable: boolean;
  jitReason: string;
  surfaceReady: boolean;
  coreLinked: boolean;
  coreBackend: string;
  backendStatus: string;
}

/** 系统图形栈探测结果；字段不可用时为 "-" */
export interface AzaharGraphicsInfo {
  vulkanVersion: string;
  glesVersion: string;
  gpuName: string;
}

export interface AzaharAppInfo {
  path: string;
  fileName: string;
  extension: string;
  supported: boolean;
}

export enum AzaharSaveStateStatus {
  OK = 0,
  /** 存档来自更早的格式版本，按宽松策略尝试读取 */
  RevisionMismatch = 1,
  /** 存档来自更新的格式版本，本构建不认识 */
  BuildMismatch = 2
}

export enum AzaharCIAInstallStatus {
  Success = 0,
  ErrorFailedToOpenFile = 1,
  ErrorFileNotFound = 2,
  ErrorAborted = 3,
  ErrorInvalid = 4,
  ErrorEncrypted = 5
}

export interface AzaharSaveStateInfo {
  slot: number;
  time: number;
  status: AzaharSaveStateStatus;
  buildName: string;
  /** .cst 文件大小（字节），0 表示文件缺失 */
  fileSize: number;
  /** 存档截图绝对路径（与 .cst 同名 .png），无截图时为空串 */
  screenshotPath: string;
  /** 存在覆盖前旧档内存备份，可撤销最近一次写档（仅保留本会话最近一次覆盖） */
  hasUndo: boolean;
}

/** RunLoop 非致命错误的上报（帧泵消费）；status 为 ResultStatus 名，如 error_savestate_build_mismatch */
export interface AzaharCoreError {
  status: string;
  details: string;
}

/** 快速存/读档专用槽位（对齐上游 QUICKSAVE_SLOT=0 约定）：不进存档列表，不可手动选择/删除 */
export const QUICK_SAVE_STATE_SLOT: number = 0;

export interface AzaharGameMetadata {
  path: string;
  titleId: string;
  shortTitle: string;
  longTitle: string;
  publisher: string;
  regions: string;
  productCode: string;
  extdataId: string;
  fileType: string;
  iconStatus: string;
  valid: boolean;
  encrypted: boolean;
  insertable: boolean;
  systemTitle: boolean;
  visible: boolean;
  hasIcon: boolean;
  iconWidth: number;
  iconHeight: number;
  iconRgb565?: ArrayBuffer;
  icon?: ArrayBuffer;
}

export interface AzaharCheatInfo {
  index: number;
  name: string;
  notes: string;
  code: string;
  type: string;
  enabled: boolean;
}

export interface AzaharMultiplayerRoomInfo {
  id: string;
  name: string;
  description: string;
  owner: string;
  address: string;
  port: number;
  maxPlayers: number;
  memberCount: number;
  netVersion: number;
  hasPassword: boolean;
  preferredGame: string;
  preferredGameId: string;
}

export interface AzaharMultiplayerMemberInfo {
  nickname: string;
  username: string;
  gameName: string;
}

export interface AzaharMultiplayerSessionInfo {
  initialized: boolean;
  joined: boolean;
  moderator: boolean;
  hosting: boolean;
  roomName: string;
  memberSlots: number;
  members: AzaharMultiplayerMemberInfo[];
  usernameBans: string[];
}

// 与 native OhosNetPlayStatus / Android NetPlayStatus 一致的错误码
export enum AzaharNetPlayStatus {
  NoError = 0,
  NetworkError = 1,
  LostConnection = 2,
  NameCollision = 3,
  MacCollision = 4,
  ConsoleIdCollision = 5,
  WrongVersion = 6,
  WrongPassword = 7,
  CouldNotConnect = 8,
  RoomIsFull = 9,
  HostBanned = 10,
  PermissionDenied = 11,
  NoSuchUser = 12,
  AlreadyInRoom = 13,
  CreateRoomError = 14,
  HostKicked = 15,
  UnknownError = 16,
}

export interface AzaharSystemProfile {
  available: boolean;
  username: string;
  birthMonth: number;
  birthDay: number;
  language: number;
  soundOutputMode: number;
  countryCode: number;
  systemSetupNeeded: boolean;
  playCoins: number;
  macAddress: string;
  consoleId: number;
  consoleIdText: string;
}

export interface AzaharSystemFilesStatus {
  old3dsInstalled: boolean;
  new3dsInstalled: boolean;
}

export enum AzaharTitleContentKind {
  Application = 0,
  Update = 1,
  DLC = 2
}

export interface AzaharTitleContentStatus {
  applicationInstalled: boolean;
  updateInstalled: boolean;
  dlcInstalled: boolean;
  applicationPath: string;
  updatePath: string;
  dlcPath: string;
}

export interface AzaharRomFsDumpResult {
  success: boolean;
  baseStatus: number;
  updateStatus: number;
  basePath: string;
  updatePath: string;
}

export interface AzaharMovieStatus {
  mode: string;
  currentInput: number;
  totalInput: number;
}

export interface AzaharMovieMetadata {
  valid: boolean;
  validationResult: number;
  titleId: string;
  author: string;
  rerecordCount: number;
  inputCount: number;
}

// OHOS Camera_Device 的 ArkTS 投影：position/type/connection 分别对应
// Camera_Position / Camera_Type / Camera_Connection 枚举值
export interface AzaharCameraDeviceInfo {
  id: string;
  position: number;
  type: number;
  connection: number;
}

/** 原生画面矩形（帧缓冲像素坐标） */
export interface AzaharScreenRect {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

/** 原生帧缓冲布局：width/height 为帧缓冲尺寸，top/bottom 为两屏矩形（disabled 时为 null） */
export interface AzaharScreenLayout {
  width: number;
  height: number;
  top: AzaharScreenRect | null;
  bottom: AzaharScreenRect | null;
}

export class AzaharNative {
  static initEmulator(
    filesDir: string,
    cacheDir: string,
    userDir: string,
    deviceType: string,
    tabletJitUserEnabled: boolean
  ): boolean {
    return azahar.initEmulator(filesDir, cacheDir, userDir, deviceType, tabletJitUserEnabled);
  }

  static shutdownEmulator(): boolean {
    return azahar.shutdownEmulator();
  }

  static loadApplication(path: string): AzaharLoadResult {
    return azahar.loadApplication(path) as AzaharLoadResult;
  }

  static startEmulation(): boolean {
    return azahar.startEmulation();
  }

  static pauseEmulation(): boolean {
    return azahar.pauseEmulation();
  }

  static resumeEmulation(): boolean {
    return azahar.resumeEmulation();
  }

  static doFrame(): boolean {
    return azahar.doFrame();
  }

  static stopEmulation(): boolean {
    return azahar.stopEmulation();
  }

  static resetEmulation(): boolean {
    return azahar.resetEmulation();
  }

  static isRunning(): boolean {
    return azahar.isRunning();
  }

  static isPaused(): boolean {
    return azahar.isPaused();
  }

  static consumeCameraPermissionRequest(): boolean {
    return azahar.consumeCameraPermissionRequest();
  }

  static consumeMicPermissionRequest(): boolean {
    return azahar.consumeMicPermissionRequest();
  }

  static consumeStillImagePickRequest(): boolean {
    return azahar.consumeStillImagePickRequest();
  }

  static consumeCoreError(): AzaharCoreError | null {
    return azahar.consumeCoreError() as AzaharCoreError | null;
  }

  static setStillImagePath(path: string): boolean {
    return azahar.setStillImagePath(path);
  }

  static getCameraDevices(): AzaharCameraDeviceInfo[] {
    return azahar.getCameraDevices();
  }

  static startGamepadInputCapture(): boolean {
    return azahar.startGamepadInputCapture();
  }

  static startGamepadAxisCapture(): boolean {
    return azahar.startGamepadAxisCapture();
  }

  static cancelGamepadInputCapture(): boolean {
    return azahar.cancelGamepadInputCapture();
  }

  static consumeGamepadInputCapture(): number {
    return azahar.consumeGamepadInputCapture();
  }

  // 测试 tab 用的原始手柄快照（JSON 字符串）：
  // {"online","name","last","pressed":[codes],"axes":[lx,ly,rx,ry,hatX,hatY],
  //  "triggers":[lt,rt],"now":ms,"events":[[seq,code,down,ms]]}，events 仅含 seq > sinceSeq
  static getGamepadTestState(sinceSeq: number): string {
    return azahar.getGamepadTestState(sinceSeq);
  }

  // 清空测试 tab 的事件日志（不影响实时状态）
  static resetGamepadTestState(): boolean {
    return azahar.resetGamepadTestState();
  }

  // 手柄当前按住的 3DS 按键（映射后的 AzaharKey 值，含轴驱动的十字键），
  // 游戏内帧泵轮询用于虚拟按键按下反馈
  static getGamepadPressedKeys(): number[] {
    return azahar.getGamepadPressedKeys();
  }

  // 手柄当前驱动的 3DS 摇杆值（死区/映射后）：
  // [circlepad_x, circlepad_y, cstick_x, cstick_y]，帧泵轮询用于虚拟摇杆显示
  static getGamepadAnalogState(): number[] {
    return azahar.getGamepadAnalogState();
  }

  static sendTouchEvent(x: number, y: number, action: AzaharTouchAction): boolean {
    return azahar.sendTouchEvent(x, y, action);
  }

  static sendKeyEvent(key: AzaharKey, isDown: boolean): boolean {
    return azahar.sendKeyEvent(key, isDown);
  }

  static sendAnalogEvent(analog: AzaharAnalog, x: number, y: number): boolean {
    return azahar.sendAnalogEvent(analog, x, y);
  }

  // 3DS 翻盖开合（PTM shell_open）；未运行/服务不可用时 setter 返回 false、getter 返回 true
  static setShellOpen(open: boolean): boolean {
    return azahar.setShellOpen(open);
  }

  static getShellOpen(): boolean {
    return azahar.getShellOpen();
  }

  // APT 系统睡眠协商状态：0=醒着 1=询问中 2=准备中 3=睡眠中（真机合盖走睡眠协商而非直接停机）
  static getSystemSleepState(): number {
    return azahar.getSystemSleepState();
  }

  static setScreenRotation(rotation: number): boolean {
    return azahar.setScreenRotation(rotation);
  }

  static saveState(slot: number): Promise<boolean> {
    return azahar.saveState(slot);
  }

  static loadState(slot: number): boolean {
    return azahar.loadState(slot);
  }

  /** maxSlot 为手动槽位上限（默认沿用上游 11：手动槽 1-10）；槽 0 固定为快速存/读档 */
  static getSaveStateInfo(maxSlot?: number): AzaharSaveStateInfo[] {
    return azahar.getSaveStateInfo(maxSlot) as AzaharSaveStateInfo[];
  }

  static deleteState(slot: number): boolean {
    return azahar.deleteState(slot);
  }

  /** 该槽位存在"覆盖前旧档"备份时可撤销最近一次写档（一次性，恢复后备份删除） */
  static hasUndoState(slot: number): boolean {
    return azahar.hasUndoState(slot);
  }

  static undoState(slot: number): boolean {
    return azahar.undoState(slot);
  }

  static captureScreenshot(path: string, resolutionScale: number = 0): boolean {
    return azahar.captureScreenshot(path, resolutionScale);
  }

  static installCIA(path: string): AzaharCIAInstallStatus {
    return azahar.installCIA(path) as AzaharCIAInstallStatus;
  }

  static getInstalledGamePaths(): string[] {
    return azahar.getInstalledGamePaths() as string[];
  }

  static getCheats(titleId: string): AzaharCheatInfo[] {
    return azahar.getCheats(titleId) as AzaharCheatInfo[];
  }

  static setCheatEnabled(titleId: string, index: number, enabled: boolean): boolean {
    return azahar.setCheatEnabled(titleId, index, enabled);
  }

  static upsertGatewayCheat(
    titleId: string,
    index: number,
    name: string,
    notes: string,
    code: string,
    enabled: boolean
  ): boolean {
    return azahar.upsertGatewayCheat(titleId, index, name, notes, code, enabled);
  }

  static removeCheat(titleId: string, index: number): boolean {
    return azahar.removeCheat(titleId, index);
  }

  static importCheats(titleId: string, contents: string): boolean {
    return azahar.importCheats(titleId, contents);
  }

  static validateGatewayCheatCode(code: string): number {
    return azahar.validateGatewayCheatCode(code);
  }

  static isSearchingForAmiibo(): boolean {
    return azahar.isSearchingForAmiibo();
  }

  static loadAmiibo(path: string): boolean {
    return azahar.loadAmiibo(path);
  }

  static removeAmiibo(): boolean {
    return azahar.removeAmiibo();
  }

  /** 现场生成合法 amiibo .bin（id 为 16 位十六进制 figure id，可含或不含 '@' 前缀） */
  static makeAmiiboFile(id: string, path: string): boolean {
    return azahar.makeAmiiboFile(id, path);
  }

  /** ZipPass：导出擦肩数据为 .pass.zip，返回写入的消息条数，<0 为错误 */
  static zipPassExport(path: string): number {
    return azahar.zipPassExport(path);
  }

  /** ZipPass：导入 .pass.zip，返回导入条数，<0 为错误（-2 缺系统文件，-3 未启用 LLE） */
  static zipPassImport(path: string): number {
    return azahar.zipPassImport(path);
  }

  /** ZipPass：导入联机期间排队收到的 pass.zip */
  static zipPassImportQueued(): number {
    return azahar.zipPassImportQueued();
  }

  /** 清除全部游戏的 StreetPass/擦肩数据 */
  static zipPassClearStreetPass(): number {
    return azahar.zipPassClearStreetPass();
  }

  static getMultiplayerRooms(): AzaharMultiplayerRoomInfo[] {
    return azahar.getMultiplayerRooms() as AzaharMultiplayerRoomInfo[];
  }

  static multiplayerJoinRoom(address: string, port: number, username: string, password: string): number {
    return azahar.multiplayerJoinRoom(address, port, username, password) as number;
  }

  static multiplayerCreateRoom(address: string, port: number, username: string, gameName: string,
    gameId: number, password: string, roomName: string, maxPlayers: number): number {
    return azahar.multiplayerCreateRoom(address, port, username, gameName, gameId, password,
      roomName, maxPlayers) as number;
  }

  static multiplayerLeaveRoom(): void {
    azahar.multiplayerLeaveRoom();
  }

  static getMultiplayerSessionInfo(): AzaharMultiplayerSessionInfo {
    return azahar.getMultiplayerSessionInfo() as AzaharMultiplayerSessionInfo;
  }

  static multiplayerKickUser(username: string): void {
    azahar.multiplayerKickUser(username);
  }

  static multiplayerBanUser(username: string): void {
    azahar.multiplayerBanUser(username);
  }

  static multiplayerUnbanUser(username: string): void {
    azahar.multiplayerUnbanUser(username);
  }

  static multiplayerSendChatMessage(message: string): void {
    azahar.multiplayerSendChatMessage(message);
  }

  static pollMultiplayerEvents(): string[] {
    return azahar.pollMultiplayerEvents() as string[];
  }

  static getSystemProfile(): AzaharSystemProfile {
    return azahar.getSystemProfile() as AzaharSystemProfile;
  }

  static setSystemProfile(profile: AzaharSystemProfile): boolean {
    return azahar.setSystemProfile(profile);
  }

  static regenerateConsoleId(): string {
    return azahar.regenerateConsoleId();
  }

  static regenerateMacAddress(): string {
    return azahar.regenerateMacAddress();
  }

  static getCountryCompatibility(region: number): number {
    return azahar.getCountryCompatibility(region);
  }

  static isFullConsoleLinked(): boolean {
    return azahar.isFullConsoleLinked();
  }

  static unlinkConsole(): boolean {
    return azahar.unlinkConsole();
  }

  static getSystemFilesStatus(): AzaharSystemFilesStatus {
    return azahar.getSystemFilesStatus() as AzaharSystemFilesStatus;
  }

  static uninstallSystemFiles(old3ds: boolean): boolean {
    return azahar.uninstallSystemFiles(old3ds);
  }

  static getTitleContentStatus(titleId: string): AzaharTitleContentStatus {
    return azahar.getTitleContentStatus(titleId) as AzaharTitleContentStatus;
  }

  static uninstallTitleContent(titleId: string, contentKind: AzaharTitleContentKind): boolean {
    return azahar.uninstallTitleContent(titleId, contentKind);
  }

  static dumpRomFS(path: string): AzaharRomFsDumpResult {
    return azahar.dumpRomFS(path) as AzaharRomFsDumpResult;
  }

  static getMovieStatus(): AzaharMovieStatus {
    return azahar.getMovieStatus() as AzaharMovieStatus;
  }

  static getMovieMetadata(path: string): AzaharMovieMetadata {
    return azahar.getMovieMetadata(path) as AzaharMovieMetadata;
  }

  static saveMovie(): boolean {
    return azahar.saveMovie();
  }

  static closeMovie(): boolean {
    return azahar.closeMovie();
  }

  static hasGamePerfHacks(titleId: string): boolean {
    return azahar.hasGamePerfHacks(titleId);
  }

  static setConfig(key: string, value: AzaharConfigValue): boolean {
    return azahar.setConfig(key, value);
  }

  static getConfig(key: string): AzaharConfigValue | undefined {
    return azahar.getConfig(key) as AzaharConfigValue | undefined;
  }

  static applyConfig(): boolean {
    return azahar.applyConfig();
  }

  static saveConfig(): boolean {
    return azahar.saveConfig();
  }

  static setTemporaryFrameLimit(speed: number): boolean {
    return azahar.setTemporaryFrameLimit(speed);
  }

  static disableTemporaryFrameLimit(): boolean {
    return azahar.disableTemporaryFrameLimit();
  }

  static getPerfStats(): number[] {
    return azahar.getPerfStats() as number[];
  }

  static updateDeviceProfile(deviceType: string, tabletJitUserEnabled: boolean): boolean {
    return azahar.updateDeviceProfile(deviceType, tabletJitUserEnabled);
  }

  static isJitSupported(deviceType: string): boolean {
    return azahar.isJitSupported(deviceType);
  }

  static isJitAvailable(): boolean {
    return azahar.isJitAvailable();
  }

  static getRuntimeInfo(): AzaharRuntimeInfo {
    return azahar.getRuntimeInfo() as AzaharRuntimeInfo;
  }

  static getGraphicsInfo(): AzaharGraphicsInfo {
    return azahar.getGraphicsInfo() as AzaharGraphicsInfo;
  }

  /**
   * 原生帧缓冲布局 [w, h, topEn, topL, topT, topR, topB, botEn, botL, botT, botR, botB]
   * emu window 不存在或未生成 layout 时返回 null
   */
  static getScreenLayout(): AzaharScreenLayout | null {
    const raw = azahar.getScreenLayout() as number[];
    if (!raw || raw.length < 12) {
      return null;
    }
    return {
      width: raw[0],
      height: raw[1],
      top: raw[2] !== 0 ? { left: raw[3], top: raw[4], right: raw[5], bottom: raw[6] } : null,
      bottom: raw[7] !== 0 ? { left: raw[8], top: raw[9], right: raw[10], bottom: raw[11] } : null
    };
  }

  // 安全区内边距（framebuffer px），写入主窗口并立即重算屏幕布局
  static setScreenOffsets(left: number, top: number, right: number, bottom: number): void {
    azahar.setScreenOffsets(left, top, right, bottom);
  }

  // 布局编辑器显式屏幕矩形（framebuffer px，窗口坐标）：双屏按矩形摆放并跳过
  // layout_option 自动布局与安全区内边距；swap_screen 仍会交换两屏角色
  static setCustomScreenRects(topX: number, topY: number, topW: number, topH: number,
    botX: number, botY: number, botW: number, botH: number): void {
    azahar.setCustomScreenRects(topX, topY, topW, topH, botX, botY, botW, botH);
  }

  // 清除显式屏幕矩形，恢复 layout_option 自动布局
  static clearCustomScreenRects(): void {
    azahar.clearCustomScreenRects();
  }

  static getAppInfo(path: string): AzaharAppInfo {
    return azahar.getAppInfo(path) as AzaharAppInfo;
  }

  static getGameMetadata(path: string): AzaharGameMetadata {
    return azahar.getGameMetadata(path) as AzaharGameMetadata;
  }

  static getSupportedExtensions(): string[] {
    return azahar.getSupportedExtensions();
  }

  static isAudioEnabled(): boolean {
    return azahar.isAudioEnabled();
  }

  static isGraphicsEnabled(): boolean {
    return azahar.isGraphicsEnabled();
  }

  static registerXComponent(xcomponentId: string, context?: object): boolean {
    return azahar.registerXComponent(xcomponentId, context);
  }

  static runNativeTests(filter: string = ''): string {
    return azahar.runNativeTests(filter);
  }

  static asmCrashProbe(): string {
    return azahar.asmCrashProbe();
  }
}
