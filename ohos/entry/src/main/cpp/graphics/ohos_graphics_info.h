#pragma once

#include <string>

namespace Azahar::Ohos {

// 系统图形栈探测结果；字段取不到时为 "-"
struct GraphicsInfo {
    std::string vulkan_version;
    std::string gles_version;
    std::string gpu_name;
};

// Vulkan API 版本走 dlopen(libvulkan.so) 探测（无需建实例）；
// GLES 版本/GPU 名创建 1x1 pbuffer 临时 EGL 上下文读 glGetString。
// 纯只读探测，可在任意线程调用，不与模拟器自有的 EGL/Vulkan 使用冲突。
GraphicsInfo ProbeGraphicsInfo();

} // namespace Azahar::Ohos
