#include "graphics/ohos_emu_window.h"

#include <algorithm>
#include <array>

#include <glad/glad.h>
#include <hilog/log.h>

#include "common/logging/log.h"
#include "common/settings.h"
#include "core/core.h"
#include "network/network.h"
#include "video_core/gpu.h"
#include "video_core/renderer_base.h"

namespace Azahar::Ohos {
namespace {

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3203
#define LOG_TAG "Azahar_Graphics"
#define AZ_GFX_LOGW(fmt, ...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)
#define AZ_GFX_LOGE(fmt, ...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)

constexpr std::array<EGLint, 15> egl_attribs{
    EGL_SURFACE_TYPE,    EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
    EGL_BLUE_SIZE,       8,              EGL_GREEN_SIZE,      8,
    EGL_RED_SIZE,        8,              EGL_DEPTH_SIZE,      0,
    EGL_STENCIL_SIZE,    0,              EGL_NONE,
};

constexpr std::array<EGLint, 5> egl_empty_attribs{EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
constexpr std::array<EGLint, 4> egl_context_attribs{EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};

class SharedContextOhos final : public Frontend::GraphicsContext {
public:
    SharedContextOhos(EGLDisplay display, EGLConfig config, EGLContext share_context)
        : egl_display{display},
          egl_surface{eglCreatePbufferSurface(display, config, egl_empty_attribs.data())},
          egl_context{eglCreateContext(display, config, share_context, egl_context_attribs.data())} {
        if (egl_surface == EGL_NO_SURFACE) {
            LOG_CRITICAL(Frontend, "OHOS eglCreatePbufferSurface() failed");
        }
        if (egl_context == EGL_NO_CONTEXT) {
            LOG_CRITICAL(Frontend, "OHOS shared eglCreateContext() failed");
        }
    }

    ~SharedContextOhos() override {
        if (egl_surface != EGL_NO_SURFACE && !eglDestroySurface(egl_display, egl_surface)) {
            LOG_CRITICAL(Frontend, "OHOS eglDestroySurface() failed");
        }
        if (egl_context != EGL_NO_CONTEXT && !eglDestroyContext(egl_display, egl_context)) {
            LOG_CRITICAL(Frontend, "OHOS eglDestroyContext() failed");
        }
    }

    bool IsGLES() override {
        return true;
    }

    bool IsValid() const {
        return egl_surface != EGL_NO_SURFACE && egl_context != EGL_NO_CONTEXT;
    }

    void MakeCurrent() override {
        eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_context);
    }

    void DoneCurrent() override {
        eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }

private:
    EGLDisplay egl_display{EGL_NO_DISPLAY};
    EGLSurface egl_surface{EGL_NO_SURFACE};
    EGLContext egl_context{EGL_NO_CONTEXT};
};

class VulkanContextOhos final : public Frontend::GraphicsContext {};

} // namespace

EmuWindowOhos::EmuWindowOhos(OHNativeWindow* surface, int width, int height, bool is_secondary)
    : EmuWindow{is_secondary}, host_window{surface}, window_width{width}, window_height{height} {
    window_info.type = Frontend::WindowSystemType::OpenHarmony;
    window_info.render_surface = surface;
    // 已有联机会话时不能重建全局 Room/RoomMember，否则游戏启动会断开已加入的房间
    if (Network::GetRoomMember().expired()) {
        Network::Init();
    }
}

EmuWindowOhos::~EmuWindowOhos() {
    DestroyWindowSurface();
    DestroyContext();
}

bool EmuWindowOhos::OnSurfaceChanged(OHNativeWindow* surface, int width, int height) {
    width = std::max(width, 0);
    height = std::max(height, 0);
    if (render_window == surface && width == window_width && height == window_height) {
        return false;
    }

    window_width = width;
    window_height = height;
    render_window = surface;
    surface_change_pending = true;
    window_info.type = Frontend::WindowSystemType::OpenHarmony;
    window_info.render_surface = surface;
    StopPresenting();
    // detach（surface=nullptr）时保留最后一次有效布局：暂停期泵帧仍会触发
    // SwapBuffers，塌缩布局会改写 present 画面的比例与位置（GetScreenLayout/触摸映射同理）
    if (surface) {
        OnFramebufferSizeChanged();
    }
    return true;
}

bool EmuWindowOhos::OnTouchEvent(int x, int y, bool pressed) {
    if (pressed) {
        return TouchPressed(static_cast<unsigned>(std::max(x, 0)),
                            static_cast<unsigned>(std::max(y, 0)));
    }

    TouchReleased();
    return true;
}

void EmuWindowOhos::OnTouchMoved(int x, int y) {
    TouchMoved(static_cast<unsigned>(std::max(x, 0)), static_cast<unsigned>(std::max(y, 0)));
}

void EmuWindowOhos::MakeCurrent() {
    if (core_context) {
        core_context->MakeCurrent();
    }
}

void EmuWindowOhos::DoneCurrent() {
    if (core_context) {
        core_context->DoneCurrent();
    }
}

void EmuWindowOhos::OnFramebufferSizeChanged() {
    const auto width = static_cast<u32>(std::max(window_width, 0));
    const auto height = static_cast<u32>(std::max(window_height, 0));
    if (custom_screen_rects_) {
        // 编辑器窗口坐标即最终位置：跳过 layout_option 算法与安全区内边距；
        // swap_screen 交换两屏角色，保持会话级快捷操作语义
        const bool swapped = Settings::values.swap_screen.GetValue();
        Layout::FramebufferLayout layout{};
        layout.width = width;
        layout.height = height;
        layout.top_screen_enabled = true;
        layout.bottom_screen_enabled = true;
        layout.top_screen =
            swapped ? custom_screen_rects_->second : custom_screen_rects_->first;
        layout.bottom_screen =
            swapped ? custom_screen_rects_->first : custom_screen_rects_->second;
        layout.render_3d_mode = get3DMode();
        NotifyFramebufferLayoutChanged(layout);
        return;
    }
    const bool is_portrait_mode = !is_secondary && window_height > window_width;
    UpdateCurrentFramebufferLayout(width, height, is_portrait_mode);
}

EmuWindowOhosOpenGL::EmuWindowOhosOpenGL(Core::System& system_, OHNativeWindow* surface,
                                         int width, int height, bool is_secondary,
                                         EGLContext* shared_context)
    : EmuWindowOhos{surface, width, height, is_secondary}, system{system_} {
    egl_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (egl_display == EGL_NO_DISPLAY) {
        LOG_CRITICAL(Frontend, "OHOS eglGetDisplay() failed");
        return;
    }
    if (eglInitialize(egl_display, nullptr, nullptr) != EGL_TRUE) {
        LOG_CRITICAL(Frontend, "OHOS eglInitialize() failed");
        return;
    }
    EGLint egl_num_configs{};
    if (eglChooseConfig(egl_display, egl_attribs.data(), &egl_config, 1, &egl_num_configs) !=
        EGL_TRUE) {
        LOG_CRITICAL(Frontend, "OHOS eglChooseConfig() failed");
        return;
    }

    if (!CreateWindowSurface()) {
        LOG_CRITICAL(Frontend, "OHOS CreateWindowSurface() failed");
        return;
    }

    if (eglQuerySurface(egl_display, egl_surface, EGL_WIDTH, &window_width) != EGL_TRUE ||
        eglQuerySurface(egl_display, egl_surface, EGL_HEIGHT, &window_height) != EGL_TRUE) {
        LOG_CRITICAL(Frontend, "OHOS eglQuerySurface() failed");
        return;
    }

    if (shared_context) {
        egl_context = *shared_context;
    } else {
        egl_context = eglCreateContext(egl_display, egl_config, EGL_NO_CONTEXT,
                                       egl_context_attribs.data());
    }
    if (egl_context == EGL_NO_CONTEXT) {
        LOG_CRITICAL(Frontend, "OHOS eglCreateContext() failed");
        return;
    }

    if (eglSurfaceAttrib(egl_display, egl_surface, EGL_SWAP_BEHAVIOR, EGL_BUFFER_DESTROYED) !=
        EGL_TRUE) {
        LOG_WARNING(Frontend, "OHOS eglSurfaceAttrib(EGL_SWAP_BEHAVIOR) failed");
    }

    core_context = CreateSharedContext();
    if (!core_context) {
        LOG_CRITICAL(Frontend, "OHOS CreateSharedContext() failed");
        return;
    }

    if (eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_context) != EGL_TRUE) {
        LOG_CRITICAL(Frontend, "OHOS eglMakeCurrent() failed");
        return;
    }
    if (!gladLoadGLES2Loader(reinterpret_cast<GLADloadproc>(eglGetProcAddress))) {
        LOG_CRITICAL(Frontend, "OHOS gladLoadGLES2Loader() failed");
        return;
    }
    if (!eglSwapInterval(egl_display, Settings::values.use_vsync ? 1 : 0)) {
        LOG_WARNING(Frontend, "OHOS eglSwapInterval() failed");
    }

    OnFramebufferSizeChanged();
}

EmuWindowOhosOpenGL::~EmuWindowOhosOpenGL() {
    DestroyWindowSurface();
    DestroyContext();
}

EGLContext* EmuWindowOhosOpenGL::GetEGLContext() {
    return &egl_context;
}

bool EmuWindowOhosOpenGL::CreateWindowSurface() {
    if (!host_window || egl_display == EGL_NO_DISPLAY) {
        return false;
    }

    EGLint format{};
    if (eglGetConfigAttrib(egl_display, egl_config, EGL_NATIVE_VISUAL_ID, &format) == EGL_TRUE) {
        OH_NativeWindow_NativeWindowHandleOpt(host_window, SET_FORMAT, format);
    }
    if (window_width > 0 && window_height > 0) {
        OH_NativeWindow_NativeWindowHandleOpt(host_window, SET_BUFFER_GEOMETRY, window_width,
                                             window_height);
    }

    egl_surface =
        eglCreateWindowSurface(egl_display, egl_config,
                               reinterpret_cast<EGLNativeWindowType>(host_window), nullptr);
    return egl_surface != EGL_NO_SURFACE;
}

void EmuWindowOhosOpenGL::DestroyWindowSurface() {
    if (egl_surface == EGL_NO_SURFACE || egl_display == EGL_NO_DISPLAY) {
        return;
    }
    if (eglGetCurrentSurface(EGL_DRAW) == egl_surface) {
        eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    if (!eglDestroySurface(egl_display, egl_surface)) {
        LOG_CRITICAL(Frontend, "OHOS eglDestroySurface() failed");
    }
    egl_surface = EGL_NO_SURFACE;
}

void EmuWindowOhosOpenGL::DestroyContext() {
    if (egl_display == EGL_NO_DISPLAY) {
        return;
    }
    if (egl_context != EGL_NO_CONTEXT) {
        if (eglGetCurrentContext() == egl_context) {
            eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        }
        if (!eglDestroyContext(egl_display, egl_context)) {
            LOG_CRITICAL(Frontend, "OHOS eglDestroyContext() failed");
        }
        egl_context = EGL_NO_CONTEXT;
    }
    if (!eglTerminate(egl_display)) {
        LOG_CRITICAL(Frontend, "OHOS eglTerminate() failed");
    }
    egl_display = EGL_NO_DISPLAY;
}

std::unique_ptr<Frontend::GraphicsContext> EmuWindowOhosOpenGL::CreateSharedContext() const {
    auto context = std::make_unique<SharedContextOhos>(egl_display, egl_config, egl_context);
    if (!context->IsValid()) {
        return nullptr;
    }
    return context;
}

void EmuWindowOhosOpenGL::PollEvents() {
    if (!surface_change_pending) {
        return;
    }

    surface_change_pending = false;
    host_window = render_window;
    render_window = nullptr;

    DestroyWindowSurface();
    if (host_window) {
        CreateWindowSurface();
        OnFramebufferSizeChanged();
    }
    presenting_state = PresentingState::Initial;
}

void EmuWindowOhosOpenGL::StopPresenting() {
    if (presenting_state == PresentingState::Running && egl_display != EGL_NO_DISPLAY) {
        eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    presenting_state = PresentingState::Stopped;
}

void EmuWindowOhosOpenGL::TryPresenting() {
    if (!system.IsPoweredOn() || egl_display == EGL_NO_DISPLAY || egl_surface == EGL_NO_SURFACE ||
        egl_context == EGL_NO_CONTEXT) {
        return;
    }
    if (presenting_state == PresentingState::Initial) [[unlikely]] {
        presenting_state = PresentingState::Running;
    }
    if (presenting_state != PresentingState::Running) [[unlikely]] {
        return;
    }

    if (eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_context) != EGL_TRUE) {
        const EGLint error = eglGetError();
        AZ_GFX_LOGE("OHOS present eglMakeCurrent failed: 0x%{public}x", error);
        presenting_state = PresentingState::Stopped;
        return;
    }

    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_STENCIL_TEST);
    glViewport(0, 0, std::max(window_width, 1), std::max(window_height, 1));
    eglSwapInterval(egl_display, Settings::values.use_vsync ? 1 : 0);
    system.GPU().Renderer().TryPresent(0, is_secondary);
    glFlush();
    if (eglSwapBuffers(egl_display, egl_surface) != EGL_TRUE) {
        const EGLint error = eglGetError();
        if (error == EGL_BAD_SURFACE || error == EGL_BAD_NATIVE_WINDOW) {
            AZ_GFX_LOGW("OHOS present swap failed, surface invalid: 0x%{public}x", error);
            presenting_state = PresentingState::Stopped;
        } else {
            AZ_GFX_LOGE("OHOS present swap failed: 0x%{public}x", error);
        }
    }
}

EmuWindowOhosVulkan::EmuWindowOhosVulkan(OHNativeWindow* surface, int width, int height,
                                         bool is_secondary)
    : EmuWindowOhos{surface, width, height, is_secondary} {
    CreateWindowSurface();
    core_context = CreateSharedContext();
    OnFramebufferSizeChanged();
}

bool EmuWindowOhosVulkan::CreateWindowSurface() {
    window_info.type = Frontend::WindowSystemType::OpenHarmony;
    window_info.render_surface = host_window;
    return true;
}

std::unique_ptr<Frontend::GraphicsContext> EmuWindowOhosVulkan::CreateSharedContext() const {
    return std::make_unique<VulkanContextOhos>();
}

void EmuWindowOhosVulkan::PollEvents() {
    if (!surface_change_pending) {
        return;
    }
    surface_change_pending = false;
    host_window = render_window;
    render_window = nullptr;
    CreateWindowSurface();
    // detach 消费 pending 时保留旧布局（同 OnSurfaceChanged 的 surface==nullptr 分支）
    if (host_window) {
        OnFramebufferSizeChanged();
    }
}

} // namespace Azahar::Ohos
