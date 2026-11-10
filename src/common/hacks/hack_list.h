// Copyright 2024-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#pragma once

#include <array>
#include "common/common_types.h"

namespace Common::Hacks {

enum class HackType : int {
    RIGHT_EYE_DISABLE,
    ACCURATE_MULTIPLICATION,
    DECRYPTION_AUTHORIZED,
    ONLINE_LLE_REQUIRED,
    REGION_FROM_SECURE,
    REQUIRES_SHADER_FIXUP,
    SPOOF_FRIEND_CODE_SEED,
    DELAY_TEXTURE_COPY_COMPLETION,

    // Per-title compatibility quirks ported from the Citra-MMJ game database.
    // Applied once when the title is loaded (see System::ApplyPerProgramHacks).
    // Local fork additions — keep at the END of the enum for merge friendliness.
    CPU_USAGE_LIMIT,       // shrink per-core CPU time slices (downcount shift)
    FMV_HACK,              // clamp CPU execution tick charge to unblock FMV playback
    SKIP_SLOW_DRAW,        // drop draws that cannot take the accelerated path
    SKIP_CPU_WRITE,        // keep cache surfaces valid on tiny CPU writes
    SKIP_TEXTURE_COPY,     // report texture copy as done when the src surface is missing
    Y2R_SKIP_CONVERSION,   // skip Y2R conversion while a completion event is pending
    DISABLE_CLIP_PLANES,   // compile shaders without clip-distance support
    FORCE_LINEAR_FILTER,   // force linear texture filtering when the game requests nearest
    DISPLAY_TRANSFER_FIXUP, // adjust display transfer dst address (TotA / Pac-Man)
    FORCE_NEW_3DS,         // run the title in New 3DS system mode
};

class UserHackData {};

/**
 * Per-title quirks that trade emulation accuracy for speed (Citra-MMJ port).
 * These are only applied when the user opts in via the game_perf_hacks
 * setting (see System::ApplyPerProgramHacks). The remaining ported quirks
 * (FORCE_NEW_3DS, DISPLAY_TRANSFER_FIXUP, FMV_HACK) are compatibility fixes
 * and always apply. ACCURATE_MULTIPLICATION is handled separately: only its
 * DISALLOW entries are a speed trade-off (see GPU::ApplyPerProgramSettings).
 */
constexpr bool IsPerfQuirk(HackType type) {
    switch (type) {
    case HackType::CPU_USAGE_LIMIT:
    case HackType::SKIP_SLOW_DRAW:
    case HackType::SKIP_CPU_WRITE:
    case HackType::SKIP_TEXTURE_COPY:
    case HackType::Y2R_SKIP_CONVERSION:
    case HackType::DISABLE_CLIP_PLANES:
    case HackType::FORCE_LINEAR_FILTER:
        return true;
    default:
        return false;
    }
}

// Per-core downcount shift values for HackType::CPU_USAGE_LIMIT.
// Timer::SetNextSlice computes downcount = slice_length >> shifts[core_id].
struct CpuLimitData : UserHackData {
    explicit CpuLimitData(std::array<u32, 4> value = {1, 4, 2, 2}) : shifts(value) {}
    std::array<u32, 4> shifts;
};

} // namespace Common::Hacks