declare namespace azahar {
  type ConfigValue = boolean | number | string;

  interface OhosCameraDevice {
    id: string;
    position: number;
    type: number;
    connection: number;
  }

  interface RuntimeInfo {
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

  interface GraphicsInfo {
    vulkanVersion: string;
    glesVersion: string;
    gpuName: string;
  }

  interface AppInfo {
    path: string;
    fileName: string;
    extension: string;
    supported: boolean;
  }

  interface SaveStateInfo {
    slot: number;
    time: number;
    status: number;
    buildName: string;
    fileSize: number;
    screenshotPath: string;
  }

  interface CoreErrorInfo {
    status: string;
    details: string;
  }

  interface GameMetadata {
    path: string;
    titleId: string;
    shortTitle: string;
    longTitle: string;
    publisher: string;
    regions: string;
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

  interface CheatInfo {
    index: number;
    name: string;
    notes: string;
    code: string;
    type: string;
    enabled: boolean;
  }

  interface MultiplayerRoomInfo {
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

  interface MultiplayerMemberInfo {
    nickname: string;
    username: string;
    gameName: string;
  }

  interface MultiplayerSessionInfo {
    initialized: boolean;
    joined: boolean;
    moderator: boolean;
    hosting: boolean;
    roomName: string;
    memberSlots: number;
    members: MultiplayerMemberInfo[];
    usernameBans: string[];
  }

  interface SystemProfile {
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

  interface SystemFilesStatus {
    old3dsInstalled: boolean;
    new3dsInstalled: boolean;
  }

  interface TitleContentStatus {
    applicationInstalled: boolean;
    updateInstalled: boolean;
    dlcInstalled: boolean;
    applicationPath: string;
    updatePath: string;
    dlcPath: string;
  }

  interface RomFsDumpResult {
    success: boolean;
    baseStatus: number;
    updateStatus: number;
    basePath: string;
    updatePath: string;
  }

  interface MovieStatus {
    mode: string;
    currentInput: number;
    totalInput: number;
  }

  interface MovieMetadata {
    valid: boolean;
    validationResult: number;
    titleId: string;
    author: string;
    rerecordCount: number;
    inputCount: number;
  }

  function initEmulator(
    filesDir: string,
    cacheDir: string,
    userDir: string,
    deviceType?: string,
    tabletJitUserEnabled?: boolean
  ): boolean;
  function shutdownEmulator(): boolean;
  function loadApplication(path: string): number;
  function startEmulation(): boolean;
  function pauseEmulation(): boolean;
  function resumeEmulation(): boolean;
  function doFrame(): boolean;
  function stopEmulation(): boolean;
  function resetEmulation(): boolean;
  function isRunning(): boolean;
  function isPaused(): boolean;
  function consumeCameraPermissionRequest(): boolean;
  function consumeMicPermissionRequest(): boolean;
  function consumeStillImagePickRequest(): boolean;
  function consumeCoreError(): CoreErrorInfo | null;
  function setStillImagePath(path: string): boolean;
  function getCameraDevices(): OhosCameraDevice[];
  function startGamepadInputCapture(): boolean;
  function startGamepadAxisCapture(): boolean;
  function cancelGamepadInputCapture(): boolean;
  function consumeGamepadInputCapture(): number;
  function getGamepadTestState(sinceSeq: number): string;
  function resetGamepadTestState(): boolean;
  function getGamepadPressedKeys(): number[];
  function getGamepadAnalogState(): number[];
  function sendTouchEvent(x: number, y: number, action: number): boolean;
  function sendKeyEvent(key: number, isDown: boolean): boolean;
  function sendAnalogEvent(analog: number, x: number, y: number): boolean;
  function setShellOpen(open: boolean): boolean;
  function getShellOpen(): boolean;
  // APT 系统睡眠协商状态：0=醒着 1=询问中 2=准备中 3=睡眠中
  function getSystemSleepState(): number;
  function setScreenRotation(rotation: number): boolean;
  function saveState(slot: number): Promise<boolean>;
  function loadState(slot: number): boolean;
  function getSaveStateInfo(maxSlot?: number): SaveStateInfo[];
  function deleteState(slot: number): boolean;
  // 该槽位存在覆盖前旧档内存备份，可撤销最近一次写档（仅保留本会话最近一次覆盖）
  function hasUndoState(slot: number): boolean;
  function undoState(slot: number): boolean;
  function captureScreenshot(path: string, resolutionScale?: number): boolean;
  function installCIA(path: string): number;
  function getInstalledGamePaths(): string[];
  function getCheats(titleId: string): CheatInfo[];
  function hasGamePerfHacks(titleId: string): boolean;
  function setCheatEnabled(titleId: string, index: number, enabled: boolean): boolean;
  function upsertGatewayCheat(
    titleId: string,
    index: number,
    name: string,
    notes: string,
    code: string,
    enabled: boolean
  ): boolean;
  function removeCheat(titleId: string, index: number): boolean;
  function importCheats(titleId: string, contents: string): boolean;
  function validateGatewayCheatCode(code: string): number;
  function isSearchingForAmiibo(): boolean;
  function loadAmiibo(path: string): boolean;
  function removeAmiibo(): boolean;
  function makeAmiiboFile(id: string, path: string): boolean;
  function zipPassExport(path: string): number;
  function zipPassImport(path: string): number;
  function zipPassImportQueued(): number;
  function zipPassClearStreetPass(): number;
  function getMultiplayerRooms(): MultiplayerRoomInfo[];
  function multiplayerJoinRoom(address: string, port: number, username: string, password: string): number;
  function multiplayerCreateRoom(address: string, port: number, username: string, gameName: string, gameId: number, password: string, roomName: string, maxPlayers: number): number;
  function multiplayerLeaveRoom(): void;
  function getMultiplayerSessionInfo(): MultiplayerSessionInfo;
  function multiplayerKickUser(username: string): void;
  function multiplayerBanUser(username: string): void;
  function multiplayerUnbanUser(username: string): void;
  function multiplayerSendChatMessage(message: string): void;
  function pollMultiplayerEvents(): string[];
  function getSystemProfile(): SystemProfile;
  function setSystemProfile(profile: SystemProfile): boolean;
  function regenerateConsoleId(): string;
  function regenerateMacAddress(): string;
  function getCountryCompatibility(region: number): number;
  function isFullConsoleLinked(): boolean;
  function unlinkConsole(): boolean;
  function getSystemFilesStatus(): SystemFilesStatus;
  function uninstallSystemFiles(old3ds: boolean): boolean;
  function getTitleContentStatus(titleId: string): TitleContentStatus;
  function uninstallTitleContent(titleId: string, contentKind: number): boolean;
  function dumpRomFS(path: string): RomFsDumpResult;
  function getMovieStatus(): MovieStatus;
  function getMovieMetadata(path: string): MovieMetadata;
  function saveMovie(): boolean;
  function closeMovie(): boolean;
  function setConfig(key: string, value: ConfigValue): boolean;
  function getConfig(key: string): ConfigValue | undefined;
  function applyConfig(): boolean;
  function saveConfig(): boolean;
  function setTemporaryFrameLimit(speed: number): boolean;
  function disableTemporaryFrameLimit(): boolean;
  function getPerfStats(): number[];
  function updateDeviceProfile(deviceType: string, tabletJitUserEnabled: boolean): boolean;
  function isJitSupported(deviceType: string): boolean;
  function isJitAvailable(): boolean;
  function getRuntimeInfo(): RuntimeInfo;
  function getGraphicsInfo(): GraphicsInfo;
  // [w, h, topEn, topL, topT, topR, topB, botEn, botL, botT, botR, botB]；无 window/layout 时为空数组
  function getScreenLayout(): number[];
  function setScreenOffsets(left: number, top: number, right: number, bottom: number): void;
  // 布局编辑器显式屏幕矩形（framebuffer px，窗口坐标）；清除后恢复自动布局
  function setCustomScreenRects(topX: number, topY: number, topW: number, topH: number,
    botX: number, botY: number, botW: number, botH: number): void;
  function clearCustomScreenRects(): void;
  function getAppInfo(path: string): AppInfo;
  function getGameMetadata(path: string): GameMetadata;
  function getSupportedExtensions(): string[];
  function isAudioEnabled(): boolean;
  function isGraphicsEnabled(): boolean;
  function registerXComponent(xcomponentId: string, context?: object): boolean;
  function runNativeTests(filter: string): string;
  function asmCrashProbe(): string;
}

export default azahar;
