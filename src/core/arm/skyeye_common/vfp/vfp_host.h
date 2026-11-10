// Copyright 2025 Citra Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#pragma once

#include <atomic>
#include <optional>
#include "common/common_types.h"

struct ARMul_State;

namespace VfpHost {

// Fast-path coverage counters for on-device profiling.
inline std::atomic<u64> g_host_hits{0};
inline std::atomic<u64> g_host_misses{0};

// Attempts to execute one VFP data-processing instruction (the operand of
// vfp_single_cpdo / vfp_double_cpdo) directly on the host FPU.
//
// Returns the FPSCR exception/NZCV bits produced by the operation, or
// std::nullopt when the instruction or its operands are outside the fast-path
// domain and the caller must fall back to the softfloat implementation.
//
// Only scalar operations on normal-or-zero operands producing normal-or-zero
// results are handled; anything else (denormals, NaNs, infinities as
// arithmetic operands or results, vector mode, float->int rounding modes
// other than round-to-zero) falls back so that observable behaviour stays
// bit-identical to the softfloat path.
std::optional<u32> TryExecute(ARMul_State* state, u32 inst, u32 fpscr);

} // namespace VfpHost
