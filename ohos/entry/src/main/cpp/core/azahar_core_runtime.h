#pragma once

#include <atomic>
#include <array>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <native_window/external_window.h>

#include "core/azahar_core_bridge.h"

namespace Azahar::Ohos {

class EmuWindowOhos;

} // namespace Azahar::Ohos

namespace Azahar::Ohos {

// 与 camera_permission_requested 同一握手：RegisterMicPermissionCheck 未授权时置位，
// 前端帧泵消费后弹系统授权框
bool ConsumeMicPermissionRequest();

// 与 mic_permission_pending 同一握手：RunLoop 返回非致命错误时置位
// （携带 ResultStatus 名与 GetStatusDetails 详情），前端帧泵消费后弹错误提示
bool ConsumeCoreError(std::string& status, std::string& details);

class AzaharCoreRuntime {
public:
    AzaharCoreRuntime();
    ~AzaharCoreRuntime();

    bool Start(std::string filepath, OHNativeWindow* native_window, int width, int height,
               std::unordered_map<std::string, ConfigValue> config, std::string files_dir,
               std::string cache_dir, std::string user_dir);
    bool Pause();
    bool Resume();
    bool Stop();
    bool Reset();
    bool SaveState(int32_t slot);
    bool LoadState(int32_t slot);
    bool DeleteSaveState(int32_t slot);
    bool HasUndoSaveState(int32_t slot);
    bool UndoSaveState(int32_t slot);
    std::vector<SaveStateSlotInfo> ListSaveStates(int32_t max_slot);
    bool CaptureScreenshot(const std::string& path, int32_t resolution_scale,
                           bool side_by_side = false);
    bool ApplyConfig(const std::unordered_map<std::string, ConfigValue>& config);

    bool PresentFrame();
    bool SendTouchEvent(double x, double y, int32_t action);
    bool OnSurfaceChanged(OHNativeWindow* native_window, int width, int height);

    bool IsRunning() const;
    bool IsPaused() const;
    std::string GetStatus() const;
    std::vector<double> GetPerfStats() const;

    // [width, height, topEnabled, topRect(l,t,r,b), bottomEnabled, bottomRect(l,t,r,b)]
    // 主 emu window 不存在或尚未产生 layout 时返回空数组
    std::vector<double> GetScreenLayout() const;

    // 安全区内边距（framebuffer px），主窗口立即重新计算屏幕布局
    void SetScreenOffsets(int32_t left, int32_t top, int32_t right, int32_t bottom);

    // 布局编辑器显式屏幕矩形（framebuffer px）；窗口未创建时暂存，Run 建窗后应用；
    // 会话级，清空后恢复 layout_option 自动布局
    void SetCustomScreenRects(int32_t top_x, int32_t top_y, int32_t top_w, int32_t top_h,
                            int32_t bottom_x, int32_t bottom_y, int32_t bottom_w,
                            int32_t bottom_h);
    void ClearCustomScreenRects();

private:
    void Run(std::string filepath, OHNativeWindow* native_window, int width, int height,
             std::unordered_map<std::string, ConfigValue> config, std::string files_dir,
             std::string cache_dir, std::string user_dir);
    void SignalStartup(bool ok, std::string status);
    void SetStatus(std::string status);
    // 须持 mutex_ 调用：把暂存的编辑器屏幕矩形应用到已创建的窗口
    void ApplyCustomScreenRectsLocked();

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::thread emu_thread_;
    std::unique_ptr<EmuWindowOhos> window_;
    std::atomic_bool stop_requested_{false};
    std::atomic_bool pause_requested_{false};
    std::atomic_bool pause_frame_requested_{false};
    // emu 线程已驻停在暂停 cv_.wait 内：此时渲染器空闲，可由其他线程直接
    // 消费截图请求（须在 mutex_ 持有期判断/执行，防止判断后线程恰好醒来）
    std::atomic_bool pause_parked_{false};
    std::atomic_bool screenshot_in_progress_{false};
    std::atomic_bool running_{false};
    bool startup_reported_ = false;
    bool startup_ok_ = false;
    std::string status_ = "azahar_core_bound";
    std::array<double, 17> perf_stats_{};
    // [top l,t,w,h, bottom l,t,w,h] framebuffer px
    std::optional<std::array<int32_t, 8>> custom_screen_rects_;
};

} // namespace Azahar::Ohos
