// Copyright Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#include "core/arm/ir/arm_ir_cache.h"

#include <bit>
#include <limits>
#include <utility>

#include "core/arm/dyncom/arm_dyncom_thumb.h"
#include "core/arm/ir/arm_ir_interpreter.h"
#include "core/arm/skyeye_common/armstate.h"
#include "core/memory.h"

namespace Core::ARMIR {

namespace {

u32 RotateRight(u32 value, u32 amount) {
    amount &= 31;
    return amount == 0 ? value : ((value >> amount) | (value << (32 - amount)));
}

u32 CountBits(u32 value) {
    return static_cast<u32>(std::popcount(value));
}

u32 Bits(u32 value, u32 first, u32 last) {
    const u32 width = last - first + 1;
    return (value >> first) & ((1U << width) - 1);
}

bool IsSupportedVFPDataProcessingInstruction(u32 instruction) {
    if (Bits(instruction, 9, 11) != 0x5 || Bits(instruction, 4, 4) != 0) {
        return false;
    }

    const u32 major = Bits(instruction, 23, 27);
    if (major == 0x1C) {
        return true;
    }
    if (major != 0x1D) {
        return false;
    }

    constexpr u32 VfpFopMask = 0x00B00040;
    constexpr u32 VfpFdiv = 0x00800000;
    constexpr u32 VfpFext = 0x00B00040;
    const u32 fop = instruction & VfpFopMask;
    if (fop == VfpFdiv) {
        return true;
    }
    if (fop != VfpFext) {
        return false;
    }

    const u32 fext_index = ((instruction & 0x000F0000) >> 15) | ((instruction & (1U << 7)) >> 7);
    switch (fext_index) {
    case 1:  // FABS
    case 2:  // FNEG
    case 3:  // FSQRT
    case 8:  // FCMP
    case 9:  // FCMPE
    case 10: // FCMPZ
    case 11: // FCMPEZ
    case 15: // FCVT between single and double
    case 16: // FUITO
    case 17: // FSITO
    case 24: // FTOUI
    case 25: // FTOUIZ
    case 26: // FTOSI
    case 27: // FTOSIZ
        return true;
    default:
        return false;
    }
}

bool DataProcessingWritesResult(u32 data_opcode) {
    switch (data_opcode) {
    case 0:  // AND
    case 1:  // EOR
    case 2:  // SUB
    case 3:  // RSB
    case 4:  // ADD
    case 5:  // ADC
    case 6:  // SBC
    case 7:  // RSC
    case 12: // ORR
    case 14: // BIC
    case 13: // MOV
    case 15: // MVN
        return true;
    default:
        return false;
    }
}

bool DataProcessingWritesPc(u32 data_opcode, [[maybe_unused]] bool set_flags, u32 rd) {
    return rd == 15 && DataProcessingWritesResult(data_opcode);
}

bool IsSupportedDataProcessing(u32 data_opcode, bool set_flags, [[maybe_unused]] u32 rn, u32 rd) {
    switch (data_opcode) {
    case 0:  // AND
    case 1:  // EOR
    case 2:  // SUB
    case 3:  // RSB
    case 4:  // ADD
    case 5:  // ADC
    case 6:  // SBC
    case 7:  // RSC
    case 12: // ORR
    case 14: // BIC
    case 13: // MOV
    case 15: // MVN
        return true;
    case 8:  // TST
    case 9:  // TEQ
    case 10: // CMP
    case 11: // CMN
        return set_flags;
    default:
        return false;
    }
}

bool IsFastLogicalSetFlagsOpcode(u32 data_opcode) {
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

bool IsFastLogicalWriteOpcode(u32 data_opcode) {
    switch (data_opcode) {
    case 0:  // AND
    case 1:  // EOR
    case 12: // ORR
    case 13: // MOV
    case 14: // BIC
    case 15: // MVN
        return true;
    default:
        return false;
    }
}

bool IsFastCarryArithmeticWriteOpcode(u32 data_opcode) {
    switch (data_opcode) {
    case 3: // RSB
    case 5: // ADC
    case 6: // SBC
    case 7: // RSC
        return true;
    default:
        return false;
    }
}

bool FastLogicalSetFlagsWritesRd(u32 data_opcode) {
    return data_opcode != 8 && data_opcode != 9;
}

void SetMoveRegisterOrHint(Op& op, u32 rd, u32 rn) {
    op.opcode = rd == rn ? Opcode::ArmHint : Opcode::ArmMoveRegisterAlways;
    op.arg0 = ConditionCode::AL;
    op.arg1 = rd | (rn << 8);
    op.arg2 = 0;
}

Op MakeMoveRegisterOrHint(u32 rd, u32 rn) {
    Op op;
    SetMoveRegisterOrHint(op, rd, rn);
    return op;
}

void SetMoveNotRegister(Op& op, u32 rd, u32 rm) {
    op.opcode = Opcode::ArmMoveNotRegisterAlways;
    op.arg0 = ConditionCode::AL;
    op.arg1 = rd | (rm << 8);
    op.arg2 = 0;
}

Op MakeMoveNotRegister(u32 rd, u32 rm) {
    Op op;
    SetMoveNotRegister(op, rd, rm);
    return op;
}

void SetMoveRegisterSetFlags(Op& op, u32 rd, u32 rm) {
    op.opcode = Opcode::ArmMoveRegisterSetFlagsAlways;
    op.arg0 = ConditionCode::AL;
    op.arg1 = rd | (rm << 8);
    op.arg2 = 0;
}

Op MakeMoveRegisterSetFlags(u32 rd, u32 rm) {
    Op op;
    SetMoveRegisterSetFlags(op, rd, rm);
    return op;
}

void SetMoveNotRegisterSetFlags(Op& op, u32 rd, u32 rm) {
    op.opcode = Opcode::ArmMoveNotRegisterSetFlagsAlways;
    op.arg0 = ConditionCode::AL;
    op.arg1 = rd | (rm << 8);
    op.arg2 = 0;
}

Op MakeMoveNotRegisterSetFlags(u32 rd, u32 rm) {
    Op op;
    SetMoveNotRegisterSetFlags(op, rd, rm);
    return op;
}

Op MakeTestRegisterNoShift(u32 rn, u32 rm) {
    return {
        .opcode = Opcode::ArmTstRegisterNoShiftNoPcAlways,
        .arg1 = rn | (rm << 8),
    };
}

Op MakeTestEqualRegisterNoShift(u32 rn, u32 rm) {
    return {
        .opcode = Opcode::ArmTeqRegisterNoShiftNoPcAlways,
        .arg1 = rn | (rm << 8),
    };
}

Op MakeTestImmediate(u32 rn, u32 immediate, bool shifter_carry,
                     bool shifter_carry_from_c_flag) {
    return {
        .opcode = Opcode::ArmTstImmediateNoPcAlways,
        .arg0 = static_cast<u32>(shifter_carry) |
                (static_cast<u32>(shifter_carry_from_c_flag) << 1),
        .arg1 = rn,
        .arg2 = immediate,
    };
}

Op MakeTestEqualImmediate(u32 rn, u32 immediate, bool shifter_carry,
                          bool shifter_carry_from_c_flag) {
    return {
        .opcode = Opcode::ArmTeqImmediateNoPcAlways,
        .arg0 = static_cast<u32>(shifter_carry) |
                (static_cast<u32>(shifter_carry_from_c_flag) << 1),
        .arg1 = rn,
        .arg2 = immediate,
    };
}

Op MakeCompareZeroImmediate(u32 rn) {
    return {
        .opcode = Opcode::ArmCompareZeroImmediateNoPcAlways,
        .arg1 = rn,
    };
}

void SetMoveImmediate(Op& op, u32 rd, u32 value) {
    op.opcode = Opcode::ArmMoveImmediateAlways;
    op.arg0 = 0;
    op.arg1 = rd;
    op.arg2 = value;
}

Op MakeMoveImmediate(u32 rd, u32 value) {
    Op op;
    SetMoveImmediate(op, rd, value);
    return op;
}

void SetMoveImmediateSetFlags(Op& op, u32 rd, u32 value, bool shifter_carry,
                              bool shifter_carry_from_c_flag) {
    op.opcode = Opcode::ArmMoveImmediateSetFlagsAlways;
    op.arg0 = static_cast<u32>(shifter_carry) |
              (static_cast<u32>(shifter_carry_from_c_flag) << 1);
    op.arg1 = rd;
    op.arg2 = value;
}

Op MakeMoveImmediateSetFlags(u32 rd, u32 value, bool shifter_carry,
                             bool shifter_carry_from_c_flag) {
    Op op;
    SetMoveImmediateSetFlags(op, rd, value, shifter_carry, shifter_carry_from_c_flag);
    return op;
}

bool TryBuildLogicalImmediateNoFlagsSimplification(Op& op, u32 data_opcode, u32 rd, u32 rn,
                                                   u32 immediate) {
    if (rd == 15) {
        return false;
    }

    if (data_opcode == 0 && immediate == 0) {
        // AND Rd, Rn, #0 does not depend on Rn, even when Rn is PC.
        SetMoveImmediate(op, rd, 0);
        return true;
    }

    if (data_opcode == 15) {
        // MVN Rd, #imm does not depend on Rn.
        SetMoveImmediate(op, rd, ~immediate);
        return true;
    }

    if (rn == 15 || immediate != 0) {
        return false;
    }

    switch (data_opcode) {
    case 1:  // EOR Rd, Rn, #0
    case 12: // ORR Rd, Rn, #0
    case 14: // BIC Rd, Rn, #0
        SetMoveRegisterOrHint(op, rd, rn);
        return true;
    default:
        return false;
    }
}

bool TryBuildLogicalRegisterNoFlagsSimplification(Op& op, u32 data_opcode, u32 rd, u32 rn,
                                                  u32 rm) {
    if (rd == 15 || rn == 15 || rm == 15 || rn != rm) {
        return false;
    }

    switch (data_opcode) {
    case 0:  // AND Rd, Rn, Rn
    case 12: // ORR Rd, Rn, Rn
        SetMoveRegisterOrHint(op, rd, rn);
        return true;
    case 1:  // EOR Rd, Rn, Rn
    case 14: // BIC Rd, Rn, Rn
        SetMoveImmediate(op, rd, 0);
        return true;
    default:
        return false;
    }
}

Opcode SelectNoPcDataOpcode(Opcode opcode, u32 rn) {
    if (rn == 15) {
        return opcode;
    }

    switch (opcode) {
    case Opcode::ArmAddImmediateAlways:
        return Opcode::ArmAddImmediateNoPcAlways;
    case Opcode::ArmSubImmediateAlways:
        return Opcode::ArmSubImmediateNoPcAlways;
    case Opcode::ArmCompareImmediateAlways:
        return Opcode::ArmCompareImmediateNoPcAlways;
    case Opcode::ArmAddRegisterAlways:
        return Opcode::ArmAddRegisterNoPcAlways;
    case Opcode::ArmSubRegisterAlways:
        return Opcode::ArmSubRegisterNoPcAlways;
    case Opcode::ArmCompareRegisterAlways:
        return Opcode::ArmCompareRegisterNoPcAlways;
    case Opcode::ArmAddImmediateSetFlagsAlways:
        return Opcode::ArmAddImmediateSetFlagsNoPcAlways;
    case Opcode::ArmSubImmediateSetFlagsAlways:
        return Opcode::ArmSubImmediateSetFlagsNoPcAlways;
    case Opcode::ArmCompareNegativeImmediateAlways:
        return Opcode::ArmCompareNegativeImmediateNoPcAlways;
    case Opcode::ArmAddRegisterSetFlagsAlways:
        return Opcode::ArmAddRegisterSetFlagsNoPcAlways;
    case Opcode::ArmSubRegisterSetFlagsAlways:
        return Opcode::ArmSubRegisterSetFlagsNoPcAlways;
    case Opcode::ArmCompareNegativeRegisterAlways:
        return Opcode::ArmCompareNegativeRegisterNoPcAlways;
    case Opcode::ArmLogicalImmediateAlways:
        return Opcode::ArmLogicalImmediateNoPcAlways;
    case Opcode::ArmLogicalRegisterAlways:
        return Opcode::ArmLogicalRegisterNoPcAlways;
    case Opcode::ArmLogicalImmediateSetFlagsAlways:
        return Opcode::ArmLogicalImmediateSetFlagsNoPcAlways;
    case Opcode::ArmLogicalRegisterSetFlagsAlways:
        return Opcode::ArmLogicalRegisterSetFlagsNoPcAlways;
    case Opcode::ArmArithmeticImmediateAlways:
        return Opcode::ArmArithmeticImmediateNoPcAlways;
    case Opcode::ArmArithmeticImmediateSetFlagsAlways:
        return Opcode::ArmArithmeticImmediateSetFlagsNoPcAlways;
    case Opcode::ArmArithmeticRegisterAlways:
        return Opcode::ArmArithmeticRegisterNoPcAlways;
    case Opcode::ArmArithmeticRegisterSetFlagsAlways:
        return Opcode::ArmArithmeticRegisterSetFlagsNoPcAlways;
    case Opcode::ArmAddShiftedRegisterAlways:
        return Opcode::ArmAddShiftedRegisterNoPcAlways;
    case Opcode::ArmSubShiftedRegisterAlways:
        return Opcode::ArmSubShiftedRegisterNoPcAlways;
    case Opcode::ArmCompareShiftedRegisterAlways:
        return Opcode::ArmCompareShiftedRegisterNoPcAlways;
    case Opcode::ArmAddShiftedRegisterSetFlagsAlways:
        return Opcode::ArmAddShiftedRegisterSetFlagsNoPcAlways;
    case Opcode::ArmSubShiftedRegisterSetFlagsAlways:
        return Opcode::ArmSubShiftedRegisterSetFlagsNoPcAlways;
    case Opcode::ArmCompareNegativeShiftedRegisterAlways:
        return Opcode::ArmCompareNegativeShiftedRegisterNoPcAlways;
    case Opcode::ArmLogicalShiftedRegisterAlways:
        return Opcode::ArmLogicalShiftedRegisterNoPcAlways;
    case Opcode::ArmLogicalShiftedRegisterSetFlagsAlways:
        return Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlways;
    case Opcode::ArmArithmeticShiftedRegisterAlways:
        return Opcode::ArmArithmeticShiftedRegisterNoPcAlways;
    case Opcode::ArmArithmeticShiftedRegisterSetFlagsAlways:
        return Opcode::ArmArithmeticShiftedRegisterSetFlagsNoPcAlways;
    case Opcode::ArmAddRegisterShiftedRegisterAlways:
        return Opcode::ArmAddRegisterShiftedRegisterNoPcAlways;
    case Opcode::ArmSubRegisterShiftedRegisterAlways:
        return Opcode::ArmSubRegisterShiftedRegisterNoPcAlways;
    case Opcode::ArmCompareRegisterShiftedRegisterAlways:
        return Opcode::ArmCompareRegisterShiftedRegisterNoPcAlways;
    case Opcode::ArmAddRegisterShiftedRegisterSetFlagsAlways:
        return Opcode::ArmAddRegisterShiftedRegisterSetFlagsNoPcAlways;
    case Opcode::ArmSubRegisterShiftedRegisterSetFlagsAlways:
        return Opcode::ArmSubRegisterShiftedRegisterSetFlagsNoPcAlways;
    case Opcode::ArmCompareNegativeRegisterShiftedRegisterAlways:
        return Opcode::ArmCompareNegativeRegisterShiftedRegisterNoPcAlways;
    case Opcode::ArmLogicalRegisterShiftedRegisterAlways:
        return Opcode::ArmLogicalRegisterShiftedRegisterNoPcAlways;
    case Opcode::ArmLogicalRegisterShiftedRegisterSetFlagsAlways:
        return Opcode::ArmLogicalRegisterShiftedRegisterSetFlagsNoPcAlways;
    case Opcode::ArmArithmeticRegisterShiftedRegisterAlways:
        return Opcode::ArmArithmeticRegisterShiftedRegisterNoPcAlways;
    case Opcode::ArmArithmeticRegisterShiftedRegisterSetFlagsAlways:
        return Opcode::ArmArithmeticRegisterShiftedRegisterSetFlagsNoPcAlways;
    default:
        return opcode;
    }
}

Opcode SelectLogicalShiftedRegisterSetFlagsNoPcOpcode(u32 data_opcode, u32 rn, u32 shift_type) {
    if (rn == 15) {
        return Opcode::ArmLogicalShiftedRegisterSetFlagsAlways;
    }

    switch (shift_type & 0x3) {
    case 0:
        if (data_opcode == 8) {
            return Opcode::ArmTstShiftedRegisterNoPcAlwaysLsl;
        }
        if (data_opcode == 9) {
            return Opcode::ArmTeqShiftedRegisterNoPcAlwaysLsl;
        }
        return Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysLsl;
    case 1:
        if (data_opcode == 8) {
            return Opcode::ArmTstShiftedRegisterNoPcAlwaysLsr;
        }
        if (data_opcode == 9) {
            return Opcode::ArmTeqShiftedRegisterNoPcAlwaysLsr;
        }
        return Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysLsr;
    case 2:
        if (data_opcode == 8) {
            return Opcode::ArmTstShiftedRegisterNoPcAlwaysAsr;
        }
        if (data_opcode == 9) {
            return Opcode::ArmTeqShiftedRegisterNoPcAlwaysAsr;
        }
        return Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysAsr;
    case 3:
        if (data_opcode == 8) {
            return Opcode::ArmTstShiftedRegisterNoPcAlwaysRor;
        }
        if (data_opcode == 9) {
            return Opcode::ArmTeqShiftedRegisterNoPcAlwaysRor;
        }
        return Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysRor;
    default:
        return Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlways;
    }
}

Opcode SelectNoPcMemoryOpcode(Opcode opcode, u32 rn) {
    if (rn == 15) {
        return opcode;
    }

    switch (opcode) {
    case Opcode::ArmLoadWordImmediate:
        return Opcode::ArmLoadWordImmediateNoPc;
    case Opcode::ArmStoreWordImmediate:
        return Opcode::ArmStoreWordImmediateNoPc;
    case Opcode::ArmLoadByteImmediate:
        return Opcode::ArmLoadByteImmediateNoPc;
    case Opcode::ArmStoreByteImmediate:
        return Opcode::ArmStoreByteImmediateNoPc;
    case Opcode::ArmLoadWordRegister:
        return Opcode::ArmLoadWordRegisterNoPc;
    case Opcode::ArmStoreWordRegister:
        return Opcode::ArmStoreWordRegisterNoPc;
    case Opcode::ArmLoadByteRegister:
        return Opcode::ArmLoadByteRegisterNoPc;
    case Opcode::ArmStoreByteRegister:
        return Opcode::ArmStoreByteRegisterNoPc;
    case Opcode::ArmLoadHalfwordImmediate:
        return Opcode::ArmLoadHalfwordImmediateNoPc;
    case Opcode::ArmStoreHalfwordImmediate:
        return Opcode::ArmStoreHalfwordImmediateNoPc;
    case Opcode::ArmLoadSignedByteImmediate:
        return Opcode::ArmLoadSignedByteImmediateNoPc;
    case Opcode::ArmLoadSignedHalfwordImmediate:
        return Opcode::ArmLoadSignedHalfwordImmediateNoPc;
    case Opcode::ArmLoadHalfwordRegister:
        return Opcode::ArmLoadHalfwordRegisterNoPc;
    case Opcode::ArmStoreHalfwordRegister:
        return Opcode::ArmStoreHalfwordRegisterNoPc;
    case Opcode::ArmLoadSignedByteRegister:
        return Opcode::ArmLoadSignedByteRegisterNoPc;
    case Opcode::ArmLoadSignedHalfwordRegister:
        return Opcode::ArmLoadSignedHalfwordRegisterNoPc;
    default:
        return opcode;
    }
}

Opcode SelectConditionalSkipOpcode(u32 condition) {
    switch (condition) {
    case ConditionCode::EQ:
        return Opcode::ArmConditionalSkipEq;
    case ConditionCode::NE:
        return Opcode::ArmConditionalSkipNe;
    case ConditionCode::CS:
        return Opcode::ArmConditionalSkipCs;
    case ConditionCode::CC:
        return Opcode::ArmConditionalSkipCc;
    case ConditionCode::MI:
        return Opcode::ArmConditionalSkipMi;
    case ConditionCode::PL:
        return Opcode::ArmConditionalSkipPl;
    case ConditionCode::VS:
        return Opcode::ArmConditionalSkipVs;
    case ConditionCode::VC:
        return Opcode::ArmConditionalSkipVc;
    case ConditionCode::HI:
        return Opcode::ArmConditionalSkipHi;
    case ConditionCode::LS:
        return Opcode::ArmConditionalSkipLs;
    case ConditionCode::GE:
        return Opcode::ArmConditionalSkipGe;
    case ConditionCode::LT:
        return Opcode::ArmConditionalSkipLt;
    case ConditionCode::GT:
        return Opcode::ArmConditionalSkipGt;
    case ConditionCode::LE:
        return Opcode::ArmConditionalSkipLe;
    default:
        return Opcode::ArmConditionalSkip;
    }
}

bool AddressInRange(u32 address, u32 start, u32 end, bool wrapped) {
    if (wrapped) {
        return address >= start || address < end;
    }
    return address >= start && address < end;
}

bool TryGetConditionalSkipCondition(const Op& op, u32& condition) {
    switch (op.opcode) {
    case Opcode::ArmDataProcessingImmediate:
    case Opcode::ArmDataProcessingRegister:
    case Opcode::ArmLoadStoreImmediate:
    case Opcode::ArmLoadStoreRegister:
        condition = (op.arg0 >> 8) & 0xF;
        break;
    case Opcode::ArmLoadStoreHalfword:
    case Opcode::ArmLoadStoreDouble:
    case Opcode::ArmLoadStoreMultiple:
    case Opcode::ArmMultiply:
    case Opcode::ArmMultiplyLong:
    case Opcode::ArmCountLeadingZeros:
    case Opcode::ArmExtend:
    case Opcode::ArmReverse:
    case Opcode::ArmExclusiveLoad:
    case Opcode::ArmExclusiveStore:
    case Opcode::ArmVFPRegisterTransfer:
    case Opcode::ArmVFPSystemRegisterTransfer:
    case Opcode::ArmVFPLoadStore:
    case Opcode::ArmVFPDataProcessing:
    case Opcode::ArmPackHalfword:
    case Opcode::ArmUnsignedSumAbsoluteDifference:
    case Opcode::ArmSwap:
    case Opcode::ArmUnsignedMultiplyAccumulateAccumulateLong:
    case Opcode::ArmExtendAdd:
    case Opcode::ArmSaturate:
    case Opcode::ArmSignedHalfwordMultiply:
    case Opcode::ArmSignedWordHalfwordMultiply:
    case Opcode::ArmSignedDualMultiply:
    case Opcode::ArmSignedDualMultiplyLong:
    case Opcode::ArmSignedMostSignificantMultiply:
    case Opcode::ArmSaturatingArithmetic:
    case Opcode::ArmParallelAddSub:
    case Opcode::ArmSelectBytes:
    case Opcode::ArmSignedHalvingParallelAddSub:
    case Opcode::ArmUnsignedHalvingParallelAddSub:
    case Opcode::ArmSignedSaturatingParallelAddSub:
    case Opcode::ArmUnsignedSaturatingParallelAddSub:
        condition = op.arg0 & 0xF;
        break;
    default:
        return false;
    }

    return condition != ConditionCode::AL && condition != ConditionCode::NV;
}

bool WritesConditionFlags(const Op& op) {
    switch (op.opcode) {
    case Opcode::ArmDataProcessingImmediate:
        return ((op.arg1 >> 16) & 1) != 0;
    case Opcode::ArmDataProcessingRegister:
        return ((op.arg1 >> 20) & 1) != 0;
    case Opcode::ArmMultiply:
        return ((op.arg0 >> 9) & 1) != 0;
    case Opcode::ArmMultiplyLong:
        return ((op.arg0 >> 10) & 1) != 0;
    case Opcode::ArmVFPSystemRegisterTransfer: {
        const bool read_from_vfp = ((op.arg0 >> 8) & 1) != 0;
        const u32 vfp_register = op.arg1 & 0xF;
        const u32 rt = (op.arg1 >> 8) & 0xF;
        return read_from_vfp && vfp_register == 1 && rt == 15;
    }
    case Opcode::ArmLoadStoreMultiple: {
        const bool load = ((op.arg0 >> 8) & 1) != 0;
        const bool user_mode_or_psr = ((op.arg0 >> 12) & 1) != 0;
        const u32 register_list = (op.arg1 >> 8) & 0xFFFF;
        return load && user_mode_or_psr && ((register_list & (1U << 15)) != 0);
    }
    default:
        return false;
    }
}

void ForceConditionAlways(Op& op) {
    switch (op.opcode) {
    case Opcode::ArmDataProcessingImmediate:
    case Opcode::ArmDataProcessingRegister:
    case Opcode::ArmLoadStoreImmediate:
    case Opcode::ArmLoadStoreRegister:
        op.arg0 = (op.arg0 & ~(0xFU << 8)) | (ConditionCode::AL << 8);
        break;
    default:
        op.arg0 = (op.arg0 & ~0xFU) | ConditionCode::AL;
        break;
    }
}

void SpecializeAlwaysDataProcessingImmediate(Op& op) {
    const u32 data_opcode = op.arg0 & 0xF;
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const bool set_flags = ((op.arg1 >> 16) & 1) != 0;
    const bool shifter_carry = ((op.arg1 >> 17) & 1) != 0;
    const bool shifter_carry_from_c_flag = ((op.arg1 >> 18) & 1) != 0;

    if (data_opcode == 13 && !set_flags && rd != 15) {
        SetMoveImmediate(op, rd, op.arg2);
        return;
    }
    if (data_opcode == 4 && !set_flags && rd != 15) {
        if (rn != 15 && op.arg2 == 0) {
            SetMoveRegisterOrHint(op, rd, rn);
            return;
        }
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmAddImmediateAlways, rn);
        op.arg0 = 0;
        op.arg1 = rd | (rn << 8);
        return;
    }
    if (data_opcode == 2 && !set_flags && rd != 15) {
        if (rn != 15 && op.arg2 == 0) {
            SetMoveRegisterOrHint(op, rd, rn);
            return;
        }
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmSubImmediateAlways, rn);
        op.arg0 = 0;
        op.arg1 = rd | (rn << 8);
        return;
    }
    if (!set_flags &&
        TryBuildLogicalImmediateNoFlagsSimplification(op, data_opcode, rd, rn, op.arg2)) {
        return;
    }
    if (set_flags && rd != 15 && (data_opcode == 13 || data_opcode == 15)) {
        const u32 value = data_opcode == 15 ? ~op.arg2 : op.arg2;
        SetMoveImmediateSetFlags(op, rd, value, shifter_carry, shifter_carry_from_c_flag);
        return;
    }
    if (!set_flags && IsFastCarryArithmeticWriteOpcode(data_opcode) && rd != 15) {
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmArithmeticImmediateAlways, rn);
        op.arg0 = data_opcode;
        op.arg1 = rd | (rn << 8);
        return;
    }
    if (!set_flags && IsFastLogicalWriteOpcode(data_opcode) && rd != 15) {
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmLogicalImmediateAlways, rn);
        op.arg0 = data_opcode;
        op.arg1 = rd | (rn << 8);
        return;
    }
    if (data_opcode == 4 && set_flags && rd != 15) {
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmAddImmediateSetFlagsAlways, rn);
        op.arg0 = 0;
        op.arg1 = rd | (rn << 8);
        return;
    }
    if (data_opcode == 2 && set_flags && rd != 15) {
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmSubImmediateSetFlagsAlways, rn);
        op.arg0 = 0;
        op.arg1 = rd | (rn << 8);
        return;
    }
    if (set_flags && IsFastCarryArithmeticWriteOpcode(data_opcode) && rd != 15) {
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmArithmeticImmediateSetFlagsAlways, rn);
        op.arg0 = data_opcode;
        op.arg1 = rd | (rn << 8);
        return;
    }
    if (rn != 15 && data_opcode == 10 && set_flags && op.arg2 == 0) {
        op = MakeCompareZeroImmediate(rn);
        return;
    }
    if (data_opcode == 10 && set_flags) {
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmCompareImmediateAlways, rn);
        op.arg0 = 0;
        op.arg1 = rn;
        return;
    }
    if (data_opcode == 11 && set_flags) {
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmCompareNegativeImmediateAlways, rn);
        op.arg0 = 0;
        op.arg1 = rn;
        return;
    }
    if (rn != 15 && data_opcode == 8 && set_flags) {
        op = MakeTestImmediate(rn, op.arg2, shifter_carry, shifter_carry_from_c_flag);
        return;
    }
    if (rn != 15 && data_opcode == 9 && set_flags) {
        op = MakeTestEqualImmediate(rn, op.arg2, shifter_carry, shifter_carry_from_c_flag);
        return;
    }
    if (set_flags && IsFastLogicalSetFlagsOpcode(data_opcode) &&
        (!FastLogicalSetFlagsWritesRd(data_opcode) || rd != 15)) {
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmLogicalImmediateSetFlagsAlways, rn);
        op.arg0 = data_opcode | (static_cast<u32>(shifter_carry) << 8) |
                  (static_cast<u32>(shifter_carry_from_c_flag) << 9);
        op.arg1 = rd | (rn << 8);
        return;
    }
}

void SpecializeAlwaysDataProcessingRegister(Op& op) {
    const u32 data_opcode = op.arg0 & 0xF;
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const u32 rm = (op.arg1 >> 16) & 0xF;
    const bool set_flags = ((op.arg1 >> 20) & 1) != 0;
    const u32 shift_type = op.arg2 & 0x3;
    const bool register_shift_amount = ((op.arg2 >> 16) & 1) != 0;
    const u32 shift_imm_or_rs = (op.arg2 >> 8) & (register_shift_amount ? 0xF : 0x1F);

    if (register_shift_amount) {
        const u32 rs = shift_imm_or_rs;
        if (rm == 15 || rs == 15) {
            return;
        }

        if (data_opcode == 13 && rd != 15) {
            op.opcode = set_flags ? Opcode::ArmMoveRegisterShiftedRegisterSetFlagsAlways
                                  : Opcode::ArmMoveRegisterShiftedRegisterAlways;
            op.arg0 = 0;
            op.arg1 = rd | (rm << 8) | (rs << 16);
            op.arg2 = shift_type;
            return;
        }
        if (!set_flags && IsFastLogicalWriteOpcode(data_opcode) && rd != 15) {
            op.opcode = SelectNoPcDataOpcode(Opcode::ArmLogicalRegisterShiftedRegisterAlways, rn);
            op.arg0 = data_opcode;
            op.arg1 = rd | (rn << 8) | (rm << 16) | (rs << 24);
            op.arg2 = shift_type;
            return;
        }
        if (!set_flags && IsFastCarryArithmeticWriteOpcode(data_opcode) && rd != 15) {
            op.opcode =
                SelectNoPcDataOpcode(Opcode::ArmArithmeticRegisterShiftedRegisterAlways, rn);
            op.arg0 = data_opcode;
            op.arg1 = rd | (rn << 8) | (rm << 16) | (rs << 24);
            op.arg2 = shift_type;
            return;
        }
        if (data_opcode == 4 && !set_flags && rd != 15) {
            op.opcode =
                SelectNoPcDataOpcode(Opcode::ArmAddRegisterShiftedRegisterAlways, rn);
            op.arg0 = 0;
            op.arg1 = rd | (rn << 8) | (rm << 16) | (rs << 24);
            op.arg2 = shift_type;
            return;
        }
        if (data_opcode == 2 && !set_flags && rd != 15) {
            op.opcode =
                SelectNoPcDataOpcode(Opcode::ArmSubRegisterShiftedRegisterAlways, rn);
            op.arg0 = 0;
            op.arg1 = rd | (rn << 8) | (rm << 16) | (rs << 24);
            op.arg2 = shift_type;
            return;
        }
        if (data_opcode == 10 && set_flags) {
            op.opcode =
                SelectNoPcDataOpcode(Opcode::ArmCompareRegisterShiftedRegisterAlways, rn);
            op.arg0 = 0;
            op.arg1 = rn | (rm << 8) | (rs << 16);
            op.arg2 = shift_type;
            return;
        }
        if (data_opcode == 4 && set_flags && rd != 15) {
            op.opcode = SelectNoPcDataOpcode(
                Opcode::ArmAddRegisterShiftedRegisterSetFlagsAlways, rn);
            op.arg0 = 0;
            op.arg1 = rd | (rn << 8) | (rm << 16) | (rs << 24);
            op.arg2 = shift_type;
            return;
        }
        if (data_opcode == 2 && set_flags && rd != 15) {
            op.opcode = SelectNoPcDataOpcode(
                Opcode::ArmSubRegisterShiftedRegisterSetFlagsAlways, rn);
            op.arg0 = 0;
            op.arg1 = rd | (rn << 8) | (rm << 16) | (rs << 24);
            op.arg2 = shift_type;
            return;
        }
        if (set_flags && IsFastCarryArithmeticWriteOpcode(data_opcode) && rd != 15) {
            op.opcode = SelectNoPcDataOpcode(
                Opcode::ArmArithmeticRegisterShiftedRegisterSetFlagsAlways, rn);
            op.arg0 = data_opcode;
            op.arg1 = rd | (rn << 8) | (rm << 16) | (rs << 24);
            op.arg2 = shift_type;
            return;
        }
        if (data_opcode == 11 && set_flags) {
            op.opcode = SelectNoPcDataOpcode(
                Opcode::ArmCompareNegativeRegisterShiftedRegisterAlways, rn);
            op.arg0 = 0;
            op.arg1 = rn | (rm << 8) | (rs << 16);
            op.arg2 = shift_type;
            return;
        }
        if (set_flags && IsFastLogicalSetFlagsOpcode(data_opcode) &&
            (!FastLogicalSetFlagsWritesRd(data_opcode) || rd != 15)) {
            op.opcode = SelectNoPcDataOpcode(
                Opcode::ArmLogicalRegisterShiftedRegisterSetFlagsAlways, rn);
            op.arg0 = data_opcode;
            op.arg1 = rd | (rn << 8) | (rm << 16) | (rs << 24);
            op.arg2 = shift_type;
            return;
        }
        return;
    }

    if (rm == 15) {
        return;
    }

    if (shift_type == 0 && shift_imm_or_rs == 0) {
        if (data_opcode == 13 && !set_flags && rd != 15) {
            SetMoveRegisterOrHint(op, rd, rm);
            return;
        }
        if (data_opcode == 15 && !set_flags && rd != 15) {
            SetMoveNotRegister(op, rd, rm);
            return;
        }
        if (data_opcode == 13 && set_flags && rd != 15) {
            SetMoveRegisterSetFlags(op, rd, rm);
            return;
        }
        if (data_opcode == 15 && set_flags && rd != 15) {
            SetMoveNotRegisterSetFlags(op, rd, rm);
            return;
        }
        if (!set_flags &&
            TryBuildLogicalRegisterNoFlagsSimplification(op, data_opcode, rd, rn, rm)) {
            return;
        }
        if (data_opcode == 4 && !set_flags && rd != 15) {
            op.opcode = SelectNoPcDataOpcode(Opcode::ArmAddRegisterAlways, rn);
            op.arg0 = 0;
            op.arg1 = rd | (rn << 8) | (rm << 16);
            return;
        }
        if (data_opcode == 2 && !set_flags && rd != 15) {
            op.opcode = SelectNoPcDataOpcode(Opcode::ArmSubRegisterAlways, rn);
            op.arg0 = 0;
            op.arg1 = rd | (rn << 8) | (rm << 16);
            return;
        }
        if (!set_flags && IsFastCarryArithmeticWriteOpcode(data_opcode) && rd != 15) {
            op.opcode = SelectNoPcDataOpcode(Opcode::ArmArithmeticRegisterAlways, rn);
            op.arg0 = data_opcode;
            op.arg1 = rd | (rn << 8) | (rm << 16);
            return;
        }
        if (!set_flags && IsFastLogicalWriteOpcode(data_opcode) && rd != 15) {
            op.opcode = SelectNoPcDataOpcode(Opcode::ArmLogicalRegisterAlways, rn);
            op.arg0 = data_opcode;
            op.arg1 = rd | (rn << 8) | (rm << 16);
            return;
        }
        if (data_opcode == 4 && set_flags && rd != 15) {
            op.opcode = SelectNoPcDataOpcode(Opcode::ArmAddRegisterSetFlagsAlways, rn);
            op.arg0 = 0;
            op.arg1 = rd | (rn << 8) | (rm << 16);
            return;
        }
        if (data_opcode == 2 && set_flags && rd != 15) {
            op.opcode = SelectNoPcDataOpcode(Opcode::ArmSubRegisterSetFlagsAlways, rn);
            op.arg0 = 0;
            op.arg1 = rd | (rn << 8) | (rm << 16);
            return;
        }
        if (set_flags && IsFastCarryArithmeticWriteOpcode(data_opcode) && rd != 15) {
            op.opcode = SelectNoPcDataOpcode(Opcode::ArmArithmeticRegisterSetFlagsAlways, rn);
            op.arg0 = data_opcode;
            op.arg1 = rd | (rn << 8) | (rm << 16);
            return;
        }
        if (data_opcode == 10 && set_flags) {
            op.opcode = SelectNoPcDataOpcode(Opcode::ArmCompareRegisterAlways, rn);
            op.arg0 = 0;
            op.arg1 = rn | (rm << 8);
            return;
        }
        if (data_opcode == 11 && set_flags) {
            op.opcode = SelectNoPcDataOpcode(Opcode::ArmCompareNegativeRegisterAlways, rn);
            op.arg0 = 0;
            op.arg1 = rn | (rm << 8);
            return;
        }
        if (rn != 15 && data_opcode == 8 && set_flags) {
            op = MakeTestRegisterNoShift(rn, rm);
            return;
        }
        if (rn != 15 && data_opcode == 9 && set_flags) {
            op = MakeTestEqualRegisterNoShift(rn, rm);
            return;
        }
        if (set_flags && IsFastLogicalSetFlagsOpcode(data_opcode) &&
            (!FastLogicalSetFlagsWritesRd(data_opcode) || rd != 15)) {
            op.opcode = SelectNoPcDataOpcode(Opcode::ArmLogicalRegisterSetFlagsAlways, rn);
            op.arg0 = data_opcode;
            op.arg1 = rd | (rn << 8) | (rm << 16);
            return;
        }
        return;
    }

    if (data_opcode == 13 && rd != 15) {
        op.opcode = set_flags ? Opcode::ArmMoveShiftedRegisterSetFlagsAlways
                              : Opcode::ArmMoveShiftedRegisterAlways;
        op.arg0 = 0;
        op.arg1 = rd | (rm << 8);
        op.arg2 = shift_type | (shift_imm_or_rs << 8);
        return;
    }
    if (!set_flags && IsFastLogicalWriteOpcode(data_opcode) && rd != 15) {
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmLogicalShiftedRegisterAlways, rn);
        op.arg0 = data_opcode;
        op.arg1 = rd | (rn << 8) | (rm << 16);
        op.arg2 = shift_type | (shift_imm_or_rs << 8);
        return;
    }
    if (data_opcode == 4 && !set_flags && rd != 15) {
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmAddShiftedRegisterAlways, rn);
        op.arg0 = 0;
        op.arg1 = rd | (rn << 8) | (rm << 16);
        op.arg2 = shift_type | (shift_imm_or_rs << 8);
        return;
    }
    if (data_opcode == 2 && !set_flags && rd != 15) {
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmSubShiftedRegisterAlways, rn);
        op.arg0 = 0;
        op.arg1 = rd | (rn << 8) | (rm << 16);
        op.arg2 = shift_type | (shift_imm_or_rs << 8);
        return;
    }
    if (!set_flags && IsFastCarryArithmeticWriteOpcode(data_opcode) && rd != 15) {
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmArithmeticShiftedRegisterAlways, rn);
        op.arg0 = data_opcode;
        op.arg1 = rd | (rn << 8) | (rm << 16);
        op.arg2 = shift_type | (shift_imm_or_rs << 8);
        return;
    }
    if (data_opcode == 10 && set_flags) {
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmCompareShiftedRegisterAlways, rn);
        op.arg0 = 0;
        op.arg1 = rn | (rm << 8);
        op.arg2 = shift_type | (shift_imm_or_rs << 8);
        return;
    }
    if (data_opcode == 4 && set_flags && rd != 15) {
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmAddShiftedRegisterSetFlagsAlways, rn);
        op.arg0 = 0;
        op.arg1 = rd | (rn << 8) | (rm << 16);
        op.arg2 = shift_type | (shift_imm_or_rs << 8);
        return;
    }
    if (data_opcode == 2 && set_flags && rd != 15) {
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmSubShiftedRegisterSetFlagsAlways, rn);
        op.arg0 = 0;
        op.arg1 = rd | (rn << 8) | (rm << 16);
        op.arg2 = shift_type | (shift_imm_or_rs << 8);
        return;
    }
    if (set_flags && IsFastCarryArithmeticWriteOpcode(data_opcode) && rd != 15) {
        op.opcode =
            SelectNoPcDataOpcode(Opcode::ArmArithmeticShiftedRegisterSetFlagsAlways, rn);
        op.arg0 = data_opcode;
        op.arg1 = rd | (rn << 8) | (rm << 16);
        op.arg2 = shift_type | (shift_imm_or_rs << 8);
        return;
    }
    if (data_opcode == 11 && set_flags) {
        op.opcode = SelectNoPcDataOpcode(Opcode::ArmCompareNegativeShiftedRegisterAlways, rn);
        op.arg0 = 0;
        op.arg1 = rn | (rm << 8);
        op.arg2 = shift_type | (shift_imm_or_rs << 8);
        return;
    }
    if (set_flags && IsFastLogicalSetFlagsOpcode(data_opcode) &&
        (!FastLogicalSetFlagsWritesRd(data_opcode) || rd != 15)) {
        op.opcode =
            SelectLogicalShiftedRegisterSetFlagsNoPcOpcode(data_opcode, rn, shift_type);
        op.arg0 = data_opcode;
        op.arg1 = rd | (rn << 8) | (rm << 16);
        op.arg2 = shift_type | (shift_imm_or_rs << 8);
        return;
    }
}

void SpecializeAlwaysLoadStoreImmediate(Op& op) {
    const bool load = (op.arg0 & 1) != 0;
    const bool byte_transfer = (op.arg0 & 2) != 0;
    const bool unprivileged = ((op.arg0 >> 2) & 1) != 0;
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
    const bool pre_indexed = ((op.arg1 >> 17) & 1) != 0;
    const bool writes_back = ((op.arg1 >> 18) & 1) != 0;

    if (unprivileged || !pre_indexed || writes_back || rd == 15) {
        return;
    }

    const Opcode opcode =
        byte_transfer ? (load ? Opcode::ArmLoadByteImmediate : Opcode::ArmStoreByteImmediate)
                      : (load ? Opcode::ArmLoadWordImmediate : Opcode::ArmStoreWordImmediate);
    if (rn != 15) {
        if (op.arg2 == 0) {
            if (byte_transfer) {
                op.opcode = load ? Opcode::ArmLoadByteImmediateNoPcOffset0
                                 : Opcode::ArmStoreByteImmediateNoPcOffset0;
            } else {
                op.opcode = load ? Opcode::ArmLoadWordImmediateNoPcOffset0
                                 : Opcode::ArmStoreWordImmediateNoPcOffset0;
            }
        } else if (byte_transfer) {
            op.opcode = load ? (add_offset ? Opcode::ArmLoadByteImmediateNoPcAdd
                                           : Opcode::ArmLoadByteImmediateNoPcSub)
                             : (add_offset ? Opcode::ArmStoreByteImmediateNoPcAdd
                                           : Opcode::ArmStoreByteImmediateNoPcSub);
        } else {
            op.opcode = load ? (add_offset ? Opcode::ArmLoadWordImmediateNoPcAdd
                                           : Opcode::ArmLoadWordImmediateNoPcSub)
                             : (add_offset ? Opcode::ArmStoreWordImmediateNoPcAdd
                                           : Opcode::ArmStoreWordImmediateNoPcSub);
        }
    } else {
        op.opcode = SelectNoPcMemoryOpcode(opcode, rn);
    }
    op.arg0 = ConditionCode::AL;
    op.arg1 = rd | (rn << 8) | (static_cast<u32>(add_offset) << 16);
}

void SpecializeAlwaysLoadStoreRegister(Op& op) {
    const bool load = (op.arg0 & 1) != 0;
    const bool byte_transfer = (op.arg0 & 2) != 0;
    const bool unprivileged = ((op.arg0 >> 2) & 1) != 0;
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const u32 rm = (op.arg1 >> 16) & 0xF;
    const bool add_offset = ((op.arg1 >> 20) & 1) != 0;
    const bool pre_indexed = ((op.arg1 >> 21) & 1) != 0;
    const bool writes_back = ((op.arg1 >> 22) & 1) != 0;
    const u32 shift_type = op.arg2 & 0x3;
    const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
    const bool register_offset_uses_c_flag = shift_type == 3 && shift_imm == 0;

    if (unprivileged || !pre_indexed || writes_back || rd == 15 || rm == 15 ||
        register_offset_uses_c_flag) {
        return;
    }

    const Opcode opcode =
        byte_transfer ? (load ? Opcode::ArmLoadByteRegister : Opcode::ArmStoreByteRegister)
                      : (load ? Opcode::ArmLoadWordRegister : Opcode::ArmStoreWordRegister);
    if (rn != 15 && shift_type == 0 && shift_imm == 0) {
        if (byte_transfer) {
            op.opcode = load ? (add_offset ? Opcode::ArmLoadByteRegisterNoPcAdd
                                           : Opcode::ArmLoadByteRegisterNoPcSub)
                             : (add_offset ? Opcode::ArmStoreByteRegisterNoPcAdd
                                           : Opcode::ArmStoreByteRegisterNoPcSub);
        } else {
            op.opcode = load ? (add_offset ? Opcode::ArmLoadWordRegisterNoPcAdd
                                           : Opcode::ArmLoadWordRegisterNoPcSub)
                             : (add_offset ? Opcode::ArmStoreWordRegisterNoPcAdd
                                           : Opcode::ArmStoreWordRegisterNoPcSub);
        }
    } else {
        op.opcode = SelectNoPcMemoryOpcode(opcode, rn);
    }
    op.arg0 = ConditionCode::AL;
    op.arg1 = rd | (rn << 8) | (rm << 16) | (static_cast<u32>(add_offset) << 20);
}

void SpecializeAlwaysLoadStoreHalfword(Op& op) {
    const bool load = ((op.arg0 >> 8) & 1) != 0;
    const u32 transfer_type = (op.arg0 >> 9) & 0x3;
    const u32 rd = op.arg1 & 0xF;
    const u32 rn = (op.arg1 >> 8) & 0xF;
    const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
    const bool immediate_offset = ((op.arg1 >> 17) & 1) != 0;
    const bool pre_indexed = ((op.arg1 >> 18) & 1) != 0;
    const bool writes_back = ((op.arg1 >> 19) & 1) != 0;
    const u32 rm = op.arg2 & 0xF;

    if (!pre_indexed || writes_back || rd == 15 || (!immediate_offset && rm == 15) ||
        (transfer_type != 1 && !load)) {
        return;
    }

    Opcode opcode = Opcode::ArmLoadStoreHalfword;
    if (immediate_offset) {
        if (transfer_type == 1) {
            opcode = load ? Opcode::ArmLoadHalfwordImmediate : Opcode::ArmStoreHalfwordImmediate;
        } else if (transfer_type == 2) {
            opcode = Opcode::ArmLoadSignedByteImmediate;
        } else if (transfer_type == 3) {
            opcode = Opcode::ArmLoadSignedHalfwordImmediate;
        } else {
            return;
        }
    } else {
        if (transfer_type == 1) {
            opcode = load ? Opcode::ArmLoadHalfwordRegister : Opcode::ArmStoreHalfwordRegister;
        } else if (transfer_type == 2) {
            opcode = Opcode::ArmLoadSignedByteRegister;
        } else if (transfer_type == 3) {
            opcode = Opcode::ArmLoadSignedHalfwordRegister;
        } else {
            return;
        }
    }

    if (immediate_offset && rn != 15 && op.arg2 == 0) {
        if (transfer_type == 1) {
            op.opcode = load ? Opcode::ArmLoadHalfwordImmediateNoPcOffset0
                             : Opcode::ArmStoreHalfwordImmediateNoPcOffset0;
        } else if (transfer_type == 2) {
            op.opcode = Opcode::ArmLoadSignedByteImmediateNoPcOffset0;
        } else if (transfer_type == 3) {
            op.opcode = Opcode::ArmLoadSignedHalfwordImmediateNoPcOffset0;
        }
    } else if (rn != 15 && transfer_type == 1) {
        if (immediate_offset) {
            op.opcode = load ? (add_offset ? Opcode::ArmLoadHalfwordImmediateNoPcAdd
                                           : Opcode::ArmLoadHalfwordImmediateNoPcSub)
                             : (add_offset ? Opcode::ArmStoreHalfwordImmediateNoPcAdd
                                           : Opcode::ArmStoreHalfwordImmediateNoPcSub);
        } else {
            op.opcode = load ? (add_offset ? Opcode::ArmLoadHalfwordRegisterNoPcAdd
                                           : Opcode::ArmLoadHalfwordRegisterNoPcSub)
                             : (add_offset ? Opcode::ArmStoreHalfwordRegisterNoPcAdd
                                           : Opcode::ArmStoreHalfwordRegisterNoPcSub);
        }
    } else if (!immediate_offset && rn != 15 && transfer_type == 2) {
        op.opcode = add_offset ? Opcode::ArmLoadSignedByteRegisterNoPcAdd
                               : Opcode::ArmLoadSignedByteRegisterNoPcSub;
    } else if (!immediate_offset && rn != 15 && transfer_type == 3) {
        op.opcode = add_offset ? Opcode::ArmLoadSignedHalfwordRegisterNoPcAdd
                               : Opcode::ArmLoadSignedHalfwordRegisterNoPcSub;
    } else if (immediate_offset && rn != 15 && transfer_type == 2) {
        op.opcode = add_offset ? Opcode::ArmLoadSignedByteImmediateNoPcAdd
                               : Opcode::ArmLoadSignedByteImmediateNoPcSub;
    } else if (immediate_offset && rn != 15 && transfer_type == 3) {
        op.opcode = add_offset ? Opcode::ArmLoadSignedHalfwordImmediateNoPcAdd
                               : Opcode::ArmLoadSignedHalfwordImmediateNoPcSub;
    } else {
        op.opcode = SelectNoPcMemoryOpcode(opcode, rn);
    }
    op.arg0 = ConditionCode::AL;
    op.arg1 = rd | (rn << 8) | (static_cast<u32>(add_offset) << 16);
}

void SpecializeAlwaysOp(Op& op) {
    switch (op.opcode) {
    case Opcode::ArmDataProcessingImmediate:
    case Opcode::ArmDataProcessingImmediateAlways:
        SpecializeAlwaysDataProcessingImmediate(op);
        break;
    case Opcode::ArmDataProcessingRegister:
    case Opcode::ArmDataProcessingRegisterAlways:
        SpecializeAlwaysDataProcessingRegister(op);
        break;
    case Opcode::ArmLoadStoreImmediate:
        SpecializeAlwaysLoadStoreImmediate(op);
        break;
    case Opcode::ArmLoadStoreRegister:
        SpecializeAlwaysLoadStoreRegister(op);
        break;
    case Opcode::ArmLoadStoreHalfword:
        SpecializeAlwaysLoadStoreHalfword(op);
        break;
    default:
        break;
    }
}

void ConvertGuardedOpToAlways(Op& op) {
    ForceConditionAlways(op);

    switch (op.opcode) {
    case Opcode::ArmDataProcessingImmediate:
        op.opcode = Opcode::ArmDataProcessingImmediateAlways;
        break;
    case Opcode::ArmDataProcessingRegister:
        op.opcode = Opcode::ArmDataProcessingRegisterAlways;
        break;
    case Opcode::ArmMultiply:
        op.opcode = Opcode::ArmMultiplyAlways;
        break;
    case Opcode::ArmMultiplyLong:
        op.opcode = Opcode::ArmMultiplyLongAlways;
        break;
    case Opcode::ArmUnsignedMultiplyAccumulateAccumulateLong:
        op.opcode = Opcode::ArmUnsignedMultiplyAccumulateAccumulateLongAlways;
        break;
    case Opcode::ArmVFPRegisterTransfer:
        op.opcode = Opcode::ArmVFPRegisterTransferAlways;
        break;
    case Opcode::ArmVFPDataProcessing:
        op.opcode = Opcode::ArmVFPDataProcessingAlways;
        break;
    default:
        break;
    }

    SpecializeAlwaysOp(op);
}

void FuseCompareBranch(Block& block) {
    if (block.ops.size() < 2) {
        return;
    }

    const Op& branch = block.ops.back();
    if (branch.opcode != Opcode::ArmBranch || branch.arg2 != 0) {
        return;
    }

    const u32 branch_condition = branch.arg1 & 0xF;
    if (branch_condition == ConditionCode::AL || branch_condition == ConditionCode::NV) {
        return;
    }

    Op& compare = block.ops[block.ops.size() - 2];
    const u32 compare_guest_size = compare.guest_size;
    const u32 fused_guest_size = compare_guest_size + branch.guest_size;
    Op fused = {
        .guest_size = static_cast<u8>(fused_guest_size),
    };

    switch (compare.opcode) {
    case Opcode::ArmCompareZeroImmediateNoPcAlways:
        fused.opcode = Opcode::ArmCompareImmediateBranchNoPcAlways;
        fused.arg0 = (compare.arg1 & 0xF) | (branch_condition << 8) |
                     (compare_guest_size << 16);
        fused.arg1 = 0;
        fused.arg2 = branch.arg0;
        break;
    case Opcode::ArmCompareImmediateNoPcAlways:
    case Opcode::ArmCompareNegativeImmediateNoPcAlways: {
        const bool compare_negative =
            compare.opcode == Opcode::ArmCompareNegativeImmediateNoPcAlways;
        fused.opcode = Opcode::ArmCompareImmediateBranchNoPcAlways;
        fused.arg0 = (compare.arg1 & 0xF) | (static_cast<u32>(compare_negative) << 4) |
                     (branch_condition << 8) | (compare_guest_size << 16);
        fused.arg1 = compare.arg2;
        fused.arg2 = branch.arg0;
        break;
    }
    case Opcode::ArmCompareRegisterNoPcAlways:
    case Opcode::ArmCompareNegativeRegisterNoPcAlways: {
        const bool compare_negative =
            compare.opcode == Opcode::ArmCompareNegativeRegisterNoPcAlways;
        const u32 rn = compare.arg1 & 0xF;
        const u32 rm = (compare.arg1 >> 8) & 0xF;
        fused.opcode = Opcode::ArmCompareRegisterBranchNoPcAlways;
        fused.arg0 = rn | (rm << 4) | (static_cast<u32>(compare_negative) << 8) |
                     (branch_condition << 12) | (compare_guest_size << 16);
        fused.arg1 = branch.arg0;
        break;
    }
    case Opcode::ArmCompareShiftedRegisterNoPcAlways:
    case Opcode::ArmCompareNegativeShiftedRegisterNoPcAlways: {
        const bool compare_negative =
            compare.opcode == Opcode::ArmCompareNegativeShiftedRegisterNoPcAlways;
        const u32 rn = compare.arg1 & 0xF;
        const u32 rm = (compare.arg1 >> 8) & 0xF;
        fused.opcode = Opcode::ArmCompareShiftedRegisterBranchNoPcAlways;
        fused.arg0 = rn | (rm << 4) | (static_cast<u32>(compare_negative) << 8) |
                     (branch_condition << 12) | (compare_guest_size << 16);
        fused.arg1 = branch.arg0;
        fused.arg2 = compare.arg2;
        break;
    }
    case Opcode::ArmCompareRegisterShiftedRegisterNoPcAlways:
    case Opcode::ArmCompareNegativeRegisterShiftedRegisterNoPcAlways: {
        const bool compare_negative =
            compare.opcode == Opcode::ArmCompareNegativeRegisterShiftedRegisterNoPcAlways;
        const u32 rn = compare.arg1 & 0xF;
        const u32 rm = (compare.arg1 >> 8) & 0xF;
        const u32 rs = (compare.arg1 >> 16) & 0xF;
        fused.opcode = Opcode::ArmCompareRegisterShiftedRegisterBranchNoPcAlways;
        fused.arg0 = rn | (rm << 4) | (rs << 8) |
                     (static_cast<u32>(compare_negative) << 12) |
                     (branch_condition << 16) | (compare_guest_size << 24);
        fused.arg1 = branch.arg0;
        fused.arg2 = compare.arg2;
        break;
    }
    case Opcode::ArmLogicalImmediateSetFlagsNoPcAlways: {
        const u32 data_opcode = compare.arg0 & 0xF;
        if (!IsFastLogicalSetFlagsOpcode(data_opcode)) {
            return;
        }
        const u32 rn = (compare.arg1 >> 8) & 0xF;
        const bool shifter_carry = ((compare.arg0 >> 8) & 1) != 0;
        const bool shifter_carry_from_c_flag = ((compare.arg0 >> 9) & 1) != 0;
        if (!FastLogicalSetFlagsWritesRd(data_opcode)) {
            const bool test_equal = data_opcode == 9;
            fused.opcode = Opcode::ArmTestImmediateBranchNoPcAlways;
            fused.arg0 = rn | (static_cast<u32>(test_equal) << 4) |
                         (static_cast<u32>(shifter_carry) << 5) |
                         (static_cast<u32>(shifter_carry_from_c_flag) << 6) |
                         (branch_condition << 8) | (compare_guest_size << 16);
        } else {
            const u32 rd = compare.arg1 & 0xF;
            fused.opcode = Opcode::ArmLogicalImmediateSetFlagsBranchNoPcAlways;
            fused.arg0 = data_opcode | (rd << 4) | (rn << 8) |
                         (branch_condition << 12) |
                         (static_cast<u32>(shifter_carry) << 16) |
                         (static_cast<u32>(shifter_carry_from_c_flag) << 17) |
                         (compare_guest_size << 24);
        }
        fused.arg1 = compare.arg2;
        fused.arg2 = branch.arg0;
        break;
    }
    case Opcode::ArmMoveImmediateSetFlagsAlways: {
        const bool shifter_carry = (compare.arg0 & 1) != 0;
        const bool shifter_carry_from_c_flag = ((compare.arg0 >> 1) & 1) != 0;
        const u32 rd = compare.arg1 & 0xF;
        fused.opcode = Opcode::ArmLogicalImmediateSetFlagsBranchNoPcAlways;
        fused.arg0 = 13 | (rd << 4) | (branch_condition << 12) |
                     (static_cast<u32>(shifter_carry) << 16) |
                     (static_cast<u32>(shifter_carry_from_c_flag) << 17) |
                     (compare_guest_size << 24);
        fused.arg1 = compare.arg2;
        fused.arg2 = branch.arg0;
        break;
    }
    case Opcode::ArmTstImmediateNoPcAlways:
    case Opcode::ArmTeqImmediateNoPcAlways: {
        const bool test_equal = compare.opcode == Opcode::ArmTeqImmediateNoPcAlways;
        const u32 rn = compare.arg1 & 0xF;
        const bool shifter_carry = (compare.arg0 & 1) != 0;
        const bool shifter_carry_from_c_flag = ((compare.arg0 >> 1) & 1) != 0;
        fused.opcode = Opcode::ArmTestImmediateBranchNoPcAlways;
        fused.arg0 = rn | (static_cast<u32>(test_equal) << 4) |
                     (static_cast<u32>(shifter_carry) << 5) |
                     (static_cast<u32>(shifter_carry_from_c_flag) << 6) |
                     (branch_condition << 8) | (compare_guest_size << 16);
        fused.arg1 = compare.arg2;
        fused.arg2 = branch.arg0;
        break;
    }
    case Opcode::ArmLogicalRegisterSetFlagsNoPcAlways: {
        const u32 data_opcode = compare.arg0 & 0xF;
        if (!IsFastLogicalSetFlagsOpcode(data_opcode)) {
            return;
        }
        const u32 rn = (compare.arg1 >> 8) & 0xF;
        const u32 rm = (compare.arg1 >> 16) & 0xF;
        if (!FastLogicalSetFlagsWritesRd(data_opcode)) {
            const bool test_equal = data_opcode == 9;
            fused.opcode = Opcode::ArmTestRegisterBranchNoPcAlways;
            fused.arg0 = rn | (rm << 4) | (static_cast<u32>(test_equal) << 8) |
                         (branch_condition << 12) | (compare_guest_size << 16);
        } else {
            const u32 rd = compare.arg1 & 0xF;
            fused.opcode = Opcode::ArmLogicalRegisterSetFlagsBranchNoPcAlways;
            fused.arg0 = data_opcode | (rd << 4) | (rn << 8) | (rm << 12) |
                         (branch_condition << 16) | (compare_guest_size << 24);
        }
        fused.arg1 = branch.arg0;
        break;
    }
    case Opcode::ArmTstRegisterNoShiftNoPcAlways:
    case Opcode::ArmTeqRegisterNoShiftNoPcAlways: {
        const bool test_equal = compare.opcode == Opcode::ArmTeqRegisterNoShiftNoPcAlways;
        const u32 rn = compare.arg1 & 0xF;
        const u32 rm = (compare.arg1 >> 8) & 0xF;
        fused.opcode = Opcode::ArmTestRegisterBranchNoPcAlways;
        fused.arg0 = rn | (rm << 4) | (static_cast<u32>(test_equal) << 8) |
                     (branch_condition << 12) | (compare_guest_size << 16);
        fused.arg1 = branch.arg0;
        break;
    }
    case Opcode::ArmMoveRegisterSetFlagsAlways:
    case Opcode::ArmMoveNotRegisterSetFlagsAlways: {
        const bool move_not = compare.opcode == Opcode::ArmMoveNotRegisterSetFlagsAlways;
        const u32 rd = compare.arg1 & 0xF;
        const u32 rm = (compare.arg1 >> 8) & 0xF;
        fused.opcode = Opcode::ArmLogicalRegisterSetFlagsBranchNoPcAlways;
        fused.arg0 = (move_not ? 15U : 13U) | (rd << 4) | (rm << 12) |
                     (branch_condition << 16) | (compare_guest_size << 24);
        fused.arg1 = branch.arg0;
        break;
    }
    case Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlways:
    case Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysLsl:
    case Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysLsr:
    case Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysAsr:
    case Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysRor: {
        const u32 data_opcode = compare.arg0 & 0xF;
        if (!IsFastLogicalSetFlagsOpcode(data_opcode)) {
            return;
        }
        const u32 rn = (compare.arg1 >> 8) & 0xF;
        const u32 rm = (compare.arg1 >> 16) & 0xF;
        if (!FastLogicalSetFlagsWritesRd(data_opcode)) {
            const bool test_equal = data_opcode == 9;
            fused.opcode = Opcode::ArmTestShiftedRegisterBranchNoPcAlways;
            fused.arg0 = rn | (rm << 4) | (static_cast<u32>(test_equal) << 8) |
                         (branch_condition << 12) | (compare_guest_size << 16);
        } else {
            const u32 rd = compare.arg1 & 0xF;
            fused.opcode = Opcode::ArmLogicalShiftedRegisterSetFlagsBranchNoPcAlways;
            fused.arg0 = data_opcode | (rd << 4) | (rn << 8) | (rm << 12) |
                         (branch_condition << 16) | (compare_guest_size << 24);
        }
        fused.arg1 = branch.arg0;
        fused.arg2 = compare.arg2;
        break;
    }
    case Opcode::ArmTstShiftedRegisterNoPcAlwaysLsl:
    case Opcode::ArmTstShiftedRegisterNoPcAlwaysLsr:
    case Opcode::ArmTstShiftedRegisterNoPcAlwaysAsr:
    case Opcode::ArmTstShiftedRegisterNoPcAlwaysRor: {
        const u32 rn = (compare.arg1 >> 8) & 0xF;
        const u32 rm = (compare.arg1 >> 16) & 0xF;
        fused.opcode = Opcode::ArmTestShiftedRegisterBranchNoPcAlways;
        fused.arg0 = rn | (rm << 4) | (branch_condition << 12) |
                     (compare_guest_size << 16);
        fused.arg1 = branch.arg0;
        fused.arg2 = compare.arg2;
        break;
    }
    case Opcode::ArmTeqShiftedRegisterNoPcAlwaysLsl:
    case Opcode::ArmTeqShiftedRegisterNoPcAlwaysLsr:
    case Opcode::ArmTeqShiftedRegisterNoPcAlwaysAsr:
    case Opcode::ArmTeqShiftedRegisterNoPcAlwaysRor: {
        const u32 rn = (compare.arg1 >> 8) & 0xF;
        const u32 rm = (compare.arg1 >> 16) & 0xF;
        fused.opcode = Opcode::ArmTestShiftedRegisterBranchNoPcAlways;
        fused.arg0 = rn | (rm << 4) | (1U << 8) | (branch_condition << 12) |
                     (compare_guest_size << 16);
        fused.arg1 = branch.arg0;
        fused.arg2 = compare.arg2;
        break;
    }
    case Opcode::ArmLogicalRegisterShiftedRegisterSetFlagsNoPcAlways: {
        const u32 data_opcode = compare.arg0 & 0xF;
        if (!IsFastLogicalSetFlagsOpcode(data_opcode)) {
            return;
        }
        const u32 rn = (compare.arg1 >> 8) & 0xF;
        const u32 rm = (compare.arg1 >> 16) & 0xF;
        const u32 rs = (compare.arg1 >> 24) & 0xF;
        if (!FastLogicalSetFlagsWritesRd(data_opcode)) {
            const bool test_equal = data_opcode == 9;
            fused.opcode = Opcode::ArmTestRegisterShiftedRegisterBranchNoPcAlways;
            fused.arg0 = rn | (rm << 4) | (rs << 8) |
                         (static_cast<u32>(test_equal) << 12) |
                         (branch_condition << 16) | (compare_guest_size << 24);
        } else {
            const u32 rd = compare.arg1 & 0xF;
            fused.opcode = Opcode::ArmLogicalRegisterShiftedRegisterSetFlagsBranchNoPcAlways;
            fused.arg0 = data_opcode | (rd << 4) | (rn << 8) | (rm << 12) |
                         (rs << 16) | (branch_condition << 20) |
                         (compare_guest_size << 24);
        }
        fused.arg1 = branch.arg0;
        fused.arg2 = compare.arg2;
        break;
    }
    case Opcode::ArmAddImmediateSetFlagsNoPcAlways:
    case Opcode::ArmSubImmediateSetFlagsNoPcAlways: {
        const bool subtract = compare.opcode == Opcode::ArmSubImmediateSetFlagsNoPcAlways;
        const u32 rd = compare.arg1 & 0xF;
        const u32 rn = (compare.arg1 >> 8) & 0xF;
        fused.opcode = Opcode::ArmAddSubImmediateSetFlagsBranchNoPcAlways;
        fused.arg0 = rd | (rn << 4) | (static_cast<u32>(subtract) << 8) |
                     (branch_condition << 12) | (compare_guest_size << 16);
        fused.arg1 = compare.arg2;
        fused.arg2 = branch.arg0;
        break;
    }
    case Opcode::ArmAddRegisterSetFlagsNoPcAlways:
    case Opcode::ArmSubRegisterSetFlagsNoPcAlways: {
        const bool subtract = compare.opcode == Opcode::ArmSubRegisterSetFlagsNoPcAlways;
        const u32 rd = compare.arg1 & 0xF;
        const u32 rn = (compare.arg1 >> 8) & 0xF;
        const u32 rm = (compare.arg1 >> 16) & 0xF;
        fused.opcode = Opcode::ArmAddSubRegisterSetFlagsBranchNoPcAlways;
        fused.arg0 = rd | (rn << 4) | (rm << 8) | (static_cast<u32>(subtract) << 12) |
                     (branch_condition << 16) | (compare_guest_size << 24);
        fused.arg1 = branch.arg0;
        break;
    }
    case Opcode::ArmAddShiftedRegisterSetFlagsNoPcAlways:
    case Opcode::ArmSubShiftedRegisterSetFlagsNoPcAlways: {
        const bool subtract = compare.opcode == Opcode::ArmSubShiftedRegisterSetFlagsNoPcAlways;
        const u32 rd = compare.arg1 & 0xF;
        const u32 rn = (compare.arg1 >> 8) & 0xF;
        const u32 rm = (compare.arg1 >> 16) & 0xF;
        fused.opcode = Opcode::ArmAddSubShiftedRegisterSetFlagsBranchNoPcAlways;
        fused.arg0 = rd | (rn << 4) | (rm << 8) | (static_cast<u32>(subtract) << 12) |
                     (branch_condition << 16) | (compare_guest_size << 24);
        fused.arg1 = branch.arg0;
        fused.arg2 = compare.arg2;
        break;
    }
    case Opcode::ArmAddRegisterShiftedRegisterSetFlagsNoPcAlways:
    case Opcode::ArmSubRegisterShiftedRegisterSetFlagsNoPcAlways: {
        const bool subtract =
            compare.opcode == Opcode::ArmSubRegisterShiftedRegisterSetFlagsNoPcAlways;
        const u32 rd = compare.arg1 & 0xF;
        const u32 rn = (compare.arg1 >> 8) & 0xF;
        const u32 rm = (compare.arg1 >> 16) & 0xF;
        const u32 rs = (compare.arg1 >> 24) & 0xF;
        fused.opcode = Opcode::ArmAddSubRegisterShiftedRegisterSetFlagsBranchNoPcAlways;
        fused.arg0 = rd | (rn << 4) | (rm << 8) | (rs << 12) |
                     (static_cast<u32>(subtract) << 16) |
                     (branch_condition << 20) | (compare_guest_size << 24);
        fused.arg1 = branch.arg0;
        fused.arg2 = compare.arg2;
        break;
    }
    case Opcode::ArmArithmeticImmediateSetFlagsNoPcAlways: {
        const u32 data_opcode = compare.arg0 & 0xF;
        if (!IsFastCarryArithmeticWriteOpcode(data_opcode)) {
            return;
        }
        const u32 rd = compare.arg1 & 0xF;
        const u32 rn = (compare.arg1 >> 8) & 0xF;
        fused.opcode = Opcode::ArmCarryArithmeticImmediateSetFlagsBranchNoPcAlways;
        fused.arg0 = data_opcode | (rd << 4) | (rn << 8) |
                     (branch_condition << 12) | (compare_guest_size << 24);
        fused.arg1 = compare.arg2;
        fused.arg2 = branch.arg0;
        break;
    }
    case Opcode::ArmArithmeticRegisterSetFlagsNoPcAlways: {
        const u32 data_opcode = compare.arg0 & 0xF;
        if (!IsFastCarryArithmeticWriteOpcode(data_opcode)) {
            return;
        }
        const u32 rd = compare.arg1 & 0xF;
        const u32 rn = (compare.arg1 >> 8) & 0xF;
        const u32 rm = (compare.arg1 >> 16) & 0xF;
        fused.opcode = Opcode::ArmCarryArithmeticRegisterSetFlagsBranchNoPcAlways;
        fused.arg0 = data_opcode | (rd << 4) | (rn << 8) | (rm << 12) |
                     (branch_condition << 16) | (compare_guest_size << 24);
        fused.arg1 = branch.arg0;
        break;
    }
    case Opcode::ArmArithmeticShiftedRegisterSetFlagsNoPcAlways: {
        const u32 data_opcode = compare.arg0 & 0xF;
        if (!IsFastCarryArithmeticWriteOpcode(data_opcode)) {
            return;
        }
        const u32 rd = compare.arg1 & 0xF;
        const u32 rn = (compare.arg1 >> 8) & 0xF;
        const u32 rm = (compare.arg1 >> 16) & 0xF;
        fused.opcode = Opcode::ArmCarryArithmeticShiftedRegisterSetFlagsBranchNoPcAlways;
        fused.arg0 = data_opcode | (rd << 4) | (rn << 8) | (rm << 12) |
                     (branch_condition << 16) | (compare_guest_size << 24);
        fused.arg1 = branch.arg0;
        fused.arg2 = compare.arg2;
        break;
    }
    case Opcode::ArmArithmeticRegisterShiftedRegisterSetFlagsNoPcAlways: {
        const u32 data_opcode = compare.arg0 & 0xF;
        if (!IsFastCarryArithmeticWriteOpcode(data_opcode)) {
            return;
        }
        const u32 rd = compare.arg1 & 0xF;
        const u32 rn = (compare.arg1 >> 8) & 0xF;
        const u32 rm = (compare.arg1 >> 16) & 0xF;
        const u32 rs = (compare.arg1 >> 24) & 0xF;
        fused.opcode =
            Opcode::ArmCarryArithmeticRegisterShiftedRegisterSetFlagsBranchNoPcAlways;
        fused.arg0 = data_opcode | (rd << 4) | (rn << 8) | (rm << 12) |
                     (rs << 16) | (branch_condition << 20) |
                     (compare_guest_size << 24);
        fused.arg1 = branch.arg0;
        fused.arg2 = compare.arg2;
        break;
    }
    default:
        return;
    }

    compare = fused;
    block.ops.pop_back();
}

void AddConditionalSkipGuards(Block& block) {
    constexpr std::size_t MinRunLength = 2;

    for (std::size_t i = 0; i < block.ops.size();) {
        u32 condition = 0;
        if (!TryGetConditionalSkipCondition(block.ops[i], condition)) {
            i++;
            continue;
        }

        const std::size_t run_start = i;
        std::size_t run_length = 0;
        u32 run_bytes = 0;
        do {
            run_length++;
            run_bytes += block.ops[i].guest_size;
            i++;
            u32 next_condition = 0;
            if (i >= block.ops.size() ||
                !TryGetConditionalSkipCondition(block.ops[i], next_condition) ||
                next_condition != condition) {
                break;
            }
        } while (true);

        if (run_length < MinRunLength) {
            continue;
        }

        const bool inserted = block.ops.insert(run_start, {
            .opcode = SelectConditionalSkipOpcode(condition),
            .guest_size = 0,
            .arg0 = condition,
            .arg1 = static_cast<u32>(run_length),
            .arg2 = run_bytes,
        });
        if (inserted) {
            bool condition_still_known = true;
            for (std::size_t j = run_start + 1; j <= run_start + run_length; ++j) {
                Op& guarded_op = block.ops[j];
                const bool writes_condition_flags = WritesConditionFlags(guarded_op);
                if (condition_still_known) {
                    ConvertGuardedOpToAlways(guarded_op);
                }
                condition_still_known = condition_still_known && !writes_condition_flags;
            }
            i++;
        }
    }
}

bool DirectBranchPreservesCpsrKey(const Block& block) {
    if (block.terminal != Terminal::DirectBranch || block.ops.empty()) {
        return false;
    }

    switch (block.ops.back().opcode) {
    case Opcode::ArmBranch:
    case Opcode::ArmBranchAlways:
    case Opcode::ArmCompareImmediateBranchNoPcAlways:
    case Opcode::ArmCompareRegisterBranchNoPcAlways:
    case Opcode::ArmCompareShiftedRegisterBranchNoPcAlways:
    case Opcode::ArmCompareRegisterShiftedRegisterBranchNoPcAlways:
    case Opcode::ArmTestImmediateBranchNoPcAlways:
    case Opcode::ArmTestRegisterBranchNoPcAlways:
    case Opcode::ArmTestShiftedRegisterBranchNoPcAlways:
    case Opcode::ArmTestRegisterShiftedRegisterBranchNoPcAlways:
    case Opcode::ArmAddSubImmediateSetFlagsBranchNoPcAlways:
    case Opcode::ArmAddSubRegisterSetFlagsBranchNoPcAlways:
    case Opcode::ArmAddSubShiftedRegisterSetFlagsBranchNoPcAlways:
    case Opcode::ArmAddSubRegisterShiftedRegisterSetFlagsBranchNoPcAlways:
    case Opcode::ArmLogicalImmediateSetFlagsBranchNoPcAlways:
    case Opcode::ArmLogicalRegisterSetFlagsBranchNoPcAlways:
    case Opcode::ArmLogicalShiftedRegisterSetFlagsBranchNoPcAlways:
    case Opcode::ArmLogicalRegisterShiftedRegisterSetFlagsBranchNoPcAlways:
    case Opcode::ArmCarryArithmeticImmediateSetFlagsBranchNoPcAlways:
    case Opcode::ArmCarryArithmeticRegisterSetFlagsBranchNoPcAlways:
    case Opcode::ArmCarryArithmeticShiftedRegisterSetFlagsBranchNoPcAlways:
    case Opcode::ArmCarryArithmeticRegisterShiftedRegisterSetFlagsBranchNoPcAlways:
        return true;
    default:
        return false;
    }
}

bool TryAppendArmInstruction(Block& block, u32 instruction, u32 pc) {
    const u32 condition = instruction >> 28;
    if (instruction == 0xF57FF01F) {
        block.ops.push_back({
            .opcode = Opcode::ArmClearExclusive,
        });
        return true;
    }

    const bool is_change_processor_state = ((instruction >> 20) & 0xFFF) == 0xF10 &&
                                           ((instruction >> 16) & 1) == 0 &&
                                           ((instruction >> 5) & 1) == 0;
    if (is_change_processor_state) {
        block.ops.push_back({
            .opcode = Opcode::ArmChangeProcessorState,
            .arg0 = instruction,
        });
        return true;
    }

    const bool is_set_endian = ((instruction >> 16) & 0xFFFF) == 0xF101 &&
                               ((instruction >> 4) & 0xF) == 0;
    if (is_set_endian) {
        block.ops.push_back({
            .opcode = Opcode::ArmSetEndian,
            .arg0 = (instruction >> 9) & 1,
        });
        return true;
    }

    const bool is_breakpoint = ((instruction >> 20) & 0xFF) == 0x12 &&
                               ((instruction >> 4) & 0xF) == 0x7;
    if (is_breakpoint) {
        block.ops.push_back({
            .opcode = Opcode::ArmHint,
            .arg0 = ConditionCode::AL,
        });
        return true;
    }

    const u32 coprocessor_pair_opcode = (instruction >> 20) & 0xFF;
    const bool is_coprocessor_pair_transfer =
        coprocessor_pair_opcode == 0xC4 || coprocessor_pair_opcode == 0xC5;
    if (is_coprocessor_pair_transfer) {
        const u32 cp_num = (instruction >> 8) & 0xF;
        if (cp_num != 10 && cp_num != 11) {
            block.ops.push_back({
                .opcode = Opcode::ArmHint,
                .arg0 = ConditionCode::AL,
            });
            return true;
        }
    }

    const bool is_coprocessor_load_store = ((instruction >> 25) & 0x7) == 0x6;
    if (is_coprocessor_load_store) {
        const u32 cp_num = (instruction >> 8) & 0xF;
        if (cp_num != 10 && cp_num != 11) {
            block.ops.push_back({
                .opcode = Opcode::ArmHint,
                .arg0 = ConditionCode::AL,
            });
            return true;
        }
    }

    const bool is_preload_data = ((instruction >> 26) & 0x3F) == 0x3D &&
                                 ((instruction >> 24) & 1) != 0 &&
                                 ((instruction >> 20) & 0x7) == 0x5 &&
                                 ((instruction >> 12) & 0xF) == 0xF;
    if (is_preload_data) {
        block.ops.push_back({
            .opcode = Opcode::ArmHint,
            .arg0 = ConditionCode::AL,
        });
        return true;
    }

    const bool is_blx_immediate = ((instruction >> 25) & 0x7F) == 0x7D;
    if (is_blx_immediate) {
        const s32 offset = static_cast<s32>(instruction << 8) >> 6;
        const u32 h_bit = ((instruction >> 24) & 1) << 1;
        block.terminal = Terminal::DirectBranch;
        block.ops.push_back({
            .opcode = Opcode::ArmBranchLinkExchange,
            .arg0 = ConditionCode::AL | (1U << 8),
            .arg1 = pc + 8 + static_cast<u32>(offset) + h_bit,
            .arg2 = pc + 4,
        });
        return true;
    }

    const bool is_store_return_state = ((instruction >> 25) & 0x7F) == 0x7C &&
                                       ((instruction >> 22) & 1) != 0 &&
                                       ((instruction >> 16) & 0x1F) == 0x0D &&
                                       ((instruction >> 8) & 0xF) == 0x5;
    if (is_store_return_state) {
        const bool pre_indexed = ((instruction >> 24) & 1) != 0;
        const bool add_offset = ((instruction >> 23) & 1) != 0;
        const bool writeback = ((instruction >> 21) & 1) != 0;
        block.ops.push_back({
            .opcode = Opcode::ArmStoreReturnState,
            .arg0 = static_cast<u32>(writeback) | (static_cast<u32>(add_offset) << 1) |
                    (static_cast<u32>(pre_indexed) << 2),
            .arg1 = 13,
            .arg2 = CountBits(instruction & 0xFFFF),
        });
        return true;
    }

    const bool is_return_from_exception = ((instruction >> 25) & 0x7F) == 0x7C &&
                                          ((instruction >> 22) & 1) == 0 &&
                                          ((instruction >> 20) & 1) != 0 &&
                                          ((instruction >> 8) & 0xF) == 0xA;
    if (is_return_from_exception) {
        const bool pre_indexed = ((instruction >> 24) & 1) != 0;
        const bool add_offset = ((instruction >> 23) & 1) != 0;
        const bool writeback = ((instruction >> 21) & 1) != 0;
        const u32 rn = (instruction >> 16) & 0xF;
        block.terminal = Terminal::IndirectBranch;
        block.ops.push_back({
            .opcode = Opcode::ArmReturnFromException,
            .arg0 = static_cast<u32>(writeback) | (static_cast<u32>(add_offset) << 1) |
                    (static_cast<u32>(pre_indexed) << 2),
            .arg1 = rn,
            .arg2 = CountBits(instruction & 0xFFFF),
        });
        return true;
    }

    const bool is_supervisor_call = ((instruction >> 24) & 0xF) == 0xF;
    if (is_supervisor_call) {
        block.terminal = Terminal::Exception;
        block.ops.push_back({
            .opcode = Opcode::ArmSupervisorCall,
            .arg0 = condition,
            .arg1 = instruction & 0x00FFFFFF,
        });
        return true;
    }

    const bool is_vfp_move_immediate = Bits(instruction, 23, 27) == 0x1D &&
                                       Bits(instruction, 20, 21) == 0x3 &&
                                       Bits(instruction, 9, 11) == 0x5 &&
                                       Bits(instruction, 4, 7) == 0;
    if (is_vfp_move_immediate) {
        const bool single = Bits(instruction, 8, 8) == 0;
        const u32 d = single ? (Bits(instruction, 12, 15) << 1) | Bits(instruction, 22, 22)
                             : Bits(instruction, 12, 15) | (Bits(instruction, 22, 22) << 4);
        const u32 imm8 = (Bits(instruction, 16, 19) << 4) | Bits(instruction, 0, 3);
        const u32 imm = single ? (Bits(imm8, 7, 7) << 31) |
                                     ((Bits(imm8, 6, 6) == 0 ? 1U : 0U) << 30) |
                                     ((Bits(imm8, 6, 6) != 0 ? 0x1FU : 0U) << 25) |
                                     (Bits(imm8, 0, 5) << 19)
                               : (Bits(imm8, 7, 7) << 31) |
                                     ((Bits(imm8, 6, 6) == 0 ? 1U : 0U) << 30) |
                                     ((Bits(imm8, 6, 6) != 0 ? 0xFFU : 0U) << 22) |
                                     (Bits(imm8, 0, 5) << 16);
        block.ops.push_back({
            .opcode = condition == ConditionCode::AL ? Opcode::ArmVFPDataProcessingAlways
                                                     : Opcode::ArmVFPDataProcessing,
            .arg0 = condition | (1U << 8) | (static_cast<u32>(single) << 10),
            .arg1 = d,
            .arg2 = imm,
        });
        return true;
    }

    const bool is_vfp_register_move = Bits(instruction, 23, 27) == 0x1D &&
                                      Bits(instruction, 16, 21) == 0x30 &&
                                      Bits(instruction, 9, 11) == 0x5 &&
                                      Bits(instruction, 6, 7) == 0x1 &&
                                      Bits(instruction, 4, 4) == 0;
    if (is_vfp_register_move) {
        const bool single = Bits(instruction, 8, 8) == 0;
        const u32 d = single ? (Bits(instruction, 12, 15) << 1) | Bits(instruction, 22, 22)
                             : Bits(instruction, 12, 15) | (Bits(instruction, 22, 22) << 4);
        const u32 m = single ? (Bits(instruction, 0, 3) << 1) | Bits(instruction, 5, 5)
                             : Bits(instruction, 0, 3) | (Bits(instruction, 5, 5) << 4);
        block.ops.push_back({
            .opcode = condition == ConditionCode::AL ? Opcode::ArmVFPDataProcessingAlways
                                                     : Opcode::ArmVFPDataProcessing,
            .arg0 = condition | (2U << 8) | (static_cast<u32>(single) << 10),
            .arg1 = d,
            .arg2 = m,
        });
        return true;
    }

    if (IsSupportedVFPDataProcessingInstruction(instruction)) {
        block.ops.push_back({
            .opcode = condition == ConditionCode::AL ? Opcode::ArmVFPDataProcessingAlways
                                                     : Opcode::ArmVFPDataProcessing,
            .arg0 = condition,
            .arg1 = instruction,
        });
        return true;
    }

    const bool is_vfp_system_register_transfer =
        (instruction & 0x0FE00FFF) == 0x0EE00A10;
    if (is_vfp_system_register_transfer) {
        const bool read_from_vfp = ((instruction >> 20) & 1) != 0;
        const u32 vfp_register = (instruction >> 16) & 0xF;
        const u32 rt = (instruction >> 12) & 0xF;
        const bool apsr_fpscr_transfer = read_from_vfp && vfp_register == 1 && rt == 15;
        if (rt != 15 || apsr_fpscr_transfer) {
            block.ops.push_back({
                .opcode = Opcode::ArmVFPSystemRegisterTransfer,
                .arg0 = condition | (static_cast<u32>(read_from_vfp) << 8),
                .arg1 = vfp_register | (rt << 8),
            });
            return true;
        }
    }

    const bool is_vfp_arm_single_transfer = (instruction & 0x0FE00F7F) == 0x0E000A10;
    if (is_vfp_arm_single_transfer) {
        const bool to_arm = ((instruction >> 20) & 1) != 0;
        const u32 rt = (instruction >> 12) & 0xF;
        if (rt != 15) {
            const u32 ext_reg = ((instruction >> 7) & 1) | (((instruction >> 16) & 0xF) << 1);
            block.ops.push_back({
                .opcode = condition == ConditionCode::AL ? Opcode::ArmVFPRegisterTransferAlways
                                                         : Opcode::ArmVFPRegisterTransfer,
                .arg0 = condition | (static_cast<u32>(to_arm) << 8),
                .arg1 = rt | (ext_reg << 8),
            });
            return true;
        }
    }

    const bool is_vfp_arm_scalar_to_register = (instruction & 0x0F100F1F) == 0x0E100B10;
    const bool is_vfp_arm_register_to_scalar = (instruction & 0x0F900F1F) == 0x0E000B10;
    if (is_vfp_arm_scalar_to_register || is_vfp_arm_register_to_scalar) {
        const u32 rt = (instruction >> 12) & 0xF;
        if (rt != 15) {
            const u32 d = ((instruction >> 16) & 0xF) | (((instruction >> 7) & 1) << 4);
            const u32 ext_reg = d * 2 + ((instruction >> 21) & 1);
            block.ops.push_back({
                .opcode = condition == ConditionCode::AL ? Opcode::ArmVFPRegisterTransferAlways
                                                         : Opcode::ArmVFPRegisterTransfer,
                .arg0 = condition |
                        (static_cast<u32>(is_vfp_arm_scalar_to_register) << 8),
                .arg1 = rt | (ext_reg << 8),
            });
            return true;
        }
    }

    const bool is_vfp_arm_two_single_transfer = Bits(instruction, 21, 27) == 0x62 &&
                                                Bits(instruction, 8, 11) == 0xA &&
                                                Bits(instruction, 4, 4) != 0;
    const bool is_vfp_arm_double_transfer = Bits(instruction, 21, 27) == 0x62 &&
                                            Bits(instruction, 6, 11) == 0x2C &&
                                            Bits(instruction, 4, 4) != 0;
    if (is_vfp_arm_two_single_transfer || is_vfp_arm_double_transfer) {
        const u32 rt = (instruction >> 12) & 0xF;
        const u32 rt2 = (instruction >> 16) & 0xF;
        const bool to_arm = ((instruction >> 20) & 1) != 0;
        const u32 ext_reg =
            is_vfp_arm_two_single_transfer
                ? ((instruction & 0xF) << 1) | ((instruction >> 5) & 1)
                : ((((instruction >> 5) & 1) << 4) | (instruction & 0xF)) * 2;
        block.ops.push_back({
            .opcode = condition == ConditionCode::AL ? Opcode::ArmVFPRegisterTransferAlways
                                                     : Opcode::ArmVFPRegisterTransfer,
            .arg0 = condition | (static_cast<u32>(to_arm) << 8) | (1U << 9),
            .arg1 = rt | (rt2 << 8),
            .arg2 = ext_reg,
        });
        return true;
    }

    const bool is_vfp_push = (instruction & 0x0FBF0E00) == 0x0D2D0A00;
    const bool is_vfp_pop = (instruction & 0x0FBF0E00) == 0x0CBD0A00;
    if (is_vfp_push || is_vfp_pop) {
        const bool single = ((instruction >> 8) & 1) == 0;
        const u32 vfp_reg =
            single ? (((instruction >> 12) & 0xF) << 1) | ((instruction >> 22) & 1)
                   : ((((instruction >> 12) & 0xF) | (((instruction >> 22) & 1) << 4)) * 2);
        const u32 imm32 = (instruction & 0xFF) << 2;
        const bool register_count_matches_bytes = single || ((instruction & 1) == 0);
        const u32 register_words = single ? (instruction & 0xFF) : ((instruction & 0xFE) >> 1) * 2;
        if (register_count_matches_bytes && imm32 != 0 && vfp_reg + register_words <= 64) {
            if (condition == ConditionCode::AL) {
                const Opcode opcode =
                    is_vfp_pop ? Opcode::ArmVFPLoadMultipleFast : Opcode::ArmVFPStoreMultipleFast;
                block.ops.push_back({
                    .opcode = opcode,
                    .arg0 = static_cast<u32>(single) |
                            (static_cast<u32>(is_vfp_pop) << 1) | (1U << 2),
                    .arg1 = 13 | (vfp_reg << 8),
                    .arg2 = imm32,
                });
                return true;
            }
            block.ops.push_back({
                .opcode = Opcode::ArmVFPLoadStore,
                .arg0 = condition | (static_cast<u32>(is_vfp_pop) << 8) |
                        (static_cast<u32>(single) << 9) |
                        (static_cast<u32>(is_vfp_pop) << 10) | (1U << 11) | (1U << 12),
                .arg1 = 13 | (vfp_reg << 8),
                .arg2 = imm32,
            });
            return true;
        }
        return false;
    }

    const bool is_vfp_load_store_multiple = (instruction & 0x0E000E00) == 0x0C000A00;
    if (is_vfp_load_store_multiple) {
        const bool pre_indexed = ((instruction >> 24) & 1) != 0;
        const bool writeback = ((instruction >> 21) & 1) != 0;
        const bool single_transfer_alias = pre_indexed && !writeback;
        if (!single_transfer_alias) {
            const bool load = ((instruction >> 20) & 1) != 0;
            const bool single = ((instruction >> 8) & 1) == 0;
            const bool add_offset = ((instruction >> 23) & 1) != 0;
            const u32 rn = (instruction >> 16) & 0xF;
            const u32 vfp_reg =
                single ? (((instruction >> 12) & 0xF) << 1) | ((instruction >> 22) & 1)
                       : ((((instruction >> 12) & 0xF) | (((instruction >> 22) & 1) << 4)) * 2);
            const u32 imm32 = (instruction & 0xFF) << 2;
            const bool register_count_matches_bytes = single || ((instruction & 1) == 0);
            const u32 register_words =
                single ? (instruction & 0xFF) : ((instruction & 0xFE) >> 1) * 2;
            if (register_count_matches_bytes && imm32 != 0 && vfp_reg + register_words <= 64) {
                if (condition == ConditionCode::AL && rn != 15) {
                    const Opcode opcode =
                        load ? Opcode::ArmVFPLoadMultipleFast : Opcode::ArmVFPStoreMultipleFast;
                    block.ops.push_back({
                        .opcode = opcode,
                        .arg0 = static_cast<u32>(single) |
                                (static_cast<u32>(add_offset) << 1) |
                                (static_cast<u32>(writeback) << 2),
                        .arg1 = rn | (vfp_reg << 8),
                        .arg2 = imm32,
                    });
                    return true;
                }
                block.ops.push_back({
                    .opcode = Opcode::ArmVFPLoadStore,
                    .arg0 = condition | (static_cast<u32>(load) << 8) |
                            (static_cast<u32>(single) << 9) |
                            (static_cast<u32>(add_offset) << 10) | (1U << 11) |
                            (static_cast<u32>(writeback) << 12),
                    .arg1 = rn | (vfp_reg << 8),
                    .arg2 = imm32,
                });
                return true;
            }
            return false;
        }
    }

    const bool is_vfp_load_store = (instruction & 0x0F200E00) == 0x0D000A00;
    if (is_vfp_load_store) {
        const bool load = ((instruction >> 20) & 1) != 0;
        const bool single = ((instruction >> 8) & 1) == 0;
        const bool add_offset = ((instruction >> 23) & 1) != 0;
        const u32 rn = (instruction >> 16) & 0xF;
        const u32 vfp_reg =
            single ? (((instruction >> 12) & 0xF) << 1) | ((instruction >> 22) & 1)
                   : ((((instruction >> 12) & 0xF) | (((instruction >> 22) & 1) << 4)) * 2);
        if (condition == ConditionCode::AL) {
            block.ops.push_back({
                .opcode = single ? (load ? Opcode::ArmVFPLoadSingleFast
                                          : Opcode::ArmVFPStoreSingleFast)
                                 : (load ? Opcode::ArmVFPLoadDoubleFast
                                          : Opcode::ArmVFPStoreDoubleFast),
                .arg0 = static_cast<u32>(add_offset),
                .arg1 = rn | (vfp_reg << 8),
                .arg2 = (instruction & 0xFF) << 2,
            });
            return true;
        }
        block.ops.push_back({
            .opcode = Opcode::ArmVFPLoadStore,
            .arg0 = condition | (static_cast<u32>(load) << 8) |
                    (static_cast<u32>(single) << 9) |
                    (static_cast<u32>(add_offset) << 10),
            .arg1 = rn | (vfp_reg << 8),
            .arg2 = (instruction & 0xFF) << 2,
        });
        return true;
    }

    // CP10/CP11 encodings not recognized as VFP above fall through to Dyncom's
    // generic pair/load-store stubs.
    if (is_coprocessor_pair_transfer || is_coprocessor_load_store) {
        block.ops.push_back({
            .opcode = Opcode::ArmHint,
            .arg0 = ConditionCode::AL,
        });
        return true;
    }

    const bool is_coprocessor_register_transfer = ((instruction >> 24) & 0xF) == 0xE &&
                                                  ((instruction >> 4) & 1) != 0;
    if (is_coprocessor_register_transfer) {
        const bool read_from_coprocessor = ((instruction >> 20) & 1) != 0;
        const u32 crn = (instruction >> 16) & 0xF;
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 cp_num = (instruction >> 8) & 0xF;
        const u32 opcode_1 = (instruction >> 21) & 0x7;
        const u32 opcode_2 = (instruction >> 5) & 0x7;
        const u32 crm = instruction & 0xF;

        if (cp_num == 15 && (rd != 15 || read_from_coprocessor)) {
            block.ops.push_back({
                .opcode = Opcode::ArmCoprocessor15Transfer,
                .arg0 = condition | (static_cast<u32>(read_from_coprocessor) << 8),
                .arg1 = rd | (crn << 8) | (crm << 16),
                .arg2 = opcode_1 | (opcode_2 << 8),
            });
            return true;
        }
        block.ops.push_back({
            .opcode = Opcode::ArmHint,
            .arg0 = ConditionCode::AL,
        });
        return true;
    }

    const bool is_coprocessor_data_processing = ((instruction >> 24) & 0xF) == 0xE &&
                                                 ((instruction >> 4) & 1) == 0;
    if (is_coprocessor_data_processing) {
        block.ops.push_back({
            .opcode = Opcode::ArmCoprocessorDataProcessing,
            .arg0 = condition,
        });
        return true;
    }

    const bool is_hint = ((instruction >> 23) & 0x1F) == 0x6 &&
                         ((instruction >> 22) & 1) == 0 &&
                         ((instruction >> 20) & 0x3) == 0x2 &&
                         ((instruction >> 16) & 0xF) == 0 &&
                         (instruction & 0xFF) <= 4;
    if (is_hint) {
        block.ops.push_back({
            .opcode = Opcode::ArmHint,
            .arg0 = condition,
        });
        return true;
    }

    const bool is_mrs = ((instruction >> 23) & 0x1F) == 0x2 &&
                        ((instruction >> 20) & 0x3) == 0 && ((instruction >> 16) & 0xF) == 0xF &&
                        (instruction & 0xFFF) == 0;
    if (is_mrs) {
        const u32 rd = (instruction >> 12) & 0xF;
        const bool source_spsr = ((instruction >> 22) & 1) != 0;
        block.ops.push_back({
            .opcode = Opcode::ArmMoveStatusToRegister,
            .arg0 = condition | (static_cast<u32>(source_spsr) << 8),
            .arg1 = rd,
        });
        return true;
    }

    const bool is_msr_register = ((instruction >> 23) & 0x1F) == 0x2 &&
                                 ((instruction >> 20) & 0x3) == 0x2 &&
                                 ((instruction >> 4) & 0xF) == 0;
    const bool is_msr_immediate =
        ((instruction >> 23) & 0x1F) == 0x6 && ((instruction >> 20) & 0x3) == 0x2 &&
        ((((instruction >> 22) & 1) != 0) || ((instruction >> 16) & 0xF) != 0);
    if (is_msr_register || is_msr_immediate) {
        const bool destination_spsr = ((instruction >> 22) & 1) != 0;
        const bool immediate_operand = is_msr_immediate;
        const u32 field_mask = (instruction >> 16) & 0xF;
        const u32 rm = instruction & 0xF;
        const u32 rotate = ((instruction >> 8) & 0xF) * 2;
        const u32 immediate = RotateRight(instruction & 0xFF, rotate);

        block.ops.push_back({
            .opcode = Opcode::ArmMoveRegisterToStatus,
            .arg0 = condition | (static_cast<u32>(destination_spsr) << 8) |
                    (static_cast<u32>(immediate_operand) << 9),
            .arg1 = field_mask,
            .arg2 = immediate_operand ? immediate : rm,
        });
        return true;
    }

    const u32 swap_opcode = (instruction >> 20) & 0xFF;
    const bool is_swap = (swap_opcode == 0x10 || swap_opcode == 0x14) &&
                         ((instruction >> 4) & 0xF) == 0x9;
    if (is_swap) {
        const bool byte = swap_opcode == 0x14;
        const u32 rn = (instruction >> 16) & 0xF;
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 rm = instruction & 0xF;
        block.ops.push_back({
            .opcode = Opcode::ArmSwap,
            .arg0 = condition | (static_cast<u32>(byte) << 8),
            .arg1 = rd | (rn << 8) | (rm << 16),
        });
        return true;
    }

    const u32 exclusive_opcode = (instruction >> 20) & 0xFF;
    const bool is_exclusive = exclusive_opcode >= 0x18 && exclusive_opcode <= 0x1F &&
                              ((instruction >> 4) & 0xF) == 0x9;
    if (is_exclusive) {
        const bool load = (exclusive_opcode & 1) != 0;
        const u32 size = (exclusive_opcode - 0x18) >> 1; // 0=word, 1=double, 2=byte, 3=half
        const u32 rn = (instruction >> 16) & 0xF;
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 rm = instruction & 0xF;
        const bool doubleword = size == 1;
        const bool valid_doubleword_registers =
            !doubleword || (load ? rd < 15 : rm < 15);
        if (valid_doubleword_registers) {
            block.ops.push_back({
                .opcode = load ? Opcode::ArmExclusiveLoad : Opcode::ArmExclusiveStore,
                .arg0 = condition | (size << 8),
                .arg1 = rd | (rn << 8) | (rm << 16),
            });
            return true;
        }
        return false;
    }

    const bool is_multiply = (instruction & 0x0FE000F0) == 0x00000090;
    const bool is_multiply_accumulate = (instruction & 0x0FE000F0) == 0x00200090;
    if (is_multiply || is_multiply_accumulate) {
        const bool set_flags = ((instruction >> 20) & 1) != 0;
        const u32 rd = (instruction >> 16) & 0xF;
        const u32 rn = (instruction >> 12) & 0xF;
        const u32 rs = (instruction >> 8) & 0xF;
        const u32 rm = instruction & 0xF;
        block.ops.push_back({
            .opcode =
                condition == ConditionCode::AL ? Opcode::ArmMultiplyAlways : Opcode::ArmMultiply,
            .arg0 = condition | (static_cast<u32>(is_multiply_accumulate) << 8) |
                    (static_cast<u32>(set_flags) << 9),
            .arg1 = rd | (rn << 8) | (rs << 16) | (rm << 24),
        });
        return true;
    }

    const bool is_unsigned_multiply_accumulate_accumulate_long =
        (instruction & 0x0FF000F0) == 0x00400090;
    if (is_unsigned_multiply_accumulate_accumulate_long) {
        const u32 rd_hi = (instruction >> 16) & 0xF;
        const u32 rd_lo = (instruction >> 12) & 0xF;
        const u32 rs = (instruction >> 8) & 0xF;
        const u32 rm = instruction & 0xF;
        block.ops.push_back({
            .opcode = condition == ConditionCode::AL
                          ? Opcode::ArmUnsignedMultiplyAccumulateAccumulateLongAlways
                          : Opcode::ArmUnsignedMultiplyAccumulateAccumulateLong,
            .arg0 = condition,
            .arg1 = rd_lo | (rd_hi << 8) | (rs << 16) | (rm << 24),
        });
        return true;
    }

    const u32 long_multiply_opcode = (instruction >> 21) & 0x7F;
    const bool is_long_multiply = long_multiply_opcode >= 4 && long_multiply_opcode <= 7 &&
                                  ((instruction >> 4) & 0xF) == 0x9;
    if (is_long_multiply) {
        const bool set_flags = ((instruction >> 20) & 1) != 0;
        const bool accumulate = (long_multiply_opcode & 1) != 0;
        const bool signed_multiply = (long_multiply_opcode & 2) != 0;
        const u32 rd_hi = (instruction >> 16) & 0xF;
        const u32 rd_lo = (instruction >> 12) & 0xF;
        const u32 rs = (instruction >> 8) & 0xF;
        const u32 rm = instruction & 0xF;
        block.ops.push_back({
            .opcode = condition == ConditionCode::AL ? Opcode::ArmMultiplyLongAlways
                                                     : Opcode::ArmMultiplyLong,
            .arg0 = condition | (static_cast<u32>(signed_multiply) << 8) |
                    (static_cast<u32>(accumulate) << 9) |
                    (static_cast<u32>(set_flags) << 10),
            .arg1 = rd_lo | (rd_hi << 8) | (rs << 16) | (rm << 24),
        });
        return true;
    }

    const bool is_clz = (instruction & 0x0FF000F0) == 0x01600010;
    if (is_clz) {
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 rm = instruction & 0xF;
        block.ops.push_back({
            .opcode = Opcode::ArmCountLeadingZeros,
            .arg0 = condition,
            .arg1 = rd | (rm << 8),
        });
        return true;
    }

    const u32 extend_opcode = instruction & 0x0FFF00F0;
    if (extend_opcode == 0x06AF0070 || extend_opcode == 0x06BF0070 ||
        extend_opcode == 0x06EF0070 || extend_opcode == 0x06FF0070) {
        const bool signed_extend = (extend_opcode == 0x06AF0070 || extend_opcode == 0x06BF0070);
        const bool halfword = (extend_opcode == 0x06BF0070 || extend_opcode == 0x06FF0070);
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 rm = instruction & 0xF;
        const u32 rotate = (instruction >> 10) & 0x3;
        block.ops.push_back({
            .opcode = Opcode::ArmExtend,
            .arg0 = condition | (static_cast<u32>(signed_extend) << 8) |
                    (static_cast<u32>(halfword) << 9) | (rotate << 10),
            .arg1 = rd | (rm << 8),
        });
        return true;
    }

    const u32 extend_add_opcode = (instruction >> 20) & 0xFF;
    const bool extend_add_low_nibble = ((instruction >> 4) & 0xF) == 0x7;
    const bool is_sxtab = extend_add_opcode == 0x6A && extend_add_low_nibble;
    const bool is_sxtah = extend_add_opcode == 0x6B && extend_add_low_nibble;
    const bool is_uxtab = extend_add_opcode == 0x6E && ((instruction >> 4) & 0x3F) == 0x7;
    const bool is_uxtah = extend_add_opcode == 0x6F && extend_add_low_nibble;
    const bool is_sxtab16 = extend_add_opcode == 0x68 && extend_add_low_nibble;
    const bool is_uxtab16 = extend_add_opcode == 0x6C && extend_add_low_nibble;
    if (is_sxtab || is_sxtah || is_uxtab || is_uxtah || is_sxtab16 || is_uxtab16) {
        const bool dual_lane = is_sxtab16 || is_uxtab16;
        const bool signed_extend = is_sxtab || is_sxtah || is_sxtab16;
        const bool halfword = is_sxtah || is_uxtah;
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 rn = (instruction >> 16) & 0xF;
        const u32 rm = instruction & 0xF;
        const u32 rotate = (instruction >> 10) & 0x3;
        block.ops.push_back({
            .opcode = Opcode::ArmExtendAdd,
            .arg0 = condition | (static_cast<u32>(signed_extend) << 8) |
                    (static_cast<u32>(halfword) << 9) |
                    (static_cast<u32>(dual_lane) << 10) | (rotate << 11),
            .arg1 = rd | (rn << 8) | (rm << 16),
        });
        return true;
    }

    const u32 saturate_opcode = (instruction >> 21) & 0x7F;
    const bool is_ssat = saturate_opcode == 0x35 && ((instruction >> 4) & 0x3) == 0x1;
    const bool is_usat = saturate_opcode == 0x37 && ((instruction >> 4) & 0x3) == 0x1;
    const bool is_ssat16 = extend_add_opcode == 0x6A && ((instruction >> 4) & 0xF) == 0x3;
    const bool is_usat16 = extend_add_opcode == 0x6E && ((instruction >> 4) & 0xF) == 0x3;
    if (is_ssat || is_usat || is_ssat16 || is_usat16) {
        const bool signed_saturate = is_ssat || is_ssat16;
        const bool dual_lane = is_ssat16 || is_usat16;
        const u32 rn = instruction & 0xF;
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 sat_imm = dual_lane ? ((instruction >> 16) & 0xF)
                                      : ((instruction >> 16) & 0x1F);
        const u32 imm5 = dual_lane ? 0 : ((instruction >> 7) & 0x1F);
        const u32 shift_type = dual_lane ? 0 : ((instruction >> 6) & 1);
        block.ops.push_back({
            .opcode = Opcode::ArmSaturate,
            .arg0 = condition | (static_cast<u32>(signed_saturate) << 8) |
                    (static_cast<u32>(dual_lane) << 9) | (shift_type << 10),
            .arg1 = rd | (rn << 8),
            .arg2 = sat_imm | (imm5 << 8),
        });
        return true;
    }

    const u32 media_opcode = (instruction >> 20) & 0xFF;
    const u32 media_low_nibble = (instruction >> 4) & 0xF;
    const bool is_reverse = media_opcode == 0x6B && media_low_nibble == 0x3;
    const bool is_reverse16 = (instruction & 0x0FFF0FF0) == 0x06BF0FB0;
    const bool is_reverse_signed_halfword =
        media_opcode == 0x6F && media_low_nibble == 0xB;
    if (is_reverse || is_reverse16 || is_reverse_signed_halfword) {
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 rm = instruction & 0xF;
        u32 reverse_type = 0; // REV
        if (is_reverse16) {
            reverse_type = 1; // REV16
        } else if (is_reverse_signed_halfword) {
            reverse_type = 2; // REVSH
        }
        block.ops.push_back({
            .opcode = Opcode::ArmReverse,
            .arg0 = condition | (reverse_type << 8),
            .arg1 = rd | (rm << 8),
        });
        return true;
    }

    const u32 pack_halfword_opcode = instruction & 0x0FF00070;
    if (pack_halfword_opcode == 0x06800010 || pack_halfword_opcode == 0x06800050) {
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 rn = (instruction >> 16) & 0xF;
        const u32 rm = instruction & 0xF;
        const bool top = pack_halfword_opcode == 0x06800050;
        block.ops.push_back({
            .opcode = Opcode::ArmPackHalfword,
            .arg0 = condition | (static_cast<u32>(top) << 8),
            .arg1 = rd | (rn << 8) | (rm << 16),
            .arg2 = (instruction >> 7) & 0x1F,
        });
        return true;
    }

    const bool is_unsigned_sum_absolute_difference =
        (instruction & 0x0FF000F0) == 0x07800010;
    if (is_unsigned_sum_absolute_difference) {
        const u32 rd = (instruction >> 16) & 0xF;
        const u32 ra = (instruction >> 12) & 0xF;
        const u32 rm = (instruction >> 8) & 0xF;
        const u32 rn = instruction & 0xF;
        block.ops.push_back({
            .opcode = Opcode::ArmUnsignedSumAbsoluteDifference,
            .arg0 = condition,
            .arg1 = rd | (rn << 8) | (rm << 16) | (ra << 24),
        });
        return true;
    }

    const u32 saturating_arithmetic_opcode = (instruction >> 20) & 0xFF;
    const bool is_saturating_arithmetic =
        (saturating_arithmetic_opcode == 0x10 || saturating_arithmetic_opcode == 0x12 ||
         saturating_arithmetic_opcode == 0x14 || saturating_arithmetic_opcode == 0x16) &&
        ((instruction >> 4) & 0xF) == 0x5;
    if (is_saturating_arithmetic) {
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 rn = (instruction >> 16) & 0xF;
        const u32 rm = instruction & 0xF;
        block.ops.push_back({
            .opcode = Opcode::ArmSaturatingArithmetic,
            .arg0 = condition | (((instruction >> 21) & 0x3) << 8),
            .arg1 = rd | (rn << 8) | (rm << 16),
        });
        return true;
    }

    const u32 parallel_add_sub_opcode = (instruction >> 20) & 0xFF;
    const u32 parallel_add_sub_nibble = (instruction >> 4) & 0xF;
    const bool is_parallel_add_sub_form =
        parallel_add_sub_nibble == 0x1 || parallel_add_sub_nibble == 0x3 ||
        parallel_add_sub_nibble == 0x5 || parallel_add_sub_nibble == 0x7 ||
        parallel_add_sub_nibble == 0x9 || parallel_add_sub_nibble == 0xF;
    const bool is_signed_parallel_add_sub =
        parallel_add_sub_opcode == 0x61 && is_parallel_add_sub_form;
    const bool is_unsigned_parallel_add_sub =
        parallel_add_sub_opcode == 0x65 && is_parallel_add_sub_form;
    if (is_signed_parallel_add_sub || is_unsigned_parallel_add_sub) {
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 rn = (instruction >> 16) & 0xF;
        const u32 rm = instruction & 0xF;
        block.ops.push_back({
            .opcode = Opcode::ArmParallelAddSub,
            .arg0 = condition | (static_cast<u32>(is_unsigned_parallel_add_sub) << 8) |
                    (((instruction >> 5) & 0x7) << 9),
            .arg1 = rd | (rn << 8) | (rm << 16),
        });
        return true;
    }

    const bool is_signed_halving_parallel_add_sub =
        parallel_add_sub_opcode == 0x63 && is_parallel_add_sub_form;
    const bool is_unsigned_halving_parallel_add_sub =
        parallel_add_sub_opcode == 0x67 && is_parallel_add_sub_form;
    if (is_signed_halving_parallel_add_sub || is_unsigned_halving_parallel_add_sub) {
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 rn = (instruction >> 16) & 0xF;
        const u32 rm = instruction & 0xF;
        block.ops.push_back({
            .opcode = is_signed_halving_parallel_add_sub
                          ? Opcode::ArmSignedHalvingParallelAddSub
                          : Opcode::ArmUnsignedHalvingParallelAddSub,
            .arg0 = condition | (((instruction >> 5) & 0x7) << 8),
            .arg1 = rd | (rn << 8) | (rm << 16),
        });
        return true;
    }

    const bool is_signed_saturating_parallel_add_sub =
        parallel_add_sub_opcode == 0x62 && is_parallel_add_sub_form;
    const bool is_unsigned_saturating_parallel_add_sub =
        parallel_add_sub_opcode == 0x66 && is_parallel_add_sub_form;
    if (is_signed_saturating_parallel_add_sub || is_unsigned_saturating_parallel_add_sub) {
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 rn = (instruction >> 16) & 0xF;
        const u32 rm = instruction & 0xF;
        block.ops.push_back({
            .opcode = is_signed_saturating_parallel_add_sub
                          ? Opcode::ArmSignedSaturatingParallelAddSub
                          : Opcode::ArmUnsignedSaturatingParallelAddSub,
            .arg0 = condition | (((instruction >> 5) & 0x7) << 8),
            .arg1 = rd | (rn << 8) | (rm << 16),
        });
        return true;
    }

    const bool is_select_bytes = parallel_add_sub_opcode == 0x68 &&
                                 ((instruction >> 4) & 0xF) == 0xB;
    if (is_select_bytes) {
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 rn = (instruction >> 16) & 0xF;
        const u32 rm = instruction & 0xF;
        block.ops.push_back({
            .opcode = Opcode::ArmSelectBytes,
            .arg0 = condition,
            .arg1 = rd | (rn << 8) | (rm << 16),
        });
        return true;
    }

    const u32 signed_media_opcode = (instruction >> 20) & 0xFF;
    const bool signed_media_bit4 = ((instruction >> 4) & 1) != 0;
    const bool signed_media_bit7 = ((instruction >> 7) & 1) != 0;
    const u32 signed_media_bits4_5 = (instruction >> 4) & 0x3;
    const u32 signed_media_bits6_7 = (instruction >> 6) & 0x3;

    const bool is_smla_xy = signed_media_opcode == 0x10 && signed_media_bit7 &&
                            !signed_media_bit4;
    const bool is_smlal_xy = signed_media_opcode == 0x14 && signed_media_bit7 &&
                             !signed_media_bit4;
    const bool is_smul_xy = signed_media_opcode == 0x16 && signed_media_bit7 &&
                            !signed_media_bit4;
    if (is_smla_xy || is_smlal_xy || is_smul_xy) {
        const bool accumulate = is_smla_xy;
        const bool long_result = is_smlal_xy;
        const bool x_high = ((instruction >> 5) & 1) != 0;
        const bool y_high = ((instruction >> 6) & 1) != 0;
        if (long_result) {
            const u32 rd_lo = (instruction >> 12) & 0xF;
            const u32 rd_hi = (instruction >> 16) & 0xF;
            const u32 rn = instruction & 0xF;
            const u32 rm = (instruction >> 8) & 0xF;
            block.ops.push_back({
                .opcode = Opcode::ArmSignedHalfwordMultiply,
                .arg0 = condition | (static_cast<u32>(long_result) << 9) |
                        (static_cast<u32>(x_high) << 10) |
                        (static_cast<u32>(y_high) << 11),
                .arg1 = rd_lo | (rd_hi << 8) | (rn << 16) | (rm << 24),
            });
            return true;
        } else {
            const u32 rd = (instruction >> 16) & 0xF;
            const u32 rn = (instruction >> 12) & 0xF;
            const u32 rs = (instruction >> 8) & 0xF;
            const u32 rm = instruction & 0xF;
            block.ops.push_back({
                .opcode = Opcode::ArmSignedHalfwordMultiply,
                .arg0 = condition | (static_cast<u32>(accumulate) << 8) |
                        (static_cast<u32>(x_high) << 10) |
                        (static_cast<u32>(y_high) << 11),
                .arg1 = rd | (rm << 8) | (rs << 16) | (rn << 24),
            });
            return true;
        }
    }

    const bool is_smlaw = signed_media_opcode == 0x12 && signed_media_bit7 &&
                          signed_media_bits4_5 == 0x0;
    const bool is_smulw = signed_media_opcode == 0x12 && signed_media_bit7 &&
                          signed_media_bits4_5 == 0x2;
    if (is_smlaw || is_smulw) {
        const bool accumulate = is_smlaw;
        const bool high = ((instruction >> 6) & 1) != 0;
        const u32 rd = (instruction >> 16) & 0xF;
        const u32 ra = (instruction >> 12) & 0xF;
        const u32 rm = (instruction >> 8) & 0xF;
        const u32 rn = instruction & 0xF;
        block.ops.push_back({
            .opcode = Opcode::ArmSignedWordHalfwordMultiply,
            .arg0 = condition | (static_cast<u32>(accumulate) << 8) |
                    (static_cast<u32>(high) << 9),
            .arg1 = rd | (rn << 8) | (rm << 16) | (ra << 24),
        });
        return true;
    }

    const bool is_signed_dual_multiply = signed_media_opcode == 0x70 && signed_media_bit4 &&
                                         signed_media_bits6_7 <= 1;
    if (is_signed_dual_multiply) {
        const bool subtract = signed_media_bits6_7 == 1;
        const bool swap = ((instruction >> 5) & 1) != 0;
        const u32 rd = (instruction >> 16) & 0xF;
        const u32 ra = (instruction >> 12) & 0xF;
        const u32 rm = (instruction >> 8) & 0xF;
        const u32 rn = instruction & 0xF;
        const bool accumulate = ra != 15;
        block.ops.push_back({
            .opcode = Opcode::ArmSignedDualMultiply,
            .arg0 = condition | (static_cast<u32>(subtract) << 8) |
                    (static_cast<u32>(swap) << 9) |
                    (static_cast<u32>(accumulate) << 10),
            .arg1 = rd | (rn << 8) | (rm << 16) | (ra << 24),
        });
        return true;
    }

    const bool is_signed_dual_multiply_long = signed_media_opcode == 0x74 && signed_media_bit4 &&
                                              signed_media_bits6_7 <= 1;
    if (is_signed_dual_multiply_long) {
        const bool subtract = signed_media_bits6_7 == 1;
        const bool swap = ((instruction >> 5) & 1) != 0;
        const u32 rd_hi = (instruction >> 16) & 0xF;
        const u32 rd_lo = (instruction >> 12) & 0xF;
        const u32 rm = (instruction >> 8) & 0xF;
        const u32 rn = instruction & 0xF;
        block.ops.push_back({
            .opcode = Opcode::ArmSignedDualMultiplyLong,
            .arg0 = condition | (static_cast<u32>(subtract) << 8) |
                    (static_cast<u32>(swap) << 9),
            .arg1 = rd_lo | (rd_hi << 8) | (rn << 16) | (rm << 24),
        });
        return true;
    }

    const bool is_signed_most_significant_multiply =
        signed_media_opcode == 0x75 && signed_media_bit4 &&
        (signed_media_bits6_7 == 0 || signed_media_bits6_7 == 3);
    if (is_signed_most_significant_multiply) {
        const bool subtract = signed_media_bits6_7 == 3;
        const bool round = ((instruction >> 5) & 1) != 0;
        const u32 rd = (instruction >> 16) & 0xF;
        const u32 ra = (instruction >> 12) & 0xF;
        const u32 rm = (instruction >> 8) & 0xF;
        const u32 rn = instruction & 0xF;
        const bool accumulate = ra != 15;
        block.ops.push_back({
            .opcode = Opcode::ArmSignedMostSignificantMultiply,
            .arg0 = condition | (static_cast<u32>(subtract) << 8) |
                    (static_cast<u32>(round) << 9) |
                    (static_cast<u32>(accumulate) << 10),
            .arg1 = rd | (rn << 8) | (rm << 16) | (ra << 24),
        });
        return true;
    }

    const bool is_blx_register = ((instruction >> 20) & 0xFF) == 0x12 &&
                                 ((instruction >> 4) & 0xF) == 0x3;
    if (is_blx_register) {
        const u32 rm = instruction & 0xF;
        block.terminal = Terminal::IndirectBranch;
        block.ops.push_back({
            .opcode = condition == ConditionCode::AL
                          ? Opcode::ArmBranchLinkExchangeRegisterAlways
                          : Opcode::ArmBranchLinkExchange,
            .arg0 = condition,
            .arg1 = rm,
        });
        return true;
    }

    const bool is_bx = ((instruction >> 20) & 0xFF) == 0x12 &&
                       ((instruction >> 4) & 0xF) == 0x1;
    if (is_bx) {
        const u32 rm = instruction & 0xF;
        block.terminal = Terminal::IndirectBranch;
        block.ops.push_back({
            .opcode = condition == ConditionCode::AL ? Opcode::ArmBranchExchangeAlways
                                                     : Opcode::ArmBranchExchange,
            .arg0 = condition,
            .arg1 = rm,
        });
        return true;
    }

    const bool is_bxj = ((instruction >> 20) & 0xFF) == 0x12 &&
                        ((instruction >> 4) & 0xF) == 0x2;
    if (is_bxj) {
        const u32 rm = instruction & 0xF;
        block.terminal = Terminal::IndirectBranch;
        block.ops.push_back({
            .opcode = condition == ConditionCode::AL ? Opcode::ArmBranchExchangeAlways
                                                     : Opcode::ArmBranchExchange,
            .arg0 = condition,
            .arg1 = rm,
        });
        return true;
    }

    const bool is_branch = ((instruction >> 25) & 0x7) == 0x5;
    const bool link = ((instruction >> 24) & 1) != 0;
    if (is_branch) {
        const s32 offset = static_cast<s32>(instruction << 8) >> 6;
        const u32 target = pc + 8 + static_cast<u32>(offset);
        block.terminal = Terminal::DirectBranch;
        if (condition == ConditionCode::AL && !link) {
            block.ops.push_back({
                .opcode = Opcode::ArmBranchAlways,
                .arg0 = target,
            });
            return true;
        }
        block.ops.push_back({
            .opcode = Opcode::ArmBranch,
            .arg0 = target,
            .arg1 = condition,
            .arg2 = link ? ((pc + 4) | 1) : 0,
        });
        return true;
    }

    const bool is_data_processing = ((instruction >> 26) & 0x3) == 0;
    const bool immediate_operand = ((instruction >> 25) & 0x1) != 0;
    if (is_data_processing && immediate_operand) {
        const u32 data_opcode = (instruction >> 21) & 0xF;
        const bool set_flags = ((instruction >> 20) & 1) != 0;
        const u32 rn = (instruction >> 16) & 0xF;
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 rotate = ((instruction >> 8) & 0xF) * 2;
        const u32 immediate = RotateRight(instruction & 0xFF, rotate);
        const bool shifter_carry_from_c_flag = rotate == 0;
        const bool shifter_carry = !shifter_carry_from_c_flag && ((immediate >> 31) != 0);

        if (IsSupportedDataProcessing(data_opcode, set_flags, rn, rd)) {
            const bool writes_pc = DataProcessingWritesPc(data_opcode, set_flags, rd);
            if (condition == ConditionCode::AL) {
                if (data_opcode == 13 && !set_flags && rd != 15) {
                    block.ops.push_back(MakeMoveImmediate(rd, immediate));
                    return true;
                }
                if (data_opcode == 4 && !set_flags && rd != 15) {
                    if (rn != 15 && immediate == 0) {
                        block.ops.push_back(MakeMoveRegisterOrHint(rd, rn));
                        return true;
                    }
                    block.ops.push_back({
                        .opcode = SelectNoPcDataOpcode(Opcode::ArmAddImmediateAlways, rn),
                        .arg1 = rd | (rn << 8),
                        .arg2 = immediate,
                    });
                    return true;
                }
                if (data_opcode == 2 && !set_flags && rd != 15) {
                    if (rn != 15 && immediate == 0) {
                        block.ops.push_back(MakeMoveRegisterOrHint(rd, rn));
                        return true;
                    }
                    block.ops.push_back({
                        .opcode = SelectNoPcDataOpcode(Opcode::ArmSubImmediateAlways, rn),
                        .arg1 = rd | (rn << 8),
                        .arg2 = immediate,
                    });
                    return true;
                }
                if (!set_flags) {
                    Op simplified;
                    if (TryBuildLogicalImmediateNoFlagsSimplification(simplified, data_opcode, rd,
                                                                      rn, immediate)) {
                        block.ops.push_back(simplified);
                        return true;
                    }
                }
                if (set_flags && rd != 15 && (data_opcode == 13 || data_opcode == 15)) {
                    const u32 value = data_opcode == 15 ? ~immediate : immediate;
                    block.ops.push_back(MakeMoveImmediateSetFlags(rd, value, shifter_carry,
                                                                  shifter_carry_from_c_flag));
                    return true;
                }
                if (!set_flags && IsFastCarryArithmeticWriteOpcode(data_opcode) && rd != 15) {
                    block.ops.push_back({
                        .opcode = SelectNoPcDataOpcode(Opcode::ArmArithmeticImmediateAlways, rn),
                        .arg0 = data_opcode,
                        .arg1 = rd | (rn << 8),
                        .arg2 = immediate,
                    });
                    return true;
                }
                if (!set_flags && IsFastLogicalWriteOpcode(data_opcode) && rd != 15) {
                    block.ops.push_back({
                        .opcode = SelectNoPcDataOpcode(Opcode::ArmLogicalImmediateAlways, rn),
                        .arg0 = data_opcode,
                        .arg1 = rd | (rn << 8),
                        .arg2 = immediate,
                    });
                    return true;
                }
                if (data_opcode == 4 && set_flags && rd != 15) {
                    block.ops.push_back({
                        .opcode =
                            SelectNoPcDataOpcode(Opcode::ArmAddImmediateSetFlagsAlways, rn),
                        .arg1 = rd | (rn << 8),
                        .arg2 = immediate,
                    });
                    return true;
                }
                if (data_opcode == 2 && set_flags && rd != 15) {
                    block.ops.push_back({
                        .opcode =
                            SelectNoPcDataOpcode(Opcode::ArmSubImmediateSetFlagsAlways, rn),
                        .arg1 = rd | (rn << 8),
                        .arg2 = immediate,
                    });
                    return true;
                }
                if (set_flags && IsFastCarryArithmeticWriteOpcode(data_opcode) && rd != 15) {
                    block.ops.push_back({
                        .opcode = SelectNoPcDataOpcode(
                            Opcode::ArmArithmeticImmediateSetFlagsAlways, rn),
                        .arg0 = data_opcode,
                        .arg1 = rd | (rn << 8),
                        .arg2 = immediate,
                    });
                    return true;
                }
                if (rn != 15 && data_opcode == 10 && set_flags && immediate == 0) {
                    block.ops.push_back(MakeCompareZeroImmediate(rn));
                    return true;
                }
                if (data_opcode == 10 && set_flags) {
                    block.ops.push_back({
                        .opcode = SelectNoPcDataOpcode(Opcode::ArmCompareImmediateAlways, rn),
                        .arg1 = rn,
                        .arg2 = immediate,
                    });
                    return true;
                }
                if (data_opcode == 11 && set_flags) {
                    block.ops.push_back({
                        .opcode =
                            SelectNoPcDataOpcode(Opcode::ArmCompareNegativeImmediateAlways, rn),
                        .arg1 = rn,
                        .arg2 = immediate,
                    });
                    return true;
                }
                if (rn != 15 && data_opcode == 8 && set_flags) {
                    block.ops.push_back(MakeTestImmediate(rn, immediate, shifter_carry,
                                                          shifter_carry_from_c_flag));
                    return true;
                }
                if (rn != 15 && data_opcode == 9 && set_flags) {
                    block.ops.push_back(MakeTestEqualImmediate(rn, immediate, shifter_carry,
                                                               shifter_carry_from_c_flag));
                    return true;
                }
                if (set_flags && IsFastLogicalSetFlagsOpcode(data_opcode) &&
                    (!FastLogicalSetFlagsWritesRd(data_opcode) || rd != 15)) {
                    block.ops.push_back({
                        .opcode =
                            SelectNoPcDataOpcode(Opcode::ArmLogicalImmediateSetFlagsAlways, rn),
                        .arg0 = data_opcode | (static_cast<u32>(shifter_carry) << 8) |
                                (static_cast<u32>(shifter_carry_from_c_flag) << 9),
                        .arg1 = rd | (rn << 8),
                        .arg2 = immediate,
                    });
                    return true;
                }
            }
            if (writes_pc) {
                block.terminal = Terminal::IndirectBranch;
            }
            block.ops.push_back({
                .opcode = condition == ConditionCode::AL ? Opcode::ArmDataProcessingImmediateAlways
                                                         : Opcode::ArmDataProcessingImmediate,
                .arg0 = data_opcode | (condition << 8),
                .arg1 = rd | (rn << 8) | (static_cast<u32>(set_flags) << 16) |
                        (static_cast<u32>(shifter_carry) << 17) |
                        (static_cast<u32>(shifter_carry_from_c_flag) << 18),
                .arg2 = immediate,
            });
            return true;
        }
    }

    if (is_data_processing && !immediate_operand) {
        const bool register_shift_amount = ((instruction >> 4) & 0x1) != 0;
        if (!register_shift_amount) {
            const u32 data_opcode = (instruction >> 21) & 0xF;
            const bool set_flags = ((instruction >> 20) & 1) != 0;
            const u32 rn = (instruction >> 16) & 0xF;
            const u32 rd = (instruction >> 12) & 0xF;
            const u32 shift_imm = (instruction >> 7) & 0x1F;
            const u32 shift_type = (instruction >> 5) & 0x3;
            const u32 rm = instruction & 0xF;

            if (IsSupportedDataProcessing(data_opcode, set_flags, rn, rd)) {
                const bool writes_pc = DataProcessingWritesPc(data_opcode, set_flags, rd);
                if (rm != 15 && condition == ConditionCode::AL && shift_type == 0 &&
                    shift_imm == 0) {
                    if (data_opcode == 13 && !set_flags && rd != 15) {
                        block.ops.push_back(MakeMoveRegisterOrHint(rd, rm));
                        return true;
                    }
                    if (data_opcode == 15 && !set_flags && rd != 15) {
                        block.ops.push_back(MakeMoveNotRegister(rd, rm));
                        return true;
                    }
                    if (data_opcode == 13 && set_flags && rd != 15) {
                        block.ops.push_back(MakeMoveRegisterSetFlags(rd, rm));
                        return true;
                    }
                    if (data_opcode == 15 && set_flags && rd != 15) {
                        block.ops.push_back(MakeMoveNotRegisterSetFlags(rd, rm));
                        return true;
                    }
                    if (!set_flags) {
                        Op simplified;
                        if (TryBuildLogicalRegisterNoFlagsSimplification(simplified, data_opcode,
                                                                         rd, rn, rm)) {
                            block.ops.push_back(simplified);
                            return true;
                        }
                    }
                    if (data_opcode == 4 && !set_flags && rd != 15) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(Opcode::ArmAddRegisterAlways, rn),
                            .arg1 = rd | (rn << 8) | (rm << 16),
                        });
                        return true;
                    }
                    if (data_opcode == 2 && !set_flags && rd != 15) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(Opcode::ArmSubRegisterAlways, rn),
                            .arg1 = rd | (rn << 8) | (rm << 16),
                        });
                        return true;
                    }
                    if (!set_flags && IsFastCarryArithmeticWriteOpcode(data_opcode) && rd != 15) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(Opcode::ArmArithmeticRegisterAlways, rn),
                            .arg0 = data_opcode,
                            .arg1 = rd | (rn << 8) | (rm << 16),
                        });
                        return true;
                    }
                    if (!set_flags && IsFastLogicalWriteOpcode(data_opcode) && rd != 15) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(Opcode::ArmLogicalRegisterAlways, rn),
                            .arg0 = data_opcode,
                            .arg1 = rd | (rn << 8) | (rm << 16),
                        });
                        return true;
                    }
                    if (data_opcode == 4 && set_flags && rd != 15) {
                        block.ops.push_back({
                            .opcode =
                                SelectNoPcDataOpcode(Opcode::ArmAddRegisterSetFlagsAlways, rn),
                            .arg1 = rd | (rn << 8) | (rm << 16),
                        });
                        return true;
                    }
                    if (data_opcode == 2 && set_flags && rd != 15) {
                        block.ops.push_back({
                            .opcode =
                                SelectNoPcDataOpcode(Opcode::ArmSubRegisterSetFlagsAlways, rn),
                            .arg1 = rd | (rn << 8) | (rm << 16),
                        });
                        return true;
                    }
                    if (set_flags && IsFastCarryArithmeticWriteOpcode(data_opcode) && rd != 15) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(
                                Opcode::ArmArithmeticRegisterSetFlagsAlways, rn),
                            .arg0 = data_opcode,
                            .arg1 = rd | (rn << 8) | (rm << 16),
                        });
                        return true;
                    }
                    if (data_opcode == 10 && set_flags) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(Opcode::ArmCompareRegisterAlways, rn),
                            .arg1 = rn | (rm << 8),
                        });
                        return true;
                    }
                    if (data_opcode == 11 && set_flags) {
                        block.ops.push_back({
                            .opcode =
                                SelectNoPcDataOpcode(Opcode::ArmCompareNegativeRegisterAlways, rn),
                            .arg1 = rn | (rm << 8),
                        });
                        return true;
                    }
                    if (rn != 15 && data_opcode == 8 && set_flags) {
                        block.ops.push_back(MakeTestRegisterNoShift(rn, rm));
                        return true;
                    }
                    if (rn != 15 && data_opcode == 9 && set_flags) {
                        block.ops.push_back(MakeTestEqualRegisterNoShift(rn, rm));
                        return true;
                    }
                    if (set_flags && IsFastLogicalSetFlagsOpcode(data_opcode) &&
                        (!FastLogicalSetFlagsWritesRd(data_opcode) || rd != 15)) {
                        block.ops.push_back({
                            .opcode =
                                SelectNoPcDataOpcode(Opcode::ArmLogicalRegisterSetFlagsAlways, rn),
                            .arg0 = data_opcode,
                            .arg1 = rd | (rn << 8) | (rm << 16),
                        });
                        return true;
                    }
                }
                if (rm != 15 && condition == ConditionCode::AL && data_opcode == 13 &&
                    rd != 15) {
                    block.ops.push_back({
                        .opcode = set_flags ? Opcode::ArmMoveShiftedRegisterSetFlagsAlways
                                            : Opcode::ArmMoveShiftedRegisterAlways,
                        .arg1 = rd | (rm << 8),
                        .arg2 = shift_type | (shift_imm << 8),
                    });
                    return true;
                }
                if (rm != 15 && condition == ConditionCode::AL) {
                    if (!set_flags && IsFastLogicalWriteOpcode(data_opcode) && rd != 15) {
                        block.ops.push_back({
                            .opcode =
                                SelectNoPcDataOpcode(Opcode::ArmLogicalShiftedRegisterAlways, rn),
                            .arg0 = data_opcode,
                            .arg1 = rd | (rn << 8) | (rm << 16),
                            .arg2 = shift_type | (shift_imm << 8),
                        });
                        return true;
                    }
                    if (data_opcode == 4 && !set_flags && rd != 15) {
                        block.ops.push_back({
                            .opcode =
                                SelectNoPcDataOpcode(Opcode::ArmAddShiftedRegisterAlways, rn),
                            .arg1 = rd | (rn << 8) | (rm << 16),
                            .arg2 = shift_type | (shift_imm << 8),
                        });
                        return true;
                    }
                    if (data_opcode == 2 && !set_flags && rd != 15) {
                        block.ops.push_back({
                            .opcode =
                                SelectNoPcDataOpcode(Opcode::ArmSubShiftedRegisterAlways, rn),
                            .arg1 = rd | (rn << 8) | (rm << 16),
                            .arg2 = shift_type | (shift_imm << 8),
                        });
                        return true;
                    }
                    if (!set_flags && IsFastCarryArithmeticWriteOpcode(data_opcode) && rd != 15) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(
                                Opcode::ArmArithmeticShiftedRegisterAlways, rn),
                            .arg0 = data_opcode,
                            .arg1 = rd | (rn << 8) | (rm << 16),
                            .arg2 = shift_type | (shift_imm << 8),
                        });
                        return true;
                    }
                    if (data_opcode == 10 && set_flags) {
                        block.ops.push_back({
                            .opcode =
                                SelectNoPcDataOpcode(Opcode::ArmCompareShiftedRegisterAlways, rn),
                            .arg1 = rn | (rm << 8),
                            .arg2 = shift_type | (shift_imm << 8),
                        });
                        return true;
                    }
                    if (data_opcode == 4 && set_flags && rd != 15) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(
                                Opcode::ArmAddShiftedRegisterSetFlagsAlways, rn),
                            .arg1 = rd | (rn << 8) | (rm << 16),
                            .arg2 = shift_type | (shift_imm << 8),
                        });
                        return true;
                    }
                    if (data_opcode == 2 && set_flags && rd != 15) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(
                                Opcode::ArmSubShiftedRegisterSetFlagsAlways, rn),
                            .arg1 = rd | (rn << 8) | (rm << 16),
                            .arg2 = shift_type | (shift_imm << 8),
                        });
                        return true;
                    }
                    if (set_flags && IsFastCarryArithmeticWriteOpcode(data_opcode) && rd != 15) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(
                                Opcode::ArmArithmeticShiftedRegisterSetFlagsAlways, rn),
                            .arg0 = data_opcode,
                            .arg1 = rd | (rn << 8) | (rm << 16),
                            .arg2 = shift_type | (shift_imm << 8),
                        });
                        return true;
                    }
                    if (data_opcode == 11 && set_flags) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(
                                Opcode::ArmCompareNegativeShiftedRegisterAlways, rn),
                            .arg1 = rn | (rm << 8),
                            .arg2 = shift_type | (shift_imm << 8),
                        });
                        return true;
                    }
                    if (set_flags && IsFastLogicalSetFlagsOpcode(data_opcode) &&
                        (!FastLogicalSetFlagsWritesRd(data_opcode) || rd != 15)) {
                        block.ops.push_back({
                            .opcode =
                                SelectLogicalShiftedRegisterSetFlagsNoPcOpcode(data_opcode, rn,
                                                                               shift_type),
                            .arg0 = data_opcode,
                            .arg1 = rd | (rn << 8) | (rm << 16),
                            .arg2 = shift_type | (shift_imm << 8),
                        });
                        return true;
                    }
                }
                if (writes_pc) {
                    block.terminal = Terminal::IndirectBranch;
                }
                block.ops.push_back({
                    .opcode = condition == ConditionCode::AL ? Opcode::ArmDataProcessingRegisterAlways
                                                             : Opcode::ArmDataProcessingRegister,
                    .arg0 = data_opcode | (condition << 8),
                    .arg1 = rd | (rn << 8) | (rm << 16) |
                            (static_cast<u32>(set_flags) << 20),
                    .arg2 = shift_type | (shift_imm << 8),
                });
                return true;
            }
        } else if (((instruction >> 7) & 0x1) == 0) {
            const u32 data_opcode = (instruction >> 21) & 0xF;
            const bool set_flags = ((instruction >> 20) & 1) != 0;
            const u32 rn = (instruction >> 16) & 0xF;
            const u32 rd = (instruction >> 12) & 0xF;
            const u32 rs = (instruction >> 8) & 0xF;
            const u32 shift_type = (instruction >> 5) & 0x3;
            const u32 rm = instruction & 0xF;

            if (IsSupportedDataProcessing(data_opcode, set_flags, rn, rd)) {
                const bool writes_pc = DataProcessingWritesPc(data_opcode, set_flags, rd);
                if (condition == ConditionCode::AL) {
                    if (data_opcode == 13 && rd != 15) {
                        block.ops.push_back({
                            .opcode = set_flags
                                          ? Opcode::ArmMoveRegisterShiftedRegisterSetFlagsAlways
                                          : Opcode::ArmMoveRegisterShiftedRegisterAlways,
                            .arg1 = rd | (rm << 8) | (rs << 16),
                            .arg2 = shift_type,
                        });
                        return true;
                    }
                    if (!set_flags && IsFastLogicalWriteOpcode(data_opcode) && rd != 15) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(
                                Opcode::ArmLogicalRegisterShiftedRegisterAlways, rn),
                            .arg0 = data_opcode,
                            .arg1 = rd | (rn << 8) | (rm << 16) | (rs << 24),
                            .arg2 = shift_type,
                        });
                        return true;
                    }
                    if (!set_flags && IsFastCarryArithmeticWriteOpcode(data_opcode) && rd != 15) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(
                                Opcode::ArmArithmeticRegisterShiftedRegisterAlways, rn),
                            .arg0 = data_opcode,
                            .arg1 = rd | (rn << 8) | (rm << 16) | (rs << 24),
                            .arg2 = shift_type,
                        });
                        return true;
                    }
                    if (data_opcode == 4 && !set_flags && rd != 15) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(
                                Opcode::ArmAddRegisterShiftedRegisterAlways, rn),
                            .arg1 = rd | (rn << 8) | (rm << 16) | (rs << 24),
                            .arg2 = shift_type,
                        });
                        return true;
                    }
                    if (data_opcode == 2 && !set_flags && rd != 15) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(
                                Opcode::ArmSubRegisterShiftedRegisterAlways, rn),
                            .arg1 = rd | (rn << 8) | (rm << 16) | (rs << 24),
                            .arg2 = shift_type,
                        });
                        return true;
                    }
                    if (data_opcode == 10 && set_flags) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(
                                Opcode::ArmCompareRegisterShiftedRegisterAlways, rn),
                            .arg1 = rn | (rm << 8) | (rs << 16),
                            .arg2 = shift_type,
                        });
                        return true;
                    }
                    if (data_opcode == 4 && set_flags && rd != 15) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(
                                Opcode::ArmAddRegisterShiftedRegisterSetFlagsAlways, rn),
                            .arg1 = rd | (rn << 8) | (rm << 16) | (rs << 24),
                            .arg2 = shift_type,
                        });
                        return true;
                    }
                    if (data_opcode == 2 && set_flags && rd != 15) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(
                                Opcode::ArmSubRegisterShiftedRegisterSetFlagsAlways, rn),
                            .arg1 = rd | (rn << 8) | (rm << 16) | (rs << 24),
                            .arg2 = shift_type,
                        });
                        return true;
                    }
                    if (set_flags && IsFastCarryArithmeticWriteOpcode(data_opcode) && rd != 15) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(
                                Opcode::ArmArithmeticRegisterShiftedRegisterSetFlagsAlways, rn),
                            .arg0 = data_opcode,
                            .arg1 = rd | (rn << 8) | (rm << 16) | (rs << 24),
                            .arg2 = shift_type,
                        });
                        return true;
                    }
                    if (data_opcode == 11 && set_flags) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(
                                Opcode::ArmCompareNegativeRegisterShiftedRegisterAlways, rn),
                            .arg1 = rn | (rm << 8) | (rs << 16),
                            .arg2 = shift_type,
                        });
                        return true;
                    }
                    if (set_flags && IsFastLogicalSetFlagsOpcode(data_opcode) &&
                        (!FastLogicalSetFlagsWritesRd(data_opcode) || rd != 15)) {
                        block.ops.push_back({
                            .opcode = SelectNoPcDataOpcode(
                                Opcode::ArmLogicalRegisterShiftedRegisterSetFlagsAlways, rn),
                            .arg0 = data_opcode,
                            .arg1 = rd | (rn << 8) | (rm << 16) | (rs << 24),
                            .arg2 = shift_type,
                        });
                        return true;
                    }
                }
                if (writes_pc) {
                    block.terminal = Terminal::IndirectBranch;
                }
                block.ops.push_back({
                    .opcode = condition == ConditionCode::AL ? Opcode::ArmDataProcessingRegisterAlways
                                                             : Opcode::ArmDataProcessingRegister,
                    .arg0 = data_opcode | (condition << 8),
                    .arg1 = rd | (rn << 8) | (rm << 16) |
                            (static_cast<u32>(set_flags) << 20),
                    .arg2 = shift_type | (rs << 8) | (1U << 16),
                });
                return true;
            }
        }
    }

    const bool is_halfword_transfer = ((instruction >> 25) & 0x7) == 0 &&
                                      ((instruction >> 7) & 1) != 0 &&
                                      ((instruction >> 4) & 1) != 0;
    if (is_halfword_transfer) {
        const bool pre_indexed = ((instruction >> 24) & 1) != 0;
        const bool add_offset = ((instruction >> 23) & 1) != 0;
        const bool immediate_offset = ((instruction >> 22) & 1) != 0;
        const bool writeback = ((instruction >> 21) & 1) != 0;
        const bool load = ((instruction >> 20) & 1) != 0;
        const u32 rn = (instruction >> 16) & 0xF;
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 transfer_type = (instruction >> 5) & 0x3;
        const bool supported_transfer = transfer_type == 1 || (load && transfer_type >= 2);
        const bool double_transfer = !load && transfer_type >= 2;
        const bool transfer_t = !pre_indexed && writeback;
        const bool writes_back = !pre_indexed || writeback;
        // Dyncom accepts PC as the register offset and reads it with normal address semantics.
        const bool valid_offset_register = true;

        if (double_transfer && rd < 15 && valid_offset_register) {
            const u32 offset =
                immediate_offset ? (((instruction >> 8) & 0xF) << 4) | (instruction & 0xF)
                                 : (instruction & 0xF);
            if (condition == ConditionCode::AL &&
                (!writes_back || (rn != rd && rn != rd + 1))) {
                block.ops.push_back({
                    .opcode = transfer_type == 2 ? Opcode::ArmLoadDoubleFast
                                                 : Opcode::ArmStoreDoubleFast,
                    .arg1 = rd | (rn << 8) | (static_cast<u32>(add_offset) << 16) |
                            (static_cast<u32>(immediate_offset) << 17) |
                            (static_cast<u32>(pre_indexed) << 18) |
                            (static_cast<u32>(writes_back) << 19),
                    .arg2 = offset,
                });
                return true;
            }
            block.ops.push_back({
                .opcode = Opcode::ArmLoadStoreDouble,
                .arg0 = condition | (static_cast<u32>(transfer_type == 2) << 8),
                .arg1 = rd | (rn << 8) | (static_cast<u32>(add_offset) << 16) |
                        (static_cast<u32>(immediate_offset) << 17) |
                        (static_cast<u32>(pre_indexed) << 18) |
                        (static_cast<u32>(writes_back) << 19),
                .arg2 = offset,
            });
            return true;
        }

        if (supported_transfer) {
            const u32 offset =
                immediate_offset ? (((instruction >> 8) & 0xF) << 4) | (instruction & 0xF)
                                 : (instruction & 0xF);
            if (valid_offset_register) {
                if (condition == ConditionCode::AL && pre_indexed && !writeback && rd != 15) {
                    Opcode opcode = Opcode::ArmLoadStoreHalfword;
                    if (immediate_offset) {
                        if (transfer_type == 1) {
                            opcode = load ? Opcode::ArmLoadHalfwordImmediate
                                          : Opcode::ArmStoreHalfwordImmediate;
                        } else if (transfer_type == 2) {
                            opcode = Opcode::ArmLoadSignedByteImmediate;
                        } else {
                            opcode = Opcode::ArmLoadSignedHalfwordImmediate;
                        }
                    } else {
                        if (transfer_type == 1) {
                            opcode = load ? Opcode::ArmLoadHalfwordRegister
                                          : Opcode::ArmStoreHalfwordRegister;
                        } else if (transfer_type == 2) {
                            opcode = Opcode::ArmLoadSignedByteRegister;
                        } else {
                            opcode = Opcode::ArmLoadSignedHalfwordRegister;
                        }
                    }
                    if (immediate_offset && rn != 15 && offset == 0) {
                        if (transfer_type == 1) {
                            opcode = load ? Opcode::ArmLoadHalfwordImmediateNoPcOffset0
                                          : Opcode::ArmStoreHalfwordImmediateNoPcOffset0;
                        } else if (transfer_type == 2) {
                            opcode = Opcode::ArmLoadSignedByteImmediateNoPcOffset0;
                        } else {
                            opcode = Opcode::ArmLoadSignedHalfwordImmediateNoPcOffset0;
                        }
                    } else {
                        opcode = SelectNoPcMemoryOpcode(opcode, rn);
                    }
                    block.ops.push_back({
                        .opcode = opcode,
                        .arg0 = condition,
                        .arg1 = rd | (rn << 8) | (static_cast<u32>(add_offset) << 16),
                        .arg2 = offset,
                    });
                    return true;
                }
                if (condition == ConditionCode::AL && writes_back && rd != 15 && rd != rn &&
                    rn != 15) {
                    Opcode opcode = Opcode::ArmLoadStoreHalfword;
                    if (immediate_offset) {
                        if (transfer_type == 1) {
                            opcode = load ? Opcode::ArmLoadHalfwordImmediateWriteback
                                          : Opcode::ArmStoreHalfwordImmediateWriteback;
                        } else if (transfer_type == 2) {
                            opcode = Opcode::ArmLoadSignedByteImmediateWriteback;
                        } else {
                            opcode = Opcode::ArmLoadSignedHalfwordImmediateWriteback;
                        }
                    } else {
                        if (transfer_type == 1) {
                            opcode = load ? Opcode::ArmLoadHalfwordRegisterWriteback
                                          : Opcode::ArmStoreHalfwordRegisterWriteback;
                        } else if (transfer_type == 2) {
                            opcode = Opcode::ArmLoadSignedByteRegisterWriteback;
                        } else {
                            opcode = Opcode::ArmLoadSignedHalfwordRegisterWriteback;
                        }
                    }
                    block.ops.push_back({
                        .opcode = opcode,
                        .arg1 = rd | (rn << 8) | (static_cast<u32>(add_offset) << 16) |
                                (static_cast<u32>(pre_indexed) << 17),
                        .arg2 = offset,
                    });
                    return true;
                }
                block.ops.push_back({
                    .opcode = Opcode::ArmLoadStoreHalfword,
                    .arg0 = condition | (static_cast<u32>(load) << 8) | (transfer_type << 9),
                    .arg1 = rd | (rn << 8) | (static_cast<u32>(add_offset) << 16) |
                            (static_cast<u32>(immediate_offset) << 17) |
                            (static_cast<u32>(pre_indexed) << 18) |
                            (static_cast<u32>(writes_back) << 19),
                    .arg2 = offset,
                });
                return true;
            }
        }
    }

    const bool is_single_data_transfer = ((instruction >> 26) & 0x3) == 1;
    const bool register_offset = ((instruction >> 25) & 1) != 0;
    const bool pre_indexed = ((instruction >> 24) & 1) != 0;
    const bool add_offset = ((instruction >> 23) & 1) != 0;
    const bool byte_transfer = ((instruction >> 22) & 1) != 0;
    const bool writeback = ((instruction >> 21) & 1) != 0;
    const bool load = ((instruction >> 20) & 1) != 0;
    const bool transfer_t = !pre_indexed && writeback;
    const bool writes_back = !pre_indexed || writeback;
    if (is_single_data_transfer && !register_offset) {
        const u32 rn = (instruction >> 16) & 0xF;
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 offset = instruction & 0xFFF;
        const bool loads_pc = load && !byte_transfer && rd == 15;
        {
            if (loads_pc) {
                block.terminal = Terminal::IndirectBranch;
            }
            if (condition == ConditionCode::AL && !byte_transfer && pre_indexed && !writeback &&
                rd != 15) {
                Opcode opcode =
                    load ? Opcode::ArmLoadWordImmediate : Opcode::ArmStoreWordImmediate;
                if (rn != 15 && offset == 0) {
                    opcode = load ? Opcode::ArmLoadWordImmediateNoPcOffset0
                                  : Opcode::ArmStoreWordImmediateNoPcOffset0;
                } else {
                    opcode = SelectNoPcMemoryOpcode(opcode, rn);
                }
                block.ops.push_back({
                    .opcode = opcode,
                    .arg0 = condition,
                    .arg1 = rd | (rn << 8) | (static_cast<u32>(add_offset) << 16),
                    .arg2 = offset,
                });
                return true;
            }
            if (condition == ConditionCode::AL && byte_transfer && pre_indexed && !writeback &&
                rd != 15) {
                Opcode opcode =
                    load ? Opcode::ArmLoadByteImmediate : Opcode::ArmStoreByteImmediate;
                if (rn != 15 && offset == 0) {
                    opcode = load ? Opcode::ArmLoadByteImmediateNoPcOffset0
                                  : Opcode::ArmStoreByteImmediateNoPcOffset0;
                } else {
                    opcode = SelectNoPcMemoryOpcode(opcode, rn);
                }
                block.ops.push_back({
                    .opcode = opcode,
                    .arg0 = condition,
                    .arg1 = rd | (rn << 8) | (static_cast<u32>(add_offset) << 16),
                    .arg2 = offset,
                });
                return true;
            }
            if (condition == ConditionCode::AL && writes_back && !transfer_t && rd != 15 &&
                rd != rn) {
                if (byte_transfer) {
                    block.ops.push_back({
                        .opcode = load ? Opcode::ArmLoadByteImmediateWriteback
                                       : Opcode::ArmStoreByteImmediateWriteback,
                        .arg1 = rd | (rn << 8) | (static_cast<u32>(add_offset) << 16) |
                                (static_cast<u32>(pre_indexed) << 17),
                        .arg2 = offset,
                    });
                    return true;
                }

                block.ops.push_back({
                    .opcode = load ? Opcode::ArmLoadWordImmediateWriteback
                                   : Opcode::ArmStoreWordImmediateWriteback,
                    .arg1 = rd | (rn << 8) | (static_cast<u32>(add_offset) << 16) |
                            (static_cast<u32>(pre_indexed) << 17),
                    .arg2 = offset,
                });
                return true;
            }
            block.ops.push_back({
                .opcode = Opcode::ArmLoadStoreImmediate,
                .arg0 = static_cast<u32>(load) | (static_cast<u32>(byte_transfer) << 1) |
                        (static_cast<u32>(transfer_t) << 2) | (condition << 8),
                .arg1 = rd | (rn << 8) | (static_cast<u32>(add_offset) << 16) |
                        (static_cast<u32>(pre_indexed) << 17) |
                        (static_cast<u32>(writes_back) << 18),
                .arg2 = offset,
            });
            return true;
        }
    }
    if (is_single_data_transfer && register_offset) {
        const u32 rn = (instruction >> 16) & 0xF;
        const u32 rd = (instruction >> 12) & 0xF;
        const u32 rm = instruction & 0xF;
        const u32 shift_type = (instruction >> 5) & 0x3;
        const u32 shift_imm = (instruction >> 7) & 0x1F;
        const bool loads_pc = load && !byte_transfer && rd == 15;
        {
            if (loads_pc) {
                block.terminal = Terminal::IndirectBranch;
            }
            const bool register_offset_uses_c_flag = shift_type == 3 && shift_imm == 0;
            if (condition == ConditionCode::AL && !byte_transfer && pre_indexed && !writeback &&
                rd != 15 && rm != 15 &&
                !register_offset_uses_c_flag) {
                block.ops.push_back({
                    .opcode = SelectNoPcMemoryOpcode(load ? Opcode::ArmLoadWordRegister
                                                          : Opcode::ArmStoreWordRegister,
                                                     rn),
                    .arg0 = condition,
                    .arg1 = rd | (rn << 8) | (rm << 16) |
                            (static_cast<u32>(add_offset) << 20),
                    .arg2 = shift_type | (shift_imm << 8),
                });
                return true;
            }
            if (condition == ConditionCode::AL && byte_transfer && pre_indexed && !writeback &&
                rd != 15 && rm != 15 &&
                !register_offset_uses_c_flag) {
                block.ops.push_back({
                    .opcode = SelectNoPcMemoryOpcode(load ? Opcode::ArmLoadByteRegister
                                                          : Opcode::ArmStoreByteRegister,
                                                     rn),
                    .arg0 = condition,
                    .arg1 = rd | (rn << 8) | (rm << 16) |
                            (static_cast<u32>(add_offset) << 20),
                    .arg2 = shift_type | (shift_imm << 8),
                });
                return true;
            }
            if (condition == ConditionCode::AL && writes_back && !transfer_t && rd != 15 &&
                rd != rn && rm != 15 && !register_offset_uses_c_flag) {
                if (byte_transfer) {
                    block.ops.push_back({
                        .opcode = load ? Opcode::ArmLoadByteRegisterWriteback
                                       : Opcode::ArmStoreByteRegisterWriteback,
                        .arg1 = rd | (rn << 8) | (rm << 16) |
                                (static_cast<u32>(add_offset) << 20) |
                                (static_cast<u32>(pre_indexed) << 21),
                        .arg2 = shift_type | (shift_imm << 8),
                    });
                    return true;
                }

                block.ops.push_back({
                    .opcode = load ? Opcode::ArmLoadWordRegisterWriteback
                                   : Opcode::ArmStoreWordRegisterWriteback,
                    .arg1 = rd | (rn << 8) | (rm << 16) |
                            (static_cast<u32>(add_offset) << 20) |
                            (static_cast<u32>(pre_indexed) << 21),
                    .arg2 = shift_type | (shift_imm << 8),
                });
                return true;
            }
            block.ops.push_back({
                .opcode = Opcode::ArmLoadStoreRegister,
                .arg0 = static_cast<u32>(load) | (static_cast<u32>(byte_transfer) << 1) |
                        (static_cast<u32>(transfer_t) << 2) | (condition << 8),
                .arg1 = rd | (rn << 8) | (rm << 16) | (static_cast<u32>(add_offset) << 20) |
                        (static_cast<u32>(pre_indexed) << 21) |
                        (static_cast<u32>(writes_back) << 22),
                .arg2 = shift_type | (shift_imm << 8),
            });
            return true;
        }
    }

    const bool is_block_transfer = ((instruction >> 25) & 0x7) == 0x4;
    if (is_block_transfer) {
        const bool pre_indexed = ((instruction >> 24) & 1) != 0;
        const bool add_offset = ((instruction >> 23) & 1) != 0;
        const bool user_mode_or_psr = ((instruction >> 22) & 1) != 0;
        const bool writeback = ((instruction >> 21) & 1) != 0;
        const bool load = ((instruction >> 20) & 1) != 0;
        const u32 rn = (instruction >> 16) & 0xF;
        const u32 register_list = instruction & 0xFFFF;

        const bool includes_pc = (register_list & (1U << 15)) != 0;
        const bool unpredictable_user_writeback =
            user_mode_or_psr && writeback && (!load || !includes_pc);
        if (unpredictable_user_writeback) {
            return false;
        }
        {
            if (load && includes_pc) {
                block.terminal = Terminal::IndirectBranch;
            }
            if (condition == ConditionCode::AL && rn != 15 && load && includes_pc &&
                !user_mode_or_psr) {
                block.ops.push_back({
                    .opcode = Opcode::ArmLoadMultipleWithPcFast,
                    .arg0 = static_cast<u32>(writeback) |
                            (static_cast<u32>(add_offset) << 1) |
                            (static_cast<u32>(pre_indexed) << 2),
                    .arg1 = rn | (register_list << 8),
                    .arg2 = CountBits(register_list),
                });
                return true;
            }
            if (condition == ConditionCode::AL && rn != 15 && register_list != 0 &&
                !includes_pc && !user_mode_or_psr) {
                block.ops.push_back({
                    .opcode = load ? Opcode::ArmLoadMultipleFast : Opcode::ArmStoreMultipleFast,
                    .arg0 = static_cast<u32>(writeback) |
                            (static_cast<u32>(add_offset) << 1) |
                            (static_cast<u32>(pre_indexed) << 2),
                    .arg1 = rn | (register_list << 8),
                    .arg2 = CountBits(register_list),
                });
                return true;
            }
            block.ops.push_back({
                .opcode = Opcode::ArmLoadStoreMultiple,
                .arg0 = condition | (static_cast<u32>(load) << 8) |
                        (static_cast<u32>(writeback) << 9) |
                        (static_cast<u32>(add_offset) << 10) |
                        (static_cast<u32>(pre_indexed) << 11) |
                        (static_cast<u32>(user_mode_or_psr) << 12),
                .arg1 = rn | (register_list << 8),
                .arg2 = CountBits(register_list),
            });
            return true;
        }
    }

    return false;
}

bool TryAppendThumbBranchInstruction(Block& block, u32 instruction, u32 pc) {
    const u32 major_opcode = (instruction >> 11) & 0x1F;
    if (major_opcode == 26 || major_opcode == 27) {
        const u32 condition = (instruction >> 8) & 0xF;
        const bool is_svc = condition == 0xF;
        const bool undefined_condition = condition == 0xE;
        if (is_svc || undefined_condition) {
            return false;
        }

        const u32 offset =
            ((instruction & 0x7F) << 1) | ((instruction & (1U << 7)) != 0 ? 0xFFFFFF00 : 0);
        block.terminal = Terminal::DirectBranch;
        block.ops.push_back({
            .opcode = Opcode::ArmBranch,
            .arg0 = pc + 4 + offset,
            .arg1 = condition,
        });
        return true;
    }

    if (major_opcode == 28) {
        const u32 offset =
            ((instruction & 0x3FF) << 1) | ((instruction & (1U << 10)) != 0 ? 0xFFFFF800 : 0);
        block.terminal = Terminal::DirectBranch;
        block.ops.push_back({
            .opcode = Opcode::ArmBranchAlways,
            .arg0 = pc + 4 + offset,
        });
        return true;
    }

    if (major_opcode == 29) {
        if ((instruction & 1) != 0) {
            return false;
        }
        block.terminal = Terminal::IndirectBranch;
        block.ops.push_back({
            .opcode = Opcode::ThumbBranchLinkExchange,
            .arg0 = (instruction & 0x07FF) << 1,
        });
        return true;
    }

    if (major_opcode == 30) {
        block.ops.push_back({
            .opcode = Opcode::ThumbBranchLinkSetup,
            .arg0 = ((instruction & 0x07FF) << 12) |
                    ((instruction & (1U << 10)) != 0 ? 0xFF800000 : 0),
        });
        return true;
    }

    if (major_opcode == 31) {
        block.terminal = Terminal::IndirectBranch;
        block.ops.push_back({
            .opcode = Opcode::ThumbBranchLink,
            .arg0 = (instruction & 0x07FF) << 1,
        });
        return true;
    }

    return false;
}

bool TryAppendThumbSpecialInstruction(Block& block, u32 instruction, [[maybe_unused]] u32 pc) {
    const bool is_hint = (instruction & 0xFF0F) == 0xBF00;
    if (is_hint) {
        block.ops.push_back({
            .opcode = Opcode::ArmHint,
            .arg0 = ConditionCode::AL,
        });
        return true;
    }

    const bool is_breakpoint = (instruction & 0xFF00) == 0xBE00;
    if (is_breakpoint) {
        block.ops.push_back({
            .opcode = Opcode::ArmHint,
            .arg0 = ConditionCode::AL,
        });
        return true;
    }

    const bool is_pop = (instruction & 0xFE00) == 0xBC00;
    const bool pop_pc = is_pop && ((instruction >> 8) & 1) != 0;
    if (pop_pc) {
        const u32 register_list = (instruction & 0x00FF) | (1U << 15);
        block.terminal = Terminal::IndirectBranch;
        block.ops.push_back({
            .opcode = Opcode::ArmLoadMultipleWithPcFast,
            .arg0 = 1U | (1U << 1),
            .arg1 = 13 | (register_list << 8),
            .arg2 = CountBits(register_list),
        });
        return true;
    }

    return false;
}

} // namespace

bool BlockCache::SupportsArmInstruction(u32 instruction) {
    Block block;
    return TryAppendArmInstruction(block, instruction, 0);
}

const Block& BlockCache::GetOrTranslateBlock(u32 pc, u32 cpsr, Memory::MemorySystem& memory) {
    return GetOrTranslateBlock(MakeKey(pc, cpsr), memory);
}

const Block& BlockCache::GetOrTranslateBlock(const BlockKey& key, Memory::MemorySystem& memory) {
    stats.lookups++;
    if (const Block* block = LookupRecentBlock(key)) {
        return *block;
    }

    if (dense_cache_enabled) {
        if (const Block* block = LookupDenseBlock(key)) {
            stats.dense_hits++;
            RememberBlock(key, *block);
            return *block;
        }
    }

    auto it = blocks.find(key);
    if (it != blocks.end()) {
        stats.map_hits++;
        RememberBlock(key, it->second);
        if (dense_cache_enabled) {
            RememberDenseBlock(key, it->second);
        }
        return it->second;
    }

    auto block = TranslateBlock(key, memory);
    auto [inserted, _] = blocks.emplace(key, std::move(block));
    stats.translations++;
    g_ir_translations.fetch_add(1, std::memory_order_relaxed);
    RememberBlock(key, inserted->second);
    if (dense_cache_enabled) {
        RememberDenseBlock(key, inserted->second);
    }
    return inserted->second;
}

const Block& BlockCache::GetOrTranslateLinkedBlockAfterLinkMiss(const Block& source,
                                                                const BlockKey& key,
                                                                Memory::MemorySystem& memory) {
    const Block& block = GetOrTranslateBlock(key, memory);
    RememberBlockLink(source, key, block);
    return block;
}

void BlockCache::Clear() {
    blocks.clear();
    ClearRecentBlocks();
    AdvanceDenseGeneration();
}

void BlockCache::InvalidateRange(u32 start_address, std::size_t length) {
    if (length == 0 || blocks.empty()) {
        return;
    }

    const u32 length32 =
        length > std::numeric_limits<u32>::max() ? std::numeric_limits<u32>::max()
                                                 : static_cast<u32>(length);
    const u32 end_address = start_address + length32;
    const bool wrapped = end_address < start_address;
    bool erased_block = false;

    for (auto it = blocks.begin(); it != blocks.end();) {
        const Block& block = it->second;
        const u32 block_end = block.start_pc + block.byte_size;
        const bool block_wrapped = block_end < block.start_pc;
        const bool start_in_range =
            AddressInRange(block.start_pc, start_address, end_address, wrapped);
        const bool end_in_range =
            block.byte_size != 0 &&
            AddressInRange(block_end - 1, start_address, end_address, wrapped);
        const bool range_starts_in_block =
            block_wrapped ? (start_address >= block.start_pc || start_address < block_end)
                          : (start_address >= block.start_pc && start_address < block_end);

        if (start_in_range || end_in_range || range_starts_in_block) {
            it = blocks.erase(it);
            erased_block = true;
        } else {
            ++it;
        }
    }
    if (erased_block) {
        ClearRecentBlocks();
        ClearBlockLinks();
        AdvanceDenseGeneration();
        Core::g_ir_invalidate_erased.fetch_add(1, std::memory_order_relaxed);
    }
}

const Block* BlockCache::LookupDenseBlock(const BlockKey& key) {
    const u32 guest_page = key.pc >> Memory::CITRA_PAGE_BITS;
    DensePage* page = GetDensePage(guest_page);
    if (!page) {
        return nullptr;
    }

    page->recently_used = true;
    const std::size_t index = (key.pc & Memory::CITRA_PAGE_MASK) >> 1;
    const DenseEntry& entry = page->entries[index];
    if (entry.generation == dense_generation && entry.block && entry.key == key) {
        return entry.block;
    }
    return nullptr;
}

void BlockCache::RememberDenseBlock(const BlockKey& key, const Block& block) {
    const u32 guest_page = key.pc >> Memory::CITRA_PAGE_BITS;
    DensePage& page = GetOrCreateDensePage(guest_page);
    const std::size_t index = (key.pc & Memory::CITRA_PAGE_MASK) >> 1;
    page.entries[index] = {
        .block = &block,
        .key = key,
        .generation = dense_generation,
    };
    page.recently_used = true;
}

BlockCache::DensePage* BlockCache::GetDensePage(u32 guest_page) {
    const std::size_t region_index = guest_page >> DenseRegionBits;
    const std::size_t page_index = guest_page & (DenseRegionSize - 1);
    const auto& region = dense_regions[region_index];
    return region ? region->pages[page_index].get() : nullptr;
}

BlockCache::DensePage& BlockCache::GetOrCreateDensePage(u32 guest_page) {
    const std::size_t region_index = guest_page >> DenseRegionBits;
    const std::size_t page_index = guest_page & (DenseRegionSize - 1);
    auto& region = dense_regions[region_index];
    if (!region) {
        region = std::make_unique<DenseRegion>();
    }
    if (region->pages[page_index]) {
        return *region->pages[page_index];
    }

    constexpr std::size_t DenseCacheBudget = 24U * 1024U * 1024U;
    constexpr std::size_t MaxDensePages = DenseCacheBudget / sizeof(DensePage);
    if (dense_clock_pages.size() < MaxDensePages) {
        dense_clock_pages.push_back(guest_page);
    } else {
        for (;;) {
            const u32 victim_page = dense_clock_pages[dense_clock_hand];
            DensePage* victim = GetDensePage(victim_page);
            if (!victim || !victim->recently_used) {
                if (victim) {
                    const std::size_t victim_region_index = victim_page >> DenseRegionBits;
                    const std::size_t victim_page_index = victim_page & (DenseRegionSize - 1);
                    dense_regions[victim_region_index]->pages[victim_page_index].reset();
                }
                dense_clock_pages[dense_clock_hand] = guest_page;
                dense_clock_hand = (dense_clock_hand + 1) % dense_clock_pages.size();
                break;
            }
            victim->recently_used = false;
            dense_clock_hand = (dense_clock_hand + 1) % dense_clock_pages.size();
        }
    }

    region->pages[page_index] = std::make_unique<DensePage>();
    return *region->pages[page_index];
}

void BlockCache::AdvanceDenseGeneration() {
    dense_generation++;
    if (dense_generation != 0) {
        return;
    }

    dense_generation = 1;
    for (auto& region : dense_regions) {
        if (!region) {
            continue;
        }
        for (auto& page : region->pages) {
            if (!page) {
                continue;
            }
            for (DenseEntry& entry : page->entries) {
                entry.generation = 0;
                entry.block = nullptr;
            }
        }
    }
}

const Block* BlockCache::LookupRecentBlock(const BlockKey& key) const {
    const auto index = BlockKeyHash{}(key) & (recent_blocks.size() - 1);
    const BlockLookupCacheEntry& entry = recent_blocks[index];
    if (entry.valid && entry.key == key) {
        return entry.block;
    }
    return nullptr;
}

void BlockCache::RememberBlock(const BlockKey& key, const Block& block) {
    const auto index = BlockKeyHash{}(key) & (recent_blocks.size() - 1);
    recent_blocks[index] = {
        .key = key,
        .block = &block,
        .valid = true,
    };
}

void BlockCache::ClearRecentBlocks() {
    for (BlockLookupCacheEntry& entry : recent_blocks) {
        entry.valid = false;
        entry.block = nullptr;
    }
}

const Block* BlockCache::LookupBlockLinkAfterLastMiss(const Block& source, const BlockKey& key) {
    const auto index = BlockKeyHash{}(key) & (source.links.slots.size() - 1);
    const BlockLink& link = source.links.slots[index];
    if (link.valid && link.key == key) {
        source.links.last = link;
        return link.block;
    }

    for (std::size_t i = 0; i < source.links.slots.size(); ++i) {
        if (i == index) {
            continue;
        }
        const BlockLink& fallback_link = source.links.slots[i];
        if (fallback_link.valid && fallback_link.key == key) {
            source.links.last = fallback_link;
            return fallback_link.block;
        }
    }
    return nullptr;
}

void BlockCache::RememberBlockLink(const Block& source, const BlockKey& key, const Block& block) {
    const auto index = BlockKeyHash{}(key) & (source.links.slots.size() - 1);
    BlockLink* target_link = &source.links.slots[index];
    if (target_link->valid && !(target_link->key == key)) {
        for (BlockLink& link : source.links.slots) {
            if (!link.valid || link.key == key) {
                target_link = &link;
                break;
            }
        }
    }

    *target_link = {
        .key = key,
        .block = &block,
        .valid = true,
    };
    source.links.last = *target_link;
}

void BlockCache::ClearBlockLinks() {
    for (auto& [_, block] : blocks) {
        block.links.last.valid = false;
        block.links.last.block = nullptr;
        for (BlockLink& link : block.links.slots) {
            link.valid = false;
            link.block = nullptr;
        }
    }
}

Block BlockCache::TranslateBlock(const BlockKey& key, Memory::MemorySystem& memory) {
    const bool thumb = (key.cpsr_key & TBIT) != 0;

    Block block;
    block.key = key;
    block.start_pc = key.pc;
    block.thumb = thumb;
    block.terminal = Terminal::Fallthrough;
    auto finalize_block = [&block]() {
        FuseCompareBranch(block);
        AddConditionalSkipGuards(block);
        block.direct_branch_preserves_cpsr_key = DirectBranchPreservesCpsrKey(block);
        return block;
    };

    for (u32 i = 0; i < MaxBlockInstructions; ++i) {
        const u32 pc = key.pc + block.byte_size;
        u32 instruction = memory.Read32(pc & 0xFFFFFFFC);
        u32 thumb_instruction = 0;
        u32 instruction_size = 4;
        if (thumb) {
            thumb_instruction = GetThumbInstruction(instruction, pc);
            if (TryAppendThumbSpecialInstruction(block, thumb_instruction, pc)) {
                instruction_size = 2;
                block.ops.back().guest_size = static_cast<u8>(instruction_size);
                block.byte_size += instruction_size;
                block.guest_instruction_count++;
                if (block.terminal != Terminal::Fallthrough || (pc & 0xFFF) >= 0xFFE) {
                    return finalize_block();
                }
                continue;
            }

            u32 arm_instruction = 0;
            ThumbDecodeStatus status =
                TranslateThumbInstruction(pc, instruction, &arm_instruction, &instruction_size);
            if (status != ThumbDecodeStatus::UNINITIALIZED &&
                status != ThumbDecodeStatus::DECODED) {
                if (status == ThumbDecodeStatus::BRANCH &&
                    TryAppendThumbBranchInstruction(block, thumb_instruction, pc)) {
                    block.ops.back().guest_size = static_cast<u8>(instruction_size);
                    block.byte_size += instruction_size;
                    block.guest_instruction_count++;
                    return finalize_block();
                }
                if (block.ops.empty()) {
                    return MakeFallbackBlock(key, FallbackReason::UnsupportedInstruction, pc,
                                             thumb_instruction);
                }
                block.terminal = Terminal::Fallback;
                block.fallback_reason = FallbackReason::UnsupportedInstruction;
                block.fallback_pc = pc;
                block.fallback_instruction = thumb_instruction;
                return finalize_block();
            }
            instruction = arm_instruction;
        }

        if (!TryAppendArmInstruction(block, instruction, pc) &&
            !(thumb && TryAppendThumbSpecialInstruction(block, thumb_instruction, pc))) {
            const u32 fallback_instruction = thumb ? thumb_instruction : instruction;
            if (block.ops.empty()) {
                return MakeFallbackBlock(key, FallbackReason::UnsupportedInstruction, pc,
                                         fallback_instruction);
            }
            block.terminal = Terminal::Fallback;
            block.fallback_reason = FallbackReason::UnsupportedInstruction;
            block.fallback_pc = pc;
            block.fallback_instruction = fallback_instruction;
            return finalize_block();
        }
        block.ops.back().guest_size = static_cast<u8>(instruction_size);

        block.byte_size += instruction_size;
        block.guest_instruction_count++;
        if (block.terminal != Terminal::Fallthrough ||
            (thumb ? (pc & 0xFFF) >= 0xFFE : (pc & 0xFFF) == 0xFFC)) {
            return finalize_block();
        }
    }

    return finalize_block();
}

Block BlockCache::MakeFallbackBlock(const BlockKey& key, FallbackReason reason, u32 fallback_pc,
                                    u32 fallback_instruction) {
    const bool thumb = (key.cpsr_key & TBIT) != 0;
    Block block;
    block.key = key;
    block.start_pc = key.pc;
    block.byte_size = thumb ? 2 : 4;
    block.thumb = thumb;
    block.terminal = Terminal::Fallback;
    block.fallback_reason = reason;
    block.fallback_pc = fallback_pc;
    block.fallback_instruction = fallback_instruction;
    block.guest_instruction_count = 0;
    block.ops.push_back({
        .opcode = Opcode::Unimplemented,
    });
    return block;
}

} // namespace Core::ARMIR
