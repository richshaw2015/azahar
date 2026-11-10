#include "graphics/ohos_graphics_info.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <dlfcn.h>
#include <hilog/log.h>

#include <cstdio>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "Azahar_OHOS"
#define LOG_DOMAIN 0x3203

#define AZ_GI_LOGW(fmt, ...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)

namespace {

constexpr const char* kUnavailable = "-";

std::string ProbeVulkanApiVersion() {
    void* vulkan_lib = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    if (!vulkan_lib) {
        AZ_GI_LOGW("dlopen libvulkan.so failed: %{public}s", dlerror());
        return kUnavailable;
    }

    // vkEnumerateInstanceVersion 仅 Vulkan 1.1+ 提供；缺该符号说明 loader 是 1.0。
    // 本地最小声明（VkResult 为 int32 枚举，VK_SUCCESS == 0），避免引入 vulkan-headers。
    using PfnVkEnumerateInstanceVersion = int32_t (*)(uint32_t*);
    const auto enumerate_version = reinterpret_cast<PfnVkEnumerateInstanceVersion>(
        dlsym(vulkan_lib, "vkEnumerateInstanceVersion"));

    std::string version = "Vulkan 1.0";
    if (enumerate_version) {
        uint32_t api_version = 0;
        if (enumerate_version(&api_version) == 0) {
            // VK_VERSION_MAJOR/MINOR/PATCH 的位布局（19.10 规范起固定）
            char buffer[32];
            std::snprintf(buffer, sizeof(buffer), "Vulkan %u.%u.%u", api_version >> 22,
                          (api_version >> 12) & 0x3ffu, api_version & 0xfffu);
            version = buffer;
        } else {
            AZ_GI_LOGW("vkEnumerateInstanceVersion failed, assuming Vulkan 1.0");
        }
    }

    // 引用计数 -1；若模拟器核心随后/正在使用同一库不受影响
    dlclose(vulkan_lib);
    return version;
}

#ifdef EGL_OPENGL_ES3_BIT
constexpr EGLint kEs3RenderableBit = EGL_OPENGL_ES3_BIT;
#else
constexpr EGLint kEs3RenderableBit = EGL_OPENGL_ES3_BIT_KHR;
#endif

// 建 1x1 pbuffer + GLES 上下文读 GL_VERSION/GL_RENDERER；ES3 失败回退 ES2
void ProbeGles(Azahar::Ohos::GraphicsInfo& info) {
    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY) {
        AZ_GI_LOGW("eglGetDisplay returned EGL_NO_DISPLAY");
        return;
    }
    if (eglInitialize(display, nullptr, nullptr) != EGL_TRUE) {
        AZ_GI_LOGW("eglInitialize failed: 0x%{public}x", eglGetError());
        return;
    }

    const struct {
        EGLint renderable_bit;
        EGLint client_version;
    } attempts[] = {
        {kEs3RenderableBit, 3},
        {EGL_OPENGL_ES2_BIT, 2},
    };

    bool probed = false;
    for (const auto& attempt : attempts) {
        const EGLint config_attribs[] = {
            EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, attempt.renderable_bit,
            EGL_NONE,
        };
        EGLConfig config = nullptr;
        EGLint num_configs = 0;
        if (eglChooseConfig(display, config_attribs, &config, 1, &num_configs) != EGL_TRUE ||
            num_configs < 1) {
            continue;
        }

        const EGLint surface_attribs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
        EGLSurface surface = eglCreatePbufferSurface(display, config, surface_attribs);
        if (surface == EGL_NO_SURFACE) {
            continue;
        }

        eglBindAPI(EGL_OPENGL_ES_API);
        const EGLint context_attribs[] = {EGL_CONTEXT_CLIENT_VERSION, attempt.client_version,
                                          EGL_NONE};
        EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attribs);
        if (context == EGL_NO_CONTEXT) {
            eglDestroySurface(display, surface);
            continue;
        }

        if (eglMakeCurrent(display, surface, surface, context) == EGL_TRUE) {
            const char* version = reinterpret_cast<const char*>(glGetString(GL_VERSION));
            const char* renderer = reinterpret_cast<const char*>(glGetString(GL_RENDERER));
            if (version && version[0] != '\0') {
                info.gles_version = version;
            }
            if (renderer && renderer[0] != '\0') {
                info.gpu_name = renderer;
            }
            eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            probed = true;
        } else {
            AZ_GI_LOGW("eglMakeCurrent failed for ES%{public}d: 0x%{public}x",
                       static_cast<int>(attempt.client_version), eglGetError());
        }

        eglDestroyContext(display, context);
        eglDestroySurface(display, surface);
        if (probed) {
            break;
        }
    }

    if (!probed) {
        AZ_GI_LOGW("no usable GLES context for version probe");
    }
    eglTerminate(display);
}

} // namespace

namespace Azahar::Ohos {

GraphicsInfo ProbeGraphicsInfo() {
    GraphicsInfo info{kUnavailable, kUnavailable, kUnavailable};
    info.vulkan_version = ProbeVulkanApiVersion();
    ProbeGles(info);
    return info;
}

} // namespace Azahar::Ohos
