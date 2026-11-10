const runtimeInfo = {
  initialized: false,
  state: 'stopped',
  loadedPath: '',
  deviceType: 'phone',
  jitSupported: false,
  jitAvailable: false,
  jitReason: 'jit_unsupported',
  surfaceReady: false,
  coreLinked: false,
  coreBackend: 'mock',
  backendStatus: 'mock_runtime'
};

const config: Record<string, boolean | number | string> = {};
const movieStatus = {
  mode: 'none',
  currentInput: 0,
  totalInput: 0
};
let fullConsoleLinked: boolean = false;
let old3dsSystemFilesInstalled: boolean = false;
let new3dsSystemFilesInstalled: boolean = false;
const titleContentStatus: Record<string, {
  applicationInstalled: boolean;
  updateInstalled: boolean;
  dlcInstalled: boolean;
  applicationPath: string;
  updatePath: string;
  dlcPath: string;
}> = {};
const playTimeSeconds: Record<string, number> = {};
let shellOpen: boolean = true;
let systemSleepState: number = 0;

// mock 无法真实分配 WX 内存：以非手机设备近似 native 探测结果
function isJitSupported(deviceType: string): boolean {
  return deviceType !== 'phone';
}

function updateJit(deviceType: string, tabletJitUserEnabled: boolean): boolean {
  runtimeInfo.deviceType = deviceType;
  runtimeInfo.jitSupported = isJitSupported(deviceType);
  runtimeInfo.jitAvailable = runtimeInfo.jitSupported && tabletJitUserEnabled;
  runtimeInfo.jitReason = runtimeInfo.jitAvailable ? 'jit_enabled' :
    (runtimeInfo.jitSupported ? 'user_setting_disabled' : 'jit_unsupported');
  config.use_cpu_jit = runtimeInfo.jitAvailable;
  return runtimeInfo.jitAvailable;
}

const NativeMock: Record<string, Object> = {
  initEmulator: (_filesDir: string, _cacheDir: string, _userDir: string, deviceType: string = 'phone', tabletJitUserEnabled: boolean = false): boolean => {
    runtimeInfo.initialized = true;
    updateJit(deviceType, tabletJitUserEnabled);
    return true;
  },
  shutdownEmulator: (): boolean => {
    runtimeInfo.initialized = false;
    runtimeInfo.state = 'stopped';
    runtimeInfo.loadedPath = '';
    return true;
  },
  loadApplication: (path: string): number => {
    if (!runtimeInfo.initialized) return 1;
    if (!path) return 2;
    runtimeInfo.loadedPath = path;
    runtimeInfo.state = 'loaded';
    if (typeof config.movie_record_path === 'string' && config.movie_record_path.length > 0) {
      movieStatus.mode = 'recording';
    } else if (typeof config.movie_playback_path === 'string' && config.movie_playback_path.length > 0) {
      movieStatus.mode = 'playing';
      movieStatus.totalInput = 1;
    } else {
      movieStatus.mode = 'none';
      movieStatus.currentInput = 0;
      movieStatus.totalInput = 0;
    }
    return 0;
  },
  startEmulation: (): boolean => {
    runtimeInfo.state = 'running';
    return true;
  },
  setShellOpen: (open: boolean): boolean => {
    shellOpen = open;
    // mock 没有 APT 协商流程：合盖视为直接进入睡眠、开盖即醒
    systemSleepState = open ? 0 : 3;
    return true;
  },
  getShellOpen: (): boolean => shellOpen,
  getSystemSleepState: (): number => systemSleepState,
  pauseEmulation: (): boolean => {
    runtimeInfo.state = 'paused';
    return true;
  },
  resumeEmulation: (): boolean => {
    runtimeInfo.state = 'running';
    return true;
  },
  doFrame: (): boolean => runtimeInfo.state === 'running',
  stopEmulation: (): boolean => {
    runtimeInfo.state = runtimeInfo.loadedPath ? 'loaded' : 'stopped';
    return true;
  },
  resetEmulation: (): boolean => true,
  isRunning: (): boolean => runtimeInfo.state === 'running',
  isPaused: (): boolean => runtimeInfo.state === 'paused',
  sendTouchEvent: (_x: number, _y: number, _action: number): boolean => true,
  sendKeyEvent: (_key: number, _isDown: boolean): boolean => true,
  sendAnalogEvent: (_analog: number, _x: number, _y: number): boolean => true,
  setScreenRotation: (_rotation: number): boolean => true,
  saveState: (_slot: number): boolean => false,
  loadState: (_slot: number): boolean => false,
  captureScreenshot: (_path: string, _resolutionScale: number = 0): boolean => runtimeInfo.state === 'running' || runtimeInfo.state === 'paused',
  setConfig: (key: string, value: boolean | number | string): boolean => {
    config[key] = value;
    if (key === 'use_cpu_jit' && typeof value === 'boolean') {
      updateJit(runtimeInfo.deviceType, value);
    }
    return true;
  },
  getConfig: (key: string): boolean | number | string | undefined => config[key],
  applyConfig: (): boolean => true,
  saveConfig: (): boolean => true,
  setTemporaryFrameLimit: (speed: number): boolean => {
    config.temporary_frame_limit = speed;
    config.is_temporary_frame_limit = true;
    return true;
  },
  disableTemporaryFrameLimit: (): boolean => {
    config.is_temporary_frame_limit = false;
    return true;
  },
  updateDeviceProfile: (deviceType: string, tabletJitUserEnabled: boolean): boolean => updateJit(deviceType, tabletJitUserEnabled),
  isJitSupported: (deviceType: string): boolean => isJitSupported(deviceType),
  isJitAvailable: (): boolean => runtimeInfo.jitAvailable,
  getRuntimeInfo: (): object => runtimeInfo,
  getAppInfo: (path: string): object => {
    const dot = path.lastIndexOf('.');
    const slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    const extension = dot >= 0 ? path.substring(dot).toLowerCase() : '';
    const supported = ['.3ds', '.cci', '.cia', '.cxi', '.3dsx', '.elf', '.axf', '.app'].includes(extension);
    return {
      path,
      fileName: slash >= 0 ? path.substring(slash + 1) : path,
      extension,
      supported
    };
  },
  getGameMetadata: (path: string): object => ({
    path,
    titleId: '000400000FF40A00',
    shortTitle: '',
    longTitle: '',
    publisher: '',
    regions: '',
    extdataId: '00000000000FF40A',
    fileType: '',
    iconStatus: 'mock',
    valid: true,
    encrypted: false,
    insertable: false,
    systemTitle: false,
    visible: true,
    hasIcon: false,
    iconWidth: 0,
    iconHeight: 0
  }),
  getSupportedExtensions: (): string[] => ['.3ds', '.cci', '.cxi', '.3dsx', '.elf', '.axf', '.app'],
  installCIA: (_path: string): number => 0,
  getInstalledGamePaths: (): string[] => [],
  isFullConsoleLinked: (): boolean => fullConsoleLinked,
  unlinkConsole: (): boolean => {
    if (!fullConsoleLinked) {
      return false;
    }
    fullConsoleLinked = false;
    return true;
  },
  getSystemFilesStatus: (): object => ({
    old3dsInstalled: old3dsSystemFilesInstalled,
    new3dsInstalled: new3dsSystemFilesInstalled
  }),
  uninstallSystemFiles: (old3ds: boolean): boolean => {
    if (old3ds) {
      old3dsSystemFilesInstalled = false;
    } else {
      new3dsSystemFilesInstalled = false;
    }
    return true;
  },
  getTitleContentStatus: (titleId: string): object => titleContentStatus[titleId] || {
    applicationInstalled: false,
    updateInstalled: false,
    dlcInstalled: false,
    applicationPath: '',
    updatePath: '',
    dlcPath: ''
  },
  uninstallTitleContent: (titleId: string, contentKind: number): boolean => {
    const status = titleContentStatus[titleId] || {
      applicationInstalled: false,
      updateInstalled: false,
      dlcInstalled: false,
      applicationPath: '',
      updatePath: '',
      dlcPath: ''
    };
    if (contentKind === 0) {
      status.applicationInstalled = false;
    } else if (contentKind === 1) {
      status.updateInstalled = false;
    } else if (contentKind === 2) {
      status.dlcInstalled = false;
    } else {
      return false;
    }
    titleContentStatus[titleId] = status;
    return true;
  },
  dumpRomFS: (_path: string): object => ({
    success: false,
    baseStatus: 3,
    updateStatus: 3,
    basePath: '',
    updatePath: ''
  }),
  getMovieStatus: (): object => movieStatus,
  getMovieMetadata: (_path: string): object => ({
    valid: true,
    validationResult: 0,
    titleId: '000400000FF40A00',
    author: 'Azahar OHOS',
    rerecordCount: 1,
    inputCount: 0
  }),
  saveMovie: (): boolean => movieStatus.mode === 'recording',
  closeMovie: (): boolean => {
    if (movieStatus.mode === 'none') {
      return false;
    }
    movieStatus.mode = 'none';
    movieStatus.currentInput = 0;
    movieStatus.totalInput = 0;
    return true;
  },
  getPlayTime: (titleId: string): number => playTimeSeconds[titleId] || 0,
  resetPlayTime: (titleId: string): boolean => {
    const hadPlayTime = (playTimeSeconds[titleId] || 0) > 0;
    delete playTimeSeconds[titleId];
    return hadPlayTime;
  },
  isAudioEnabled: (): boolean => true,
  isGraphicsEnabled: (): boolean => runtimeInfo.surfaceReady,
  registerXComponent: (_xcomponentId: string, _context?: object): boolean => {
    runtimeInfo.surfaceReady = true;
    return true;
  }
};

export default NativeMock;
