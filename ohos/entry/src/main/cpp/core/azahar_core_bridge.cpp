#include "azahar_core_bridge.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <thread>

#include "core/ohos_jit_capability.h"

#if AZAHAR_OHOS_CORE_AVAILABLE
#include <native_window/external_window.h>

#include "common/file_util.h"
#include "common/hacks/hack_manager.h"
#include "common/settings.h"
#include "common/string_util.h"
#include "core/zip_pass.h"

namespace Loader {
void resetProgramId();
}
#include "core/cheats/cheat_base.h"
#include "core/cheats/cheats.h"
#include "core/cheats/gateway_cheat.h"
#include "core/core.h"
#include "core/azahar_core_runtime.h"
#include "core/hw/unique_data.h"
#include "core/hle/service/am/am.h"
#include "core/hle/service/apt/apt.h"
#include "core/hle/service/cfg/cfg.h"
#include "core/hle/service/nfc/nfc_device.h"
#include "core/hle/service/nfc/nfc.h"
#include "core/hle/service/ptm/ptm.h"
#include "core/loader/loader.h"
#include "core/loader/smdh.h"
#include "core/movie.h"
#include "core/system_titles.h"
#include "input/ohos_gamepad.h"
#include "input/ohos_input.h"
#include "network/announce_multiplayer_session.h"
#include "network/network.h"
#include "network/room.h"
#include "network/room_member.h"
#include "network/verify_user.h"
#else
namespace Azahar::Ohos {
class AzaharCoreRuntime {};
} // namespace Azahar::Ohos
#endif

namespace Azahar::Ohos {

namespace {
constexpr const char* kSupportedExtensions[] = {
    ".3ds", ".cci", ".cxi", ".3dsx", ".elf", ".axf", ".app",
};

#if AZAHAR_OHOS_CORE_AVAILABLE
constexpr uint64_t kUpdateTidHigh = 0x0004000e00000000;

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
        FileUtil::CreateFullPath(FileUtil::GetUserPath(path));
    }
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

template <std::size_t N>
std::string SmdhTextToUtf8(const std::array<char16_t, N>& text) {
    std::u16string trimmed;
    for (const char16_t ch : text) {
        if (ch == 0) {
            break;
        }
        trimmed.push_back(ch);
    }
    return Common::UTF16ToUTF8(trimmed);
}

std::string TitleIdToString(u64 title_id) {
    if (title_id == 0) {
        return "";
    }
    std::ostringstream stream;
    stream << std::uppercase << std::hex << std::setw(16) << std::setfill('0') << title_id;
    return stream.str();
}

std::string ConfigString(const std::unordered_map<std::string, ConfigValue>& config,
                         const std::string& key, const std::string& fallback) {
    const auto it = config.find(key);
    if (it == config.end() || !std::holds_alternative<std::string>(it->second)) {
        return fallback;
    }
    return std::get<std::string>(it->second);
}

bool ConfigBool(const std::unordered_map<std::string, ConfigValue>& config, const std::string& key,
                bool fallback) {
    const auto it = config.find(key);
    if (it == config.end() || !std::holds_alternative<bool>(it->second)) {
        return fallback;
    }
    return std::get<bool>(it->second);
}

std::string NormalizeMacAddress(std::string mac) {
    std::string hex;
    hex.reserve(12);
    for (const char ch : mac) {
        if (std::isxdigit(static_cast<unsigned char>(ch)) != 0) {
            hex.push_back(static_cast<char>(std::toupper(static_cast<unsigned char>(ch))));
        }
    }
    if (hex.size() != 12) {
        return "";
    }
    std::string out;
    out.reserve(17);
    for (std::size_t i = 0; i < hex.size(); ++i) {
        if (i > 0 && i % 2 == 0) {
            out.push_back(':');
        }
        out.push_back(hex[i]);
    }
    return out;
}

void ApplyNetworkConfig(const std::unordered_map<std::string, ConfigValue>& config) {
    Settings::values.web_api_url =
        ConfigString(config, "web_api_url", "https://api.citra-emu.org");
    Settings::values.network_token = ConfigString(config, "citra_token", "");
}

std::optional<u64> ParseTitleId(std::string title_id) {
    title_id.erase(std::remove_if(title_id.begin(), title_id.end(), [](unsigned char ch) {
                       return std::isspace(ch) != 0;
                   }),
                   title_id.end());
    if (title_id.rfind("0x", 0) == 0 || title_id.rfind("0X", 0) == 0) {
        title_id = title_id.substr(2);
    }
    if (title_id.empty()) {
        return std::nullopt;
    }

    try {
        std::size_t consumed = 0;
        const u64 value = static_cast<u64>(std::stoull(title_id, &consumed, 16));
        if (consumed != title_id.size()) {
            return std::nullopt;
        }
        return value;
    } catch (const std::exception&) {
        return std::nullopt;
    }
}

std::string RegionsToString(const Loader::SMDH& smdh) {
    using GameRegion = Loader::SMDH::GameRegion;
    static constexpr std::array<const char*, 7> region_names{
        "Japan", "North America", "Europe", "Australia", "China", "Korea", "Taiwan",
    };

    const std::vector<GameRegion> regions = smdh.GetRegions();
    if (regions.empty()) {
        return "";
    }
    if (regions.size() == region_names.size()) {
        return "Region free";
    }

    std::string result;
    for (const GameRegion region : regions) {
        const auto index = static_cast<std::size_t>(region);
        if (index >= region_names.size()) {
            continue;
        }
        if (!result.empty()) {
            result += ", ";
        }
        result += region_names[index];
    }
    return result;
}

std::string MoviePlayModeName(Core::Movie::PlayMode mode) {
    switch (mode) {
    case Core::Movie::PlayMode::None:
        return "none";
    case Core::Movie::PlayMode::Recording:
        return "recording";
    case Core::Movie::PlayMode::Playing:
        return "playing";
    case Core::Movie::PlayMode::MovieFinished:
        return "finished";
    }
    return "none";
}

std::string LoaderResultName(Loader::ResultStatus status) {
    switch (status) {
    case Loader::ResultStatus::Success:
        return "success";
    case Loader::ResultStatus::Error:
        return "error";
    case Loader::ResultStatus::ErrorInvalidFormat:
        return "invalid_format";
    case Loader::ResultStatus::ErrorNotImplemented:
        return "not_implemented";
    case Loader::ResultStatus::ErrorNotLoaded:
        return "not_loaded";
    case Loader::ResultStatus::ErrorNotUsed:
        return "not_used";
    case Loader::ResultStatus::ErrorAlreadyLoaded:
        return "already_loaded";
    case Loader::ResultStatus::ErrorMemoryAllocationFailed:
        return "memory_allocation_failed";
    case Loader::ResultStatus::ErrorEncrypted:
        return "encrypted";
    case Loader::ResultStatus::ErrorGbaTitle:
        return "gba_title";
    case Loader::ResultStatus::ErrorArtic:
        return "artic";
    case Loader::ResultStatus::ErrorNotFound:
        return "not_found";
    case Loader::ResultStatus::ErrorPatches:
        return "patches";
    case Loader::ResultStatus::ErrorPatchesInvalidTitle:
        return "patches_invalid_title";
    }
    return "unknown";
}

std::vector<uint8_t> Rgb565ToRgba(const std::vector<u16>& icon) {
    std::vector<uint8_t> rgba;
    rgba.resize(icon.size() * 4);
    for (std::size_t i = 0; i < icon.size(); ++i) {
        const u16 pixel = icon[i];
        const uint8_t r = static_cast<uint8_t>(((pixel >> 11) & 0x1F) * 255 / 31);
        const uint8_t g = static_cast<uint8_t>(((pixel >> 5) & 0x3F) * 255 / 63);
        const uint8_t b = static_cast<uint8_t>((pixel & 0x1F) * 255 / 31);
        rgba[i * 4] = r;
        rgba[i * 4 + 1] = g;
        rgba[i * 4 + 2] = b;
        rgba[i * 4 + 3] = 255;
    }
    return rgba;
}

std::vector<uint8_t> Rgb565ToBytes(const std::vector<u16>& icon) {
    std::vector<uint8_t> rgb565;
    rgb565.resize(icon.size() * 2);
    for (std::size_t i = 0; i < icon.size(); ++i) {
        const u16 pixel = icon[i];
        rgb565[i * 2] = static_cast<uint8_t>(pixel & 0xFF);
        rgb565[i * 2 + 1] = static_cast<uint8_t>((pixel >> 8) & 0xFF);
    }
    return rgb565;
}
#endif
}

std::string RuntimeStateName(RuntimeState state) {
    switch (state) {
    case RuntimeState::Stopped:
        return "stopped";
    case RuntimeState::Loaded:
        return "loaded";
    case RuntimeState::Running:
        return "running";
    case RuntimeState::Paused:
        return "paused";
    }
    return "unknown";
}

std::string CoreBackendName(CoreBackend backend) {
    switch (backend) {
    case CoreBackend::Stub:
        return "stub";
    case CoreBackend::AzaharCore:
        return "azahar_core";
    }
    return "unknown";
}

CoreBridge& CoreBridge::Get() {
    static CoreBridge bridge;
    return bridge;
}

CoreBridge::CoreBridge() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    runtime_.backend = CoreBackend::AzaharCore;
    runtime_.backend_status = "azahar_core_bound";
#else
    runtime_.backend = CoreBackend::Stub;
    runtime_.backend_status = "azahar_core_not_linked";
#endif
}

CoreBridge::~CoreBridge() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    Gamepad::Shutdown();
    if (real_core_) {
        real_core_->Stop();
    }
#endif
}

bool CoreBridge::Initialize(std::string files_dir, std::string cache_dir, std::string user_dir,
                            std::string device_type, bool tablet_jit_user_enabled) {
    if (user_dir.empty()) {
        return false;
    }

    const std::string runtime_files_dir = files_dir;
    const std::string runtime_cache_dir = cache_dir;
    const std::string runtime_user_dir = user_dir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        files_dir_ = std::move(files_dir);
        cache_dir_ = std::move(cache_dir);
        user_dir_ = std::move(user_dir);
        runtime_.device_type = NormalizeDeviceType(std::move(device_type));
        tablet_jit_user_enabled_ = tablet_jit_user_enabled;
        runtime_.initialized = true;
        EnsureDefaultConfigLocked();
        ApplyJitPolicyLocked();
#if AZAHAR_OHOS_CORE_AVAILABLE
        if (!real_core_) {
            real_core_ = std::make_unique<AzaharCoreRuntime>();
        }
        if (runtime_.custom_screen_rects) {
            // 先于 Initialize 到达的编辑器矩形暂存值补发给刚创建的 core
            const auto& r = *runtime_.custom_screen_rects;
            real_core_->SetCustomScreenRects(
                static_cast<int32_t>(r[0]), static_cast<int32_t>(r[1]),
                static_cast<int32_t>(r[2]), static_cast<int32_t>(r[3]),
                static_cast<int32_t>(r[4]), static_cast<int32_t>(r[5]),
                static_cast<int32_t>(r[6]), static_cast<int32_t>(r[7]));
        }
        runtime_.backend = CoreBackend::AzaharCore;
        runtime_.backend_status = real_core_->GetStatus();
#endif
    }
#if AZAHAR_OHOS_CORE_AVAILABLE
    ApplyRuntimePaths(runtime_files_dir, runtime_cache_dir, runtime_user_dir);
    Gamepad::Initialize();
#endif
    return true;
}

bool CoreBridge::Shutdown() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        core = real_core_.get();
    }
    if (core) {
        core->Stop();
    }
    Gamepad::Shutdown();
#endif

    std::lock_guard<std::mutex> lock(mutex_);
    runtime_.initialized = false;
    runtime_.state = RuntimeState::Stopped;
    runtime_.loaded_path.clear();
#if AZAHAR_OHOS_CORE_AVAILABLE
    runtime_.backend = CoreBackend::AzaharCore;
    runtime_.backend_status = real_core_ ? real_core_->GetStatus() : "azahar_core_bound";
#endif
    return true;
}

LoadResult CoreBridge::LoadApplication(const std::string& path) {
    if (path.empty()) {
        return LoadResult::EmptyPath;
    }
    if (!IsSupportedApplicationPath(path)) {
        return LoadResult::UnsupportedFormat;
    }
    if (!LocalFileExists(path)) {
        return LoadResult::FileNotFound;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    if (!runtime_.initialized) {
        return LoadResult::NotInitialized;
    }

    runtime_.loaded_path = path;
    runtime_.state = RuntimeState::Loaded;
    return LoadResult::Success;
}

bool CoreBridge::StartEmulation() {
    std::string path;
    std::string files_dir;
    std::string cache_dir;
    std::string user_dir;
    SurfaceInfo surface;
    std::unordered_map<std::string, ConfigValue> config;
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
#endif
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!runtime_.initialized || runtime_.loaded_path.empty()) {
            return false;
        }
#if AZAHAR_OHOS_CORE_AVAILABLE
        if (!runtime_.surface.ready || !runtime_.surface.native_window) {
            runtime_.backend_status = "azahar_core_no_surface";
            return false;
        }
        if (!real_core_) {
            real_core_ = std::make_unique<AzaharCoreRuntime>();
        }
        core = real_core_.get();
        path = runtime_.loaded_path;
        files_dir = files_dir_;
        cache_dir = cache_dir_;
        user_dir = user_dir_;
        surface = runtime_.surface;
        // 启动前重评估 JIT 策略：use_cpu_jit 由缓存的权限探测结果与
        // 当前用户设置共同决定，确保最新设置值随本次会话进入核心
        ApplyJitPolicyLocked();
        config = config_;
        runtime_.state = RuntimeState::Running;
        runtime_.backend = CoreBackend::AzaharCore;
        runtime_.backend_status = "azahar_core_starting";
#else
        runtime_.state = RuntimeState::Running;
        return true;
#endif
    }

#if AZAHAR_OHOS_CORE_AVAILABLE
    const bool started = core->Start(std::move(path),
                                     static_cast<OHNativeWindow*>(surface.native_window),
                                     static_cast<int>(surface.width),
                                     static_cast<int>(surface.height), std::move(config),
                                     std::move(files_dir), std::move(cache_dir),
                                     std::move(user_dir));
    std::lock_guard<std::mutex> lock(mutex_);
    runtime_.backend_status = core->GetStatus();
    runtime_.state = started ? RuntimeState::Running : RuntimeState::Loaded;
    return started;
#else
    return false;
#endif
}

bool CoreBridge::PauseEmulation() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        core = real_core_.get();
        if (!core || runtime_.state != RuntimeState::Running) {
            return false;
        }
    }

    const bool paused = core->Pause();
    if (paused) {
        core->OnSurfaceChanged(nullptr, 0, 0);
    }
    std::lock_guard<std::mutex> lock(mutex_);
    runtime_.backend_status = core->GetStatus();
    if (paused) {
        runtime_.state = RuntimeState::Paused;
    }
    return paused;
#else
    std::lock_guard<std::mutex> lock(mutex_);
    if (runtime_.state != RuntimeState::Running) {
        return false;
    }
    runtime_.state = RuntimeState::Paused;
    return true;
#endif
}

bool CoreBridge::ResumeEmulation() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
    SurfaceInfo surface;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        core = real_core_.get();
        if (!core || runtime_.state != RuntimeState::Paused) {
            return false;
        }
        if (!runtime_.surface.ready || !runtime_.surface.native_window) {
            runtime_.backend_status = "azahar_core_no_surface";
            return false;
        }
        surface = runtime_.surface;
    }

    core->OnSurfaceChanged(static_cast<OHNativeWindow*>(surface.native_window),
                           static_cast<int>(surface.width), static_cast<int>(surface.height));
    const bool resumed = core->Resume();
    std::lock_guard<std::mutex> lock(mutex_);
    runtime_.backend_status = core->GetStatus();
    if (resumed) {
        runtime_.state = RuntimeState::Running;
    }
    return resumed;
#else
    std::lock_guard<std::mutex> lock(mutex_);
    if (runtime_.state != RuntimeState::Paused) {
        return false;
    }
    runtime_.state = RuntimeState::Running;
    return true;
#endif
}

bool CoreBridge::DoFrame() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        core = real_core_.get();
        if (!core || runtime_.state != RuntimeState::Running) {
            return false;
        }
    }
    return core->PresentFrame();
#else
    return false;
#endif
}

bool CoreBridge::StopEmulation() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    // AzaharPlus: clear the running program id and consume queued ZipPass data.
    Loader::resetProgramId();
    Core::importQueuedZipPass();
    AzaharCoreRuntime* core = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        core = real_core_.get();
    }
    if (core) {
        core->Stop();
    }
    std::lock_guard<std::mutex> lock(mutex_);
    runtime_.state = runtime_.loaded_path.empty() ? RuntimeState::Stopped : RuntimeState::Loaded;
    runtime_.backend_status = core ? core->GetStatus() : runtime_.backend_status;
    return true;
#else
    std::lock_guard<std::mutex> lock(mutex_);
    runtime_.state = runtime_.loaded_path.empty() ? RuntimeState::Stopped : RuntimeState::Loaded;
    return true;
#endif
}

bool CoreBridge::ResetEmulation() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        core = real_core_.get();
        if (!core || runtime_.loaded_path.empty()) {
            return false;
        }
    }
    if (!core->Reset()) {
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        runtime_.backend_status = core->GetStatus();
        if (runtime_.state != RuntimeState::Paused) {
            runtime_.state = RuntimeState::Running;
            return true;
        }
    }
    // 暂停中的 RequestReset 会一直挂起在 RunLoop：走 ResumeEmulation 恢复执行使其生效
    //（对齐 nds resetEmulation 原生内嵌 pause→reset→resume，且保持 state 真实反映运行状态）
    return ResumeEmulation();
#else
    std::lock_guard<std::mutex> lock(mutex_);
    if (runtime_.loaded_path.empty()) {
        return false;
    }
    runtime_.state = RuntimeState::Running;
    return true;
#endif
}

bool CoreBridge::IsRunning() const {
    std::lock_guard<std::mutex> lock(mutex_);
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (real_core_) {
        return real_core_->IsRunning();
    }
#endif
    return runtime_.state == RuntimeState::Running;
}

bool CoreBridge::IsPaused() const {
    std::lock_guard<std::mutex> lock(mutex_);
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (real_core_) {
        return real_core_->IsPaused();
    }
#endif
    return runtime_.state == RuntimeState::Paused;
}

bool CoreBridge::SendTouchEvent(double x, double y, int32_t action) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
#endif
    {
        std::lock_guard<std::mutex> lock(mutex_);
        config_["last_touch_x"] = x;
        config_["last_touch_y"] = y;
        config_["last_touch_action"] = static_cast<double>(action);
#if AZAHAR_OHOS_CORE_AVAILABLE
        core = real_core_.get();
#endif
    }
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (core && core->IsRunning()) {
        return core->SendTouchEvent(x, y, action);
    }
#endif
    return true;
}

bool CoreBridge::SendKeyEvent(int32_t key, bool is_down) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        config_["last_key"] = static_cast<double>(key);
        config_["last_key_down"] = is_down;
    }
#if AZAHAR_OHOS_CORE_AVAILABLE
    return Input::SetButtonState(key, is_down);
#else
    return true;
#endif
}

bool CoreBridge::SendAnalogEvent(int32_t analog, double x, double y) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        config_["last_analog"] = static_cast<double>(analog);
        config_["last_analog_x"] = x;
        config_["last_analog_y"] = y;
    }
#if AZAHAR_OHOS_CORE_AVAILABLE
    // 前端（触摸屏坐标系/OH_GamePad 轴）y 向下为正；core 约定 +y = 上，
    // 与 Android onGamePadMoveEvent 的 -y 取反对齐
    return Input::SetAnalogState(analog, static_cast<float>(x), static_cast<float>(-y));
#else
    return true;
#endif
}

bool CoreBridge::SetShellOpen(bool open) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    auto& system = Core::System::GetInstance();
    // service_manager 仅在核心完成 Init 后存在；未开机时 ServiceManager() 是空引用
    if (!system.IsPoweredOn()) {
        return false;
    }
    auto ptm = system.ServiceManager().GetService<Service::PTM::Module::Interface>("ptm:u");
    if (!ptm) {
        return false;
    }
    ptm->GetModule()->SetShellOpen(open);
    return true;
#else
    return false;
#endif
}

bool CoreBridge::IsShellOpen() const {
#if AZAHAR_OHOS_CORE_AVAILABLE
    auto& system = Core::System::GetInstance();
    // service_manager 仅在核心完成 Init 后存在；未开机时 ServiceManager() 是空引用
    if (!system.IsPoweredOn()) {
        return true;
    }
    auto ptm = system.ServiceManager().GetService<Service::PTM::Module::Interface>("ptm:u");
    return ptm ? ptm->GetModule()->IsShellOpen() : true;
#else
    return true;
#endif
}

int32_t CoreBridge::GetSystemSleepState() const {
#if AZAHAR_OHOS_CORE_AVAILABLE
    auto& system = Core::System::GetInstance();
    if (!system.IsPoweredOn()) {
        return 0;
    }
    auto apt = Service::APT::GetModule(system);
    auto manager = apt ? apt->GetAppletManager() : nullptr;
    return manager ? static_cast<int32_t>(manager->GetSleepState()) : 0;
#else
    return 0;
#endif
}

bool CoreBridge::SaveState(int32_t slot) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        config_["last_save_slot"] = static_cast<double>(slot);
        core = real_core_.get();
    }
    return core ? core->SaveState(slot) : false;
#else
    std::lock_guard<std::mutex> lock(mutex_);
    config_["last_save_slot"] = static_cast<double>(slot);
    return false;
#endif
}

bool CoreBridge::LoadState(int32_t slot) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        config_["last_load_slot"] = static_cast<double>(slot);
        core = real_core_.get();
    }
    return core ? core->LoadState(slot) : false;
#else
    std::lock_guard<std::mutex> lock(mutex_);
    config_["last_load_slot"] = static_cast<double>(slot);
    return false;
#endif
}

bool CoreBridge::DeleteSaveState(int32_t slot) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        core = real_core_.get();
    }
    return core ? core->DeleteSaveState(slot) : false;
#else
    return false;
#endif
}

bool CoreBridge::HasUndoSaveState(int32_t slot) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        core = real_core_.get();
    }
    return core ? core->HasUndoSaveState(slot) : false;
#else
    return false;
#endif
}

bool CoreBridge::UndoSaveState(int32_t slot) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        core = real_core_.get();
    }
    return core ? core->UndoSaveState(slot) : false;
#else
    return false;
#endif
}

std::vector<SaveStateSlotInfo> CoreBridge::ListSaveStates(int32_t max_slot) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        core = real_core_.get();
    }
    return core ? core->ListSaveStates(max_slot) : std::vector<SaveStateSlotInfo> {};
#else
    return {};
#endif
}

bool CoreBridge::CaptureScreenshot(const std::string& path, int32_t resolution_scale) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        config_["last_screenshot_path"] = path;
        config_["last_screenshot_resolution_scale"] = static_cast<double>(resolution_scale);
        core = real_core_.get();
    }
    return core ? core->CaptureScreenshot(path, resolution_scale) : false;
#else
    return false;
#endif
}

int32_t CoreBridge::InstallCIA(const std::string& path) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    std::string files_dir;
    std::string cache_dir;
    std::string user_dir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        files_dir = files_dir_;
        cache_dir = cache_dir_;
        user_dir = user_dir_;
        config_["cia_install_total"] = 0.0;
        config_["cia_install_done"] = 0.0;
    }

    ApplyRuntimePaths(files_dir, cache_dir, user_dir);
    const auto status = Service::AM::InstallCIA(
        path, [this](std::size_t total_bytes_read, std::size_t file_size) {
            std::lock_guard<std::mutex> lock(mutex_);
            config_["cia_install_total"] = static_cast<double>(file_size);
            config_["cia_install_done"] = static_cast<double>(total_bytes_read);
        });
    return static_cast<int32_t>(status);
#else
    return 1;
#endif
}

std::vector<std::string> CoreBridge::GetInstalledGamePaths() const {
    std::vector<std::string> games;
#if AZAHAR_OHOS_CORE_AVAILABLE
    std::string files_dir;
    std::string cache_dir;
    std::string user_dir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        files_dir = files_dir_;
        cache_dir = cache_dir_;
        user_dir = user_dir_;
    }
    ApplyRuntimePaths(files_dir, cache_dir, user_dir);

    const auto scan_dir = [&games](const std::string& root, int media_type) {
        const FileUtil::DirectoryEntryCallable scan = [&games, &scan, media_type](
            u64*, const std::string& directory, const std::string& virtual_name) {
            std::string path = directory + virtual_name;
            if (FileUtil::IsDirectory(path)) {
                path += '/';
                FileUtil::ForeachDirectoryEntry(nullptr, path, scan);
                return true;
            }
            if (!FileUtil::Exists(path)) {
                return false;
            }

            std::unique_ptr<Loader::AppLoader> loader = Loader::GetLoader(path);
            if (!loader) {
                return true;
            }

            bool executable = false;
            const Loader::ResultStatus result = loader->IsExecutable(executable);
            if (result == Loader::ResultStatus::Success && executable) {
                games.emplace_back(path + "|" + std::to_string(media_type));
            }
            return true;
        };

        if (FileUtil::Exists(root)) {
            scan(nullptr, "", root);
        }
    };

    scan_dir(FileUtil::GetUserPath(FileUtil::UserPath::SDMCDir) +
             "Nintendo 3DS/00000000000000000000000000000000/"
             "00000000000000000000000000000000/title/00040000",
             1);
    scan_dir(FileUtil::GetUserPath(FileUtil::UserPath::SDMCDir) +
             "Nintendo 3DS/00000000000000000000000000000000/"
             "00000000000000000000000000000000/title/00040002",
             1);
    scan_dir(FileUtil::GetUserPath(FileUtil::UserPath::NANDDir) +
             "00000000000000000000000000000000/title/00040010",
             0);
#endif
    return games;
}

std::vector<CheatInfo> CoreBridge::ListCheats(const std::string& title_id) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    const auto parsed_title_id = ParseTitleId(title_id);
    if (!parsed_title_id.has_value()) {
        return {};
    }

    std::string files_dir;
    std::string cache_dir;
    std::string user_dir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        files_dir = files_dir_;
        cache_dir = cache_dir_;
        user_dir = user_dir_;
    }
    ApplyRuntimePaths(files_dir, cache_dir, user_dir);

    auto& engine = Core::System::GetInstance().CheatEngine();
    engine.LoadCheatFile(*parsed_title_id);
    const auto cheats = engine.GetCheats();

    std::vector<CheatInfo> result;
    result.reserve(cheats.size());
    for (std::size_t index = 0; index < cheats.size(); ++index) {
        const auto& cheat = cheats[index];
        if (!cheat) {
            continue;
        }
        CheatInfo info;
        info.index = static_cast<int32_t>(index);
        info.name = cheat->GetName();
        info.notes = cheat->GetComments();
        info.code = cheat->GetCode();
        info.type = cheat->GetType();
        info.enabled = cheat->IsEnabled();
        result.push_back(std::move(info));
    }
    return result;
#else
    return {};
#endif
}

bool CoreBridge::SetCheatEnabled(const std::string& title_id, int32_t index, bool enabled) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    const auto parsed_title_id = ParseTitleId(title_id);
    if (!parsed_title_id.has_value() || index < 0) {
        return false;
    }

    std::string files_dir;
    std::string cache_dir;
    std::string user_dir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        files_dir = files_dir_;
        cache_dir = cache_dir_;
        user_dir = user_dir_;
    }
    ApplyRuntimePaths(files_dir, cache_dir, user_dir);

    auto& engine = Core::System::GetInstance().CheatEngine();
    engine.LoadCheatFile(*parsed_title_id);
    const auto cheats = engine.GetCheats();
    const auto cheat_index = static_cast<std::size_t>(index);
    if (cheat_index >= cheats.size() || !cheats[cheat_index]) {
        return false;
    }

    cheats[cheat_index]->SetEnabled(enabled);
    engine.SaveCheatFile(*parsed_title_id);
    return true;
#else
    return false;
#endif
}

bool CoreBridge::UpsertGatewayCheat(const std::string& title_id, int32_t index,
                                    const std::string& name, const std::string& notes,
                                    const std::string& code, bool enabled) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    const auto parsed_title_id = ParseTitleId(title_id);
    if (!parsed_title_id.has_value() || name.empty() || code.empty() ||
        ValidateGatewayCheatCode(code) != 0) {
        return false;
    }

    std::string files_dir;
    std::string cache_dir;
    std::string user_dir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        files_dir = files_dir_;
        cache_dir = cache_dir_;
        user_dir = user_dir_;
    }
    ApplyRuntimePaths(files_dir, cache_dir, user_dir);

    auto cheat = std::make_shared<Cheats::GatewayCheat>(name, code, notes);
    cheat->SetEnabled(enabled);

    auto& engine = Core::System::GetInstance().CheatEngine();
    engine.LoadCheatFile(*parsed_title_id);
    if (index < 0) {
        engine.AddCheat(std::move(cheat));
    } else {
        const auto cheats = engine.GetCheats();
        const auto cheat_index = static_cast<std::size_t>(index);
        if (cheat_index >= cheats.size()) {
            return false;
        }
        engine.UpdateCheat(cheat_index, std::move(cheat));
    }
    engine.SaveCheatFile(*parsed_title_id);
    return true;
#else
    return false;
#endif
}

bool CoreBridge::RemoveCheat(const std::string& title_id, int32_t index) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    const auto parsed_title_id = ParseTitleId(title_id);
    if (!parsed_title_id.has_value() || index < 0) {
        return false;
    }

    std::string files_dir;
    std::string cache_dir;
    std::string user_dir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        files_dir = files_dir_;
        cache_dir = cache_dir_;
        user_dir = user_dir_;
    }
    ApplyRuntimePaths(files_dir, cache_dir, user_dir);

    auto& engine = Core::System::GetInstance().CheatEngine();
    engine.LoadCheatFile(*parsed_title_id);
    const auto cheats = engine.GetCheats();
    const auto cheat_index = static_cast<std::size_t>(index);
    if (cheat_index >= cheats.size()) {
        return false;
    }

    engine.RemoveCheat(cheat_index);
    engine.SaveCheatFile(*parsed_title_id);
    return true;
#else
    return false;
#endif
}

bool CoreBridge::ImportCheats(const std::string& title_id, const std::string& contents) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    const auto parsed_title_id = ParseTitleId(title_id);
    if (!parsed_title_id.has_value() || contents.empty()) {
        return false;
    }

    auto imported = Cheats::GatewayCheat::LoadString(contents);
    if (imported.empty()) {
        return false;
    }
    for (const auto& cheat : imported) {
        if (!cheat || ValidateGatewayCheatCode(cheat->GetCode()) != 0) {
            return false;
        }
        // Imported entries always start disabled; an enable marker in the source
        // file must not silently activate a cheat in the current game.
        cheat->SetEnabled(false);
    }

    std::string files_dir;
    std::string cache_dir;
    std::string user_dir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        files_dir = files_dir_;
        cache_dir = cache_dir_;
        user_dir = user_dir_;
    }
    ApplyRuntimePaths(files_dir, cache_dir, user_dir);

    auto& engine = Core::System::GetInstance().CheatEngine();
    engine.LoadCheatFile(*parsed_title_id);
    for (auto& cheat : imported) {
        engine.AddCheat(std::move(cheat));
    }
    engine.SaveCheatFile(*parsed_title_id);
    return true;
#else
    return false;
#endif
}

int32_t CoreBridge::ValidateGatewayCheatCode(const std::string& code) const {
#if AZAHAR_OHOS_CORE_AVAILABLE
    const auto code_lines = Common::SplitString(code, '\n');
    bool has_code_line = false;
    for (std::size_t i = 0; i < code_lines.size(); ++i) {
        if (code_lines[i].empty()) {
            continue;
        }
        has_code_line = true;
        Cheats::GatewayCheat::CheatLine cheat_line(code_lines[i]);
        if (!cheat_line.valid) {
            return static_cast<int32_t>(i + 1);
        }
    }
    return has_code_line ? 0 : 1;
#else
    return 1;
#endif
}

bool CoreBridge::HasGamePerfHacks(const std::string& title_id) const {
#if AZAHAR_OHOS_CORE_AVAILABLE
    const auto parsed_title_id = ParseTitleId(title_id);
    if (!parsed_title_id.has_value()) {
        return false;
    }
    // 与 ApplyPerProgramHacks 口径一致：perf quirk 只有 FORCE 条目才会被应用
    for (const auto& [type, entry] : Common::Hacks::hack_manager.entries) {
        if (!Common::Hacks::IsPerfQuirk(type) ||
            entry.mode != Common::Hacks::HackAllowMode::FORCE) {
            continue;
        }
        if (std::find(entry.affected_title_ids.begin(), entry.affected_title_ids.end(),
                      *parsed_title_id) != entry.affected_title_ids.end()) {
            return true;
        }
    }
#endif
    return false;
}

bool CoreBridge::IsSearchingForAmiibo() const {
#if AZAHAR_OHOS_CORE_AVAILABLE
    auto& service_manager = Core::System::GetInstance().ServiceManager();
    auto nfc = service_manager.GetService<Service::NFC::Module::Interface>("nfc:u");
    return nfc ? nfc->IsSearchingForAmiibos() : false;
#else
    return false;
#endif
}

bool CoreBridge::LoadAmiibo(const std::string& path) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (path.empty()) {
        return false;
    }
    auto& service_manager = Core::System::GetInstance().ServiceManager();
    auto nfc = service_manager.GetService<Service::NFC::Module::Interface>("nfc:u");
    return nfc ? nfc->LoadAmiibo(path) : false;
#else
    return false;
#endif
}

bool CoreBridge::MakeAmiiboFile(const std::string& id, const std::string& path) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    return Service::NFC::makeAmiiboFile(id, path);
#else
    return false;
#endif
}

int CoreBridge::ZipPassExport(const std::string& path) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    return Core::exportZipPass(path);
#else
    return -1;
#endif
}

int CoreBridge::ZipPassImport(const std::string& path) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    return Core::importZipPass(path);
#else
    return -1;
#endif
}

int CoreBridge::ZipPassImportQueued() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    return Core::importQueuedZipPass();
#else
    return -1;
#endif
}

int CoreBridge::ZipPassClearStreetPass() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    return Core::clearStreetPassConfig();
#else
    return -1;
#endif
}

bool CoreBridge::RemoveAmiibo() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    auto& service_manager = Core::System::GetInstance().ServiceManager();
    auto nfc = service_manager.GetService<Service::NFC::Module::Interface>("nfc:u");
    if (!nfc) {
        return false;
    }
    nfc->RemoveAmiibo();
    return true;
#else
    return false;
#endif
}

std::vector<MultiplayerRoomInfo> CoreBridge::ListMultiplayerRooms() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    std::unordered_map<std::string, ConfigValue> config;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        config = config_;
    }
    ApplyNetworkConfig(config);

    Network::AnnounceMultiplayerSession session{"Azahar"};
    const AnnounceMultiplayerRoom::RoomList rooms = session.GetRoomList();

    std::vector<MultiplayerRoomInfo> result;
    result.reserve(rooms.size());
    for (const auto& room : rooms) {
        MultiplayerRoomInfo info;
        info.id = room.id;
        info.name = room.name;
        info.description = room.description;
        info.owner = room.owner;
        info.address = room.ip;
        info.port = room.port;
        info.max_players = room.max_player;
        info.member_count = static_cast<uint32_t>(room.members.size());
        info.net_version = room.net_version;
        info.has_password = room.has_password;
        info.preferred_game = room.preferred_game;
        info.preferred_game_id = TitleIdToString(room.preferred_game_id);
        result.push_back(std::move(info));
    }
    return result;
#else
    return {};
#endif
}

// 与 Android NetPlayStatus 兼容的错误码，ArkTS 侧按值映射错误文案
enum OhosNetPlayStatus : int32_t {
    NETPLAY_NO_ERROR = 0,
    NETPLAY_NETWORK_ERROR = 1,
    NETPLAY_LOST_CONNECTION = 2,
    NETPLAY_NAME_COLLISION = 3,
    NETPLAY_MAC_COLLISION = 4,
    NETPLAY_CONSOLE_ID_COLLISION = 5,
    NETPLAY_WRONG_VERSION = 6,
    NETPLAY_WRONG_PASSWORD = 7,
    NETPLAY_COULD_NOT_CONNECT = 8,
    NETPLAY_ROOM_IS_FULL = 9,
    NETPLAY_HOST_BANNED = 10,
    NETPLAY_PERMISSION_DENIED = 11,
    NETPLAY_NO_SUCH_USER = 12,
    NETPLAY_ALREADY_IN_ROOM = 13,
    NETPLAY_CREATE_ROOM_ERROR = 14,
    NETPLAY_HOST_KICKED = 15,
    NETPLAY_UNKNOWN_ERROR = 16,
};

void CoreBridge::PushMultiplayerEvent(const std::string& event) {
    std::lock_guard<std::mutex> lock(multiplayer_mutex_);
    constexpr size_t kMaxQueuedEvents = 512;
    if (multiplayer_events_.size() >= kMaxQueuedEvents) {
        multiplayer_events_.pop_front();
    }
    multiplayer_events_.push_back(event);
}

void CoreBridge::BindMultiplayerCallbacks(const std::shared_ptr<Network::RoomMember>& member) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (!member || multiplayer_bound_member_.lock() == member) {
        return;
    }
    multiplayer_bound_member_ = member;

    member->BindOnStateChanged([this](const Network::RoomMember::State& state) {
        if (state == Network::RoomMember::State::Joined) {
            PushMultiplayerEvent("joined");
        } else if (state == Network::RoomMember::State::Moderator) {
            PushMultiplayerEvent("moderator");
        }
    });
    member->BindOnError([this](const Network::RoomMember::Error& error) {
        int32_t code = NETPLAY_UNKNOWN_ERROR;
        switch (error) {
        case Network::RoomMember::Error::LostConnection:
            code = NETPLAY_LOST_CONNECTION;
            break;
        case Network::RoomMember::Error::HostKicked:
            code = NETPLAY_HOST_KICKED;
            break;
        case Network::RoomMember::Error::UnknownError:
            code = NETPLAY_UNKNOWN_ERROR;
            break;
        case Network::RoomMember::Error::NameCollision:
            code = NETPLAY_NAME_COLLISION;
            break;
        case Network::RoomMember::Error::MacCollision:
            code = NETPLAY_MAC_COLLISION;
            break;
        case Network::RoomMember::Error::WrongVersion:
            code = NETPLAY_WRONG_VERSION;
            break;
        case Network::RoomMember::Error::WrongPassword:
            code = NETPLAY_WRONG_PASSWORD;
            break;
        case Network::RoomMember::Error::CouldNotConnect:
            code = NETPLAY_COULD_NOT_CONNECT;
            break;
        case Network::RoomMember::Error::RoomIsFull:
            code = NETPLAY_ROOM_IS_FULL;
            break;
        case Network::RoomMember::Error::HostBanned:
            code = NETPLAY_HOST_BANNED;
            break;
        case Network::RoomMember::Error::PermissionDenied:
            code = NETPLAY_PERMISSION_DENIED;
            break;
        case Network::RoomMember::Error::NoSuchUser:
            code = NETPLAY_NO_SUCH_USER;
            break;
        case Network::RoomMember::Error::ConsoleIdCollision:
            code = NETPLAY_CONSOLE_ID_COLLISION;
            break;
        }
        PushMultiplayerEvent("error|" + std::to_string(code));
    });
    member->BindOnStatusMessageReceived([this](const Network::StatusMessageEntry& entry) {
        switch (entry.type) {
        case Network::IdMemberJoin:
            PushMultiplayerEvent("member_join|" + entry.nickname);
            break;
        case Network::IdMemberLeave:
            PushMultiplayerEvent("member_leave|" + entry.nickname);
            break;
        case Network::IdMemberKicked:
            PushMultiplayerEvent("member_kicked|" + entry.nickname);
            break;
        case Network::IdMemberBanned:
            PushMultiplayerEvent("member_banned|" + entry.nickname);
            break;
        case Network::IdAddressUnbanned:
            PushMultiplayerEvent("address_unbanned|" + entry.nickname);
            break;
        default:
            break;
        }
    });
    member->BindOnChatMessageRecieved([this](const Network::ChatEntry& chat) {
        PushMultiplayerEvent("chat|" + chat.nickname + "|" + chat.message);
    });
#endif
}

bool CoreBridge::EnsureMultiplayerNetwork() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (auto member = Network::GetRoomMember().lock()) {
        BindMultiplayerCallbacks(member);
        return true;
    }
    if (!Network::Init()) {
        return false;
    }
    if (auto member = Network::GetRoomMember().lock()) {
        BindMultiplayerCallbacks(member);
        return true;
    }
#endif
    return false;
}

int32_t CoreBridge::MultiplayerJoinRoom(const std::string& address, int32_t port,
                                        const std::string& username, const std::string& password) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (!EnsureMultiplayerNetwork()) {
        return NETPLAY_NETWORK_ERROR;
    }
    auto member = Network::GetRoomMember().lock();
    if (!member) {
        return NETPLAY_NETWORK_ERROR;
    }
    if (member->GetState() == Network::RoomMember::State::Joining || member->IsConnected()) {
        return NETPLAY_ALREADY_IN_ROOM;
    }
    member->Join(username, Service::CFG::GetConsoleIdHash(Core::System::GetInstance()),
                 address.c_str(), static_cast<u16>(port), 0, Network::NoPreferredMac, password);
    // 与 Android 相同的等待窗口：连接握手与加入过程最多 500ms
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    if (member->GetState() == Network::RoomMember::State::Joined ||
        member->GetState() == Network::RoomMember::State::Moderator) {
        return NETPLAY_NO_ERROR;
    }
    if (!member->IsConnected()) {
        return NETPLAY_COULD_NOT_CONNECT;
    }
    return NETPLAY_WRONG_PASSWORD;
#else
    return NETPLAY_NETWORK_ERROR;
#endif
}

int32_t CoreBridge::MultiplayerCreateRoom(const std::string& address, int32_t port,
                                          const std::string& username,
                                          const std::string& game_name, int64_t game_id,
                                          const std::string& password,
                                          const std::string& room_name, int32_t max_players) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (!EnsureMultiplayerNetwork()) {
        return NETPLAY_NETWORK_ERROR;
    }
    auto member = Network::GetRoomMember().lock();
    auto room = Network::GetRoom().lock();
    if (!member || !room) {
        return NETPLAY_NETWORK_ERROR;
    }
    if (member->GetState() == Network::RoomMember::State::Joining || member->IsConnected()) {
        return NETPLAY_ALREADY_IN_ROOM;
    }
    if (room_name.length() < 3 || room_name.length() > 20) {
        return NETPLAY_CREATE_ROOM_ERROR;
    }
    if (!room->Create(room_name, "", address, static_cast<u16>(port), password,
                      static_cast<unsigned int>(std::min<int32_t>(max_players, 16)), username,
                      game_name, static_cast<u64>(game_id),
                      std::make_unique<Network::VerifyUser::NullBackend>(), {})) {
        return NETPLAY_CREATE_ROOM_ERROR;
    }
    // 与 Android 一致：创建后再以成员身份加入自己开的房间
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    member->Join(username, Service::CFG::GetConsoleIdHash(Core::System::GetInstance()),
                 address.c_str(), static_cast<u16>(port), 0, Network::NoPreferredMac, password);
    for (int i = 0; i < 5; i++) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        if (member->GetState() == Network::RoomMember::State::Joined ||
            member->GetState() == Network::RoomMember::State::Moderator) {
            return NETPLAY_NO_ERROR;
        }
    }
    room->Destroy();
    return NETPLAY_CREATE_ROOM_ERROR;
#else
    return NETPLAY_NETWORK_ERROR;
#endif
}

void CoreBridge::MultiplayerLeaveRoom() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    Core::importQueuedZipPass();
    if (auto room = Network::GetRoom().lock()) {
        if (auto member = Network::GetRoomMember().lock()) {
            member->Leave();
        }
        if (room->GetState() == Network::Room::State::Open) {
            room->Destroy();
        }
    }
    PushMultiplayerEvent("chat_cleared");
#endif
}

MultiplayerSessionInfo CoreBridge::GetMultiplayerSessionInfo() {
    MultiplayerSessionInfo info;
#if AZAHAR_OHOS_CORE_AVAILABLE
    auto member = Network::GetRoomMember().lock();
    if (!member) {
        return info;
    }
    info.initialized = true;
    info.joined = member->GetState() == Network::RoomMember::State::Joined ||
                  member->GetState() == Network::RoomMember::State::Moderator;
    info.moderator = member->GetState() == Network::RoomMember::State::Moderator;
    if (auto room = Network::GetRoom().lock()) {
        info.hosting = room->GetState() == Network::Room::State::Open;
        if (info.hosting) {
            const auto ban_list = room->GetBanList();
            info.username_bans = ban_list.first;
        }
    }
    const auto members = member->GetMemberInformation();
    if (!members.empty()) {
        const auto room_info = member->GetRoomInformation();
        info.room_name = room_info.name;
        info.member_slots = static_cast<int32_t>(room_info.member_slots);
        info.members.reserve(members.size());
        for (const auto& entry : members) {
            MultiplayerMemberInfo m;
            m.nickname = entry.nickname;
            m.username = entry.username;
            m.game_name = entry.game_info.name;
            info.members.push_back(std::move(m));
        }
    }
#endif
    return info;
}

void CoreBridge::MultiplayerKickUser(const std::string& username) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (auto member = Network::GetRoomMember().lock()) {
        member->SendModerationRequest(Network::RoomMessageTypes::IdModKick, username);
    }
#endif
}

void CoreBridge::MultiplayerBanUser(const std::string& username) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (auto member = Network::GetRoomMember().lock()) {
        member->SendModerationRequest(Network::RoomMessageTypes::IdModBan, username);
    }
#endif
}

void CoreBridge::MultiplayerUnbanUser(const std::string& username) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (auto member = Network::GetRoomMember().lock()) {
        member->SendModerationRequest(Network::RoomMessageTypes::IdModUnban, username);
    }
#endif
}

void CoreBridge::MultiplayerSendChatMessage(const std::string& message) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (auto member = Network::GetRoomMember().lock()) {
        if (member->GetState() == Network::RoomMember::State::Joined ||
            member->GetState() == Network::RoomMember::State::Moderator) {
            member->SendChatMessage(message);
        }
    }
#endif
}

std::vector<std::string> CoreBridge::PollMultiplayerEvents() {
    std::lock_guard<std::mutex> lock(multiplayer_mutex_);
    std::vector<std::string> out(multiplayer_events_.begin(), multiplayer_events_.end());
    multiplayer_events_.clear();
    return out;
}

SystemProfile CoreBridge::GetSystemProfile() {
    SystemProfile profile;
#if AZAHAR_OHOS_CORE_AVAILABLE
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!runtime_.initialized) {
            return profile;
        }
    }

    auto& system = Core::System::GetInstance();
    auto cfg = Service::CFG::GetModule(system);
    if (!cfg) {
        return profile;
    }

    profile.available = true;
    profile.username = Common::UTF16ToUTF8(cfg->GetUsername());
    const auto [month, day] = cfg->GetBirthday();
    profile.birth_month = month;
    profile.birth_day = day;
    profile.language = static_cast<uint8_t>(cfg->GetSystemLanguage());
    profile.sound_output_mode = static_cast<uint8_t>(cfg->GetSoundOutputMode());
    profile.country_code = cfg->GetCountryCode();
    profile.system_setup_needed = cfg->IsSystemSetupNeeded();
    profile.play_coins = Service::PTM::Module::GetPlayCoins();
    profile.mac_address = cfg->GetMacAddress();
    profile.console_id = cfg->GetConsoleUniqueId();
#endif
    return profile;
}

bool CoreBridge::SetSystemProfile(const SystemProfile& profile) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!runtime_.initialized) {
            return false;
        }
    }

    auto& system = Core::System::GetInstance();
    auto cfg = Service::CFG::GetModule(system);
    if (!cfg) {
        return false;
    }

    std::u16string username = Common::UTF8ToUTF16(profile.username);
    if (username.size() > 10) {
        username.resize(10);
    }
    cfg->SetUsername(username);
    cfg->SetBirthday(static_cast<uint8_t>(std::clamp<int>(profile.birth_month, 1, 12)),
                     static_cast<uint8_t>(std::clamp<int>(profile.birth_day, 1, 31)));
    cfg->SetSystemLanguage(
        static_cast<Service::CFG::SystemLanguage>(std::clamp<int>(profile.language, 0, 11)));
    cfg->SetSoundOutputMode(static_cast<Service::CFG::SoundOutputMode>(
        std::clamp<int>(profile.sound_output_mode, 0, 2)));
    cfg->SetCountryCode(static_cast<uint8_t>(std::clamp<int>(profile.country_code, 0, 186)));
    cfg->SetSystemSetupNeeded(profile.system_setup_needed);
    cfg->UpdateConfigNANDSavegame();

    Service::PTM::Module::SetPlayCoins(std::min<uint16_t>(profile.play_coins, 300));

    const std::string mac = NormalizeMacAddress(profile.mac_address);
    if (!mac.empty()) {
        cfg->GetMacAddress() = mac;
        cfg->SaveMacAddress();
    }
    return true;
#else
    return false;
#endif
}

std::string CoreBridge::RegenerateConsoleId() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!runtime_.initialized) {
            return "";
        }
    }

    auto& system = Core::System::GetInstance();
    auto cfg = Service::CFG::GetModule(system);
    if (!cfg) {
        return "";
    }
    const auto [random_number, console_id] = cfg->GenerateConsoleUniqueId();
    if (cfg->SetConsoleUniqueId(random_number, console_id).IsError()) {
        return "";
    }
    cfg->UpdateConfigNANDSavegame();
    char buf[24];
    std::snprintf(buf, sizeof(buf), "0x%016llX", static_cast<unsigned long long>(console_id));
    return buf;
#else
    return "";
#endif
}

std::string CoreBridge::RegenerateMacAddress() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!runtime_.initialized) {
            return "";
        }
    }

    auto& system = Core::System::GetInstance();
    auto cfg = Service::CFG::GetModule(system);
    if (!cfg) {
        return "";
    }
    cfg->GetMacAddress() = Service::CFG::GenerateRandomMAC();
    cfg->SaveMacAddress();
    return cfg->GetMacAddress();
#else
    return "";
#endif
}

int CoreBridge::GetCountryCompatibility(int region) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!runtime_.initialized) {
            return 0;
        }
    }

    auto& system = Core::System::GetInstance();
    auto cfg = Service::CFG::GetModule(system);
    if (!cfg) {
        return 0;
    }
    int result = 0;
    const u8 country = cfg->GetCountryCode();
    if (region != Settings::REGION_VALUE_AUTO_SELECT &&
        !Service::CFG::Module::IsValidRegionCountry(static_cast<u32>(region), country)) {
        result |= 1;
    }
    if (HW::UniqueData::GetSecureInfoA().IsValid()) {
        const u32 console_region = cfg->GetRegionValue(true);
        if (!Service::CFG::Module::IsValidRegionCountry(console_region, country)) {
            result |= 2;
        }
    }
    return result;
#else
    return 0;
#endif
}

SystemFilesStatus CoreBridge::GetSystemFilesStatus() {
    SystemFilesStatus status;
#if AZAHAR_OHOS_CORE_AVAILABLE
    std::string files_dir;
    std::string cache_dir;
    std::string user_dir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!runtime_.initialized) {
            return status;
        }
        files_dir = files_dir_;
        cache_dir = cache_dir_;
        user_dir = user_dir_;
    }
    ApplyRuntimePaths(files_dir, cache_dir, user_dir);
    const auto installed = Core::AreSystemTitlesInstalled();
    status.old3ds_installed = installed.first;
    status.new3ds_installed = installed.second;
#endif
    return status;
}

bool CoreBridge::UninstallSystemFiles(bool old3ds) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    std::string files_dir;
    std::string cache_dir;
    std::string user_dir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!runtime_.initialized) {
            return false;
        }
        files_dir = files_dir_;
        cache_dir = cache_dir_;
        user_dir = user_dir_;
    }
    ApplyRuntimePaths(files_dir, cache_dir, user_dir);
    Core::UninstallSystemFiles(old3ds ? Core::SystemTitleSet::Old3ds
                                      : Core::SystemTitleSet::New3ds);
    return true;
#else
    return false;
#endif
}

TitleContentStatus CoreBridge::GetTitleContentStatus(const std::string& title_id) {
    TitleContentStatus status;
#if AZAHAR_OHOS_CORE_AVAILABLE
    const auto parsed_title_id = ParseTitleId(title_id);
    if (!parsed_title_id.has_value()) {
        return status;
    }

    std::string files_dir;
    std::string cache_dir;
    std::string user_dir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!runtime_.initialized) {
            return status;
        }
        files_dir = files_dir_;
        cache_dir = cache_dir_;
        user_dir = user_dir_;
    }
    ApplyRuntimePaths(files_dir, cache_dir, user_dir);

    const u64 base_title_id = *parsed_title_id;
    const auto media_type = Service::AM::GetTitleMediaType(base_title_id);
    const u64 update_title_id = Service::AM::GetTitleUpdateId(base_title_id);
    const u64 dlc_title_id = base_title_id | 0x8C00000000ULL;

    status.application_path = Service::AM::GetTitlePath(media_type, base_title_id) + "content/";
    status.update_path =
        Service::AM::GetTitlePath(Service::FS::MediaType::SDMC, update_title_id) + "content/";
    status.dlc_path =
        Service::AM::GetTitlePath(Service::FS::MediaType::SDMC, dlc_title_id) + "content/";

    status.application_installed = FileUtil::Exists(status.application_path);
    status.update_installed = FileUtil::Exists(status.update_path);
    status.dlc_installed = FileUtil::Exists(status.dlc_path);
#endif
    return status;
}

bool CoreBridge::UninstallTitleContent(const std::string& title_id, int32_t content_kind) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    const auto parsed_title_id = ParseTitleId(title_id);
    if (!parsed_title_id.has_value() || content_kind < 0 || content_kind > 2) {
        return false;
    }

    std::string files_dir;
    std::string cache_dir;
    std::string user_dir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!runtime_.initialized) {
            return false;
        }
        files_dir = files_dir_;
        cache_dir = cache_dir_;
        user_dir = user_dir_;
    }
    ApplyRuntimePaths(files_dir, cache_dir, user_dir);

    const u64 base_title_id = *parsed_title_id;
    Service::FS::MediaType media_type = Service::AM::GetTitleMediaType(base_title_id);
    u64 target_title_id = base_title_id;
    if (content_kind == 1) {
        media_type = Service::FS::MediaType::SDMC;
        target_title_id = Service::AM::GetTitleUpdateId(base_title_id);
    } else if (content_kind == 2) {
        media_type = Service::FS::MediaType::SDMC;
        target_title_id = base_title_id | 0x8C00000000ULL;
    }

    return !Service::AM::UninstallProgram(media_type, target_title_id).IsError();
#else
    return false;
#endif
}

RomFsDumpResult CoreBridge::DumpRomFS(const std::string& path) {
    RomFsDumpResult result;
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (path.empty()) {
        result.base_status = static_cast<int32_t>(Loader::ResultStatus::ErrorNotFound);
        return result;
    }

    std::string files_dir;
    std::string cache_dir;
    std::string user_dir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!runtime_.initialized) {
            result.base_status = static_cast<int32_t>(Loader::ResultStatus::ErrorNotLoaded);
            return result;
        }
        files_dir = files_dir_;
        cache_dir = cache_dir_;
        user_dir = user_dir_;
    }
    ApplyRuntimePaths(files_dir, cache_dir, user_dir);

    std::unique_ptr<Loader::AppLoader> loader = Loader::GetLoader(path);
    if (!loader) {
        result.base_status = static_cast<int32_t>(Loader::ResultStatus::ErrorNotFound);
        return result;
    }

    u64 program_id = 0;
    const Loader::ResultStatus id_status = loader->ReadProgramId(program_id);
    if (id_status != Loader::ResultStatus::Success || program_id == 0) {
        result.base_status = static_cast<int32_t>(id_status);
        return result;
    }

    const std::string dump_root = FileUtil::GetUserPath(FileUtil::UserPath::DumpDir) + "romfs/";
    FileUtil::CreateFullPath(dump_root);
    result.base_path = dump_root + TitleIdToString(program_id);
    result.update_path = dump_root + TitleIdToString(Service::AM::GetTitleUpdateId(program_id));

    const Loader::ResultStatus base_status = loader->DumpRomFS(result.base_path);
    result.base_status = static_cast<int32_t>(base_status);
    if (base_status != Loader::ResultStatus::Success) {
        return result;
    }

    const Loader::ResultStatus update_status = loader->DumpUpdateRomFS(result.update_path);
    result.update_status = static_cast<int32_t>(update_status);
    result.success = true;
#endif
    return result;
}

MovieStatus CoreBridge::GetMovieStatus() const {
    MovieStatus status;
#if AZAHAR_OHOS_CORE_AVAILABLE
    const Core::Movie& movie = Core::System::GetInstance().Movie();
    status.mode = MoviePlayModeName(movie.GetPlayMode());
    status.current_input = movie.GetCurrentInputIndex();
    status.total_input = movie.GetTotalInputCount();
#endif
    return status;
}

MovieMetadata CoreBridge::GetMovieMetadata(const std::string& path) const {
    MovieMetadata result;
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (path.empty()) {
        return result;
    }

    const Core::Movie& movie = Core::System::GetInstance().Movie();
    const Core::Movie::ValidationResult validation_result = movie.ValidateMovie(path);
    result.validation_result = static_cast<int32_t>(validation_result);
    result.valid = validation_result != Core::Movie::ValidationResult::Invalid;
    if (!result.valid) {
        return result;
    }

    const Core::Movie::MovieMetadata metadata = movie.GetMovieMetadata(path);
    result.title_id = TitleIdToString(metadata.program_id);
    result.author = metadata.author;
    result.rerecord_count = metadata.rerecord_count;
    result.input_count = metadata.input_count;
#endif
    return result;
}

bool CoreBridge::SaveMovie() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    Core::Movie& movie = Core::System::GetInstance().Movie();
    if (movie.GetPlayMode() != Core::Movie::PlayMode::Recording) {
        return false;
    }
    movie.SaveMovie();
    return true;
#else
    return false;
#endif
}

bool CoreBridge::CloseMovie() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    Core::Movie& movie = Core::System::GetInstance().Movie();
    if (movie.GetPlayMode() == Core::Movie::PlayMode::None) {
        return false;
    }
    movie.Shutdown();
    return true;
#else
    return false;
#endif
}

bool CoreBridge::IsFullConsoleLinked() const {
#if AZAHAR_OHOS_CORE_AVAILABLE
    std::lock_guard<std::mutex> lock(mutex_);
    if (!runtime_.initialized) {
        return false;
    }
    return HW::UniqueData::IsFullConsoleLinked();
#else
    return false;
#endif
}

bool CoreBridge::UnlinkConsole() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    std::lock_guard<std::mutex> lock(mutex_);
    if (!runtime_.initialized || !HW::UniqueData::IsFullConsoleLinked()) {
        return false;
    }
    HW::UniqueData::UnlinkConsole();
    return !HW::UniqueData::IsFullConsoleLinked();
#else
    return false;
#endif
}

bool CoreBridge::SetConfig(const std::string& key, ConfigValue value) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (key == "use_shader_jit") {
        if (!std::holds_alternative<bool>(value)) {
            return false;
        }
        config_["use_shader_jit_requested"] = std::get<bool>(value);
        ApplyJitPolicyLocked();
        return true;
    }

    config_[key] = std::move(value);
    return true;
}

std::optional<ConfigValue> CoreBridge::GetConfig(const std::string& key) const {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto it = config_.find(key);
    if (it == config_.end()) {
        return std::nullopt;
    }
    return it->second;
}

bool CoreBridge::ApplyConfig() {
    std::unordered_map<std::string, ConfigValue> config;
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
#endif
    {
        std::lock_guard<std::mutex> lock(mutex_);
        EnsureDefaultConfigLocked();
        ApplyJitPolicyLocked();
        config = config_;
#if AZAHAR_OHOS_CORE_AVAILABLE
        core = real_core_.get();
#endif
    }
#if AZAHAR_OHOS_CORE_AVAILABLE
    // Gamepad mappings apply regardless of whether a game is running.
    Gamepad::ApplyConfig(config);
    if (core) {
        return core->ApplyConfig(config);
    }
#endif
    return true;
}

bool CoreBridge::SaveConfig() {
    return true;
}

bool CoreBridge::SetTemporaryFrameLimit(double speed) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    Settings::temporary_frame_limit = std::clamp(speed, 0.0, 1000.0);
    Settings::is_temporary_frame_limit = true;
#endif
    return true;
}

bool CoreBridge::DisableTemporaryFrameLimit() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    Settings::is_temporary_frame_limit = false;
#endif
    return true;
}

std::vector<double> CoreBridge::GetPerfStats() {
    std::vector<double> stats(17, 0.0);
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        core = real_core_.get();
    }
    if (core) {
        stats = core->GetPerfStats();
    }
#endif
    return stats;
}

std::vector<double> CoreBridge::GetScreenLayout() {
    std::lock_guard<std::mutex> lock(mutex_);
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (real_core_) {
        return real_core_->GetScreenLayout();
    }
#endif
    return {};
}

void CoreBridge::SetScreenOffsets(int32_t left, int32_t top, int32_t right, int32_t bottom) {
    std::lock_guard<std::mutex> lock(mutex_);
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (real_core_) {
        real_core_->SetScreenOffsets(left, top, right, bottom);
    }
#endif
}

void CoreBridge::SetCustomScreenRects(const std::array<double, 8>& rects) {
    std::lock_guard<std::mutex> lock(mutex_);
    runtime_.custom_screen_rects = rects;
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (real_core_) {
        const auto& r = rects;
        real_core_->SetCustomScreenRects(
            static_cast<int32_t>(r[0]), static_cast<int32_t>(r[1]),
            static_cast<int32_t>(r[2]), static_cast<int32_t>(r[3]),
            static_cast<int32_t>(r[4]), static_cast<int32_t>(r[5]),
            static_cast<int32_t>(r[6]), static_cast<int32_t>(r[7]));
    }
#endif
}

void CoreBridge::ClearCustomScreenRects() {
    std::lock_guard<std::mutex> lock(mutex_);
    runtime_.custom_screen_rects.reset();
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (real_core_) {
        real_core_->ClearCustomScreenRects();
    }
#endif
}

bool CoreBridge::UpdateDeviceProfile(std::string device_type, bool tablet_jit_user_enabled) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        runtime_.device_type = NormalizeDeviceType(std::move(device_type));
        tablet_jit_user_enabled_ = tablet_jit_user_enabled;
        config_["use_cpu_jit_requested"] = tablet_jit_user_enabled_;
        ApplyJitPolicyLocked();
    }
    // ApplyConfig 内部同样获取 mutex_，不能在持锁状态下调用；
    // 必须单独触发一次推送，否则 use_cpu_jit 只停留在暂存表不生效
    ApplyConfig();
    std::lock_guard<std::mutex> lock(mutex_);
    return runtime_.jit.available;
}

JitPolicy CoreBridge::EvaluateJitPolicy(const std::string& device_type,
                                        bool tablet_jit_user_enabled) const {
    JitPolicy policy;
    // JIT 权限在启动阶段一次性探测（手机/坚盾直接判负，否则试分配 WX 内存），
    // DetectJitSupport 内部已缓存结果，此处不产生额外探测开销
    policy.supported = OhosJitCapability::DetectJitSupport(NormalizeDeviceType(device_type));
    if (!policy.supported) {
        policy.reason = "jit_unsupported";
        return policy;
    }
    if (!tablet_jit_user_enabled) {
        policy.reason = "user_setting_disabled";
        return policy;
    }
    policy.available = true;
    policy.reason = "jit_enabled";
    return policy;
}

bool CoreBridge::IsJitSupported(const std::string& device_type) const {
    return OhosJitCapability::DetectJitSupport(NormalizeDeviceType(device_type));
}

bool CoreBridge::IsJitAvailable() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return runtime_.jit.available;
}

RuntimeInfo CoreBridge::GetRuntimeInfo() const {
    std::lock_guard<std::mutex> lock(mutex_);
    RuntimeInfo info = runtime_;
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (real_core_) {
        info.backend = CoreBackend::AzaharCore;
        info.backend_status = real_core_->GetStatus();
        if (real_core_->IsRunning()) {
            info.state = real_core_->IsPaused() ? RuntimeState::Paused : RuntimeState::Running;
        } else if (info.state == RuntimeState::Running || info.state == RuntimeState::Paused) {
            info.state = info.loaded_path.empty() ? RuntimeState::Stopped : RuntimeState::Loaded;
        }
    }
#endif
    return info;
}

AppInfo CoreBridge::GetAppInfo(const std::string& path) const {
    AppInfo info;
    info.path = path;
    const size_t slash = path.find_last_of("/\\");
    info.file_name = slash == std::string::npos ? path : path.substr(slash + 1);
    info.extension = ExtensionOf(path);
    info.supported = IsSupportedApplicationPath(path);
    return info;
}

GameMetadata CoreBridge::GetGameMetadata(const std::string& path) const {
    GameMetadata metadata;
    metadata.path = path;
    metadata.icon_status = "core_unavailable";

#if AZAHAR_OHOS_CORE_AVAILABLE
    metadata.icon_status = "not_checked";
    std::string files_dir;
    std::string cache_dir;
    std::string user_dir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        files_dir = files_dir_;
        cache_dir = cache_dir_;
        user_dir = user_dir_;
    }
    ApplyRuntimePaths(files_dir, cache_dir, user_dir);

    std::unique_ptr<Loader::AppLoader> loader = Loader::GetLoader(path);
    if (!loader) {
        metadata.icon_status = "loader_not_found";
        return metadata;
    }

    u64 program_id = 0;
    Loader::ResultStatus id_result = loader->ReadProgramId(program_id);
    if (id_result == Loader::ResultStatus::ErrorNotImplemented) {
        id_result = Loader::ResultStatus::Success;
    }
    if (id_result != Loader::ResultStatus::Success) {
        metadata.encrypted = id_result == Loader::ResultStatus::ErrorEncrypted;
        metadata.icon_status = "program_id_" + LoaderResultName(id_result);
        return metadata;
    }

    metadata.valid = true;
    metadata.title_id = TitleIdToString(program_id);
    metadata.file_type = Loader::GetFileTypeString(loader->GetFileType(), loader->IsFileCompressed());
    metadata.insertable = loader->GetFileType() == Loader::FileType::CCI;
    metadata.system_title = ((program_id >> 32) & 0xFFFFFFFF) == 0x00040010;

    std::string product_code;
    if (loader->ReadProductCode(product_code) == Loader::ResultStatus::Success) {
        metadata.product_code = std::move(product_code);
    }

    u64 extdata_id = 0;
    if (loader->ReadExtdataId(extdata_id) == Loader::ResultStatus::Success) {
        metadata.extdata_id = TitleIdToString(extdata_id);
    }

    std::vector<u8> smdh_data;
    Loader::ResultStatus icon_result = loader->ReadIcon(smdh_data, false);
    metadata.icon_status = "read_icon_" + LoaderResultName(icon_result);
    if (icon_result == Loader::ResultStatus::Success && program_id >= 0x0004000000000000 &&
        program_id <= 0x00040000FFFFFFFF) {
        const u64 update_tid = (program_id & 0xFFFFFFFFULL) | kUpdateTidHigh;
        const std::string update_path =
            Service::AM::GetTitleContentPath(Service::FS::MediaType::SDMC, update_tid);
        if (FileUtil::Exists(update_path)) {
            if (std::unique_ptr<Loader::AppLoader> update_loader = Loader::GetLoader(update_path)) {
                std::vector<u8> update_smdh;
                if (update_loader->ReadIcon(update_smdh, false) == Loader::ResultStatus::Success) {
                    smdh_data = std::move(update_smdh);
                    metadata.icon_status = "read_update_icon_success";
                }
            }
        }
    }

    if (icon_result != Loader::ResultStatus::Success && icon_result == Loader::ResultStatus::ErrorEncrypted) {
        metadata.encrypted = true;
    }
    if (!Loader::IsValidSMDH(smdh_data)) {
        metadata.icon_status += "_invalid_smdh";
        return metadata;
    }

    Loader::SMDH smdh;
    std::memcpy(&smdh, smdh_data.data(), sizeof(Loader::SMDH));
    constexpr Loader::SMDH::TitleLanguage language = Loader::SMDH::TitleLanguage::English;
    metadata.short_title = SmdhTextToUtf8(smdh.GetShortTitle(language));
    metadata.long_title = SmdhTextToUtf8(smdh.GetLongTitle(language));
    metadata.publisher = SmdhTextToUtf8(smdh.titles[static_cast<std::size_t>(language)].publisher);
    metadata.regions = RegionsToString(smdh);
    metadata.visible = smdh.flags.visible;

    const std::vector<u16> icon = smdh.GetIcon(true);
    if (!icon.empty()) {
        metadata.has_icon = true;
        metadata.icon_width = 48;
        metadata.icon_height = 48;
        metadata.icon_rgb565 = Rgb565ToBytes(icon);
        metadata.icon_rgba = Rgb565ToRgba(icon);
        metadata.icon_status = "ok";
    } else {
        metadata.icon_status = "empty_icon";
    }
#endif

    return metadata;
}

std::vector<std::string> CoreBridge::GetSupportedExtensions() const {
    return std::vector<std::string>(std::begin(kSupportedExtensions), std::end(kSupportedExtensions));
}

bool CoreBridge::IsAudioEnabled() const {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto it = config_.find("enable_realtime_audio");
    if (it != config_.end() && std::holds_alternative<bool>(it->second)) {
        return std::get<bool>(it->second);
    }
    return true;
}

bool CoreBridge::IsGraphicsEnabled() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return runtime_.surface.ready;
}

bool CoreBridge::RegisterXComponentId(std::string xcomponent_id) {
    std::lock_guard<std::mutex> lock(mutex_);
    runtime_.surface.xcomponent_id = std::move(xcomponent_id);
    return true;
}

bool CoreBridge::OnSurfaceCreated(OH_NativeXComponent* component, void* window) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
    uint64_t width = 0;
    uint64_t height = 0;
#endif
    {
        std::lock_guard<std::mutex> lock(mutex_);
        runtime_.surface.ready = true;
        runtime_.surface.native_window = window;
        UpdateSurfaceSizeLocked(component, window);
#if AZAHAR_OHOS_CORE_AVAILABLE
        core = real_core_.get();
        width = runtime_.surface.width;
        height = runtime_.surface.height;
#endif
    }
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (core) {
        core->OnSurfaceChanged(static_cast<OHNativeWindow*>(window), static_cast<int>(width),
                               static_cast<int>(height));
    }
#endif
    return true;
}

bool CoreBridge::OnSurfaceChanged(OH_NativeXComponent* component, void* window) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
    uint64_t width = 0;
    uint64_t height = 0;
#endif
    {
        std::lock_guard<std::mutex> lock(mutex_);
        runtime_.surface.ready = true;
        runtime_.surface.native_window = window;
        UpdateSurfaceSizeLocked(component, window);
#if AZAHAR_OHOS_CORE_AVAILABLE
        core = real_core_.get();
        width = runtime_.surface.width;
        height = runtime_.surface.height;
#endif
    }
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (core) {
        core->OnSurfaceChanged(static_cast<OHNativeWindow*>(window), static_cast<int>(width),
                               static_cast<int>(height));
    }
#endif
    return true;
}

void CoreBridge::OnSurfaceDestroyed() {
#if AZAHAR_OHOS_CORE_AVAILABLE
    AzaharCoreRuntime* core = nullptr;
#endif
    {
        std::lock_guard<std::mutex> lock(mutex_);
        runtime_.surface.ready = false;
        runtime_.surface.width = 0;
        runtime_.surface.height = 0;
        runtime_.surface.native_window = nullptr;
#if AZAHAR_OHOS_CORE_AVAILABLE
        core = real_core_.get();
#endif
    }
#if AZAHAR_OHOS_CORE_AVAILABLE
    if (core) {
        core->OnSurfaceChanged(nullptr, 0, 0);
    }
#endif
}

void CoreBridge::EnsureDefaultConfigLocked() {
    auto put_if_missing = [this](const std::string& key, ConfigValue value) {
        if (config_.find(key) == config_.end()) {
            config_.emplace(key, std::move(value));
        }
    };

    put_if_missing("graphics_api", 2.0);
    put_if_missing("use_gles", false);
    put_if_missing("use_hw_shader", true);
    put_if_missing("use_shader_jit", true);
    put_if_missing("use_shader_jit_requested", ConfigBool(config_, "use_shader_jit", true));
    put_if_missing("cpu_core_mode", -1.0);
    put_if_missing("use_fastinterp", true);
    put_if_missing("use_disk_shader_cache", true);
    put_if_missing("use_hw_geometry_cache", true);
    put_if_missing("resolution_factor", 1.0);
    put_if_missing("cpu_clock_percentage", 100.0);
    put_if_missing("enable_rpc_server", false);
    put_if_missing("use_artic_base_controller", false);
    put_if_missing("frame_limit", 100.0);
    put_if_missing("turbo_limit", 200.0);
    put_if_missing("use_vsync", false);
    put_if_missing("texture_filter", 0.0);
    put_if_missing("texture_sampling", 0.0);
    put_if_missing("delay_game_render_thread_us", 0.0);
    put_if_missing("use_integer_scaling", false);
    put_if_missing("shaders_accurate_mul", false);
    put_if_missing("spirv_shader_gen", true);
    put_if_missing("disable_spirv_optimizer", true);
    put_if_missing("async_shader_compilation", false);
    put_if_missing("async_presentation", true);
    put_if_missing("simulate_3ds_gpu_timings", false);
    put_if_missing("use_skip_duplicate_frames", false);
    put_if_missing("use_frame_limit", true);
    put_if_missing("layout_option", 0.0);
    put_if_missing("portrait_layout_option", 0.0);
    put_if_missing("screen_gap", 0.0);
    put_if_missing("swap_screen", false);
    put_if_missing("upright_screen", false);
    put_if_missing("secondary_display_layout", 4.0);
    put_if_missing("large_screen_proportion", 2.25);
    put_if_missing("small_screen_position", 0.0);
    put_if_missing("aspect_ratio", 0.0);
    put_if_missing("screen_top_stretch", false);
    put_if_missing("screen_top_leftright_padding", 0.0);
    put_if_missing("screen_top_topbottom_padding", 0.0);
    put_if_missing("screen_bottom_stretch", false);
    put_if_missing("screen_bottom_leftright_padding", 0.0);
    put_if_missing("screen_bottom_topbottom_padding", 0.0);
    put_if_missing("render_3d", 2.0);
    put_if_missing("render_3d_which_display", 0.0);
    put_if_missing("mono_render_option", 0.0);
    put_if_missing("factor_3d", 0.0);
    put_if_missing("swap_eyes_3d", false);
    put_if_missing("disable_right_eye_render", false);
    put_if_missing("cardboard_screen_size", 85.0);
    put_if_missing("cardboard_x_shift", 0.0);
    put_if_missing("cardboard_y_shift", 0.0);
    put_if_missing("audio_emulation", 0.0);
    put_if_missing("enable_audio_stretching", false);
    put_if_missing("enable_realtime_audio", true);
    put_if_missing("simulate_headphones_plugged", false);
    put_if_missing("volume", 1.0);
    put_if_missing("is_new_3ds", true);
    put_if_missing("game_perf_hacks", false);
    put_if_missing("lle_applets", false);
    put_if_missing("enable_required_online_lle_modules", false);
    put_if_missing("region_value", -1.0);
    put_if_missing("apply_region_free_patch", true);
    put_if_missing("plugin_loader", false);
    put_if_missing("allow_plugin_loader", true);
    put_if_missing("init_clock", 0.0);
    put_if_missing("init_time", 946731601.0);
    put_if_missing("init_time_offset", 0.0);
    put_if_missing("init_ticks_type", 0.0);
    put_if_missing("init_ticks_override", 0.0);
    put_if_missing("steps_per_hour", 0.0);
    put_if_missing("renderer_debug", false);
    put_if_missing("debug_log", false);
    put_if_missing("deterministic_async_operations", false);
    put_if_missing("toggle_unique_data_console_type", false);
    put_if_missing("delay_start_for_lle_modules", true);
    put_if_missing("filter_mode", true);
    put_if_missing("pp_shader_name", std::string{"None (builtin)"});
    put_if_missing("anaglyph_shader_name", std::string{"Dubois (builtin)"});
    put_if_missing("use_virtual_sd", true);
    put_if_missing("compress_cia_installs", false);
    put_if_missing("async_fs_operations", true);
    put_if_missing("dump_textures", false);
    put_if_missing("custom_textures", false);
    put_if_missing("preload_textures", false);
    put_if_missing("async_custom_loading", true);
    put_if_missing("use_cpu_jit_requested", true);
}

void CoreBridge::ApplyJitPolicyLocked() {
    runtime_.jit = EvaluateJitPolicy(runtime_.device_type, tablet_jit_user_enabled_);
    config_["use_cpu_jit"] = runtime_.jit.available;
    const bool shader_jit_requested =
        ConfigBool(config_, "use_shader_jit_requested", ConfigBool(config_, "use_shader_jit", true));
    config_["use_shader_jit_requested"] = shader_jit_requested;
    config_["use_shader_jit"] = runtime_.jit.available && shader_jit_requested;
}

std::string CoreBridge::NormalizeDeviceType(std::string device_type) const {
    std::transform(device_type.begin(), device_type.end(), device_type.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return device_type.empty() ? "phone" : device_type;
}

std::string CoreBridge::ExtensionOf(const std::string& path) const {
    const size_t query = path.find('?');
    const std::string clean = query == std::string::npos ? path : path.substr(0, query);
    const size_t dot = clean.find_last_of('.');
    if (dot == std::string::npos) {
        return "";
    }
    return NormalizeDeviceType(clean.substr(dot));
}

bool CoreBridge::IsSupportedApplicationPath(const std::string& path) const {
    const std::string ext = ExtensionOf(path);
    return std::find(std::begin(kSupportedExtensions), std::end(kSupportedExtensions), ext) !=
           std::end(kSupportedExtensions);
}

bool CoreBridge::LocalFileExists(const std::string& path) const {
    if (path.empty() || path.find("://") != std::string::npos) {
        return true;
    }
    std::ifstream file(path);
    return file.good();
}

void CoreBridge::UpdateSurfaceSizeLocked(OH_NativeXComponent* component, void* window) {
    if (!component) {
        runtime_.surface.width = 0;
        runtime_.surface.height = 0;
        return;
    }

    uint64_t width = 0;
    uint64_t height = 0;
    if (OH_NativeXComponent_GetXComponentSize(component, window, &width, &height) ==
        OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
        runtime_.surface.width = width;
        runtime_.surface.height = height;
    }
}

} // namespace Azahar::Ohos
