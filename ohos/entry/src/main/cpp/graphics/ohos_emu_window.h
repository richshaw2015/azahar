#pragma once

#include <memory>
#include <optional>
#include <utility>

#include <EGL/egl.h>
#include <native_window/external_window.h>

#include "core/frontend/emu_window.h"

namespace Core {
class System;
}

namespace Azahar::Ohos {

class EmuWindowOhos : public Frontend::EmuWindow {
public:
    EmuWindowOhos(OHNativeWindow* surface, int width, int height, bool is_secondary = false);
    ~EmuWindowOhos() override;

    bool OnSurfaceChanged(OHNativeWindow* surface, int width, int height);
    bool OnTouchEvent(int x, int y, bool pressed);
    void OnTouchMoved(int x, int y);

    void MakeCurrent() override;
    void DoneCurrent() override;

    virtual void TryPresenting() {}
    virtual void StopPresenting() {}
    virtual EGLContext* GetEGLContext() {
        return nullptr;
    }

    // Safe-area insets in framebuffer pixels; re-layouts screens immediately.
    void SetScreenOffsets(int left, int top, int right, int bottom) {
        SetFramebufferLayoutInsets(left, top, right, bottom);
        OnFramebufferSizeChanged();
    }

    // 布局类设置（swap_screen/upright_screen/layout_option 等）变更后按当前 surface
    // 尺寸重算布局；等价一次同尺寸 surface 变更（对齐 Android updateFramebuffer 的效果）
    void RefreshFramebufferLayout() {
        OnFramebufferSizeChanged();
    }

    // 布局编辑器下发的显式屏幕矩形（framebuffer px，窗口坐标）：设置后双屏按矩形
    // 摆放，跳过 layout_option 自动布局与安全区内边距；swap_screen 仍会交换两屏角色。
    // 会话级状态，ClearCustomScreenRects 后恢复自动布局（对齐 nds setCustomScreenRects）
    void SetCustomScreenRects(Common::Rectangle<u32> top, Common::Rectangle<u32> bottom) {
        custom_screen_rects_ = {top, bottom};
        OnFramebufferSizeChanged();
    }

    void ClearCustomScreenRects() {
        custom_screen_rects_.reset();
        OnFramebufferSizeChanged();
    }

protected:
    void OnFramebufferSizeChanged();

    virtual bool CreateWindowSurface() {
        return false;
    }
    virtual void DestroyWindowSurface() {}
    virtual void DestroyContext() {}

    OHNativeWindow* render_window{};
    OHNativeWindow* host_window{};
    int window_width{};
    int window_height{};
    bool surface_change_pending = false;
    std::unique_ptr<Frontend::GraphicsContext> core_context;
    std::optional<std::pair<Common::Rectangle<u32>, Common::Rectangle<u32>>>
        custom_screen_rects_;
};

class EmuWindowOhosOpenGL final : public EmuWindowOhos {
public:
    EmuWindowOhosOpenGL(Core::System& system, OHNativeWindow* surface, int width, int height,
                        bool is_secondary = false, EGLContext* shared_context = nullptr);
    ~EmuWindowOhosOpenGL() override;

    void TryPresenting() override;
    void StopPresenting() override;
    void PollEvents() override;
    EGLContext* GetEGLContext() override;
    std::unique_ptr<GraphicsContext> CreateSharedContext() const override;

private:
    bool CreateWindowSurface() override;
    void DestroyWindowSurface() override;
    void DestroyContext() override;

    Core::System& system;
    EGLConfig egl_config{};
    EGLSurface egl_surface{EGL_NO_SURFACE};
    EGLContext egl_context{EGL_NO_CONTEXT};
    EGLDisplay egl_display{EGL_NO_DISPLAY};

    enum class PresentingState {
        Initial,
        Running,
        Stopped,
    };
    PresentingState presenting_state{PresentingState::Initial};
};

class EmuWindowOhosVulkan final : public EmuWindowOhos {
public:
    EmuWindowOhosVulkan(OHNativeWindow* surface, int width, int height,
                        bool is_secondary = false);
    ~EmuWindowOhosVulkan() override = default;

    void PollEvents() override;
    std::unique_ptr<GraphicsContext> CreateSharedContext() const override;

private:
    bool CreateWindowSurface() override;
};

} // namespace Azahar::Ohos
