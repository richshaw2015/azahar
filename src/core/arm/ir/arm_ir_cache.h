// Copyright Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#pragma once

#include <array>
#include <cstddef>
#include <memory>
#include <unordered_map>
#include <vector>
#include "common/common_types.h"
#include "core/arm/skyeye_common/armstate.h"

namespace Memory {
class MemorySystem;
}

namespace Core::ARMIR {

enum class Opcode : u16 {
    Unimplemented,
    ArmBranch,
    ArmBranchExchange,
    ArmBranchLinkExchange,
    ArmHint,
    ArmClearExclusive,
    ArmChangeProcessorState,
    ArmSetEndian,
    ArmDataProcessingImmediate,
    ArmDataProcessingRegister,
    ArmLoadStoreImmediate,
    ArmLoadStoreRegister,
    ArmLoadStoreHalfword,
    ArmLoadStoreDouble,
    ArmLoadStoreMultiple,
    ArmMultiply,
    ArmMultiplyLong,
    ArmCountLeadingZeros,
    ArmExtend,
    ArmReverse,
    ArmExclusiveLoad,
    ArmExclusiveStore,
    ArmCoprocessor15Transfer,
    ArmCoprocessorDataProcessing,
    ArmMoveStatusToRegister,
    ArmMoveRegisterToStatus,
    ThumbBranchLinkSetup,
    ThumbBranchLink,
    ThumbBranchLinkExchange,
    ArmSupervisorCall,
    ArmLoadWordImmediate,
    ArmStoreWordImmediate,
    ArmLoadWordRegister,
    ArmStoreWordRegister,
    ArmBranchAlways,
    ArmLoadByteImmediate,
    ArmStoreByteImmediate,
    ArmLoadByteRegister,
    ArmStoreByteRegister,
    ArmLoadHalfwordImmediate,
    ArmStoreHalfwordImmediate,
    ArmLoadSignedByteImmediate,
    ArmLoadSignedHalfwordImmediate,
    ArmLoadHalfwordRegister,
    ArmStoreHalfwordRegister,
    ArmLoadSignedByteRegister,
    ArmLoadSignedHalfwordRegister,
    ArmDataProcessingImmediateAlways,
    ArmDataProcessingRegisterAlways,
    ArmVFPRegisterTransfer,
    ArmVFPSystemRegisterTransfer,
    ArmVFPLoadStore,
    ArmVFPDataProcessing,
    ArmPackHalfword,
    ArmUnsignedSumAbsoluteDifference,
    ArmSwap,
    ArmUnsignedMultiplyAccumulateAccumulateLong,
    ArmExtendAdd,
    ArmSaturate,
    ArmSignedHalfwordMultiply,
    ArmSignedWordHalfwordMultiply,
    ArmSignedDualMultiply,
    ArmSignedDualMultiplyLong,
    ArmSignedMostSignificantMultiply,
    ArmSaturatingArithmetic,
    ArmParallelAddSub,
    ArmSelectBytes,
    ArmSignedHalvingParallelAddSub,
    ArmUnsignedHalvingParallelAddSub,
    ArmSignedSaturatingParallelAddSub,
    ArmUnsignedSaturatingParallelAddSub,
    ArmStoreReturnState,
    ArmReturnFromException,
    ArmMoveImmediateAlways,
    ArmAddImmediateAlways,
    ArmSubImmediateAlways,
    ArmCompareImmediateAlways,
    ArmMoveRegisterAlways,
    ArmAddRegisterAlways,
    ArmSubRegisterAlways,
    ArmCompareRegisterAlways,
    ArmAddImmediateSetFlagsAlways,
    ArmSubImmediateSetFlagsAlways,
    ArmCompareNegativeImmediateAlways,
    ArmAddRegisterSetFlagsAlways,
    ArmSubRegisterSetFlagsAlways,
    ArmCompareNegativeRegisterAlways,
    ArmLogicalImmediateSetFlagsAlways,
    ArmLogicalRegisterSetFlagsAlways,
    ArmLogicalImmediateAlways,
    ArmLogicalRegisterAlways,
    ArmMoveShiftedRegisterAlways,
    ArmMoveShiftedRegisterSetFlagsAlways,
    ArmAddShiftedRegisterAlways,
    ArmSubShiftedRegisterAlways,
    ArmCompareShiftedRegisterAlways,
    ArmAddShiftedRegisterSetFlagsAlways,
    ArmSubShiftedRegisterSetFlagsAlways,
    ArmCompareNegativeShiftedRegisterAlways,
    ArmLogicalShiftedRegisterAlways,
    ArmLogicalShiftedRegisterSetFlagsAlways,
    ArmMoveRegisterShiftedRegisterAlways,
    ArmMoveRegisterShiftedRegisterSetFlagsAlways,
    ArmAddRegisterShiftedRegisterAlways,
    ArmSubRegisterShiftedRegisterAlways,
    ArmCompareRegisterShiftedRegisterAlways,
    ArmAddRegisterShiftedRegisterSetFlagsAlways,
    ArmSubRegisterShiftedRegisterSetFlagsAlways,
    ArmCompareNegativeRegisterShiftedRegisterAlways,
    ArmLogicalRegisterShiftedRegisterAlways,
    ArmLogicalRegisterShiftedRegisterSetFlagsAlways,
    ArmArithmeticImmediateAlways,
    ArmArithmeticImmediateSetFlagsAlways,
    ArmArithmeticRegisterAlways,
    ArmArithmeticRegisterSetFlagsAlways,
    ArmArithmeticShiftedRegisterAlways,
    ArmArithmeticShiftedRegisterSetFlagsAlways,
    ArmArithmeticRegisterShiftedRegisterAlways,
    ArmArithmeticRegisterShiftedRegisterSetFlagsAlways,
    ArmLoadWordImmediateWriteback,
    ArmStoreWordImmediateWriteback,
    ArmLoadByteImmediateWriteback,
    ArmStoreByteImmediateWriteback,
    ArmLoadWordRegisterWriteback,
    ArmStoreWordRegisterWriteback,
    ArmLoadByteRegisterWriteback,
    ArmStoreByteRegisterWriteback,
    ArmLoadHalfwordImmediateWriteback,
    ArmStoreHalfwordImmediateWriteback,
    ArmLoadSignedByteImmediateWriteback,
    ArmLoadSignedHalfwordImmediateWriteback,
    ArmLoadHalfwordRegisterWriteback,
    ArmStoreHalfwordRegisterWriteback,
    ArmLoadSignedByteRegisterWriteback,
    ArmLoadSignedHalfwordRegisterWriteback,
    ArmLoadMultipleFast,
    ArmStoreMultipleFast,
    ArmVFPLoadSingleFast,
    ArmVFPStoreSingleFast,
    ArmVFPLoadDoubleFast,
    ArmVFPStoreDoubleFast,
    ArmVFPLoadMultipleFast,
    ArmVFPStoreMultipleFast,
    ArmLoadDoubleFast,
    ArmStoreDoubleFast,
    ArmBranchExchangeAlways,
    ArmBranchLinkExchangeRegisterAlways,
    ArmLoadMultipleWithPcFast,
    ArmMultiplyAlways,
    ArmMultiplyLongAlways,
    ArmUnsignedMultiplyAccumulateAccumulateLongAlways,
    ArmVFPRegisterTransferAlways,
    ArmVFPDataProcessingAlways,
    ArmConditionalSkip,
    ArmAddImmediateNoPcAlways,
    ArmSubImmediateNoPcAlways,
    ArmCompareImmediateNoPcAlways,
    ArmAddRegisterNoPcAlways,
    ArmSubRegisterNoPcAlways,
    ArmCompareRegisterNoPcAlways,
    ArmAddImmediateSetFlagsNoPcAlways,
    ArmSubImmediateSetFlagsNoPcAlways,
    ArmCompareNegativeImmediateNoPcAlways,
    ArmAddRegisterSetFlagsNoPcAlways,
    ArmSubRegisterSetFlagsNoPcAlways,
    ArmCompareNegativeRegisterNoPcAlways,
    ArmLogicalImmediateNoPcAlways,
    ArmLogicalRegisterNoPcAlways,
    ArmLogicalImmediateSetFlagsNoPcAlways,
    ArmLogicalRegisterSetFlagsNoPcAlways,
    ArmArithmeticImmediateNoPcAlways,
    ArmArithmeticImmediateSetFlagsNoPcAlways,
    ArmArithmeticRegisterNoPcAlways,
    ArmArithmeticRegisterSetFlagsNoPcAlways,
    ArmLoadWordImmediateNoPc,
    ArmStoreWordImmediateNoPc,
    ArmLoadByteImmediateNoPc,
    ArmStoreByteImmediateNoPc,
    ArmLoadWordRegisterNoPc,
    ArmStoreWordRegisterNoPc,
    ArmLoadByteRegisterNoPc,
    ArmStoreByteRegisterNoPc,
    ArmLoadHalfwordImmediateNoPc,
    ArmStoreHalfwordImmediateNoPc,
    ArmLoadSignedByteImmediateNoPc,
    ArmLoadSignedHalfwordImmediateNoPc,
    ArmLoadHalfwordRegisterNoPc,
    ArmStoreHalfwordRegisterNoPc,
    ArmLoadSignedByteRegisterNoPc,
    ArmLoadSignedHalfwordRegisterNoPc,
    ArmAddShiftedRegisterNoPcAlways,
    ArmSubShiftedRegisterNoPcAlways,
    ArmCompareShiftedRegisterNoPcAlways,
    ArmAddShiftedRegisterSetFlagsNoPcAlways,
    ArmSubShiftedRegisterSetFlagsNoPcAlways,
    ArmCompareNegativeShiftedRegisterNoPcAlways,
    ArmLogicalShiftedRegisterNoPcAlways,
    ArmLogicalShiftedRegisterSetFlagsNoPcAlways,
    ArmArithmeticShiftedRegisterNoPcAlways,
    ArmArithmeticShiftedRegisterSetFlagsNoPcAlways,
    ArmAddRegisterShiftedRegisterNoPcAlways,
    ArmSubRegisterShiftedRegisterNoPcAlways,
    ArmCompareRegisterShiftedRegisterNoPcAlways,
    ArmAddRegisterShiftedRegisterSetFlagsNoPcAlways,
    ArmSubRegisterShiftedRegisterSetFlagsNoPcAlways,
    ArmCompareNegativeRegisterShiftedRegisterNoPcAlways,
    ArmLogicalRegisterShiftedRegisterNoPcAlways,
    ArmLogicalRegisterShiftedRegisterSetFlagsNoPcAlways,
    ArmArithmeticRegisterShiftedRegisterNoPcAlways,
    ArmArithmeticRegisterShiftedRegisterSetFlagsNoPcAlways,
    ArmCompareImmediateBranchNoPcAlways,
    ArmCompareRegisterBranchNoPcAlways,
    ArmCompareShiftedRegisterBranchNoPcAlways,
    ArmCompareRegisterShiftedRegisterBranchNoPcAlways,
    ArmTestImmediateBranchNoPcAlways,
    ArmTestRegisterBranchNoPcAlways,
    ArmTestShiftedRegisterBranchNoPcAlways,
    ArmTestRegisterShiftedRegisterBranchNoPcAlways,
    ArmAddSubImmediateSetFlagsBranchNoPcAlways,
    ArmAddSubRegisterSetFlagsBranchNoPcAlways,
    ArmAddSubShiftedRegisterSetFlagsBranchNoPcAlways,
    ArmAddSubRegisterShiftedRegisterSetFlagsBranchNoPcAlways,
    ArmLogicalImmediateSetFlagsBranchNoPcAlways,
    ArmLogicalRegisterSetFlagsBranchNoPcAlways,
    ArmLogicalShiftedRegisterSetFlagsBranchNoPcAlways,
    ArmLogicalRegisterShiftedRegisterSetFlagsBranchNoPcAlways,
    ArmCarryArithmeticImmediateSetFlagsBranchNoPcAlways,
    ArmCarryArithmeticRegisterSetFlagsBranchNoPcAlways,
    ArmCarryArithmeticShiftedRegisterSetFlagsBranchNoPcAlways,
    ArmCarryArithmeticRegisterShiftedRegisterSetFlagsBranchNoPcAlways,
    ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysLsl,
    ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysLsr,
    ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysAsr,
    ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysRor,
    ArmLoadWordImmediateNoPcAdd,
    ArmLoadWordImmediateNoPcSub,
    ArmStoreWordImmediateNoPcAdd,
    ArmStoreWordImmediateNoPcSub,
    ArmLoadByteImmediateNoPcAdd,
    ArmLoadByteImmediateNoPcSub,
    ArmStoreByteImmediateNoPcAdd,
    ArmStoreByteImmediateNoPcSub,
    ArmLoadHalfwordImmediateNoPcAdd,
    ArmLoadHalfwordImmediateNoPcSub,
    ArmStoreHalfwordImmediateNoPcAdd,
    ArmStoreHalfwordImmediateNoPcSub,
    ArmLoadWordRegisterNoPcAdd,
    ArmLoadWordRegisterNoPcSub,
    ArmStoreWordRegisterNoPcAdd,
    ArmStoreWordRegisterNoPcSub,
    ArmLoadByteRegisterNoPcAdd,
    ArmLoadByteRegisterNoPcSub,
    ArmStoreByteRegisterNoPcAdd,
    ArmStoreByteRegisterNoPcSub,
    ArmLoadHalfwordRegisterNoPcAdd,
    ArmLoadHalfwordRegisterNoPcSub,
    ArmStoreHalfwordRegisterNoPcAdd,
    ArmStoreHalfwordRegisterNoPcSub,
    ArmLoadSignedByteRegisterNoPcAdd,
    ArmLoadSignedByteRegisterNoPcSub,
    ArmLoadSignedHalfwordRegisterNoPcAdd,
    ArmLoadSignedHalfwordRegisterNoPcSub,
    ArmLoadSignedByteImmediateNoPcAdd,
    ArmLoadSignedByteImmediateNoPcSub,
    ArmLoadSignedHalfwordImmediateNoPcAdd,
    ArmLoadSignedHalfwordImmediateNoPcSub,
    ArmTstShiftedRegisterNoPcAlwaysLsl,
    ArmTstShiftedRegisterNoPcAlwaysLsr,
    ArmTstShiftedRegisterNoPcAlwaysAsr,
    ArmTstShiftedRegisterNoPcAlwaysRor,
    ArmTeqShiftedRegisterNoPcAlwaysLsl,
    ArmTeqShiftedRegisterNoPcAlwaysLsr,
    ArmTeqShiftedRegisterNoPcAlwaysAsr,
    ArmTeqShiftedRegisterNoPcAlwaysRor,
    ArmConditionalSkipEq,
    ArmConditionalSkipNe,
    ArmConditionalSkipCs,
    ArmConditionalSkipCc,
    ArmConditionalSkipMi,
    ArmConditionalSkipPl,
    ArmConditionalSkipVs,
    ArmConditionalSkipVc,
    ArmConditionalSkipHi,
    ArmConditionalSkipLs,
    ArmConditionalSkipGe,
    ArmConditionalSkipLt,
    ArmConditionalSkipGt,
    ArmConditionalSkipLe,
    ArmLoadWordImmediateNoPcOffset0,
    ArmStoreWordImmediateNoPcOffset0,
    ArmLoadByteImmediateNoPcOffset0,
    ArmStoreByteImmediateNoPcOffset0,
    ArmLoadHalfwordImmediateNoPcOffset0,
    ArmStoreHalfwordImmediateNoPcOffset0,
    ArmLoadSignedByteImmediateNoPcOffset0,
    ArmLoadSignedHalfwordImmediateNoPcOffset0,
    ArmMoveImmediateSetFlagsAlways,
    ArmMoveRegisterSetFlagsAlways,
    ArmMoveNotRegisterSetFlagsAlways,
    ArmMoveNotRegisterAlways,
    ArmTstRegisterNoShiftNoPcAlways,
    ArmTeqRegisterNoShiftNoPcAlways,
    ArmTstImmediateNoPcAlways,
    ArmTeqImmediateNoPcAlways,
    ArmCompareZeroImmediateNoPcAlways,
    Count,
};

constexpr std::size_t OpcodeCount = static_cast<std::size_t>(Opcode::Count);

enum class Terminal : u8 {
    Fallthrough,
    Fallback,
    DirectBranch,
    IndirectBranch,
    Exception,
};

enum class FallbackReason : u8 {
    BackendIncomplete,
    UnsupportedInstruction,
    DecodeFailure,
    PendingInterrupt,
};

struct Op {
    Opcode opcode{};
    u8 guest_size{4};
    u32 arg0{};
    u32 arg1{};
    u32 arg2{};
};
static_assert(sizeof(Op) == 16);

constexpr std::size_t MaxBlockInstructions = 48;
constexpr std::size_t MaxBlockOps = MaxBlockInstructions + (MaxBlockInstructions / 2);

class OpBuffer {
public:
    void push_back(const Op& op) {
        ops[count++] = op;
    }

    Op& back() {
        return ops[count - 1];
    }

    const Op& back() const {
        return ops[count - 1];
    }

    Op& operator[](std::size_t index) {
        return ops[index];
    }

    const Op& operator[](std::size_t index) const {
        return ops[index];
    }

    bool insert(std::size_t index, const Op& op) {
        if (count >= ops.size() || index > count) {
            return false;
        }
        for (std::size_t i = count; i > index; --i) {
            ops[i] = ops[i - 1];
        }
        ops[index] = op;
        count++;
        return true;
    }

    void pop_back() {
        if (count != 0) {
            count--;
        }
    }

    bool empty() const {
        return count == 0;
    }

    std::size_t size() const {
        return count;
    }

    Op* begin() {
        return ops.data();
    }

    Op* end() {
        return ops.data() + count;
    }

    const Op* begin() const {
        return ops.data();
    }

    const Op* end() const {
        return ops.data() + count;
    }

private:
    std::array<Op, MaxBlockOps> ops{};
    std::size_t count{};
};

struct BlockKey {
    u32 pc{};
    u32 cpsr_key{};

    bool operator==(const BlockKey& other) const {
        return pc == other.pc && cpsr_key == other.cpsr_key;
    }
};

struct BlockKeyHash {
    std::size_t operator()(const BlockKey& key) const {
        const u64 mixed = (static_cast<u64>(key.pc) << 32) | key.cpsr_key;
        return static_cast<std::size_t>(mixed ^ (mixed >> 33) ^ (mixed >> 17));
    }
};

struct Block;

struct BlockLookupCacheEntry {
    BlockKey key{};
    const Block* block{};
    bool valid{};
};

using BlockLink = BlockLookupCacheEntry;

constexpr std::size_t BlockLookupCacheSize = 1024;
constexpr std::size_t BlockLinkSlots = 4;
constexpr u32 BlockCpsrKeyMask = TBIT | EBIT | MODEBITS;

struct BlockLinks {
    BlockLink last{};
    std::array<BlockLink, BlockLinkSlots> slots{};
};

// Threaded-code record for the AArch64 executor (src/core/arm/asm).
// arm_asm_exec.S fixes this layout to { handler, a0, a1, a2, a3 } = 40
// bytes via arm_asm_layout.h; handler holds a host function pointer.
struct AsmOp {
    u64 handler{};
    u64 a0{};
    u64 a1{};
    u64 a2{};
    u64 a3{};
};
static_assert(sizeof(AsmOp) == 40);

// Translated program for the AArch64 executor; built lazily per block.
struct AsmProgram {
    std::vector<AsmOp> ops;
    // Bitmask of guest r0-r2 held in resident host registers for this
    // program (0 = none). A program is resident only when every record is
    // provably safe against stale regfile copies of r0-r2.
    u32 resmask = 0;
};

struct Block {
    BlockKey key{};
    u32 start_pc{};
    u32 byte_size{};
    bool thumb{};
    Terminal terminal{Terminal::Fallback};
    FallbackReason fallback_reason{FallbackReason::BackendIncomplete};
    u32 fallback_pc{};
    u32 fallback_instruction{};
    u32 guest_instruction_count{};
    bool direct_branch_preserves_cpsr_key{};
    OpBuffer ops;
    mutable BlockLinks links;
    // shared_ptr rather than unique_ptr: TranslateBlock returns Block by
    // value through paths that require a copyable type.
    mutable std::shared_ptr<AsmProgram> asm_program;
    // Consecutive assembly runs that entered the executor but bailed on a
    // slow op after fewer than kAsmMinUsefulOps guest instructions. At
    // kAsmBadRunSkipThreshold the interpreter stops entering asm for this
    // block (the record stream still serves inbound chain jumps).
    mutable u8 asm_bad_runs{};
};

class BlockCache {
public:
    struct Stats {
        u64 lookups{};
        u64 dense_hits{};
        u64 map_hits{};
        u64 translations{};
    };

    static bool SupportsArmInstruction(u32 instruction);
    const Block& GetOrTranslateBlock(u32 pc, u32 cpsr, Memory::MemorySystem& memory);
    const Block& GetOrTranslateBlock(const BlockKey& key, Memory::MemorySystem& memory);
    const Block& GetOrTranslateLinkedBlockAfterLinkMiss(const Block& source, const BlockKey& key,
                                                        Memory::MemorySystem& memory);
    static const Block* LookupBlockLinkAfterLastMiss(const Block& source, const BlockKey& key);
    bool IsBlockCurrent(const Block& block, const BlockKey& key) const {
        return block.key == key;
    }
    Stats GetStats() const {
        return stats;
    }
    void SetDenseCacheEnabled(bool enabled) {
        dense_cache_enabled = enabled;
    }
    void Clear();
    void InvalidateRange(u32 start_address, std::size_t length);
    // `tag` distinguishes identical (pc, cpsr) pairs across different page
    // tables/processes; it lives in the upper cpsr_key bits which are unused
    // by BlockCpsrKeyMask.
    static BlockKey MakeKey(u32 pc, u32 cpsr, u64 tag = 0) {
        const bool thumb = (cpsr & TBIT) != 0;
        return {
            .pc = thumb ? (pc & ~1U) : (pc & ~3U),
            .cpsr_key = (cpsr & BlockCpsrKeyMask) |
                        static_cast<u32>((tag & 0xFFFFU) << 16),
        };
    }

private:
    struct DenseEntry {
        const Block* block{};
        BlockKey key{};
        u32 generation{};
    };

    static constexpr std::size_t DenseEntriesPerPage = 4096 / 2;
    static constexpr std::size_t DenseRegionBits = 10;
    static constexpr std::size_t DenseRegionSize = 1U << DenseRegionBits;
    static constexpr std::size_t DenseRegionCount = (1U << 20) / DenseRegionSize;

    struct DensePage {
        std::array<DenseEntry, DenseEntriesPerPage> entries{};
        bool recently_used{};
    };

    struct DenseRegion {
        std::array<std::unique_ptr<DensePage>, DenseRegionSize> pages{};
    };

    static Block TranslateBlock(const BlockKey& key, Memory::MemorySystem& memory);
    static Block MakeFallbackBlock(const BlockKey& key, FallbackReason reason,
                                   u32 fallback_pc = 0, u32 fallback_instruction = 0);
    const Block* LookupRecentBlock(const BlockKey& key) const;
    void RememberBlock(const BlockKey& key, const Block& block);
    void ClearRecentBlocks();
    static void RememberBlockLink(const Block& source, const BlockKey& key, const Block& block);
    void ClearBlockLinks();
    const Block* LookupDenseBlock(const BlockKey& key);
    void RememberDenseBlock(const BlockKey& key, const Block& block);
    DensePage& GetOrCreateDensePage(u32 guest_page);
    DensePage* GetDensePage(u32 guest_page);
    void AdvanceDenseGeneration();

    std::unordered_map<BlockKey, Block, BlockKeyHash> blocks;
    std::array<BlockLookupCacheEntry, BlockLookupCacheSize> recent_blocks{};
    std::array<std::unique_ptr<DenseRegion>, DenseRegionCount> dense_regions{};
    std::vector<u32> dense_clock_pages;
    std::size_t dense_clock_hand{};
    u32 dense_generation{1};
    bool dense_cache_enabled{true};
    Stats stats{};
};

} // namespace Core::ARMIR
