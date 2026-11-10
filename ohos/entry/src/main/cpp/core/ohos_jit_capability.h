// SPDX-FileCopyrightText: Copyright 2025 Azahar Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <string>

// JIT（动态重编译）运行时能力门禁，判定逻辑参考 nds 端 ohos_jit_capability。
// 能力在启动阶段首次判定时一次性探测并缓存：手机与坚盾守护模式直接判负跳过分配，
// 其余设备尝试分配匿名可写可执行内存，成功即认为具备 JIT 权限。
// 影响探测的条件（设备形态、坚盾、ACL 权限）会话内均不会变化，无需持久化与运行时复测。
// 用户设置允许（用户侧条件由 CoreBridge::EvaluateJitPolicy 叠加）。
namespace OhosJitCapability {

// 一次性探测 JIT 权限并缓存结果；后续调用直接返回缓存值，不再重复尝试分配。
// 结果以首个调用者传入的 device_type 为准
bool DetectJitSupport(const std::string& device_type);

} // namespace OhosJitCapability
