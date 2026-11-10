#pragma once

#include <ace/xcomponent/native_interface_xcomponent.h>

#include <array>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <variant>
#include <vector>

namespace Network {
class RoomMember;
}

namespace Azahar::Ohos {

class AzaharCoreRuntime;

enum class RuntimeState {
    Stopped = 0,
    Loaded = 1,
    Running = 2,
    Paused = 3,
};

enum class LoadResult {
    Success = 0,
    NotInitialized = 1,
    EmptyPath = 2,
    UnsupportedFormat = 3,
    FileNotFound = 4,
};

enum class CoreBackend {
    Stub = 0,
    AzaharCore = 1,
};

using ConfigValue = std::variant<bool, double, std::string>;

struct JitPolicy {
    // 启动阶段动态探测结果（DetectJitSupport 缓存值）：设备是否具备 JIT 权限
    bool supported = false;
    // supported && 用户设置：进入核心的最终生效值
    bool available = false;
    std::string reason = "jit_unsupported";
};

struct AppInfo {
    std::string path;
    std::string file_name;
    std::string extension;
    bool supported = false;
};

struct GameMetadata {
    std::string path;
    std::string title_id;
    std::string short_title;
    std::string long_title;
    std::string publisher;
    std::string regions;
    std::string product_code;
    std::string extdata_id;
    std::string file_type;
    std::string icon_status = "core_unavailable";
    bool valid = false;
    bool encrypted = false;
    bool insertable = false;
    bool system_title = false;
    bool visible = false;
    bool has_icon = false;
    uint32_t icon_width = 0;
    uint32_t icon_height = 0;
    std::vector<uint8_t> icon_rgb565;
    std::vector<uint8_t> icon_rgba;
};

struct SurfaceInfo {
    bool ready = false;
    uint64_t width = 0;
    uint64_t height = 0;
    void* native_window = nullptr;
    std::string xcomponent_id;
};

struct RuntimeInfo {
    bool initialized = false;
    RuntimeState state = RuntimeState::Stopped;
    std::string loaded_path;
    std::string device_type = "phone";
    JitPolicy jit;
    SurfaceInfo surface;
    CoreBackend backend = CoreBackend::Stub;
    std::string backend_status = "azahar_core_not_linked";
    // 布局编辑器显式屏幕矩形（px，[top l,t,w,h, bottom l,t,w,h]）；
    // 先于 real_core_ 创建到达时暂存，core 就绪后下发生效
    std::optional<std::array<double, 8>> custom_screen_rects;
};

struct SaveStateSlotInfo {
    int32_t slot = 0;
    uint64_t time = 0;
    int32_t status = 0;
    std::string build_name;
    uint64_t file_size = 0;
    std::string screenshot_path;
    // 该槽位存在"覆盖前旧档"内存备份，可撤销最近一次写档（仅保留本会话最近一次覆盖）
    bool has_undo = false;
};

struct CheatInfo {
    int32_t index = 0;
    std::string name;
    std::string notes;
    std::string code;
    std::string type;
    bool enabled = false;
};

struct MultiplayerRoomInfo {
    std::string id;
    std::string name;
    std::string description;
    std::string owner;
    std::string address;
    uint16_t port = 0;
    uint32_t max_players = 0;
    uint32_t member_count = 0;
    uint32_t net_version = 0;
    bool has_password = false;
    std::string preferred_game;
    std::string preferred_game_id;
};

struct MultiplayerMemberInfo {
    std::string nickname;
    std::string username;
    std::string game_name;
};

struct MultiplayerSessionInfo {
    bool initialized = false;
    bool joined = false;
    bool moderator = false;
    bool hosting = false;
    std::string room_name;
    int32_t member_slots = 0;
    std::vector<MultiplayerMemberInfo> members;
    std::vector<std::string> username_bans;
};

struct SystemProfile {
    bool available = false;
    std::string username;
    uint8_t birth_month = 1;
    uint8_t birth_day = 1;
    uint8_t language = 1;
    uint8_t sound_output_mode = 1;
    uint8_t country_code = 1;
    bool system_setup_needed = false;
    uint16_t play_coins = 0;
    std::string mac_address;
    uint64_t console_id = 0;
};

struct SystemFilesStatus {
    bool old3ds_installed = false;
    bool new3ds_installed = false;
};

struct TitleContentStatus {
    bool application_installed = false;
    bool update_installed = false;
    bool dlc_installed = false;
    std::string application_path;
    std::string update_path;
    std::string dlc_path;
};

struct RomFsDumpResult {
    bool success = false;
    int32_t base_status = 3;
    int32_t update_status = 3;
    std::string base_path;
    std::string update_path;
};

struct MovieStatus {
    std::string mode = "none";
    uint64_t current_input = 0;
    uint64_t total_input = 0;
};

struct MovieMetadata {
    bool valid = false;
    int32_t validation_result = 3;
    std::string title_id;
    std::string author;
    uint32_t rerecord_count = 0;
    uint64_t input_count = 0;
};

class CoreBridge {
public:
    static CoreBridge& Get();

    ~CoreBridge();

    bool Initialize(std::string files_dir, std::string cache_dir, std::string user_dir,
                    std::string device_type, bool tablet_jit_user_enabled);
    bool Shutdown();

    LoadResult LoadApplication(const std::string& path);
    bool StartEmulation();
    bool PauseEmulation();
    bool ResumeEmulation();
    bool StopEmulation();
    bool ResetEmulation();
    bool DoFrame();

    bool IsRunning() const;
    bool IsPaused() const;

    bool SendTouchEvent(double x, double y, int32_t action);
    bool SendKeyEvent(int32_t key, bool is_down);
    bool SendAnalogEvent(int32_t analog, double x, double y);
    // 3DS 翻盖开合（PTM shell_open）：游戏用它触发睡眠/合盖流程
    bool SetShellOpen(bool open);
    bool IsShellOpen() const;
    // 系统睡眠协商状态（APT SleepState）：0=醒着 1=询问中 2=准备中 3=睡眠中
    int32_t GetSystemSleepState() const;
    bool SaveState(int32_t slot);
    bool LoadState(int32_t slot);
    bool DeleteSaveState(int32_t slot);
    bool HasUndoSaveState(int32_t slot);
    bool UndoSaveState(int32_t slot);
    std::vector<SaveStateSlotInfo> ListSaveStates(int32_t max_slot);
    bool CaptureScreenshot(const std::string& path, int32_t resolution_scale);
    int32_t InstallCIA(const std::string& path);
    std::vector<std::string> GetInstalledGamePaths() const;
    std::vector<CheatInfo> ListCheats(const std::string& title_id);
    bool SetCheatEnabled(const std::string& title_id, int32_t index, bool enabled);
    bool UpsertGatewayCheat(const std::string& title_id, int32_t index, const std::string& name,
                            const std::string& notes, const std::string& code, bool enabled);
    bool RemoveCheat(const std::string& title_id, int32_t index);
    bool ImportCheats(const std::string& title_id, const std::string& contents);
    int32_t ValidateGatewayCheatCode(const std::string& code) const;
    bool HasGamePerfHacks(const std::string& title_id) const;
    bool IsSearchingForAmiibo() const;
    bool LoadAmiibo(const std::string& path);
    bool MakeAmiiboFile(const std::string& id, const std::string& path);
    int ZipPassExport(const std::string& path);
    int ZipPassImport(const std::string& path);
    int ZipPassImportQueued();
    int ZipPassClearStreetPass();
    bool RemoveAmiibo();
    std::vector<MultiplayerRoomInfo> ListMultiplayerRooms();
    // 联机会话：加入/创建/离开房间。返回值为 NetPlayStatus 兼容错误码（0=成功）
    int32_t MultiplayerJoinRoom(const std::string& address, int32_t port,
                                const std::string& username, const std::string& password);
    int32_t MultiplayerCreateRoom(const std::string& address, int32_t port,
                                  const std::string& username, const std::string& game_name,
                                  int64_t game_id, const std::string& password,
                                  const std::string& room_name, int32_t max_players);
    void MultiplayerLeaveRoom();
    MultiplayerSessionInfo GetMultiplayerSessionInfo();
    void MultiplayerKickUser(const std::string& username);
    void MultiplayerBanUser(const std::string& username);
    void MultiplayerUnbanUser(const std::string& username);
    void MultiplayerSendChatMessage(const std::string& message);
    // 取走队列中累计的联机事件（成员进出/聊天/错误），ArkTS 侧周期性调用
    std::vector<std::string> PollMultiplayerEvents();
    SystemProfile GetSystemProfile();
    bool SetSystemProfile(const SystemProfile& profile);
    // 重新生成主机唯一 ID 与 MAC 地址；返回新值文本，失败返回空串
    std::string RegenerateConsoleId();
    std::string RegenerateMacAddress();
    int GetCountryCompatibility(int region);
    SystemFilesStatus GetSystemFilesStatus();
    bool UninstallSystemFiles(bool old3ds);
    TitleContentStatus GetTitleContentStatus(const std::string& title_id);
    bool UninstallTitleContent(const std::string& title_id, int32_t content_kind);
    RomFsDumpResult DumpRomFS(const std::string& path);
    MovieStatus GetMovieStatus() const;
    MovieMetadata GetMovieMetadata(const std::string& path) const;
    bool SaveMovie();
    bool CloseMovie();
    bool IsFullConsoleLinked() const;
    bool UnlinkConsole();

    bool SetConfig(const std::string& key, ConfigValue value);
    std::optional<ConfigValue> GetConfig(const std::string& key) const;
    bool ApplyConfig();
    bool SaveConfig();
    bool SetTemporaryFrameLimit(double speed);
    bool DisableTemporaryFrameLimit();
    std::vector<double> GetPerfStats();
    // [width, height, topEnabled, topL, topT, topR, topB, bottomEnabled, botL, botT, botR, botB]
    // 无 window 或未生成 layout 时返回空数组
    std::vector<double> GetScreenLayout();

    // 安全区内边距（framebuffer px），写入主 emu window 并立即重算屏幕布局
    void SetScreenOffsets(int32_t left, int32_t top, int32_t right, int32_t bottom);

    // 布局编辑器显式屏幕矩形（framebuffer px，[top l,t,w,h, bottom l,t,w,h]）；
    // 会话级：清空后恢复 layout_option 自动布局
    void SetCustomScreenRects(const std::array<double, 8>& rects);
    void ClearCustomScreenRects();

    bool UpdateDeviceProfile(std::string device_type, bool tablet_jit_user_enabled);
    JitPolicy EvaluateJitPolicy(const std::string& device_type,
                                bool tablet_jit_user_enabled) const;
    // 设备是否具备 JIT 权限：统一读启动阶段一次性探测的缓存结果
    bool IsJitSupported(const std::string& device_type) const;
    bool IsJitAvailable() const;

    RuntimeInfo GetRuntimeInfo() const;
    AppInfo GetAppInfo(const std::string& path) const;
    GameMetadata GetGameMetadata(const std::string& path) const;
    std::vector<std::string> GetSupportedExtensions() const;

    bool IsAudioEnabled() const;
    bool IsGraphicsEnabled() const;

    bool RegisterXComponentId(std::string xcomponent_id);
    bool OnSurfaceCreated(OH_NativeXComponent* component, void* window);
    bool OnSurfaceChanged(OH_NativeXComponent* component, void* window);
    void OnSurfaceDestroyed();

private:
    // 联机会话：确保 ENet 初始化并给当前 RoomMember 绑定事件回调（成员换了会自动重绑）
    bool EnsureMultiplayerNetwork();
    void BindMultiplayerCallbacks(const std::shared_ptr<Network::RoomMember>& member);
    void PushMultiplayerEvent(const std::string& event);
    std::mutex multiplayer_mutex_;
    std::deque<std::string> multiplayer_events_;
    std::weak_ptr<Network::RoomMember> multiplayer_bound_member_;

    CoreBridge();

    void EnsureDefaultConfigLocked();
    void ApplyJitPolicyLocked();
    std::string NormalizeDeviceType(std::string device_type) const;
    std::string ExtensionOf(const std::string& path) const;
    bool IsSupportedApplicationPath(const std::string& path) const;
    bool LocalFileExists(const std::string& path) const;
    void UpdateSurfaceSizeLocked(OH_NativeXComponent* component, void* window);

    mutable std::mutex mutex_;
    RuntimeInfo runtime_;
    std::string files_dir_;
    std::string cache_dir_;
    std::string user_dir_;
    bool tablet_jit_user_enabled_ = false;
    std::unordered_map<std::string, ConfigValue> config_;
    std::unique_ptr<AzaharCoreRuntime> real_core_;
};

std::string RuntimeStateName(RuntimeState state);
std::string CoreBackendName(CoreBackend backend);

} // namespace Azahar::Ohos
