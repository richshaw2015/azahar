// SPDX-FileCopyrightText: Copyright 2025 Azahar Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "ohos_jit_capability.h"

#include <sys/mman.h>

#include <mutex>

#include <DeviceSecurityKit/device_security_mode.h>

namespace OhosJitCapability {
namespace {

constexpr size_t kProbeSize = 4096;
std::once_flag g_probe_once;
bool g_probe_result = false;

// 坚盾守护模式开启时系统禁止应用申请匿名可写可执行内存；
// 该模式修改后需重启生效，探测时判定一次即可
bool IsSecureShieldModeEnabled() {
    const DSM_DeviceSecurityMode mode = HMS_DSM_GetDeviceSecurityMode();
    return (mode & DSM_SECURE_SHIELD_MODE) != 0;
}

// 尝试分配一页匿名可写可执行内存：依赖 ACL 权限
// ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY 生效且系统未拦截，
// 分配成功即认为 JIT 权限可用
bool ProbeWritableExecutableMemory() {
    void* region = mmap(nullptr, kProbeSize, PROT_READ | PROT_WRITE | PROT_EXEC,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (region == MAP_FAILED) {
        return false;
    }
    munmap(region, kProbeSize);
    return true;
}

} // namespace

bool DetectJitSupport(const std::string& device_type) {
    std::call_once(g_probe_once, [&device_type] {
        // 手机与坚盾守护模式必然不可用，直接判负跳过实际分配
        g_probe_result = device_type != "phone" && !IsSecureShieldModeEnabled() &&
                         ProbeWritableExecutableMemory();
    });
    return g_probe_result;
}

} // namespace OhosJitCapability
