#include "core/azahar_core_runtime.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdlib>
#include <execinfo.h>
#include <filesystem>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <vector>

#include <hilog/log.h>
#include <accesstoken/ability_access_control.h>

#include "audio_core/input_details.h"
#include "audio_core/dsp_interface.h"
#include "audio_core/sink.h"
#include "audio_core/sink_details.h"
#include "common/file_util.h"
#include "common/logging/backend.h"
#include "common/logging/log.h"
#include "common/settings.h"
#include "core/core.h"
#include "core/frontend/framebuffer_layout.h"
#include "core/frontend/applets/default_applets.h"
#include "core/hle/service/service.h"
#include "core/loader/loader.h"
#include "core/movie.h"
#include "core/savestate.h"
#include "camera/ohos_camera.h"
#include "camera/ohos_still_image_camera.h"
#include "core/frontend/camera/factory.h"
#include "graphics/ohos_emu_window.h"
#include "input/ohos_input.h"
#include "network/network.h"
#include "network/network.h"
#include "video_core/debug_utils/debug_utils.h"
#include "video_core/gpu.h"
#include "video_core/renderer_base.h"
#include "video_core/renderer_vulkan/vk_platform.h"

#include <lodepng.h>

namespace Azahar::Ohos {
namespace {

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3203
#define LOG_TAG "Azahar_OHOS"
#define AZ_RT_LOGI(fmt, ...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)
#define AZ_RT_LOGW(fmt, ...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)
#define AZ_RT_LOGE(fmt, ...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)

std::once_flag fatal_signal_logger_once;

void FatalSignalHandler(int signal, siginfo_t* info, void*) {
    static volatile sig_atomic_t handling_signal = 0;
    if (handling_signal != 0) {
        std::_Exit(128 + signal);
    }
    handling_signal = 1;

    void* frames[64] {};
    const int frame_count = backtrace(frames, sizeof(frames) / sizeof(frames[0]));
    AZ_RT_LOGE("Azahar fatal signal=%{public}d addr=%{public}p frames=%{public}d", signal,
               info ? info->si_addr : nullptr, frame_count);
    for (int i = 0; i < frame_count; ++i) {
        AZ_RT_LOGE("Azahar fatal bt #%{public}02d pc=%{public}p", i, frames[i]);
    }

    std::signal(signal, SIG_DFL);
    std::raise(signal);
}

void InstallFatalSignalLogger() {
    std::call_once(fatal_signal_logger_once, [] {
        struct sigaction action {};
        action.sa_sigaction = FatalSignalHandler;
        sigemptyset(&action.sa_mask);
        action.sa_flags = SA_SIGINFO | SA_RESETHAND;
        sigaction(SIGSEGV, &action, nullptr);
        sigaction(SIGABRT, &action, nullptr);
    });
}

std::string ResultStatusName(Core::System::ResultStatus status) {
    switch (status) {
    case Core::System::ResultStatus::Success:
        return "success";
    case Core::System::ResultStatus::ErrorNotInitialized:
        return "error_not_initialized";
    case Core::System::ResultStatus::ErrorGetLoader:
        return "error_get_loader";
    case Core::System::ResultStatus::ErrorSystemMode:
        return "error_system_mode";
    case Core::System::ResultStatus::ErrorLoader:
        return "error_loader";
    case Core::System::ResultStatus::ErrorLoader_ErrorEncrypted:
        return "error_loader_encrypted";
    case Core::System::ResultStatus::ErrorLoader_ErrorInvalidFormat:
        return "error_loader_invalid_format";
    case Core::System::ResultStatus::ErrorLoader_ErrorGbaTitle:
        return "error_loader_gba_title";
    case Core::System::ResultStatus::ErrorLoader_ErrorPatches:
        return "error_loader_patches";
    case Core::System::ResultStatus::ErrorLoader_ErrorPatchesInvalidTitle:
        return "error_loader_patches_invalid_title";
    case Core::System::ResultStatus::ErrorSystemFiles:
        return "error_system_files";
    case Core::System::ResultStatus::ErrorSavestate:
        return "error_savestate";
    case Core::System::ResultStatus::ErrorArticDisconnected:
        return "error_artic_disconnected";
    case Core::System::ResultStatus::ErrorN3DSApplication:
        return "error_n3ds_application";
    case Core::System::ResultStatus::ErrorCoreExceptionRaised:
        return "error_core_exception";
    case Core::System::ResultStatus::ErrorSavestateBuildMismatch:
        return "error_savestate_build_mismatch";
    case Core::System::ResultStatus::ErrorShaderCacheCrash:
        return "error_shader_cache_crash";
    case Core::System::ResultStatus::ShutdownRequested:
        return "shutdown_requested";
    case Core::System::ResultStatus::ErrorUnknown:
        return "error_unknown";
    }
    return "error_unknown";
}

std::string WithTrailingSlash(std::string path) {
    if (!path.empty() && path.back() != '/') {
        path.push_back('/');
    }
    return path;
}

void EnsureUserDirectories() {
    constexpr std::array runtime_paths{
        FileUtil::UserPath::CacheDir,  FileUtil::UserPath::SDMCDir,
        FileUtil::UserPath::NANDDir,   FileUtil::UserPath::SysDataDir,
        FileUtil::UserPath::CheatsDir, FileUtil::UserPath::ShaderDir,  FileUtil::UserPath::StatesDir,
    };

    for (const FileUtil::UserPath path : runtime_paths) {
        const std::string& directory = FileUtil::GetUserPath(path);
        if (!FileUtil::CreateFullPath(directory)) {
            LOG_WARNING(Core, "Failed to create OHOS runtime directory: {}", directory);
        }
    }

    LOG_INFO(Core, "OHOS runtime paths: user={}, cache={}, sdmc={}, nand={}, states={}",
             FileUtil::GetUserPath(FileUtil::UserPath::UserDir),
             FileUtil::GetUserPath(FileUtil::UserPath::CacheDir),
             FileUtil::GetUserPath(FileUtil::UserPath::SDMCDir),
             FileUtil::GetUserPath(FileUtil::UserPath::NANDDir),
             FileUtil::GetUserPath(FileUtil::UserPath::StatesDir));
}

bool EnsureParentDirectory(const std::string& path) {
    const std::size_t slash = path.find_last_of("/\\");
    if (slash == std::string::npos) {
        return true;
    }
    return FileUtil::CreateFullPath(path.substr(0, slash + 1));
}

bool SaveScreenshotPng(const std::string& path, const std::vector<u8>& bgra, u32 width, u32 height,
                       bool invert_y) {
    if (path.empty() || width == 0 || height == 0 || bgra.size() < width * height * 4ull) {
        return false;
    }
    if (!EnsureParentDirectory(path)) {
        LOG_ERROR(Frontend, "Failed to create screenshot directory for \"{}\"", path);
        return false;
    }

    std::vector<u8> rgba(width * height * 4ull);
    for (u32 y = 0; y < height; ++y) {
        const u32 source_y = invert_y ? (height - 1 - y) : y;
        for (u32 x = 0; x < width; ++x) {
            const std::size_t source = (static_cast<std::size_t>(source_y) * width + x) * 4;
            const std::size_t dest = (static_cast<std::size_t>(y) * width + x) * 4;
            rgba[dest] = bgra[source + 2];
            rgba[dest + 1] = bgra[source + 1];
            rgba[dest + 2] = bgra[source];
            rgba[dest + 3] = 255;
        }
    }

    std::vector<u8> encoded;
    const u32 encode_status = lodepng::encode(encoded, rgba.data(), width, height);
    if (encode_status != 0) {
        LOG_ERROR(Frontend, "Failed to encode screenshot \"{}\": {}", path,
                  lodepng_error_text(encode_status));
        return false;
    }

    FileUtil::IOFile file(path, "wb");
    if (!file.IsOpen() || file.WriteBytes(encoded.data(), encoded.size()) != encoded.size()) {
        LOG_ERROR(Frontend, "Failed to save screenshot to \"{}\"", path);
        return false;
    }

    LOG_INFO(Frontend, "Screenshot saved to \"{}\"", path);
    return true;
}

bool ConfigBool(const std::unordered_map<std::string, ConfigValue>& config,
                const std::string& key, bool fallback) {
    const auto it = config.find(key);
    if (it == config.end() || !std::holds_alternative<bool>(it->second)) {
        return fallback;
    }
    return std::get<bool>(it->second);
}

double ConfigNumber(const std::unordered_map<std::string, ConfigValue>& config,
                    const std::string& key, double fallback) {
    const auto it = config.find(key);
    if (it == config.end() || !std::holds_alternative<double>(it->second)) {
        return fallback;
    }
    return std::get<double>(it->second);
}

std::string ConfigString(const std::unordered_map<std::string, ConfigValue>& config,
                         const std::string& key, const std::string& fallback) {
    const auto it = config.find(key);
    if (it == config.end() || !std::holds_alternative<std::string>(it->second)) {
        return fallback;
    }
    return std::get<std::string>(it->second);
}

template <typename T>
T ClampedEnum(double value, int min_value, int max_value) {
    const auto rounded = static_cast<int>(std::lround(value));
    return static_cast<T>(std::clamp(rounded, min_value, max_value));
}

void ApplyRuntimePaths(const std::string& files_dir, const std::string& cache_dir,
                       const std::string& user_dir) {
    if (!files_dir.empty()) {
        FileUtil::SetCurrentDir(files_dir);
    }

    if (user_dir.empty()) {
        return;
    }

    FileUtil::SetUserPath(WithTrailingSlash(user_dir));

    if (!cache_dir.empty()) {
        FileUtil::UpdateUserPath(FileUtil::UserPath::CacheDir, WithTrailingSlash(cache_dir));
        // shader 缓存属临时数据，锚定到应用沙箱而非用户可见目录。
        // UpdateUserPath 要求目标已存在，须先创建否则静默拒绝重定向。
        const std::string shader_dir = WithTrailingSlash(cache_dir) + "shaders/";
        FileUtil::CreateFullPath(shader_dir);
        FileUtil::UpdateUserPath(FileUtil::UserPath::ShaderDir, shader_dir);
    }

    if (!files_dir.empty()) {
        // sysdata 是系统托管的持久数据，归入私有目录不对用户暴露（同上须先创建）。
        const std::string sysdata_dir = WithTrailingSlash(files_dir) + "sysdata/";
        FileUtil::CreateFullPath(sysdata_dir);
        FileUtil::UpdateUserPath(FileUtil::UserPath::SysDataDir, sysdata_dir);
    }

    EnsureUserDirectories();
}

void ApplySettingsFromConfig(const std::unordered_map<std::string, ConfigValue>& config) {
    Settings::values.use_cpu_jit = ConfigBool(config, "use_cpu_jit", false);
    // cpu_core_mode 是唯一的 CPU 后端设置项：0=JIT 1=快速解释器
    // 3=普通解释器(DynCom)；其余取值（含已废弃的 2=IR 解释器、-1 未选择的老配置）
    // 一律回退到默认快速解释器。
    const int cpu_core_mode =
        static_cast<int>(std::lround(ConfigNumber(config, "cpu_core_mode", -1.0)));
    if (cpu_core_mode == 0 || cpu_core_mode == 1 || cpu_core_mode == 3) {
        Settings::values.use_fastinterp = cpu_core_mode == 1;
    } else {
        Settings::values.use_fastinterp = ConfigBool(config, "use_fastinterp", true);
    }
    // Benchmark escape hatch: `cpu_backend` is never a registered setting, so it
    // survives syncNativeSettings() and wins over the individual flags.
    // `--ps cpuBackend dyncom|fastinterp|jit`
    const std::string cpu_backend = ConfigString(config, "cpu_backend", "");
    if (!cpu_backend.empty()) {
        Settings::values.use_fastinterp = cpu_backend == "fastinterp";
        Settings::values.use_cpu_jit = cpu_backend == "jit";
    }
    Settings::values.cpu_clock_percentage =
        static_cast<s32>(std::lround(ConfigNumber(config, "cpu_clock_percentage", 100.0)));
    Settings::values.enable_rpc_server = ConfigBool(config, "enable_rpc_server", false);
    Settings::values.use_artic_base_controller =
        ConfigBool(config, "use_artic_base_controller", false);
    const auto graphics_api =
        ClampedEnum<Settings::GraphicsAPI>(ConfigNumber(config, "graphics_api", 2.0), 0, 2);
    Settings::values.graphics_api = graphics_api;
    Settings::values.use_gles = graphics_api == Settings::GraphicsAPI::OpenGL;
    Settings::values.use_hw_shader = ConfigBool(config, "use_hw_shader", true);
    Settings::values.use_hw_geometry_cache = ConfigBool(config, "use_hw_geometry_cache", true);
    Settings::values.use_shader_jit = ConfigBool(config, "use_shader_jit", true);
    Settings::values.use_disk_shader_cache = ConfigBool(config, "use_disk_shader_cache", true);
    Settings::values.use_vsync = ConfigBool(config, "use_vsync", false);
    Settings::values.use_integer_scaling = ConfigBool(config, "use_integer_scaling", false);
    Settings::values.shaders_accurate_mul = ConfigBool(config, "shaders_accurate_mul", false);
    Settings::values.spirv_shader_gen = ConfigBool(config, "spirv_shader_gen", true);
    Settings::values.disable_spirv_optimizer =
        ConfigBool(config, "disable_spirv_optimizer", true);
    Settings::values.async_shader_compilation =
        ConfigBool(config, "async_shader_compilation", false);
    Settings::values.async_presentation = ConfigBool(config, "async_presentation", true);
    Settings::values.simulate_3ds_gpu_timings =
        ConfigBool(config, "simulate_3ds_gpu_timings", false);
    Settings::values.use_skip_duplicate_frames =
        ConfigBool(config, "use_skip_duplicate_frames", false);
    // 倍率钳制在 1~4（4x 已覆盖平板横屏并排 ~2.8K，更高倍率纯超采样、鸿蒙设备性能不划算）；
    // 旧配置残留的 0（已移除的自动项）归为 1x，5~8 归为 4x
    const double resolution_factor = ConfigNumber(config, "resolution_factor", 1.0);
    Settings::values.resolution_factor =
        static_cast<u32>(std::clamp(resolution_factor, 1.0, 4.0));
    const bool use_frame_limit = ConfigBool(config, "use_frame_limit", true);
    Settings::values.frame_limit =
        use_frame_limit ? ConfigNumber(config, "frame_limit", 100.0) : 0.0;
    Settings::values.turbo_limit = ConfigNumber(config, "turbo_limit", 200.0);
    Settings::values.texture_filter =
        ClampedEnum<Settings::TextureFilter>(ConfigNumber(config, "texture_filter", 0.0), 0, 5);
    Settings::values.texture_sampling =
        ClampedEnum<Settings::TextureSampling>(ConfigNumber(config, "texture_sampling", 0.0), 0,
                                               2);
    Settings::values.delay_game_render_thread_us = static_cast<u16>(std::clamp(
        std::lround(ConfigNumber(config, "delay_game_render_thread_us", 0.0)), 0L, 65000L));
    constexpr int max_layout_option = static_cast<int>(Settings::LayoutOption::CustomLayout);
    Settings::values.layout_option =
        ClampedEnum<Settings::LayoutOption>(ConfigNumber(config, "layout_option", 0.0), 0,
                                            max_layout_option);
    Settings::values.portrait_layout_option = ClampedEnum<Settings::PortraitLayoutOption>(
        ConfigNumber(config, "portrait_layout_option", 0.0), 0, 2);
    Settings::values.screen_gap =
        static_cast<int>(std::lround(ConfigNumber(config, "screen_gap", 0.0)));
    Settings::values.swap_screen = ConfigBool(config, "swap_screen", false);
    Settings::values.upright_screen = ConfigBool(config, "upright_screen", false);
    Settings::values.secondary_display_layout = ClampedEnum<Settings::SecondaryDisplayLayout>(
        ConfigNumber(config, "secondary_display_layout", 4.0), 0, 7);
    Settings::values.large_screen_proportion =
        static_cast<float>(std::clamp(ConfigNumber(config, "large_screen_proportion", 2.25), 1.0,
                                      16.0));
    Settings::values.small_screen_position = ClampedEnum<Settings::SmallScreenPosition>(
        ConfigNumber(config, "small_screen_position", 0.0), 0, 7);
    Settings::values.aspect_ratio =
        ClampedEnum<Settings::AspectRatio>(ConfigNumber(config, "aspect_ratio", 0.0), 0, 5);
    Settings::values.screen_top_stretch = ConfigBool(config, "screen_top_stretch", false);
    Settings::values.screen_top_leftright_padding = static_cast<u16>(std::clamp(
        std::lround(ConfigNumber(config, "screen_top_leftright_padding", 0.0)), 0L, 1000L));
    Settings::values.screen_top_topbottom_padding = static_cast<u16>(std::clamp(
        std::lround(ConfigNumber(config, "screen_top_topbottom_padding", 0.0)), 0L, 1000L));
    Settings::values.screen_bottom_stretch = ConfigBool(config, "screen_bottom_stretch", false);
    Settings::values.screen_bottom_leftright_padding = static_cast<u16>(std::clamp(
        std::lround(ConfigNumber(config, "screen_bottom_leftright_padding", 0.0)), 0L, 1000L));
    Settings::values.screen_bottom_topbottom_padding = static_cast<u16>(std::clamp(
        std::lround(ConfigNumber(config, "screen_bottom_topbottom_padding", 0.0)), 0L, 1000L));

    Settings::values.render_3d =
        ClampedEnum<Settings::StereoRenderOption>(ConfigNumber(config, "render_3d", 2.0), 0, 6);
    Settings::values.render_3d_which_display = ClampedEnum<Settings::StereoWhichDisplay>(
        ConfigNumber(config, "render_3d_which_display", 0.0), 0, 3);
    Settings::values.mono_render_option =
        ClampedEnum<Settings::MonoRenderOption>(ConfigNumber(config, "mono_render_option", 0.0),
                                                0, 1);
    Settings::values.factor_3d =
        static_cast<u32>(std::clamp(std::lround(ConfigNumber(config, "factor_3d", 0.0)), 0L,
                                    255L));
    Settings::values.swap_eyes_3d = ConfigBool(config, "swap_eyes_3d", false);
    Settings::values.disable_right_eye_render =
        ConfigBool(config, "disable_right_eye_render", false);
    Settings::values.cardboard_screen_size = static_cast<u32>(std::clamp(
        std::lround(ConfigNumber(config, "cardboard_screen_size", 85.0)), 30L, 100L));
    Settings::values.cardboard_x_shift = static_cast<s32>(std::clamp(
        std::lround(ConfigNumber(config, "cardboard_x_shift", 0.0)), -100L, 100L));
    Settings::values.cardboard_y_shift = static_cast<s32>(std::clamp(
        std::lround(ConfigNumber(config, "cardboard_y_shift", 0.0)), -100L, 100L));

    Settings::values.audio_emulation =
        ClampedEnum<Settings::AudioEmulation>(ConfigNumber(config, "audio_emulation", 0.0), 0, 2);
    Settings::values.enable_audio_stretching =
        ConfigBool(config, "enable_audio_stretching", false);
    Settings::values.enable_realtime_audio = ConfigBool(config, "enable_realtime_audio", true);
    Settings::values.simulate_headphones_plugged =
        ConfigBool(config, "simulate_headphones_plugged", false);
    Settings::values.volume =
        static_cast<float>(std::clamp(ConfigNumber(config, "volume", 1.0), 0.0, 1.0));
    Settings::values.input_type =
        ClampedEnum<AudioCore::InputType>(ConfigNumber(config, "input_type", 0.0), 0, 7);
#ifdef HAVE_OHOS_AUDIO
    Settings::values.output_type = AudioCore::SinkType::Ohos;
    Settings::values.output_device = AudioCore::auto_device_name;
#endif

    Settings::values.is_new_3ds = ConfigBool(config, "is_new_3ds", true);
    Settings::values.game_perf_hacks = ConfigBool(config, "game_perf_hacks", false);
    Settings::values.lle_applets = ConfigBool(config, "lle_applets", false);
    Settings::values.enable_required_online_lle_modules =
        ConfigBool(config, "enable_required_online_lle_modules", false);
    Settings::values.lle_modules.clear();
    for (const auto& service_module : Service::service_module_map) {
        Settings::values.lle_modules.emplace(service_module.name, false);
    }
    Settings::values.region_value =
        static_cast<s32>(std::lround(ConfigNumber(config, "region_value",
                                                 Settings::REGION_VALUE_AUTO_SELECT)));
    Settings::values.init_clock =
        ClampedEnum<Settings::InitClock>(ConfigNumber(config, "init_clock", 0.0), 0, 1);
    Settings::values.init_time =
        static_cast<u64>(std::max(0.0, ConfigNumber(config, "init_time", 946731601.0)));
    Settings::values.init_time_offset =
        static_cast<s64>(std::lround(ConfigNumber(config, "init_time_offset", 0.0)));
    Settings::values.init_ticks_type =
        ClampedEnum<Settings::InitTicks>(ConfigNumber(config, "init_ticks_type", 0.0), 0, 1);
    Settings::values.init_ticks_override =
        static_cast<s64>(std::lround(ConfigNumber(config, "init_ticks_override", 0.0)));
    Settings::values.steps_per_hour = static_cast<u16>(std::clamp(
        std::lround(ConfigNumber(config, "steps_per_hour", 0.0)), 0L, 65535L));
    Settings::values.apply_region_free_patch =
        ConfigBool(config, "apply_region_free_patch", true);
    Settings::values.plugin_loader_enabled = ConfigBool(config, "plugin_loader", false);
    Settings::values.allow_plugin_loader = ConfigBool(config, "allow_plugin_loader", true);
    Settings::values.use_virtual_sd = ConfigBool(config, "use_virtual_sd", true);
    Settings::values.compress_cia_installs = ConfigBool(config, "compress_cia_installs", false);
    Settings::values.async_fs_operations = ConfigBool(config, "async_fs_operations", true);
    Settings::values.dump_textures = ConfigBool(config, "dump_textures", false);
    Settings::values.custom_textures = ConfigBool(config, "custom_textures", false);
    Settings::values.preload_textures = ConfigBool(config, "preload_textures", false);
    Settings::values.async_custom_loading = ConfigBool(config, "async_custom_loading", true);
    Settings::values.renderer_debug = ConfigBool(config, "renderer_debug", false);
    // debug_log 同时驱动：文件日志逐条即时落盘（instant_debug_log → backend.cpp:356）
    // 和会话结束导出帧时间 CSV（record_frame_times → perf_stats.cpp:37）
    const bool debug_log = ConfigBool(config, "debug_log", false);
    Settings::values.instant_debug_log = debug_log;
    Settings::values.record_frame_times = debug_log;
    Settings::values.deterministic_async_operations =
        ConfigBool(config, "deterministic_async_operations", false);
    Settings::values.toggle_unique_data_console_type =
        ConfigBool(config, "toggle_unique_data_console_type", false);
    Settings::values.delay_start_for_lle_modules =
        ConfigBool(config, "delay_start_for_lle_modules", true);
    Settings::values.filter_mode = ConfigBool(config, "filter_mode", true);
    Settings::values.pp_shader_name = ConfigString(config, "pp_shader_name", "None (builtin)");
    Settings::values.anaglyph_shader_name =
        ConfigString(config, "anaglyph_shader_name", "Dubois (builtin)");

    using namespace Service::CAM;
    Settings::values.camera_name[OuterRightCamera] =
        ConfigString(config, "camera_outer_right_name", "ohos");
    Settings::values.camera_config[OuterRightCamera] =
        ConfigString(config, "camera_outer_right_config", "_back");
    Settings::values.camera_flip[OuterRightCamera] =
        static_cast<int>(std::clamp(std::lround(ConfigNumber(config, "camera_outer_right_flip", 0.0)),
                                    0L, 3L));
    Settings::values.camera_name[InnerCamera] = ConfigString(config, "camera_inner_name", "ohos");
    Settings::values.camera_config[InnerCamera] =
        ConfigString(config, "camera_inner_config", "_front");
    Settings::values.camera_flip[InnerCamera] =
        static_cast<int>(std::clamp(std::lround(ConfigNumber(config, "camera_inner_flip", 0.0)), 0L,
                                    3L));
    Settings::values.camera_name[OuterLeftCamera] =
        ConfigString(config, "camera_outer_left_name", "ohos");
    Settings::values.camera_config[OuterLeftCamera] =
        ConfigString(config, "camera_outer_left_config", "_back");
    Settings::values.camera_flip[OuterLeftCamera] =
        static_cast<int>(std::clamp(std::lround(ConfigNumber(config, "camera_outer_left_flip", 0.0)),
                                    0L, 3L));

    Settings::values.web_api_url =
        ConfigString(config, "web_api_url", "https://api.citra-emu.org");
    Settings::values.network_token = ConfigString(config, "citra_token", "");
}

} // namespace

// 前置声明：撤销覆盖备份随会话清理，实现在存档区块（SaveState 附近）
static void ClearUndoBackup();

AzaharCoreRuntime::AzaharCoreRuntime() = default;

AzaharCoreRuntime::~AzaharCoreRuntime() {
    Stop();
}

bool AzaharCoreRuntime::Start(std::string filepath, OHNativeWindow* native_window, int width,
                              int height, std::unordered_map<std::string, ConfigValue> config,
                              std::string files_dir, std::string cache_dir, std::string user_dir) {
    InstallFatalSignalLogger();

    if (running_) {
        return false;
    }
    if (emu_thread_.joinable()) {
        emu_thread_.join();
    }
    if (!native_window) {
        SetStatus("azahar_core_no_surface");
        return false;
    }

    stop_requested_ = false;
    pause_requested_ = false;
    pause_frame_requested_ = false;
    screenshot_in_progress_ = false;
    // 撤销备份绑定上一会话的存档文件，新游戏会话一律丢弃（对齐 nds 换 ROM 清空）
    ClearUndoBackup();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        startup_reported_ = false;
        startup_ok_ = false;
        status_ = "azahar_core_starting";
    }

    emu_thread_ = std::thread(&AzaharCoreRuntime::Run, this, std::move(filepath), native_window,
                              width, height, std::move(config), std::move(files_dir),
                              std::move(cache_dir), std::move(user_dir));

    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait(lock, [this] { return startup_reported_; });
    const bool ok = startup_ok_;
    lock.unlock();

    if (!ok && emu_thread_.joinable()) {
        emu_thread_.join();
    }
    return ok;
}

bool AzaharCoreRuntime::Pause() {
    if (!running_) {
        return false;
    }
    auto& system = Core::System::GetInstance();
    if (system.IsPoweredOn()) {
        system.DSP().PauseAudio();
    }
    pause_requested_ = true;
    SetStatus("azahar_core_paused");
    return true;
}

bool AzaharCoreRuntime::Resume() {
    if (!running_) {
        return false;
    }
    auto& system = Core::System::GetInstance();
    if (system.IsPoweredOn()) {
        // The core run loop is suspended while paused, so the next measured frame interval would
        // otherwise include the entire pause duration and distort realtime audio scheduling.
        system.ResetPerfStatsFrameTimeBaseline();
        system.DSP().ResumeAudio();
    }
    pause_requested_ = false;
    pause_frame_requested_ = false;
    cv_.notify_all();
    SetStatus("azahar_core_running");
    return true;
}

bool AzaharCoreRuntime::Stop() {
    stop_requested_ = true;
    pause_requested_ = false;
    pause_frame_requested_ = false;
    Input::ReleaseAll();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (window_) {
            window_->StopPresenting();
        }
    }
    cv_.notify_all();

    if (emu_thread_.joinable()) {
        emu_thread_.join();
    }
    screenshot_in_progress_ = false;
    running_ = false;
    ClearUndoBackup();
    SetStatus("azahar_core_stopped");
    return true;
}

bool AzaharCoreRuntime::Reset() {
    if (!running_ || !Core::System::GetInstance().IsPoweredOn()) {
        return false;
    }
    Core::System::GetInstance().RequestReset();
    SetStatus("azahar_core_reset_requested");
    return true;
}

// 与 Core::GetSaveStatePath 的 .cst 命名同源推导截图路径（对齐 nds 的同名 .bmp 方案）
static std::string SaveStateScreenshotPath(const std::string& state_path) {
    return state_path.substr(0, state_path.size() - std::string(".cst").size()) + ".png";
}

// 即时存档覆盖撤销（对齐 nds SaveStateUndoBackup / RetroArch undo_save_buf）：
// 本会话最近一次成功覆盖前的旧档与截图只留底在内存，不落盘、不跨会话；
// 新一次覆盖写档会替换旧备份，游戏 Start/Stop 时清空。
struct SaveStateUndoBackup {
    // -1 表示无有效备份
    int32_t slot = -1;
    std::string state_path;
    std::string state_data;
    std::string screenshot_path;
    std::string screenshot_data;
    bool screenshot_state_known = false;
    bool screenshot_existed = false;
};

static SaveStateUndoBackup g_undo_backup;
static std::mutex g_undo_backup_mutex;

static void ClearUndoBackup() {
    std::lock_guard<std::mutex> lock(g_undo_backup_mutex);
    g_undo_backup = SaveStateUndoBackup{};
}

// 备份与槽位按 state_path 绑定：movie id 变化/重载 ROM 后路径解析不同即视为不可撤销
static bool UndoBackupMatches(const std::string& state_path, int32_t slot) {
    std::lock_guard<std::mutex> lock(g_undo_backup_mutex);
    return g_undo_backup.slot == slot && g_undo_backup.state_path == state_path
        && !g_undo_backup.state_data.empty();
}

// 把留底写回磁盘：.cst 必须恢复成功；截图失败只告警。
// 旧档当时没有截图时，删掉覆盖操作生成的新截图避免张冠李戴（对齐 nds）
static bool WriteUndoBackup(const SaveStateUndoBackup& backup) {
    if (backup.state_path.empty() || backup.state_data.empty()) {
        return false;
    }
    if (FileUtil::WriteStringToFile(false, backup.state_path, backup.state_data)
            != backup.state_data.size()) {
        return false;
    }
    if (backup.screenshot_state_known && !backup.screenshot_path.empty()) {
        if (backup.screenshot_existed) {
            if (FileUtil::WriteStringToFile(false, backup.screenshot_path, backup.screenshot_data)
                    != backup.screenshot_data.size()) {
                AZ_RT_LOGW("UndoBackup: screenshot restore failed for %{public}s",
                           backup.screenshot_path.c_str());
            }
        } else {
            FileUtil::Delete(backup.screenshot_path);
        }
    }
    return true;
}

bool AzaharCoreRuntime::SaveState(int32_t slot) {
    Core::System& system = Core::System::GetInstance();
    if (!running_ || !system.IsPoweredOn() || slot < 0) {
        return false;
    }

    // 先算出目标文件路径，用于检测写入完成和截图命名；读不到 program id（如 homebrew）时无法追踪
    u64 title_id = 0;
    std::string state_path;
    if (system.GetAppLoader().ReadProgramId(title_id) == Loader::ResultStatus::Success) {
        state_path = Core::GetSaveStatePath(title_id, system.Movie().GetCurrentMovieID(),
                                            static_cast<u32>(slot));
    }

    namespace fs = std::filesystem;
    std::error_code ec;
    const fs::file_time_type prev_write =
        (!state_path.empty() && FileUtil::Exists(state_path))
            ? fs::last_write_time(state_path, ec)
            : fs::file_time_type::min();

    // 覆盖前把旧档与截图读进内存留底（对齐 nds）。候选备份仅在新档成功落盘后提交，
    // 保存失败不会挤掉上一条仍可用的撤销记录
    SaveStateUndoBackup candidate;
    const std::string screenshot_path = state_path.empty() ? "" : SaveStateScreenshotPath(state_path);
    if (!state_path.empty() && FileUtil::Exists(state_path)) {
        const std::size_t state_read =
            FileUtil::ReadFileToString(false, state_path, candidate.state_data);
        if (state_read > 0 && state_read == candidate.state_data.size()) {
            candidate.slot = slot;
            candidate.state_path = state_path;
            candidate.screenshot_path = screenshot_path;
            if (FileUtil::Exists(screenshot_path)) {
                const std::size_t shot_read = FileUtil::ReadFileToString(
                    false, screenshot_path, candidate.screenshot_data);
                if (shot_read > 0 && shot_read == candidate.screenshot_data.size()) {
                    candidate.screenshot_state_known = true;
                    candidate.screenshot_existed = true;
                } else {
                    candidate.screenshot_data.clear();
                    AZ_RT_LOGW("SaveState: failed to back up screenshot %{public}s",
                               screenshot_path.c_str());
                }
            } else {
                candidate.screenshot_state_known = true;
                candidate.screenshot_existed = false;
            }
        } else {
            candidate.state_data.clear();
            AZ_RT_LOGW("SaveState: failed to back up existing state before overwrite: %{public}s",
                       state_path.c_str());
        }
    }

    if (!system.SendSignal(Core::System::Signal::Save, static_cast<u32>(slot))) {
        return false;
    }
    if (state_path.empty()) {
        return true;
    }

    // 暂停中模拟线程休眠在 cv_ 上，需持续补帧驱动 RunLoop 消费 Save 信号直到 .cst 落盘，
    // 否则暂停菜单里的保存会被推迟到恢复运行才生效（信号甚至可能随退出丢失）
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    bool saved = false;
    while (std::chrono::steady_clock::now() < deadline) {
        if (FileUtil::Exists(state_path)) {
            std::error_code write_ec;
            const auto write_time = fs::last_write_time(state_path, write_ec);
            if (!write_ec && write_time != prev_write) {
                saved = true;
                break;
            }
        }
        if (pause_requested_) {
            pause_frame_requested_ = true;
            cv_.notify_all();
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    if (!saved) {
        AZ_RT_LOGE("SaveState timed out waiting for %{public}s", state_path.c_str());
        // 写入可能产生了损坏/不完整的 .cst：用覆盖前的内存留底回滚，保持槽位可读
        if (candidate.slot >= 0 && !WriteUndoBackup(candidate)) {
            AZ_RT_LOGE("SaveState: rollback of %{public}s failed", state_path.c_str());
        }
        return false;
    }
    AZ_RT_LOGI("SaveState: slot %{public}d written to %{public}s", slot, state_path.c_str());

    if (candidate.slot >= 0) {
        std::lock_guard<std::mutex> lock(g_undo_backup_mutex);
        g_undo_backup = std::move(candidate);
    }

    // 与 .cst 同名生成截图，供暂停菜单/详情页预览；双屏左右拼接对齐 nds 布局
    if (!CaptureScreenshot(screenshot_path, 0, true)) {
        AZ_RT_LOGW("SaveState: screenshot capture failed for %{public}s",
                   screenshot_path.c_str());
    }
    return true;
}

bool AzaharCoreRuntime::LoadState(int32_t slot) {
    if (!running_ || !Core::System::GetInstance().IsPoweredOn() || slot < 0) {
        return false;
    }
    return Core::System::GetInstance().SendSignal(Core::System::Signal::Load,
                                                  static_cast<u32>(slot));
}

bool AzaharCoreRuntime::DeleteSaveState(int32_t slot) {
    const Core::System& system = Core::System::GetInstance();
    if (!running_ || !system.IsPoweredOn() || slot < 0) {
        return false;
    }

    u64 title_id = 0;
    if (system.GetAppLoader().ReadProgramId(title_id) != Loader::ResultStatus::Success) {
        return false;
    }

    const std::string state_path = Core::GetSaveStatePath(
        title_id, system.Movie().GetCurrentMovieID(), static_cast<u32>(slot));
    if (!FileUtil::Exists(state_path)) {
        return false;
    }

    // 截图与撤销备份都是 .cst 的附属产物，随存档一并删除
    const std::string screenshot_path = SaveStateScreenshotPath(state_path);
    const bool deleted = FileUtil::Delete(state_path);
    if (FileUtil::Exists(screenshot_path)) {
        FileUtil::Delete(screenshot_path);
    }
    if (deleted) {
        std::lock_guard<std::mutex> lock(g_undo_backup_mutex);
        if (g_undo_backup.slot == slot && g_undo_backup.state_path == state_path) {
            g_undo_backup = SaveStateUndoBackup{};
        }
    }
    return deleted;
}

bool AzaharCoreRuntime::HasUndoSaveState(int32_t slot) {
    const Core::System& system = Core::System::GetInstance();
    if (!running_ || !system.IsPoweredOn() || slot < 0) {
        return false;
    }
    u64 title_id = 0;
    if (system.GetAppLoader().ReadProgramId(title_id) != Loader::ResultStatus::Success) {
        return false;
    }
    const std::string state_path = Core::GetSaveStatePath(
        title_id, system.Movie().GetCurrentMovieID(), static_cast<u32>(slot));
    return UndoBackupMatches(state_path, slot);
}

bool AzaharCoreRuntime::UndoSaveState(int32_t slot) {
    const Core::System& system = Core::System::GetInstance();
    if (!running_ || !system.IsPoweredOn() || slot < 0) {
        return false;
    }
    u64 title_id = 0;
    if (system.GetAppLoader().ReadProgramId(title_id) != Loader::ResultStatus::Success) {
        return false;
    }
    const std::string state_path = Core::GetSaveStatePath(
        title_id, system.Movie().GetCurrentMovieID(), static_cast<u32>(slot));

    // 恢复即覆盖当前档。失败返回 false 且保留备份可重试；成功后备份一次性消费（对齐 nds）
    std::lock_guard<std::mutex> lock(g_undo_backup_mutex);
    if (g_undo_backup.slot != slot || g_undo_backup.state_path != state_path
        || g_undo_backup.state_data.empty()) {
        return false;
    }
    if (!WriteUndoBackup(g_undo_backup)) {
        AZ_RT_LOGE("UndoSaveState: restore failed for %{public}s", state_path.c_str());
        return false;
    }
    g_undo_backup = SaveStateUndoBackup{};
    return true;
}

std::vector<SaveStateSlotInfo> AzaharCoreRuntime::ListSaveStates(int32_t max_slot) {
    const Core::System& system = Core::System::GetInstance();
    if (!running_ || !system.IsPoweredOn()) {
        return {};
    }

    u64 title_id = 0;
    if (system.GetAppLoader().ReadProgramId(title_id) != Loader::ResultStatus::Success) {
        return {};
    }

    const u64 movie_id = system.Movie().GetCurrentMovieID();
    std::vector<SaveStateSlotInfo> result;
    const auto savestates = Core::ListSaveStates(title_id, movie_id, static_cast<u32>(max_slot));
    result.reserve(savestates.size());
    for (const auto& savestate : savestates) {
        if (savestate.slot > static_cast<u32>(max_slot)) {
            continue;
        }
        const std::string state_path = Core::GetSaveStatePath(title_id, movie_id, savestate.slot);
        const std::string screenshot_path = SaveStateScreenshotPath(state_path);
        result.push_back({
            static_cast<int32_t>(savestate.slot),
            savestate.time,
            static_cast<int32_t>(savestate.status),
            savestate.build_name,
            FileUtil::Exists(state_path) ? FileUtil::GetSize(state_path) : 0,
            FileUtil::Exists(screenshot_path) ? screenshot_path : "",
            UndoBackupMatches(state_path, static_cast<int32_t>(savestate.slot)),
        });
    }
    return result;
}

bool AzaharCoreRuntime::CaptureScreenshot(const std::string& path, int32_t resolution_scale,
                                          bool side_by_side) {
    Core::System& system = Core::System::GetInstance();
    if (path.empty() || stop_requested_ || !running_ || !system.IsPoweredOn()) {
        AZ_RT_LOGW("CaptureScreenshot rejected: empty=%{public}d stop=%{public}d running=%{public}d powered=%{public}d",
                   path.empty() ? 1 : 0, stop_requested_ ? 1 : 0, running_ ? 1 : 0,
                   system.IsPoweredOn() ? 1 : 0);
        return false;
    }

    bool expected = false;
    if (!screenshot_in_progress_.compare_exchange_strong(expected, true)) {
        AZ_RT_LOGW("CaptureScreenshot rejected: already in progress");
        return false;
    }

    auto& renderer = system.GPU().Renderer();
    if (renderer.IsScreenshotPending()) {
        AZ_RT_LOGW("CaptureScreenshot rejected: renderer still has pending request");
        screenshot_in_progress_ = false;
        return false;
    }

    u32 scale = 0;
    if (resolution_scale > 0) {
        scale = static_cast<u32>(resolution_scale);
    } else {
        scale = renderer.GetResolutionScaleFactor();
    }

    Layout::FramebufferLayout layout{0, 0, true, true, {}, {}};
    if (side_by_side) {
        // 左右拼接：两屏同高并保留各自原生宽高比（上屏 400x240 | 下屏 320x240 = 720x240），
        // 对齐 nds 存档预览的双屏横排样式
        const u32 top_w = Core::kScreenTopWidth * scale;
        const u32 bot_w = Core::kScreenBottomWidth * scale;
        const u32 h = Core::kScreenTopHeight * scale;
        layout.width = top_w + bot_w;
        layout.height = h;
        if (Settings::values.swap_screen.GetValue()) {
            layout.top_screen = Common::Rectangle<u32>{bot_w, 0, top_w + bot_w, h};
            layout.bottom_screen = Common::Rectangle<u32>{0, 0, bot_w, h};
        } else {
            layout.top_screen = Common::Rectangle<u32>{0, 0, top_w, h};
            layout.bottom_screen = Common::Rectangle<u32>{top_w, 0, top_w + bot_w, h};
        }
    } else {
        // 上下屏等宽拼接：下屏原生 320x240 比上屏 400x240 窄，默认布局居中会留两侧黑边，
        // 这里把下屏等比放大到上屏宽度（320x240 -> 400x300），不变形无黑边
        const u32 screen_w = Core::kScreenTopWidth * scale;
        const u32 top_h = Core::kScreenTopHeight * scale;
        const u32 bot_h = screen_w * Core::kScreenBottomHeight / Core::kScreenBottomWidth;
        layout.width = screen_w;
        layout.height = top_h + bot_h;
        const Common::Rectangle<u32> top_rect{0, 0, screen_w, top_h};
        const Common::Rectangle<u32> bot_rect{0, top_h, screen_w, top_h + bot_h};
        if (Settings::values.swap_screen.GetValue()) {
            layout.top_screen = Common::Rectangle<u32>{0, bot_h, screen_w, bot_h + top_h};
            layout.bottom_screen = Common::Rectangle<u32>{0, 0, screen_w, bot_h};
        } else {
            layout.top_screen = top_rect;
            layout.bottom_screen = bot_rect;
        }
    }
    // 截图固定输出单视图：render_3d 立体选项（如 SideBySideFull）会把左右眼并排画出
    layout.render_3d_mode = Settings::StereoRenderOption::Off;
    if (layout.width == 0 || layout.height == 0) {
        AZ_RT_LOGE("CaptureScreenshot rejected: invalid layout scale=%{public}u", scale);
        screenshot_in_progress_ = false;
        return false;
    }
    AZ_RT_LOGI("CaptureScreenshot requested: %{public}ux%{public}u scale=%{public}u paused=%{public}d path=%{public}s",
               layout.width, layout.height, scale, pause_requested_ ? 1 : 0, path.c_str());

    auto pixels = std::make_shared<std::vector<u8>>(layout.width * layout.height * 4ull);
    auto save_result = std::make_shared<std::atomic_bool>(false);
    auto capture_done = std::make_shared<std::atomic_bool>(false);
    renderer.RequestScreenshot(
        pixels->data(),
        [this, pixels, save_result, capture_done, path, width = layout.width,
         height = layout.height](bool invert_y) {
            save_result->store(SaveScreenshotPng(path, *pixels, width, height, invert_y));
            screenshot_in_progress_ = false;
            capture_done->store(true);
        },
        layout);

    // 截图在渲染线程下一帧的回调里落盘：同步等待完成，保证返回 true 时文件已写入。
    // 等待以本次调用的 capture_done 为准：超时滞留的上一笔请求若在泵帧中被消费，
    // 其陈旧回调会误清本次的 screenshot_in_progress_，不能作为完成信号。
    // 暂停中 emu 线程驻停（pause_parked_）时优先在调用线程直接消费截图请求——
    // 泵帧链路（pause_frame_requested_→RunLoop→VBlank→SwapBuffers）在部分场景
    // 整体失效（实测 renderer_pending=1 挂满 3s 超时）；持有 mutex_ 期间 emu
    // 线程无法退出 cv_.wait，保证渲染器状态被本线程独占（对齐 nds 图形层取帧）。
    // 未驻停/未实现该路径的后端（GL）退回泵帧驱动
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (!capture_done->load() && std::chrono::steady_clock::now() < deadline) {
        if (pause_requested_) {
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (pause_parked_) {
                    renderer.ProcessPendingScreenshot();
                }
            }
            if (!capture_done->load()) {
                pause_frame_requested_ = true;
                cv_.notify_all();
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    if (!capture_done->load()) {
        AZ_RT_LOGE("CaptureScreenshot timed out: renderer_pending=%{public}d",
                   renderer.IsScreenshotPending() ? 1 : 0);
        screenshot_in_progress_ = false;
        // requested 只能被渲染线程的 RenderScreenshot 消费，暂停态没有自然帧时
        // 超时请求会永久滞留、后续调用全被 IsScreenshotPending 秒拒；主动复位
        renderer.Settings().screenshot_requested.store(false);
        return false;
    }
    if (!save_result->load()) {
        AZ_RT_LOGE("CaptureScreenshot render callback failed to save %{public}s", path.c_str());
    }
    return save_result->load();
}

static std::atomic<bool> mic_permission_pending{false};

bool ConsumeMicPermissionRequest() {
    return mic_permission_pending.exchange(false);
}

// RunLoop 非致命错误的待上报缓存（与 mic_permission_pending 同一握手模式，
// 但携带状态名+详情，需互斥保护而非原子量）
static std::mutex core_error_mutex;
static bool core_error_pending = false;
static std::string core_error_status;
static std::string core_error_details;
static std::string last_core_error_status;
static std::chrono::steady_clock::time_point last_core_error_time{};

bool NotifyCoreError(const std::string& status, const std::string& details) {
    const auto now = std::chrono::steady_clock::now();
    std::lock_guard<std::mutex> lock(core_error_mutex);
    // 同一错误可能每帧重复返回（如 CPU 异常）：相同 status 限频避免 toast/log 刷屏
    if (status == last_core_error_status &&
        now - last_core_error_time < std::chrono::seconds(3)) {
        return false;
    }
    last_core_error_status = status;
    last_core_error_time = now;
    core_error_status = status;
    core_error_details = details;
    core_error_pending = true;
    return true;
}

bool ConsumeCoreError(std::string& status, std::string& details) {
    std::lock_guard<std::mutex> lock(core_error_mutex);
    if (!core_error_pending) {
        return false;
    }
    status = std::move(core_error_status);
    details = std::move(core_error_details);
    core_error_pending = false;
    return true;
}

bool AzaharCoreRuntime::ApplyConfig(const std::unordered_map<std::string, ConfigValue>& config) {
    Core::System& system = Core::System::GetInstance();
    ApplySettingsFromConfig(config);
    if (running_ && system.IsPoweredOn()) {
        system.ApplySettings();
    }
    {
        // swap_screen/upright_screen/layout_option 等布局类设置只在
        // UpdateCurrentFramebufferLayout 时消费；apply 后按当前 surface 尺寸重算，
        // 对齐 Android applySettings + updateFramebuffer 的组合（桌面端 ApplySettings 内已含）
        std::lock_guard<std::mutex> lock(mutex_);
        if (window_) {
            window_->RefreshFramebufferLayout();
        }
    }
    return true;
}

bool AzaharCoreRuntime::PresentFrame() {
    if (!running_ || stop_requested_ || pause_requested_) {
        return false;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    if (!window_) {
        return false;
    }

    window_->TryPresenting();
    return true;
}

bool AzaharCoreRuntime::SendTouchEvent(double x, double y, int32_t action) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!window_) {
        return false;
    }

    const int px = static_cast<int>(std::lround(x));
    const int py = static_cast<int>(std::lround(y));
    switch (action) {
    case 0:
        return window_->OnTouchEvent(px, py, true);
    case 1:
        window_->OnTouchMoved(px, py);
        return true;
    case 2:
        return window_->OnTouchEvent(px, py, false);
    default:
        return false;
    }
}

bool AzaharCoreRuntime::OnSurfaceChanged(OHNativeWindow* native_window, int width, int height) {
    bool changed = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!window_) {
            return false;
        }
        changed = window_->OnSurfaceChanged(native_window, width, height);
    }

    Core::System& system = Core::System::GetInstance();
    if (changed && system.IsPoweredOn()) {
        system.GPU().Renderer().NotifySurfaceChanged(false);
    }
    return changed;
}

std::vector<double> AzaharCoreRuntime::GetScreenLayout() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!window_) {
        return {};
    }
    const Layout::FramebufferLayout& layout = window_->GetFramebufferLayout();
    if (layout.width == 0 || layout.height == 0) {
        return {};
    }
    return {
        static_cast<double>(layout.width),
        static_cast<double>(layout.height),
        layout.top_screen_enabled ? 1.0 : 0.0,
        static_cast<double>(layout.top_screen.left),
        static_cast<double>(layout.top_screen.top),
        static_cast<double>(layout.top_screen.right),
        static_cast<double>(layout.top_screen.bottom),
        layout.bottom_screen_enabled ? 1.0 : 0.0,
        static_cast<double>(layout.bottom_screen.left),
        static_cast<double>(layout.bottom_screen.top),
        static_cast<double>(layout.bottom_screen.right),
        static_cast<double>(layout.bottom_screen.bottom),
    };
}

void AzaharCoreRuntime::SetScreenOffsets(int32_t left, int32_t top, int32_t right, int32_t bottom) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (window_) {
        window_->SetScreenOffsets(left, top, right, bottom);
    }
}

void AzaharCoreRuntime::ApplyCustomScreenRectsLocked() {
    const auto& r = *custom_screen_rects_;
    const auto to_rect = [](int32_t x, int32_t y, int32_t w, int32_t h) {
        const u32 left = static_cast<u32>(std::max(x, 0));
        const u32 top = static_cast<u32>(std::max(y, 0));
        return Common::Rectangle<u32>{left, top, left + static_cast<u32>(std::max(w, 0)),
                                    top + static_cast<u32>(std::max(h, 0))};
    };
    window_->SetCustomScreenRects(to_rect(r[0], r[1], r[2], r[3]),
                                  to_rect(r[4], r[5], r[6], r[7]));
}

void AzaharCoreRuntime::SetCustomScreenRects(int32_t top_x, int32_t top_y, int32_t top_w,
                                             int32_t top_h, int32_t bottom_x, int32_t bottom_y,
                                             int32_t bottom_w, int32_t bottom_h) {
    std::lock_guard<std::mutex> lock(mutex_);
    custom_screen_rects_ = {top_x, top_y, top_w, top_h, bottom_x, bottom_y, bottom_w, bottom_h};
    if (window_) {
        ApplyCustomScreenRectsLocked();
    }
}

void AzaharCoreRuntime::ClearCustomScreenRects() {
    std::lock_guard<std::mutex> lock(mutex_);
    custom_screen_rects_.reset();
    if (window_) {
        window_->ClearCustomScreenRects();
    }
}

bool AzaharCoreRuntime::IsRunning() const {
    return running_;
}

bool AzaharCoreRuntime::IsPaused() const {
    return running_ && pause_requested_;
}

std::string AzaharCoreRuntime::GetStatus() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return status_;
}

std::vector<double> AzaharCoreRuntime::GetPerfStats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return std::vector<double>(perf_stats_.begin(), perf_stats_.end());
}

void AzaharCoreRuntime::Run(std::string filepath, OHNativeWindow* native_window, int width,
                            int height, std::unordered_map<std::string, ConfigValue> config,
                            std::string files_dir, std::string cache_dir, std::string user_dir) {
    running_ = true;
    SetStatus("azahar_core_initializing");

    ApplyRuntimePaths(files_dir, cache_dir, user_dir);
    ApplySettingsFromConfig(config);

    // “调试日志”开关：开启才创建 log/ 并挂文件后端（关闭时目录和后端都不存在）。
    static bool file_logging_started = false;
    if (Settings::values.instant_debug_log.GetValue() && !file_logging_started) {
        FileUtil::CreateFullPath(FileUtil::GetUserPath(FileUtil::UserPath::LogDir));
        Common::Log::Initialize();
        Common::Log::Start();
        file_logging_started = true;
    }

    Input::ApplyDefaultProfile();
    Settings::LogSettings();

    Core::System& system = Core::System::GetInstance();
    const std::string movie_record_path = ConfigString(config, "movie_record_path", "");
    const std::string movie_record_author = ConfigString(config, "movie_record_author", "");
    const std::string movie_playback_path = ConfigString(config, "movie_playback_path", "");
    if (!movie_playback_path.empty()) {
        system.Movie().SetReadOnly(ConfigBool(config, "movie_read_only", true));
        system.Movie().PrepareForPlayback(movie_playback_path);
    } else if (!movie_record_path.empty()) {
        EnsureParentDirectory(movie_record_path);
        system.Movie().PrepareForRecording();
    }

    system.EjectCartridge();
    const std::string inserted_cartridge = ConfigString(config, "inserted_cartridge", "");
    if (!inserted_cartridge.empty()) {
        system.InsertCartridge(inserted_cartridge);
    }

    static std::once_flag camera_factories_registered;
    std::call_once(camera_factories_registered, [] {
        Camera::RegisterFactory("image", std::make_unique<Camera::OhosStillImage::Factory>());
        Camera::RegisterFactory("ohos", std::make_unique<Camera::Ohos::Factory>());
    });
    static std::once_flag mic_permission_registered;
    std::call_once(mic_permission_registered, [&system] {
        // 与相机同一握手：无权限时置位 pending，帧泵消费后由前端弹系统授权框；
        // 拒绝则输入工厂回落 NullInput（静音），下帧再触发会重新置位
        system.RegisterMicPermissionCheck([] {
            if (OH_AT_CheckSelfPermission("ohos.permission.MICROPHONE")) {
                return true;
            }
            mic_permission_pending.store(true);
            return false;
        });
    });

    Frontend::RegisterDefaultApplets(system);
    Pica::g_debug_context = Pica::DebugContext::Construct();

    bool window_ready = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        bool use_vulkan = Settings::GetWorkingGraphicsAPI() == Settings::GraphicsAPI::Vulkan;
#ifdef ENABLE_VULKAN
        if (use_vulkan) {
            try {
                const auto library = Vulkan::OpenLibrary();
                if (!library || !library->IsLoaded()) {
                    throw std::runtime_error("Vulkan loader is unavailable");
                }
                const auto instance = Vulkan::CreateInstance(
                    *library, Frontend::WindowSystemType::OpenHarmony, false, false);
                if (!instance || instance->enumeratePhysicalDevices().empty()) {
                    throw std::runtime_error("No Vulkan physical device is available");
                }
            } catch (const std::exception& error) {
                AZ_RT_LOGW("Vulkan preflight failed, falling back to OpenGL: %{public}s",
                           error.what());
                Settings::values.graphics_api = Settings::GraphicsAPI::OpenGL;
                Settings::values.use_gles = true;
                use_vulkan = false;
            }
        }
#else
        use_vulkan = false;
#endif
        if (use_vulkan) {
            window_ = std::make_unique<EmuWindowOhosVulkan>(native_window, width, height);
            window_ready = true;
        } else {
            window_ = std::make_unique<EmuWindowOhosOpenGL>(system, native_window, width, height);
            EGLContext* egl_context = window_->GetEGLContext();
            window_ready = egl_context && *egl_context != EGL_NO_CONTEXT;
            if (window_ready) {
                window_->MakeCurrent();
            }
        }
        if (!window_ready) {
            window_.reset();
        } else if (custom_screen_rects_) {
            // 建窗前的编辑器矩形暂存值在此生效（窗口构造时先按自动布局初始化）
            ApplyCustomScreenRectsLocked();
        }
    }
    if (!window_ready) {
        running_ = false;
        SignalStartup(false, "azahar_core_graphics_init_failed");
        Input::Shutdown();
        Network::Shutdown();
        Pica::g_debug_context.reset();
        return;
    }

    AZ_RT_LOGI("Azahar core loading path: %{public}s", filepath.c_str());
    Core::System::ResultStatus load_result = Core::System::ResultStatus::ErrorUnknown;
    try {
        std::lock_guard<std::mutex> lock(mutex_);
        load_result = system.Load(*window_, filepath);
    } catch (const std::exception& error) {
        // 匿名可执行内存被系统拒绝（坚盾守护模式运行中开启、ACL 未生效等）时，
        // JIT 代码缓存 mmap 抛 std::bad_alloc。异常逃出模拟线程会 std::terminate
        // 直接闪退，必须在此兜底：关闭 JIT 改用解释器后端重试一次。
        AZ_RT_LOGE("Azahar core load threw: %{public}s", error.what());
        const bool jit_was_requested =
            Settings::values.use_cpu_jit.GetValue() || Settings::values.use_shader_jit.GetValue();
        if (jit_was_requested) {
            Settings::values.use_cpu_jit = false;
            Settings::values.use_shader_jit = false;
            if (system.IsPoweredOn()) {
                system.Shutdown();
            }
            try {
                std::lock_guard<std::mutex> lock(mutex_);
                load_result = system.Load(*window_, filepath);
                if (load_result == Core::System::ResultStatus::Success) {
                    AZ_RT_LOGI("Azahar core load succeeded with JIT disabled");
                }
            } catch (const std::exception& retry_error) {
                AZ_RT_LOGE("Interpreter fallback load threw: %{public}s", retry_error.what());
            }
        }
    }
    if (load_result != Core::System::ResultStatus::Success) {
        const std::string load_status = ResultStatusName(load_result);
        AZ_RT_LOGE("Azahar core load failed: %{public}s", load_status.c_str());
        running_ = false;
        SignalStartup(false, "azahar_core_load_failed:" + load_status);
        if (system.IsPoweredOn()) {
            system.Shutdown();
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            window_.reset();
        }
        Input::Shutdown();
        Network::Shutdown();
        Pica::g_debug_context.reset();
        return;
    }

    if (!movie_playback_path.empty()) {
        system.Movie().StartPlayback(movie_playback_path);
    } else if (!movie_record_path.empty()) {
        system.Movie().StartRecording(movie_record_path, movie_record_author);
    }

    SignalStartup(true, "azahar_core_running");
    AZ_RT_LOGI("Azahar core run loop started");

    while (!stop_requested_) {
        if (pause_requested_) {
            std::unique_lock<std::mutex> lock(mutex_);
            pause_parked_ = true;
            cv_.wait(lock, [this] {
                return stop_requested_ || !pause_requested_ || pause_frame_requested_;
            });
            pause_parked_ = false;
            if (stop_requested_) {
                break;
            }
            if (window_) {
                window_->PollEvents();
            }
            if (!pause_requested_) {
                pause_frame_requested_ = false;
            }
            if (pause_requested_ && !pause_frame_requested_.exchange(false)) {
                continue;
            }
        }

        const Core::System::ResultStatus result = system.RunLoop();
        if (result == Core::System::ResultStatus::Success) {
            const auto now = std::chrono::steady_clock::now();
            static auto last_stats_sample = now;
            if (now - last_stats_sample >= std::chrono::seconds(1)) {
                last_stats_sample = now;
                if (system.perf_stats) {
                    const auto r = system.GetAndResetPerfStats();
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        perf_stats_ = {r.system_fps,
                                       r.game_fps,
                                       r.emulation_speed,
                                       r.time_vblank_interval,
                                       r.time_hle_svc,
                                       r.time_hle_ipc,
                                       r.time_gpu,
                                       r.time_swap,
                                       r.time_remaining,
                                       r.ir_mips,
                                       r.ir_average_block_size,
                                       r.ir_dense_cache_hit_rate,
                                       r.ir_translations_per_second,
                                       r.ir_fallbacks_per_second,
                                       r.hardware_draw_rate,
                                       r.geometry_cache_hit_rate,
                                       r.time_host_gpu};
                    }
                }
            }
            continue;
        }

        if (result == Core::System::ResultStatus::ShutdownRequested) {
            AZ_RT_LOGW("Azahar core shutdown requested");
            SetStatus("azahar_core_shutdown_requested");
            break;
        }

        // core 返回的所有非致命错误（存档被拒、CPU 异常、系统文件缺失、渲染器故障等）
        // 一律无条件继续运行 —— 用户明确要求最大宽容、会话永不中断。通知前端帧泵
        // toast，绝不 break：break 会让 emu 线程退出、画面永久冻结且无任何反馈
        const std::string run_status = ResultStatusName(result);
        if (NotifyCoreError(run_status, system.GetStatusDetails())) {
            AZ_RT_LOGW("Azahar core error, continuing: %{public}s (%{public}s)",
                       run_status.c_str(), system.GetStatusDetails().c_str());
        }
        continue;
    }

    if (system.Movie().GetPlayMode() != Core::Movie::PlayMode::None) {
        system.Movie().Shutdown();
    }

    if (system.IsPoweredOn()) {
        system.Shutdown();
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        window_.reset();
    }
    Input::Shutdown();
    Network::Shutdown();
    Pica::g_debug_context.reset();
    running_ = false;
    pause_requested_ = false;
    if (GetStatus() == "azahar_core_running" || GetStatus() == "azahar_core_paused") {
        SetStatus("azahar_core_stopped");
    }
    cv_.notify_all();
}

void AzaharCoreRuntime::SignalStartup(bool ok, std::string status) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        startup_reported_ = true;
        startup_ok_ = ok;
        status_ = std::move(status);
    }
    cv_.notify_all();
}

void AzaharCoreRuntime::SetStatus(std::string status) {
    std::lock_guard<std::mutex> lock(mutex_);
    status_ = std::move(status);
}

} // namespace Azahar::Ohos
