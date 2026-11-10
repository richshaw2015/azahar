// Copyright 2020-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#pragma once

#include <string>
#include <vector>
#include "common/common_types.h"

namespace Core {

struct SaveStateInfo {
    u32 slot;
    u64 time;
    enum class ValidationStatus {
        OK,
        RevisionMismatch,
        BuildMismatch,
    } status;
    std::string build_name;
    std::string build_version;
};

constexpr u32 SaveStateSlotCount = 11; // Maximum count of savestate slots

// 即时存档序列化格式版本（对齐 melonDS SAVESTATE_MAJOR 的显式版本管理，取代 git SHA
// 作为兼容性判据）：仅在序列化布局发生不兼容变更时递增；新增字段等兼容变更应优先
// 用 BOOST_CLASS_VERSION 在各 serialize 内做版本分支，不必递增本值。
// 首个版本即 1：字段引入前的旧档头部读出 0，校验时归一化为 1 处理
constexpr u32 SaveStateFormatVersion = 1;

/// Returns the file path of the savestate for a given slot.
std::string GetSaveStatePath(u64 program_id, u64 movie_id, u32 slot);

std::vector<SaveStateInfo> ListSaveStates(u64 program_id, u64 movie_id,
                                          u32 max_slot = SaveStateSlotCount);

SaveStateInfo GetSaveStateInfo(u64 program_id, u64 movie_id, u32 slot);

} // namespace Core
