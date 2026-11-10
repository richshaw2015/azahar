// Copyright Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#include "core/arm/ir/arm_ir_interpreter.h"

#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <limits>
#include <utility>

#if defined(__OHOS__)
#include <hilog/log.h>
#endif
#include "common/assert.h"
#include "common/common_funcs.h"
#include "common/logging/log.h"
#include "common/settings.h"
#if defined(__aarch64__)
#include "core/arm/asm/arm_asm_exec.h"
#include "core/arm/asm/arm_asm_layout.h"
#endif
#include "core/arm/skyeye_common/armsupp.h"
#include "core/arm/skyeye_common/armstate.h"
#include "core/arm/skyeye_common/vfp/vfp.h"
#include "core/arm/skyeye_common/vfp/vfp_host.h"
#include "core/core.h"
#include "core/core_timing.h"
#include "core/hle/kernel/svc.h"
#include "core/memory.h"
#ifdef ENABLE_GDBSTUB
#include "core/gdbstub/gdbstub.h"
#endif

namespace Core {

namespace {

constexpr u8 LazyFlagN = 1U << 0;
constexpr u8 LazyFlagZ = 1U << 1;
constexpr u8 LazyFlagC = 1U << 2;
constexpr u8 LazyFlagV = 1U << 3;
constexpr u8 LazyFlagNZ = LazyFlagN | LazyFlagZ;
constexpr u8 LazyFlagNZC = LazyFlagNZ | LazyFlagC;
constexpr u8 LazyFlagNZCV = LazyFlagNZC | LazyFlagV;

FORCE_INLINE u32 RotateRight(u32 value, u32 amount) {
    amount &= 31;
    return amount == 0 ? value : ((value >> amount) | (value << (32 - amount)));
}

FORCE_INLINE u32 CountLeadingZeros(u32 value) {
    return static_cast<u32>(std::countl_zero(value));
}

u32 PopLowestRegister(u32& register_list) {
    const u32 reg = static_cast<u32>(std::countr_zero(register_list));
    register_list &= register_list - 1;
    return reg;
}

u32 PopLowestRegisterRun(u32& register_list, u32& first_register) {
    first_register = static_cast<u32>(std::countr_zero(register_list));
    const u32 shifted_registers = register_list >> first_register;
    const u32 register_count = static_cast<u32>(std::countr_one(shifted_registers));

    const u32 register_mask =
        static_cast<u32>(((u64{1} << register_count) - 1) << first_register);
    register_list &= ~register_mask;
    return register_count;
}

s64 SignedFromU64(u64 value) {
    constexpr u64 SignBit = 0x8000000000000000ULL;
    constexpr u64 ValueMask = 0x7FFFFFFFFFFFFFFFULL;
    s64 result = static_cast<s64>(value & ValueMask);
    if ((value & SignBit) != 0) {
        result -= static_cast<s64>(ValueMask);
        result -= 1;
    }
    return result;
}

const char* FallbackReasonName(ARMIR::FallbackReason reason) {
    switch (reason) {
    case ARMIR::FallbackReason::BackendIncomplete:
        return "backend-incomplete";
    case ARMIR::FallbackReason::UnsupportedInstruction:
        return "unsupported-instruction";
    case ARMIR::FallbackReason::DecodeFailure:
        return "decode-failure";
    case ARMIR::FallbackReason::PendingInterrupt:
        return "pending-interrupt";
    }
    return "unknown";
}

#if defined(__OHOS__)
// Block-level breadcrumb ring for the OHOS asm fallback aborts: stderr never
// reaches hilog there, so the last few block transitions are dumped to a
// sandbox file when the fatal fallback path is hit.
struct IrBlockTrace {
    u32 pc;
    u32 cpsr_key;
    u32 aux0; // op_index/opcode or link source pc depending on kind
    u32 aux1; // Reg[15] or exit metadata
    u32 cpsr;
    u32 tflag_thumb_kind; // (tflag << 8) | (thumb << 4) | kind
};
constexpr u32 kIrTraceSize = 256;
thread_local IrBlockTrace g_ir_trace[kIrTraceSize];
thread_local u32 g_ir_trace_pos = 0;

void IrTracePush(u8 kind, u32 pc, u32 cpsr_key, u8 thumb, u32 aux0, u32 aux1, u32 cpsr,
                 u32 tflag) {
    // Tracing costs a ring write per block event; keep it gated behind the
    // verify flag so normal runs pay only one branch.
    if (!Settings::values.cpu_asm_verify.GetValue()) {
        return;
    }
    IrBlockTrace& e = g_ir_trace[g_ir_trace_pos % kIrTraceSize];
    e = {pc, cpsr_key, aux0, aux1, cpsr,
         (tflag << 8) | (static_cast<u32>(thumb) << 4) | kind};
    ++g_ir_trace_pos;
}

void IrTraceDump(FILE* f) {
    if (!f) {
        return;
    }
    const u32 n = std::min<u32>(g_ir_trace_pos, kIrTraceSize);
    const u32 start = g_ir_trace_pos - n;
    for (u32 i = 0; i < n; ++i) {
        const IrBlockTrace& e = g_ir_trace[(start + i) % kIrTraceSize];
        std::fprintf(f,
                     "  t%u: kind=%u pc=%08X ckey=%08x th=%u tf=%u aux0=%08X aux1=%08X "
                     "cpsr=%08X\n",
                     start + i, e.tflag_thumb_kind & 0xF, e.pc, e.cpsr_key,
                     (e.tflag_thumb_kind >> 4) & 0xF, (e.tflag_thumb_kind >> 8) & 1,
                     e.aux0, e.aux1, e.cpsr);
    }
}

FILE* IrAbortOpen() {
    const char* paths[] = {
        "/data/storage/el2/base/files/asm_abort.txt",
        "/data/app/el2/100/base/app.superedu.3ds/files/asm_abort.txt",
    };
    for (const char* p : paths) {
        if (FILE* f = std::fopen(p, "a")) {
            return f;
        }
    }
    return nullptr;
}

// Records every write to state->TFlag (the Cpsr T-bit mirror): pc = site id,
// cpsr_key = new value, aux1 = Reg[15] at the write.
#define IR_TRACE_TFLAG(expr, site)                                                          \
    do {                                                                                  \
        state->TFlag = (expr);                                                            \
        IrTracePush(7, (site), static_cast<u32>(state->TFlag != 0), 0, 0, state->Reg[15], \
                    state->Cpsr, state->TFlag != 0);                                      \
    } while (0)
#endif

#if !defined(__OHOS__)
#define IR_TRACE_TFLAG(expr, site) state->TFlag = (expr)
#endif

u32 SignExtend8(u32 value) {
    value &= 0xFF;
    return (value & 0x80) != 0 ? (value | 0xFFFFFF00) : value;
}

u32 SignExtend16(u32 value) {
    value &= 0xFFFF;
    return (value & 0x8000) != 0 ? (value | 0xFFFF0000) : value;
}

s32 SignedHalfword(u32 value, bool high) {
    return static_cast<s16>((value >> (high ? 16 : 0)) & 0xFFFF);
}

u32 SignedSaturateLane(s32 value, u32 bits) {
    const s32 min = -(1 << (bits - 1));
    const s32 max = (1 << (bits - 1)) - 1;
    const u32 mask = (1U << bits) - 1;
    if (value < min) {
        return static_cast<u32>(min) & mask;
    }
    if (value > max) {
        return static_cast<u32>(max);
    }
    return static_cast<u32>(value) & mask;
}

u32 UnsignedSaturatingAddLane(u32 left, u32 right, u32 max) {
    const u32 result = left + right;
    return result > max ? max : result;
}

u32 UnsignedSaturatingSubLane(u32 left, u32 right) {
    return left <= right ? 0 : left - right;
}

u32 SignedSaturationLimitFromWrappedResult(u32 value) {
    return (value & 0x80000000) == 0 ? 0x80000000 : 0x7FFFFFFF;
}

void SetGEFlag(ARMul_State& state, u32 lane, bool enabled) {
    const u32 mask = 1U << (16 + lane);
    if (enabled) {
        state.Cpsr |= mask;
    } else {
        state.Cpsr &= ~mask;
    }
}

void SetGEHalfwordFlags(ARMul_State& state, u32 halfword, bool enabled) {
    SetGEFlag(state, halfword * 2, enabled);
    SetGEFlag(state, halfword * 2 + 1, enabled);
}

u32 UnsignedAbsoluteDifference8(u32 left, u32 right) {
    left &= 0xFF;
    right &= 0xFF;
    return left > right ? left - right : right - left;
}

bool NeedsShifterCarry(u32 data_opcode, bool set_flags) {
    if (!set_flags) {
        return false;
    }

    switch (data_opcode) {
    case 0:  // AND
    case 1:  // EOR
    case 8:  // TST
    case 9:  // TEQ
    case 12: // ORR
    case 13: // MOV
    case 14: // BIC
    case 15: // MVN
        return true;
    default:
        return false;
    }
}

bool EvaluateLogicalWriteResult(u32 data_opcode, u32 rn_value, u32 operand, u32& data_result) {
    switch (data_opcode) {
    case 0: // AND
        data_result = rn_value & operand;
        return true;
    case 1: // EOR
        data_result = rn_value ^ operand;
        return true;
    case 12: // ORR
        data_result = rn_value | operand;
        return true;
    case 13: // MOV
        data_result = operand;
        return true;
    case 14: // BIC
        data_result = rn_value & ~operand;
        return true;
    case 15: // MVN
        data_result = ~operand;
        return true;
    default:
        return false;
    }
}

bool RegisterShiftOperandNeedsCarry(u32 shift_type, u32 shift_imm, bool register_shift_amount) {
    return !register_shift_amount && shift_type == 3 && shift_imm == 0;
}

struct ShiftedRegister {
    u32 value{};
    bool carry{};
};

struct AddWithCarryResult {
    u32 value{};
    bool carry{};
    bool overflow{};
};

AddWithCarryResult EvaluateAddWithCarry(u32 left, u32 right, u32 carry_in) {
    const u64 unsigned_sum =
        static_cast<u64>(left) + static_cast<u64>(right) + static_cast<u64>(carry_in);
    const s64 signed_sum = static_cast<s64>(static_cast<s32>(left)) +
                           static_cast<s64>(static_cast<s32>(right)) +
                           static_cast<s64>(carry_in);
    const u32 value = static_cast<u32>(unsigned_sum);
    return {
        .value = value,
        .carry = static_cast<u64>(value) != unsigned_sum,
        .overflow = static_cast<s64>(static_cast<s32>(value)) != signed_sum,
    };
}

FORCE_INLINE AddWithCarryResult EvaluateAddSubFlags(u32 left, u32 operand, bool subtract) {
    if (operand == 0) {
        return {
            .value = left,
            .carry = subtract,
            .overflow = false,
        };
    }
    return subtract ? EvaluateAddWithCarry(left, ~operand, 1)
                    : EvaluateAddWithCarry(left, operand, 0);
}

FORCE_INLINE AddWithCarryResult EvaluateCompareFlags(u32 left, u32 operand,
                                                     bool compare_negative) {
    if (operand == 0) {
        return {
            .value = left,
            .carry = !compare_negative,
            .overflow = false,
        };
    }
    return compare_negative ? EvaluateAddWithCarry(left, operand, 0)
                            : EvaluateAddWithCarry(left, ~operand, 1);
}

bool EvaluateCarryArithmeticWriteResult(u32 data_opcode, u32 rn_value, u32 operand, u32 carry_in,
                                        AddWithCarryResult& result) {
    switch (data_opcode) {
    case 3: // RSB
        result = EvaluateAddWithCarry(~rn_value, operand, 1);
        return true;
    case 5: // ADC
        result = EvaluateAddWithCarry(rn_value, operand, carry_in);
        return true;
    case 6: // SBC
        result = EvaluateAddWithCarry(rn_value, ~operand, carry_in);
        return true;
    case 7: // RSC
        result = EvaluateAddWithCarry(~rn_value, operand, carry_in);
        return true;
    default:
        return false;
    }
}

ShiftedRegister EvaluateShiftedRegisterValue(u32 rm_value, u32 shift_type, u32 shift_imm,
                                             bool c_flag) {
    switch (shift_type) {
    case 0: // LSL
        if (shift_imm == 0) {
            return {.value = rm_value, .carry = c_flag};
        }
        return {
            .value = rm_value << shift_imm,
            .carry = ((rm_value >> (32 - shift_imm)) & 1) != 0,
        };
    case 1: // LSR
        if (shift_imm == 0) {
            return {.value = 0, .carry = (rm_value >> 31) != 0};
        }
        return {
            .value = rm_value >> shift_imm,
            .carry = ((rm_value >> (shift_imm - 1)) & 1) != 0,
        };
    case 2: // ASR
        if (shift_imm == 0) {
            return {
                .value = (rm_value & 0x80000000) != 0 ? 0xFFFFFFFF : 0,
                .carry = (rm_value >> 31) != 0,
            };
        }
        return {
            .value = static_cast<u32>(static_cast<s32>(rm_value) >> shift_imm),
            .carry = ((rm_value >> (shift_imm - 1)) & 1) != 0,
        };
    case 3: // ROR / RRX
        if (shift_imm == 0) {
            return {
                .value = (c_flag ? 0x80000000 : 0) | (rm_value >> 1),
                .carry = (rm_value & 1) != 0,
            };
        }
        return {
            .value = RotateRight(rm_value, shift_imm),
            .carry = ((rm_value >> (shift_imm - 1)) & 1) != 0,
        };
    default:
        return {.value = rm_value, .carry = c_flag};
    }
}

ShiftedRegister EvaluateShiftedRegisterOperand(const ARMul_State& state, u32 rm, u32 shift_type,
                                                u32 shift_imm, bool c_flag) {
    return EvaluateShiftedRegisterValue(state.Reg[rm], shift_type, shift_imm, c_flag);
}

template <u32 ShiftType>
FORCE_INLINE ShiftedRegister EvaluateShiftedRegisterOperandByType(const ARMul_State& state, u32 rm,
                                                                  u32 shift_imm, bool c_flag) {
    const u32 rm_value = state.Reg[rm];
    if constexpr (ShiftType == 0) { // LSL
        if (shift_imm == 0) {
            return {.value = rm_value, .carry = c_flag};
        }
        return {
            .value = rm_value << shift_imm,
            .carry = ((rm_value >> (32 - shift_imm)) & 1) != 0,
        };
    } else if constexpr (ShiftType == 1) { // LSR
        if (shift_imm == 0) {
            return {.value = 0, .carry = (rm_value >> 31) != 0};
        }
        return {
            .value = rm_value >> shift_imm,
            .carry = ((rm_value >> (shift_imm - 1)) & 1) != 0,
        };
    } else if constexpr (ShiftType == 2) { // ASR
        if (shift_imm == 0) {
            return {
                .value = (rm_value & 0x80000000) != 0 ? 0xFFFFFFFF : 0,
                .carry = (rm_value >> 31) != 0,
            };
        }
        return {
            .value = static_cast<u32>(static_cast<s32>(rm_value) >> shift_imm),
            .carry = ((rm_value >> (shift_imm - 1)) & 1) != 0,
        };
    } else { // ROR / RRX
        if (shift_imm == 0) {
            return {
                .value = (c_flag ? 0x80000000 : 0) | (rm_value >> 1),
                .carry = (rm_value & 1) != 0,
            };
        }
        return {
            .value = RotateRight(rm_value, shift_imm),
            .carry = ((rm_value >> (shift_imm - 1)) & 1) != 0,
        };
    }
}

ShiftedRegister EvaluateRegisterShiftedRegisterOperand(const ARMul_State& state, u32 rm,
                                                       u32 shift_type, u32 rs, bool c_flag) {
    const u32 rm_value = state.Reg[rm];
    const u32 shift_amount = state.Reg[rs] & 0xFF;
    if (shift_amount == 0) {
        return {.value = rm_value, .carry = c_flag};
    }

    switch (shift_type) {
    case 0: // LSL
        if (shift_amount < 32) {
            return {
                .value = rm_value << shift_amount,
                .carry = ((rm_value >> (32 - shift_amount)) & 1) != 0,
            };
        }
        return {
            .value = 0,
            .carry = shift_amount == 32 && (rm_value & 1) != 0,
        };
    case 1: // LSR
        if (shift_amount < 32) {
            return {
                .value = rm_value >> shift_amount,
                .carry = ((rm_value >> (shift_amount - 1)) & 1) != 0,
            };
        }
        return {
            .value = 0,
            .carry = shift_amount == 32 && ((rm_value >> 31) & 1) != 0,
        };
    case 2: // ASR
        if (shift_amount < 32) {
            return {
                .value = static_cast<u32>(static_cast<s32>(rm_value) >> shift_amount),
                .carry = ((rm_value >> (shift_amount - 1)) & 1) != 0,
            };
        }
        return {
            .value = (rm_value & 0x80000000) != 0 ? 0xFFFFFFFF : 0,
            .carry = (rm_value >> 31) != 0,
        };
    case 3: { // ROR
        const u32 rotate = shift_amount & 31;
        if (rotate == 0) {
            return {
                .value = rm_value,
                .carry = (rm_value >> 31) != 0,
            };
        }
        return {
            .value = RotateRight(rm_value, rotate),
            .carry = ((rm_value >> (rotate - 1)) & 1) != 0,
        };
    }
    default:
        return {.value = rm_value, .carry = c_flag};
    }
}

template <u32 ShiftType>
FORCE_INLINE ShiftedRegister EvaluateRegisterShiftedRegisterOperandByType(
    const ARMul_State& state, u32 rm, u32 rs, bool c_flag) {
    const u32 rm_value = state.Reg[rm];
    const u32 shift_amount = state.Reg[rs] & 0xFF;
    if (shift_amount == 0) {
        return {.value = rm_value, .carry = c_flag};
    }

    if constexpr (ShiftType == 0) { // LSL
        if (shift_amount < 32) {
            return {
                .value = rm_value << shift_amount,
                .carry = ((rm_value >> (32 - shift_amount)) & 1) != 0,
            };
        }
        return {
            .value = 0,
            .carry = shift_amount == 32 && (rm_value & 1) != 0,
        };
    } else if constexpr (ShiftType == 1) { // LSR
        if (shift_amount < 32) {
            return {
                .value = rm_value >> shift_amount,
                .carry = ((rm_value >> (shift_amount - 1)) & 1) != 0,
            };
        }
        return {
            .value = 0,
            .carry = shift_amount == 32 && ((rm_value >> 31) & 1) != 0,
        };
    } else if constexpr (ShiftType == 2) { // ASR
        if (shift_amount < 32) {
            return {
                .value = static_cast<u32>(static_cast<s32>(rm_value) >> shift_amount),
                .carry = ((rm_value >> (shift_amount - 1)) & 1) != 0,
            };
        }
        return {
            .value = (rm_value & 0x80000000) != 0 ? 0xFFFFFFFF : 0,
            .carry = (rm_value >> 31) != 0,
        };
    } else { // ROR
        const u32 rotate = shift_amount & 31;
        if (rotate == 0) {
            return {
                .value = rm_value,
                .carry = (rm_value >> 31) != 0,
            };
        }
        return {
            .value = RotateRight(rm_value, rotate),
            .carry = ((rm_value >> (rotate - 1)) & 1) != 0,
        };
    }
}

u32 EvaluateAddressOffsetRegisterOperand(const ARMul_State& state, u32 rm, u32 shift_type,
                                         u32 shift_imm) {
    const u32 rm_value = state.Reg[rm];
    switch (shift_type) {
    case 0: // LSL
        return shift_imm == 0 ? rm_value : (rm_value << shift_imm);
    case 1: // LSR
        return shift_imm == 0 ? 0 : (rm_value >> shift_imm);
    case 2: // ASR
        return shift_imm == 0 ? ((rm_value & 0x80000000) != 0 ? 0xFFFFFFFF : 0)
                              : static_cast<u32>(static_cast<s32>(rm_value) >> shift_imm);
    case 3: // ROR; RRX is kept on the generic path because it consumes C.
        return RotateRight(rm_value, shift_imm);
    default:
        return rm_value;
    }
}

template <u32 ShiftType>
FORCE_INLINE u32 EvaluateAddressOffsetRegisterOperandByType(const ARMul_State& state, u32 rm,
                                                            u32 shift_imm) {
    const u32 rm_value = state.Reg[rm];
    if constexpr (ShiftType == 0) { // LSL
        return shift_imm == 0 ? rm_value : (rm_value << shift_imm);
    } else if constexpr (ShiftType == 1) { // LSR
        return shift_imm == 0 ? 0 : (rm_value >> shift_imm);
    } else if constexpr (ShiftType == 2) { // ASR
        return shift_imm == 0 ? ((rm_value & 0x80000000) != 0 ? 0xFFFFFFFF : 0)
                              : static_cast<u32>(static_cast<s32>(rm_value) >> shift_imm);
    } else { // ROR; RRX is kept on the generic path by the translator.
        return RotateRight(rm_value, shift_imm);
    }
}

FORCE_INLINE void AdvancePC(ARMul_State& state, const ARMIR::Op& op) {
    state.Reg[15] += op.guest_size;
}

FORCE_INLINE u32 ReadDataRegister(const ARMul_State& state, u32 reg, const ARMIR::Op& op) {
    return reg == 15 ? ((state.Reg[15] & ~1U) + op.guest_size * 2) : state.Reg[reg];
}

FORCE_INLINE u32 ReadAddressRegister(const ARMul_State& state, u32 reg, const ARMIR::Op& op) {
    return reg == 15 ? ((state.Reg[15] & ~3U) + op.guest_size * 2) : state.Reg[reg];
}

template <typename T>
T ReadUnaligned(const u8* pointer) {
    T value;
    std::memcpy(&value, pointer, sizeof(T));
    return value;
}

template <typename T>
void WriteUnaligned(u8* pointer, T value) {
    std::memcpy(pointer, &value, sizeof(T));
}

FORCE_INLINE void LoadRegisterRun(ARMul_State& state, u32 first_register, u32 register_count,
                                  const u8* pointer) {
    std::memcpy(&state.Reg[first_register], pointer, register_count * sizeof(u32));
}

FORCE_INLINE void StoreRegisterRun(const ARMul_State& state, u32 first_register,
                                   u32 register_count, u8* pointer) {
    std::memcpy(pointer, &state.Reg[first_register], register_count * sizeof(u32));
}

FORCE_INLINE bool IsTightSelfBranch(const ARMIR::Block& block) {
    if (block.terminal != ARMIR::Terminal::DirectBranch || block.ops.size() != 1) {
        return false;
    }

    const ARMIR::Op& op = block.ops[0];
    return op.opcode == ARMIR::Opcode::ArmBranchAlways && op.arg0 == block.key.pc;
}

FORCE_INLINE ARMIR::BlockKey MakeNextKeyWithPreservedCpsrKey(const ARMIR::Block& block, u32 pc) {
    return {
        .pc = block.thumb ? (pc & ~1U) : (pc & ~3U),
        .cpsr_key = block.key.cpsr_key,
    };
}

FORCE_INLINE std::size_t FastmemCacheIndex(u32 page, std::size_t cache_size) {
    const u32 mixed_page = page ^ (page >> 7) ^ (page >> 13);
    return mixed_page & (cache_size - 1);
}

constexpr bool ConditionPassedFromFlagIndex(u32 condition, u32 flag_index) {
    const bool n = (flag_index & 0b1000) != 0;
    const bool z = (flag_index & 0b0100) != 0;
    const bool c = (flag_index & 0b0010) != 0;
    const bool v = (flag_index & 0b0001) != 0;

    switch (condition) {
    case ConditionCode::EQ:
        return z;
    case ConditionCode::NE:
        return !z;
    case ConditionCode::CS:
        return c;
    case ConditionCode::CC:
        return !c;
    case ConditionCode::MI:
        return n;
    case ConditionCode::PL:
        return !n;
    case ConditionCode::VS:
        return v;
    case ConditionCode::VC:
        return !v;
    case ConditionCode::HI:
        return c && !z;
    case ConditionCode::LS:
        return !c || z;
    case ConditionCode::GE:
        return n == v;
    case ConditionCode::LT:
        return n != v;
    case ConditionCode::GT:
        return !z && n == v;
    case ConditionCode::LE:
        return z || n != v;
    default:
        return false;
    }
}

constexpr u16 MakeConditionPassMask(u32 condition) {
    u16 mask = 0;
    for (u32 flag_index = 0; flag_index < 16; ++flag_index) {
        if (ConditionPassedFromFlagIndex(condition, flag_index)) {
            mask |= static_cast<u16>(1U << flag_index);
        }
    }
    return mask;
}

constexpr std::array<u16, 16> ConditionPassMasks = {
    MakeConditionPassMask(ConditionCode::EQ), MakeConditionPassMask(ConditionCode::NE),
    MakeConditionPassMask(ConditionCode::CS), MakeConditionPassMask(ConditionCode::CC),
    MakeConditionPassMask(ConditionCode::MI), MakeConditionPassMask(ConditionCode::PL),
    MakeConditionPassMask(ConditionCode::VS), MakeConditionPassMask(ConditionCode::VC),
    MakeConditionPassMask(ConditionCode::HI), MakeConditionPassMask(ConditionCode::LS),
    MakeConditionPassMask(ConditionCode::GE), MakeConditionPassMask(ConditionCode::LT),
    MakeConditionPassMask(ConditionCode::GT), MakeConditionPassMask(ConditionCode::LE),
    MakeConditionPassMask(ConditionCode::AL), MakeConditionPassMask(ConditionCode::NV),
};
static_assert(ConditionPassMasks[ConditionCode::AL] == 0);
static_assert(ConditionPassMasks[ConditionCode::NV] == 0);

constexpr u32 ConditionUsesVFlagMask = (1U << ConditionCode::VS) | (1U << ConditionCode::VC) |
                                       (1U << ConditionCode::GE) | (1U << ConditionCode::LT) |
                                       (1U << ConditionCode::GT) | (1U << ConditionCode::LE);

FORCE_INLINE bool ConditionUsesVFlag(u32 condition) {
    return ((ConditionUsesVFlagMask >> (condition & 0xF)) & 1) != 0;
}

FORCE_INLINE bool ConditionPassedFromFlags(u32 condition, bool n, bool z, bool c, bool v) {
    DEBUG_ASSERT(condition < ConditionPassMasks.size());

    const u32 flag_index = (static_cast<u32>(n) << 3) | (static_cast<u32>(z) << 2) |
                           (static_cast<u32>(c) << 1) | static_cast<u32>(v);
    return ((ConditionPassMasks[condition & 0xF] >> flag_index) & 1) != 0;
}

} // namespace

namespace {
std::atomic<u64> g_next_ir_tag{1};

// Lazily assigns a stable per-page-table tag. The tag lives inside the
// PageTable itself so a recycled PageTable allocation (freed process, new
// process at the same address) starts with ir_tag == 0 and gets a fresh id
// rather than colliding with stale block-cache entries.
u64 IRTagForPageTable(Memory::PageTable* page_table) {
    if (!page_table) {
        return 0;
    }
    if (page_table->ir_tag == 0) {
        page_table->ir_tag = g_next_ir_tag.fetch_add(1, std::memory_order_relaxed);
    }
    return page_table->ir_tag;
}
} // namespace

ARM_IRInterpreter::ARM_IRInterpreter(Core::System& system, Memory::MemorySystem& memory,
                                     PrivilegeMode initial_mode, u32 id,
                                     std::shared_ptr<Core::Timing::Timer> timer)
    : ARM_Interface(id, std::move(timer)) {
    state = std::make_unique<ARMul_State>(system, memory, initial_mode);
    svc_context = std::make_unique<Kernel::SVCContext>(system);
    current_page_table = memory.GetCurrentPageTable();
    current_page_table_raw = current_page_table.get();
    current_block_tag = IRTagForPageTable(current_page_table_raw);
    current_fastmem_page_table_generation =
        current_page_table_raw ? current_page_table_raw->GetFastmemGeneration() : 0;
    block_cache.SetDenseCacheEnabled(Settings::values.use_cpu_ir_dense_cache.GetValue());
    LoadFlagsFromCpsr();
}

ARM_IRInterpreter::~ARM_IRInterpreter() = default;

std::atomic<u64> g_ir_guest_instructions{0};
std::atomic<u64> g_ir_time_ns{0};
std::atomic<u64> g_ir_blk_exec_ns{0};
std::atomic<u64> g_ir_svc_ns{0};
std::atomic<u64> g_ir_svc_count{0};
std::atomic<u64> g_ir_block_count{0};
std::atomic<u64> g_ir_lookup_ns{0};
std::atomic<u64> g_ir_link_current{0};
std::atomic<u64> g_ir_link_last{0};
std::atomic<u64> g_ir_link_slot{0};
std::atomic<u64> g_ir_link_miss{0};
std::atomic<u64> g_ir_acquire{0};
std::atomic<u64> g_ir_translations{0};
std::atomic<u64> g_ir_cache_clears{0};
std::atomic<u64> g_ir_invalidate_calls{0};
std::atomic<u64> g_ir_invalidate_erased{0};
bool g_ir_profile_opcodes{false};
bool g_ir_profile_blocks{false};
std::array<u64, ARMIR::OpcodeCount> g_ir_opcode_counts{};
std::array<u64, ARMIR::OpcodeCount> g_ir_opcode_ticks{};

void ARM_IRInterpreter::Run() {
    const u64 num_instructions = std::max<s64>(timer->GetDowncount(), 0);
    if (num_instructions == 0) {
        return;
    }
    if (break_flag) [[unlikely]] {
        return;
    }
    const ARMIR::BlockCache::Stats cache_before = block_cache.GetStats();
    const IRExecutionResult ir_result = ExecuteIRInstructions(num_instructions);
    const ARMIR::BlockCache::Stats cache_after = block_cache.GetStats();
    const bool used_fallback =
        ir_result.instructions < num_instructions && !ir_result.stop_execution;
    if (state->system.perf_stats) {
        state->system.perf_stats->ReportIRExecution(
            ir_result.instructions, ir_result.blocks, cache_after.lookups - cache_before.lookups,
            cache_after.dense_hits - cache_before.dense_hits,
            cache_after.translations - cache_before.translations, used_fallback ? 1 : 0);
    }
    if (ir_result.instructions < num_instructions && !ir_result.stop_execution) {
        HandleIRFallback(ir_result, num_instructions);
    }
    state->ServeBreak();
}

void ARM_IRInterpreter::Step() {
    if (break_flag) [[unlikely]] {
        return;
    }
    const IRExecutionResult ir_result = ExecuteIRInstructions(1);
    if (ir_result.instructions == 0 && !ir_result.stop_execution) {
        HandleIRFallback(ir_result, 1);
    }
    state->ServeBreak();
}

void ARM_IRInterpreter::ClearInstructionCache() {
    g_ir_cache_clears.fetch_add(1, std::memory_order_relaxed);
    block_cache.Clear();
    state->instruction_cache.clear();
#if defined(__aarch64__)
    ARMAsm::ClearChainTable(asm_chain_table);
#endif
}

void ARM_IRInterpreter::InvalidateCacheRange(u32 start_address, std::size_t length) {
    g_ir_invalidate_calls.fetch_add(1, std::memory_order_relaxed);
    block_cache.InvalidateRange(start_address, length);
    state->instruction_cache.clear();
#if defined(__aarch64__)
    ARMAsm::ClearChainTable(asm_chain_table);
#endif
}

void ARM_IRInterpreter::ClearExclusiveState() {
    state->UnsetExclusiveMemoryAddress();
}

void ARM_IRInterpreter::SetPageTable(const std::shared_ptr<Memory::PageTable>& page_table) {
    current_page_table = page_table;
    current_page_table_raw = current_page_table.get();
    current_block_tag = IRTagForPageTable(current_page_table_raw);
    current_fastmem_page_table_generation =
        current_page_table_raw ? current_page_table_raw->GetFastmemGeneration() : 0;
    ResetFastmemCache();
    // Translated blocks carry the page-table tag in their cache key, so a
    // process switch must not drop block_cache — doing so forced thousands of
    // full retranslations per second under frequent context switches. Only
    // the pc-keyed raw instruction cache and the asm chain table still need
    // clearing since they are not tag-segregated.
    state->instruction_cache.clear();
#if defined(__aarch64__)
    ARMAsm::ClearChainTable(asm_chain_table);
#endif
}

std::shared_ptr<Memory::PageTable> ARM_IRInterpreter::GetPageTable() const {
    return current_page_table;
}

void ARM_IRInterpreter::SetPC(u32 pc) {
    state->Reg[15] = pc;
}

u32 ARM_IRInterpreter::GetPC() const {
    return state->Reg[15];
}

u32 ARM_IRInterpreter::GetReg(int index) const {
    return state->Reg[index];
}

void ARM_IRInterpreter::SetReg(int index, u32 value) {
    state->Reg[index] = value;
}

u32 ARM_IRInterpreter::GetVFPReg(int index) const {
    return state->ExtReg[index];
}

void ARM_IRInterpreter::SetVFPReg(int index, u32 value) {
    state->ExtReg[index] = value;
}

u32 ARM_IRInterpreter::GetVFPSystemReg(VFPSystemRegister reg) const {
    return state->VFP[reg];
}

void ARM_IRInterpreter::SetVFPSystemReg(VFPSystemRegister reg, u32 value) {
    state->VFP[reg] = value;
}

u32 ARM_IRInterpreter::GetCPSR() const {
    return (state->Cpsr & 0x0FFFFFDF) | (static_cast<u32>(ReadNFlag()) << 31) |
           (static_cast<u32>(ReadZFlag()) << 30) | (static_cast<u32>(ReadCFlag()) << 29) |
           (static_cast<u32>(ReadVFlag()) << 28) | (state->TFlag << 5);
}

void ARM_IRInterpreter::SetCPSR(u32 cpsr) {
    state->Cpsr = cpsr;
    IR_TRACE_TFLAG((cpsr & TBIT) != 0, 1);
    LoadFlagsFromCpsr();
}

u32 ARM_IRInterpreter::GetCP15Register(CP15Register reg) const {
    return state->CP15[reg];
}

void ARM_IRInterpreter::SetCP15Register(CP15Register reg, u32 value) {
    state->CP15[reg] = value;
}

void ARM_IRInterpreter::SaveContext(ThreadContext& ctx) {
    ctx.cpu_registers = state->Reg;
    ctx.cpsr = GetCPSR();
    ctx.fpu_registers = state->ExtReg;
    ctx.fpscr = state->VFP[VFP_FPSCR];
    ctx.fpexc = state->VFP[VFP_FPEXC];
}

void ARM_IRInterpreter::LoadContext(const ThreadContext& ctx) {
    state->Reg = ctx.cpu_registers;
    state->Cpsr = ctx.cpsr;
    LoadFlagsFromCpsr();
    state->ExtReg = ctx.fpu_registers;
    state->VFP[VFP_FPSCR] = ctx.fpscr;
    state->VFP[VFP_FPEXC] = ctx.fpexc;
}

void ARM_IRInterpreter::PrepareReschedule() {
    state->NumInstrsToExecute = 0;
}

const ARMIR::Block& ARM_IRInterpreter::GetCurrentBlock() {
    const u32 pc = GetPC();
    return block_cache.GetOrTranslateBlock(
        ARMIR::BlockCache::MakeKey(pc, GetCpsrForBlockKey(), current_block_tag), state->memory);
}

FORCE_INLINE u32 ARM_IRInterpreter::GetCpsrForBlockKey() const {
    return (state->Cpsr & ~TBIT) | (state->TFlag << 5);
}

template <u32 Condition>
FORCE_INLINE bool ARM_IRInterpreter::ConditionPassedT() const {
    const bool lazy_valid = lazy_flags.valid;
    const u8 lazy_mask = lazy_flags.mask;
    if constexpr (Condition < ConditionCode::AL) {
        if (lazy_valid && (lazy_mask & LazyFlagNZCV) == LazyFlagNZCV) {
            return ConditionPassedFromFlags(Condition, lazy_flags.n != 0, lazy_flags.z != 0,
                                            lazy_flags.c != 0, lazy_flags.v != 0);
        }
    }

    const auto read_n = [this, lazy_valid, lazy_mask] {
        return lazy_valid && ((lazy_mask & LazyFlagN) != 0) ? lazy_flags.n != 0
                                                            : state->NFlag != 0;
    };
    const auto read_z = [this, lazy_valid, lazy_mask] {
        return lazy_valid && ((lazy_mask & LazyFlagZ) != 0) ? lazy_flags.z != 0
                                                            : state->ZFlag != 0;
    };
    const auto read_c = [this, lazy_valid, lazy_mask] {
        return lazy_valid && ((lazy_mask & LazyFlagC) != 0) ? lazy_flags.c != 0
                                                            : state->CFlag != 0;
    };
    const auto read_v = [this, lazy_valid, lazy_mask] {
        return lazy_valid && ((lazy_mask & LazyFlagV) != 0) ? lazy_flags.v != 0
                                                            : state->VFlag != 0;
    };

    if constexpr (Condition == ConditionCode::EQ) {
        return read_z();
    } else if constexpr (Condition == ConditionCode::NE) {
        return !read_z();
    } else if constexpr (Condition == ConditionCode::CS) {
        return read_c();
    } else if constexpr (Condition == ConditionCode::CC) {
        return !read_c();
    } else if constexpr (Condition == ConditionCode::MI) {
        return read_n();
    } else if constexpr (Condition == ConditionCode::PL) {
        return !read_n();
    } else if constexpr (Condition == ConditionCode::VS) {
        return read_v();
    } else if constexpr (Condition == ConditionCode::VC) {
        return !read_v();
    } else if constexpr (Condition == ConditionCode::HI) {
        return read_c() && !read_z();
    } else if constexpr (Condition == ConditionCode::LS) {
        return !read_c() || read_z();
    } else if constexpr (Condition == ConditionCode::GE) {
        return read_n() == read_v();
    } else if constexpr (Condition == ConditionCode::LT) {
        return read_n() != read_v();
    } else if constexpr (Condition == ConditionCode::GT) {
        return !read_z() && read_n() == read_v();
    } else if constexpr (Condition == ConditionCode::LE) {
        return read_z() || read_n() != read_v();
    } else {
        return Condition == ConditionCode::AL || Condition == ConditionCode::NV;
    }
}

template <bool ProfileOpcodes, bool CheckRemaining, u32 Condition>
FORCE_INLINE bool ARM_IRInterpreter::ExecuteConditionalSkipT(
    const ARMIR::Block& block, std::size_t& op_index, const ARMIR::Op& op,
    u64 remaining_instructions, IRBlockResult& result) {
    if constexpr (!CheckRemaining) {
        (void)block;
        (void)remaining_instructions;
    }

    if (ConditionPassedT<Condition>()) {
        return false;
    }

    const u32 skip_instructions = op.arg1;
    if constexpr (CheckRemaining) {
        const u64 remaining = remaining_instructions - result.instructions;
        if (remaining < skip_instructions) {
            u32 skipped_bytes = 0;
            for (u64 i = 0; i < remaining; ++i) {
                skipped_bytes += block.ops[op_index + 1 + i].guest_size;
            }
            state->Reg[15] += skipped_bytes;
            result.instructions += static_cast<u32>(remaining);
            if constexpr (ProfileOpcodes) {
                result.conditional_skipped_instructions += static_cast<u32>(remaining);
            }
            return true;
        }
    }

    state->Reg[15] += op.arg2;
    result.instructions += skip_instructions;
    if constexpr (ProfileOpcodes) {
        result.conditional_skipped_instructions += skip_instructions;
    }
    op_index += skip_instructions;
    return false;
}

void ARM_IRInterpreter::ExecuteDataProcessingNoFlags(u32 data_opcode, u32 rn_value, u32 rd,
                                                     u32 operand) {
    switch (data_opcode) {
    case 0: // AND
        state->Reg[rd] = rn_value & operand;
        return;
    case 1: // EOR
        state->Reg[rd] = rn_value ^ operand;
        return;
    case 2: // SUB
        state->Reg[rd] = rn_value - operand;
        return;
    case 3: // RSB
        state->Reg[rd] = operand - rn_value;
        return;
    case 4: // ADD
        state->Reg[rd] = rn_value + operand;
        return;
    case 5: { // ADC
        const u32 carry_in = ReadCFlag() ? 1 : 0;
        state->Reg[rd] = rn_value + operand + carry_in;
        return;
    }
    case 6: { // SBC
        const u32 carry_in = ReadCFlag() ? 1 : 0;
        state->Reg[rd] = rn_value + ~operand + carry_in;
        return;
    }
    case 7: { // RSC
        const u32 carry_in = ReadCFlag() ? 1 : 0;
        state->Reg[rd] = ~rn_value + operand + carry_in;
        return;
    }
    case 12: // ORR
        state->Reg[rd] = rn_value | operand;
        return;
    case 13: // MOV
        state->Reg[rd] = operand;
        return;
    case 14: // BIC
        state->Reg[rd] = rn_value & ~operand;
        return;
    case 15: // MVN
        state->Reg[rd] = ~operand;
        return;
    default:
        UNREACHABLE();
    }
}

void ARM_IRInterpreter::ExecuteDataProcessingSetFlags(u32 data_opcode, u32 rn_value, u32 rd,
                                                      u32 operand, bool shifter_carry) {
    u32 data_result = 0;
    bool carry = false;
    bool overflow = false;

    switch (data_opcode) {
    case 0: // AND
        data_result = rn_value & operand;
        state->Reg[rd] = data_result;
        SetLazyLogicalFlags(data_result, shifter_carry);
        return;
    case 1: // EOR
        data_result = rn_value ^ operand;
        state->Reg[rd] = data_result;
        SetLazyLogicalFlags(data_result, shifter_carry);
        return;
    case 2: { // SUB
        const AddWithCarryResult add = EvaluateAddWithCarry(rn_value, ~operand, 1);
        data_result = add.value;
        carry = add.carry;
        overflow = add.overflow;
        state->Reg[rd] = data_result;
        SetLazyArithmeticFlags(data_result, carry, overflow);
        return;
    }
    case 3: { // RSB
        const AddWithCarryResult add = EvaluateAddWithCarry(~rn_value, operand, 1);
        data_result = add.value;
        carry = add.carry;
        overflow = add.overflow;
        state->Reg[rd] = data_result;
        SetLazyArithmeticFlags(data_result, carry, overflow);
        return;
    }
    case 4: { // ADD
        const AddWithCarryResult add = EvaluateAddWithCarry(rn_value, operand, 0);
        data_result = add.value;
        carry = add.carry;
        overflow = add.overflow;
        state->Reg[rd] = data_result;
        SetLazyArithmeticFlags(data_result, carry, overflow);
        return;
    }
    case 5: { // ADC
        const u32 carry_in = ReadCFlag() ? 1 : 0;
        const AddWithCarryResult add = EvaluateAddWithCarry(rn_value, operand, carry_in);
        data_result = add.value;
        carry = add.carry;
        overflow = add.overflow;
        state->Reg[rd] = data_result;
        SetLazyArithmeticFlags(data_result, carry, overflow);
        return;
    }
    case 6: { // SBC
        const u32 carry_in = ReadCFlag() ? 1 : 0;
        const AddWithCarryResult add = EvaluateAddWithCarry(rn_value, ~operand, carry_in);
        data_result = add.value;
        carry = add.carry;
        overflow = add.overflow;
        state->Reg[rd] = data_result;
        SetLazyArithmeticFlags(data_result, carry, overflow);
        return;
    }
    case 7: { // RSC
        const u32 carry_in = ReadCFlag() ? 1 : 0;
        const AddWithCarryResult add = EvaluateAddWithCarry(~rn_value, operand, carry_in);
        data_result = add.value;
        carry = add.carry;
        overflow = add.overflow;
        state->Reg[rd] = data_result;
        SetLazyArithmeticFlags(data_result, carry, overflow);
        return;
    }
    case 8: // TST
        SetLazyLogicalFlags(rn_value & operand, shifter_carry);
        return;
    case 9: // TEQ
        SetLazyLogicalFlags(rn_value ^ operand, shifter_carry);
        return;
    case 10: { // CMP
        const AddWithCarryResult add = EvaluateAddWithCarry(rn_value, ~operand, 1);
        data_result = add.value;
        carry = add.carry;
        overflow = add.overflow;
        SetLazyArithmeticFlags(data_result, carry, overflow);
        return;
    }
    case 11: { // CMN
        const AddWithCarryResult add = EvaluateAddWithCarry(rn_value, operand, 0);
        data_result = add.value;
        carry = add.carry;
        overflow = add.overflow;
        SetLazyArithmeticFlags(data_result, carry, overflow);
        return;
    }
    case 12: // ORR
        data_result = rn_value | operand;
        state->Reg[rd] = data_result;
        SetLazyLogicalFlags(data_result, shifter_carry);
        return;
    case 13: // MOV
        data_result = operand;
        state->Reg[rd] = data_result;
        SetLazyLogicalFlags(data_result, shifter_carry);
        return;
    case 14: // BIC
        data_result = rn_value & ~operand;
        state->Reg[rd] = data_result;
        SetLazyLogicalFlags(data_result, shifter_carry);
        return;
    case 15: // MVN
        data_result = ~operand;
        state->Reg[rd] = data_result;
        SetLazyLogicalFlags(data_result, shifter_carry);
        return;
    default:
        UNREACHABLE();
    }
}

template <u32 ShiftType, bool Subtract>
FORCE_INLINE void ARM_IRInterpreter::ExecuteAddSubShiftedRegisterNoPc(const ARMIR::Op& op) {
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const u32 rm = (op.arg1 >> 16) & 0xF;
    const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
    const bool needs_c_flag = ShiftType == 3 && shift_imm == 0;
    const ShiftedRegister shifted = EvaluateShiftedRegisterOperandByType<ShiftType>(
        *state, rm, shift_imm, needs_c_flag ? ReadCFlag() : false);
    if constexpr (Subtract) {
        state->Reg[rd] = state->Reg[rn] - shifted.value;
    } else {
        state->Reg[rd] = state->Reg[rn] + shifted.value;
    }
}

template <u32 ShiftType, bool CompareNegative>
FORCE_INLINE void ARM_IRInterpreter::ExecuteCompareShiftedRegisterNoPc(const ARMIR::Op& op) {
    const u32 rn = op.arg1 & 0xF;
    const u32 rm = (op.arg1 >> 8) & 0xF;
    const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
    const bool needs_c_flag = ShiftType == 3 && shift_imm == 0;
    const ShiftedRegister shifted = EvaluateShiftedRegisterOperandByType<ShiftType>(
        *state, rm, shift_imm, needs_c_flag ? ReadCFlag() : false);
    const AddWithCarryResult add =
        EvaluateCompareFlags(state->Reg[rn], shifted.value, CompareNegative);
    SetLazyArithmeticFlags(add.value, add.carry, add.overflow);
}

template <u32 ShiftType, bool Subtract>
FORCE_INLINE void ARM_IRInterpreter::ExecuteAddSubShiftedRegisterSetFlagsNoPc(
    const ARMIR::Op& op) {
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const u32 rm = (op.arg1 >> 16) & 0xF;
    const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
    const bool needs_c_flag = ShiftType == 3 && shift_imm == 0;
    const ShiftedRegister shifted = EvaluateShiftedRegisterOperandByType<ShiftType>(
        *state, rm, shift_imm, needs_c_flag ? ReadCFlag() : false);
    const AddWithCarryResult add = EvaluateAddSubFlags(state->Reg[rn], shifted.value, Subtract);
    state->Reg[rd] = add.value;
    SetLazyArithmeticFlags(add.value, add.carry, add.overflow);
}

template <u32 ShiftType, bool CheckRemaining, bool Profile>
FORCE_INLINE void ARM_IRInterpreter::ExecuteAddSubShiftedRegisterSetFlagsBranchNoPc(
    const ARMIR::Op& op, u64 remaining_instructions, IRBlockResult& result) {
    if constexpr (!CheckRemaining) {
        (void)remaining_instructions;
    }

    const u32 rd = op.arg0 & 0xF;
    const u32 rn = (op.arg0 >> 4) & 0xF;
    const u32 rm = (op.arg0 >> 8) & 0xF;
    const bool subtract = ((op.arg0 >> 12) & 1) != 0;
    const u32 branch_condition = (op.arg0 >> 16) & 0xF;
    const u32 compare_guest_size = (op.arg0 >> 24) & 0xFF;
    const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
    const bool needs_c_flag = ShiftType == 3 && shift_imm == 0;
    const ShiftedRegister shifted = EvaluateShiftedRegisterOperandByType<ShiftType>(
        *state, rm, shift_imm, needs_c_flag ? ReadCFlag() : false);
    const AddWithCarryResult add = EvaluateAddSubFlags(state->Reg[rn], shifted.value, subtract);
    state->Reg[rd] = add.value;
    SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

    if constexpr (CheckRemaining) {
        if (remaining_instructions - result.instructions < 2) {
            state->Reg[15] += compare_guest_size;
            result.instructions++;
            return;
        }
    }

    const bool take_branch = ConditionPassedFromFlags(
        branch_condition, (add.value >> 31) != 0, add.value == 0, add.carry, add.overflow);
    CountFusedBranch<Profile>(result, take_branch);
    state->Reg[15] = take_branch ? op.arg1 : state->Reg[15] + op.guest_size;
    result.instructions += 2;
}

template <u32 ShiftType, bool SetFlags>
FORCE_INLINE bool ARM_IRInterpreter::ExecuteCarryArithmeticShiftedRegisterNoPc(
    const ARMIR::Op& op) {
    const u32 data_opcode = op.arg0 & 0xF;
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const u32 rm = (op.arg1 >> 16) & 0xF;
    const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
    const bool needs_c_flag = ShiftType == 3 && shift_imm == 0;
    const bool uses_carry = data_opcode != 3;
    const bool c_flag = (needs_c_flag || uses_carry) ? ReadCFlag() : false;
    const ShiftedRegister shifted = EvaluateShiftedRegisterOperandByType<ShiftType>(
        *state, rm, shift_imm, needs_c_flag ? c_flag : false);
    AddWithCarryResult add{};
    if (!EvaluateCarryArithmeticWriteResult(data_opcode, state->Reg[rn], shifted.value,
                                            uses_carry && c_flag ? 1 : 0, add)) {
        return false;
    }
    state->Reg[rd] = add.value;
    if constexpr (SetFlags) {
        SetLazyArithmeticFlags(add.value, add.carry, add.overflow);
    }
    return true;
}

template <u32 ShiftType, bool CheckRemaining, bool Profile>
FORCE_INLINE bool ARM_IRInterpreter::ExecuteCarryArithmeticShiftedRegisterSetFlagsBranchNoPc(
    const ARMIR::Op& op, u64 remaining_instructions, IRBlockResult& result) {
    if constexpr (!CheckRemaining) {
        (void)remaining_instructions;
    }

    const u32 data_opcode = op.arg0 & 0xF;
    const u32 rd = (op.arg0 >> 4) & 0xF;
    const u32 rn = (op.arg0 >> 8) & 0xF;
    const u32 rm = (op.arg0 >> 12) & 0xF;
    const u32 branch_condition = (op.arg0 >> 16) & 0xF;
    const u32 compare_guest_size = (op.arg0 >> 24) & 0xFF;
    const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
    const bool needs_c_flag = ShiftType == 3 && shift_imm == 0;
    const bool uses_carry = data_opcode != 3;
    const bool c_flag = (needs_c_flag || uses_carry) ? ReadCFlag() : false;
    const ShiftedRegister shifted = EvaluateShiftedRegisterOperandByType<ShiftType>(
        *state, rm, shift_imm, needs_c_flag ? c_flag : false);
    AddWithCarryResult add{};
    if (!EvaluateCarryArithmeticWriteResult(data_opcode, state->Reg[rn], shifted.value,
                                            uses_carry && c_flag ? 1 : 0, add)) {
        return false;
    }
    state->Reg[rd] = add.value;
    SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

    if constexpr (CheckRemaining) {
        if (remaining_instructions - result.instructions < 2) {
            state->Reg[15] += compare_guest_size;
            result.instructions++;
            return true;
        }
    }

    const bool take_branch = ConditionPassedFromFlags(
        branch_condition, (add.value >> 31) != 0, add.value == 0, add.carry, add.overflow);
    CountFusedBranch<Profile>(result, take_branch);
    state->Reg[15] = take_branch ? op.arg1 : state->Reg[15] + op.guest_size;
    result.instructions += 2;
    return true;
}

template <u32 ShiftType, bool Subtract>
FORCE_INLINE void ARM_IRInterpreter::ExecuteAddSubRegisterShiftedRegisterNoPc(
    const ARMIR::Op& op) {
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const u32 rm = (op.arg1 >> 16) & 0xF;
    const u32 rs = (op.arg1 >> 24) & 0xF;
    const ShiftedRegister shifted =
        EvaluateRegisterShiftedRegisterOperandByType<ShiftType>(*state, rm, rs, false);
    if constexpr (Subtract) {
        state->Reg[rd] = state->Reg[rn] - shifted.value;
    } else {
        state->Reg[rd] = state->Reg[rn] + shifted.value;
    }
}

template <u32 ShiftType, bool CompareNegative>
FORCE_INLINE void ARM_IRInterpreter::ExecuteCompareRegisterShiftedRegisterNoPc(
    const ARMIR::Op& op) {
    const u32 rn = op.arg1 & 0xF;
    const u32 rm = (op.arg1 >> 8) & 0xF;
    const u32 rs = (op.arg1 >> 16) & 0xF;
    const ShiftedRegister shifted =
        EvaluateRegisterShiftedRegisterOperandByType<ShiftType>(*state, rm, rs, false);
    const AddWithCarryResult add =
        EvaluateCompareFlags(state->Reg[rn], shifted.value, CompareNegative);
    SetLazyArithmeticFlags(add.value, add.carry, add.overflow);
}

template <u32 ShiftType, bool Subtract>
FORCE_INLINE void ARM_IRInterpreter::ExecuteAddSubRegisterShiftedRegisterSetFlagsNoPc(
    const ARMIR::Op& op) {
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const u32 rm = (op.arg1 >> 16) & 0xF;
    const u32 rs = (op.arg1 >> 24) & 0xF;
    const ShiftedRegister shifted =
        EvaluateRegisterShiftedRegisterOperandByType<ShiftType>(*state, rm, rs, false);
    const AddWithCarryResult add = EvaluateAddSubFlags(state->Reg[rn], shifted.value, Subtract);
    state->Reg[rd] = add.value;
    SetLazyArithmeticFlags(add.value, add.carry, add.overflow);
}

template <u32 ShiftType>
FORCE_INLINE bool ARM_IRInterpreter::ExecuteLogicalRegisterShiftedRegisterNoPc(
    const ARMIR::Op& op) {
    const u32 data_opcode = op.arg0 & 0xF;
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const u32 rm = (op.arg1 >> 16) & 0xF;
    const u32 rs = (op.arg1 >> 24) & 0xF;
    const ShiftedRegister shifted =
        EvaluateRegisterShiftedRegisterOperandByType<ShiftType>(*state, rm, rs, false);
    u32 data_result = 0;
    if (!EvaluateLogicalWriteResult(data_opcode, state->Reg[rn], shifted.value, data_result)) {
        return false;
    }
    state->Reg[rd] = data_result;
    return true;
}

template <u32 ShiftType>
FORCE_INLINE bool ARM_IRInterpreter::ExecuteLogicalRegisterShiftedRegisterSetFlagsNoPc(
    const ARMIR::Op& op) {
    const u32 data_opcode = op.arg0 & 0xF;
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const u32 rm = (op.arg1 >> 16) & 0xF;
    const u32 rs = (op.arg1 >> 24) & 0xF;
    const bool needs_c_flag = (state->Reg[rs] & 0xFF) == 0;
    const ShiftedRegister shifted = EvaluateRegisterShiftedRegisterOperandByType<ShiftType>(
        *state, rm, rs, needs_c_flag ? ReadCFlag() : false);

    u32 data_result = 0;
    bool write_result = true;
    switch (data_opcode) {
    case 0: // AND
        data_result = state->Reg[rn] & shifted.value;
        break;
    case 1: // EOR
        data_result = state->Reg[rn] ^ shifted.value;
        break;
    case 8: // TST
        data_result = state->Reg[rn] & shifted.value;
        write_result = false;
        break;
    case 9: // TEQ
        data_result = state->Reg[rn] ^ shifted.value;
        write_result = false;
        break;
    case 12: // ORR
        data_result = state->Reg[rn] | shifted.value;
        break;
    case 13: // MOV
        data_result = shifted.value;
        break;
    case 14: // BIC
        data_result = state->Reg[rn] & ~shifted.value;
        break;
    case 15: // MVN
        data_result = ~shifted.value;
        break;
    default:
        return false;
    }
    if (write_result) {
        state->Reg[rd] = data_result;
    }
    SetLazyLogicalFlags(data_result, shifted.carry);
    return true;
}

template <u32 ShiftType, bool SetFlags>
FORCE_INLINE bool ARM_IRInterpreter::ExecuteCarryArithmeticRegisterShiftedRegisterNoPc(
    const ARMIR::Op& op) {
    const u32 data_opcode = op.arg0 & 0xF;
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const u32 rm = (op.arg1 >> 16) & 0xF;
    const u32 rs = (op.arg1 >> 24) & 0xF;
    const bool uses_carry = data_opcode != 3;
    const u32 carry_in = uses_carry && ReadCFlag() ? 1 : 0;
    const ShiftedRegister shifted =
        EvaluateRegisterShiftedRegisterOperandByType<ShiftType>(*state, rm, rs, false);
    AddWithCarryResult add{};
    if (!EvaluateCarryArithmeticWriteResult(data_opcode, state->Reg[rn], shifted.value, carry_in,
                                            add)) {
        return false;
    }
    state->Reg[rd] = add.value;
    if constexpr (SetFlags) {
        SetLazyArithmeticFlags(add.value, add.carry, add.overflow);
    }
    return true;
}

template <u32 ShiftType, bool CompareNegative, bool CheckRemaining, bool Profile>
FORCE_INLINE void ARM_IRInterpreter::ExecuteCompareRegisterShiftedRegisterBranchNoPc(
    const ARMIR::Op& op, u64 remaining_instructions, IRBlockResult& result) {
    if constexpr (!CheckRemaining) {
        (void)remaining_instructions;
    }

    const u32 rn = op.arg0 & 0xF;
    const u32 rm = (op.arg0 >> 4) & 0xF;
    const u32 rs = (op.arg0 >> 8) & 0xF;
    const u32 branch_condition = (op.arg0 >> 16) & 0xF;
    const u32 compare_guest_size = (op.arg0 >> 24) & 0xFF;
    const ShiftedRegister shifted =
        EvaluateRegisterShiftedRegisterOperandByType<ShiftType>(*state, rm, rs, false);
    const AddWithCarryResult add =
        EvaluateCompareFlags(state->Reg[rn], shifted.value, CompareNegative);
    SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

    if constexpr (CheckRemaining) {
        if (remaining_instructions - result.instructions < 2) {
            state->Reg[15] += compare_guest_size;
            result.instructions++;
            return;
        }
    }

    const bool take_branch = ConditionPassedFromFlags(
        branch_condition, (add.value >> 31) != 0, add.value == 0, add.carry, add.overflow);
    CountFusedBranch<Profile>(result, take_branch);
    state->Reg[15] = take_branch ? op.arg1 : state->Reg[15] + op.guest_size;
    result.instructions += 2;
}

template <u32 ShiftType, bool CheckRemaining, bool Profile>
FORCE_INLINE void ARM_IRInterpreter::ExecuteTestRegisterShiftedRegisterBranchNoPc(
    const ARMIR::Op& op, u64 remaining_instructions, IRBlockResult& result) {
    if constexpr (!CheckRemaining) {
        (void)remaining_instructions;
    }

    const u32 rn = op.arg0 & 0xF;
    const u32 rm = (op.arg0 >> 4) & 0xF;
    const u32 rs = (op.arg0 >> 8) & 0xF;
    const bool test_equal = ((op.arg0 >> 12) & 1) != 0;
    const u32 branch_condition = (op.arg0 >> 16) & 0xF;
    const u32 compare_guest_size = (op.arg0 >> 24) & 0xFF;
    const bool needs_c_flag = (state->Reg[rs] & 0xFF) == 0;
    const ShiftedRegister shifted = EvaluateRegisterShiftedRegisterOperandByType<ShiftType>(
        *state, rm, rs, needs_c_flag ? ReadCFlag() : false);
    const bool overflow = ConditionUsesVFlag(branch_condition) ? ReadVFlag() : false;
    const u32 logical_result =
        test_equal ? (state->Reg[rn] ^ shifted.value) : (state->Reg[rn] & shifted.value);
    SetLazyLogicalFlags(logical_result, shifted.carry);

    if constexpr (CheckRemaining) {
        if (remaining_instructions - result.instructions < 2) {
            state->Reg[15] += compare_guest_size;
            result.instructions++;
            return;
        }
    }

    const bool take_branch =
        ConditionPassedFromFlags(branch_condition, (logical_result >> 31) != 0,
                                 logical_result == 0, shifted.carry, overflow);
    CountFusedBranch<Profile>(result, take_branch);
    state->Reg[15] = take_branch ? op.arg1 : state->Reg[15] + op.guest_size;
    result.instructions += 2;
}

template <u32 ShiftType, bool CheckRemaining, bool Profile>
FORCE_INLINE void ARM_IRInterpreter::ExecuteAddSubRegisterShiftedRegisterSetFlagsBranchNoPc(
    const ARMIR::Op& op, u64 remaining_instructions, IRBlockResult& result) {
    if constexpr (!CheckRemaining) {
        (void)remaining_instructions;
    }

    const u32 rd = op.arg0 & 0xF;
    const u32 rn = (op.arg0 >> 4) & 0xF;
    const u32 rm = (op.arg0 >> 8) & 0xF;
    const u32 rs = (op.arg0 >> 12) & 0xF;
    const bool subtract = ((op.arg0 >> 16) & 1) != 0;
    const u32 branch_condition = (op.arg0 >> 20) & 0xF;
    const u32 compare_guest_size = (op.arg0 >> 24) & 0xFF;
    const ShiftedRegister shifted =
        EvaluateRegisterShiftedRegisterOperandByType<ShiftType>(*state, rm, rs, false);
    const AddWithCarryResult add = EvaluateAddSubFlags(state->Reg[rn], shifted.value, subtract);
    state->Reg[rd] = add.value;
    SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

    if constexpr (CheckRemaining) {
        if (remaining_instructions - result.instructions < 2) {
            state->Reg[15] += compare_guest_size;
            result.instructions++;
            return;
        }
    }

    const bool take_branch = ConditionPassedFromFlags(
        branch_condition, (add.value >> 31) != 0, add.value == 0, add.carry, add.overflow);
    CountFusedBranch<Profile>(result, take_branch);
    state->Reg[15] = take_branch ? op.arg1 : state->Reg[15] + op.guest_size;
    result.instructions += 2;
}

template <u32 ShiftType, bool CheckRemaining, bool Profile>
FORCE_INLINE bool ARM_IRInterpreter::ExecuteLogicalRegisterShiftedRegisterSetFlagsBranchNoPc(
    const ARMIR::Op& op, u64 remaining_instructions, IRBlockResult& result) {
    if constexpr (!CheckRemaining) {
        (void)remaining_instructions;
    }

    const u32 data_opcode = op.arg0 & 0xF;
    const u32 rd = (op.arg0 >> 4) & 0xF;
    const u32 rn = (op.arg0 >> 8) & 0xF;
    const u32 rm = (op.arg0 >> 12) & 0xF;
    const u32 rs = (op.arg0 >> 16) & 0xF;
    const u32 branch_condition = (op.arg0 >> 20) & 0xF;
    const u32 compare_guest_size = (op.arg0 >> 24) & 0xFF;
    const bool needs_c_flag = (state->Reg[rs] & 0xFF) == 0;
    const ShiftedRegister shifted = EvaluateRegisterShiftedRegisterOperandByType<ShiftType>(
        *state, rm, rs, needs_c_flag ? ReadCFlag() : false);
    const bool overflow = ConditionUsesVFlag(branch_condition) ? ReadVFlag() : false;
    u32 data_result = 0;
    if (!EvaluateLogicalWriteResult(data_opcode, state->Reg[rn], shifted.value, data_result)) {
        return false;
    }
    state->Reg[rd] = data_result;
    SetLazyLogicalFlags(data_result, shifted.carry);

    if constexpr (CheckRemaining) {
        if (remaining_instructions - result.instructions < 2) {
            state->Reg[15] += compare_guest_size;
            result.instructions++;
            return true;
        }
    }

    const bool take_branch =
        ConditionPassedFromFlags(branch_condition, (data_result >> 31) != 0, data_result == 0,
                                 shifted.carry, overflow);
    CountFusedBranch<Profile>(result, take_branch);
    state->Reg[15] = take_branch ? op.arg1 : state->Reg[15] + op.guest_size;
    result.instructions += 2;
    return true;
}

template <u32 ShiftType, bool CheckRemaining, bool Profile>
FORCE_INLINE bool ARM_IRInterpreter::ExecuteCarryArithmeticRegisterShiftedRegisterSetFlagsBranchNoPc(
    const ARMIR::Op& op, u64 remaining_instructions, IRBlockResult& result) {
    if constexpr (!CheckRemaining) {
        (void)remaining_instructions;
    }

    const u32 data_opcode = op.arg0 & 0xF;
    const u32 rd = (op.arg0 >> 4) & 0xF;
    const u32 rn = (op.arg0 >> 8) & 0xF;
    const u32 rm = (op.arg0 >> 12) & 0xF;
    const u32 rs = (op.arg0 >> 16) & 0xF;
    const u32 branch_condition = (op.arg0 >> 20) & 0xF;
    const u32 compare_guest_size = (op.arg0 >> 24) & 0xFF;
    const u32 carry_in = data_opcode == 3 ? 0 : (ReadCFlag() ? 1 : 0);
    const ShiftedRegister shifted =
        EvaluateRegisterShiftedRegisterOperandByType<ShiftType>(*state, rm, rs, false);
    AddWithCarryResult add{};
    if (!EvaluateCarryArithmeticWriteResult(data_opcode, state->Reg[rn], shifted.value, carry_in,
                                            add)) {
        return false;
    }
    state->Reg[rd] = add.value;
    SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

    if constexpr (CheckRemaining) {
        if (remaining_instructions - result.instructions < 2) {
            state->Reg[15] += compare_guest_size;
            result.instructions++;
            return true;
        }
    }

    const bool take_branch = ConditionPassedFromFlags(
        branch_condition, (add.value >> 31) != 0, add.value == 0, add.carry, add.overflow);
    CountFusedBranch<Profile>(result, take_branch);
    state->Reg[15] = take_branch ? op.arg1 : state->Reg[15] + op.guest_size;
    result.instructions += 2;
    return true;
}

template <bool Profile>
FORCE_INLINE u8* ARM_IRInterpreter::GetFastMemoryPointerT(u32 address) {
    const u32 page = address >> Memory::CITRA_PAGE_BITS;
    if (current_fastmem_last_cache.valid && current_fastmem_last_cache.page == page) [[likely]] {
        if constexpr (Profile) {
            current_fastmem_page_cache_hits++;
        }
        return current_fastmem_last_cache.pointer;
    }
    if (current_fastmem_previous_cache.valid &&
        current_fastmem_previous_cache.page == page) [[likely]] {
        if constexpr (Profile) {
            current_fastmem_page_cache_hits++;
        }
        std::swap(current_fastmem_last_cache, current_fastmem_previous_cache);
        return current_fastmem_last_cache.pointer;
    }

    FastmemCacheEntry& entry = current_fastmem_cache[FastmemCacheIndex(
        page, current_fastmem_cache.size())];
    if (entry.valid && entry.generation == current_fastmem_cache_generation &&
        entry.page == page) {
        if constexpr (Profile) {
            current_fastmem_page_cache_hits++;
        }
        current_fastmem_previous_cache = current_fastmem_last_cache;
        current_fastmem_last_cache = entry;
        return entry.pointer;
    }
    if constexpr (Profile) {
        current_fastmem_page_cache_misses++;
    }
    if (!current_page_table_raw) {
        return nullptr;
    }

    u8* page_pointer = current_page_table_raw->pointers[page];
    entry = {
        .page = page,
        .generation = current_fastmem_cache_generation,
        .pointer = page_pointer,
        .valid = true,
    };
    current_fastmem_previous_cache = current_fastmem_last_cache;
    current_fastmem_last_cache = entry;
    return page_pointer;
}

template <bool Profile>
FORCE_INLINE u8* ARM_IRInterpreter::GetFastMemoryPointerForSpanT(u32 address, u32 bytes) {
    if (bytes == 0) {
        return GetFastMemoryPointerT<Profile>(address);
    }

    const u32 page_offset = address & Memory::CITRA_PAGE_MASK;
    if (bytes > Memory::CITRA_PAGE_SIZE || page_offset > Memory::CITRA_PAGE_SIZE - bytes) {
        return nullptr;
    }

    return GetFastMemoryPointerT<Profile>(address);
}

template <bool Profile, u32 Bytes>
FORCE_INLINE u8* ARM_IRInterpreter::GetFastMemoryPointerForAccessT(u32 address) {
    static_assert(Bytes > 0);
    if constexpr (Bytes > 1) {
        const u32 page_offset = address & Memory::CITRA_PAGE_MASK;
        if (page_offset > Memory::CITRA_PAGE_SIZE - Bytes) {
            return nullptr;
        }
    }
    return GetFastMemoryPointerT<Profile>(address);
}

template <bool Profile, bool BigEndian>
FORCE_INLINE bool ARM_IRInterpreter::TryFastReadMemory32T(u32 address, u32& value) {
    if constexpr (BigEndian) {
        return false;
    }
    if (const u8* page_pointer = GetFastMemoryPointerForAccessT<Profile, sizeof(u32)>(address)) {
        CountFastmemHitT<Profile>();
        value = ReadUnaligned<u32>(&page_pointer[address & Memory::CITRA_PAGE_MASK]);
        return true;
    }
    return false;
}

template <bool Profile, bool BigEndian>
FORCE_INLINE bool ARM_IRInterpreter::TryFastWriteMemory32T(u32 address, u32 value) {
    if constexpr (BigEndian) {
        return false;
    }
    if (u8* page_pointer = GetFastMemoryPointerForAccessT<Profile, sizeof(u32)>(address)) {
        CountFastmemHitT<Profile>();
        WriteUnaligned(&page_pointer[address & Memory::CITRA_PAGE_MASK], value);
        return true;
    }
    return false;
}

template <bool Profile, bool BigEndian>
FORCE_INLINE bool ARM_IRInterpreter::TryFastReadMemory16T(u32 address, u16& value) {
    if constexpr (BigEndian) {
        return false;
    }
    if (const u8* page_pointer = GetFastMemoryPointerForAccessT<Profile, sizeof(u16)>(address)) {
        CountFastmemHitT<Profile>();
        value = ReadUnaligned<u16>(&page_pointer[address & Memory::CITRA_PAGE_MASK]);
        return true;
    }
    return false;
}

template <bool Profile, bool BigEndian>
FORCE_INLINE bool ARM_IRInterpreter::TryFastWriteMemory16T(u32 address, u16 value) {
    if constexpr (BigEndian) {
        return false;
    }
    if (u8* page_pointer = GetFastMemoryPointerForAccessT<Profile, sizeof(u16)>(address)) {
        CountFastmemHitT<Profile>();
        WriteUnaligned(&page_pointer[address & Memory::CITRA_PAGE_MASK], value);
        return true;
    }
    return false;
}

template <bool Profile>
FORCE_INLINE u8 ARM_IRInterpreter::ReadMemory8T(u32 address) {
    if (const u8* page_pointer = GetFastMemoryPointerT<Profile>(address)) [[likely]] {
        CountFastmemHitT<Profile>();
        return page_pointer[address & Memory::CITRA_PAGE_MASK];
    }
    CountFastmemFallbackT<Profile>();
    return state->ReadMemory8(address);
}

template <bool Profile, bool BigEndian>
FORCE_INLINE u16 ARM_IRInterpreter::ReadMemory16T(u32 address) {
    if constexpr (!BigEndian) {
        if (const u8* page_pointer =
                GetFastMemoryPointerForAccessT<Profile, sizeof(u16)>(address)) [[likely]] {
            CountFastmemHitT<Profile>();
            return ReadUnaligned<u16>(&page_pointer[address & Memory::CITRA_PAGE_MASK]);
        }
    }
    CountFastmemFallbackT<Profile>();
    return state->ReadMemory16(address);
}

template <bool Profile, bool BigEndian>
FORCE_INLINE u32 ARM_IRInterpreter::ReadMemory32T(u32 address) {
    if constexpr (!BigEndian) {
        if (const u8* page_pointer =
                GetFastMemoryPointerForAccessT<Profile, sizeof(u32)>(address)) [[likely]] {
            CountFastmemHitT<Profile>();
            return ReadUnaligned<u32>(&page_pointer[address & Memory::CITRA_PAGE_MASK]);
        }
    }
    CountFastmemFallbackT<Profile>();
    return state->ReadMemory32(address);
}

template <bool Profile>
FORCE_INLINE void ARM_IRInterpreter::WriteMemory8T(u32 address, u8 value) {
    if (u8* page_pointer = GetFastMemoryPointerT<Profile>(address)) [[likely]] {
        CountFastmemHitT<Profile>();
        page_pointer[address & Memory::CITRA_PAGE_MASK] = value;
        return;
    }
    CountFastmemFallbackT<Profile>();
    state->WriteMemory8(address, value);
}

template <bool Profile, bool BigEndian>
FORCE_INLINE void ARM_IRInterpreter::WriteMemory16T(u32 address, u16 value) {
    if constexpr (!BigEndian) {
        if (u8* page_pointer =
                GetFastMemoryPointerForAccessT<Profile, sizeof(u16)>(address)) [[likely]] {
            CountFastmemHitT<Profile>();
            WriteUnaligned(&page_pointer[address & Memory::CITRA_PAGE_MASK], value);
            return;
        }
    }
    CountFastmemFallbackT<Profile>();
    state->WriteMemory16(address, value);
}

template <bool Profile, bool BigEndian>
FORCE_INLINE void ARM_IRInterpreter::WriteMemory32T(u32 address, u32 value) {
    if constexpr (!BigEndian) {
        if (u8* page_pointer =
                GetFastMemoryPointerForAccessT<Profile, sizeof(u32)>(address)) [[likely]] {
            CountFastmemHitT<Profile>();
            WriteUnaligned(&page_pointer[address & Memory::CITRA_PAGE_MASK], value);
            return;
        }
    }
    CountFastmemFallbackT<Profile>();
    state->WriteMemory32(address, value);
}

template <bool Profile, bool BigEndian>
FORCE_INLINE void ARM_IRInterpreter::WriteMemory64T(u32 address, u64 value) {
    if constexpr (!BigEndian) {
        if (u8* page_pointer =
                GetFastMemoryPointerForAccessT<Profile, sizeof(u64)>(address)) [[likely]] {
            CountFastmemHitT<Profile>();
            WriteUnaligned(&page_pointer[address & Memory::CITRA_PAGE_MASK], value);
            return;
        }
    }
    CountFastmemFallbackT<Profile>();
    state->WriteMemory64(address, value);
}

template <bool Profile, bool BigEndian, u32 ShiftType, bool Load, bool ByteTransfer>
FORCE_INLINE void ARM_IRInterpreter::ExecuteLoadStoreRegisterNoPc(const ARMIR::Op& op,
                                                                  IRBlockResult& result) {
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const u32 rm = (op.arg1 >> 16) & 0xF;
    const bool add_offset = ((op.arg1 >> 20) & 1) != 0;
    const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
    const u32 offset = EvaluateAddressOffsetRegisterOperandByType<ShiftType>(
        *state, rm, shift_imm);
    const u32 address = add_offset ? (state->Reg[rn] + offset) : (state->Reg[rn] - offset);

    if constexpr (Load) {
        if constexpr (ByteTransfer) {
            state->Reg[rd] = ReadMemory8T<Profile>(address);
        } else {
            state->Reg[rd] = ReadMemory32T<Profile, BigEndian>(address);
        }
    } else {
        if constexpr (ByteTransfer) {
            WriteMemory8T<Profile>(address, static_cast<u8>(state->Reg[rd]));
        } else {
            WriteMemory32T<Profile, BigEndian>(address, state->Reg[rd]);
        }
    }

    AdvancePC(*state, op);
    result.instructions++;
}

template <bool Profile, bool BigEndian, u32 ShiftType, bool Load, bool ByteTransfer>
FORCE_INLINE void ARM_IRInterpreter::ExecuteLoadStoreRegisterWriteback(const ARMIR::Op& op,
                                                                       IRBlockResult& result) {
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const u32 rm = (op.arg1 >> 16) & 0xF;
    const bool add_offset = ((op.arg1 >> 20) & 1) != 0;
    const bool pre_indexed = ((op.arg1 >> 21) & 1) != 0;
    const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
    const u32 offset = EvaluateAddressOffsetRegisterOperandByType<ShiftType>(
        *state, rm, shift_imm);
    const u32 base = state->Reg[rn];
    const u32 writeback_value = add_offset ? (base + offset) : (base - offset);
    const u32 address = pre_indexed ? writeback_value : base;

    if constexpr (Load) {
        if constexpr (ByteTransfer) {
            state->Reg[rd] = ReadMemory8T<Profile>(address);
        } else {
            state->Reg[rd] = ReadMemory32T<Profile, BigEndian>(address);
        }
    } else {
        if constexpr (ByteTransfer) {
            WriteMemory8T<Profile>(address, static_cast<u8>(state->Reg[rd]));
        } else {
            WriteMemory32T<Profile, BigEndian>(address, state->Reg[rd]);
        }
    }
    state->Reg[rn] = writeback_value;

    AdvancePC(*state, op);
    result.instructions++;
}

template <bool Profile, bool BigEndian, bool Load, bool ByteTransfer, bool Writeback>
FORCE_INLINE void ARM_IRInterpreter::DispatchLoadStoreRegisterByShiftType(
    const ARMIR::Op& op, IRBlockResult& result) {
    const u32 shift_type = op.arg2 & 0x3;
    switch (shift_type) {
    case 0:
        if constexpr (Writeback) {
            ExecuteLoadStoreRegisterWriteback<Profile, BigEndian, 0, Load, ByteTransfer>(op,
                                                                                        result);
        } else {
            ExecuteLoadStoreRegisterNoPc<Profile, BigEndian, 0, Load, ByteTransfer>(op, result);
        }
        break;
    case 1:
        if constexpr (Writeback) {
            ExecuteLoadStoreRegisterWriteback<Profile, BigEndian, 1, Load, ByteTransfer>(op,
                                                                                        result);
        } else {
            ExecuteLoadStoreRegisterNoPc<Profile, BigEndian, 1, Load, ByteTransfer>(op, result);
        }
        break;
    case 2:
        if constexpr (Writeback) {
            ExecuteLoadStoreRegisterWriteback<Profile, BigEndian, 2, Load, ByteTransfer>(op,
                                                                                        result);
        } else {
            ExecuteLoadStoreRegisterNoPc<Profile, BigEndian, 2, Load, ByteTransfer>(op, result);
        }
        break;
    case 3:
        if constexpr (Writeback) {
            ExecuteLoadStoreRegisterWriteback<Profile, BigEndian, 3, Load, ByteTransfer>(op,
                                                                                        result);
        } else {
            ExecuteLoadStoreRegisterNoPc<Profile, BigEndian, 3, Load, ByteTransfer>(op, result);
        }
        break;
    }
}

template <u32 ShiftType, bool CompareNegative, bool CheckRemaining, bool Profile>
FORCE_INLINE void ARM_IRInterpreter::ExecuteCompareShiftedRegisterBranchNoPc(
    const ARMIR::Op& op, u64 remaining_instructions, IRBlockResult& result) {
    if constexpr (!CheckRemaining) {
        (void)remaining_instructions;
    }

    const u32 rn = op.arg0 & 0xF;
    const u32 rm = (op.arg0 >> 4) & 0xF;
    const u32 branch_condition = (op.arg0 >> 12) & 0xF;
    const u32 compare_guest_size = (op.arg0 >> 16) & 0xFF;
    const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
    const bool needs_c_flag = ShiftType == 3 && shift_imm == 0;
    const ShiftedRegister shifted = EvaluateShiftedRegisterOperandByType<ShiftType>(
        *state, rm, shift_imm, needs_c_flag ? ReadCFlag() : false);
    const AddWithCarryResult add =
        EvaluateCompareFlags(state->Reg[rn], shifted.value, CompareNegative);
    SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

    if constexpr (CheckRemaining) {
        if (remaining_instructions - result.instructions < 2) {
            state->Reg[15] += compare_guest_size;
            result.instructions++;
            return;
        }
    }

    const bool take_branch = ConditionPassedFromFlags(
        branch_condition, (add.value >> 31) != 0, add.value == 0, add.carry, add.overflow);
    CountFusedBranch<Profile>(result, take_branch);
    state->Reg[15] = take_branch ? op.arg1 : state->Reg[15] + op.guest_size;
    result.instructions += 2;
}

template <u32 ShiftType, bool CheckRemaining, bool Profile>
FORCE_INLINE void ARM_IRInterpreter::ExecuteTestShiftedRegisterBranchNoPc(
    const ARMIR::Op& op, u64 remaining_instructions, IRBlockResult& result) {
    if constexpr (!CheckRemaining) {
        (void)remaining_instructions;
    }

    const u32 rn = op.arg0 & 0xF;
    const u32 rm = (op.arg0 >> 4) & 0xF;
    const bool test_equal = ((op.arg0 >> 8) & 1) != 0;
    const u32 branch_condition = (op.arg0 >> 12) & 0xF;
    const u32 compare_guest_size = (op.arg0 >> 16) & 0xFF;
    const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
    const bool needs_c_flag = (ShiftType == 0 && shift_imm == 0) ||
                              (ShiftType == 3 && shift_imm == 0);
    const ShiftedRegister shifted = EvaluateShiftedRegisterOperandByType<ShiftType>(
        *state, rm, shift_imm, needs_c_flag ? ReadCFlag() : false);
    const bool overflow = ConditionUsesVFlag(branch_condition) ? ReadVFlag() : false;
    const u32 logical_result =
        test_equal ? (state->Reg[rn] ^ shifted.value) : (state->Reg[rn] & shifted.value);
    SetLazyLogicalFlags(logical_result, shifted.carry);

    if constexpr (CheckRemaining) {
        if (remaining_instructions - result.instructions < 2) {
            state->Reg[15] += compare_guest_size;
            result.instructions++;
            return;
        }
    }

    const bool take_branch =
        ConditionPassedFromFlags(branch_condition, (logical_result >> 31) != 0,
                                 logical_result == 0, shifted.carry, overflow);
    CountFusedBranch<Profile>(result, take_branch);
    state->Reg[15] = take_branch ? op.arg1 : state->Reg[15] + op.guest_size;
    result.instructions += 2;
}

template <u32 ShiftType>
FORCE_INLINE bool ARM_IRInterpreter::ExecuteLogicalShiftedRegisterNoPc(const ARMIR::Op& op) {
    const u32 data_opcode = op.arg0 & 0xF;
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const u32 rm = (op.arg1 >> 16) & 0xF;
    const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
    const bool needs_c_flag = ShiftType == 3 && shift_imm == 0;
    const ShiftedRegister shifted = EvaluateShiftedRegisterOperandByType<ShiftType>(
        *state, rm, shift_imm, needs_c_flag ? ReadCFlag() : false);
    const u32 rn_value = state->Reg[rn];

    switch (data_opcode) {
    case 0: // AND
        state->Reg[rd] = rn_value & shifted.value;
        return true;
    case 1: // EOR
        state->Reg[rd] = rn_value ^ shifted.value;
        return true;
    case 12: // ORR
        state->Reg[rd] = rn_value | shifted.value;
        return true;
    case 13: // MOV
        state->Reg[rd] = shifted.value;
        return true;
    case 14: // BIC
        state->Reg[rd] = rn_value & ~shifted.value;
        return true;
    case 15: // MVN
        state->Reg[rd] = ~shifted.value;
        return true;
    default:
        return false;
    }
}

template <u32 ShiftType>
FORCE_INLINE bool ARM_IRInterpreter::ExecuteLogicalShiftedRegisterSetFlagsNoPc(
    const ARMIR::Op& op) {
    const u32 data_opcode = op.arg0 & 0xF;
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const u32 rm = (op.arg1 >> 16) & 0xF;
    const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
    const bool needs_c_flag = (ShiftType == 0 && shift_imm == 0) ||
                              (ShiftType == 3 && shift_imm == 0);
    const ShiftedRegister shifted = EvaluateShiftedRegisterOperandByType<ShiftType>(
        *state, rm, shift_imm, needs_c_flag ? ReadCFlag() : false);

    u32 data_result = 0;
    bool write_result = true;
    const u32 rn_value = state->Reg[rn];
    switch (data_opcode) {
    case 0: // AND
        data_result = rn_value & shifted.value;
        break;
    case 1: // EOR
        data_result = rn_value ^ shifted.value;
        break;
    case 8: // TST
        data_result = rn_value & shifted.value;
        write_result = false;
        break;
    case 9: // TEQ
        data_result = rn_value ^ shifted.value;
        write_result = false;
        break;
    case 12: // ORR
        data_result = rn_value | shifted.value;
        break;
    case 13: // MOV
        data_result = shifted.value;
        break;
    case 14: // BIC
        data_result = rn_value & ~shifted.value;
        break;
    case 15: // MVN
        data_result = ~shifted.value;
        break;
    default:
        return false;
    }
    if (write_result) {
        state->Reg[rd] = data_result;
    }
    SetLazyLogicalFlags(data_result, shifted.carry);
    return true;
}

template <u32 ShiftType, bool TestEqual>
FORCE_INLINE void ARM_IRInterpreter::ExecuteTestShiftedRegisterSetFlagsNoPc(
    const ARMIR::Op& op) {
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const u32 rm = (op.arg1 >> 16) & 0xF;
    const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
    const bool needs_c_flag = (ShiftType == 0 && shift_imm == 0) ||
                              (ShiftType == 3 && shift_imm == 0);
    const ShiftedRegister shifted = EvaluateShiftedRegisterOperandByType<ShiftType>(
        *state, rm, shift_imm, needs_c_flag ? ReadCFlag() : false);
    const u32 rn_value = state->Reg[rn];
    const u32 result = TestEqual ? (rn_value ^ shifted.value) : (rn_value & shifted.value);
    SetLazyLogicalFlags(result, shifted.carry);
}

template <u32 ShiftType, bool CheckRemaining, bool Profile>
FORCE_INLINE bool ARM_IRInterpreter::ExecuteLogicalShiftedRegisterSetFlagsBranchNoPc(
    const ARMIR::Op& op, u64 remaining_instructions, IRBlockResult& result) {
    if constexpr (!CheckRemaining) {
        (void)remaining_instructions;
    }

    const u32 data_opcode = op.arg0 & 0xF;
    const u32 rd = (op.arg0 >> 4) & 0xF;
    const u32 rn = (op.arg0 >> 8) & 0xF;
    const u32 rm = (op.arg0 >> 12) & 0xF;
    const u32 branch_condition = (op.arg0 >> 16) & 0xF;
    const u32 compare_guest_size = (op.arg0 >> 24) & 0xFF;
    const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
    const bool needs_c_flag = (ShiftType == 0 && shift_imm == 0) ||
                              (ShiftType == 3 && shift_imm == 0);
    const ShiftedRegister shifted = EvaluateShiftedRegisterOperandByType<ShiftType>(
        *state, rm, shift_imm, needs_c_flag ? ReadCFlag() : false);
    const bool overflow = ConditionUsesVFlag(branch_condition) ? ReadVFlag() : false;

    u32 data_result = 0;
    if (!EvaluateLogicalWriteResult(data_opcode, state->Reg[rn], shifted.value, data_result)) {
        return false;
    }
    state->Reg[rd] = data_result;
    SetLazyLogicalFlags(data_result, shifted.carry);

    if constexpr (CheckRemaining) {
        if (remaining_instructions - result.instructions < 2) {
            state->Reg[15] += compare_guest_size;
            result.instructions++;
            return true;
        }
    }

    const bool take_branch =
        ConditionPassedFromFlags(branch_condition, (data_result >> 31) != 0, data_result == 0,
                                 shifted.carry, overflow);
    CountFusedBranch<Profile>(result, take_branch);
    state->Reg[15] = take_branch ? op.arg1 : state->Reg[15] + op.guest_size;
    result.instructions += 2;
    return true;
}

ARM_IRInterpreter::IRExecutionResult ARM_IRInterpreter::ExecuteIRInstructions(u64 num_instructions) {
    IRExecutionResult result;
    if (num_instructions == 0) {
        return result;
    }
    const auto timing_t0 = std::chrono::steady_clock::now();
    const auto add_ir_time = [&] {
        g_ir_time_ns.fetch_add(
            static_cast<u64>(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                 std::chrono::steady_clock::now() - timing_t0)
                                 .count()),
            std::memory_order_relaxed);
    };

    RefreshFastmemCacheForCurrentPageTable();
    LoadFlagsFromCpsr();
    state->NumInstrsToExecute = num_instructions;
    const bool profile_blocks = g_ir_profile_blocks;
    u64 pending_ticks = 0;
    const ARMIR::Block* linked_block = nullptr;
#ifdef ENABLE_GDBSTUB
    const bool gdbstub_connected = GDBStub::IsConnected();
#else
    constexpr bool gdbstub_connected = false;
#endif

    while (result.instructions < num_instructions) {
        if (state->NumInstrsToExecute == 0) {
            result.stop_execution = true;
            break;
        }
        if (!state->NirqSig && !(state->Cpsr & IBIT)) {
            result.stop_execution = true;
            break;
        }
#ifdef ENABLE_GDBSTUB
        if (gdbstub_connected) [[unlikely]] {
            const u32 execution_pc = state->TFlag ? (state->Reg[15] & ~1U) : (state->Reg[15] & ~3U);
            state->Reg[15] = execution_pc;
            if (GDBStub::CheckBreakpoint(execution_pc, state->GetInstructionSize(),
                                         GDBStub::BreakpointType::Execute)) {
                state->RecordBreak({
                    .address = execution_pc,
                    .type = GDBStub::BreakpointType::Execute,
                });
                result.stop_execution = true;
                break;
            }
        }
#endif

        const ARMIR::Block* block_to_execute = linked_block;
        if (!linked_block) {
            const auto acq_t0 =
                profile_blocks ? std::chrono::steady_clock::now()
                               : std::chrono::steady_clock::time_point{};
            if (state->TFlag) {
                state->Reg[15] &= 0xFFFFFFFE;
            } else {
                state->Reg[15] &= 0xFFFFFFFC;
            }
            const ARMIR::BlockKey current_key = ARMIR::BlockCache::MakeKey(
                state->Reg[15], GetCpsrForBlockKey(), current_block_tag);
            block_to_execute = &block_cache.GetOrTranslateBlock(current_key, state->memory);
            if (profile_blocks) {
                g_ir_lookup_ns.fetch_add(
                    static_cast<u64>(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                         std::chrono::steady_clock::now() - acq_t0)
                                         .count()),
                    std::memory_order_relaxed);
                g_ir_acquire.fetch_add(1, std::memory_order_relaxed);
            }
        }
        linked_block = nullptr;
        const ARMIR::Block& block = *block_to_execute;
        if (!gdbstub_connected && IsTightSelfBranch(block)) {
            const u64 loop_instructions = num_instructions - result.instructions;
            result.instructions += loop_instructions;
            pending_ticks += loop_instructions;
            state->NumInstrsToExecute = 0;
            state->Reg[15] = block.key.pc;
            break;
        }

        const u64 remaining_instructions = num_instructions - result.instructions;
        const u64 block_remaining_instructions = gdbstub_connected ? 1 : remaining_instructions;
        const bool check_remaining =
            gdbstub_connected ||
            remaining_instructions < static_cast<u64>(block.guest_instruction_count);
        const bool block_big_endian = (block.key.cpsr_key & EBIT) != 0;
        const bool profile = g_ir_profile_opcodes;
        const auto blk_t0 = profile_blocks ? std::chrono::steady_clock::now()
                                           : std::chrono::steady_clock::time_point{};
        const IRBlockResult block_result =
            profile
                ? (block_big_endian
                       ? (check_remaining
                              ? TryExecuteBlock<true, true, true>(block,
                                                                 block_remaining_instructions,
                                                                 &g_ir_opcode_counts)
                              : TryExecuteBlock<true, false, true>(
                                     block, block_remaining_instructions, &g_ir_opcode_counts))
                       : (check_remaining
                              ? TryExecuteBlock<true, true, false>(block,
                                                                  block_remaining_instructions,
                                                                  &g_ir_opcode_counts)
                              : TryExecuteBlock<true, false, false>(
                                     block, block_remaining_instructions, &g_ir_opcode_counts)))
                : (block_big_endian
                       ? (check_remaining
                              ? TryExecuteBlock<false, true, true>(block,
                                                                  block_remaining_instructions,
                                                                  nullptr)
                              : TryExecuteBlock<false, false, true>(
                                     block, block_remaining_instructions, nullptr))
                       : (check_remaining
                              ? TryExecuteBlock<false, true, false>(block,
                                                                   block_remaining_instructions,
                                                                   nullptr)
                              : TryExecuteBlock<false, false, false>(
                                     block, block_remaining_instructions, nullptr)));
        if (profile_blocks) {
            g_ir_blk_exec_ns.fetch_add(
                static_cast<u64>(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                     std::chrono::steady_clock::now() - blk_t0)
                                     .count()),
                std::memory_order_relaxed);
            g_ir_block_count.fetch_add(block_result.blocks, std::memory_order_relaxed);
        }
        result.blocks += block_result.blocks;
        if (block_result.instructions == 0 && block_result.needs_fallback) {
            result.fallback_pc = block_result.fallback_pc;
            result.fallback_instruction = block_result.fallback_instruction;
            result.fallback_reason = block_result.fallback_reason;
            result.fallback_thumb = block_result.fallback_thumb;
            break;
        }

        result.instructions += block_result.instructions;
        pending_ticks += block_result.instructions;
        state->NumInstrsToExecute =
            result.instructions >= num_instructions ? 0 : num_instructions - result.instructions;
        if (block_result.supervisor_call) {
            const auto svc_t0 =
                profile_blocks ? std::chrono::steady_clock::now()
                               : std::chrono::steady_clock::time_point{};
            SaveFlagsToCpsr();
            if (pending_ticks != 0 && timer) {
                // Citra-MMJ compat (FMV_HACK): charge a minimum tick count before entering the SVC.
                timer->AddTicks(
                    std::max(pending_ticks, static_cast<u64>(Settings::values.core_ticks_hack)));
                pending_ticks = 0;
            }
            svc_context->CallSVC(block_result.supervisor_call_immediate & 0xFFFF);
            RefreshFastmemCacheForCurrentPageTable();
            state->UnsetExclusiveMemoryAddress();
            state->Reg[15] += block_result.supervisor_call_guest_size;
            LoadFlagsFromCpsr();
            if (profile_blocks) {
                g_ir_svc_ns.fetch_add(
                    static_cast<u64>(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                         std::chrono::steady_clock::now() - svc_t0)
                                         .count()),
                    std::memory_order_relaxed);
                g_ir_svc_count.fetch_add(1, std::memory_order_relaxed);
            }
            if (state->NumInstrsToExecute == 0) {
                result.stop_execution = true;
                break;
            }
            continue;
        }
        if (block_result.stop_execution) {
            result.stop_execution = true;
            break;
        }
        if (block_result.needs_fallback) {
            result.fallback_pc = block_result.fallback_pc;
            result.fallback_instruction = block_result.fallback_instruction;
            result.fallback_reason = block_result.fallback_reason;
            result.fallback_thumb = block_result.fallback_thumb;
            break;
        }

        if (result.instructions < num_instructions && (state->NirqSig || (state->Cpsr & IBIT))) {
            const auto link_t0 =
                profile_blocks ? std::chrono::steady_clock::now()
                               : std::chrono::steady_clock::time_point{};
            // When TryExecuteBlock chained blocks it reports the chain's tail
            // block plus the successor key it could not chain to; resolve
            // from those instead of the originally entered block.
            const ARMIR::Block& link_src =
                block_result.link_source ? *block_result.link_source : block;
            const ARMIR::BlockKey next_key =
                block_result.link_source
                    ? block_result.link_key
                    : (block.direct_branch_preserves_cpsr_key
                           ? MakeNextKeyWithPreservedCpsrKey(block, state->Reg[15])
                           : ARMIR::BlockCache::MakeKey(state->Reg[15], GetCpsrForBlockKey(),
                                                        current_block_tag));
#if defined(__OHOS__)
            u32 link_via = 9;
#endif
            if (block_cache.IsBlockCurrent(link_src, next_key)) {
                linked_block = &link_src;
#if defined(__OHOS__)
                link_via = 0;
#endif
                if (profile_blocks) {
                    g_ir_link_current.fetch_add(1, std::memory_order_relaxed);
                }
            } else {
                const ARMIR::BlockLink& last_link = link_src.links.last;
                if (last_link.valid && last_link.key == next_key) {
                    linked_block = last_link.block;
#if defined(__OHOS__)
                    link_via = 1;
#endif
                    if (profile_blocks) {
                        g_ir_link_last.fetch_add(1, std::memory_order_relaxed);
                    }
                } else if (const ARMIR::Block* cached_link =
                               ARMIR::BlockCache::LookupBlockLinkAfterLastMiss(link_src,
                                                                               next_key)) {
                    linked_block = cached_link;
#if defined(__OHOS__)
                    link_via = 2;
#endif
                    if (profile_blocks) {
                        g_ir_link_slot.fetch_add(1, std::memory_order_relaxed);
                    }
                } else {
                    linked_block = &block_cache.GetOrTranslateLinkedBlockAfterLinkMiss(
                        link_src, next_key, state->memory);
#if defined(__OHOS__)
                    link_via = 3;
#endif
                    if (profile_blocks) {
                        g_ir_link_miss.fetch_add(1, std::memory_order_relaxed);
                    }
                }
            }
#if defined(__OHOS__)
            IrTracePush(4, next_key.pc, next_key.cpsr_key,
                        static_cast<u8>(link_src.thumb),
                        link_src.key.pc |
                            (block.direct_branch_preserves_cpsr_key ? 0x80000000u : 0) |
                            (block_result.link_source ? 0x40000000u : 0),
                        link_via | (linked_block ? static_cast<u32>(linked_block->thumb) << 8 : 0x80u),
                        state->Cpsr, state->TFlag != 0);
#endif
            if (profile_blocks) {
                g_ir_lookup_ns.fetch_add(
                    static_cast<u64>(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                         std::chrono::steady_clock::now() - link_t0)
                                         .count()),
                    std::memory_order_relaxed);
            }
        }
    }

    SaveFlagsToCpsr();
    if (pending_ticks != 0 && timer) {
        timer->AddTicks(pending_ticks);
    }
    g_ir_guest_instructions.fetch_add(result.instructions, std::memory_order_relaxed);
    add_ir_time();
    return result;
}

#if defined(__aarch64__)
// Returned by ExecuteAsmPrefix when the whole block was consumed in
// assembly. Any other value is the C++ op index to continue from.
constexpr std::size_t kAsmCompletedBlock = ~std::size_t{0};

// An asm run that bails on a slow op after fewer than this many guest
// instructions paid the prologue/epilogue for nothing; after
// kAsmBadRunSkipThreshold such runs in a row the block stays on C++.
constexpr u32 kAsmMinUsefulOps = 4;
constexpr u8 kAsmBadRunSkipThreshold = 4;

// True when the op can write guest memory if the asm executor runs it.
// Verification replays a span with the pure C++ engine only when the span is
// airtight: if asm stores could commit before the replay, the replay's loads
// would observe the new values and report false mismatches on read-back
// patterns. Store-side bugs still surface indirectly when a later store-free
// block consumes the corrupted data.
static bool OpMayStoreGuestMemory(const ARMIR::Op& op) {
    using Opcode = ARMIR::Opcode;
    switch (op.opcode) {
    case Opcode::ArmLoadStoreImmediate:
    case Opcode::ArmLoadStoreRegister:
        return (op.arg0 & 1) == 0;
    case Opcode::ArmLoadStoreHalfword:
    case Opcode::ArmLoadStoreDouble:
    case Opcode::ArmLoadStoreMultiple:
        return ((op.arg0 >> 8) & 1) == 0;
    case Opcode::ArmVFPLoadStore:
        return ((op.arg0 >> 8) & 1) == 0;
    case Opcode::ArmExclusiveStore:
    case Opcode::ArmSwap:
    case Opcode::ArmStoreReturnState:
    case Opcode::ArmStoreWordImmediate:
    case Opcode::ArmStoreWordRegister:
    case Opcode::ArmStoreByteImmediate:
    case Opcode::ArmStoreByteRegister:
    case Opcode::ArmStoreHalfwordImmediate:
    case Opcode::ArmStoreHalfwordRegister:
    case Opcode::ArmStoreWordImmediateWriteback:
    case Opcode::ArmStoreByteImmediateWriteback:
    case Opcode::ArmStoreWordRegisterWriteback:
    case Opcode::ArmStoreByteRegisterWriteback:
    case Opcode::ArmStoreHalfwordImmediateWriteback:
    case Opcode::ArmStoreHalfwordRegisterWriteback:
    case Opcode::ArmStoreMultipleFast:
    case Opcode::ArmVFPStoreSingleFast:
    case Opcode::ArmVFPStoreDoubleFast:
    case Opcode::ArmVFPStoreMultipleFast:
    case Opcode::ArmStoreDoubleFast:
    case Opcode::ArmStoreWordImmediateNoPc:
    case Opcode::ArmStoreByteImmediateNoPc:
    case Opcode::ArmStoreWordRegisterNoPc:
    case Opcode::ArmStoreByteRegisterNoPc:
    case Opcode::ArmStoreHalfwordImmediateNoPc:
    case Opcode::ArmStoreHalfwordRegisterNoPc:
    case Opcode::ArmStoreWordImmediateNoPcAdd:
    case Opcode::ArmStoreWordImmediateNoPcSub:
    case Opcode::ArmStoreByteImmediateNoPcAdd:
    case Opcode::ArmStoreByteImmediateNoPcSub:
    case Opcode::ArmStoreHalfwordImmediateNoPcAdd:
    case Opcode::ArmStoreHalfwordImmediateNoPcSub:
    case Opcode::ArmStoreWordRegisterNoPcAdd:
    case Opcode::ArmStoreWordRegisterNoPcSub:
    case Opcode::ArmStoreByteRegisterNoPcAdd:
    case Opcode::ArmStoreByteRegisterNoPcSub:
    case Opcode::ArmStoreHalfwordRegisterNoPcAdd:
    case Opcode::ArmStoreHalfwordRegisterNoPcSub:
    case Opcode::ArmStoreWordImmediateNoPcOffset0:
    case Opcode::ArmStoreByteImmediateNoPcOffset0:
    case Opcode::ArmStoreHalfwordImmediateNoPcOffset0:
        return true;
    case Opcode::Count:
    default:
        return false;
    }
}

template <bool CheckRemaining>
std::size_t ARM_IRInterpreter::ExecuteAsmPrefix(const ARMIR::Block& block,
                                              u64 remaining_instructions,
                                              IRBlockResult& result) {
    if (!Settings::values.use_cpu_asm_interpreter.GetValue() || asm_verify_active) {
        return 0;
    }
    if (!current_page_table_raw) {
        return 0;
    }
    if (!block.asm_program) {
        block.asm_program = ARMAsm::BuildProgram(block);
        ++ARMAsm::g_asm_stats.programs_built;
    }
    // Register unconditionally so blocks skipped by the budget check below
    // (slice-tail runs) can still serve as inbound chain targets — the chain
    // probe re-checks the budget itself before jumping.
    ARMAsm::RegisterChainEntry(asm_chain_table, block.key.pc, block.key.cpsr_key,
                               block.asm_program->ops.data(),
                               block.guest_instruction_count,
                               block.asm_program->resmask);
    if constexpr (CheckRemaining) {
        // The assembly path always consumes whole ops; the C++ fused-op
        // handlers have CheckRemaining early exits that only trigger when
        // the block does not fit the budget. Refuse asm in that case so
        // the C++ loop keeps its exact accounting.
        if (block.guest_instruction_count > remaining_instructions) {
            return 0;
        }
    }
    // Refused entries never amortize the run prologue (~50 host insns)
    // against a handful of fast ops. The chain entry above is registered
    // anyway: inbound chain jumps into this block carry no prologue cost.
    if (block.asm_bad_runs >= kAsmBadRunSkipThreshold) {
        ++ARMAsm::g_asm_stats.skipped_runs;
        return 0;
    }
    // Differential verify aid: snapshot entry state so the same guest
    // instruction span can be replayed by the pure C++ engine afterwards.
    // Only store-free blocks are verifiable this way: asm stores commit to
    // guest memory before the replay runs, so a replayed load could observe
    // them and produce false mismatches.
    bool verify = Settings::values.cpu_asm_verify.GetValue() && !asm_verify_active;
    if (verify) {
        for (const auto& op : block.ops) {
            if (OpMayStoreGuestMemory(op)) {
                verify = false;
                ++ARMAsm::g_asm_stats.verify_skipped;
                break;
            }
        }
    }
    std::array<u32, 16> snap_regs;
    std::array<u32, 64> snap_ext;
    std::array<u32, VFP_SYSTEM_REGISTER_COUNT> snap_vfp{};
    u32 snap_cpsr = 0;
    u64 snap_budget = 0;
    if (verify) {
        SaveFlagsToCpsr();
        snap_regs = state->Reg;
        snap_ext = state->ExtReg;
        snap_vfp = state->VFP;
        snap_cpsr = state->Cpsr;
        snap_budget = state->NumInstrsToExecute;
    }
    ARMAsm::ExecContext ctx{
        .regs = state->Reg.data(),
        .flags4 = &state->NFlag,
        .lazy = &lazy_flags,
        .pagetable = current_page_table_raw->GetPointerArray().data(),
        .guest_size = block.thumb ? 2u : 4u,
        .pc = state->Reg[15],
        .ops_executed = 0,
        .exit_reason = 0,
        .exit_index = 0,
        .budget = static_cast<u32>(
            std::min<u64>(remaining_instructions, 0xFFFFFFFFULL)),
        .extreg = state->ExtReg.data(),
        .chain = (Settings::values.cpu_asm_mask.GetValue() & Core::ARMAsm::kAsmMaskChain)
                     ? asm_chain_table.data()
                     : nullptr,
        .cpsr_key = block.key.cpsr_key,
        .chain_hits = 0,
        .chain_misses = 0,
        .excl_tag = state->ExclusiveTagStorage(),
        .excl_state = state->ExclusiveStateStorage(),
        .resmask = block.asm_program->resmask,
        .miss_key = 0,
        .miss_budget = 0,
        .miss_res = 0,
        .miss_pckey = 0,
        .tflag = &state->TFlag,
    };
    citra_asm_run(&ctx, block.asm_program->ops.data());
#if defined(__OHOS__)
    IrTracePush(5, block.key.pc, block.key.cpsr_key,
                static_cast<u8>(block.thumb) | (ctx.chain_hits ? 0x8 : 0),
                (ctx.exit_reason << 28) | ctx.exit_index, ctx.pc, state->Cpsr,
                state->TFlag != 0);
#endif
    ++ARMAsm::g_asm_stats.runs;
    ARMAsm::g_asm_stats.ops_executed += ctx.ops_executed;
    ARMAsm::g_asm_stats.chain_hits += ctx.chain_hits;
    ARMAsm::g_asm_stats.chain_misses += ctx.chain_misses;
    ARMAsm::g_asm_stats.miss_key += ctx.miss_key;
    ARMAsm::g_asm_stats.miss_budget += ctx.miss_budget;
    ARMAsm::g_asm_stats.miss_res += ctx.miss_res;
    ARMAsm::g_asm_stats.miss_pckey += ctx.miss_pckey;
    result.instructions += ctx.ops_executed;
    state->Reg[15] = ctx.pc;
    if (verify && ctx.chain_hits != 0) {
        // A chained span crosses blocks whose ops are not visible here, so
        // their stores cannot be ruled out — not airtight.
        verify = false;
        ++ARMAsm::g_asm_stats.verify_skipped;
    }
    if (verify) {
        const auto asm_regs = state->Reg;
        const auto asm_ext = state->ExtReg;
        const auto asm_vfp = state->VFP;
        SaveFlagsToCpsr();
        const u32 asm_cpsr = state->Cpsr;
        state->Reg = snap_regs;
        state->ExtReg = snap_ext;
        state->VFP = snap_vfp;
        state->Cpsr = snap_cpsr;
        lazy_flags = {};
        LoadFlagsFromCpsr();
        state->NumInstrsToExecute = snap_budget;
        asm_verify_active = true;
        const IRExecutionResult replay = ExecuteIRInstructions(ctx.ops_executed);
        asm_verify_active = false;
        state->NumInstrsToExecute = snap_budget;
        ++ARMAsm::g_asm_stats.verify_runs;
        if (replay.instructions == ctx.ops_executed) {
            int bad = -1;
            u32 bad_idx = 0;
            for (int i = 0; i < 16; ++i) {
                if (state->Reg[i] != asm_regs[i]) {
                    bad = i;
                    break;
                }
            }
            if (bad < 0 && state->ExtReg != asm_ext) {
                bad = 100;
            }
            if (bad < 0 && state->Cpsr != asm_cpsr) {
                bad = 101;
            }
            if (bad < 0) {
                for (u32 i = 0; i < VFP_SYSTEM_REGISTER_COUNT; ++i) {
                    if (state->VFP[i] != asm_vfp[i]) {
                        bad = 200;
                        bad_idx = i;
                        break;
                    }
                }
            }
            if (bad >= 0) {
                const u32 asm_v = bad < 16  ? asm_regs[bad]
                                  : bad == 101 ? asm_cpsr
                                  : bad == 200 ? asm_vfp[bad_idx]
                                               : 0;
                const u32 cpp_v = bad < 16  ? state->Reg[bad]
                                  : bad == 101 ? state->Cpsr
                                  : bad == 200 ? state->VFP[bad_idx]
                                               : 0;
                const u64 mn = ARMAsm::g_asm_stats.verify_mismatches.fetch_add(1);
                if (mn == 0) {
                    ARMAsm::g_asm_stats.verify_first_pc.store(block.key.pc);
                    ARMAsm::g_asm_stats.verify_first_key.store(block.key.cpsr_key);
                    ARMAsm::g_asm_stats.verify_first_field.store(static_cast<u32>(bad));
                    ARMAsm::g_asm_stats.verify_first_asm.store(asm_v);
                    ARMAsm::g_asm_stats.verify_first_cpp.store(cpp_v);
                }
                char* buf = ARMAsm::g_asm_stats.verify_dumps[mn % 4];
                int off = std::snprintf(buf, 768,
                                        "blk=%08x k=%x th=%d f=%d a=%x c=%x ex=%d oe=%u|",
                                        block.key.pc, block.key.cpsr_key,
                                        static_cast<int>(block.thumb), bad, asm_v, cpp_v,
                                        ctx.exit_reason, ctx.ops_executed);
                for (const auto& op : block.ops) {
                    if (off > 700) {
                        break;
                    }
                    off += std::snprintf(buf + off, 768 - off, " %d:%x,%x,%x",
                                         static_cast<int>(op.opcode), op.arg0, op.arg1,
                                         op.arg2);
                }
#if defined(__OHOS__)
                OH_LOG_Print(LOG_APP, LOG_ERROR, 0x3203, "CitraAbort",
                             "ASM VERIFY MISMATCH blk=%{public}08x k=%{public}x th=%{public}d "
                             "f=%{public}d asm=%{public}08x cpp=%{public}08x oe=%{public}u "
                             "exit=%{public}u dump=%{public}s",
                             block.key.pc, block.key.cpsr_key,
                             static_cast<int>(block.thumb), bad, asm_v, cpp_v,
                             ctx.ops_executed, ctx.exit_reason, buf);
                if (FILE* f = std::fopen(
                        "/data/storage/el2/base/files/asm_abort.txt", "a")) {
                    std::fprintf(f, "VERIFY MISMATCH blk=%08x k=%x th=%d f=%d asm=%08x "
                                    "cpp=%08x oe=%u exit=%u %s\n",
                                 block.key.pc, block.key.cpsr_key,
                                 static_cast<int>(block.thumb), bad, asm_v, cpp_v,
                                 ctx.ops_executed, ctx.exit_reason, buf);
                    std::fclose(f);
                }
#endif
                LOG_CRITICAL(Core_ARM11,
                             "ASM VERIFY MISMATCH block={:#010x} cpsr_key={:#x} thumb={} "
                             "field={} asm={:#010x} cpp={:#010x} ops_executed={} exit={}",
                             block.key.pc, block.key.cpsr_key, block.thumb, bad, asm_v,
                             cpp_v, ctx.ops_executed, ctx.exit_reason);
            }
        } else {
            ++ARMAsm::g_asm_stats.verify_truncated;
            // Replay could not cover the span (fallback/stop); restore the
            // asm outcome so execution continues from a coherent state.
            state->Reg = asm_regs;
            state->ExtReg = asm_ext;
            state->VFP = asm_vfp;
            state->Cpsr = asm_cpsr;
            LoadFlagsFromCpsr();
        }
    }
    if (ctx.exit_reason == ASM_EXIT_END) {
        block.asm_bad_runs = 0;
        if (ctx.chain_hits != 0) {
            // The record-stream chain crossed block boundaries invisibly to
            // this frame: `block` is the run's *entry* block, not the
            // terminator the caller's link math expects. Reusing the entry
            // block's preserved cpsr_key would stamp its mode onto the tail
            // block's successor pc (e.g. an ARM key on a Thumb target), so
            // hand the caller a freshly computed key instead.
            result.link_source = &block;
            result.link_key = ARMIR::BlockCache::MakeKey(
                state->Reg[15], GetCpsrForBlockKey(), current_block_tag);
        }
        return kAsmCompletedBlock;
    }
    ++ARMAsm::g_asm_stats.slow_exits;
    if (ctx.exit_index < block.ops.size()) {
        const auto& op = block.ops[ctx.exit_index];
        const auto op_idx = static_cast<u16>(op.opcode);
        if (op_idx < ARMAsm::g_asm_stats.slow_op_counts.size()) {
            ++ARMAsm::g_asm_stats.slow_op_counts[op_idx];
        }
        if (op.opcode == ARMIR::Opcode::ArmDataProcessingRegisterAlways ||
            op.opcode == ARMIR::Opcode::ArmDataProcessingRegister) {
            const u32 bucket =
                (((op.arg1 >> 8) & 0xF) == 15 ? 1 : 0) |
                (((op.arg1 >> 16) & 0xF) == 15 ? 2 : 0) |
                (((op.arg1 >> 20) & 1) ? 4 : 0) | (((op.arg2 >> 16) & 1) ? 8 : 0);
            ++ARMAsm::g_asm_stats.slow_dp_reg[bucket & 0xF];
        }
        if (op.opcode == ARMIR::Opcode::ArmLoadStoreRegister) {
            const u32 reason =
                ((op.arg0 >> 2) & 1)      ? 0
                : ((op.arg1 >> 22) & 1)   ? 1
                : (op.arg1 & 0xF) == 15   ? 2
                : ((op.arg1 >> 8) & 0xF) == 15  ? 3
                : ((op.arg1 >> 16) & 0xF) == 15 ? 4
                                              : 5;
            ++ARMAsm::g_asm_stats.slow_lsx_reason[reason];
            if (reason == 2) {
                ARMAsm::g_asm_stats.slow_probe_inst.store(
                    (static_cast<u64>(op.arg0) << 32) | op.arg1);
                ARMAsm::g_asm_stats.slow_probe_arg0.store(
                    (static_cast<u64>(block.start_pc) << 32) | op.arg2);
                ARMAsm::g_asm_stats.slow_probe_meta.store(
                    (static_cast<u64>(op.opcode) << 40) |
                    (static_cast<u64>(op.guest_size) << 32) | ctx.exit_index);
            }
        }
        if (op.opcode == ARMIR::Opcode::ArmVFPLoadStore) {
            const u32 rn = op.arg1 & 0xF;
            const bool multiple = ((op.arg0 >> 11) & 1) != 0;
            const bool single = ((op.arg0 >> 9) & 1) != 0;
            const u32 ext_reg = (op.arg1 >> 8) & 0x3F;
            const u32 reason =
                rn == 15 ? 0
                : (multiple &&
                   (op.arg2 == 0 || (op.arg2 & 3) != 0 ||
                    ext_reg + op.arg2 / 4 > 64))
                      ? 1
                : (!multiple && !single && ext_reg + 2 > 64) ? 2
                                                             : 3;
            ++ARMAsm::g_asm_stats.slow_vls_reason[reason];
        }
        {
            // Memory-op slow exits: record the live base register so offline
            // analysis can tell which guest address region is failing the
            // fast path (stack/heap/MMIO/page span). rn sits in arg1&0xF for
            // multiple/VFP ops and in (arg1>>8)&0xF for scalar load/store.
            u32 mem_rn = 0xFF;
            switch (op.opcode) {
            case ARMIR::Opcode::ArmLoadStoreImmediate:
            case ARMIR::Opcode::ArmLoadStoreRegister:
            case ARMIR::Opcode::ArmLoadStoreHalfword:
            case ARMIR::Opcode::ArmLoadStoreDouble:
            case ARMIR::Opcode::ArmLoadWordImmediateNoPc:
            case ARMIR::Opcode::ArmStoreWordImmediateNoPc:
            case ARMIR::Opcode::ArmLoadByteImmediateNoPc:
            case ARMIR::Opcode::ArmStoreByteImmediateNoPc:
            case ARMIR::Opcode::ArmLoadHalfwordImmediateNoPc:
            case ARMIR::Opcode::ArmStoreHalfwordImmediateNoPc:
            case ARMIR::Opcode::ArmLoadWordImmediateNoPcAdd:
            case ARMIR::Opcode::ArmLoadWordImmediateNoPcSub:
            case ARMIR::Opcode::ArmStoreWordImmediateNoPcAdd:
            case ARMIR::Opcode::ArmStoreWordImmediateNoPcSub:
            case ARMIR::Opcode::ArmLoadByteImmediateNoPcAdd:
            case ARMIR::Opcode::ArmLoadByteImmediateNoPcSub:
            case ARMIR::Opcode::ArmStoreByteImmediateNoPcAdd:
            case ARMIR::Opcode::ArmStoreByteImmediateNoPcSub:
            case ARMIR::Opcode::ArmLoadHalfwordImmediateNoPcAdd:
            case ARMIR::Opcode::ArmLoadHalfwordImmediateNoPcSub:
            case ARMIR::Opcode::ArmStoreHalfwordImmediateNoPcAdd:
            case ARMIR::Opcode::ArmStoreHalfwordImmediateNoPcSub:
            case ARMIR::Opcode::ArmLoadWordImmediateNoPcOffset0:
            case ARMIR::Opcode::ArmStoreWordImmediateNoPcOffset0:
            case ARMIR::Opcode::ArmLoadByteImmediateNoPcOffset0:
            case ARMIR::Opcode::ArmStoreByteImmediateNoPcOffset0:
            case ARMIR::Opcode::ArmLoadHalfwordImmediateNoPcOffset0:
            case ARMIR::Opcode::ArmStoreHalfwordImmediateNoPcOffset0:
                mem_rn = (op.arg1 >> 8) & 0xF;
                break;
            case ARMIR::Opcode::ArmLoadStoreMultiple:
            case ARMIR::Opcode::ArmLoadMultipleFast:
            case ARMIR::Opcode::ArmStoreMultipleFast:
            case ARMIR::Opcode::ArmLoadMultipleWithPcFast:
            case ARMIR::Opcode::ArmVFPLoadStore:
            case ARMIR::Opcode::ArmVFPLoadSingleFast:
            case ARMIR::Opcode::ArmVFPStoreSingleFast:
            case ARMIR::Opcode::ArmVFPLoadDoubleFast:
            case ARMIR::Opcode::ArmVFPStoreDoubleFast:
            case ARMIR::Opcode::ArmVFPLoadMultipleFast:
            case ARMIR::Opcode::ArmVFPStoreMultipleFast:
                mem_rn = op.arg1 & 0xF;
                break;
            default:
                break;
            }
            if (mem_rn != 0xFF) {
                ARMAsm::g_asm_stats.slow_mem_rn.store(
                    (static_cast<u64>(block.start_pc) << 32) | state->Reg[mem_rn]);
                ARMAsm::g_asm_stats.slow_mem_a1.store(
                    (static_cast<u64>(op_idx) << 48) | op.arg1);
            }
        }
        if (op.opcode == ARMIR::Opcode::ArmMultiply) {
            ARMAsm::g_asm_stats.slow_probe_inst.store(
                (static_cast<u64>(op.arg0) << 32) | op.arg1);
            ARMAsm::g_asm_stats.slow_probe_arg0.store(
                (static_cast<u64>(block.start_pc) << 32) | op.arg2);
            ARMAsm::g_asm_stats.slow_probe_meta.store(
                (static_cast<u64>(op.opcode) << 40) |
                (static_cast<u64>(op.guest_size) << 32) | ctx.exit_index);
        }
        if (op.opcode == ARMIR::Opcode::ArmVFPDataProcessingAlways ||
            op.opcode == ARMIR::Opcode::ArmVFPDataProcessing) {
            ARMAsm::g_asm_stats.slow_vfpdp_inst.store(
                (static_cast<u64>(op.arg0) << 32) | op.arg1);
            ARMAsm::g_asm_stats.slow_vfpdp_arg0.store(
                (static_cast<u64>(block.start_pc) << 32) | op.arg2);
            ARMAsm::g_asm_stats.slow_vfpdp_meta.store(
                (static_cast<u64>(op.opcode) << 40) |
                (static_cast<u64>(op.guest_size) << 32) | ctx.exit_index);
        }
    }
    // A SLOW exit always names an op in this (entry) block — chained slow
    // exits were rewritten to END — so ops_executed is this block's own
    // fast-op yield for the run.
    if (ctx.ops_executed < kAsmMinUsefulOps) {
        block.asm_bad_runs = std::min<u8>(block.asm_bad_runs + 1, 0xFF);
    } else {
        block.asm_bad_runs = 0;
    }
    return ctx.exit_index;
}
#endif

template <bool ProfileOpcodes, bool CheckRemaining, bool BigEndian>
ARM_IRInterpreter::IRBlockResult ARM_IRInterpreter::TryExecuteBlock(
    const ARMIR::Block& first_block, u64 remaining_instructions,
    std::array<u64, ARMIR::OpcodeCount>* opcode_counts) {
    IRBlockResult result;
    const ARMIR::Block* current_block = &first_block;
chain_restart:
    // Block chaining: when a block ends normally and its successor is already
    // linked, jump straight into it (goto chain_restart below) instead of
    // returning to ExecuteIRInstructions for a full call + bookkeeping round
    // trip per block.
    const ARMIR::Block& block = *current_block;
    result.blocks++;
#if defined(__OHOS__)
    IrTracePush(current_block == &first_block ? 0 : 1, block.key.pc, block.key.cpsr_key,
                static_cast<u8>(block.thumb), static_cast<u32>(block.terminal),
                state->Reg[15], state->Cpsr, state->TFlag != 0);
#endif
    if (block.ops.empty()) {
        result.needs_fallback = true;
        result.fallback_pc = block.fallback_pc;
        result.fallback_instruction = block.fallback_instruction;
        result.fallback_reason = static_cast<u32>(block.fallback_reason);
        result.fallback_thumb = block.thumb;
        return result;
    }
    if (block.thumb != (state->TFlag != 0)) {
        result.needs_fallback = true;
        result.fallback_pc = state->Reg[15];
        result.fallback_instruction = block.fallback_instruction;
        result.fallback_reason = static_cast<u32>(ARMIR::FallbackReason::BackendIncomplete);
        result.fallback_thumb = state->TFlag != 0;
#if defined(__OHOS__)
        if (FILE* f = IrAbortOpen()) {
            std::fprintf(f,
                         "thumb-mismatch: pc=%08X tflag=%d block_pc=%08X blk_thumb=%d "
                         "blk_key_cpsr=%x cpsr=%08X chained=%d terminal=%d\n",
                         state->Reg[15], static_cast<int>(state->TFlag != 0),
                         block.key.pc, static_cast<int>(block.thumb),
                         block.key.cpsr_key, state->Cpsr,
                         current_block != &first_block,
                         static_cast<int>(block.terminal));
            IrTraceDump(f);
            std::fclose(f);
        }
#endif
        return result;
    }
    if constexpr (!CheckRemaining) {
        (void)remaining_instructions;
    }
    if constexpr (!ProfileOpcodes) {
        (void)opcode_counts;
    }

    const std::size_t op_count = block.ops.size();
    std::size_t op_index = 0;
#if defined(__aarch64__)
    if constexpr (!ProfileOpcodes && !BigEndian) {
        const std::size_t asm_next = ExecuteAsmPrefix<CheckRemaining>(
            block, remaining_instructions - result.instructions, result);
        if (asm_next == kAsmCompletedBlock) {
            if (current_block != &first_block && !result.link_source) {
                // The internal chain moved current_block past the entry
                // block and the tail was consumed by an asm run: report the
                // real tail plus a fresh successor key so the caller's link
                // math cannot reuse the entry block's preserved cpsr key
                // (which would stamp the entry block's mode onto a successor
                // pc that may have switched instruction set meanwhile).
                result.link_source = current_block;
                result.link_key = ARMIR::BlockCache::MakeKey(
                    state->Reg[15], GetCpsrForBlockKey(), current_block_tag);
            }
            return result;
        }
        op_index = asm_next;
    }
#endif
    for (; op_index < op_count; ++op_index) {
        const ARMIR::Op& op = block.ops[op_index];
        if constexpr (CheckRemaining) {
            if (result.instructions >= remaining_instructions) {
                goto block_done;
            }
        }

        // Records the op's ticks on every exit path, including the early
        // `return result` cases that would otherwise be invisible in [ops-t].
        struct OpTickScope {
            u64 t0{};
            std::size_t idx{};
            bool active{false};
            FORCE_INLINE ~OpTickScope() {
#if defined(__aarch64__)
                if (active) {
                    u64 t1;
                    asm volatile("mrs %0, cntvct_el0" : "=r"(t1));
                    g_ir_opcode_ticks[idx] += t1 - t0;
                }
#else
                (void)t0;
                (void)idx;
                (void)active;
#endif
            }
        } op_scope;
        if constexpr (ProfileOpcodes) {
            const auto opcode_index = static_cast<std::size_t>(op.opcode);
            (*opcode_counts)[opcode_index]++;
#if defined(__aarch64__)
            u64 prof_t0;
            asm volatile("mrs %0, cntvct_el0" : "=r"(prof_t0));
            op_scope = {prof_t0, opcode_index, true};
#else
            op_scope.active = false;
#endif
        }

        switch (op.opcode) {
        case ARMIR::Opcode::Unimplemented: {
            const bool undefined_instruction =
                block.fallback_reason == ARMIR::FallbackReason::UnsupportedInstruction ||
                block.fallback_reason == ARMIR::FallbackReason::DecodeFailure;
            if (undefined_instruction) {
                result.stop_execution = true;
                goto block_done;
            }
            result.needs_fallback = true;
            result.fallback_pc = block.fallback_pc;
            result.fallback_instruction = block.fallback_instruction;
            result.fallback_reason = static_cast<u32>(block.fallback_reason);
            result.fallback_thumb = block.thumb;
            goto block_done;
        }
        case ARMIR::Opcode::ArmConditionalSkip: {
            if (ConditionPassed(op.arg0 & 0xF)) {
                break;
            }

            const u32 skip_instructions = op.arg1;
            if constexpr (CheckRemaining) {
                const u64 remaining = remaining_instructions - result.instructions;
                if (remaining < skip_instructions) {
                    u32 skipped_bytes = 0;
                    for (u64 i = 0; i < remaining; ++i) {
                        skipped_bytes += block.ops[op_index + 1 + i].guest_size;
                    }
                    state->Reg[15] += skipped_bytes;
                    result.instructions += static_cast<u32>(remaining);
                    if constexpr (ProfileOpcodes) {
                        result.conditional_skipped_instructions += static_cast<u32>(remaining);
                    }
                    goto block_done;
                }
            }

            state->Reg[15] += op.arg2;
            result.instructions += skip_instructions;
            if constexpr (ProfileOpcodes) {
                result.conditional_skipped_instructions += skip_instructions;
            }
            op_index += skip_instructions;
            break;
        }
        case ARMIR::Opcode::ArmConditionalSkipEq:
            if (ExecuteConditionalSkipT<ProfileOpcodes, CheckRemaining, ConditionCode::EQ>(
                    block, op_index, op, remaining_instructions, result)) {
                goto block_done;
            }
            break;
        case ARMIR::Opcode::ArmConditionalSkipNe:
            if (ExecuteConditionalSkipT<ProfileOpcodes, CheckRemaining, ConditionCode::NE>(
                    block, op_index, op, remaining_instructions, result)) {
                goto block_done;
            }
            break;
        case ARMIR::Opcode::ArmConditionalSkipCs:
            if (ExecuteConditionalSkipT<ProfileOpcodes, CheckRemaining, ConditionCode::CS>(
                    block, op_index, op, remaining_instructions, result)) {
                goto block_done;
            }
            break;
        case ARMIR::Opcode::ArmConditionalSkipCc:
            if (ExecuteConditionalSkipT<ProfileOpcodes, CheckRemaining, ConditionCode::CC>(
                    block, op_index, op, remaining_instructions, result)) {
                goto block_done;
            }
            break;
        case ARMIR::Opcode::ArmConditionalSkipMi:
            if (ExecuteConditionalSkipT<ProfileOpcodes, CheckRemaining, ConditionCode::MI>(
                    block, op_index, op, remaining_instructions, result)) {
                goto block_done;
            }
            break;
        case ARMIR::Opcode::ArmConditionalSkipPl:
            if (ExecuteConditionalSkipT<ProfileOpcodes, CheckRemaining, ConditionCode::PL>(
                    block, op_index, op, remaining_instructions, result)) {
                goto block_done;
            }
            break;
        case ARMIR::Opcode::ArmConditionalSkipVs:
            if (ExecuteConditionalSkipT<ProfileOpcodes, CheckRemaining, ConditionCode::VS>(
                    block, op_index, op, remaining_instructions, result)) {
                goto block_done;
            }
            break;
        case ARMIR::Opcode::ArmConditionalSkipVc:
            if (ExecuteConditionalSkipT<ProfileOpcodes, CheckRemaining, ConditionCode::VC>(
                    block, op_index, op, remaining_instructions, result)) {
                goto block_done;
            }
            break;
        case ARMIR::Opcode::ArmConditionalSkipHi:
            if (ExecuteConditionalSkipT<ProfileOpcodes, CheckRemaining, ConditionCode::HI>(
                    block, op_index, op, remaining_instructions, result)) {
                goto block_done;
            }
            break;
        case ARMIR::Opcode::ArmConditionalSkipLs:
            if (ExecuteConditionalSkipT<ProfileOpcodes, CheckRemaining, ConditionCode::LS>(
                    block, op_index, op, remaining_instructions, result)) {
                goto block_done;
            }
            break;
        case ARMIR::Opcode::ArmConditionalSkipGe:
            if (ExecuteConditionalSkipT<ProfileOpcodes, CheckRemaining, ConditionCode::GE>(
                    block, op_index, op, remaining_instructions, result)) {
                goto block_done;
            }
            break;
        case ARMIR::Opcode::ArmConditionalSkipLt:
            if (ExecuteConditionalSkipT<ProfileOpcodes, CheckRemaining, ConditionCode::LT>(
                    block, op_index, op, remaining_instructions, result)) {
                goto block_done;
            }
            break;
        case ARMIR::Opcode::ArmConditionalSkipGt:
            if (ExecuteConditionalSkipT<ProfileOpcodes, CheckRemaining, ConditionCode::GT>(
                    block, op_index, op, remaining_instructions, result)) {
                goto block_done;
            }
            break;
        case ARMIR::Opcode::ArmConditionalSkipLe:
            if (ExecuteConditionalSkipT<ProfileOpcodes, CheckRemaining, ConditionCode::LE>(
                    block, op_index, op, remaining_instructions, result)) {
                goto block_done;
            }
            break;
        case ARMIR::Opcode::ArmBranch:
            if (ConditionFailed(op.arg1)) {
                AdvancePC(*state, op);
            } else {
                if ((op.arg2 & 1) != 0) {
                    state->Reg[14] = op.arg2 & ~1U;
                }
                state->Reg[15] = op.arg0;
            }
            result.instructions++;
            goto block_done;
        case ARMIR::Opcode::ArmBranchAlways:
            state->Reg[15] = op.arg0;
            result.instructions++;
            goto block_done;
        case ARMIR::Opcode::ArmBranchExchange:
            if (ConditionPassedOrAlways(op.arg0)) {
                const u32 address = state->Reg[op.arg1 & 0xF];
                IR_TRACE_TFLAG(address & 1, 2);
                state->Reg[15] = address & 0xFFFFFFFE;
            } else {
                AdvancePC(*state, op);
            }
            result.instructions++;
            goto block_done;
        case ARMIR::Opcode::ArmBranchLinkExchange: {
            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                goto block_done;
            }

            const bool immediate_target = ((op.arg0 >> 8) & 1) != 0;
            if (immediate_target) {
                state->Reg[14] = op.arg2;
                state->Reg[15] = op.arg1;
                IR_TRACE_TFLAG(1, 3);
            } else {
                const u32 jump_address = state->Reg[op.arg1 & 0xF];
                state->Reg[14] = state->Reg[15] + op.guest_size;
                if (state->TFlag) {
                    state->Reg[14] |= 1;
                }
                state->Reg[15] = jump_address & 0xFFFFFFFE;
                IR_TRACE_TFLAG(jump_address & 1, 4);
            }
            result.instructions++;
            goto block_done;
        }
        case ARMIR::Opcode::ArmBranchExchangeAlways: {
            const u32 address = state->Reg[op.arg1 & 0xF];
            IR_TRACE_TFLAG(address & 1, 5);
            state->Reg[15] = address & 0xFFFFFFFE;
            result.instructions++;
            goto block_done;
        }
        case ARMIR::Opcode::ArmBranchLinkExchangeRegisterAlways: {
            const u32 jump_address = state->Reg[op.arg1 & 0xF];
            state->Reg[14] = state->Reg[15] + op.guest_size;
            if (state->TFlag) {
                state->Reg[14] |= 1;
            }
            state->Reg[15] = jump_address & 0xFFFFFFFE;
            IR_TRACE_TFLAG(jump_address & 1, 6);
            result.instructions++;
            goto block_done;
        }
        case ARMIR::Opcode::ArmHint:
            AdvancePC(*state, op);
            result.instructions++;
            break;
        case ARMIR::Opcode::ArmClearExclusive:
            state->UnsetExclusiveMemoryAddress();
            AdvancePC(*state, op);
            result.instructions++;
            break;
        case ARMIR::Opcode::ArmChangeProcessorState: {

            if (state->InAPrivilegedMode()) {
                SaveFlagsToCpsr();
                const bool enable = ((op.arg0 >> 18) & 1) != 0;
                const bool change_interrupt_bits = ((op.arg0 >> 19) & 1) != 0;
                const bool change_mode = ((op.arg0 >> 17) & 1) != 0;

                if (change_interrupt_bits) {
                    u32 mask = 0;
                    if (((op.arg0 >> 8) & 1) != 0) {
                        mask |= 1U << 8;
                    }
                    if (((op.arg0 >> 7) & 1) != 0) {
                        mask |= 1U << 7;
                    }
                    if (((op.arg0 >> 6) & 1) != 0) {
                        mask |= 1U << 6;
                    }
                    state->Cpsr = (state->Cpsr & ~mask) | (enable ? mask : 0);
                }
                if (change_mode) {
                    const u32 mode = op.arg0 & 0x1F;
                    state->Cpsr = (state->Cpsr & 0xFFFFFFE0) | mode;
                    state->ChangePrivilegeMode(mode);
                }
                LoadFlagsFromCpsr();
            }

            AdvancePC(*state, op);
            result.instructions++;
            goto block_done;
        }
        case ARMIR::Opcode::ArmSetEndian:
            SaveFlagsToCpsr();
            if ((op.arg0 & 1) != 0) {
                state->Cpsr |= EBIT;
            } else {
                state->Cpsr &= ~EBIT;
            }
            LoadFlagsFromCpsr();
            AdvancePC(*state, op);
            result.instructions++;
            goto block_done;
        case ARMIR::Opcode::ThumbBranchLinkSetup:
            state->Reg[14] = state->Reg[15] + 4 + op.arg0;
            AdvancePC(*state, op);
            result.instructions++;
            break;
        case ARMIR::Opcode::ThumbBranchLink: {
            const u32 target = state->Reg[14] + op.arg0;
            state->Reg[14] = (state->Reg[15] + 2) | 1;
            // Dyncom normalizes the next Thumb dispatch address. This matters for a
            // standalone BL suffix with an odd LR as well as for malformed guest code.
            state->Reg[15] = target & ~1U;
            result.instructions++;
            goto block_done;
        }
        case ARMIR::Opcode::ThumbBranchLinkExchange: {
            const u32 next_lr = (state->Reg[15] + 2) | 1;
            state->Reg[15] = (state->Reg[14] + op.arg0) & 0xFFFFFFFC;
            state->Reg[14] = next_lr;
            IR_TRACE_TFLAG(0, 7);
            result.instructions++;
            goto block_done;
        }
        case ARMIR::Opcode::ArmMoveImmediateAlways: {
            const u32 rd = op.arg1 & 0xF;
            state->Reg[rd] = op.arg2;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmMoveImmediateSetFlagsAlways: {
            const u32 rd = op.arg1 & 0xF;
            const bool shifter_carry = (op.arg0 & 1) != 0;
            const bool shifter_carry_from_c_flag = ((op.arg0 >> 1) & 1) != 0;
            const bool carry = shifter_carry_from_c_flag ? ReadCFlag() : shifter_carry;
            state->Reg[rd] = op.arg2;
            SetLazyLogicalFlags(op.arg2, carry);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmAddImmediateAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            state->Reg[rd] = rn_value + op.arg2;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSubImmediateAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            state->Reg[rd] = rn_value - op.arg2;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareImmediateAlways: {
            const u32 rn = op.arg1 & 0xF;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            const AddWithCarryResult add = EvaluateCompareFlags(rn_value, op.arg2, false);
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmMoveRegisterAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            state->Reg[rd] = state->Reg[rm];

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmMoveNotRegisterAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            state->Reg[rd] = ~state->Reg[rm];

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmMoveRegisterSetFlagsAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 value = state->Reg[rm];
            state->Reg[rd] = value;
            SetLazyNZFlags(value);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmMoveNotRegisterSetFlagsAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 value = ~state->Reg[rm];
            state->Reg[rd] = value;
            SetLazyNZFlags(value);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmTstRegisterNoShiftNoPcAlways: {
            const u32 rn = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            SetLazyNZFlags(state->Reg[rn] & state->Reg[rm]);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmTeqRegisterNoShiftNoPcAlways: {
            const u32 rn = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            SetLazyNZFlags(state->Reg[rn] ^ state->Reg[rm]);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmTstImmediateNoPcAlways: {
            const u32 rn = op.arg1 & 0xF;
            const u32 value = state->Reg[rn] & op.arg2;
            if (((op.arg0 >> 1) & 1) != 0) {
                SetLazyNZFlags(value);
            } else {
                SetLazyLogicalFlags(value, (op.arg0 & 1) != 0);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmTeqImmediateNoPcAlways: {
            const u32 rn = op.arg1 & 0xF;
            const u32 value = state->Reg[rn] ^ op.arg2;
            if (((op.arg0 >> 1) & 1) != 0) {
                SetLazyNZFlags(value);
            } else {
                SetLazyLogicalFlags(value, (op.arg0 & 1) != 0);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmAddRegisterAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            state->Reg[rd] = rn_value + state->Reg[rm];

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSubRegisterAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            state->Reg[rd] = rn_value - state->Reg[rm];

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareRegisterAlways: {
            const u32 rn = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            const AddWithCarryResult add = EvaluateCompareFlags(rn_value, state->Reg[rm], false);
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmAddImmediateSetFlagsAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            const AddWithCarryResult add = EvaluateAddSubFlags(rn_value, op.arg2, false);
            state->Reg[rd] = add.value;
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSubImmediateSetFlagsAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            const AddWithCarryResult add = EvaluateAddSubFlags(rn_value, op.arg2, true);
            state->Reg[rd] = add.value;
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareNegativeImmediateAlways: {
            const u32 rn = op.arg1 & 0xF;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            const AddWithCarryResult add = EvaluateCompareFlags(rn_value, op.arg2, true);
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmAddRegisterSetFlagsAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            const AddWithCarryResult add = EvaluateAddSubFlags(rn_value, state->Reg[rm], false);
            state->Reg[rd] = add.value;
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSubRegisterSetFlagsAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            const AddWithCarryResult add = EvaluateAddSubFlags(rn_value, state->Reg[rm], true);
            state->Reg[rd] = add.value;
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareNegativeRegisterAlways: {
            const u32 rn = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            const AddWithCarryResult add = EvaluateCompareFlags(rn_value, state->Reg[rm], true);
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmAddImmediateNoPcAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            state->Reg[rd] = state->Reg[rn] + op.arg2;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSubImmediateNoPcAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            state->Reg[rd] = state->Reg[rn] - op.arg2;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareImmediateNoPcAlways: {
            const u32 rn = op.arg1 & 0xF;
            const AddWithCarryResult add = EvaluateCompareFlags(state->Reg[rn], op.arg2, false);
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareZeroImmediateNoPcAlways: {
            const u32 rn = op.arg1 & 0xF;
            SetLazyArithmeticFlags(state->Reg[rn], true, false);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmAddRegisterNoPcAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            state->Reg[rd] = state->Reg[rn] + state->Reg[rm];

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSubRegisterNoPcAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            state->Reg[rd] = state->Reg[rn] - state->Reg[rm];

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareRegisterNoPcAlways: {
            const u32 rn = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            if (rn == rm) {
                SetLazyArithmeticFlags(0, true, false);

                AdvancePC(*state, op);
                result.instructions++;
                break;
            }
            const AddWithCarryResult add =
                EvaluateCompareFlags(state->Reg[rn], state->Reg[rm], false);
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareImmediateBranchNoPcAlways: {
            const u32 rn = op.arg0 & 0xF;
            const bool compare_negative = ((op.arg0 >> 4) & 1) != 0;
            const u32 branch_condition = (op.arg0 >> 8) & 0xF;
            const u32 compare_guest_size = (op.arg0 >> 16) & 0xFF;
            if (op.arg1 == 0) {
                const u32 value = state->Reg[rn];
                const bool carry = !compare_negative;
                SetLazyArithmeticFlags(value, carry, false);

                if constexpr (CheckRemaining) {
                    if (remaining_instructions - result.instructions < 2) {
                        state->Reg[15] += compare_guest_size;
                        result.instructions++;
                        goto block_done;
                    }
                }

                const bool take_branch = ConditionPassedFromFlags(
                    branch_condition, (value >> 31) != 0, value == 0, carry, false);
                CountFusedBranch<ProfileOpcodes>(result, take_branch);
                state->Reg[15] = take_branch ? op.arg2 : state->Reg[15] + op.guest_size;
                result.instructions += 2;
                goto block_done;
            }
            const AddWithCarryResult add =
                EvaluateCompareFlags(state->Reg[rn], op.arg1, compare_negative);
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            if constexpr (CheckRemaining) {
                if (remaining_instructions - result.instructions < 2) {
                    state->Reg[15] += compare_guest_size;
                    result.instructions++;
                    goto block_done;
                }
            }

            const bool take_branch = ConditionPassedFromFlags(
                branch_condition, (add.value >> 31) != 0, add.value == 0, add.carry,
                add.overflow);
            CountFusedBranch<ProfileOpcodes>(result, take_branch);
            state->Reg[15] = take_branch ? op.arg2 : state->Reg[15] + op.guest_size;
            result.instructions += 2;
            goto block_done;
        }
        case ARMIR::Opcode::ArmCompareRegisterBranchNoPcAlways: {
            const u32 rn = op.arg0 & 0xF;
            const u32 rm = (op.arg0 >> 4) & 0xF;
            const bool compare_negative = ((op.arg0 >> 8) & 1) != 0;
            const u32 branch_condition = (op.arg0 >> 12) & 0xF;
            const u32 compare_guest_size = (op.arg0 >> 16) & 0xFF;
            if (!compare_negative && rn == rm) {
                SetLazyArithmeticFlags(0, true, false);

                if constexpr (CheckRemaining) {
                    if (remaining_instructions - result.instructions < 2) {
                        state->Reg[15] += compare_guest_size;
                        result.instructions++;
                        goto block_done;
                    }
                }

                const bool take_branch =
                    ConditionPassedFromFlags(branch_condition, false, true, true, false);
                CountFusedBranch<ProfileOpcodes>(result, take_branch);
                state->Reg[15] = take_branch ? op.arg1 : state->Reg[15] + op.guest_size;
                result.instructions += 2;
                goto block_done;
            }
            const AddWithCarryResult add =
                EvaluateCompareFlags(state->Reg[rn], state->Reg[rm], compare_negative);
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            if constexpr (CheckRemaining) {
                if (remaining_instructions - result.instructions < 2) {
                    state->Reg[15] += compare_guest_size;
                    result.instructions++;
                    goto block_done;
                }
            }

            const bool take_branch = ConditionPassedFromFlags(
                branch_condition, (add.value >> 31) != 0, add.value == 0, add.carry,
                add.overflow);
            CountFusedBranch<ProfileOpcodes>(result, take_branch);
            state->Reg[15] = take_branch ? op.arg1 : state->Reg[15] + op.guest_size;
            result.instructions += 2;
            goto block_done;
        }
        case ARMIR::Opcode::ArmCompareShiftedRegisterBranchNoPcAlways: {
            const bool compare_negative = ((op.arg0 >> 8) & 1) != 0;
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                if (compare_negative) {
                    ExecuteCompareShiftedRegisterBranchNoPc<0, true, CheckRemaining,
                                                            ProfileOpcodes>(
                        op, remaining_instructions, result);
                } else {
                    ExecuteCompareShiftedRegisterBranchNoPc<0, false, CheckRemaining,
                                                            ProfileOpcodes>(
                        op, remaining_instructions, result);
                }
                break;
            case 1:
                if (compare_negative) {
                    ExecuteCompareShiftedRegisterBranchNoPc<1, true, CheckRemaining,
                                                            ProfileOpcodes>(
                        op, remaining_instructions, result);
                } else {
                    ExecuteCompareShiftedRegisterBranchNoPc<1, false, CheckRemaining,
                                                            ProfileOpcodes>(
                        op, remaining_instructions, result);
                }
                break;
            case 2:
                if (compare_negative) {
                    ExecuteCompareShiftedRegisterBranchNoPc<2, true, CheckRemaining,
                                                            ProfileOpcodes>(
                        op, remaining_instructions, result);
                } else {
                    ExecuteCompareShiftedRegisterBranchNoPc<2, false, CheckRemaining,
                                                            ProfileOpcodes>(
                        op, remaining_instructions, result);
                }
                break;
            case 3:
                if (compare_negative) {
                    ExecuteCompareShiftedRegisterBranchNoPc<3, true, CheckRemaining,
                                                            ProfileOpcodes>(
                        op, remaining_instructions, result);
                } else {
                    ExecuteCompareShiftedRegisterBranchNoPc<3, false, CheckRemaining,
                                                            ProfileOpcodes>(
                        op, remaining_instructions, result);
                }
                break;
            }
            goto block_done;
        }
        case ARMIR::Opcode::ArmCompareRegisterShiftedRegisterBranchNoPcAlways: {
            const bool compare_negative = ((op.arg0 >> 12) & 1) != 0;
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                if (compare_negative) {
                    ExecuteCompareRegisterShiftedRegisterBranchNoPc<0, true, CheckRemaining,
                                                                    ProfileOpcodes>(
                        op, remaining_instructions, result);
                } else {
                    ExecuteCompareRegisterShiftedRegisterBranchNoPc<0, false, CheckRemaining,
                                                                     ProfileOpcodes>(
                        op, remaining_instructions, result);
                }
                break;
            case 1:
                if (compare_negative) {
                    ExecuteCompareRegisterShiftedRegisterBranchNoPc<1, true, CheckRemaining,
                                                                    ProfileOpcodes>(
                        op, remaining_instructions, result);
                } else {
                    ExecuteCompareRegisterShiftedRegisterBranchNoPc<1, false, CheckRemaining,
                                                                     ProfileOpcodes>(
                        op, remaining_instructions, result);
                }
                break;
            case 2:
                if (compare_negative) {
                    ExecuteCompareRegisterShiftedRegisterBranchNoPc<2, true, CheckRemaining,
                                                                    ProfileOpcodes>(
                        op, remaining_instructions, result);
                } else {
                    ExecuteCompareRegisterShiftedRegisterBranchNoPc<2, false, CheckRemaining,
                                                                     ProfileOpcodes>(
                        op, remaining_instructions, result);
                }
                break;
            case 3:
                if (compare_negative) {
                    ExecuteCompareRegisterShiftedRegisterBranchNoPc<3, true, CheckRemaining,
                                                                    ProfileOpcodes>(
                        op, remaining_instructions, result);
                } else {
                    ExecuteCompareRegisterShiftedRegisterBranchNoPc<3, false, CheckRemaining,
                                                                     ProfileOpcodes>(
                        op, remaining_instructions, result);
                }
                break;
            }
            goto block_done;
        }
        case ARMIR::Opcode::ArmTestImmediateBranchNoPcAlways: {
            const u32 rn = op.arg0 & 0xF;
            const bool test_equal = ((op.arg0 >> 4) & 1) != 0;
            const bool shifter_carry = ((op.arg0 >> 5) & 1) != 0;
            const bool shifter_carry_from_c_flag = ((op.arg0 >> 6) & 1) != 0;
            const u32 branch_condition = (op.arg0 >> 8) & 0xF;
            const u32 compare_guest_size = (op.arg0 >> 16) & 0xFF;
            const bool carry = shifter_carry_from_c_flag ? ReadCFlag() : shifter_carry;
            const bool overflow = ConditionUsesVFlag(branch_condition) ? ReadVFlag() : false;
            const u32 logical_result =
                test_equal ? (state->Reg[rn] ^ op.arg1) : (state->Reg[rn] & op.arg1);
            SetLazyLogicalFlags(logical_result, carry);

            if constexpr (CheckRemaining) {
                if (remaining_instructions - result.instructions < 2) {
                    state->Reg[15] += compare_guest_size;
                    result.instructions++;
                    goto block_done;
                }
            }

            const bool take_branch =
                ConditionPassedFromFlags(branch_condition, (logical_result >> 31) != 0,
                                         logical_result == 0, carry, overflow);
            CountFusedBranch<ProfileOpcodes>(result, take_branch);
            state->Reg[15] = take_branch ? op.arg2 : state->Reg[15] + op.guest_size;
            result.instructions += 2;
            goto block_done;
        }
        case ARMIR::Opcode::ArmTestRegisterBranchNoPcAlways: {
            const u32 rn = op.arg0 & 0xF;
            const u32 rm = (op.arg0 >> 4) & 0xF;
            const bool test_equal = ((op.arg0 >> 8) & 1) != 0;
            const u32 branch_condition = (op.arg0 >> 12) & 0xF;
            const u32 compare_guest_size = (op.arg0 >> 16) & 0xFF;
            const bool carry = ReadCFlag();
            const bool overflow = ConditionUsesVFlag(branch_condition) ? ReadVFlag() : false;
            const u32 logical_result =
                test_equal ? (state->Reg[rn] ^ state->Reg[rm]) : (state->Reg[rn] & state->Reg[rm]);
            SetLazyLogicalFlags(logical_result, carry);

            if constexpr (CheckRemaining) {
                if (remaining_instructions - result.instructions < 2) {
                    state->Reg[15] += compare_guest_size;
                    result.instructions++;
                    goto block_done;
                }
            }

            const bool take_branch =
                ConditionPassedFromFlags(branch_condition, (logical_result >> 31) != 0,
                                         logical_result == 0, carry, overflow);
            CountFusedBranch<ProfileOpcodes>(result, take_branch);
            state->Reg[15] = take_branch ? op.arg1 : state->Reg[15] + op.guest_size;
            result.instructions += 2;
            goto block_done;
        }
        case ARMIR::Opcode::ArmTestShiftedRegisterBranchNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                ExecuteTestShiftedRegisterBranchNoPc<0, CheckRemaining, ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            case 1:
                ExecuteTestShiftedRegisterBranchNoPc<1, CheckRemaining, ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            case 2:
                ExecuteTestShiftedRegisterBranchNoPc<2, CheckRemaining, ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            case 3:
                ExecuteTestShiftedRegisterBranchNoPc<3, CheckRemaining, ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            }
            goto block_done;
        }
        case ARMIR::Opcode::ArmTestRegisterShiftedRegisterBranchNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                ExecuteTestRegisterShiftedRegisterBranchNoPc<0, CheckRemaining, ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            case 1:
                ExecuteTestRegisterShiftedRegisterBranchNoPc<1, CheckRemaining, ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            case 2:
                ExecuteTestRegisterShiftedRegisterBranchNoPc<2, CheckRemaining, ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            case 3:
                ExecuteTestRegisterShiftedRegisterBranchNoPc<3, CheckRemaining, ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            }
            goto block_done;
        }
        case ARMIR::Opcode::ArmAddSubImmediateSetFlagsBranchNoPcAlways: {
            const u32 rd = op.arg0 & 0xF;
            const u32 rn = (op.arg0 >> 4) & 0xF;
            const bool subtract = ((op.arg0 >> 8) & 1) != 0;
            const u32 branch_condition = (op.arg0 >> 12) & 0xF;
            const u32 compare_guest_size = (op.arg0 >> 16) & 0xFF;
            if (op.arg1 == 0) {
                const u32 value = state->Reg[rn];
                const bool carry = subtract;
                state->Reg[rd] = value;
                SetLazyArithmeticFlags(value, carry, false);

                if constexpr (CheckRemaining) {
                    if (remaining_instructions - result.instructions < 2) {
                        state->Reg[15] += compare_guest_size;
                        result.instructions++;
                        goto block_done;
                    }
                }

                const bool take_branch = ConditionPassedFromFlags(
                    branch_condition, (value >> 31) != 0, value == 0, carry, false);
                CountFusedBranch<ProfileOpcodes>(result, take_branch);
                state->Reg[15] = take_branch ? op.arg2 : state->Reg[15] + op.guest_size;
                result.instructions += 2;
                goto block_done;
            }
            const AddWithCarryResult add =
                EvaluateAddSubFlags(state->Reg[rn], op.arg1, subtract);
            state->Reg[rd] = add.value;
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            if constexpr (CheckRemaining) {
                if (remaining_instructions - result.instructions < 2) {
                    state->Reg[15] += compare_guest_size;
                    result.instructions++;
                    goto block_done;
                }
            }

            const bool take_branch = ConditionPassedFromFlags(
                branch_condition, (add.value >> 31) != 0, add.value == 0, add.carry,
                add.overflow);
            CountFusedBranch<ProfileOpcodes>(result, take_branch);
            state->Reg[15] = take_branch ? op.arg2 : state->Reg[15] + op.guest_size;
            result.instructions += 2;
            goto block_done;
        }
        case ARMIR::Opcode::ArmAddSubRegisterSetFlagsBranchNoPcAlways: {
            const u32 rd = op.arg0 & 0xF;
            const u32 rn = (op.arg0 >> 4) & 0xF;
            const u32 rm = (op.arg0 >> 8) & 0xF;
            const bool subtract = ((op.arg0 >> 12) & 1) != 0;
            const u32 branch_condition = (op.arg0 >> 16) & 0xF;
            const u32 compare_guest_size = (op.arg0 >> 24) & 0xFF;
            const AddWithCarryResult add =
                EvaluateAddSubFlags(state->Reg[rn], state->Reg[rm], subtract);
            state->Reg[rd] = add.value;
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            if constexpr (CheckRemaining) {
                if (remaining_instructions - result.instructions < 2) {
                    state->Reg[15] += compare_guest_size;
                    result.instructions++;
                    goto block_done;
                }
            }

            const bool take_branch = ConditionPassedFromFlags(
                branch_condition, (add.value >> 31) != 0, add.value == 0, add.carry,
                add.overflow);
            CountFusedBranch<ProfileOpcodes>(result, take_branch);
            state->Reg[15] = take_branch ? op.arg1 : state->Reg[15] + op.guest_size;
            result.instructions += 2;
            goto block_done;
        }
        case ARMIR::Opcode::ArmAddSubShiftedRegisterSetFlagsBranchNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                ExecuteAddSubShiftedRegisterSetFlagsBranchNoPc<0, CheckRemaining, ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            case 1:
                ExecuteAddSubShiftedRegisterSetFlagsBranchNoPc<1, CheckRemaining, ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            case 2:
                ExecuteAddSubShiftedRegisterSetFlagsBranchNoPc<2, CheckRemaining, ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            case 3:
                ExecuteAddSubShiftedRegisterSetFlagsBranchNoPc<3, CheckRemaining, ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            }
            goto block_done;
        }
        case ARMIR::Opcode::ArmAddSubRegisterShiftedRegisterSetFlagsBranchNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                ExecuteAddSubRegisterShiftedRegisterSetFlagsBranchNoPc<0, CheckRemaining,
                                                                       ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            case 1:
                ExecuteAddSubRegisterShiftedRegisterSetFlagsBranchNoPc<1, CheckRemaining,
                                                                       ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            case 2:
                ExecuteAddSubRegisterShiftedRegisterSetFlagsBranchNoPc<2, CheckRemaining,
                                                                       ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            case 3:
                ExecuteAddSubRegisterShiftedRegisterSetFlagsBranchNoPc<3, CheckRemaining,
                                                                       ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            }
            goto block_done;
        }
        case ARMIR::Opcode::ArmLogicalImmediateSetFlagsBranchNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = (op.arg0 >> 4) & 0xF;
            const u32 rn = (op.arg0 >> 8) & 0xF;
            const u32 branch_condition = (op.arg0 >> 12) & 0xF;
            const bool shifter_carry = ((op.arg0 >> 16) & 1) != 0;
            const bool shifter_carry_from_c_flag = ((op.arg0 >> 17) & 1) != 0;
            const u32 compare_guest_size = (op.arg0 >> 24) & 0xFF;
            const bool carry = shifter_carry_from_c_flag ? ReadCFlag() : shifter_carry;
            const bool overflow = ConditionUsesVFlag(branch_condition) ? ReadVFlag() : false;
            u32 data_result = 0;
            if (!EvaluateLogicalWriteResult(data_opcode, state->Reg[rn], op.arg1, data_result)) {
                result.needs_fallback = true;
                goto block_done;
            }
            state->Reg[rd] = data_result;
            SetLazyLogicalFlags(data_result, carry);

            if constexpr (CheckRemaining) {
                if (remaining_instructions - result.instructions < 2) {
                    state->Reg[15] += compare_guest_size;
                    result.instructions++;
                    goto block_done;
                }
            }

            const bool take_branch =
                ConditionPassedFromFlags(branch_condition, (data_result >> 31) != 0,
                                         data_result == 0, carry, overflow);
            CountFusedBranch<ProfileOpcodes>(result, take_branch);
            state->Reg[15] = take_branch ? op.arg2 : state->Reg[15] + op.guest_size;
            result.instructions += 2;
            goto block_done;
        }
        case ARMIR::Opcode::ArmLogicalRegisterSetFlagsBranchNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = (op.arg0 >> 4) & 0xF;
            const u32 rn = (op.arg0 >> 8) & 0xF;
            const u32 rm = (op.arg0 >> 12) & 0xF;
            const u32 branch_condition = (op.arg0 >> 16) & 0xF;
            const u32 compare_guest_size = (op.arg0 >> 24) & 0xFF;
            const bool carry = ReadCFlag();
            const bool overflow = ConditionUsesVFlag(branch_condition) ? ReadVFlag() : false;
            u32 data_result = 0;
            if (!EvaluateLogicalWriteResult(data_opcode, state->Reg[rn], state->Reg[rm],
                                            data_result)) {
                result.needs_fallback = true;
                goto block_done;
            }
            state->Reg[rd] = data_result;
            SetLazyLogicalFlags(data_result, carry);

            if constexpr (CheckRemaining) {
                if (remaining_instructions - result.instructions < 2) {
                    state->Reg[15] += compare_guest_size;
                    result.instructions++;
                    goto block_done;
                }
            }

            const bool take_branch =
                ConditionPassedFromFlags(branch_condition, (data_result >> 31) != 0,
                                         data_result == 0, carry, overflow);
            CountFusedBranch<ProfileOpcodes>(result, take_branch);
            state->Reg[15] = take_branch ? op.arg1 : state->Reg[15] + op.guest_size;
            result.instructions += 2;
            goto block_done;
        }
        case ARMIR::Opcode::ArmLogicalShiftedRegisterSetFlagsBranchNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            bool supported = false;
            switch (shift_type) {
            case 0:
                supported = ExecuteLogicalShiftedRegisterSetFlagsBranchNoPc<0, CheckRemaining,
                                                                            ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            case 1:
                supported = ExecuteLogicalShiftedRegisterSetFlagsBranchNoPc<1, CheckRemaining,
                                                                            ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            case 2:
                supported = ExecuteLogicalShiftedRegisterSetFlagsBranchNoPc<2, CheckRemaining,
                                                                            ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            case 3:
                supported = ExecuteLogicalShiftedRegisterSetFlagsBranchNoPc<3, CheckRemaining,
                                                                            ProfileOpcodes>(
                    op, remaining_instructions, result);
                break;
            default:
                break;
            }
            if (!supported) {
                result.needs_fallback = true;
                goto block_done;
            }
            goto block_done;
        }
        case ARMIR::Opcode::ArmLogicalRegisterShiftedRegisterSetFlagsBranchNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            bool supported = false;
            switch (shift_type) {
            case 0:
                supported = ExecuteLogicalRegisterShiftedRegisterSetFlagsBranchNoPc<
                    0, CheckRemaining, ProfileOpcodes>(op, remaining_instructions, result);
                break;
            case 1:
                supported = ExecuteLogicalRegisterShiftedRegisterSetFlagsBranchNoPc<
                    1, CheckRemaining, ProfileOpcodes>(op, remaining_instructions, result);
                break;
            case 2:
                supported = ExecuteLogicalRegisterShiftedRegisterSetFlagsBranchNoPc<
                    2, CheckRemaining, ProfileOpcodes>(op, remaining_instructions, result);
                break;
            case 3:
                supported = ExecuteLogicalRegisterShiftedRegisterSetFlagsBranchNoPc<
                    3, CheckRemaining, ProfileOpcodes>(op, remaining_instructions, result);
                break;
            default:
                break;
            }
            if (!supported) {
                result.needs_fallback = true;
                goto block_done;
            }
            goto block_done;
        }
        case ARMIR::Opcode::ArmCarryArithmeticImmediateSetFlagsBranchNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = (op.arg0 >> 4) & 0xF;
            const u32 rn = (op.arg0 >> 8) & 0xF;
            const u32 branch_condition = (op.arg0 >> 12) & 0xF;
            const u32 compare_guest_size = (op.arg0 >> 24) & 0xFF;
            const u32 carry_in = data_opcode == 3 ? 0 : (ReadCFlag() ? 1 : 0);
            AddWithCarryResult add{};
            if (!EvaluateCarryArithmeticWriteResult(data_opcode, state->Reg[rn], op.arg1,
                                                    carry_in, add)) {
                result.needs_fallback = true;
                goto block_done;
            }
            state->Reg[rd] = add.value;
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            if constexpr (CheckRemaining) {
                if (remaining_instructions - result.instructions < 2) {
                    state->Reg[15] += compare_guest_size;
                    result.instructions++;
                    goto block_done;
                }
            }

            const bool take_branch = ConditionPassedFromFlags(
                branch_condition, (add.value >> 31) != 0, add.value == 0, add.carry,
                add.overflow);
            CountFusedBranch<ProfileOpcodes>(result, take_branch);
            state->Reg[15] = take_branch ? op.arg2 : state->Reg[15] + op.guest_size;
            result.instructions += 2;
            goto block_done;
        }
        case ARMIR::Opcode::ArmCarryArithmeticRegisterSetFlagsBranchNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = (op.arg0 >> 4) & 0xF;
            const u32 rn = (op.arg0 >> 8) & 0xF;
            const u32 rm = (op.arg0 >> 12) & 0xF;
            const u32 branch_condition = (op.arg0 >> 16) & 0xF;
            const u32 compare_guest_size = (op.arg0 >> 24) & 0xFF;
            const u32 carry_in = data_opcode == 3 ? 0 : (ReadCFlag() ? 1 : 0);
            AddWithCarryResult add{};
            if (!EvaluateCarryArithmeticWriteResult(data_opcode, state->Reg[rn], state->Reg[rm],
                                                    carry_in, add)) {
                result.needs_fallback = true;
                goto block_done;
            }
            state->Reg[rd] = add.value;
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            if constexpr (CheckRemaining) {
                if (remaining_instructions - result.instructions < 2) {
                    state->Reg[15] += compare_guest_size;
                    result.instructions++;
                    goto block_done;
                }
            }

            const bool take_branch = ConditionPassedFromFlags(
                branch_condition, (add.value >> 31) != 0, add.value == 0, add.carry,
                add.overflow);
            CountFusedBranch<ProfileOpcodes>(result, take_branch);
            state->Reg[15] = take_branch ? op.arg1 : state->Reg[15] + op.guest_size;
            result.instructions += 2;
            goto block_done;
        }
        case ARMIR::Opcode::ArmCarryArithmeticShiftedRegisterSetFlagsBranchNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            bool supported = false;
            switch (shift_type) {
            case 0:
                supported = ExecuteCarryArithmeticShiftedRegisterSetFlagsBranchNoPc<
                    0, CheckRemaining, ProfileOpcodes>(op, remaining_instructions, result);
                break;
            case 1:
                supported = ExecuteCarryArithmeticShiftedRegisterSetFlagsBranchNoPc<
                    1, CheckRemaining, ProfileOpcodes>(op, remaining_instructions, result);
                break;
            case 2:
                supported = ExecuteCarryArithmeticShiftedRegisterSetFlagsBranchNoPc<
                    2, CheckRemaining, ProfileOpcodes>(op, remaining_instructions, result);
                break;
            case 3:
                supported = ExecuteCarryArithmeticShiftedRegisterSetFlagsBranchNoPc<
                    3, CheckRemaining, ProfileOpcodes>(op, remaining_instructions, result);
                break;
            default:
                break;
            }
            if (!supported) {
                result.needs_fallback = true;
                goto block_done;
            }
            goto block_done;
        }
        case ARMIR::Opcode::ArmCarryArithmeticRegisterShiftedRegisterSetFlagsBranchNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            bool supported = false;
            switch (shift_type) {
            case 0:
                supported =
                    ExecuteCarryArithmeticRegisterShiftedRegisterSetFlagsBranchNoPc<
                        0, CheckRemaining, ProfileOpcodes>(op, remaining_instructions, result);
                break;
            case 1:
                supported =
                    ExecuteCarryArithmeticRegisterShiftedRegisterSetFlagsBranchNoPc<
                        1, CheckRemaining, ProfileOpcodes>(op, remaining_instructions, result);
                break;
            case 2:
                supported =
                    ExecuteCarryArithmeticRegisterShiftedRegisterSetFlagsBranchNoPc<
                        2, CheckRemaining, ProfileOpcodes>(op, remaining_instructions, result);
                break;
            case 3:
                supported =
                    ExecuteCarryArithmeticRegisterShiftedRegisterSetFlagsBranchNoPc<
                        3, CheckRemaining, ProfileOpcodes>(op, remaining_instructions, result);
                break;
            default:
                break;
            }
            if (!supported) {
                result.needs_fallback = true;
                goto block_done;
            }
            goto block_done;
        }
        case ARMIR::Opcode::ArmAddImmediateSetFlagsNoPcAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            if (op.arg2 == 0) {
                const u32 value = state->Reg[rn];
                state->Reg[rd] = value;
                SetLazyArithmeticFlags(value, false, false);

                AdvancePC(*state, op);
                result.instructions++;
                break;
            }
            const AddWithCarryResult add = EvaluateAddSubFlags(state->Reg[rn], op.arg2, false);
            state->Reg[rd] = add.value;
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSubImmediateSetFlagsNoPcAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            if (op.arg2 == 0) {
                const u32 value = state->Reg[rn];
                state->Reg[rd] = value;
                SetLazyArithmeticFlags(value, true, false);

                AdvancePC(*state, op);
                result.instructions++;
                break;
            }
            const AddWithCarryResult add = EvaluateAddSubFlags(state->Reg[rn], op.arg2, true);
            state->Reg[rd] = add.value;
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareNegativeImmediateNoPcAlways: {
            const u32 rn = op.arg1 & 0xF;
            if (op.arg2 == 0) {
                const u32 value = state->Reg[rn];
                SetLazyArithmeticFlags(value, false, false);

                AdvancePC(*state, op);
                result.instructions++;
                break;
            }
            const AddWithCarryResult add = EvaluateCompareFlags(state->Reg[rn], op.arg2, true);
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmAddRegisterSetFlagsNoPcAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const AddWithCarryResult add =
                EvaluateAddSubFlags(state->Reg[rn], state->Reg[rm], false);
            state->Reg[rd] = add.value;
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSubRegisterSetFlagsNoPcAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const AddWithCarryResult add =
                EvaluateAddSubFlags(state->Reg[rn], state->Reg[rm], true);
            state->Reg[rd] = add.value;
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareNegativeRegisterNoPcAlways: {
            const u32 rn = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const AddWithCarryResult add =
                EvaluateCompareFlags(state->Reg[rn], state->Reg[rm], true);
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalImmediateAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 operand = op.arg2;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            switch (data_opcode) {
            case 0: // AND
                state->Reg[rd] = rn_value & operand;
                break;
            case 1: // EOR
                state->Reg[rd] = rn_value ^ operand;
                break;
            case 12: // ORR
                state->Reg[rd] = rn_value | operand;
                break;
            case 13: // MOV
                state->Reg[rd] = operand;
                break;
            case 14: // BIC
                state->Reg[rd] = rn_value & ~operand;
                break;
            case 15: // MVN
                state->Reg[rd] = ~operand;
                break;
            default:
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalRegisterAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 operand = state->Reg[rm];
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            switch (data_opcode) {
            case 0: // AND
                state->Reg[rd] = rn_value & operand;
                break;
            case 1: // EOR
                state->Reg[rd] = rn_value ^ operand;
                break;
            case 12: // ORR
                state->Reg[rd] = rn_value | operand;
                break;
            case 13: // MOV
                state->Reg[rd] = operand;
                break;
            case 14: // BIC
                state->Reg[rd] = rn_value & ~operand;
                break;
            case 15: // MVN
                state->Reg[rd] = ~operand;
                break;
            default:
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmMoveShiftedRegisterAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const bool needs_c_flag = shift_type == 3 && shift_imm == 0;
            const ShiftedRegister shifted =
                EvaluateShiftedRegisterOperand(*state, rm, shift_type, shift_imm,
                                               needs_c_flag ? ReadCFlag() : false);
            state->Reg[rd] = shifted.value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmMoveShiftedRegisterSetFlagsAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const bool needs_c_flag = RegisterShiftOperandNeedsCarry(shift_type, shift_imm, false);
            const ShiftedRegister shifted =
                EvaluateShiftedRegisterOperand(*state, rm, shift_type, shift_imm,
                                               needs_c_flag ? ReadCFlag() : false);
            state->Reg[rd] = shifted.value;
            SetLazyLogicalFlags(shifted.value, shifted.carry);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmAddShiftedRegisterAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const bool needs_c_flag = shift_type == 3 && shift_imm == 0;
            const ShiftedRegister shifted =
                EvaluateShiftedRegisterOperand(*state, rm, shift_type, shift_imm,
                                               needs_c_flag ? ReadCFlag() : false);
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            state->Reg[rd] = rn_value + shifted.value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSubShiftedRegisterAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const bool needs_c_flag = shift_type == 3 && shift_imm == 0;
            const ShiftedRegister shifted =
                EvaluateShiftedRegisterOperand(*state, rm, shift_type, shift_imm,
                                               needs_c_flag ? ReadCFlag() : false);
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            state->Reg[rd] = rn_value - shifted.value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareShiftedRegisterAlways: {
            const u32 rn = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const bool needs_c_flag = shift_type == 3 && shift_imm == 0;
            const ShiftedRegister shifted =
                EvaluateShiftedRegisterOperand(*state, rm, shift_type, shift_imm,
                                               needs_c_flag ? ReadCFlag() : false);
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            const AddWithCarryResult add = EvaluateCompareFlags(rn_value, shifted.value, false);
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmAddShiftedRegisterSetFlagsAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const bool needs_c_flag = shift_type == 3 && shift_imm == 0;
            const ShiftedRegister shifted =
                EvaluateShiftedRegisterOperand(*state, rm, shift_type, shift_imm,
                                               needs_c_flag ? ReadCFlag() : false);
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            const AddWithCarryResult add = EvaluateAddSubFlags(rn_value, shifted.value, false);
            state->Reg[rd] = add.value;
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSubShiftedRegisterSetFlagsAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const bool needs_c_flag = shift_type == 3 && shift_imm == 0;
            const ShiftedRegister shifted =
                EvaluateShiftedRegisterOperand(*state, rm, shift_type, shift_imm,
                                               needs_c_flag ? ReadCFlag() : false);
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            const AddWithCarryResult add = EvaluateAddSubFlags(rn_value, shifted.value, true);
            state->Reg[rd] = add.value;
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareNegativeShiftedRegisterAlways: {
            const u32 rn = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const bool needs_c_flag = shift_type == 3 && shift_imm == 0;
            const ShiftedRegister shifted =
                EvaluateShiftedRegisterOperand(*state, rm, shift_type, shift_imm,
                                               needs_c_flag ? ReadCFlag() : false);
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            const AddWithCarryResult add = EvaluateCompareFlags(rn_value, shifted.value, true);
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalShiftedRegisterAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const bool needs_c_flag = shift_type == 3 && shift_imm == 0;
            const ShiftedRegister shifted =
                EvaluateShiftedRegisterOperand(*state, rm, shift_type, shift_imm,
                                               needs_c_flag ? ReadCFlag() : false);
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            switch (data_opcode) {
            case 0: // AND
                state->Reg[rd] = rn_value & shifted.value;
                break;
            case 1: // EOR
                state->Reg[rd] = rn_value ^ shifted.value;
                break;
            case 12: // ORR
                state->Reg[rd] = rn_value | shifted.value;
                break;
            case 13: // MOV
                state->Reg[rd] = shifted.value;
                break;
            case 14: // BIC
                state->Reg[rd] = rn_value & ~shifted.value;
                break;
            case 15: // MVN
                state->Reg[rd] = ~shifted.value;
                break;
            default:
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalShiftedRegisterSetFlagsAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const bool needs_c_flag =
                (shift_type == 0 && shift_imm == 0) ||
                RegisterShiftOperandNeedsCarry(shift_type, shift_imm, false);
            const ShiftedRegister shifted =
                EvaluateShiftedRegisterOperand(*state, rm, shift_type, shift_imm,
                                               needs_c_flag ? ReadCFlag() : false);
            u32 data_result = 0;
            bool write_result = true;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            switch (data_opcode) {
            case 0: // AND
                data_result = rn_value & shifted.value;
                break;
            case 1: // EOR
                data_result = rn_value ^ shifted.value;
                break;
            case 8: // TST
                data_result = rn_value & shifted.value;
                write_result = false;
                break;
            case 9: // TEQ
                data_result = rn_value ^ shifted.value;
                write_result = false;
                break;
            case 12: // ORR
                data_result = rn_value | shifted.value;
                break;
            case 13: // MOV
                data_result = shifted.value;
                break;
            case 14: // BIC
                data_result = rn_value & ~shifted.value;
                break;
            case 15: // MVN
                data_result = ~shifted.value;
                break;
            default:
                result.needs_fallback = true;
                goto block_done;
            }
            if (write_result) {
                state->Reg[rd] = data_result;
            }
            SetLazyLogicalFlags(data_result, shifted.carry);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmAddShiftedRegisterNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                ExecuteAddSubShiftedRegisterNoPc<0, false>(op);
                break;
            case 1:
                ExecuteAddSubShiftedRegisterNoPc<1, false>(op);
                break;
            case 2:
                ExecuteAddSubShiftedRegisterNoPc<2, false>(op);
                break;
            case 3:
                ExecuteAddSubShiftedRegisterNoPc<3, false>(op);
                break;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSubShiftedRegisterNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                ExecuteAddSubShiftedRegisterNoPc<0, true>(op);
                break;
            case 1:
                ExecuteAddSubShiftedRegisterNoPc<1, true>(op);
                break;
            case 2:
                ExecuteAddSubShiftedRegisterNoPc<2, true>(op);
                break;
            case 3:
                ExecuteAddSubShiftedRegisterNoPc<3, true>(op);
                break;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareShiftedRegisterNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                ExecuteCompareShiftedRegisterNoPc<0, false>(op);
                break;
            case 1:
                ExecuteCompareShiftedRegisterNoPc<1, false>(op);
                break;
            case 2:
                ExecuteCompareShiftedRegisterNoPc<2, false>(op);
                break;
            case 3:
                ExecuteCompareShiftedRegisterNoPc<3, false>(op);
                break;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmAddShiftedRegisterSetFlagsNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                ExecuteAddSubShiftedRegisterSetFlagsNoPc<0, false>(op);
                break;
            case 1:
                ExecuteAddSubShiftedRegisterSetFlagsNoPc<1, false>(op);
                break;
            case 2:
                ExecuteAddSubShiftedRegisterSetFlagsNoPc<2, false>(op);
                break;
            case 3:
                ExecuteAddSubShiftedRegisterSetFlagsNoPc<3, false>(op);
                break;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSubShiftedRegisterSetFlagsNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                ExecuteAddSubShiftedRegisterSetFlagsNoPc<0, true>(op);
                break;
            case 1:
                ExecuteAddSubShiftedRegisterSetFlagsNoPc<1, true>(op);
                break;
            case 2:
                ExecuteAddSubShiftedRegisterSetFlagsNoPc<2, true>(op);
                break;
            case 3:
                ExecuteAddSubShiftedRegisterSetFlagsNoPc<3, true>(op);
                break;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareNegativeShiftedRegisterNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                ExecuteCompareShiftedRegisterNoPc<0, true>(op);
                break;
            case 1:
                ExecuteCompareShiftedRegisterNoPc<1, true>(op);
                break;
            case 2:
                ExecuteCompareShiftedRegisterNoPc<2, true>(op);
                break;
            case 3:
                ExecuteCompareShiftedRegisterNoPc<3, true>(op);
                break;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalShiftedRegisterNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            bool supported = false;
            switch (shift_type) {
            case 0:
                supported = ExecuteLogicalShiftedRegisterNoPc<0>(op);
                break;
            case 1:
                supported = ExecuteLogicalShiftedRegisterNoPc<1>(op);
                break;
            case 2:
                supported = ExecuteLogicalShiftedRegisterNoPc<2>(op);
                break;
            case 3:
                supported = ExecuteLogicalShiftedRegisterNoPc<3>(op);
                break;
            default:
                break;
            }
            if (!supported) {
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            bool supported = false;
            switch (shift_type) {
            case 0:
                supported = ExecuteLogicalShiftedRegisterSetFlagsNoPc<0>(op);
                break;
            case 1:
                supported = ExecuteLogicalShiftedRegisterSetFlagsNoPc<1>(op);
                break;
            case 2:
                supported = ExecuteLogicalShiftedRegisterSetFlagsNoPc<2>(op);
                break;
            case 3:
                supported = ExecuteLogicalShiftedRegisterSetFlagsNoPc<3>(op);
                break;
            default:
                break;
            }
            if (!supported) {
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysLsl: {
            if (!ExecuteLogicalShiftedRegisterSetFlagsNoPc<0>(op)) {
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysLsr: {
            if (!ExecuteLogicalShiftedRegisterSetFlagsNoPc<1>(op)) {
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysAsr: {
            if (!ExecuteLogicalShiftedRegisterSetFlagsNoPc<2>(op)) {
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysRor: {
            if (!ExecuteLogicalShiftedRegisterSetFlagsNoPc<3>(op)) {
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmTstShiftedRegisterNoPcAlwaysLsl:
            ExecuteTestShiftedRegisterSetFlagsNoPc<0, false>(op);
            AdvancePC(*state, op);
            result.instructions++;
            break;
        case ARMIR::Opcode::ArmTstShiftedRegisterNoPcAlwaysLsr:
            ExecuteTestShiftedRegisterSetFlagsNoPc<1, false>(op);
            AdvancePC(*state, op);
            result.instructions++;
            break;
        case ARMIR::Opcode::ArmTstShiftedRegisterNoPcAlwaysAsr:
            ExecuteTestShiftedRegisterSetFlagsNoPc<2, false>(op);
            AdvancePC(*state, op);
            result.instructions++;
            break;
        case ARMIR::Opcode::ArmTstShiftedRegisterNoPcAlwaysRor:
            ExecuteTestShiftedRegisterSetFlagsNoPc<3, false>(op);
            AdvancePC(*state, op);
            result.instructions++;
            break;
        case ARMIR::Opcode::ArmTeqShiftedRegisterNoPcAlwaysLsl:
            ExecuteTestShiftedRegisterSetFlagsNoPc<0, true>(op);
            AdvancePC(*state, op);
            result.instructions++;
            break;
        case ARMIR::Opcode::ArmTeqShiftedRegisterNoPcAlwaysLsr:
            ExecuteTestShiftedRegisterSetFlagsNoPc<1, true>(op);
            AdvancePC(*state, op);
            result.instructions++;
            break;
        case ARMIR::Opcode::ArmTeqShiftedRegisterNoPcAlwaysAsr:
            ExecuteTestShiftedRegisterSetFlagsNoPc<2, true>(op);
            AdvancePC(*state, op);
            result.instructions++;
            break;
        case ARMIR::Opcode::ArmTeqShiftedRegisterNoPcAlwaysRor:
            ExecuteTestShiftedRegisterSetFlagsNoPc<3, true>(op);
            AdvancePC(*state, op);
            result.instructions++;
            break;
        case ARMIR::Opcode::ArmArithmeticShiftedRegisterNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            bool supported = false;
            switch (shift_type) {
            case 0:
                supported = ExecuteCarryArithmeticShiftedRegisterNoPc<0, false>(op);
                break;
            case 1:
                supported = ExecuteCarryArithmeticShiftedRegisterNoPc<1, false>(op);
                break;
            case 2:
                supported = ExecuteCarryArithmeticShiftedRegisterNoPc<2, false>(op);
                break;
            case 3:
                supported = ExecuteCarryArithmeticShiftedRegisterNoPc<3, false>(op);
                break;
            default:
                break;
            }
            if (!supported) {
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmArithmeticShiftedRegisterSetFlagsNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            bool supported = false;
            switch (shift_type) {
            case 0:
                supported = ExecuteCarryArithmeticShiftedRegisterNoPc<0, true>(op);
                break;
            case 1:
                supported = ExecuteCarryArithmeticShiftedRegisterNoPc<1, true>(op);
                break;
            case 2:
                supported = ExecuteCarryArithmeticShiftedRegisterNoPc<2, true>(op);
                break;
            case 3:
                supported = ExecuteCarryArithmeticShiftedRegisterNoPc<3, true>(op);
                break;
            default:
                break;
            }
            if (!supported) {
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmMoveRegisterShiftedRegisterAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 rs = (op.arg1 >> 16) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const ShiftedRegister shifted =
                EvaluateRegisterShiftedRegisterOperand(*state, rm, shift_type, rs, false);
            state->Reg[rd] = shifted.value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmMoveRegisterShiftedRegisterSetFlagsAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 rs = (op.arg1 >> 16) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const bool needs_c_flag = (state->Reg[rs] & 0xFF) == 0;
            const ShiftedRegister shifted =
                EvaluateRegisterShiftedRegisterOperand(*state, rm, shift_type, rs,
                                                       needs_c_flag ? ReadCFlag() : false);
            state->Reg[rd] = shifted.value;
            SetLazyLogicalFlags(shifted.value, shifted.carry);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmAddRegisterShiftedRegisterAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rs = (op.arg1 >> 24) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const ShiftedRegister shifted =
                EvaluateRegisterShiftedRegisterOperand(*state, rm, shift_type, rs, false);
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            state->Reg[rd] = rn_value + shifted.value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSubRegisterShiftedRegisterAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rs = (op.arg1 >> 24) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const ShiftedRegister shifted =
                EvaluateRegisterShiftedRegisterOperand(*state, rm, shift_type, rs, false);
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            state->Reg[rd] = rn_value - shifted.value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareRegisterShiftedRegisterAlways: {
            const u32 rn = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 rs = (op.arg1 >> 16) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const ShiftedRegister shifted =
                EvaluateRegisterShiftedRegisterOperand(*state, rm, shift_type, rs, false);
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            const AddWithCarryResult add = EvaluateCompareFlags(rn_value, shifted.value, false);
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmAddRegisterShiftedRegisterSetFlagsAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rs = (op.arg1 >> 24) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const ShiftedRegister shifted =
                EvaluateRegisterShiftedRegisterOperand(*state, rm, shift_type, rs, false);
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            const AddWithCarryResult add = EvaluateAddSubFlags(rn_value, shifted.value, false);
            state->Reg[rd] = add.value;
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSubRegisterShiftedRegisterSetFlagsAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rs = (op.arg1 >> 24) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const ShiftedRegister shifted =
                EvaluateRegisterShiftedRegisterOperand(*state, rm, shift_type, rs, false);
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            const AddWithCarryResult add = EvaluateAddSubFlags(rn_value, shifted.value, true);
            state->Reg[rd] = add.value;
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareNegativeRegisterShiftedRegisterAlways: {
            const u32 rn = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 rs = (op.arg1 >> 16) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const ShiftedRegister shifted =
                EvaluateRegisterShiftedRegisterOperand(*state, rm, shift_type, rs, false);
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            const AddWithCarryResult add = EvaluateCompareFlags(rn_value, shifted.value, true);
            SetLazyArithmeticFlags(add.value, add.carry, add.overflow);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalRegisterShiftedRegisterAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rs = (op.arg1 >> 24) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const ShiftedRegister shifted =
                EvaluateRegisterShiftedRegisterOperand(*state, rm, shift_type, rs, false);
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            switch (data_opcode) {
            case 0: // AND
                state->Reg[rd] = rn_value & shifted.value;
                break;
            case 1: // EOR
                state->Reg[rd] = rn_value ^ shifted.value;
                break;
            case 12: // ORR
                state->Reg[rd] = rn_value | shifted.value;
                break;
            case 13: // MOV
                state->Reg[rd] = shifted.value;
                break;
            case 14: // BIC
                state->Reg[rd] = rn_value & ~shifted.value;
                break;
            case 15: // MVN
                state->Reg[rd] = ~shifted.value;
                break;
            default:
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalRegisterShiftedRegisterSetFlagsAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rs = (op.arg1 >> 24) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const bool needs_c_flag = (state->Reg[rs] & 0xFF) == 0;
            const ShiftedRegister shifted =
                EvaluateRegisterShiftedRegisterOperand(*state, rm, shift_type, rs,
                                                       needs_c_flag ? ReadCFlag() : false);
            u32 data_result = 0;
            bool write_result = true;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            switch (data_opcode) {
            case 0: // AND
                data_result = rn_value & shifted.value;
                break;
            case 1: // EOR
                data_result = rn_value ^ shifted.value;
                break;
            case 8: // TST
                data_result = rn_value & shifted.value;
                write_result = false;
                break;
            case 9: // TEQ
                data_result = rn_value ^ shifted.value;
                write_result = false;
                break;
            case 12: // ORR
                data_result = rn_value | shifted.value;
                break;
            case 13: // MOV
                data_result = shifted.value;
                break;
            case 14: // BIC
                data_result = rn_value & ~shifted.value;
                break;
            case 15: // MVN
                data_result = ~shifted.value;
                break;
            default:
                result.needs_fallback = true;
                goto block_done;
            }
            if (write_result) {
                state->Reg[rd] = data_result;
            }
            SetLazyLogicalFlags(data_result, shifted.carry);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmAddRegisterShiftedRegisterNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                ExecuteAddSubRegisterShiftedRegisterNoPc<0, false>(op);
                break;
            case 1:
                ExecuteAddSubRegisterShiftedRegisterNoPc<1, false>(op);
                break;
            case 2:
                ExecuteAddSubRegisterShiftedRegisterNoPc<2, false>(op);
                break;
            case 3:
                ExecuteAddSubRegisterShiftedRegisterNoPc<3, false>(op);
                break;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSubRegisterShiftedRegisterNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                ExecuteAddSubRegisterShiftedRegisterNoPc<0, true>(op);
                break;
            case 1:
                ExecuteAddSubRegisterShiftedRegisterNoPc<1, true>(op);
                break;
            case 2:
                ExecuteAddSubRegisterShiftedRegisterNoPc<2, true>(op);
                break;
            case 3:
                ExecuteAddSubRegisterShiftedRegisterNoPc<3, true>(op);
                break;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareRegisterShiftedRegisterNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                ExecuteCompareRegisterShiftedRegisterNoPc<0, false>(op);
                break;
            case 1:
                ExecuteCompareRegisterShiftedRegisterNoPc<1, false>(op);
                break;
            case 2:
                ExecuteCompareRegisterShiftedRegisterNoPc<2, false>(op);
                break;
            case 3:
                ExecuteCompareRegisterShiftedRegisterNoPc<3, false>(op);
                break;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmAddRegisterShiftedRegisterSetFlagsNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                ExecuteAddSubRegisterShiftedRegisterSetFlagsNoPc<0, false>(op);
                break;
            case 1:
                ExecuteAddSubRegisterShiftedRegisterSetFlagsNoPc<1, false>(op);
                break;
            case 2:
                ExecuteAddSubRegisterShiftedRegisterSetFlagsNoPc<2, false>(op);
                break;
            case 3:
                ExecuteAddSubRegisterShiftedRegisterSetFlagsNoPc<3, false>(op);
                break;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSubRegisterShiftedRegisterSetFlagsNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                ExecuteAddSubRegisterShiftedRegisterSetFlagsNoPc<0, true>(op);
                break;
            case 1:
                ExecuteAddSubRegisterShiftedRegisterSetFlagsNoPc<1, true>(op);
                break;
            case 2:
                ExecuteAddSubRegisterShiftedRegisterSetFlagsNoPc<2, true>(op);
                break;
            case 3:
                ExecuteAddSubRegisterShiftedRegisterSetFlagsNoPc<3, true>(op);
                break;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCompareNegativeRegisterShiftedRegisterNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            switch (shift_type) {
            case 0:
                ExecuteCompareRegisterShiftedRegisterNoPc<0, true>(op);
                break;
            case 1:
                ExecuteCompareRegisterShiftedRegisterNoPc<1, true>(op);
                break;
            case 2:
                ExecuteCompareRegisterShiftedRegisterNoPc<2, true>(op);
                break;
            case 3:
                ExecuteCompareRegisterShiftedRegisterNoPc<3, true>(op);
                break;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalRegisterShiftedRegisterNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            bool supported = false;
            switch (shift_type) {
            case 0:
                supported = ExecuteLogicalRegisterShiftedRegisterNoPc<0>(op);
                break;
            case 1:
                supported = ExecuteLogicalRegisterShiftedRegisterNoPc<1>(op);
                break;
            case 2:
                supported = ExecuteLogicalRegisterShiftedRegisterNoPc<2>(op);
                break;
            case 3:
                supported = ExecuteLogicalRegisterShiftedRegisterNoPc<3>(op);
                break;
            }
            if (!supported) {
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalRegisterShiftedRegisterSetFlagsNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            bool supported = false;
            switch (shift_type) {
            case 0:
                supported = ExecuteLogicalRegisterShiftedRegisterSetFlagsNoPc<0>(op);
                break;
            case 1:
                supported = ExecuteLogicalRegisterShiftedRegisterSetFlagsNoPc<1>(op);
                break;
            case 2:
                supported = ExecuteLogicalRegisterShiftedRegisterSetFlagsNoPc<2>(op);
                break;
            case 3:
                supported = ExecuteLogicalRegisterShiftedRegisterSetFlagsNoPc<3>(op);
                break;
            }
            if (!supported) {
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmArithmeticImmediateAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            ExecuteDataProcessingNoFlags(data_opcode, ReadDataRegister(*state, rn, op), rd,
                                         op.arg2);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmArithmeticImmediateSetFlagsAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            ExecuteDataProcessingSetFlags(data_opcode, ReadDataRegister(*state, rn, op), rd,
                                          op.arg2, false);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmArithmeticRegisterAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            ExecuteDataProcessingNoFlags(data_opcode, ReadDataRegister(*state, rn, op), rd,
                                         state->Reg[rm]);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmArithmeticRegisterSetFlagsAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            ExecuteDataProcessingSetFlags(data_opcode, ReadDataRegister(*state, rn, op), rd,
                                          state->Reg[rm], false);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmArithmeticImmediateNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            ExecuteDataProcessingNoFlags(data_opcode, state->Reg[rn], rd, op.arg2);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmArithmeticImmediateSetFlagsNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            ExecuteDataProcessingSetFlags(data_opcode, state->Reg[rn], rd, op.arg2, false);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmArithmeticRegisterNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            ExecuteDataProcessingNoFlags(data_opcode, state->Reg[rn], rd, state->Reg[rm]);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmArithmeticRegisterSetFlagsNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            ExecuteDataProcessingSetFlags(data_opcode, state->Reg[rn], rd, state->Reg[rm], false);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmArithmeticShiftedRegisterAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const bool needs_c_flag = shift_type == 3 && shift_imm == 0;
            const ShiftedRegister shifted =
                EvaluateShiftedRegisterOperand(*state, rm, shift_type, shift_imm,
                                               needs_c_flag ? ReadCFlag() : false);
            ExecuteDataProcessingNoFlags(data_opcode, ReadDataRegister(*state, rn, op), rd,
                                         shifted.value);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmArithmeticShiftedRegisterSetFlagsAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const bool needs_c_flag = shift_type == 3 && shift_imm == 0;
            const ShiftedRegister shifted =
                EvaluateShiftedRegisterOperand(*state, rm, shift_type, shift_imm,
                                               needs_c_flag ? ReadCFlag() : false);
            ExecuteDataProcessingSetFlags(data_opcode, ReadDataRegister(*state, rn, op), rd,
                                          shifted.value, false);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmArithmeticRegisterShiftedRegisterAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rs = (op.arg1 >> 24) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const ShiftedRegister shifted =
                EvaluateRegisterShiftedRegisterOperand(*state, rm, shift_type, rs, false);
            ExecuteDataProcessingNoFlags(data_opcode, ReadDataRegister(*state, rn, op), rd,
                                         shifted.value);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmArithmeticRegisterShiftedRegisterSetFlagsAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rs = (op.arg1 >> 24) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const ShiftedRegister shifted =
                EvaluateRegisterShiftedRegisterOperand(*state, rm, shift_type, rs, false);
            ExecuteDataProcessingSetFlags(data_opcode, ReadDataRegister(*state, rn, op), rd,
                                          shifted.value, false);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmArithmeticRegisterShiftedRegisterNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            bool supported = false;
            switch (shift_type) {
            case 0:
                supported = ExecuteCarryArithmeticRegisterShiftedRegisterNoPc<0, false>(op);
                break;
            case 1:
                supported = ExecuteCarryArithmeticRegisterShiftedRegisterNoPc<1, false>(op);
                break;
            case 2:
                supported = ExecuteCarryArithmeticRegisterShiftedRegisterNoPc<2, false>(op);
                break;
            case 3:
                supported = ExecuteCarryArithmeticRegisterShiftedRegisterNoPc<3, false>(op);
                break;
            default:
                break;
            }
            if (!supported) {
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmArithmeticRegisterShiftedRegisterSetFlagsNoPcAlways: {
            const u32 shift_type = op.arg2 & 0x3;
            bool supported = false;
            switch (shift_type) {
            case 0:
                supported = ExecuteCarryArithmeticRegisterShiftedRegisterNoPc<0, true>(op);
                break;
            case 1:
                supported = ExecuteCarryArithmeticRegisterShiftedRegisterNoPc<1, true>(op);
                break;
            case 2:
                supported = ExecuteCarryArithmeticRegisterShiftedRegisterNoPc<2, true>(op);
                break;
            case 3:
                supported = ExecuteCarryArithmeticRegisterShiftedRegisterNoPc<3, true>(op);
                break;
            default:
                break;
            }
            if (!supported) {
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalImmediateSetFlagsAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const bool shifter_carry = ((op.arg0 >> 8) & 1) != 0;
            const bool shifter_carry_from_c_flag = ((op.arg0 >> 9) & 1) != 0;
            const bool carry = shifter_carry_from_c_flag ? ReadCFlag() : shifter_carry;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 operand = op.arg2;
            u32 data_result = 0;
            bool write_result = true;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            switch (data_opcode) {
            case 0: // AND
                data_result = rn_value & operand;
                break;
            case 1: // EOR
                data_result = rn_value ^ operand;
                break;
            case 8: // TST
                data_result = rn_value & operand;
                write_result = false;
                break;
            case 9: // TEQ
                data_result = rn_value ^ operand;
                write_result = false;
                break;
            case 12: // ORR
                data_result = rn_value | operand;
                break;
            case 13: // MOV
                data_result = operand;
                break;
            case 14: // BIC
                data_result = rn_value & ~operand;
                break;
            case 15: // MVN
                data_result = ~operand;
                break;
            default:
                result.needs_fallback = true;
                goto block_done;
            }
            if (write_result) {
                state->Reg[rd] = data_result;
            }
            SetLazyLogicalFlags(data_result, carry);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalRegisterSetFlagsAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const bool carry = ReadCFlag();
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 operand = state->Reg[rm];
            u32 data_result = 0;
            bool write_result = true;
            const u32 rn_value = ReadDataRegister(*state, rn, op);
            switch (data_opcode) {
            case 0: // AND
                data_result = rn_value & operand;
                break;
            case 1: // EOR
                data_result = rn_value ^ operand;
                break;
            case 8: // TST
                data_result = rn_value & operand;
                write_result = false;
                break;
            case 9: // TEQ
                data_result = rn_value ^ operand;
                write_result = false;
                break;
            case 12: // ORR
                data_result = rn_value | operand;
                break;
            case 13: // MOV
                data_result = operand;
                break;
            case 14: // BIC
                data_result = rn_value & ~operand;
                break;
            case 15: // MVN
                data_result = ~operand;
                break;
            default:
                result.needs_fallback = true;
                goto block_done;
            }
            if (write_result) {
                state->Reg[rd] = data_result;
            }
            SetLazyLogicalFlags(data_result, carry);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalImmediateNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 operand = op.arg2;
            const u32 rn_value = state->Reg[rn];
            switch (data_opcode) {
            case 0: // AND
                state->Reg[rd] = rn_value & operand;
                break;
            case 1: // EOR
                state->Reg[rd] = rn_value ^ operand;
                break;
            case 12: // ORR
                state->Reg[rd] = rn_value | operand;
                break;
            case 13: // MOV
                state->Reg[rd] = operand;
                break;
            case 14: // BIC
                state->Reg[rd] = rn_value & ~operand;
                break;
            case 15: // MVN
                state->Reg[rd] = ~operand;
                break;
            default:
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalRegisterNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 operand = state->Reg[rm];
            const u32 rn_value = state->Reg[rn];
            switch (data_opcode) {
            case 0: // AND
                state->Reg[rd] = rn_value & operand;
                break;
            case 1: // EOR
                state->Reg[rd] = rn_value ^ operand;
                break;
            case 12: // ORR
                state->Reg[rd] = rn_value | operand;
                break;
            case 13: // MOV
                state->Reg[rd] = operand;
                break;
            case 14: // BIC
                state->Reg[rd] = rn_value & ~operand;
                break;
            case 15: // MVN
                state->Reg[rd] = ~operand;
                break;
            default:
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalImmediateSetFlagsNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const bool shifter_carry = ((op.arg0 >> 8) & 1) != 0;
            const bool shifter_carry_from_c_flag = ((op.arg0 >> 9) & 1) != 0;
            const bool carry = shifter_carry_from_c_flag ? ReadCFlag() : shifter_carry;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 operand = op.arg2;
            const u32 rn_value = state->Reg[rn];
            u32 data_result = 0;
            bool write_result = true;
            switch (data_opcode) {
            case 0: // AND
                data_result = rn_value & operand;
                break;
            case 1: // EOR
                data_result = rn_value ^ operand;
                break;
            case 8: // TST
                data_result = rn_value & operand;
                write_result = false;
                break;
            case 9: // TEQ
                data_result = rn_value ^ operand;
                write_result = false;
                break;
            case 12: // ORR
                data_result = rn_value | operand;
                break;
            case 13: // MOV
                data_result = operand;
                break;
            case 14: // BIC
                data_result = rn_value & ~operand;
                break;
            case 15: // MVN
                data_result = ~operand;
                break;
            default:
                result.needs_fallback = true;
                goto block_done;
            }
            if (write_result) {
                state->Reg[rd] = data_result;
            }
            SetLazyLogicalFlags(data_result, carry);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLogicalRegisterSetFlagsNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const bool carry = ReadCFlag();
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 operand = state->Reg[rm];
            const u32 rn_value = state->Reg[rn];
            u32 data_result = 0;
            bool write_result = true;
            switch (data_opcode) {
            case 0: // AND
                data_result = rn_value & operand;
                break;
            case 1: // EOR
                data_result = rn_value ^ operand;
                break;
            case 8: // TST
                data_result = rn_value & operand;
                write_result = false;
                break;
            case 9: // TEQ
                data_result = rn_value ^ operand;
                write_result = false;
                break;
            case 12: // ORR
                data_result = rn_value | operand;
                break;
            case 13: // MOV
                data_result = operand;
                break;
            case 14: // BIC
                data_result = rn_value & ~operand;
                break;
            case 15: // MVN
                data_result = ~operand;
                break;
            default:
                result.needs_fallback = true;
                goto block_done;
            }
            if (write_result) {
                state->Reg[rd] = data_result;
            }
            SetLazyLogicalFlags(data_result, carry);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmDataProcessingImmediate: {

            const u32 data_opcode = op.arg0 & 0xF;
            const u32 condition = (op.arg0 >> 8) & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool set_flags = ((op.arg1 >> 16) & 1) != 0;
            const u32 operand = op.arg2;
            if (!set_flags) {
                ExecuteDataProcessingNoFlags(data_opcode, ReadDataRegister(*state, rn, op), rd,
                                             operand);
                result.instructions++;
                if (rd == 15) {
                    goto block_done;
                }
                AdvancePC(*state, op);
                break;
            }

            const bool shifter_carry = ((op.arg1 >> 17) & 1) != 0;
            const bool shifter_carry_from_c_flag = ((op.arg1 >> 18) & 1) != 0;
            const bool effective_shifter_carry =
                NeedsShifterCarry(data_opcode, true)
                    ? (shifter_carry_from_c_flag ? ReadCFlag() : shifter_carry)
                    : false;
            const bool writes_pc = rd == 15 && !(data_opcode >= 8 && data_opcode <= 11);
            if (writes_pc) {
                SaveFlagsToCpsr();
            }

            ExecuteDataProcessingSetFlags(data_opcode, ReadDataRegister(*state, rn, op), rd,
                                          operand, effective_shifter_carry);

            result.instructions++;
            if (writes_pc) {
                if (state->CurrentModeHasSPSR()) {
                    state->Cpsr = state->Spsr_copy;
                    state->ChangePrivilegeMode(state->Cpsr & 0x1F);
                }
                LoadFlagsFromCpsr();
                goto block_done;
            }
            AdvancePC(*state, op);
            break;
        }
        case ARMIR::Opcode::ArmDataProcessingImmediateAlways: {

            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool set_flags = ((op.arg1 >> 16) & 1) != 0;
            const u32 operand = op.arg2;
            if (!set_flags) {
                ExecuteDataProcessingNoFlags(data_opcode, ReadDataRegister(*state, rn, op), rd,
                                             operand);
                result.instructions++;
                if (rd == 15) {
                    goto block_done;
                }
                AdvancePC(*state, op);
                break;
            }

            const bool shifter_carry = ((op.arg1 >> 17) & 1) != 0;
            const bool shifter_carry_from_c_flag = ((op.arg1 >> 18) & 1) != 0;
            const bool effective_shifter_carry =
                NeedsShifterCarry(data_opcode, true)
                    ? (shifter_carry_from_c_flag ? ReadCFlag() : shifter_carry)
                    : false;
            const bool writes_pc = rd == 15 && !(data_opcode >= 8 && data_opcode <= 11);
            if (writes_pc) {
                SaveFlagsToCpsr();
            }

            ExecuteDataProcessingSetFlags(data_opcode, ReadDataRegister(*state, rn, op), rd,
                                          operand, effective_shifter_carry);

            result.instructions++;
            if (writes_pc) {
                if (state->CurrentModeHasSPSR()) {
                    state->Cpsr = state->Spsr_copy;
                    state->ChangePrivilegeMode(state->Cpsr & 0x1F);
                }
                LoadFlagsFromCpsr();
                goto block_done;
            }
            AdvancePC(*state, op);
            break;
        }
        case ARMIR::Opcode::ArmDataProcessingRegister: {

            const u32 data_opcode = op.arg0 & 0xF;
            const u32 condition = (op.arg0 >> 8) & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const bool set_flags = ((op.arg1 >> 20) & 1) != 0;
            const u32 shift_type = op.arg2 & 0x3;
            const bool register_shift_amount = ((op.arg2 >> 16) & 1) != 0;
            const u32 shift_imm_or_rs = (op.arg2 >> 8) & (register_shift_amount ? 0xF : 0x1F);
            const bool needs_c_flag =
                NeedsShifterCarry(data_opcode, set_flags) ||
                RegisterShiftOperandNeedsCarry(shift_type, shift_imm_or_rs, register_shift_amount);
            const bool c_flag = needs_c_flag ? ReadCFlag() : false;
            const ShiftedRegister shifted =
                register_shift_amount
                    ? EvaluateRegisterShiftedRegisterOperand(*state, rm, shift_type,
                                                             shift_imm_or_rs, c_flag)
                    : EvaluateShiftedRegisterValue(ReadDataRegister(*state, rm, op), shift_type,
                                                   shift_imm_or_rs, c_flag);

            if (!set_flags) {
                ExecuteDataProcessingNoFlags(data_opcode, ReadDataRegister(*state, rn, op), rd,
                                             shifted.value);
                result.instructions++;
                if (rd == 15) {
                    goto block_done;
                }
            } else {
                const bool writes_pc = rd == 15 && !(data_opcode >= 8 && data_opcode <= 11);
                if (writes_pc) {
                    SaveFlagsToCpsr();
                }
                ExecuteDataProcessingSetFlags(data_opcode, ReadDataRegister(*state, rn, op), rd,
                                              shifted.value, shifted.carry);
                result.instructions++;
                if (writes_pc) {
                    if (state->CurrentModeHasSPSR()) {
                        state->Cpsr = state->Spsr_copy;
                        state->ChangePrivilegeMode(state->Cpsr & 0x1F);
                    }
                    LoadFlagsFromCpsr();
                    goto block_done;
                }
            }

            AdvancePC(*state, op);
            break;
        }
        case ARMIR::Opcode::ArmDataProcessingRegisterAlways: {

            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const bool set_flags = ((op.arg1 >> 20) & 1) != 0;
            const u32 shift_type = op.arg2 & 0x3;
            const bool register_shift_amount = ((op.arg2 >> 16) & 1) != 0;
            const u32 shift_imm_or_rs = (op.arg2 >> 8) & (register_shift_amount ? 0xF : 0x1F);
            const bool needs_c_flag =
                NeedsShifterCarry(data_opcode, set_flags) ||
                RegisterShiftOperandNeedsCarry(shift_type, shift_imm_or_rs, register_shift_amount);
            const bool c_flag = needs_c_flag ? ReadCFlag() : false;
            const ShiftedRegister shifted =
                register_shift_amount
                    ? EvaluateRegisterShiftedRegisterOperand(*state, rm, shift_type,
                                                             shift_imm_or_rs, c_flag)
                    : EvaluateShiftedRegisterValue(ReadDataRegister(*state, rm, op), shift_type,
                                                   shift_imm_or_rs, c_flag);

            if (!set_flags) {
                ExecuteDataProcessingNoFlags(data_opcode, ReadDataRegister(*state, rn, op), rd,
                                             shifted.value);
                result.instructions++;
                if (rd == 15) {
                    goto block_done;
                }
            } else {
                const bool writes_pc = rd == 15 && !(data_opcode >= 8 && data_opcode <= 11);
                if (writes_pc) {
                    SaveFlagsToCpsr();
                }
                ExecuteDataProcessingSetFlags(data_opcode, ReadDataRegister(*state, rn, op), rd,
                                              shifted.value, shifted.carry);
                result.instructions++;
                if (writes_pc) {
                    if (state->CurrentModeHasSPSR()) {
                        state->Cpsr = state->Spsr_copy;
                        state->ChangePrivilegeMode(state->Cpsr & 0x1F);
                    }
                    LoadFlagsFromCpsr();
                    goto block_done;
                }
            }

            AdvancePC(*state, op);
            break;
        }
        case ARMIR::Opcode::ArmLoadWordImmediate: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + op.arg2) : (base - op.arg2);
            state->Reg[rd] = ReadMemory32T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreWordImmediate: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + op.arg2) : (base - op.arg2);
            WriteMemory32T<ProfileOpcodes, BigEndian>(address, state->Reg[rd]);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadWordRegister: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const bool add_offset = ((op.arg1 >> 20) & 1) != 0;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const u32 offset =
                EvaluateAddressOffsetRegisterOperand(*state, rm, shift_type, shift_imm);
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + offset) : (base - offset);
            state->Reg[rd] = ReadMemory32T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreWordRegister: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const bool add_offset = ((op.arg1 >> 20) & 1) != 0;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const u32 offset =
                EvaluateAddressOffsetRegisterOperand(*state, rm, shift_type, shift_imm);
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + offset) : (base - offset);
            WriteMemory32T<ProfileOpcodes, BigEndian>(address, state->Reg[rd]);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadByteImmediate: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + op.arg2) : (base - op.arg2);
            state->Reg[rd] = ReadMemory8T<ProfileOpcodes>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreByteImmediate: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + op.arg2) : (base - op.arg2);
            WriteMemory8T<ProfileOpcodes>(address, static_cast<u8>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadWordImmediateNoPc: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 address = add_offset ? (state->Reg[rn] + op.arg2)
                                           : (state->Reg[rn] - op.arg2);
            state->Reg[rd] = ReadMemory32T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreWordImmediateNoPc: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 address = add_offset ? (state->Reg[rn] + op.arg2)
                                           : (state->Reg[rn] - op.arg2);
            WriteMemory32T<ProfileOpcodes, BigEndian>(address, state->Reg[rd]);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadWordImmediateNoPcAdd: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn] + op.arg2;
            state->Reg[rd] = ReadMemory32T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadWordImmediateNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn] - op.arg2;
            state->Reg[rd] = ReadMemory32T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreWordImmediateNoPcAdd: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn] + op.arg2;
            WriteMemory32T<ProfileOpcodes, BigEndian>(address, state->Reg[rd]);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreWordImmediateNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn] - op.arg2;
            WriteMemory32T<ProfileOpcodes, BigEndian>(address, state->Reg[rd]);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadByteImmediateNoPc: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 address = add_offset ? (state->Reg[rn] + op.arg2)
                                           : (state->Reg[rn] - op.arg2);
            state->Reg[rd] = ReadMemory8T<ProfileOpcodes>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreByteImmediateNoPc: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 address = add_offset ? (state->Reg[rn] + op.arg2)
                                           : (state->Reg[rn] - op.arg2);
            WriteMemory8T<ProfileOpcodes>(address, static_cast<u8>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadByteImmediateNoPcAdd: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn] + op.arg2;
            state->Reg[rd] = ReadMemory8T<ProfileOpcodes>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadByteImmediateNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn] - op.arg2;
            state->Reg[rd] = ReadMemory8T<ProfileOpcodes>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreByteImmediateNoPcAdd: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn] + op.arg2;
            WriteMemory8T<ProfileOpcodes>(address, static_cast<u8>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreByteImmediateNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn] - op.arg2;
            WriteMemory8T<ProfileOpcodes>(address, static_cast<u8>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadWordImmediateNoPcOffset0: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn];
            state->Reg[rd] = ReadMemory32T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreWordImmediateNoPcOffset0: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn];
            WriteMemory32T<ProfileOpcodes, BigEndian>(address, state->Reg[rd]);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadByteImmediateNoPcOffset0: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn];
            state->Reg[rd] = ReadMemory8T<ProfileOpcodes>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreByteImmediateNoPcOffset0: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn];
            WriteMemory8T<ProfileOpcodes>(address, static_cast<u8>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadWordRegisterNoPc: {
            DispatchLoadStoreRegisterByShiftType<ProfileOpcodes, BigEndian, true, false, false>(
                op, result);
            break;
        }
        case ARMIR::Opcode::ArmStoreWordRegisterNoPc: {
            DispatchLoadStoreRegisterByShiftType<ProfileOpcodes, BigEndian, false, false, false>(
                op, result);
            break;
        }
        case ARMIR::Opcode::ArmLoadByteRegisterNoPc: {
            DispatchLoadStoreRegisterByShiftType<ProfileOpcodes, BigEndian, true, true, false>(
                op, result);
            break;
        }
        case ARMIR::Opcode::ArmStoreByteRegisterNoPc: {
            DispatchLoadStoreRegisterByShiftType<ProfileOpcodes, BigEndian, false, true, false>(
                op, result);
            break;
        }
        case ARMIR::Opcode::ArmLoadWordRegisterNoPcAdd: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 address = state->Reg[rn] + state->Reg[rm];
            state->Reg[rd] = ReadMemory32T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadWordRegisterNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 address = state->Reg[rn] - state->Reg[rm];
            state->Reg[rd] = ReadMemory32T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreWordRegisterNoPcAdd: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 address = state->Reg[rn] + state->Reg[rm];
            WriteMemory32T<ProfileOpcodes, BigEndian>(address, state->Reg[rd]);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreWordRegisterNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 address = state->Reg[rn] - state->Reg[rm];
            WriteMemory32T<ProfileOpcodes, BigEndian>(address, state->Reg[rd]);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadByteRegisterNoPcAdd: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 address = state->Reg[rn] + state->Reg[rm];
            state->Reg[rd] = ReadMemory8T<ProfileOpcodes>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadByteRegisterNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 address = state->Reg[rn] - state->Reg[rm];
            state->Reg[rd] = ReadMemory8T<ProfileOpcodes>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreByteRegisterNoPcAdd: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 address = state->Reg[rn] + state->Reg[rm];
            WriteMemory8T<ProfileOpcodes>(address, static_cast<u8>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreByteRegisterNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 address = state->Reg[rn] - state->Reg[rm];
            WriteMemory8T<ProfileOpcodes>(address, static_cast<u8>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadWordImmediateWriteback: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 17) & 1) != 0;
            const u32 base = state->Reg[rn];
            const u32 writeback_value = add_offset ? (base + op.arg2) : (base - op.arg2);
            const u32 address = pre_indexed ? writeback_value : base;
            state->Reg[rd] = ReadMemory32T<ProfileOpcodes, BigEndian>(address);
            state->Reg[rn] = writeback_value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreWordImmediateWriteback: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 17) & 1) != 0;
            const u32 base = state->Reg[rn];
            const u32 writeback_value = add_offset ? (base + op.arg2) : (base - op.arg2);
            const u32 address = pre_indexed ? writeback_value : base;
            WriteMemory32T<ProfileOpcodes, BigEndian>(address, state->Reg[rd]);
            state->Reg[rn] = writeback_value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadByteImmediateWriteback: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 17) & 1) != 0;
            const u32 base = state->Reg[rn];
            const u32 writeback_value = add_offset ? (base + op.arg2) : (base - op.arg2);
            const u32 address = pre_indexed ? writeback_value : base;
            state->Reg[rd] = ReadMemory8T<ProfileOpcodes>(address);
            state->Reg[rn] = writeback_value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreByteImmediateWriteback: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 17) & 1) != 0;
            const u32 base = state->Reg[rn];
            const u32 writeback_value = add_offset ? (base + op.arg2) : (base - op.arg2);
            const u32 address = pre_indexed ? writeback_value : base;
            WriteMemory8T<ProfileOpcodes>(address, static_cast<u8>(state->Reg[rd]));
            state->Reg[rn] = writeback_value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadByteRegister: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const bool add_offset = ((op.arg1 >> 20) & 1) != 0;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const u32 offset =
                EvaluateAddressOffsetRegisterOperand(*state, rm, shift_type, shift_imm);
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + offset) : (base - offset);
            state->Reg[rd] = ReadMemory8T<ProfileOpcodes>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreByteRegister: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const bool add_offset = ((op.arg1 >> 20) & 1) != 0;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const u32 offset =
                EvaluateAddressOffsetRegisterOperand(*state, rm, shift_type, shift_imm);
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + offset) : (base - offset);
            WriteMemory8T<ProfileOpcodes>(address, static_cast<u8>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadWordRegisterWriteback: {
            DispatchLoadStoreRegisterByShiftType<ProfileOpcodes, BigEndian, true, false, true>(
                op, result);
            break;
        }
        case ARMIR::Opcode::ArmStoreWordRegisterWriteback: {
            DispatchLoadStoreRegisterByShiftType<ProfileOpcodes, BigEndian, false, false, true>(
                op, result);
            break;
        }
        case ARMIR::Opcode::ArmLoadByteRegisterWriteback: {
            DispatchLoadStoreRegisterByShiftType<ProfileOpcodes, BigEndian, true, true, true>(
                op, result);
            break;
        }
        case ARMIR::Opcode::ArmStoreByteRegisterWriteback: {
            DispatchLoadStoreRegisterByShiftType<ProfileOpcodes, BigEndian, false, true, true>(
                op, result);
            break;
        }
        case ARMIR::Opcode::ArmLoadStoreImmediate: {

            const u32 condition = (op.arg0 >> 8) & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool load = (op.arg0 & 1) != 0;
            const bool byte_transfer = (op.arg0 & 2) != 0;
            const bool unprivileged = ((op.arg0 >> 2) & 1) != 0;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool loads_pc = load && !byte_transfer && rd == 15;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 17) & 1) != 0;
            const bool writes_back = ((op.arg1 >> 18) & 1) != 0;
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 writeback_value = add_offset ? (base + op.arg2) : (base - op.arg2);
            const u32 address = pre_indexed ? writeback_value : base;
            const u32 store_value = writes_back && rd == rn ? writeback_value : state->Reg[rd];

            if (load) {
                u32 value = 0;
                if (unprivileged) {
                    CountFastmemFallbackT<ProfileOpcodes>();
                    const u32 previous_mode = state->Mode;
                    state->ChangePrivilegeMode(USER32MODE);
                    value = byte_transfer ? state->ReadMemory8(address)
                                          : state->ReadMemory32(address);
                    state->ChangePrivilegeMode(previous_mode);
                } else {
                    value = byte_transfer ? ReadMemory8T<ProfileOpcodes>(address)
                                          : ReadMemory32T<ProfileOpcodes, BigEndian>(address);
                }
                if (loads_pc) {
                    IR_TRACE_TFLAG(value & 1, 8);
                    value &= 0xFFFFFFFE;
                }
                state->Reg[rd] = value;
            } else if (byte_transfer) {
                if (unprivileged) {
                    const u8 value = static_cast<u8>(store_value);
                    CountFastmemFallbackT<ProfileOpcodes>();
                    const u32 previous_mode = state->Mode;
                    state->ChangePrivilegeMode(USER32MODE);
                    state->WriteMemory8(address, value);
                    state->ChangePrivilegeMode(previous_mode);
                } else {
                    WriteMemory8T<ProfileOpcodes>(address, static_cast<u8>(store_value));
                }
            } else {
                if (unprivileged) {
                    const u32 value = store_value;
                    CountFastmemFallbackT<ProfileOpcodes>();
                    const u32 previous_mode = state->Mode;
                    state->ChangePrivilegeMode(USER32MODE);
                    state->WriteMemory32(address, value);
                    state->ChangePrivilegeMode(previous_mode);
                } else {
                    WriteMemory32T<ProfileOpcodes, BigEndian>(address, store_value);
                }
            }
            if (writes_back && (!load || rd != rn)) {
                state->Reg[rn] = writeback_value;
            }
            result.instructions++;
            if (loads_pc) {
                goto block_done;
            }
            AdvancePC(*state, op);
            break;
        }
        case ARMIR::Opcode::ArmLoadStoreRegister: {

            const u32 condition = (op.arg0 >> 8) & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool load = (op.arg0 & 1) != 0;
            const bool byte_transfer = (op.arg0 & 2) != 0;
            const bool unprivileged = ((op.arg0 >> 2) & 1) != 0;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const bool loads_pc = load && !byte_transfer && rd == 15;
            const bool add_offset = ((op.arg1 >> 20) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 21) & 1) != 0;
            const bool writes_back = ((op.arg1 >> 22) & 1) != 0;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const bool c_flag =
                RegisterShiftOperandNeedsCarry(shift_type, shift_imm, false) ? ReadCFlag()
                                                                             : false;
            const u32 offset =
                EvaluateShiftedRegisterValue(ReadDataRegister(*state, rm, op), shift_type,
                                             shift_imm, c_flag)
                    .value;
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 writeback_value = add_offset ? (base + offset) : (base - offset);
            const u32 address = pre_indexed ? writeback_value : base;
            const u32 store_value = writes_back && rd == rn ? writeback_value : state->Reg[rd];

            if (load) {
                u32 value = 0;
                if (unprivileged) {
                    CountFastmemFallbackT<ProfileOpcodes>();
                    const u32 previous_mode = state->Mode;
                    state->ChangePrivilegeMode(USER32MODE);
                    value = byte_transfer ? state->ReadMemory8(address)
                                          : state->ReadMemory32(address);
                    state->ChangePrivilegeMode(previous_mode);
                } else {
                    value = byte_transfer ? ReadMemory8T<ProfileOpcodes>(address)
                                          : ReadMemory32T<ProfileOpcodes, BigEndian>(address);
                }
                if (loads_pc) {
                    IR_TRACE_TFLAG(value & 1, 9);
                    value &= 0xFFFFFFFE;
                }
                state->Reg[rd] = value;
            } else if (byte_transfer) {
                if (unprivileged) {
                    const u8 value = static_cast<u8>(store_value);
                    CountFastmemFallbackT<ProfileOpcodes>();
                    const u32 previous_mode = state->Mode;
                    state->ChangePrivilegeMode(USER32MODE);
                    state->WriteMemory8(address, value);
                    state->ChangePrivilegeMode(previous_mode);
                } else {
                    WriteMemory8T<ProfileOpcodes>(address, static_cast<u8>(store_value));
                }
            } else {
                if (unprivileged) {
                    const u32 value = store_value;
                    CountFastmemFallbackT<ProfileOpcodes>();
                    const u32 previous_mode = state->Mode;
                    state->ChangePrivilegeMode(USER32MODE);
                    state->WriteMemory32(address, value);
                    state->ChangePrivilegeMode(previous_mode);
                } else {
                    WriteMemory32T<ProfileOpcodes, BigEndian>(address, store_value);
                }
            }
            if (writes_back && (!load || rd != rn)) {
                state->Reg[rn] = writeback_value;
            }
            result.instructions++;
            if (loads_pc) {
                goto block_done;
            }
            AdvancePC(*state, op);
            break;
        }
        case ARMIR::Opcode::ArmLoadHalfwordImmediate: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + op.arg2) : (base - op.arg2);
            state->Reg[rd] = ReadMemory16T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreHalfwordImmediate: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + op.arg2) : (base - op.arg2);
            WriteMemory16T<ProfileOpcodes, BigEndian>(address, static_cast<u16>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedByteImmediate: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + op.arg2) : (base - op.arg2);
            state->Reg[rd] = SignExtend8(ReadMemory8T<ProfileOpcodes>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedHalfwordImmediate: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + op.arg2) : (base - op.arg2);
            state->Reg[rd] =
                SignExtend16(ReadMemory16T<ProfileOpcodes, BigEndian>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadHalfwordRegister: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 offset = state->Reg[op.arg2 & 0xF];
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + offset) : (base - offset);
            state->Reg[rd] = ReadMemory16T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreHalfwordRegister: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 offset = state->Reg[op.arg2 & 0xF];
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + offset) : (base - offset);
            WriteMemory16T<ProfileOpcodes, BigEndian>(address, static_cast<u16>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedByteRegister: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 offset = state->Reg[op.arg2 & 0xF];
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + offset) : (base - offset);
            state->Reg[rd] = SignExtend8(ReadMemory8T<ProfileOpcodes>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedHalfwordRegister: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 offset = state->Reg[op.arg2 & 0xF];
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + offset) : (base - offset);
            state->Reg[rd] =
                SignExtend16(ReadMemory16T<ProfileOpcodes, BigEndian>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadHalfwordImmediateNoPc: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 address = add_offset ? (state->Reg[rn] + op.arg2)
                                           : (state->Reg[rn] - op.arg2);
            state->Reg[rd] = ReadMemory16T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreHalfwordImmediateNoPc: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 address = add_offset ? (state->Reg[rn] + op.arg2)
                                           : (state->Reg[rn] - op.arg2);
            WriteMemory16T<ProfileOpcodes, BigEndian>(address, static_cast<u16>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadHalfwordImmediateNoPcAdd: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn] + op.arg2;
            state->Reg[rd] = ReadMemory16T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadHalfwordImmediateNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn] - op.arg2;
            state->Reg[rd] = ReadMemory16T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreHalfwordImmediateNoPcAdd: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn] + op.arg2;
            WriteMemory16T<ProfileOpcodes, BigEndian>(address, static_cast<u16>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreHalfwordImmediateNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn] - op.arg2;
            WriteMemory16T<ProfileOpcodes, BigEndian>(address, static_cast<u16>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedByteImmediateNoPc: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 address = add_offset ? (state->Reg[rn] + op.arg2)
                                           : (state->Reg[rn] - op.arg2);
            state->Reg[rd] = SignExtend8(ReadMemory8T<ProfileOpcodes>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedHalfwordImmediateNoPc: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 address = add_offset ? (state->Reg[rn] + op.arg2)
                                           : (state->Reg[rn] - op.arg2);
            state->Reg[rd] =
                SignExtend16(ReadMemory16T<ProfileOpcodes, BigEndian>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedByteImmediateNoPcAdd: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn] + op.arg2;
            state->Reg[rd] = SignExtend8(ReadMemory8T<ProfileOpcodes>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedByteImmediateNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn] - op.arg2;
            state->Reg[rd] = SignExtend8(ReadMemory8T<ProfileOpcodes>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedHalfwordImmediateNoPcAdd: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn] + op.arg2;
            state->Reg[rd] =
                SignExtend16(ReadMemory16T<ProfileOpcodes, BigEndian>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedHalfwordImmediateNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn] - op.arg2;
            state->Reg[rd] =
                SignExtend16(ReadMemory16T<ProfileOpcodes, BigEndian>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadHalfwordImmediateNoPcOffset0: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn];
            state->Reg[rd] = ReadMemory16T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreHalfwordImmediateNoPcOffset0: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn];
            WriteMemory16T<ProfileOpcodes, BigEndian>(address, static_cast<u16>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedByteImmediateNoPcOffset0: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn];
            state->Reg[rd] = SignExtend8(ReadMemory8T<ProfileOpcodes>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedHalfwordImmediateNoPcOffset0: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn];
            state->Reg[rd] =
                SignExtend16(ReadMemory16T<ProfileOpcodes, BigEndian>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadHalfwordRegisterNoPc: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 offset = state->Reg[op.arg2 & 0xF];
            const u32 address = add_offset ? (state->Reg[rn] + offset)
                                           : (state->Reg[rn] - offset);
            state->Reg[rd] = ReadMemory16T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreHalfwordRegisterNoPc: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 offset = state->Reg[op.arg2 & 0xF];
            const u32 address = add_offset ? (state->Reg[rn] + offset)
                                           : (state->Reg[rn] - offset);
            WriteMemory16T<ProfileOpcodes, BigEndian>(address, static_cast<u16>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedByteRegisterNoPc: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 offset = state->Reg[op.arg2 & 0xF];
            const u32 address = add_offset ? (state->Reg[rn] + offset)
                                           : (state->Reg[rn] - offset);
            state->Reg[rd] = SignExtend8(ReadMemory8T<ProfileOpcodes>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedHalfwordRegisterNoPc: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const u32 offset = state->Reg[op.arg2 & 0xF];
            const u32 address = add_offset ? (state->Reg[rn] + offset)
                                           : (state->Reg[rn] - offset);
            state->Reg[rd] =
                SignExtend16(ReadMemory16T<ProfileOpcodes, BigEndian>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadHalfwordRegisterNoPcAdd: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = op.arg2 & 0xF;
            const u32 address = state->Reg[rn] + state->Reg[rm];
            state->Reg[rd] = ReadMemory16T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadHalfwordRegisterNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = op.arg2 & 0xF;
            const u32 address = state->Reg[rn] - state->Reg[rm];
            state->Reg[rd] = ReadMemory16T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreHalfwordRegisterNoPcAdd: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = op.arg2 & 0xF;
            const u32 address = state->Reg[rn] + state->Reg[rm];
            WriteMemory16T<ProfileOpcodes, BigEndian>(address, static_cast<u16>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreHalfwordRegisterNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = op.arg2 & 0xF;
            const u32 address = state->Reg[rn] - state->Reg[rm];
            WriteMemory16T<ProfileOpcodes, BigEndian>(address, static_cast<u16>(state->Reg[rd]));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedByteRegisterNoPcAdd: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = op.arg2 & 0xF;
            const u32 address = state->Reg[rn] + state->Reg[rm];
            state->Reg[rd] = SignExtend8(ReadMemory8T<ProfileOpcodes>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedByteRegisterNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = op.arg2 & 0xF;
            const u32 address = state->Reg[rn] - state->Reg[rm];
            state->Reg[rd] = SignExtend8(ReadMemory8T<ProfileOpcodes>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedHalfwordRegisterNoPcAdd: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = op.arg2 & 0xF;
            const u32 address = state->Reg[rn] + state->Reg[rm];
            state->Reg[rd] =
                SignExtend16(ReadMemory16T<ProfileOpcodes, BigEndian>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedHalfwordRegisterNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = op.arg2 & 0xF;
            const u32 address = state->Reg[rn] - state->Reg[rm];
            state->Reg[rd] =
                SignExtend16(ReadMemory16T<ProfileOpcodes, BigEndian>(address));

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadHalfwordImmediateWriteback: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 17) & 1) != 0;
            const u32 base = state->Reg[rn];
            const u32 writeback_value = add_offset ? (base + op.arg2) : (base - op.arg2);
            const u32 address = pre_indexed ? writeback_value : base;
            state->Reg[rd] = ReadMemory16T<ProfileOpcodes, BigEndian>(address);
            state->Reg[rn] = writeback_value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreHalfwordImmediateWriteback: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 17) & 1) != 0;
            const u32 base = state->Reg[rn];
            const u32 writeback_value = add_offset ? (base + op.arg2) : (base - op.arg2);
            const u32 address = pre_indexed ? writeback_value : base;
            WriteMemory16T<ProfileOpcodes, BigEndian>(address, static_cast<u16>(state->Reg[rd]));
            state->Reg[rn] = writeback_value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedByteImmediateWriteback: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 17) & 1) != 0;
            const u32 base = state->Reg[rn];
            const u32 writeback_value = add_offset ? (base + op.arg2) : (base - op.arg2);
            const u32 address = pre_indexed ? writeback_value : base;
            state->Reg[rd] = SignExtend8(ReadMemory8T<ProfileOpcodes>(address));
            state->Reg[rn] = writeback_value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedHalfwordImmediateWriteback: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 17) & 1) != 0;
            const u32 base = state->Reg[rn];
            const u32 writeback_value = add_offset ? (base + op.arg2) : (base - op.arg2);
            const u32 address = pre_indexed ? writeback_value : base;
            state->Reg[rd] =
                SignExtend16(ReadMemory16T<ProfileOpcodes, BigEndian>(address));
            state->Reg[rn] = writeback_value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadHalfwordRegisterWriteback: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 17) & 1) != 0;
            const u32 offset = state->Reg[op.arg2 & 0xF];
            const u32 base = state->Reg[rn];
            const u32 writeback_value = add_offset ? (base + offset) : (base - offset);
            const u32 address = pre_indexed ? writeback_value : base;
            state->Reg[rd] = ReadMemory16T<ProfileOpcodes, BigEndian>(address);
            state->Reg[rn] = writeback_value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreHalfwordRegisterWriteback: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 17) & 1) != 0;
            const u32 offset = state->Reg[op.arg2 & 0xF];
            const u32 base = state->Reg[rn];
            const u32 writeback_value = add_offset ? (base + offset) : (base - offset);
            const u32 address = pre_indexed ? writeback_value : base;
            WriteMemory16T<ProfileOpcodes, BigEndian>(address, static_cast<u16>(state->Reg[rd]));
            state->Reg[rn] = writeback_value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedByteRegisterWriteback: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 17) & 1) != 0;
            const u32 offset = state->Reg[op.arg2 & 0xF];
            const u32 base = state->Reg[rn];
            const u32 writeback_value = add_offset ? (base + offset) : (base - offset);
            const u32 address = pre_indexed ? writeback_value : base;
            state->Reg[rd] = SignExtend8(ReadMemory8T<ProfileOpcodes>(address));
            state->Reg[rn] = writeback_value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadSignedHalfwordRegisterWriteback: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 17) & 1) != 0;
            const u32 offset = state->Reg[op.arg2 & 0xF];
            const u32 base = state->Reg[rn];
            const u32 writeback_value = add_offset ? (base + offset) : (base - offset);
            const u32 address = pre_indexed ? writeback_value : base;
            state->Reg[rd] =
                SignExtend16(ReadMemory16T<ProfileOpcodes, BigEndian>(address));
            state->Reg[rn] = writeback_value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadStoreHalfword: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool load = ((op.arg0 >> 8) & 1) != 0;
            const u32 transfer_type = (op.arg0 >> 9) & 0x3;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool immediate_offset = ((op.arg1 >> 17) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 18) & 1) != 0;
            const bool writes_back = ((op.arg1 >> 19) & 1) != 0;
            const u32 offset = immediate_offset ? op.arg2 : state->Reg[op.arg2 & 0xF];
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 writeback_value = add_offset ? (base + offset) : (base - offset);
            const u32 address = pre_indexed ? writeback_value : base;
            const u32 store_value = writes_back && rd == rn ? writeback_value : state->Reg[rd];

            switch (transfer_type) {
            case 1: // LDRH / STRH
                if (load) {
                    state->Reg[rd] = ReadMemory16T<ProfileOpcodes, BigEndian>(address);
                } else {
                    WriteMemory16T<ProfileOpcodes, BigEndian>(address,
                                                              static_cast<u16>(store_value));
                }
                break;
            case 2: { // LDRSB
                state->Reg[rd] = SignExtend8(ReadMemory8T<ProfileOpcodes>(address));
                break;
            }
            case 3: { // LDRSH
                state->Reg[rd] = SignExtend16(ReadMemory16T<ProfileOpcodes, BigEndian>(address));
                break;
            }
            default:
                result.needs_fallback = true;
                goto block_done;
            }

            if (writes_back && (!load || rd != rn)) {
                state->Reg[rn] = writeback_value;
            }
            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadStoreDouble: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool load = ((op.arg0 >> 8) & 1) != 0;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool immediate_offset = ((op.arg1 >> 17) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 18) & 1) != 0;
            const bool writes_back = ((op.arg1 >> 19) & 1) != 0;
            const u32 offset = immediate_offset ? op.arg2 : state->Reg[op.arg2 & 0xF];
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 writeback_value = add_offset ? (base + offset) : (base - offset);
            const u32 address = pre_indexed ? writeback_value : base;
            const u32 low_store_value =
                writes_back && rn == rd ? writeback_value : state->Reg[rd];
            const u32 high_store_value =
                writes_back && rn == rd + 1 ? writeback_value : state->Reg[rd + 1];

            if constexpr (!BigEndian) {
                if (u8* page_pointer = GetFastMemoryPointerForSpanT<ProfileOpcodes>(address, 8)) {
                    CountFastmemHitT<ProfileOpcodes>(2);
                    if (load) {
                        state->Reg[rd] =
                            ReadUnaligned<u32>(&page_pointer[address & Memory::CITRA_PAGE_MASK]);
                        state->Reg[rd + 1] = ReadUnaligned<u32>(
                            &page_pointer[(address + 4) & Memory::CITRA_PAGE_MASK]);
                    } else {
                        WriteUnaligned(&page_pointer[address & Memory::CITRA_PAGE_MASK],
                                       low_store_value);
                        WriteUnaligned(&page_pointer[(address + 4) & Memory::CITRA_PAGE_MASK],
                                       high_store_value);
                    }
                    if (writes_back && (!load || (rn != rd && rn != rd + 1))) {
                        state->Reg[rn] = writeback_value;
                    }

                    AdvancePC(*state, op);
                    result.instructions++;
                    break;
                }
            }

            if (load) {
                state->Reg[rd] = ReadMemory32T<ProfileOpcodes, BigEndian>(address);
                state->Reg[rd + 1] = ReadMemory32T<ProfileOpcodes, BigEndian>(address + 4);
            } else {
                WriteMemory32T<ProfileOpcodes, BigEndian>(address, low_store_value);
                WriteMemory32T<ProfileOpcodes, BigEndian>(address + 4, high_store_value);
            }
            if (writes_back && (!load || (rn != rd && rn != rd + 1))) {
                state->Reg[rn] = writeback_value;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadDoubleFast: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool immediate_offset = ((op.arg1 >> 17) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 18) & 1) != 0;
            const bool writes_back = ((op.arg1 >> 19) & 1) != 0;
            const u32 offset = immediate_offset ? op.arg2 : state->Reg[op.arg2 & 0xF];
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 writeback_value = add_offset ? (base + offset) : (base - offset);
            const u32 address = pre_indexed ? writeback_value : base;

            if constexpr (!BigEndian) {
                if (const u8* page_pointer =
                        GetFastMemoryPointerForSpanT<ProfileOpcodes>(address, 8)) {
                    const u32 fast_offset = address & Memory::CITRA_PAGE_MASK;
                    CountFastmemHitT<ProfileOpcodes>(2);
                    state->Reg[rd] = ReadUnaligned<u32>(&page_pointer[fast_offset]);
                    state->Reg[rd + 1] = ReadUnaligned<u32>(&page_pointer[fast_offset + 4]);
                    if (writes_back) {
                        state->Reg[rn] = writeback_value;
                    }

                    AdvancePC(*state, op);
                    result.instructions++;
                    break;
                }
            }

            state->Reg[rd] = ReadMemory32T<ProfileOpcodes, BigEndian>(address);
            state->Reg[rd + 1] = ReadMemory32T<ProfileOpcodes, BigEndian>(address + 4);
            if (writes_back) {
                state->Reg[rn] = writeback_value;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreDoubleFast: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool immediate_offset = ((op.arg1 >> 17) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 18) & 1) != 0;
            const bool writes_back = ((op.arg1 >> 19) & 1) != 0;
            const u32 offset = immediate_offset ? op.arg2 : state->Reg[op.arg2 & 0xF];
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 writeback_value = add_offset ? (base + offset) : (base - offset);
            const u32 address = pre_indexed ? writeback_value : base;

            if constexpr (!BigEndian) {
                if (u8* page_pointer = GetFastMemoryPointerForSpanT<ProfileOpcodes>(address, 8)) {
                    const u32 fast_offset = address & Memory::CITRA_PAGE_MASK;
                    CountFastmemHitT<ProfileOpcodes>(2);
                    WriteUnaligned(&page_pointer[fast_offset], state->Reg[rd]);
                    WriteUnaligned(&page_pointer[fast_offset + 4], state->Reg[rd + 1]);
                    if (writes_back) {
                        state->Reg[rn] = writeback_value;
                    }

                    AdvancePC(*state, op);
                    result.instructions++;
                    break;
                }
            }

            WriteMemory32T<ProfileOpcodes, BigEndian>(address, state->Reg[rd]);
            WriteMemory32T<ProfileOpcodes, BigEndian>(address + 4, state->Reg[rd + 1]);
            if (writes_back) {
                state->Reg[rn] = writeback_value;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadStoreMultiple: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool load = ((op.arg0 >> 8) & 1) != 0;
            const bool writeback = ((op.arg0 >> 9) & 1) != 0;
            const bool add_offset = ((op.arg0 >> 10) & 1) != 0;
            const bool pre_indexed = ((op.arg0 >> 11) & 1) != 0;
            const bool user_mode_registers = ((op.arg0 >> 12) & 1) != 0;
            const u32 rn = op.arg1 & 0xF;
            const u32 register_list = (op.arg1 >> 8) & 0xFFFF;
            const bool loads_pc = load && ((register_list >> 15) & 1) != 0;
            const bool restore_spsr = loads_pc && user_mode_registers;
            const u32 transfer_bytes = op.arg2 * 4;
            const u32 old_base = state->Reg[rn];
            u32 address = 0;
            if (add_offset) {
                address = pre_indexed ? old_base + 4 : old_base;
            } else {
                address = pre_indexed ? old_base - transfer_bytes : old_base - transfer_bytes + 4;
            }

            if (writeback) {
                state->Reg[rn] = add_offset ? old_base + transfer_bytes : old_base - transfer_bytes;
            }

            if (op.arg2 == 1) {
                const u32 reg = static_cast<u32>(std::countr_zero(register_list));
                if (load) {
                    u32 value = ReadMemory32T<ProfileOpcodes, BigEndian>(address);
                    if (restore_spsr && reg == 15) {
                        if (state->CurrentModeHasSPSR()) {
                            state->Cpsr = state->Spsr_copy;
                            state->ChangePrivilegeMode(state->Cpsr & 0x1F);
                            LoadFlagsFromCpsr();
                        }
                        state->Reg[15] = value;
                    } else if (reg == 15) {
                        IR_TRACE_TFLAG(value & 1, 10);
                        value &= 0xFFFFFFFE;
                        state->Reg[15] = value;
                    } else if (!restore_spsr && user_mode_registers &&
                               state->Mode != USER32MODE && (reg == 13 || reg == 14)) {
                        state->Reg_usr[reg - 13] = value;
                    } else {
                        state->Reg[reg] = value;
                    }
                } else {
                    u32 value = 0;
                    if (user_mode_registers && state->Mode != USER32MODE &&
                        (reg == 13 || reg == 14)) {
                        value = state->Reg_usr[reg - 13];
                    } else if (reg == 15) {
                        value = state->Reg[15] + 8;
                    } else {
                        value = (!user_mode_registers && writeback && reg == rn) ? old_base
                                                                                 : state->Reg[reg];
                    }
                    WriteMemory32T<ProfileOpcodes, BigEndian>(address, value);
                }

                result.instructions++;
                if (loads_pc) {
                    goto block_done;
                }
                AdvancePC(*state, op);
                break;
            }

            if constexpr (!BigEndian) {
                if (u8* page_pointer =
                        GetFastMemoryPointerForSpanT<ProfileOpcodes>(address, transfer_bytes)) {
                    u32 fast_offset = address & Memory::CITRA_PAGE_MASK;
                    CountFastmemHitT<ProfileOpcodes>(op.arg2);
                    u32 remaining_registers = register_list;
                    while (remaining_registers != 0) {
                        const u32 reg = PopLowestRegister(remaining_registers);
                        if (load) {
                            u32 value = ReadUnaligned<u32>(&page_pointer[fast_offset]);
                            if (restore_spsr && reg == 15) {
                                if (state->CurrentModeHasSPSR()) {
                                    state->Cpsr = state->Spsr_copy;
                                    state->ChangePrivilegeMode(state->Cpsr & 0x1F);
                                    LoadFlagsFromCpsr();
                                }
                                state->Reg[15] = value;
                            } else if (reg == 15) {
                                IR_TRACE_TFLAG(value & 1, 11);
                                value &= 0xFFFFFFFE;
                                state->Reg[15] = value;
                            } else if (!restore_spsr && user_mode_registers &&
                                       state->Mode != USER32MODE && (reg == 13 || reg == 14)) {
                                state->Reg_usr[reg - 13] = value;
                            } else {
                                state->Reg[reg] = value;
                            }
                        } else {
                            u32 value = 0;
                            if (user_mode_registers && state->Mode != USER32MODE &&
                                (reg == 13 || reg == 14)) {
                                value = state->Reg_usr[reg - 13];
                            } else if (reg == 15) {
                                value = state->Reg[15] + 8;
                            } else {
                                value = (!user_mode_registers && writeback && reg == rn)
                                            ? old_base
                                            : state->Reg[reg];
                            }
                            WriteUnaligned(&page_pointer[fast_offset], value);
                        }
                        fast_offset += 4;
                    }

                    result.instructions++;
                    if (loads_pc) {
                        goto block_done;
                    }
                    AdvancePC(*state, op);
                    break;
                }
            }

            u32 remaining_registers = register_list;
            while (remaining_registers != 0) {
                const u32 reg = PopLowestRegister(remaining_registers);
                if (load) {
                    u32 value = ReadMemory32T<ProfileOpcodes, BigEndian>(address);
                    if (restore_spsr && reg == 15) {
                        if (state->CurrentModeHasSPSR()) {
                            state->Cpsr = state->Spsr_copy;
                            state->ChangePrivilegeMode(state->Cpsr & 0x1F);
                            LoadFlagsFromCpsr();
                        }
                        state->Reg[15] = value;
                    } else if (reg == 15) {
                        IR_TRACE_TFLAG(value & 1, 12);
                        value &= 0xFFFFFFFE;
                        state->Reg[15] = value;
                    } else if (!restore_spsr && user_mode_registers &&
                               state->Mode != USER32MODE && (reg == 13 || reg == 14)) {
                        state->Reg_usr[reg - 13] = value;
                    } else {
                        state->Reg[reg] = value;
                    }
                } else {
                    u32 value = 0;
                    if (user_mode_registers && state->Mode != USER32MODE &&
                        (reg == 13 || reg == 14)) {
                        value = state->Reg_usr[reg - 13];
                    } else if (reg == 15) {
                        value = state->Reg[15] + 8;
                    } else {
                        value = (!user_mode_registers && writeback && reg == rn) ? old_base
                                                                                 : state->Reg[reg];
                    }
                    WriteMemory32T<ProfileOpcodes, BigEndian>(address, value);
                }
                address += 4;
            }

            result.instructions++;
            if (loads_pc) {
                goto block_done;
            }
            AdvancePC(*state, op);
            break;
        }
        case ARMIR::Opcode::ArmLoadMultipleFast: {
            const bool writeback = (op.arg0 & 1) != 0;
            const bool add_offset = ((op.arg0 >> 1) & 1) != 0;
            const bool pre_indexed = ((op.arg0 >> 2) & 1) != 0;
            const u32 rn = op.arg1 & 0xF;
            const u32 register_list = (op.arg1 >> 8) & 0xFFFF;
            const u32 transfer_bytes = op.arg2 * 4;
            const u32 old_base = state->Reg[rn];
            u32 address = 0;
            if (add_offset) {
                address = pre_indexed ? old_base + 4 : old_base;
            } else {
                address = pre_indexed ? old_base - transfer_bytes : old_base - transfer_bytes + 4;
            }

            if (writeback) {
                state->Reg[rn] = add_offset ? old_base + transfer_bytes : old_base - transfer_bytes;
            }

            if (op.arg2 == 1) {
                const u32 reg = static_cast<u32>(std::countr_zero(register_list & 0x7FFF));
                state->Reg[reg] = ReadMemory32T<ProfileOpcodes, BigEndian>(address);

                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            if constexpr (!BigEndian) {
                if (u8* page_pointer =
                        GetFastMemoryPointerForSpanT<ProfileOpcodes>(address, transfer_bytes)) {
                    u32 fast_offset = address & Memory::CITRA_PAGE_MASK;
                    CountFastmemHitT<ProfileOpcodes>(op.arg2);
                    u32 remaining_registers = register_list & 0x7FFF;
                    while (remaining_registers != 0) {
                        u32 first_register = 0;
                        const u32 register_count =
                            PopLowestRegisterRun(remaining_registers, first_register);
                        LoadRegisterRun(*state, first_register, register_count,
                                        &page_pointer[fast_offset]);
                        fast_offset += register_count * sizeof(u32);
                    }

                    AdvancePC(*state, op);
                    result.instructions++;
                    break;
                }
            }

            u32 remaining_registers = register_list & 0x7FFF;
            while (remaining_registers != 0) {
                u32 first_register = 0;
                const u32 register_count =
                    PopLowestRegisterRun(remaining_registers, first_register);
                for (u32 i = 0; i < register_count; ++i) {
                    state->Reg[first_register + i] =
                        ReadMemory32T<ProfileOpcodes, BigEndian>(address);
                    address += 4;
                }
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmLoadMultipleWithPcFast: {
            const bool writeback = (op.arg0 & 1) != 0;
            const bool add_offset = ((op.arg0 >> 1) & 1) != 0;
            const bool pre_indexed = ((op.arg0 >> 2) & 1) != 0;
            const u32 rn = op.arg1 & 0xF;
            const u32 register_list = (op.arg1 >> 8) & 0xFFFF;
            const u32 transfer_bytes = op.arg2 * 4;
            const u32 old_base = state->Reg[rn];
            u32 address = 0;
            if (add_offset) {
                address = pre_indexed ? old_base + 4 : old_base;
            } else {
                address = pre_indexed ? old_base - transfer_bytes : old_base - transfer_bytes + 4;
            }

            if (writeback) {
                state->Reg[rn] = add_offset ? old_base + transfer_bytes : old_base - transfer_bytes;
            }

            if (op.arg2 == 1) {
                const u32 reg = static_cast<u32>(std::countr_zero(register_list));
                u32 value = ReadMemory32T<ProfileOpcodes, BigEndian>(address);
                if (reg == 15) {
                    IR_TRACE_TFLAG(value & 1, 13);
                    value &= 0xFFFFFFFE;
                }
                state->Reg[reg] = value;

                result.instructions++;
                if (reg == 15) {
                    goto block_done;
                }
                AdvancePC(*state, op);
                break;
            }

            if constexpr (!BigEndian) {
                if (const u8* page_pointer =
                        GetFastMemoryPointerForSpanT<ProfileOpcodes>(address, transfer_bytes)) {
                    u32 fast_offset = address & Memory::CITRA_PAGE_MASK;
                    CountFastmemHitT<ProfileOpcodes>(op.arg2);
                    u32 remaining_registers = register_list;
                    while (remaining_registers != 0) {
                        u32 first_register = 0;
                        const u32 register_count =
                            PopLowestRegisterRun(remaining_registers, first_register);
                        const u32 normal_register_count =
                            first_register < 15
                                ? std::min(register_count, 15U - first_register)
                                : 0;
                        if (normal_register_count != 0) {
                            LoadRegisterRun(*state, first_register, normal_register_count,
                                            &page_pointer[fast_offset]);
                            fast_offset += normal_register_count * sizeof(u32);
                        }
                        for (u32 i = normal_register_count; i < register_count; ++i) {
                            const u32 reg = first_register + i;
                            u32 value = ReadUnaligned<u32>(&page_pointer[fast_offset]);
                            if (reg == 15) {
                                IR_TRACE_TFLAG(value & 1, 14);
                                value &= 0xFFFFFFFE;
                            }
                            state->Reg[reg] = value;
                            fast_offset += 4;
                        }
                    }

                    result.instructions++;
                    goto block_done;
                }
            }

            u32 remaining_registers = register_list;
            while (remaining_registers != 0) {
                u32 first_register = 0;
                const u32 register_count =
                    PopLowestRegisterRun(remaining_registers, first_register);
                for (u32 i = 0; i < register_count; ++i) {
                    const u32 reg = first_register + i;
                    u32 value = ReadMemory32T<ProfileOpcodes, BigEndian>(address);
                    if (reg == 15) {
                        IR_TRACE_TFLAG(value & 1, 15);
                        value &= 0xFFFFFFFE;
                    }
                    state->Reg[reg] = value;
                    address += 4;
                }
            }

            result.instructions++;
            goto block_done;
        }
        case ARMIR::Opcode::ArmStoreMultipleFast: {
            const bool writeback = (op.arg0 & 1) != 0;
            const bool add_offset = ((op.arg0 >> 1) & 1) != 0;
            const bool pre_indexed = ((op.arg0 >> 2) & 1) != 0;
            const u32 rn = op.arg1 & 0xF;
            const u32 register_list = (op.arg1 >> 8) & 0xFFFF;
            const u32 transfer_bytes = op.arg2 * 4;
            const u32 old_base = state->Reg[rn];
            u32 address = 0;
            if (add_offset) {
                address = pre_indexed ? old_base + 4 : old_base;
            } else {
                address = pre_indexed ? old_base - transfer_bytes : old_base - transfer_bytes + 4;
            }

            if (writeback) {
                state->Reg[rn] = add_offset ? old_base + transfer_bytes : old_base - transfer_bytes;
            }

            if (op.arg2 == 1) {
                const u32 reg = static_cast<u32>(std::countr_zero(register_list & 0x7FFF));
                const u32 value = writeback && reg == rn ? old_base : state->Reg[reg];
                WriteMemory32T<ProfileOpcodes, BigEndian>(address, value);

                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            if constexpr (!BigEndian) {
                if (u8* page_pointer =
                        GetFastMemoryPointerForSpanT<ProfileOpcodes>(address, transfer_bytes)) {
                    u32 fast_offset = address & Memory::CITRA_PAGE_MASK;
                    CountFastmemHitT<ProfileOpcodes>(op.arg2);
                    u32 remaining_registers = register_list & 0x7FFF;
                    while (remaining_registers != 0) {
                        u32 first_register = 0;
                        const u32 register_count =
                            PopLowestRegisterRun(remaining_registers, first_register);
                        const bool run_contains_base =
                            writeback && rn >= first_register &&
                            rn < first_register + register_count;
                        if (!run_contains_base) {
                            StoreRegisterRun(*state, first_register, register_count,
                                             &page_pointer[fast_offset]);
                            fast_offset += register_count * sizeof(u32);
                        } else {
                            for (u32 i = 0; i < register_count; ++i) {
                                const u32 reg = first_register + i;
                                const u32 value = reg == rn ? old_base : state->Reg[reg];
                                WriteUnaligned(&page_pointer[fast_offset], value);
                                fast_offset += 4;
                            }
                        }
                    }

                    AdvancePC(*state, op);
                    result.instructions++;
                    break;
                }
            }

            u32 remaining_registers = register_list & 0x7FFF;
            while (remaining_registers != 0) {
                u32 first_register = 0;
                const u32 register_count =
                    PopLowestRegisterRun(remaining_registers, first_register);
                for (u32 i = 0; i < register_count; ++i) {
                    const u32 reg = first_register + i;
                    const u32 value = writeback && reg == rn ? old_base : state->Reg[reg];
                    WriteMemory32T<ProfileOpcodes, BigEndian>(address, value);
                    address += 4;
                }
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmStoreReturnState: {

            const bool writeback = (op.arg0 & 1) != 0;
            const bool add_offset = ((op.arg0 >> 1) & 1) != 0;
            const bool pre_indexed = ((op.arg0 >> 2) & 1) != 0;
            const u32 rn = op.arg1 & 0xF;
            const u32 transfer_bytes = op.arg2 * 4;
            const u32 old_base = state->Reg[rn];
            u32 address = 0;
            if (add_offset) {
                address = pre_indexed ? old_base + 4 : old_base;
            } else {
                address = pre_indexed ? old_base - transfer_bytes : old_base - transfer_bytes + 4;
            }

            if (writeback) {
                state->Reg[rn] = add_offset ? old_base + transfer_bytes : old_base - transfer_bytes;
            }

            WriteMemory32T<ProfileOpcodes, BigEndian>(address, state->Reg[14]);
            WriteMemory32T<ProfileOpcodes, BigEndian>(address + 4, state->Spsr_copy);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmReturnFromException: {

            const bool writeback = (op.arg0 & 1) != 0;
            const bool add_offset = ((op.arg0 >> 1) & 1) != 0;
            const bool pre_indexed = ((op.arg0 >> 2) & 1) != 0;
            const u32 rn = op.arg1 & 0xF;
            const u32 transfer_bytes = op.arg2 * 4;
            const u32 old_base = rn == 15 ? state->Reg[15] + 8 : state->Reg[rn];
            u32 address = 0;
            if (add_offset) {
                address = pre_indexed ? old_base + 4 : old_base;
            } else {
                address = pre_indexed ? old_base - transfer_bytes : old_base - transfer_bytes + 4;
            }

            if (writeback) {
                state->Reg[rn] = add_offset ? old_base + transfer_bytes : old_base - transfer_bytes;
            }

            const u32 cpsr = ReadMemory32T<ProfileOpcodes, BigEndian>(address);
            const u32 pc = ReadMemory32T<ProfileOpcodes, BigEndian>(address + 4);
            state->Cpsr = cpsr;
            state->Reg[15] = pc;

            result.instructions++;
            goto block_done;
        }
        case ARMIR::Opcode::ArmMultiply: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool accumulate = ((op.arg0 >> 8) & 1) != 0;
            const bool set_flags = ((op.arg0 >> 9) & 1) != 0;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rs = (op.arg1 >> 16) & 0xF;
            const u32 rm = (op.arg1 >> 24) & 0xF;

            u64 multiply_result =
                static_cast<u64>(state->Reg[rm]) * static_cast<u64>(state->Reg[rs]);
            if (accumulate) {
                multiply_result += state->Reg[rn];
            }
            const u32 data_result = static_cast<u32>(multiply_result);
            state->Reg[rd] = data_result;
            if (set_flags) {
                SetLazyNZFlags(data_result);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmMultiplyAlways: {
            const bool accumulate = ((op.arg0 >> 8) & 1) != 0;
            const bool set_flags = ((op.arg0 >> 9) & 1) != 0;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rs = (op.arg1 >> 16) & 0xF;
            const u32 rm = (op.arg1 >> 24) & 0xF;

            u64 multiply_result =
                static_cast<u64>(state->Reg[rm]) * static_cast<u64>(state->Reg[rs]);
            if (accumulate) {
                multiply_result += state->Reg[rn];
            }
            const u32 data_result = static_cast<u32>(multiply_result);
            state->Reg[rd] = data_result;
            if (set_flags) {
                SetLazyNZFlags(data_result);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmUnsignedMultiplyAccumulateAccumulateLong: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const u32 rd_lo = op.arg1 & 0xF;
            const u32 rd_hi = (op.arg1 >> 8) & 0xF;
            const u32 rs = (op.arg1 >> 16) & 0xF;
            const u32 rm = (op.arg1 >> 24) & 0xF;
            const u64 result_value =
                static_cast<u64>(state->Reg[rm]) * static_cast<u64>(state->Reg[rs]) +
                state->Reg[rd_lo] + state->Reg[rd_hi];
            state->Reg[rd_lo] = static_cast<u32>(result_value);
            state->Reg[rd_hi] = static_cast<u32>(result_value >> 32);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmUnsignedMultiplyAccumulateAccumulateLongAlways: {
            const u32 rd_lo = op.arg1 & 0xF;
            const u32 rd_hi = (op.arg1 >> 8) & 0xF;
            const u32 rs = (op.arg1 >> 16) & 0xF;
            const u32 rm = (op.arg1 >> 24) & 0xF;
            const u64 result_value =
                static_cast<u64>(state->Reg[rm]) * static_cast<u64>(state->Reg[rs]) +
                state->Reg[rd_lo] + state->Reg[rd_hi];
            state->Reg[rd_lo] = static_cast<u32>(result_value);
            state->Reg[rd_hi] = static_cast<u32>(result_value >> 32);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmMultiplyLong: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool signed_multiply = ((op.arg0 >> 8) & 1) != 0;
            const bool accumulate = ((op.arg0 >> 9) & 1) != 0;
            const bool set_flags = ((op.arg0 >> 10) & 1) != 0;
            const u32 rd_lo = op.arg1 & 0xF;
            const u32 rd_hi = (op.arg1 >> 8) & 0xF;
            const u32 rs = (op.arg1 >> 16) & 0xF;
            const u32 rm = (op.arg1 >> 24) & 0xF;

            u64 multiply_result = 0;
            if (signed_multiply) {
                const s64 lhs = static_cast<s64>(static_cast<s32>(state->Reg[rm]));
                const s64 rhs = static_cast<s64>(static_cast<s32>(state->Reg[rs]));
                s64 signed_result = lhs * rhs;
                if (accumulate) {
                    const u64 accumulator =
                        (static_cast<u64>(state->Reg[rd_hi]) << 32) | state->Reg[rd_lo];
                    signed_result += SignedFromU64(accumulator);
                }
                multiply_result = static_cast<u64>(signed_result);
            } else {
                multiply_result =
                    static_cast<u64>(state->Reg[rm]) * static_cast<u64>(state->Reg[rs]);
                if (accumulate) {
                    multiply_result +=
                        (static_cast<u64>(state->Reg[rd_hi]) << 32) | state->Reg[rd_lo];
                }
            }

            state->Reg[rd_hi] = static_cast<u32>(multiply_result >> 32);
            state->Reg[rd_lo] = static_cast<u32>(multiply_result);
            if (set_flags) {
                SetLazyNZFlags((state->Reg[rd_hi] >> 31) != 0,
                               state->Reg[rd_hi] == 0 && state->Reg[rd_lo] == 0);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmMultiplyLongAlways: {
            const bool signed_multiply = ((op.arg0 >> 8) & 1) != 0;
            const bool accumulate = ((op.arg0 >> 9) & 1) != 0;
            const bool set_flags = ((op.arg0 >> 10) & 1) != 0;
            const u32 rd_lo = op.arg1 & 0xF;
            const u32 rd_hi = (op.arg1 >> 8) & 0xF;
            const u32 rs = (op.arg1 >> 16) & 0xF;
            const u32 rm = (op.arg1 >> 24) & 0xF;

            u64 multiply_result = 0;
            if (signed_multiply) {
                const s64 lhs = static_cast<s64>(static_cast<s32>(state->Reg[rm]));
                const s64 rhs = static_cast<s64>(static_cast<s32>(state->Reg[rs]));
                s64 signed_result = lhs * rhs;
                if (accumulate) {
                    const u64 accumulator =
                        (static_cast<u64>(state->Reg[rd_hi]) << 32) | state->Reg[rd_lo];
                    signed_result += SignedFromU64(accumulator);
                }
                multiply_result = static_cast<u64>(signed_result);
            } else {
                multiply_result =
                    static_cast<u64>(state->Reg[rm]) * static_cast<u64>(state->Reg[rs]);
                if (accumulate) {
                    multiply_result +=
                        (static_cast<u64>(state->Reg[rd_hi]) << 32) | state->Reg[rd_lo];
                }
            }

            state->Reg[rd_hi] = static_cast<u32>(multiply_result >> 32);
            state->Reg[rd_lo] = static_cast<u32>(multiply_result);
            if (set_flags) {
                SetLazyNZFlags((state->Reg[rd_hi] >> 31) != 0,
                               state->Reg[rd_hi] == 0 && state->Reg[rd_lo] == 0);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSaturatingArithmetic: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const u32 arithmetic_op = (op.arg0 >> 8) & 0x3;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rn_value = state->Reg[rn];
            const u32 rm_value = state->Reg[rm];

            u32 value = 0;
            switch (arithmetic_op) {
            case 0: { // QADD
                value = rm_value + rn_value;
                if (AddOverflow(rm_value, rn_value, value)) {
                    value = SignedSaturationLimitFromWrappedResult(value);
                    state->Cpsr |= (1U << 27);
                }
                break;
            }
            case 1: { // QSUB
                value = rm_value - rn_value;
                if (SubOverflow(rm_value, rn_value, value)) {
                    value = SignedSaturationLimitFromWrappedResult(value);
                    state->Cpsr |= (1U << 27);
                }
                break;
            }
            case 2: { // QDADD
                u32 doubled = rn_value * 2;
                if (AddOverflow(rn_value, rn_value, doubled)) {
                    doubled = SignedSaturationLimitFromWrappedResult(doubled);
                    state->Cpsr |= (1U << 27);
                }
                value = rm_value + doubled;
                if (AddOverflow(rm_value, doubled, value)) {
                    value = SignedSaturationLimitFromWrappedResult(value);
                    state->Cpsr |= (1U << 27);
                }
                break;
            }
            case 3: { // QDSUB
                u32 doubled = rn_value * 2;
                if (AddOverflow(rn_value, rn_value, doubled)) {
                    doubled = SignedSaturationLimitFromWrappedResult(doubled);
                    state->Cpsr |= (1U << 27);
                }
                value = rm_value - doubled;
                if (SubOverflow(rm_value, doubled, value)) {
                    value = SignedSaturationLimitFromWrappedResult(value);
                    state->Cpsr |= (1U << 27);
                }
                break;
            }
            default:
                break;
            }

            state->Reg[rd] = value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmParallelAddSub: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool unsigned_parallel = ((op.arg0 >> 8) & 1) != 0;
            const u32 parallel_op = (op.arg0 >> 9) & 0x7;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rn_value = state->Reg[rn];
            const u32 rm_value = state->Reg[rm];

            if (!unsigned_parallel) {
                if (parallel_op <= 3) {
                    const s32 rn_lo = static_cast<s16>(rn_value & 0xFFFF);
                    const s32 rn_hi = static_cast<s16>((rn_value >> 16) & 0xFFFF);
                    const s32 rm_lo = static_cast<s16>(rm_value & 0xFFFF);
                    const s32 rm_hi = static_cast<s16>((rm_value >> 16) & 0xFFFF);
                    s32 lo_result = 0;
                    s32 hi_result = 0;
                    switch (parallel_op) {
                    case 0: // SADD16
                        lo_result = rn_lo + rm_lo;
                        hi_result = rn_hi + rm_hi;
                        break;
                    case 1: // SASX
                        lo_result = rn_lo - rm_hi;
                        hi_result = rn_hi + rm_lo;
                        break;
                    case 2: // SSAX
                        lo_result = rn_lo + rm_hi;
                        hi_result = rn_hi - rm_lo;
                        break;
                    case 3: // SSUB16
                        lo_result = rn_lo - rm_lo;
                        hi_result = rn_hi - rm_hi;
                        break;
                    default:
                        break;
                    }
                    state->Reg[rd] = (static_cast<u32>(lo_result) & 0xFFFF) |
                                     ((static_cast<u32>(hi_result) & 0xFFFF) << 16);
                    SetGEHalfwordFlags(*state, 0, lo_result >= 0);
                    SetGEHalfwordFlags(*state, 1, hi_result >= 0);
                } else {
                    s32 byte_results[4]{};
                    for (u32 lane = 0; lane < 4; ++lane) {
                        const s32 rn_byte =
                            static_cast<s8>((rn_value >> (lane * 8)) & 0xFF);
                        const s32 rm_byte =
                            static_cast<s8>((rm_value >> (lane * 8)) & 0xFF);
                        byte_results[lane] =
                            parallel_op == 4 ? (rn_byte + rm_byte) : (rn_byte - rm_byte);
                        SetGEFlag(*state, lane, byte_results[lane] >= 0);
                    }
                    state->Reg[rd] =
                        (static_cast<u32>(byte_results[0]) & 0xFF) |
                        ((static_cast<u32>(byte_results[1]) & 0xFF) << 8) |
                        ((static_cast<u32>(byte_results[2]) & 0xFF) << 16) |
                        ((static_cast<u32>(byte_results[3]) & 0xFF) << 24);
                }
            } else {
                if (parallel_op <= 3) {
                    const s32 rn_lo = rn_value & 0xFFFF;
                    const s32 rn_hi = (rn_value >> 16) & 0xFFFF;
                    const s32 rm_lo = rm_value & 0xFFFF;
                    const s32 rm_hi = (rm_value >> 16) & 0xFFFF;
                    s32 lo_result = 0;
                    s32 hi_result = 0;
                    bool lo_ge = false;
                    bool hi_ge = false;
                    switch (parallel_op) {
                    case 0: // UADD16
                        lo_result = rn_lo + rm_lo;
                        hi_result = rn_hi + rm_hi;
                        lo_ge = lo_result >= 0x10000;
                        hi_ge = hi_result >= 0x10000;
                        break;
                    case 1: // UASX
                        lo_result = rn_lo - rm_hi;
                        hi_result = rn_hi + rm_lo;
                        lo_ge = lo_result >= 0;
                        hi_ge = hi_result >= 0x10000;
                        break;
                    case 2: // USAX
                        lo_result = rn_lo + rm_hi;
                        hi_result = rn_hi - rm_lo;
                        lo_ge = lo_result >= 0x10000;
                        hi_ge = hi_result >= 0;
                        break;
                    case 3: // USUB16
                        lo_result = rn_lo - rm_lo;
                        hi_result = rn_hi - rm_hi;
                        lo_ge = lo_result >= 0;
                        hi_ge = hi_result >= 0;
                        break;
                    default:
                        break;
                    }
                    state->Reg[rd] = (static_cast<u32>(lo_result) & 0xFFFF) |
                                     ((static_cast<u32>(hi_result) & 0xFFFF) << 16);
                    SetGEHalfwordFlags(*state, 0, lo_ge);
                    SetGEHalfwordFlags(*state, 1, hi_ge);
                } else {
                    s32 byte_results[4]{};
                    for (u32 lane = 0; lane < 4; ++lane) {
                        const s32 rn_byte = (rn_value >> (lane * 8)) & 0xFF;
                        const s32 rm_byte = (rm_value >> (lane * 8)) & 0xFF;
                        byte_results[lane] =
                            parallel_op == 4 ? (rn_byte + rm_byte) : (rn_byte - rm_byte);
                        SetGEFlag(*state, lane,
                                  parallel_op == 4 ? byte_results[lane] >= 0x100
                                                   : byte_results[lane] >= 0);
                    }
                    state->Reg[rd] =
                        (static_cast<u32>(byte_results[0]) & 0xFF) |
                        ((static_cast<u32>(byte_results[1]) & 0xFF) << 8) |
                        ((static_cast<u32>(byte_results[2]) & 0xFF) << 16) |
                        ((static_cast<u32>(byte_results[3]) & 0xFF) << 24);
                }
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSignedHalvingParallelAddSub: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const u32 parallel_op = (op.arg0 >> 8) & 0x7;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rn_value = state->Reg[rn];
            const u32 rm_value = state->Reg[rm];

            if (parallel_op <= 3) {
                const s32 rn_lo = static_cast<s16>(rn_value & 0xFFFF);
                const s32 rn_hi = static_cast<s16>((rn_value >> 16) & 0xFFFF);
                const s32 rm_lo = static_cast<s16>(rm_value & 0xFFFF);
                const s32 rm_hi = static_cast<s16>((rm_value >> 16) & 0xFFFF);
                s32 lo_result = 0;
                s32 hi_result = 0;
                switch (parallel_op) {
                case 0: // SHADD16
                    lo_result = (rn_lo + rm_lo) >> 1;
                    hi_result = (rn_hi + rm_hi) >> 1;
                    break;
                case 1: // SHASX
                    lo_result = (rn_lo - rm_hi) >> 1;
                    hi_result = (rn_hi + rm_lo) >> 1;
                    break;
                case 2: // SHSAX
                    lo_result = (rn_lo + rm_hi) >> 1;
                    hi_result = (rn_hi - rm_lo) >> 1;
                    break;
                case 3: // SHSUB16
                    lo_result = (rn_lo - rm_lo) >> 1;
                    hi_result = (rn_hi - rm_hi) >> 1;
                    break;
                default:
                    break;
                }
                state->Reg[rd] = (static_cast<u32>(lo_result) & 0xFFFF) |
                                 ((static_cast<u32>(hi_result) & 0xFFFF) << 16);
            } else {
                s32 byte_results[4]{};
                for (u32 lane = 0; lane < 4; ++lane) {
                    const s32 rn_byte = static_cast<s8>((rn_value >> (lane * 8)) & 0xFF);
                    const s32 rm_byte = static_cast<s8>((rm_value >> (lane * 8)) & 0xFF);
                    byte_results[lane] =
                        (parallel_op == 4 ? (rn_byte + rm_byte) : (rn_byte - rm_byte)) >> 1;
                }
                state->Reg[rd] =
                    (static_cast<u32>(byte_results[0]) & 0xFF) |
                    ((static_cast<u32>(byte_results[1]) & 0xFF) << 8) |
                    ((static_cast<u32>(byte_results[2]) & 0xFF) << 16) |
                    ((static_cast<u32>(byte_results[3]) & 0xFF) << 24);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmUnsignedHalvingParallelAddSub: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const u32 parallel_op = (op.arg0 >> 8) & 0x7;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rn_value = state->Reg[rn];
            const u32 rm_value = state->Reg[rm];

            if (parallel_op <= 3) {
                const u32 rn_lo = rn_value & 0xFFFF;
                const u32 rn_hi = (rn_value >> 16) & 0xFFFF;
                const u32 rm_lo = rm_value & 0xFFFF;
                const u32 rm_hi = (rm_value >> 16) & 0xFFFF;
                u32 lo_result = 0;
                u32 hi_result = 0;
                switch (parallel_op) {
                case 0: // UHADD16
                    lo_result = rn_lo + rm_lo;
                    hi_result = rn_hi + rm_hi;
                    break;
                case 1: // UHASX
                    lo_result = rn_lo - rm_hi;
                    hi_result = rn_hi + rm_lo;
                    break;
                case 2: // UHSAX
                    lo_result = rn_lo + rm_hi;
                    hi_result = rn_hi - rm_lo;
                    break;
                case 3: // UHSUB16
                    lo_result = rn_lo - rm_lo;
                    hi_result = rn_hi - rm_hi;
                    break;
                default:
                    break;
                }
                lo_result >>= 1;
                hi_result >>= 1;
                state->Reg[rd] = (lo_result & 0xFFFF) | ((hi_result & 0xFFFF) << 16);
            } else {
                u32 byte_results[4]{};
                for (u32 lane = 0; lane < 4; ++lane) {
                    const u32 rn_byte = (rn_value >> (lane * 8)) & 0xFF;
                    const u32 rm_byte = (rm_value >> (lane * 8)) & 0xFF;
                    byte_results[lane] =
                        (parallel_op == 4 ? (rn_byte + rm_byte) : (rn_byte - rm_byte)) >> 1;
                }
                state->Reg[rd] =
                    (byte_results[0] & 0xFF) | ((byte_results[1] & 0xFF) << 8) |
                    ((byte_results[2] & 0xFF) << 16) | ((byte_results[3] & 0xFF) << 24);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSignedSaturatingParallelAddSub: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const u32 parallel_op = (op.arg0 >> 8) & 0x7;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rn_value = state->Reg[rn];
            const u32 rm_value = state->Reg[rm];

            if (parallel_op <= 3) {
                const s32 rn_lo = static_cast<s16>(rn_value & 0xFFFF);
                const s32 rn_hi = static_cast<s16>((rn_value >> 16) & 0xFFFF);
                const s32 rm_lo = static_cast<s16>(rm_value & 0xFFFF);
                const s32 rm_hi = static_cast<s16>((rm_value >> 16) & 0xFFFF);
                u32 lo_result = 0;
                u32 hi_result = 0;
                switch (parallel_op) {
                case 0: // QADD16
                    lo_result = SignedSaturateLane(rn_lo + rm_lo, 16);
                    hi_result = SignedSaturateLane(rn_hi + rm_hi, 16);
                    break;
                case 1: // QASX
                    lo_result = SignedSaturateLane(rn_lo - rm_hi, 16);
                    hi_result = SignedSaturateLane(rn_hi + rm_lo, 16);
                    break;
                case 2: // QSAX
                    lo_result = SignedSaturateLane(rn_lo + rm_hi, 16);
                    hi_result = SignedSaturateLane(rn_hi - rm_lo, 16);
                    break;
                case 3: // QSUB16
                    lo_result = SignedSaturateLane(rn_lo - rm_lo, 16);
                    hi_result = SignedSaturateLane(rn_hi - rm_hi, 16);
                    break;
                default:
                    break;
                }
                state->Reg[rd] = (lo_result & 0xFFFF) | ((hi_result & 0xFFFF) << 16);
            } else {
                u32 byte_results[4]{};
                for (u32 lane = 0; lane < 4; ++lane) {
                    const s32 rn_byte = static_cast<s8>((rn_value >> (lane * 8)) & 0xFF);
                    const s32 rm_byte = static_cast<s8>((rm_value >> (lane * 8)) & 0xFF);
                    byte_results[lane] =
                        SignedSaturateLane(parallel_op == 4 ? (rn_byte + rm_byte)
                                                             : (rn_byte - rm_byte),
                                           8);
                }
                state->Reg[rd] =
                    (byte_results[0] & 0xFF) | ((byte_results[1] & 0xFF) << 8) |
                    ((byte_results[2] & 0xFF) << 16) | ((byte_results[3] & 0xFF) << 24);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmUnsignedSaturatingParallelAddSub: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const u32 parallel_op = (op.arg0 >> 8) & 0x7;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rn_value = state->Reg[rn];
            const u32 rm_value = state->Reg[rm];

            if (parallel_op <= 3) {
                const u32 rn_lo = rn_value & 0xFFFF;
                const u32 rn_hi = (rn_value >> 16) & 0xFFFF;
                const u32 rm_lo = rm_value & 0xFFFF;
                const u32 rm_hi = (rm_value >> 16) & 0xFFFF;
                u32 lo_result = 0;
                u32 hi_result = 0;
                switch (parallel_op) {
                case 0: // UQADD16
                    lo_result = UnsignedSaturatingAddLane(rn_lo, rm_lo, 0xFFFF);
                    hi_result = UnsignedSaturatingAddLane(rn_hi, rm_hi, 0xFFFF);
                    break;
                case 1: // UQASX
                    lo_result = UnsignedSaturatingSubLane(rn_lo, rm_hi);
                    hi_result = UnsignedSaturatingAddLane(rn_hi, rm_lo, 0xFFFF);
                    break;
                case 2: // UQSAX
                    lo_result = UnsignedSaturatingAddLane(rn_lo, rm_hi, 0xFFFF);
                    hi_result = UnsignedSaturatingSubLane(rn_hi, rm_lo);
                    break;
                case 3: // UQSUB16
                    lo_result = UnsignedSaturatingSubLane(rn_lo, rm_lo);
                    hi_result = UnsignedSaturatingSubLane(rn_hi, rm_hi);
                    break;
                default:
                    break;
                }
                state->Reg[rd] = (lo_result & 0xFFFF) | ((hi_result & 0xFFFF) << 16);
            } else {
                u32 byte_results[4]{};
                for (u32 lane = 0; lane < 4; ++lane) {
                    const u32 rn_byte = (rn_value >> (lane * 8)) & 0xFF;
                    const u32 rm_byte = (rm_value >> (lane * 8)) & 0xFF;
                    byte_results[lane] =
                        parallel_op == 4 ? UnsignedSaturatingAddLane(rn_byte, rm_byte, 0xFF)
                                         : UnsignedSaturatingSubLane(rn_byte, rm_byte);
                }
                state->Reg[rd] =
                    (byte_results[0] & 0xFF) | ((byte_results[1] & 0xFF) << 8) |
                    ((byte_results[2] & 0xFF) << 16) | ((byte_results[3] & 0xFF) << 24);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSelectBytes: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 from = state->Reg[rn];
            const u32 to = state->Reg[rm];
            u32 value = 0;
            for (u32 lane = 0; lane < 4; ++lane) {
                const u32 mask = 0xFFU << (lane * 8);
                value |= ((state->Cpsr & (1U << (16 + lane))) != 0 ? from : to) & mask;
            }
            state->Reg[rd] = value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSignedHalfwordMultiply: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool accumulate = ((op.arg0 >> 8) & 1) != 0;
            const bool long_result = ((op.arg0 >> 9) & 1) != 0;
            const bool x_high = ((op.arg0 >> 10) & 1) != 0;
            const bool y_high = ((op.arg0 >> 11) & 1) != 0;

            if (long_result) {
                const u32 rd_lo = op.arg1 & 0xF;
                const u32 rd_hi = (op.arg1 >> 8) & 0xF;
                const u32 rn = (op.arg1 >> 16) & 0xF;
                const u32 rm = (op.arg1 >> 24) & 0xF;
                const s64 product =
                    static_cast<s64>(SignedHalfword(state->Reg[rn], x_high)) *
                    static_cast<s64>(SignedHalfword(state->Reg[rm], y_high));
                const u64 accumulator =
                    static_cast<u64>(state->Reg[rd_lo]) |
                    (static_cast<u64>(state->Reg[rd_hi]) << 32);
                const u64 value = accumulator + static_cast<u64>(product);
                state->Reg[rd_lo] = static_cast<u32>(value);
                state->Reg[rd_hi] = static_cast<u32>(value >> 32);
            } else {
                const u32 rd = op.arg1 & 0xF;
                const u32 rm = (op.arg1 >> 8) & 0xF;
                const u32 rs = (op.arg1 >> 16) & 0xF;
                const u32 rn = (op.arg1 >> 24) & 0xF;
                const s32 product = SignedHalfword(state->Reg[rm], x_high) *
                                    SignedHalfword(state->Reg[rs], y_high);
                u32 value = static_cast<u32>(product);
                if (accumulate) {
                    const u32 accumulator = state->Reg[rn];
                    const u32 accumulated = value + accumulator;
                    if (AddOverflow(value, accumulator, accumulated)) {
                        state->Cpsr |= (1U << 27);
                    }
                    value = accumulated;
                }
                state->Reg[rd] = value;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSignedWordHalfwordMultiply: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool accumulate = ((op.arg0 >> 8) & 1) != 0;
            const bool high = ((op.arg0 >> 9) & 1) != 0;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 ra = (op.arg1 >> 24) & 0xF;
            s64 multiply_result = static_cast<s64>(static_cast<s32>(state->Reg[rn])) *
                                  static_cast<s64>(SignedHalfword(state->Reg[rm], high));
            if (accumulate) {
                multiply_result +=
                    static_cast<s64>(static_cast<s32>(state->Reg[ra])) * 0x10000LL;
            }

            state->Reg[rd] = static_cast<u32>(multiply_result >> 16);
            if (accumulate && (multiply_result >> 16) != static_cast<s32>(state->Reg[rd])) {
                state->Cpsr |= (1U << 27);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSignedDualMultiply: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool subtract = ((op.arg0 >> 8) & 1) != 0;
            const bool swap = ((op.arg0 >> 9) & 1) != 0;
            const bool accumulate = ((op.arg0 >> 10) & 1) != 0;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 ra = (op.arg1 >> 24) & 0xF;

            u32 rm_value = state->Reg[rm];
            if (swap) {
                rm_value = ((rm_value & 0xFFFF) << 16) | (rm_value >> 16);
            }
            const u32 product1 =
                static_cast<u32>(SignedHalfword(state->Reg[rn], false) *
                                 SignedHalfword(rm_value, false));
            const u32 product2 =
                static_cast<u32>(SignedHalfword(state->Reg[rn], true) *
                                 SignedHalfword(rm_value, true));

            u32 value = subtract ? (product1 - product2) : (product1 + product2);
            if (accumulate) {
                const u32 accumulator = state->Reg[ra];
                if (ARMul_AddOverflowQ(value, accumulator)) {
                    state->Cpsr |= (1U << 27);
                }
                value += accumulator;
            }
            if (!subtract && ARMul_AddOverflowQ(product1, product2)) {
                state->Cpsr |= (1U << 27);
            }
            state->Reg[rd] = value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSignedDualMultiplyLong: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool subtract = ((op.arg0 >> 8) & 1) != 0;
            const bool swap = ((op.arg0 >> 9) & 1) != 0;
            const u32 rd_lo = op.arg1 & 0xF;
            const u32 rd_hi = (op.arg1 >> 8) & 0xF;
            const u32 rn = (op.arg1 >> 16) & 0xF;
            const u32 rm = (op.arg1 >> 24) & 0xF;

            u32 rm_value = state->Reg[rm];
            if (swap) {
                rm_value = ((rm_value & 0xFFFF) << 16) | (rm_value >> 16);
            }
            const s64 product1 = static_cast<s64>(SignedHalfword(state->Reg[rn], false)) *
                                 static_cast<s64>(SignedHalfword(rm_value, false));
            const s64 product2 = static_cast<s64>(SignedHalfword(state->Reg[rn], true)) *
                                 static_cast<s64>(SignedHalfword(rm_value, true));
            const s64 product = subtract ? (product1 - product2) : (product1 + product2);
            const u64 accumulator =
                static_cast<u64>(state->Reg[rd_lo]) |
                (static_cast<u64>(state->Reg[rd_hi]) << 32);
            const u64 value = accumulator + static_cast<u64>(product);
            state->Reg[rd_lo] = static_cast<u32>(value);
            state->Reg[rd_hi] = static_cast<u32>(value >> 32);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSignedMostSignificantMultiply: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool subtract = ((op.arg0 >> 8) & 1) != 0;
            const bool round = ((op.arg0 >> 9) & 1) != 0;
            const bool accumulate = ((op.arg0 >> 10) & 1) != 0;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 ra = (op.arg1 >> 24) & 0xF;

            u64 value = static_cast<u64>(static_cast<s64>(static_cast<s32>(state->Reg[rn])) *
                                         static_cast<s64>(static_cast<s32>(state->Reg[rm])));
            if (accumulate) {
                const u64 accumulator = static_cast<u64>(state->Reg[ra]) << 32;
                value = subtract ? (accumulator - value) : (value + accumulator);
            }
            if (round) {
                value += 0x80000000ULL;
            }
            state->Reg[rd] = static_cast<u32>(value >> 32);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCountLeadingZeros: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            state->Reg[rd] = CountLeadingZeros(state->Reg[rm]);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmExtend: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool signed_extend = ((op.arg0 >> 8) & 1) != 0;
            const bool halfword = ((op.arg0 >> 9) & 1) != 0;
            const u32 rotate = (op.arg0 >> 10) & 0x3;
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 rotated = RotateRight(state->Reg[rm], rotate * 8);
            if (halfword) {
                const u32 value = rotated & 0xFFFF;
                state->Reg[rd] =
                    signed_extend && (value & 0x8000) != 0 ? (value | 0xFFFF0000) : value;
            } else {
                const u32 value = rotated & 0xFF;
                state->Reg[rd] =
                    signed_extend && (value & 0x80) != 0 ? (value | 0xFFFFFF00) : value;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmExtendAdd: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool signed_extend = ((op.arg0 >> 8) & 1) != 0;
            const bool halfword = ((op.arg0 >> 9) & 1) != 0;
            const bool dual_lane = ((op.arg0 >> 10) & 1) != 0;
            const u32 rotate = (op.arg0 >> 11) & 0x3;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rotated = RotateRight(state->Reg[rm], rotate * 8);

            if (dual_lane) {
                if (rn == 15) {
                    if (signed_extend) {
                        const u32 lo = SignExtend8(rotated);
                        const u32 hi = SignExtend8(rotated >> 16);
                        state->Reg[rd] = (lo & 0xFFFF) | (hi << 16);
                    } else {
                        state->Reg[rd] = rotated & 0x00FF00FF;
                    }
                } else {
                    const u32 rn_value = state->Reg[rn];
                    if (signed_extend) {
                        const u32 lo = rn_value + SignExtend8(rotated);
                        const u32 hi = (rn_value >> 16) + SignExtend8(rotated >> 16);
                        state->Reg[rd] = (lo & 0xFFFF) | (hi << 16);
                    } else {
                        const u32 lo = (rn_value & 0xFFFF) + (rotated & 0xFF);
                        const u32 hi = (rn_value >> 16) + ((rotated >> 16) & 0xFF);
                        state->Reg[rd] = (hi << 16) | (lo & 0xFFFF);
                    }
                }
            } else if (halfword) {
                const u32 operand = signed_extend ? SignExtend16(rotated) : (rotated & 0xFFFF);
                state->Reg[rd] = state->Reg[rn] + operand;
            } else {
                const u32 operand = signed_extend ? SignExtend8(rotated) : (rotated & 0xFF);
                state->Reg[rd] = state->Reg[rn] + operand;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSaturate: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool signed_saturate = ((op.arg0 >> 8) & 1) != 0;
            const bool dual_lane = ((op.arg0 >> 9) & 1) != 0;
            const u32 shift_type = (op.arg0 >> 10) & 1;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 sat_imm = op.arg2 & 0xFF;
            const u32 imm5 = (op.arg2 >> 8) & 0x1F;

            bool saturated = false;
            if (dual_lane) {
                bool saturated_hi = false;
                if (signed_saturate) {
                    state->Reg[rd] =
                        (ARMul_SignedSatQ(static_cast<s16>(state->Reg[rn]), sat_imm,
                                          &saturated) &
                         0xFFFF) |
                        (ARMul_SignedSatQ(static_cast<s32>(state->Reg[rn]) >> 16, sat_imm,
                                          &saturated_hi)
                         << 16);
                } else {
                    state->Reg[rd] =
                        (ARMul_UnsignedSatQ(static_cast<s16>(state->Reg[rn]), sat_imm,
                                            &saturated) &
                         0xFFFF) |
                        (ARMul_UnsignedSatQ(static_cast<s32>(state->Reg[rn]) >> 16, sat_imm,
                                            &saturated_hi)
                         << 16);
                }
                saturated = saturated || saturated_hi;
            } else {
                u32 value = state->Reg[rn];
                u32 shift_amount = imm5;
                if (shift_type == 1 && shift_amount == 0) {
                    shift_amount = 31;
                }
                if (shift_type == 0) {
                    value <<= shift_amount;
                } else {
                    value = static_cast<u32>(static_cast<s32>(value) >> shift_amount);
                }

                state->Reg[rd] = signed_saturate
                                     ? ARMul_SignedSatQ(static_cast<s32>(value), sat_imm,
                                                       &saturated)
                                     : ARMul_UnsignedSatQ(static_cast<s32>(value), sat_imm,
                                                         &saturated);
            }

            if (saturated) {
                state->Cpsr |= (1U << 27);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmReverse: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const u32 reverse_type = (op.arg0 >> 8) & 0x3;
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 value = state->Reg[rm];
            switch (reverse_type) {
            case 0: // REV
                state->Reg[rd] = ((value & 0x000000FF) << 24) | ((value & 0x0000FF00) << 8) |
                                 ((value & 0x00FF0000) >> 8) | ((value & 0xFF000000) >> 24);
                break;
            case 1: // REV16
                state->Reg[rd] = ((value & 0x000000FF) << 8) | ((value & 0x0000FF00) >> 8) |
                                 ((value & 0x00FF0000) << 8) | ((value & 0xFF000000) >> 8);
                break;
            case 2: { // REVSH
                const u32 reversed = ((value & 0xFF) << 8) | ((value & 0xFF00) >> 8);
                state->Reg[rd] =
                    (reversed & 0x8000) != 0 ? (reversed | 0xFFFF0000) : reversed;
                break;
            }
            default:
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmPackHalfword: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool top = ((op.arg0 >> 8) & 1) != 0;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            if (top) {
                const u32 shift = op.arg2 != 0 ? op.arg2 : 31;
                const u32 shifted = static_cast<u32>(static_cast<s32>(state->Reg[rm]) >> shift);
                state->Reg[rd] = (state->Reg[rn] & 0xFFFF0000) | (shifted & 0xFFFF);
            } else {
                state->Reg[rd] = (state->Reg[rn] & 0xFFFF) |
                                 ((state->Reg[rm] << op.arg2) & 0xFFFF0000);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmUnsignedSumAbsoluteDifference: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 ra = (op.arg1 >> 24) & 0xF;
            const u32 rn_value = state->Reg[rn];
            const u32 rm_value = state->Reg[rm];
            u32 result_value =
                UnsignedAbsoluteDifference8(rn_value, rm_value) +
                UnsignedAbsoluteDifference8(rn_value >> 8, rm_value >> 8) +
                UnsignedAbsoluteDifference8(rn_value >> 16, rm_value >> 16) +
                UnsignedAbsoluteDifference8(rn_value >> 24, rm_value >> 24);
            if (ra != 15) {
                result_value += state->Reg[ra];
            }
            state->Reg[rd] = result_value;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmSwap: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool byte = ((op.arg0 >> 8) & 1) != 0;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 address = state->Reg[rn];
            if (byte) {
                const u32 value = ReadMemory8T<ProfileOpcodes>(address);
                WriteMemory8T<ProfileOpcodes>(address, static_cast<u8>(state->Reg[rm]));
                state->Reg[rd] = value;
            } else {
                const u32 value = ReadMemory32T<ProfileOpcodes, BigEndian>(address);
                WriteMemory32T<ProfileOpcodes, BigEndian>(address, state->Reg[rm]);
                state->Reg[rd] = value;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmExclusiveLoad: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const u32 size = (op.arg0 >> 8) & 0x3;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 address = state->Reg[rn];
            state->SetExclusiveMemoryAddress(address);

            switch (size) {
            case 0: // LDREX
                state->Reg[rd] = ReadMemory32T<ProfileOpcodes, BigEndian>(address);
                break;
            case 1: // LDREXD
                state->Reg[rd] = ReadMemory32T<ProfileOpcodes, BigEndian>(address);
                state->Reg[rd + 1] = ReadMemory32T<ProfileOpcodes, BigEndian>(address + 4);
                break;
            case 2: // LDREXB
                state->Reg[rd] = ReadMemory8T<ProfileOpcodes>(address);
                break;
            case 3: // LDREXH
                state->Reg[rd] = ReadMemory16T<ProfileOpcodes, BigEndian>(address);
                break;
            default:
                result.needs_fallback = true;
                goto block_done;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmExclusiveStore: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const u32 size = (op.arg0 >> 8) & 0x3;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 address = state->Reg[rn];
            const bool exclusive = state->IsExclusiveMemoryAccess(address);
            if (exclusive) {
                state->UnsetExclusiveMemoryAddress();
                switch (size) {
                case 0: // STREX
                    WriteMemory32T<ProfileOpcodes, BigEndian>(address, state->Reg[rm]);
                    break;
                case 1: { // STREXD
                    const u64 value =
                        BigEndian
                            ? ((static_cast<u64>(state->Reg[rm]) << 32) | state->Reg[rm + 1])
                            : ((static_cast<u64>(state->Reg[rm + 1]) << 32) | state->Reg[rm]);
                    WriteMemory64T<ProfileOpcodes, BigEndian>(address, value);
                    break;
                }
                case 2: // STREXB
                    WriteMemory8T<ProfileOpcodes>(address, static_cast<u8>(state->Reg[rm]));
                    break;
                case 3: // STREXH
                    WriteMemory16T<ProfileOpcodes, BigEndian>(
                        address, static_cast<u16>(state->Reg[rm]));
                    break;
                default:
                    result.needs_fallback = true;
                    goto block_done;
                }
            }
            state->Reg[rd] = exclusive ? 0 : 1;

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmVFPRegisterTransfer: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool to_arm = ((op.arg0 >> 8) & 1) != 0;
            const bool pair_transfer = ((op.arg0 >> 9) & 1) != 0;
            const u32 rt = op.arg1 & 0xF;
            const u32 rt2 = (op.arg1 >> 8) & 0xF;
            const u32 ext_reg = pair_transfer ? op.arg2 : ((op.arg1 >> 8) & 0x3F);
            if (to_arm) {
                state->Reg[rt] = state->ExtReg[ext_reg];
                if (pair_transfer) {
                    state->Reg[rt2] = state->ExtReg[ext_reg + 1];
                }
            } else {
                state->ExtReg[ext_reg] = state->Reg[rt];
                if (pair_transfer) {
                    state->ExtReg[ext_reg + 1] = state->Reg[rt2];
                }
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmVFPRegisterTransferAlways: {
            const bool to_arm = ((op.arg0 >> 8) & 1) != 0;
            const bool pair_transfer = ((op.arg0 >> 9) & 1) != 0;
            const u32 rt = op.arg1 & 0xF;
            const u32 rt2 = (op.arg1 >> 8) & 0xF;
            const u32 ext_reg = pair_transfer ? op.arg2 : ((op.arg1 >> 8) & 0x3F);
            if (to_arm) {
                state->Reg[rt] = state->ExtReg[ext_reg];
                if (pair_transfer) {
                    state->Reg[rt2] = state->ExtReg[ext_reg + 1];
                }
            } else {
                state->ExtReg[ext_reg] = state->Reg[rt];
                if (pair_transfer) {
                    state->ExtReg[ext_reg + 1] = state->Reg[rt2];
                }
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmVFPSystemRegisterTransfer: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool read_from_vfp = ((op.arg0 >> 8) & 1) != 0;
            const u32 vfp_register = op.arg1 & 0xF;
            const u32 rt = (op.arg1 >> 8) & 0xF;
            if (read_from_vfp) {
                switch (vfp_register) {
                case 0:
                    state->Reg[rt] = state->VFP[VFP_FPSID];
                    break;
                case 1:
                    if (rt == 15) {
                        const u32 fpscr = state->VFP[VFP_FPSCR];
                        ClearLazyFlags();
                        state->NFlag = (fpscr >> 31) & 1;
                        state->ZFlag = (fpscr >> 30) & 1;
                        state->CFlag = (fpscr >> 29) & 1;
                        state->VFlag = (fpscr >> 28) & 1;
                    } else {
                        state->Reg[rt] = state->VFP[VFP_FPSCR];
                    }
                    break;
                case 6:
                    state->Reg[rt] = state->VFP[VFP_MVFR1];
                    break;
                case 7:
                    state->Reg[rt] = state->VFP[VFP_MVFR0];
                    break;
                case 8:
                    if (state->InAPrivilegedMode()) {
                        state->Reg[rt] = state->VFP[VFP_FPEXC];
                    }
                    break;
                case 9:
                    if (state->InAPrivilegedMode()) {
                        state->Reg[rt] = state->VFP[VFP_FPINST];
                    }
                    break;
                case 10:
                    if (state->InAPrivilegedMode()) {
                        state->Reg[rt] = state->VFP[VFP_FPINST2];
                    }
                    break;
                default:
                    break;
                }
            } else {
                switch (vfp_register) {
                case 1:
                    state->VFP[VFP_FPSCR] = state->Reg[rt];
                    break;
                case 8:
                    if (state->InAPrivilegedMode()) {
                        state->VFP[VFP_FPEXC] = state->Reg[rt];
                    }
                    break;
                case 9:
                    if (state->InAPrivilegedMode()) {
                        state->VFP[VFP_FPINST] = state->Reg[rt];
                    }
                    break;
                case 10:
                    if (state->InAPrivilegedMode()) {
                        state->VFP[VFP_FPINST2] = state->Reg[rt];
                    }
                    break;
                default:
                    break;
                }
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmVFPLoadStore: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool load = ((op.arg0 >> 8) & 1) != 0;
            const bool single = ((op.arg0 >> 9) & 1) != 0;
            const bool add_offset = ((op.arg0 >> 10) & 1) != 0;
            const bool multiple = ((op.arg0 >> 11) & 1) != 0;
            const bool writeback = ((op.arg0 >> 12) & 1) != 0;
            const u32 rn = op.arg1 & 0xF;
            const u32 ext_reg = (op.arg1 >> 8) & 0x3F;
            const u32 old_base = state->Reg[rn];
            const u32 base = rn == 15 ? ((old_base & 0xFFFFFFFC) + 8) : old_base;
            u32 address = add_offset ? (base + op.arg2) : (base - op.arg2);

            if (multiple) {
                address = add_offset ? base : (base - op.arg2);
                const u32 register_words = op.arg2 / 4;
                for (u32 i = 0; i < register_words;) {
                    if (single) {
                        if (load) {
                            state->ExtReg[ext_reg + i] =
                                ReadMemory32T<ProfileOpcodes, BigEndian>(address);
                        } else {
                            WriteMemory32T<ProfileOpcodes, BigEndian>(
                                address, state->ExtReg[ext_reg + i]);
                        }
                        address += 4;
                        i++;
                    } else {
                        if (load) {
                            const u32 word1 = ReadMemory32T<ProfileOpcodes, BigEndian>(address);
                            const u32 word2 = ReadMemory32T<ProfileOpcodes, BigEndian>(address + 4);
                            if constexpr (BigEndian) {
                                state->ExtReg[ext_reg + i] = word2;
                                state->ExtReg[ext_reg + i + 1] = word1;
                            } else {
                                state->ExtReg[ext_reg + i] = word1;
                                state->ExtReg[ext_reg + i + 1] = word2;
                            }
                        } else {
                            const u32 word1 = state->ExtReg[ext_reg + i];
                            const u32 word2 = state->ExtReg[ext_reg + i + 1];
                            if constexpr (BigEndian) {
                                WriteMemory32T<ProfileOpcodes, BigEndian>(address, word2);
                                WriteMemory32T<ProfileOpcodes, BigEndian>(address + 4, word1);
                            } else {
                                WriteMemory32T<ProfileOpcodes, BigEndian>(address, word1);
                                WriteMemory32T<ProfileOpcodes, BigEndian>(address + 4, word2);
                            }
                        }
                        address += 8;
                        i += 2;
                    }
                }
                if (writeback) {
                    state->Reg[rn] = add_offset ? (old_base + op.arg2) : (old_base - op.arg2);
                }
            } else if (single) {
                if (load) {
                    state->ExtReg[ext_reg] = ReadMemory32T<ProfileOpcodes, BigEndian>(address);
                } else {
                    WriteMemory32T<ProfileOpcodes, BigEndian>(address, state->ExtReg[ext_reg]);
                }
            } else if (load) {
                const u32 word1 = ReadMemory32T<ProfileOpcodes, BigEndian>(address);
                const u32 word2 = ReadMemory32T<ProfileOpcodes, BigEndian>(address + 4);
                if constexpr (BigEndian) {
                    state->ExtReg[ext_reg] = word2;
                    state->ExtReg[ext_reg + 1] = word1;
                } else {
                    state->ExtReg[ext_reg] = word1;
                    state->ExtReg[ext_reg + 1] = word2;
                }
            } else {
                const u32 word1 = state->ExtReg[ext_reg];
                const u32 word2 = state->ExtReg[ext_reg + 1];
                if constexpr (BigEndian) {
                    WriteMemory32T<ProfileOpcodes, BigEndian>(address, word2);
                    WriteMemory32T<ProfileOpcodes, BigEndian>(address + 4, word1);
                } else {
                    WriteMemory32T<ProfileOpcodes, BigEndian>(address, word1);
                    WriteMemory32T<ProfileOpcodes, BigEndian>(address + 4, word2);
                }
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmVFPLoadSingleFast: {
            const bool add_offset = (op.arg0 & 1) != 0;
            const u32 rn = op.arg1 & 0xF;
            const u32 ext_reg = (op.arg1 >> 8) & 0x3F;
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + op.arg2) : (base - op.arg2);
            state->ExtReg[ext_reg] = ReadMemory32T<ProfileOpcodes, BigEndian>(address);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmVFPStoreSingleFast: {
            const bool add_offset = (op.arg0 & 1) != 0;
            const u32 rn = op.arg1 & 0xF;
            const u32 ext_reg = (op.arg1 >> 8) & 0x3F;
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + op.arg2) : (base - op.arg2);
            WriteMemory32T<ProfileOpcodes, BigEndian>(address, state->ExtReg[ext_reg]);

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmVFPLoadDoubleFast: {
            const bool add_offset = (op.arg0 & 1) != 0;
            const u32 rn = op.arg1 & 0xF;
            const u32 ext_reg = (op.arg1 >> 8) & 0x3F;
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + op.arg2) : (base - op.arg2);

            if constexpr (!BigEndian) {
                if (const u8* page_pointer =
                        GetFastMemoryPointerForSpanT<ProfileOpcodes>(address, 8)) {
                    const u32 fast_offset = address & Memory::CITRA_PAGE_MASK;
                    CountFastmemHitT<ProfileOpcodes>(2);
                    state->ExtReg[ext_reg] = ReadUnaligned<u32>(&page_pointer[fast_offset]);
                    state->ExtReg[ext_reg + 1] =
                        ReadUnaligned<u32>(&page_pointer[fast_offset + 4]);

                    AdvancePC(*state, op);
                    result.instructions++;
                    break;
                }
            }

            const u32 word1 = ReadMemory32T<ProfileOpcodes, BigEndian>(address);
            const u32 word2 = ReadMemory32T<ProfileOpcodes, BigEndian>(address + 4);
            if constexpr (BigEndian) {
                state->ExtReg[ext_reg] = word2;
                state->ExtReg[ext_reg + 1] = word1;
            } else {
                state->ExtReg[ext_reg] = word1;
                state->ExtReg[ext_reg + 1] = word2;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmVFPStoreDoubleFast: {
            const bool add_offset = (op.arg0 & 1) != 0;
            const u32 rn = op.arg1 & 0xF;
            const u32 ext_reg = (op.arg1 >> 8) & 0x3F;
            const u32 base = ReadAddressRegister(*state, rn, op);
            const u32 address = add_offset ? (base + op.arg2) : (base - op.arg2);
            const u32 word1 = state->ExtReg[ext_reg];
            const u32 word2 = state->ExtReg[ext_reg + 1];

            if constexpr (!BigEndian) {
                if (u8* page_pointer = GetFastMemoryPointerForSpanT<ProfileOpcodes>(address, 8)) {
                    const u32 fast_offset = address & Memory::CITRA_PAGE_MASK;
                    CountFastmemHitT<ProfileOpcodes>(2);
                    WriteUnaligned(&page_pointer[fast_offset], word1);
                    WriteUnaligned(&page_pointer[fast_offset + 4], word2);

                    AdvancePC(*state, op);
                    result.instructions++;
                    break;
                }
            }

            if constexpr (BigEndian) {
                WriteMemory32T<ProfileOpcodes, BigEndian>(address, word2);
                WriteMemory32T<ProfileOpcodes, BigEndian>(address + 4, word1);
            } else {
                WriteMemory32T<ProfileOpcodes, BigEndian>(address, word1);
                WriteMemory32T<ProfileOpcodes, BigEndian>(address + 4, word2);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmVFPLoadMultipleFast: {
            const bool single = (op.arg0 & 1) != 0;
            const bool add_offset = ((op.arg0 >> 1) & 1) != 0;
            const bool writeback = ((op.arg0 >> 2) & 1) != 0;
            const u32 rn = op.arg1 & 0xF;
            const u32 ext_reg = (op.arg1 >> 8) & 0x3F;
            const u32 old_base = state->Reg[rn];
            const u32 address = add_offset ? old_base : (old_base - op.arg2);
            const u32 register_words = op.arg2 / 4;

            if constexpr (!BigEndian) {
                if (const u8* page_pointer =
                        GetFastMemoryPointerForSpanT<ProfileOpcodes>(address, op.arg2)) {
                    u32 fast_offset = address & Memory::CITRA_PAGE_MASK;
                    CountFastmemHitT<ProfileOpcodes>(register_words);
                    if (single) {
                        for (u32 i = 0; i < register_words; ++i) {
                            state->ExtReg[ext_reg + i] =
                                ReadUnaligned<u32>(&page_pointer[fast_offset]);
                            fast_offset += 4;
                        }
                    } else {
                        for (u32 i = 0; i < register_words; i += 2) {
                            state->ExtReg[ext_reg + i] =
                                ReadUnaligned<u32>(&page_pointer[fast_offset]);
                            state->ExtReg[ext_reg + i + 1] =
                                ReadUnaligned<u32>(&page_pointer[fast_offset + 4]);
                            fast_offset += 8;
                        }
                    }

                    if (writeback) {
                        state->Reg[rn] =
                            add_offset ? (old_base + op.arg2) : (old_base - op.arg2);
                    }
                    AdvancePC(*state, op);
                    result.instructions++;
                    break;
                }
            }

            u32 current_address = address;
            for (u32 i = 0; i < register_words;) {
                if (single) {
                    state->ExtReg[ext_reg + i] =
                        ReadMemory32T<ProfileOpcodes, BigEndian>(current_address);
                    current_address += 4;
                    i++;
                } else {
                    const u32 word1 = ReadMemory32T<ProfileOpcodes, BigEndian>(current_address);
                    const u32 word2 = ReadMemory32T<ProfileOpcodes, BigEndian>(current_address + 4);
                    if constexpr (BigEndian) {
                        state->ExtReg[ext_reg + i] = word2;
                        state->ExtReg[ext_reg + i + 1] = word1;
                    } else {
                        state->ExtReg[ext_reg + i] = word1;
                        state->ExtReg[ext_reg + i + 1] = word2;
                    }
                    current_address += 8;
                    i += 2;
                }
            }
            if (writeback) {
                state->Reg[rn] = add_offset ? (old_base + op.arg2) : (old_base - op.arg2);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmVFPStoreMultipleFast: {
            const bool single = (op.arg0 & 1) != 0;
            const bool add_offset = ((op.arg0 >> 1) & 1) != 0;
            const bool writeback = ((op.arg0 >> 2) & 1) != 0;
            const u32 rn = op.arg1 & 0xF;
            const u32 ext_reg = (op.arg1 >> 8) & 0x3F;
            const u32 old_base = state->Reg[rn];
            const u32 address = add_offset ? old_base : (old_base - op.arg2);
            const u32 register_words = op.arg2 / 4;

            if constexpr (!BigEndian) {
                if (u8* page_pointer =
                        GetFastMemoryPointerForSpanT<ProfileOpcodes>(address, op.arg2)) {
                    u32 fast_offset = address & Memory::CITRA_PAGE_MASK;
                    CountFastmemHitT<ProfileOpcodes>(register_words);
                    if (single) {
                        for (u32 i = 0; i < register_words; ++i) {
                            WriteUnaligned(&page_pointer[fast_offset],
                                           state->ExtReg[ext_reg + i]);
                            fast_offset += 4;
                        }
                    } else {
                        for (u32 i = 0; i < register_words; i += 2) {
                            WriteUnaligned(&page_pointer[fast_offset],
                                           state->ExtReg[ext_reg + i]);
                            WriteUnaligned(&page_pointer[fast_offset + 4],
                                           state->ExtReg[ext_reg + i + 1]);
                            fast_offset += 8;
                        }
                    }

                    if (writeback) {
                        state->Reg[rn] =
                            add_offset ? (old_base + op.arg2) : (old_base - op.arg2);
                    }
                    AdvancePC(*state, op);
                    result.instructions++;
                    break;
                }
            }

            u32 current_address = address;
            for (u32 i = 0; i < register_words;) {
                if (single) {
                    WriteMemory32T<ProfileOpcodes, BigEndian>(
                        current_address, state->ExtReg[ext_reg + i]);
                    current_address += 4;
                    i++;
                } else {
                    const u32 word1 = state->ExtReg[ext_reg + i];
                    const u32 word2 = state->ExtReg[ext_reg + i + 1];
                    if constexpr (BigEndian) {
                        WriteMemory32T<ProfileOpcodes, BigEndian>(current_address, word2);
                        WriteMemory32T<ProfileOpcodes, BigEndian>(current_address + 4, word1);
                    } else {
                        WriteMemory32T<ProfileOpcodes, BigEndian>(current_address, word1);
                        WriteMemory32T<ProfileOpcodes, BigEndian>(current_address + 4, word2);
                    }
                    current_address += 8;
                    i += 2;
                }
            }
            if (writeback) {
                state->Reg[rn] = add_offset ? (old_base + op.arg2) : (old_base - op.arg2);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmVFPDataProcessing: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            ARMul_State* raw_state = state.get();
            const u32 mode = (op.arg0 >> 8) & 0x3;
            if (mode == 1) {
                VMOVI(raw_state, (op.arg0 >> 10) & 1, op.arg1, op.arg2);
            } else if (mode == 2) {
                VMOVR(raw_state, (op.arg0 >> 10) & 1, op.arg1, op.arg2);
            } else {
                const u32 instruction = op.arg1;
                const u32 fpscr = state->VFP[VFP_FPSCR];
                std::optional<u32> exceptions;
                if (Settings::values.use_vfp_hostfp.GetValue())
                    exceptions = VfpHost::TryExecute(raw_state, instruction, fpscr);
                if (!exceptions) {
                    exceptions = ((instruction >> 8) & 1) != 0
                                     ? vfp_double_cpdo(raw_state, instruction, fpscr)
                                     : vfp_single_cpdo(raw_state, instruction, fpscr);
                }
                vfp_raise_exceptions(raw_state, *exceptions, instruction,
                                     state->VFP[VFP_FPSCR]);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmVFPDataProcessingAlways: {
            ARMul_State* raw_state = state.get();
            const u32 mode = (op.arg0 >> 8) & 0x3;
            if (mode == 1) {
                VMOVI(raw_state, (op.arg0 >> 10) & 1, op.arg1, op.arg2);
            } else if (mode == 2) {
                VMOVR(raw_state, (op.arg0 >> 10) & 1, op.arg1, op.arg2);
            } else {
                const u32 instruction = op.arg1;
                const u32 fpscr = state->VFP[VFP_FPSCR];
                std::optional<u32> exceptions;
                if (Settings::values.use_vfp_hostfp.GetValue())
                    exceptions = VfpHost::TryExecute(raw_state, instruction, fpscr);
                if (!exceptions) {
                    exceptions = ((instruction >> 8) & 1) != 0
                                     ? vfp_double_cpdo(raw_state, instruction, fpscr)
                                     : vfp_single_cpdo(raw_state, instruction, fpscr);
                }
                vfp_raise_exceptions(raw_state, *exceptions, instruction,
                                     state->VFP[VFP_FPSCR]);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCoprocessor15Transfer: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool read_from_coprocessor = ((op.arg0 >> 8) & 1) != 0;
            const u32 rd = op.arg1 & 0xF;
            const u32 crn = (op.arg1 >> 8) & 0xF;
            const u32 crm = (op.arg1 >> 16) & 0xF;
            const u32 opcode_1 = op.arg2 & 0x7;
            const u32 opcode_2 = (op.arg2 >> 8) & 0x7;

            if (read_from_coprocessor) {
                const u32 value = state->ReadCP15Register(crn, opcode_1, crm, opcode_2);
                if (rd == 15) {
                    SaveFlagsToCpsr();
                    state->Cpsr = (state->Cpsr & ~0xF0000000) | (value & 0xF0000000);
                    LoadFlagsFromCpsr();
                } else {
                    state->Reg[rd] = value;
                }
            } else {
                state->WriteCP15Register(state->Reg[rd], crn, opcode_1, crm, opcode_2);
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmCoprocessorDataProcessing: {
            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            state->NumInstrsToExecute = 0;
            result.instructions++;
            result.stop_execution = true;
            goto block_done;
        }
        case ARMIR::Opcode::ArmMoveStatusToRegister: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                break;
            }

            const bool source_spsr = ((op.arg0 >> 8) & 1) != 0;
            const u32 rd = op.arg1 & 0xF;
            if (source_spsr) {
                state->Reg[rd] = state->Spsr_copy;
            } else {
                SaveFlagsToCpsr();
                state->Reg[rd] = state->Cpsr;
            }

            AdvancePC(*state, op);
            result.instructions++;
            break;
        }
        case ARMIR::Opcode::ArmMoveRegisterToStatus: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                goto block_done;
            }

            constexpr u32 UserMask = 0xF80F0200;
            constexpr u32 PrivMask = 0x000001DF;
            constexpr u32 StateMask = 0x01000020;

            const bool destination_spsr = ((op.arg0 >> 8) & 1) != 0;
            const bool immediate_operand = ((op.arg0 >> 9) & 1) != 0;
            const u32 field_mask = op.arg1 & 0xF;
            const u32 operand = immediate_operand ? op.arg2 : state->Reg[op.arg2 & 0xF];
            const u32 byte_mask = ((field_mask & 1) != 0 ? 0x000000FF : 0) |
                                  ((field_mask & 2) != 0 ? 0x0000FF00 : 0) |
                                  ((field_mask & 4) != 0 ? 0x00FF0000 : 0) |
                                  ((field_mask & 8) != 0 ? 0xFF000000 : 0);

            if (destination_spsr) {
                if (state->CurrentModeHasSPSR()) {
                    const u32 mask = byte_mask & (UserMask | PrivMask | StateMask);
                    state->Spsr_copy = (state->Spsr_copy & ~mask) | (operand & mask);
                }
            } else {
                u32 mask = 0;
                if (state->InAPrivilegedMode()) {
                    if ((operand & StateMask) == 0) {
                        mask = byte_mask & (UserMask | PrivMask);
                    }
                } else {
                    mask = byte_mask & UserMask;
                }

                SaveFlagsToCpsr();
                state->Cpsr = (state->Cpsr & ~mask) | (operand & mask);
                state->ChangePrivilegeMode(state->Cpsr & 0x1F);
                LoadFlagsFromCpsr();
            }

            AdvancePC(*state, op);
            result.instructions++;
            goto block_done;
        }
        case ARMIR::Opcode::ArmSupervisorCall: {

            const u32 condition = op.arg0 & 0xF;
            if (condition != ConditionCode::AL && !ConditionPassed(condition)) {
                AdvancePC(*state, op);
                result.instructions++;
                goto block_done;
            }

            result.instructions++;
            result.supervisor_call = true;
            result.supervisor_call_immediate = op.arg1;
            result.supervisor_call_guest_size = op.guest_size;
            goto block_done;
        }
        case ARMIR::Opcode::Count:
            UNREACHABLE();
        }
    }
block_done:
#if defined(__OHOS__)
    {
        const std::size_t last_idx = op_index < op_count ? op_index : op_count - 1;
        const ARMIR::Op& last_op = block.ops[last_idx];
        IrTracePush(2, block.key.pc, block.key.cpsr_key, static_cast<u8>(block.thumb),
                    (static_cast<u32>(last_op.opcode) << 16) | static_cast<u32>(last_idx),
                    state->Reg[15], state->Cpsr, state->TFlag != 0);
    }
#endif
    if (block.terminal == ARMIR::Terminal::Fallback &&
        (block.fallback_reason == ARMIR::FallbackReason::UnsupportedInstruction ||
         block.fallback_reason == ARMIR::FallbackReason::DecodeFailure)) {
        result.stop_execution = true;
    } else {
        result.needs_fallback = block.terminal == ARMIR::Terminal::Fallback;
    }
    if (result.needs_fallback) {
        result.fallback_pc = block.fallback_pc;
        result.fallback_instruction = block.fallback_instruction;
        result.fallback_reason = static_cast<u32>(block.fallback_reason);
        result.fallback_thumb = block.thumb;
    }
    if (result.supervisor_call || result.stop_execution || result.needs_fallback) {
        return result;
    }
    // Chain boundary: mirror the exit conditions of the ExecuteIRInstructions
    // loop head, then resolve the next block through this block's link slots.
    // A link miss returns to the caller, which translates and records the link.
    if (result.instructions >= remaining_instructions || state->NumInstrsToExecute == 0 ||
        (!state->NirqSig && !(state->Cpsr & IBIT))) {
        if (current_block != &first_block) {
            // Report the real chain tail with a freshly computed successor
            // key: the caller's link math otherwise falls back to the entry
            // block, whose preserved cpsr_key could stamp the wrong
            // instruction-set state onto the tail block's successor.
            result.link_source = current_block;
            result.link_key = ARMIR::BlockCache::MakeKey(
                state->Reg[15], GetCpsrForBlockKey(), current_block_tag);
        }
        return result;
    }
    state->NumInstrsToExecute = remaining_instructions - result.instructions;
    const ARMIR::BlockKey next_key =
        block.direct_branch_preserves_cpsr_key
            ? MakeNextKeyWithPreservedCpsrKey(block, state->Reg[15])
            : ARMIR::BlockCache::MakeKey(state->Reg[15], GetCpsrForBlockKey(), current_block_tag);
    const ARMIR::Block* next_block = nullptr;
#if defined(__OHOS__)
    u32 link_via = 9;
#endif
    if (block_cache.IsBlockCurrent(block, next_key)) {
        next_block = &block;
#if defined(__OHOS__)
        link_via = 0;
#endif
        if (g_ir_profile_blocks) {
            g_ir_link_current.fetch_add(1, std::memory_order_relaxed);
        }
    } else {
        const ARMIR::BlockLink& last_link = block.links.last;
        if (last_link.valid && last_link.key == next_key) {
            next_block = last_link.block;
#if defined(__OHOS__)
            link_via = 1;
#endif
            if (g_ir_profile_blocks) {
                g_ir_link_last.fetch_add(1, std::memory_order_relaxed);
            }
        } else {
            next_block = ARMIR::BlockCache::LookupBlockLinkAfterLastMiss(block, next_key);
#if defined(__OHOS__)
            link_via = 2;
#endif
            if (next_block && g_ir_profile_blocks) {
                g_ir_link_slot.fetch_add(1, std::memory_order_relaxed);
            }
        }
    }
#if defined(__OHOS__)
    IrTracePush(3, next_key.pc, next_key.cpsr_key,
                static_cast<u8>(block.thumb),
                (block.key.pc) | (block.direct_branch_preserves_cpsr_key ? 0x80000000u : 0),
                link_via, state->Cpsr, state->TFlag != 0);
#endif
    // A tight self-branch is handled by the caller (it consumes the whole
    // remaining budget without executing), and a link miss needs translation.
    // Under !CheckRemaining a chained block always runs to completion, so
    // blocks that do not fit the remaining budget must also return — the
    // caller re-dispatches them through the CheckRemaining variant for exact
    // per-instruction accounting.
    if (!next_block || IsTightSelfBranch(*next_block) ||
        (!CheckRemaining &&
         next_block->guest_instruction_count >
             remaining_instructions - result.instructions)) {
        result.link_source = &block;
        result.link_key = next_key;
        return result;
    }
    current_block = next_block;
    goto chain_restart;
}

template ARM_IRInterpreter::IRBlockResult ARM_IRInterpreter::TryExecuteBlock<false, false, false>(
    const ARMIR::Block& block, u64 remaining_instructions,
    std::array<u64, ARMIR::OpcodeCount>* opcode_counts);
template ARM_IRInterpreter::IRBlockResult ARM_IRInterpreter::TryExecuteBlock<false, false, true>(
    const ARMIR::Block& block, u64 remaining_instructions,
    std::array<u64, ARMIR::OpcodeCount>* opcode_counts);
template ARM_IRInterpreter::IRBlockResult ARM_IRInterpreter::TryExecuteBlock<false, true, false>(
    const ARMIR::Block& block, u64 remaining_instructions,
    std::array<u64, ARMIR::OpcodeCount>* opcode_counts);
template ARM_IRInterpreter::IRBlockResult ARM_IRInterpreter::TryExecuteBlock<false, true, true>(
    const ARMIR::Block& block, u64 remaining_instructions,
    std::array<u64, ARMIR::OpcodeCount>* opcode_counts);
template ARM_IRInterpreter::IRBlockResult ARM_IRInterpreter::TryExecuteBlock<true, false, false>(
    const ARMIR::Block& block, u64 remaining_instructions,
    std::array<u64, ARMIR::OpcodeCount>* opcode_counts);
template ARM_IRInterpreter::IRBlockResult ARM_IRInterpreter::TryExecuteBlock<true, false, true>(
    const ARMIR::Block& block, u64 remaining_instructions,
    std::array<u64, ARMIR::OpcodeCount>* opcode_counts);
template ARM_IRInterpreter::IRBlockResult ARM_IRInterpreter::TryExecuteBlock<true, true, false>(
    const ARMIR::Block& block, u64 remaining_instructions,
    std::array<u64, ARMIR::OpcodeCount>* opcode_counts);
template ARM_IRInterpreter::IRBlockResult ARM_IRInterpreter::TryExecuteBlock<true, true, true>(
    const ARMIR::Block& block, u64 remaining_instructions,
    std::array<u64, ARMIR::OpcodeCount>* opcode_counts);
void ARM_IRInterpreter::HandleIRFallback(const IRExecutionResult& result,
                                         u64 requested_instructions) {
    ir_fallback_count++;
    const auto reason = static_cast<ARMIR::FallbackReason>(result.fallback_reason);
#if defined(__OHOS__)
    // stderr does not reach hilog on OHOS; mirror the abort context so the
    // fatal fallback reason is actually visible on device.
    OH_LOG_Print(LOG_APP, LOG_FATAL, 0x3203, "CitraAbort",
                 "IR fallback: reason=%{public}s pc=%{public}08X inst=%{public}08X "
                 "thumb=%{public}d executed=%{public}llu requested=%{public}llu",
                 FallbackReasonName(reason), result.fallback_pc,
                 result.fallback_instruction, static_cast<int>(result.fallback_thumb),
                 static_cast<unsigned long long>(result.instructions),
                 static_cast<unsigned long long>(requested_instructions));
    // hilog drops lines under load — persist the context to a file as well.
    if (FILE* f = IrAbortOpen()) {
        std::fprintf(f,
                     "IR fallback: reason=%s pc=%08X inst=%08X thumb=%d executed=%llu "
                     "requested=%llu t=%llu\n",
                     FallbackReasonName(reason), result.fallback_pc,
                     result.fallback_instruction, static_cast<int>(result.fallback_thumb),
                     static_cast<unsigned long long>(result.instructions),
                     static_cast<unsigned long long>(requested_instructions),
                     static_cast<unsigned long long>(
                         std::chrono::steady_clock::now().time_since_epoch().count()));
        IrTraceDump(f);
        std::fclose(f);
    }
#endif
    UNREACHABLE_MSG(
        "IR interpreter reached an unimplemented execution path: reason={} pc={:#010X} "
        "instruction={:#010X} thumb={} executed={} requested={}",
        FallbackReasonName(reason), result.fallback_pc, result.fallback_instruction,
        result.fallback_thumb, result.instructions, requested_instructions);
}

u8* ARM_IRInterpreter::GetFastMemoryPointer(u32 address) {
    return GetFastMemoryPointerUnprofiled(address);
}

u8* ARM_IRInterpreter::GetFastMemoryPointerUnprofiled(u32 address) {
    const u32 page = address >> Memory::CITRA_PAGE_BITS;
    if (current_fastmem_last_cache.valid && current_fastmem_last_cache.page == page) {
        return current_fastmem_last_cache.pointer;
    }
    if (current_fastmem_previous_cache.valid && current_fastmem_previous_cache.page == page) {
        std::swap(current_fastmem_last_cache, current_fastmem_previous_cache);
        return current_fastmem_last_cache.pointer;
    }

    FastmemCacheEntry& entry = current_fastmem_cache[FastmemCacheIndex(
        page, current_fastmem_cache.size())];
    if (entry.valid && entry.generation == current_fastmem_cache_generation &&
        entry.page == page) {
        current_fastmem_previous_cache = current_fastmem_last_cache;
        current_fastmem_last_cache = entry;
        return entry.pointer;
    }
    if (!current_page_table_raw) {
        return nullptr;
    }

    u8* page_pointer = current_page_table_raw->pointers[page];
    entry = {
        .page = page,
        .generation = current_fastmem_cache_generation,
        .pointer = page_pointer,
        .valid = true,
    };
    current_fastmem_previous_cache = current_fastmem_last_cache;
    current_fastmem_last_cache = entry;
    return page_pointer;
}

u8* ARM_IRInterpreter::GetFastMemoryPointerForSpan(u32 address, u32 bytes) {
    if (bytes == 0) {
        return GetFastMemoryPointer(address);
    }

    const u32 page_offset = address & Memory::CITRA_PAGE_MASK;
    if (bytes > Memory::CITRA_PAGE_SIZE || page_offset > Memory::CITRA_PAGE_SIZE - bytes) {
        return nullptr;
    }

    return GetFastMemoryPointer(address);
}

void ARM_IRInterpreter::RefreshFastmemCacheForCurrentPageTable() {
    std::shared_ptr<Memory::PageTable> active_page_table = state->memory.GetCurrentPageTable();
    if (active_page_table != current_page_table) {
        current_page_table = active_page_table;
        current_page_table_raw = current_page_table.get();
        current_fastmem_page_table_generation =
            current_page_table_raw ? current_page_table_raw->GetFastmemGeneration() : 0;
        ResetFastmemCache();
        return;
    }

    if (!current_page_table_raw) {
        current_fastmem_page_table_generation = 0;
        ResetFastmemCache();
        return;
    }

    const u64 generation = current_page_table_raw->GetFastmemGeneration();
    if (generation != current_fastmem_page_table_generation) {
        current_fastmem_page_table_generation = generation;
        ResetFastmemCache();
    }
}

void ARM_IRInterpreter::ResetFastmemCache() {
    current_fastmem_last_cache = {};
    current_fastmem_previous_cache = {};
    current_fastmem_cache_generation++;
    if (current_fastmem_cache_generation == 0) {
        current_fastmem_cache = {};
        current_fastmem_cache_generation = 1;
    }
}

bool ARM_IRInterpreter::TryFastReadMemory32(u32 address, u32& value) {
    if (current_big_endian) {
        return false;
    }
    if (const u8* page_pointer = GetFastMemoryPointer(address)) {
        CountFastmemHit();
        value = ReadUnaligned<u32>(&page_pointer[address & Memory::CITRA_PAGE_MASK]);
        return true;
    }
    return false;
}

bool ARM_IRInterpreter::TryFastWriteMemory32(u32 address, u32 value) {
    if (current_big_endian) {
        return false;
    }
    if (u8* page_pointer = GetFastMemoryPointer(address)) {
        CountFastmemHit();
        WriteUnaligned(&page_pointer[address & Memory::CITRA_PAGE_MASK], value);
        return true;
    }
    return false;
}

bool ARM_IRInterpreter::TryFastReadMemory16(u32 address, u16& value) {
    if (current_big_endian) {
        return false;
    }
    if (const u8* page_pointer = GetFastMemoryPointer(address)) {
        CountFastmemHit();
        value = ReadUnaligned<u16>(&page_pointer[address & Memory::CITRA_PAGE_MASK]);
        return true;
    }
    return false;
}

bool ARM_IRInterpreter::TryFastWriteMemory16(u32 address, u16 value) {
    if (current_big_endian) {
        return false;
    }
    if (u8* page_pointer = GetFastMemoryPointer(address)) {
        CountFastmemHit();
        WriteUnaligned(&page_pointer[address & Memory::CITRA_PAGE_MASK], value);
        return true;
    }
    return false;
}

u8 ARM_IRInterpreter::ReadMemory8(u32 address) {
    if (const u8* page_pointer = GetFastMemoryPointer(address)) {
        CountFastmemHit();
        return page_pointer[address & Memory::CITRA_PAGE_MASK];
    }
    CountFastmemFallback();
    return state->ReadMemory8(address);
}

u16 ARM_IRInterpreter::ReadMemory16(u32 address) {
    if (!current_big_endian) {
        if (const u8* page_pointer = GetFastMemoryPointer(address)) {
            CountFastmemHit();
            return ReadUnaligned<u16>(&page_pointer[address & Memory::CITRA_PAGE_MASK]);
        }
    }
    CountFastmemFallback();
    return state->ReadMemory16(address);
}

u32 ARM_IRInterpreter::ReadMemory32(u32 address) {
    if (!current_big_endian) {
        if (const u8* page_pointer = GetFastMemoryPointer(address)) {
            CountFastmemHit();
            return ReadUnaligned<u32>(&page_pointer[address & Memory::CITRA_PAGE_MASK]);
        }
    }
    CountFastmemFallback();
    return state->ReadMemory32(address);
}

void ARM_IRInterpreter::WriteMemory8(u32 address, u8 value) {
    if (u8* page_pointer = GetFastMemoryPointer(address)) {
        CountFastmemHit();
        page_pointer[address & Memory::CITRA_PAGE_MASK] = value;
        return;
    }
    CountFastmemFallback();
    state->WriteMemory8(address, value);
}

void ARM_IRInterpreter::WriteMemory16(u32 address, u16 value) {
    if (!current_big_endian) {
        if (u8* page_pointer = GetFastMemoryPointer(address)) {
            CountFastmemHit();
            WriteUnaligned(&page_pointer[address & Memory::CITRA_PAGE_MASK], value);
            return;
        }
    }
    CountFastmemFallback();
    state->WriteMemory16(address, value);
}

void ARM_IRInterpreter::WriteMemory32(u32 address, u32 value) {
    if (!current_big_endian) {
        if (u8* page_pointer = GetFastMemoryPointer(address)) {
            CountFastmemHit();
            WriteUnaligned(&page_pointer[address & Memory::CITRA_PAGE_MASK], value);
            return;
        }
    }
    CountFastmemFallback();
    state->WriteMemory32(address, value);
}

void ARM_IRInterpreter::WriteMemory64(u32 address, u64 value) {
    if (!current_big_endian) {
        if (u8* page_pointer = GetFastMemoryPointer(address)) {
            CountFastmemHit();
            WriteUnaligned(&page_pointer[address & Memory::CITRA_PAGE_MASK], value);
            return;
        }
    }
    CountFastmemFallback();
    state->WriteMemory64(address, value);
}

void ARM_IRInterpreter::LoadFlagsFromCpsr() {
    ClearLazyFlags();
    state->NFlag = state->Cpsr >> 31;
    state->ZFlag = (state->Cpsr >> 30) & 1;
    state->CFlag = (state->Cpsr >> 29) & 1;
    state->VFlag = (state->Cpsr >> 28) & 1;
    IR_TRACE_TFLAG((state->Cpsr >> 5) & 1, 16);
    current_big_endian = (state->Cpsr & EBIT) != 0;
}

void ARM_IRInterpreter::SaveFlagsToCpsr() {
    FlushLazyFlags();
    state->Cpsr = (state->Cpsr & 0x0FFFFFDF) | (state->NFlag << 31) | (state->ZFlag << 30) |
                  (state->CFlag << 29) | (state->VFlag << 28) | (state->TFlag << 5);
}

void ARM_IRInterpreter::ClearLazyFlags() {
    lazy_flags = {};
}

void ARM_IRInterpreter::FlushLazyFlags() {
    if (!lazy_flags.valid) {
        return;
    }
    CountLazyFlagMaterialization();
    if ((lazy_flags.mask & LazyFlagN) != 0) {
        state->NFlag = lazy_flags.n;
    }
    if ((lazy_flags.mask & LazyFlagZ) != 0) {
        state->ZFlag = lazy_flags.z;
    }
    if ((lazy_flags.mask & LazyFlagC) != 0) {
        state->CFlag = lazy_flags.c;
    }
    if ((lazy_flags.mask & LazyFlagV) != 0) {
        state->VFlag = lazy_flags.v;
    }
    ClearLazyFlags();
}

void ARM_IRInterpreter::SetLazyNZFlags(u32 result) {
    SetLazyNZFlags((result >> 31) != 0, result == 0);
}

void ARM_IRInterpreter::SetLazyNZFlags(u32 n, u32 z) {
    const u8 preserved_mask =
        lazy_flags.valid ? (lazy_flags.mask & (LazyFlagC | LazyFlagV)) : 0;
    const u32 old_c = lazy_flags.c;
    const u32 old_v = lazy_flags.v;
    CountLazyFlagWrite();
    lazy_flags.valid = true;
    lazy_flags.mask = LazyFlagNZ | preserved_mask;
    lazy_flags.n = n != 0;
    lazy_flags.z = z != 0;
    if ((preserved_mask & LazyFlagC) != 0) {
        lazy_flags.c = old_c;
    }
    if ((preserved_mask & LazyFlagV) != 0) {
        lazy_flags.v = old_v;
    }
}

void ARM_IRInterpreter::SetLazyLogicalFlags(u32 result, bool carry) {
    const bool preserve_v = lazy_flags.valid && ((lazy_flags.mask & LazyFlagV) != 0);
    const u32 old_v = lazy_flags.v;
    CountLazyFlagWrite();
    lazy_flags.valid = true;
    lazy_flags.mask = LazyFlagNZC | (preserve_v ? LazyFlagV : 0);
    lazy_flags.n = (result >> 31) != 0;
    lazy_flags.z = result == 0;
    lazy_flags.c = carry;
    if (preserve_v) {
        lazy_flags.v = old_v;
    }
}

void ARM_IRInterpreter::SetLazyArithmeticFlags(u32 result, bool carry, bool overflow) {
    CountLazyFlagWrite();
    lazy_flags.valid = true;
    lazy_flags.mask = LazyFlagNZCV;
    lazy_flags.n = (result >> 31) != 0;
    lazy_flags.z = result == 0;
    lazy_flags.c = carry;
    lazy_flags.v = overflow;
}

FORCE_INLINE bool ARM_IRInterpreter::ReadNFlag() const {
    return lazy_flags.valid && ((lazy_flags.mask & LazyFlagN) != 0) ? lazy_flags.n != 0
                                                                    : state->NFlag != 0;
}

FORCE_INLINE bool ARM_IRInterpreter::ReadZFlag() const {
    return lazy_flags.valid && ((lazy_flags.mask & LazyFlagZ) != 0) ? lazy_flags.z != 0
                                                                    : state->ZFlag != 0;
}

FORCE_INLINE bool ARM_IRInterpreter::ReadCFlag() const {
    return lazy_flags.valid && ((lazy_flags.mask & LazyFlagC) != 0) ? lazy_flags.c != 0
                                                                    : state->CFlag != 0;
}

FORCE_INLINE bool ARM_IRInterpreter::ReadVFlag() const {
    return lazy_flags.valid && ((lazy_flags.mask & LazyFlagV) != 0) ? lazy_flags.v != 0
                                                                    : state->VFlag != 0;
}

FORCE_INLINE bool ARM_IRInterpreter::ConditionFailed(u32 condition) const {
    return condition != ConditionCode::AL && !ConditionPassed(condition);
}

FORCE_INLINE bool ARM_IRInterpreter::ConditionPassed(u32 condition) const {
    const bool lazy_valid = lazy_flags.valid;
    const u8 lazy_mask = lazy_flags.mask;
    if (condition < ConditionCode::AL && lazy_valid &&
        (lazy_mask & LazyFlagNZCV) == LazyFlagNZCV) {
        return ConditionPassedFromFlags(condition, lazy_flags.n != 0, lazy_flags.z != 0,
                                        lazy_flags.c != 0, lazy_flags.v != 0);
    }

    switch (condition) {
    case ConditionCode::EQ: {
        const bool z = lazy_valid && ((lazy_mask & LazyFlagZ) != 0) ? lazy_flags.z != 0
                                                                    : state->ZFlag != 0;
        return z;
    }
    case ConditionCode::NE: {
        const bool z = lazy_valid && ((lazy_mask & LazyFlagZ) != 0) ? lazy_flags.z != 0
                                                                    : state->ZFlag != 0;
        return !z;
    }
    case ConditionCode::CS: {
        const bool c = lazy_valid && ((lazy_mask & LazyFlagC) != 0) ? lazy_flags.c != 0
                                                                    : state->CFlag != 0;
        return c;
    }
    case ConditionCode::CC: {
        const bool c = lazy_valid && ((lazy_mask & LazyFlagC) != 0) ? lazy_flags.c != 0
                                                                    : state->CFlag != 0;
        return !c;
    }
    case ConditionCode::MI: {
        const bool n = lazy_valid && ((lazy_mask & LazyFlagN) != 0) ? lazy_flags.n != 0
                                                                    : state->NFlag != 0;
        return n;
    }
    case ConditionCode::PL: {
        const bool n = lazy_valid && ((lazy_mask & LazyFlagN) != 0) ? lazy_flags.n != 0
                                                                    : state->NFlag != 0;
        return !n;
    }
    case ConditionCode::VS: {
        const bool v = lazy_valid && ((lazy_mask & LazyFlagV) != 0) ? lazy_flags.v != 0
                                                                    : state->VFlag != 0;
        return v;
    }
    case ConditionCode::VC: {
        const bool v = lazy_valid && ((lazy_mask & LazyFlagV) != 0) ? lazy_flags.v != 0
                                                                    : state->VFlag != 0;
        return !v;
    }
    case ConditionCode::HI: {
        const bool c = lazy_valid && ((lazy_mask & LazyFlagC) != 0) ? lazy_flags.c != 0
                                                                    : state->CFlag != 0;
        if (!c) {
            return false;
        }
        const bool z = lazy_valid && ((lazy_mask & LazyFlagZ) != 0) ? lazy_flags.z != 0
                                                                    : state->ZFlag != 0;
        return !z;
    }
    case ConditionCode::LS: {
        const bool c = lazy_valid && ((lazy_mask & LazyFlagC) != 0) ? lazy_flags.c != 0
                                                                    : state->CFlag != 0;
        if (!c) {
            return true;
        }
        const bool z = lazy_valid && ((lazy_mask & LazyFlagZ) != 0) ? lazy_flags.z != 0
                                                                    : state->ZFlag != 0;
        return z;
    }
    case ConditionCode::GE: {
        const bool n = lazy_valid && ((lazy_mask & LazyFlagN) != 0) ? lazy_flags.n != 0
                                                                    : state->NFlag != 0;
        const bool v = lazy_valid && ((lazy_mask & LazyFlagV) != 0) ? lazy_flags.v != 0
                                                                    : state->VFlag != 0;
        return n == v;
    }
    case ConditionCode::LT: {
        const bool n = lazy_valid && ((lazy_mask & LazyFlagN) != 0) ? lazy_flags.n != 0
                                                                    : state->NFlag != 0;
        const bool v = lazy_valid && ((lazy_mask & LazyFlagV) != 0) ? lazy_flags.v != 0
                                                                    : state->VFlag != 0;
        return n != v;
    }
    case ConditionCode::GT: {
        const bool z = lazy_valid && ((lazy_mask & LazyFlagZ) != 0) ? lazy_flags.z != 0
                                                                    : state->ZFlag != 0;
        if (z) {
            return false;
        }
        const bool n = lazy_valid && ((lazy_mask & LazyFlagN) != 0) ? lazy_flags.n != 0
                                                                    : state->NFlag != 0;
        const bool v = lazy_valid && ((lazy_mask & LazyFlagV) != 0) ? lazy_flags.v != 0
                                                                    : state->VFlag != 0;
        return n == v;
    }
    case ConditionCode::LE: {
        const bool z = lazy_valid && ((lazy_mask & LazyFlagZ) != 0) ? lazy_flags.z != 0
                                                                    : state->ZFlag != 0;
        if (z) {
            return true;
        }
        const bool n = lazy_valid && ((lazy_mask & LazyFlagN) != 0) ? lazy_flags.n != 0
                                                                    : state->NFlag != 0;
        const bool v = lazy_valid && ((lazy_mask & LazyFlagV) != 0) ? lazy_flags.v != 0
                                                                    : state->VFlag != 0;
        return n != v;
    }
    default:
        return condition == ConditionCode::AL || condition == ConditionCode::NV;
    }
}

FORCE_INLINE bool ARM_IRInterpreter::ConditionPassedOrAlways(u32 condition) const {
    return condition == ConditionCode::AL || ConditionPassed(condition);
}

} // namespace Core
