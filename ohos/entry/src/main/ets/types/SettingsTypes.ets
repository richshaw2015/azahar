import { HomeTab } from './HomeTab';

export type SettingValue = boolean | number | string | string[];

export enum SettingType {
  Boolean = 'boolean',
  Number = 'number',
  String = 'string',
  StringArray = 'stringArray'
}

export interface SettingDefinition {
  key: string;
  type: SettingType;
  defaultValue: SettingValue;
  nativeKey?: string;
}

export interface SettingOption {
  value: string | number;
  label: string;
  description?: string;
}

export const PREFERENCES_NAME: string = 'azahar_settings';
export const GLOBAL_WALLPAPER_URI_KEY: string = 'global_wallpaper_uri';

// 全部设置项 key 常量（唯一事实来源；SETTINGS_DEFINITIONS 与调用点统一引用）
export const KEY_ALLOW_PLUGIN_LOADER: string = 'allow_plugin_loader';
export const KEY_APP_ICON_STYLE: string = 'app_icon_style';
export const KEY_ANAGLYPH_SHADER_NAME: string = 'anaglyph_shader_name';
export const KEY_APPLY_REGION_FREE_PATCH: string = 'apply_region_free_patch';
export const KEY_ASPECT_RATIO: string = 'aspect_ratio';
export const KEY_ASYNC_CUSTOM_LOADING: string = 'async_custom_loading';
export const KEY_ASYNC_FS_OPERATIONS: string = 'async_fs_operations';
export const KEY_ASYNC_PRESENTATION: string = 'async_presentation';
export const KEY_ASYNC_SHADER_COMPILATION: string = 'async_shader_compilation';
export const KEY_AUDIO_EMULATION: string = 'audio_emulation';
export const KEY_AUDIO_INPUT_TYPE: string = 'audio_input_type';
export const KEY_BGM_ENABLED: string = 'bgm_enabled';
export const KEY_BGM_VOLUME: string = 'bgm_volume';
export const KEY_CAMERA_INNER_CONFIG: string = 'camera_inner_config';
export const KEY_CAMERA_INNER_FLIP: string = 'camera_inner_flip';
export const KEY_CAMERA_INNER_NAME: string = 'camera_inner_name';
export const KEY_CAMERA_OUTER_LEFT_CONFIG: string = 'camera_outer_left_config';
export const KEY_CAMERA_OUTER_LEFT_FLIP: string = 'camera_outer_left_flip';
export const KEY_CAMERA_OUTER_LEFT_NAME: string = 'camera_outer_left_name';
export const KEY_CAMERA_OUTER_RIGHT_CONFIG: string = 'camera_outer_right_config';
export const KEY_CAMERA_OUTER_RIGHT_FLIP: string = 'camera_outer_right_flip';
export const KEY_CAMERA_OUTER_RIGHT_NAME: string = 'camera_outer_right_name';
export const KEY_CARDBOARD_SCREEN_SIZE: string = 'cardboard_screen_size';
export const KEY_CARDBOARD_X_SHIFT: string = 'cardboard_x_shift';
export const KEY_CARDBOARD_Y_SHIFT: string = 'cardboard_y_shift';
export const KEY_CITRA_TOKEN: string = 'citra_token';
export const KEY_COMPRESS_CIA_INSTALLS: string = 'compress_cia_installs';
export const KEY_COVER_CORNER_RADIUS: string = 'cover_corner_radius';
export const KEY_CPU_CLOCK_PERCENTAGE: string = 'cpu_clock_percentage';
export const KEY_CPU_CORE_MODE: string = 'cpu_core_mode';
export const KEY_CUSTOM_TEXTURES: string = 'custom_textures';
export const KEY_DEFAULT_TAB: string = 'default_tab';
export const KEY_DELAY_GAME_RENDER_THREAD_US: string = 'delay_game_render_thread_us';
export const KEY_DELAY_START_FOR_LLE_MODULES: string = 'delay_start_for_lle_modules';
export const KEY_DETERMINISTIC_ASYNC_OPERATIONS: string = 'deterministic_async_operations';
export const KEY_DISABLE_GESTURE_BACK_IN_GAME: string = 'disable_gesture_back_in_game';
export const KEY_DISABLE_RIGHT_EYE_RENDER: string = 'disable_right_eye_render';
export const KEY_DISABLE_SPIRV_OPTIMIZER: string = 'disable_spirv_optimizer';
export const KEY_DUMP_TEXTURES: string = 'dump_textures';
export const KEY_ENABLE_AUDIO_STRETCHING: string = 'enable_audio_stretching';
export const KEY_ENABLE_REALTIME_AUDIO: string = 'enable_realtime_audio';
export const KEY_ENABLE_REQUIRED_ONLINE_LLE_MODULES: string = 'enable_required_online_lle_modules';
export const KEY_ENABLE_RPC_SERVER: string = 'enable_rpc_server';
export const KEY_FILTER_MODE: string = 'filter_mode';
export const KEY_FRAME_LIMIT: string = 'frame_limit';
export const KEY_GAME_LIST_LAYOUT: string = 'game_list_layout';
export const KEY_GAME_LIST_SORT_ASCENDING: string = 'game_list_sort_ascending';
export const KEY_GAME_NAME_SOURCE: string = 'game_name_source';
export const KEY_GAME_PERF_HACKS: string = 'game_perf_hacks';
export const KEY_GAMEPAD_AXIS_MAP: string = 'gamepad_axis_map';
export const KEY_GAMEPAD_BUTTON_MAP: string = 'gamepad_button_map';
export const KEY_GAMEPAD_COMBO: string = 'gamepad_combo';
export const KEY_GAMEPAD_DEADZONE: string = 'gamepad_deadzone';
export const KEY_GAMEPAD_HOTKEY_MAP: string = 'gamepad_hotkey_map';
export const KEY_GRAPHICS_API: string = 'graphics_api';
export const KEY_GRID_SIZE: string = 'grid_size';
export const KEY_IGNORE_SAFE_AREA: string = 'ignore_safe_area';
export const KEY_INIT_CLOCK: string = 'init_clock';
export const KEY_INIT_TICKS_OVERRIDE: string = 'init_ticks_override';
export const KEY_INIT_TICKS_TYPE: string = 'init_ticks_type';
export const KEY_INIT_TIME: string = 'init_time';
export const KEY_INIT_TIME_OFFSET: string = 'init_time_offset';
export const KEY_INPUT_HAPTIC_ENABLED: string = 'input_haptic_enabled';
export const KEY_INPUT_HAPTIC_STRENGTH: string = 'input_haptic_strength';
export const KEY_INSERTED_CARTRIDGE: string = 'inserted_cartridge';
export const KEY_DEBUG_LOG: string = 'debug_log';
export const KEY_LARGE_SCREEN_PROPORTION: string = 'large_screen_proportion';
export const KEY_LAST_ARTIC_BASE_ADDR: string = 'last_artic_base_addr';
export const KEY_LAYOUT_EDITOR_GRID_SIZE: string = 'layout_editor_grid_size';
// 布局编辑器网格密度默认值，SnapGuideSystem.DEFAULT_GRID_SIZE 的唯一事实来源（该文件反向引用本常量，避免 types→utils 循环依赖）
export const DEFAULT_LAYOUT_EDITOR_GRID_SIZE: number = 8;
export const KEY_LAYOUT_OPTION: string = 'layout_option';
export const KEY_LIST_SIZE: string = 'list_size';
export const KEY_LLE_APPLETS: string = 'lle_applets';
export const KEY_LOCK_GAME_BRIGHTNESS: string = 'lock_game_brightness';
export const KEY_MONO_RENDER_OPTION: string = 'mono_render_option';
export const KEY_MULTIPLAYER_FILTER_TEXT: string = 'multiplayer_filter_text';
export const KEY_MULTIPLAYER_HIDE_EMPTY: string = 'multiplayer_hide_empty';
export const KEY_MULTIPLAYER_HIDE_FULL: string = 'multiplayer_hide_full';
export const KEY_MULTIPLAYER_ROOM_ADDRESS: string = 'multiplayer_room_address';
export const KEY_MULTIPLAYER_ROOM_PASSWORD: string = 'multiplayer_room_password';
export const KEY_MULTIPLAYER_ROOM_PORT: string = 'multiplayer_room_port';
export const KEY_OVERLAY_THEME: string = 'overlay_theme';
export const KEY_PERFORMANCE_OVERLAY_ENABLE: string = 'performance_overlay_enable';
export const KEY_PERFORMANCE_OVERLAY_POSITION: string = 'performance_overlay_position';
export const KEY_PLUGIN_LOADER: string = 'plugin_loader';
export const KEY_PORTRAIT_LAYOUT_OPTION: string = 'portrait_layout_option';
export const KEY_PP_SHADER_NAME: string = 'pp_shader_name';
export const KEY_PRELOAD_TEXTURES: string = 'preload_textures';
export const KEY_PRIVACY_MODE_IN_GAME: string = 'privacy_mode_in_game';
export const KEY_REGION_VALUE: string = 'region_value';
export const KEY_RENDERER_DEBUG: string = 'renderer_debug';
export const KEY_RESOLUTION_FACTOR: string = 'resolution_factor';
export const KEY_SAVE_STATE_SLOT_COUNT: string = 'save_state_slot_count';
export const KEY_SCREEN_BOTTOM_LEFTRIGHT_PADDING: string = 'screen_bottom_leftright_padding';
export const KEY_SCREEN_BOTTOM_STRETCH: string = 'screen_bottom_stretch';
export const KEY_SCREEN_BOTTOM_TOPBOTTOM_PADDING: string = 'screen_bottom_topbottom_padding';
export const KEY_SCREEN_GAP: string = 'screen_gap';
export const KEY_SCREEN_ORIENTATION: string = 'screen_orientation';
export const KEY_SCREEN_TOP_LEFTRIGHT_PADDING: string = 'screen_top_leftright_padding';
export const KEY_SCREEN_TOP_STRETCH: string = 'screen_top_stretch';
export const KEY_SCREEN_TOP_TOPBOTTOM_PADDING: string = 'screen_top_topbottom_padding';
export const KEY_SECONDARY_DISPLAY_LAYOUT: string = 'secondary_display_layout';
export const KEY_SFX_ENABLED: string = 'sfx_enabled';
export const KEY_SFX_VOLUME: string = 'sfx_volume';
export const KEY_SHADERS_ACCURATE_MUL: string = 'shaders_accurate_mul';
export const KEY_SIMULATE_HEADPHONES_PLUGGED: string = 'simulate_headphones_plugged';
export const KEY_SMALL_SCREEN_POSITION: string = 'small_screen_position';
export const KEY_SOFT_INPUT_BEHAVIOUR: string = 'soft_input_behaviour';
export const KEY_SPIRV_SHADER_GEN: string = 'spirv_shader_gen';
export const KEY_STEPS_PER_HOUR: string = 'steps_per_hour';
export const KEY_TEXTURE_FILTER: string = 'texture_filter';
export const KEY_TEXTURE_SAMPLING: string = 'texture_sampling';
export const KEY_TOGGLE_UNIQUE_DATA_CONSOLE_TYPE: string = 'toggle_unique_data_console_type';
export const KEY_TURBO_LIMIT: string = 'turbo_limit';
export const KEY_UPRIGHT_SCREEN: string = 'upright_screen';
export const KEY_USE_ARTIC_BASE_CONTROLLER: string = 'use_artic_base_controller';
export const KEY_USE_DISK_SHADER_CACHE: string = 'use_disk_shader_cache';
export const KEY_USE_FRAME_LIMIT: string = 'use_frame_limit';
export const KEY_USE_HW_SHADER: string = 'use_hw_shader';
export const KEY_USE_INTEGER_SCALING: string = 'use_integer_scaling';
export const KEY_USE_SHADER_JIT: string = 'use_shader_jit';
export const KEY_USE_SKIP_DUPLICATE_FRAMES: string = 'use_skip_duplicate_frames';
export const KEY_USE_VIRTUAL_SD: string = 'use_virtual_sd';
export const KEY_USE_VSYNC: string = 'use_vsync';
export const KEY_VOLUME: string = 'volume';
export const KEY_WEB_API_URL: string = 'web_api_url';
export const KEY_FACTOR_3D: string = 'factor_3d';
export const KEY_IS_NEW_3DS: string = 'is_new_3ds';
export const KEY_RENDER_3D: string = 'render_3d';
export const KEY_RENDER_3D_WHICH_DISPLAY: string = 'render_3d_which_display';
export const KEY_SIMULATE_3DS_GPU_TIMINGS: string = 'simulate_3ds_gpu_timings';
export const KEY_SWAP_EYES_3D: string = 'swap_eyes_3d';
export const KEY_CONTROL_OPACITY: string = 'controlOpacity';

/** 手动存档槽位数量默认值与可选档位（对齐 nds SAVE_STATE_SLOT_COUNT_OPTIONS） */
export const DEFAULT_SAVE_STATE_SLOT_COUNT: number = 10;
export const SAVE_STATE_SLOT_COUNT_OPTIONS: SettingOption[] = [
  { value: 10, label: '10' },
  { value: 20, label: '20' },
  { value: 50, label: '50' },
  { value: 100, label: '100' }
];

export const SETTINGS_DEFINITIONS: SettingDefinition[] = [
  {
    // CPU 核心模式：0=动态重编译(JIT) 1=快速解释器 2=IR 解释器；-1=未选择，按设备能力推导
    key: KEY_CPU_CORE_MODE,
    type: SettingType.Number,
    defaultValue: -1
  },
  {
    key: KEY_USE_SHADER_JIT,
    type: SettingType.Boolean,
    defaultValue: true,
    nativeKey: 'use_shader_jit'
  },
  {
    key: KEY_USE_HW_SHADER,
    type: SettingType.Boolean,
    defaultValue: true,
    nativeKey: 'use_hw_shader'
  },
  {
    key: KEY_USE_DISK_SHADER_CACHE,
    type: SettingType.Boolean,
    defaultValue: true,
    nativeKey: 'use_disk_shader_cache'
  },
  {
    key: KEY_GRAPHICS_API,
    type: SettingType.Number,
    defaultValue: 2,
    nativeKey: 'graphics_api'
  },
  {
    key: KEY_RESOLUTION_FACTOR,
    type: SettingType.Number,
    defaultValue: 1,
    nativeKey: 'resolution_factor'
  },
  {
    key: KEY_CPU_CLOCK_PERCENTAGE,
    type: SettingType.Number,
    defaultValue: 100,
    nativeKey: 'cpu_clock_percentage'
  },
  {
    key: KEY_ENABLE_RPC_SERVER,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'enable_rpc_server'
  },
  {
    key: KEY_USE_ARTIC_BASE_CONTROLLER,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'use_artic_base_controller'
  },
  {
    // 物理手柄映射：空串=出厂默认映射；非空 JSON 为权威表（nativeButtonIdx->物理键码，缺省=未绑定）
    key: KEY_GAMEPAD_BUTTON_MAP,
    type: SettingType.String,
    defaultValue: '',
    nativeKey: 'gamepad_button_map'
  },
  {
    // 摇杆来源：{"circlepad":0,"cstick":1}；-1=无 0=左摇杆 1=右摇杆 2=十字键轴
    key: KEY_GAMEPAD_AXIS_MAP,
    type: SettingType.String,
    defaultValue: '',
    nativeKey: 'gamepad_axis_map'
  },
  {
    // 组合键（键宏）：{"code":物理键码,"buttons":[nativeButtonIdx,...]}
    key: KEY_GAMEPAD_COMBO,
    type: SettingType.String,
    defaultValue: '',
    nativeKey: 'gamepad_combo'
  },
  {
    // 摇杆死区，百分比 0-50；默认 10% 对齐 Qt 端 configure_input 的 deadzone 默认值
    key: KEY_GAMEPAD_DEADZONE,
    type: SettingType.Number,
    defaultValue: 10,
    nativeKey: 'gamepad_deadzone'
  },
  {
    // 手柄快捷键：{action:物理键码}，仅 ArkTS 侧消费，不进 native 配置。
    // 默认：2313(手柄 Mode/Home 键, ppsspp 实测) -> 暂停/继续，与 nds 默认映射一致
    key: KEY_GAMEPAD_HOTKEY_MAP,
    type: SettingType.String,
    defaultValue: '{"toggle_pause":2313}'
  },
  {
    key: KEY_FRAME_LIMIT,
    type: SettingType.Number,
    defaultValue: 100,
    nativeKey: 'frame_limit'
  },
  {
    key: KEY_TURBO_LIMIT,
    type: SettingType.Number,
    defaultValue: 200,
    nativeKey: 'turbo_limit'
  },
  {
    key: KEY_USE_VSYNC,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'use_vsync'
  },
  {
    key: KEY_TEXTURE_SAMPLING,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'texture_sampling'
  },
  {
    key: KEY_DELAY_GAME_RENDER_THREAD_US,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'delay_game_render_thread_us'
  },
  {
    key: KEY_TEXTURE_FILTER,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'texture_filter'
  },
  {
    key: KEY_USE_INTEGER_SCALING,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'use_integer_scaling'
  },
  {
    key: KEY_SHADERS_ACCURATE_MUL,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'shaders_accurate_mul'
  },
  {
    key: KEY_SPIRV_SHADER_GEN,
    type: SettingType.Boolean,
    defaultValue: true,
    nativeKey: 'spirv_shader_gen'
  },
  {
    key: KEY_DISABLE_SPIRV_OPTIMIZER,
    type: SettingType.Boolean,
    defaultValue: true,
    nativeKey: 'disable_spirv_optimizer'
  },
  {
    key: KEY_USE_SKIP_DUPLICATE_FRAMES,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'use_skip_duplicate_frames'
  },
  {
    key: KEY_USE_FRAME_LIMIT,
    type: SettingType.Boolean,
    defaultValue: true,
    nativeKey: 'use_frame_limit'
  },
  {
    key: KEY_ASYNC_SHADER_COMPILATION,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'async_shader_compilation'
  },
  {
    key: KEY_ASYNC_PRESENTATION,
    type: SettingType.Boolean,
    defaultValue: true,
    nativeKey: 'async_presentation'
  },
  {
    key: KEY_SIMULATE_3DS_GPU_TIMINGS,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'simulate_3ds_gpu_timings'
  },
  {
    key: KEY_LAYOUT_OPTION,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'layout_option'
  },
  {
    key: KEY_PORTRAIT_LAYOUT_OPTION,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'portrait_layout_option'
  },
  {
    key: KEY_SCREEN_GAP,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'screen_gap'
  },
  {
    key: KEY_UPRIGHT_SCREEN,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'upright_screen'
  },
  {
    key: KEY_SECONDARY_DISPLAY_LAYOUT,
    type: SettingType.Number,
    defaultValue: 4,
    nativeKey: 'secondary_display_layout'
  },
  {
    key: KEY_LARGE_SCREEN_PROPORTION,
    type: SettingType.Number,
    defaultValue: 2.25,
    nativeKey: 'large_screen_proportion'
  },
  {
    key: KEY_SMALL_SCREEN_POSITION,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'small_screen_position'
  },
  {
    key: KEY_ASPECT_RATIO,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'aspect_ratio'
  },
  {
    key: KEY_PERFORMANCE_OVERLAY_ENABLE,
    type: SettingType.Boolean,
    defaultValue: false
  },
  {
    key: KEY_PERFORMANCE_OVERLAY_POSITION,
    type: SettingType.Number,
    defaultValue: 0
  },
  {
    // 忽略安全区域
    key: KEY_IGNORE_SAFE_AREA,
    type: SettingType.Boolean,
    defaultValue: false
  },
  {
    // 屏幕方向：auto=自动 portrait=竖屏 landscape=横屏
    key: KEY_SCREEN_ORIENTATION,
    type: SettingType.String,
    defaultValue: 'auto'
  },
  {
    // 游戏时锁定亮度
    key: KEY_LOCK_GAME_BRIGHTNESS,
    type: SettingType.Boolean,
    defaultValue: true
  },
  {
    key: KEY_DISABLE_GESTURE_BACK_IN_GAME,
    type: SettingType.Boolean,
    defaultValue: false
  },
  {
    key: KEY_PRIVACY_MODE_IN_GAME,
    type: SettingType.Boolean,
    defaultValue: false
  },
  {
    key: KEY_SCREEN_TOP_STRETCH,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'screen_top_stretch'
  },
  {
    key: KEY_SCREEN_TOP_LEFTRIGHT_PADDING,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'screen_top_leftright_padding'
  },
  {
    key: KEY_SCREEN_TOP_TOPBOTTOM_PADDING,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'screen_top_topbottom_padding'
  },
  {
    key: KEY_SCREEN_BOTTOM_STRETCH,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'screen_bottom_stretch'
  },
  {
    key: KEY_SCREEN_BOTTOM_LEFTRIGHT_PADDING,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'screen_bottom_leftright_padding'
  },
  {
    key: KEY_SCREEN_BOTTOM_TOPBOTTOM_PADDING,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'screen_bottom_topbottom_padding'
  },
  {
    key: KEY_AUDIO_EMULATION,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'audio_emulation'
  },
  {
    // 音频输入类型：1=无 2=静态噪声 6=设备麦克风 7=吹气模拟(OHOS)；默认吹气模拟(对齐 nds)
    key: KEY_AUDIO_INPUT_TYPE,
    type: SettingType.Number,
    defaultValue: 7,
    nativeKey: 'input_type'
  },
  {
    key: KEY_ENABLE_AUDIO_STRETCHING,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'enable_audio_stretching'
  },
  {
    key: KEY_ENABLE_REALTIME_AUDIO,
    type: SettingType.Boolean,
    defaultValue: true,
    nativeKey: 'enable_realtime_audio'
  },
  {
    key: KEY_VOLUME,
    type: SettingType.Number,
    defaultValue: 1,
    nativeKey: 'volume'
  },
  {
    key: KEY_SIMULATE_HEADPHONES_PLUGGED,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'simulate_headphones_plugged'
  },
  {
    key: KEY_BGM_ENABLED,
    type: SettingType.Boolean,
    defaultValue: true
  },
  {
    key: KEY_BGM_VOLUME,
    type: SettingType.Number,
    defaultValue: 20
  },
  {
    key: KEY_SFX_ENABLED,
    type: SettingType.Boolean,
    defaultValue: true
  },
  {
    key: KEY_SFX_VOLUME,
    type: SettingType.Number,
    defaultValue: 30
  },
  {
    key: KEY_IS_NEW_3DS,
    type: SettingType.Boolean,
    defaultValue: true,
    nativeKey: 'is_new_3ds'
  },
  {
    key: KEY_GAME_PERF_HACKS,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'game_perf_hacks'
  },
  {
    key: KEY_LLE_APPLETS,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'lle_applets'
  },
  {
    key: KEY_ENABLE_REQUIRED_ONLINE_LLE_MODULES,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'enable_required_online_lle_modules'
  },
  {
    key: KEY_REGION_VALUE,
    type: SettingType.Number,
    defaultValue: -1,
    nativeKey: 'region_value'
  },
  {
    key: KEY_INIT_CLOCK,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'init_clock'
  },
  {
    key: KEY_INIT_TIME,
    type: SettingType.Number,
    defaultValue: 946731601,
    nativeKey: 'init_time'
  },
  {
    key: KEY_INIT_TIME_OFFSET,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'init_time_offset'
  },
  {
    key: KEY_INIT_TICKS_TYPE,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'init_ticks_type'
  },
  {
    key: KEY_INIT_TICKS_OVERRIDE,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'init_ticks_override'
  },
  {
    key: KEY_STEPS_PER_HOUR,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'steps_per_hour'
  },
  {
    key: KEY_APPLY_REGION_FREE_PATCH,
    type: SettingType.Boolean,
    defaultValue: true,
    nativeKey: 'apply_region_free_patch'
  },
  {
    key: KEY_PLUGIN_LOADER,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'plugin_loader'
  },
  {
    key: KEY_ALLOW_PLUGIN_LOADER,
    type: SettingType.Boolean,
    defaultValue: true,
    nativeKey: 'allow_plugin_loader'
  },
  {
    key: KEY_USE_VIRTUAL_SD,
    type: SettingType.Boolean,
    defaultValue: true,
    nativeKey: 'use_virtual_sd'
  },
  {
    key: KEY_COMPRESS_CIA_INSTALLS,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'compress_cia_installs'
  },
  {
    key: KEY_ASYNC_FS_OPERATIONS,
    type: SettingType.Boolean,
    defaultValue: true,
    nativeKey: 'async_fs_operations'
  },
  {
    // 与 Android STEREOSCOPIC_3D_MODE 默认值一致（SideBySideFull）；实际是否立体由 render_3d_which_display 控制
    key: KEY_RENDER_3D,
    type: SettingType.Number,
    defaultValue: 2,
    nativeKey: 'render_3d'
  },
  {
    key: KEY_RENDER_3D_WHICH_DISPLAY,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'render_3d_which_display'
  },
  {
    key: KEY_MONO_RENDER_OPTION,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'mono_render_option'
  },
  {
    key: KEY_FACTOR_3D,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'factor_3d'
  },
  {
    key: KEY_SWAP_EYES_3D,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'swap_eyes_3d'
  },
  {
    key: KEY_DISABLE_RIGHT_EYE_RENDER,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'disable_right_eye_render'
  },
  {
    key: KEY_CARDBOARD_SCREEN_SIZE,
    type: SettingType.Number,
    defaultValue: 85,
    nativeKey: 'cardboard_screen_size'
  },
  {
    key: KEY_CARDBOARD_X_SHIFT,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'cardboard_x_shift'
  },
  {
    key: KEY_CARDBOARD_Y_SHIFT,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'cardboard_y_shift'
  },
  {
    key: KEY_DUMP_TEXTURES,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'dump_textures'
  },
  {
    key: KEY_CUSTOM_TEXTURES,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'custom_textures'
  },
  {
    key: KEY_PRELOAD_TEXTURES,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'preload_textures'
  },
  {
    key: KEY_ASYNC_CUSTOM_LOADING,
    type: SettingType.Boolean,
    defaultValue: true,
    nativeKey: 'async_custom_loading'
  },
  {
    key: KEY_RENDERER_DEBUG,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'renderer_debug'
  },
  {
    key: KEY_DEBUG_LOG,
    type: SettingType.Boolean,
    defaultValue: false,
    // native 侧一个开关驱动两个上游字段（instant_debug_log / record_frame_times）
    nativeKey: 'debug_log'
  },
  {
    key: KEY_DETERMINISTIC_ASYNC_OPERATIONS,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'deterministic_async_operations'
  },
  {
    key: KEY_TOGGLE_UNIQUE_DATA_CONSOLE_TYPE,
    type: SettingType.Boolean,
    defaultValue: false,
    nativeKey: 'toggle_unique_data_console_type'
  },
  {
    key: KEY_DELAY_START_FOR_LLE_MODULES,
    type: SettingType.Boolean,
    defaultValue: true,
    nativeKey: 'delay_start_for_lle_modules'
  },
  {
    key: KEY_FILTER_MODE,
    type: SettingType.Boolean,
    defaultValue: true,
    nativeKey: 'filter_mode'
  },
  {
    key: KEY_PP_SHADER_NAME,
    type: SettingType.String,
    defaultValue: 'None (builtin)',
    nativeKey: 'pp_shader_name'
  },
  {
    key: KEY_ANAGLYPH_SHADER_NAME,
    type: SettingType.String,
    defaultValue: 'Dubois (builtin)',
    nativeKey: 'anaglyph_shader_name'
  },
  {
    key: KEY_CAMERA_OUTER_RIGHT_NAME,
    type: SettingType.String,
    defaultValue: 'ohos',
    nativeKey: 'camera_outer_right_name'
  },
  {
    key: KEY_CAMERA_OUTER_RIGHT_CONFIG,
    type: SettingType.String,
    defaultValue: '_back',
    nativeKey: 'camera_outer_right_config'
  },
  {
    key: KEY_CAMERA_OUTER_RIGHT_FLIP,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'camera_outer_right_flip'
  },
  {
    key: KEY_CAMERA_INNER_NAME,
    type: SettingType.String,
    defaultValue: 'ohos',
    nativeKey: 'camera_inner_name'
  },
  {
    key: KEY_CAMERA_INNER_CONFIG,
    type: SettingType.String,
    defaultValue: '_front',
    nativeKey: 'camera_inner_config'
  },
  {
    key: KEY_CAMERA_INNER_FLIP,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'camera_inner_flip'
  },
  {
    key: KEY_CAMERA_OUTER_LEFT_NAME,
    type: SettingType.String,
    defaultValue: 'ohos',
    nativeKey: 'camera_outer_left_name'
  },
  {
    key: KEY_CAMERA_OUTER_LEFT_CONFIG,
    type: SettingType.String,
    defaultValue: '_back',
    nativeKey: 'camera_outer_left_config'
  },
  {
    key: KEY_CAMERA_OUTER_LEFT_FLIP,
    type: SettingType.Number,
    defaultValue: 0,
    nativeKey: 'camera_outer_left_flip'
  },
  {
    key: KEY_WEB_API_URL,
    type: SettingType.String,
    defaultValue: 'https://api.citra-emu.org',
    nativeKey: 'web_api_url'
  },
  {
    key: KEY_CITRA_TOKEN,
    type: SettingType.String,
    defaultValue: '',
    nativeKey: 'citra_token'
  },
  {
    key: KEY_INSERTED_CARTRIDGE,
    type: SettingType.String,
    defaultValue: '',
    nativeKey: 'inserted_cartridge'
  },
  {
    key: KEY_MULTIPLAYER_ROOM_ADDRESS,
    type: SettingType.String,
    defaultValue: ''
  },
  {
    key: KEY_MULTIPLAYER_ROOM_PORT,
    type: SettingType.Number,
    defaultValue: 24872
  },
  {
    key: KEY_MULTIPLAYER_ROOM_PASSWORD,
    type: SettingType.String,
    defaultValue: ''
  },
  {
    key: KEY_MULTIPLAYER_FILTER_TEXT,
    type: SettingType.String,
    defaultValue: ''
  },
  {
    key: KEY_MULTIPLAYER_HIDE_FULL,
    type: SettingType.Boolean,
    defaultValue: false
  },
  {
    key: KEY_MULTIPLAYER_HIDE_EMPTY,
    type: SettingType.Boolean,
    defaultValue: false
  },
  {
    key: KEY_INPUT_HAPTIC_ENABLED,
    type: SettingType.Boolean,
    defaultValue: true
  },
  {
    key: KEY_INPUT_HAPTIC_STRENGTH,
    type: SettingType.Number,
    defaultValue: 70
  },
  {
    key: KEY_SOFT_INPUT_BEHAVIOUR,
    type: SettingType.String,
    defaultValue: 'always_visible'
  },
  {
    key: KEY_CONTROL_OPACITY,
    type: SettingType.Number,
    defaultValue: 70
  },
  {
    key: KEY_GAME_NAME_SOURCE,
    type: SettingType.String,
    defaultValue: 'metadata'
  },
  {
    key: KEY_GAME_LIST_LAYOUT,
    type: SettingType.String,
    defaultValue: 'grid'
  },
  {
    key: KEY_GRID_SIZE,
    type: SettingType.Number,
    defaultValue: 160
  },
  {
    key: KEY_LIST_SIZE,
    type: SettingType.Number,
    defaultValue: 64
  },
  {
    key: KEY_COVER_CORNER_RADIUS,
    type: SettingType.Number,
    defaultValue: 4
  },
  {
    key: KEY_DEFAULT_TAB,
    type: SettingType.Number,
    defaultValue: HomeTab.RECENT
  },
  {
    key: KEY_GAME_LIST_SORT_ASCENDING,
    type: SettingType.Boolean,
    defaultValue: true
  },
  {
    key: GLOBAL_WALLPAPER_URI_KEY,
    type: SettingType.String,
    defaultValue: ''
  },
  {
    // 应用图标样式：''=默认图标，其余为 app.json5 alternateIcons 中声明的 name
    key: KEY_APP_ICON_STYLE,
    type: SettingType.String,
    defaultValue: ''
  },
  {
    // 布局编辑器网格密度：px 间距，0=关闭吸附（无 nativeKey，纯前端编辑器参数）
    key: KEY_LAYOUT_EDITOR_GRID_SIZE,
    type: SettingType.Number,
    defaultValue: DEFAULT_LAYOUT_EDITOR_GRID_SIZE
  },
  {
    // 上次连接的 Artic Base 主机地址（对齐 Android SettingKeys.last_artic_base_addr，纯前端记忆）
    key: KEY_LAST_ARTIC_BASE_ADDR,
    type: SettingType.String,
    defaultValue: ''
  },
  {
    // 手动存档槽位数量（无 nativeKey，纯前端项）：槽 0 固定为快速存/读档，N 个手动槽为 1..N
    key: KEY_SAVE_STATE_SLOT_COUNT,
    type: SettingType.Number,
    defaultValue: DEFAULT_SAVE_STATE_SLOT_COUNT
  }
];

export function getSettingDefinition(key: string): SettingDefinition | undefined {
  for (let i = 0; i < SETTINGS_DEFINITIONS.length; i++) {
    const definition = SETTINGS_DEFINITIONS[i];
    if (definition.key === key) {
      return definition;
    }
  }
  return undefined;
}

export function getSettingDefinitions(): SettingDefinition[] {
  return SETTINGS_DEFINITIONS;
}

export function getDefaultSettingValue(key: string): SettingValue {
  const definition = getSettingDefinition(key);
  return definition ? definition.defaultValue : '';
}
