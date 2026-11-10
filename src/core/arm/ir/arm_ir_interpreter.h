// Copyright Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#pragma once

#include <array>
#include <atomic>
#include <memory>
#include "common/common_types.h"
#include "core/arm/arm_interface.h"
#include "core/arm/ir/arm_ir_cache.h"
#if defined(__aarch64__)
#include "core/arm/asm/arm_asm_exec.h"
#endif
#include "core/arm/skyeye_common/arm_regformat.h"
#include "core/arm/skyeye_common/armstate.h"

namespace Memory {
class MemorySystem;
}

namespace Kernel {
class SVCContext;
}

namespace Core {

class System;

class ARM_IRInterpreter final : public ARM_Interface {
public:
    explicit ARM_IRInterpreter(Core::System& system, Memory::MemorySystem& memory,
                               PrivilegeMode initial_mode, u32 id,
                               std::shared_ptr<Core::Timing::Timer> timer);
    ~ARM_IRInterpreter() override;

    void Run() override;
    void Step() override;

    void ClearInstructionCache() override;
    void InvalidateCacheRange(u32 start_address, std::size_t length) override;
    void ClearExclusiveState() override;

    void SetPageTable(const std::shared_ptr<Memory::PageTable>& page_table) override;

    void SetPC(u32 pc) override;
    u32 GetPC() const override;
    u32 GetReg(int index) const override;
    void SetReg(int index, u32 value) override;
    u32 GetVFPReg(int index) const override;
    void SetVFPReg(int index, u32 value) override;
    u32 GetVFPSystemReg(VFPSystemRegister reg) const override;
    void SetVFPSystemReg(VFPSystemRegister reg, u32 value) override;
    u32 GetCPSR() const override;
    void SetCPSR(u32 cpsr) override;
    u32 GetCP15Register(CP15Register reg) const override;
    void SetCP15Register(CP15Register reg, u32 value) override;

    void SaveContext(ThreadContext& ctx) override;
    void LoadContext(const ThreadContext& ctx) override;

    void PrepareReschedule() override;

    bool HasSingleInstructionBreakAccuracy() override {
        return true;
    }

    u64 GetIRFallbackCount() const {
        return ir_fallback_count;
    }

protected:
    std::shared_ptr<Memory::PageTable> GetPageTable() const override;

private:
    struct IRExecutionResult {
        u64 instructions{};
        u64 blocks{};
        u32 fallback_pc{};
        u32 fallback_instruction{};
        u32 fallback_reason{};
        bool fallback_thumb{};
        bool stop_execution{};
    };

    struct IRBlockResult {
        u32 instructions{};
        bool needs_fallback{};
        u32 fallback_pc{};
        u32 fallback_instruction{};
        u32 fallback_reason{};
        bool fallback_thumb{};
        bool stop_execution{};
        bool supervisor_call{};
        u32 supervisor_call_immediate{};
        u8 supervisor_call_guest_size{4};
        u32 blocks{};
        // When a chained run ends on a link miss or a tight self-branch,
        // these describe the chain's tail block and the successor key that
        // still needs resolution by the caller.
        const ARMIR::Block* link_source{};
        ARMIR::BlockKey link_key{};
        u32 conditional_skipped_instructions{};
        u32 fused_branch_evaluations{};
        u32 fused_branch_taken{};
    };

    struct LazyFlags {
        bool valid{};
        u8 mask{};
        u32 n{};
        u32 z{};
        u32 c{};
        u32 v{};
    };

    struct FastmemCacheEntry {
        u32 page{};
        u32 generation{};
        u8* pointer{};
        bool valid{};
    };
    static constexpr std::size_t FastmemCacheSize = 256;

    const ARMIR::Block& GetCurrentBlock();
    u32 GetCpsrForBlockKey() const;
    IRExecutionResult ExecuteIRInstructions(u64 num_instructions);
    template <bool ProfileOpcodes, bool CheckRemaining, bool BigEndian>
    IRBlockResult TryExecuteBlock(
        const ARMIR::Block& block, u64 remaining_instructions,
        std::array<u64, ARMIR::OpcodeCount>* opcode_counts);
#if defined(__aarch64__)
    template <bool CheckRemaining>
    std::size_t ExecuteAsmPrefix(const ARMIR::Block& block, u64 remaining_instructions,
                                 IRBlockResult& result);
#endif
    void HandleIRFallback(const IRExecutionResult& result, u64 requested_instructions);
    template <bool Profile>
    u8* GetFastMemoryPointerT(u32 address);
    u8* GetFastMemoryPointer(u32 address);
    u8* GetFastMemoryPointerUnprofiled(u32 address);
    template <bool Profile>
    u8* GetFastMemoryPointerForSpanT(u32 address, u32 bytes);
    template <bool Profile, u32 Bytes>
    u8* GetFastMemoryPointerForAccessT(u32 address);
    u8* GetFastMemoryPointerForSpan(u32 address, u32 bytes);
    void RefreshFastmemCacheForCurrentPageTable();
    void ResetFastmemCache();
    template <bool Profile, bool BigEndian>
    bool TryFastReadMemory16T(u32 address, u16& value);
    template <bool Profile, bool BigEndian>
    bool TryFastWriteMemory16T(u32 address, u16 value);
    template <bool Profile, bool BigEndian>
    bool TryFastReadMemory32T(u32 address, u32& value);
    template <bool Profile, bool BigEndian>
    bool TryFastWriteMemory32T(u32 address, u32 value);
    bool TryFastReadMemory16(u32 address, u16& value);
    bool TryFastWriteMemory16(u32 address, u16 value);
    bool TryFastReadMemory32(u32 address, u32& value);
    bool TryFastWriteMemory32(u32 address, u32 value);
    template <bool Profile>
    u8 ReadMemory8T(u32 address);
    template <bool Profile, bool BigEndian>
    u16 ReadMemory16T(u32 address);
    template <bool Profile, bool BigEndian>
    u32 ReadMemory32T(u32 address);
    template <bool Profile>
    void WriteMemory8T(u32 address, u8 value);
    template <bool Profile, bool BigEndian>
    void WriteMemory16T(u32 address, u16 value);
    template <bool Profile, bool BigEndian>
    void WriteMemory32T(u32 address, u32 value);
    template <bool Profile, bool BigEndian>
    void WriteMemory64T(u32 address, u64 value);
    u8 ReadMemory8(u32 address);
    u16 ReadMemory16(u32 address);
    u32 ReadMemory32(u32 address);
    void WriteMemory8(u32 address, u8 value);
    void WriteMemory16(u32 address, u16 value);
    void WriteMemory32(u32 address, u32 value);
    void WriteMemory64(u32 address, u64 value);
    void CountFastmemHit([[maybe_unused]] u64 count = 1) {
    }
    template <bool Profile>
    void CountFastmemHitT(u64 count = 1) {
        if constexpr (Profile) {
            current_fastmem_hits += count;
        } else {
            (void)count;
        }
    }
    void CountFastmemFallback() {
    }
    template <bool Profile>
    void CountFastmemFallbackT() {
        if constexpr (Profile) {
            current_fastmem_fallbacks++;
        }
    }
    void CountLazyFlagWrite() {
    }
    void CountLazyFlagMaterialization() {
    }
    template <bool Profile>
    void CountFusedBranch(IRBlockResult& result, bool taken) {
        if constexpr (Profile) {
            result.fused_branch_evaluations++;
            if (taken) {
                result.fused_branch_taken++;
            }
        }
    }
    void LoadFlagsFromCpsr();
    void SaveFlagsToCpsr();
    void ClearLazyFlags();
    void FlushLazyFlags();
    void SetLazyNZFlags(u32 result);
    void SetLazyNZFlags(u32 n, u32 z);
    void SetLazyLogicalFlags(u32 result, bool carry);
    void SetLazyArithmeticFlags(u32 result, bool carry, bool overflow);
    bool ReadNFlag() const;
    bool ReadZFlag() const;
    bool ReadCFlag() const;
    bool ReadVFlag() const;
    bool ConditionFailed(u32 condition) const;
    bool ConditionPassed(u32 condition) const;
    bool ConditionPassedOrAlways(u32 condition) const;
    template <u32 Condition>
    bool ConditionPassedT() const;
    template <bool ProfileOpcodes, bool CheckRemaining, u32 Condition>
    bool ExecuteConditionalSkipT(const ARMIR::Block& block, std::size_t& op_index,
                                 const ARMIR::Op& op, u64 remaining_instructions,
                                 IRBlockResult& result);
    template <u32 ShiftType, bool Subtract>
    void ExecuteAddSubShiftedRegisterNoPc(const ARMIR::Op& op);
    template <u32 ShiftType, bool CompareNegative>
    void ExecuteCompareShiftedRegisterNoPc(const ARMIR::Op& op);
    template <u32 ShiftType, bool Subtract>
    void ExecuteAddSubShiftedRegisterSetFlagsNoPc(const ARMIR::Op& op);
    template <u32 ShiftType, bool CheckRemaining, bool Profile>
    void ExecuteAddSubShiftedRegisterSetFlagsBranchNoPc(const ARMIR::Op& op,
                                                        u64 remaining_instructions,
                                                        IRBlockResult& result);
    template <u32 ShiftType, bool SetFlags>
    bool ExecuteCarryArithmeticShiftedRegisterNoPc(const ARMIR::Op& op);
    template <u32 ShiftType, bool CheckRemaining, bool Profile>
    bool ExecuteCarryArithmeticShiftedRegisterSetFlagsBranchNoPc(const ARMIR::Op& op,
                                                                 u64 remaining_instructions,
                                                                 IRBlockResult& result);
    template <u32 ShiftType, bool Subtract>
    void ExecuteAddSubRegisterShiftedRegisterNoPc(const ARMIR::Op& op);
    template <u32 ShiftType, bool CompareNegative>
    void ExecuteCompareRegisterShiftedRegisterNoPc(const ARMIR::Op& op);
    template <u32 ShiftType, bool Subtract>
    void ExecuteAddSubRegisterShiftedRegisterSetFlagsNoPc(const ARMIR::Op& op);
    template <u32 ShiftType>
    bool ExecuteLogicalRegisterShiftedRegisterNoPc(const ARMIR::Op& op);
    template <u32 ShiftType>
    bool ExecuteLogicalRegisterShiftedRegisterSetFlagsNoPc(const ARMIR::Op& op);
    template <u32 ShiftType, bool SetFlags>
    bool ExecuteCarryArithmeticRegisterShiftedRegisterNoPc(const ARMIR::Op& op);
    template <u32 ShiftType, bool CompareNegative, bool CheckRemaining, bool Profile>
    void ExecuteCompareRegisterShiftedRegisterBranchNoPc(const ARMIR::Op& op,
                                                         u64 remaining_instructions,
                                                         IRBlockResult& result);
    template <u32 ShiftType, bool CheckRemaining, bool Profile>
    void ExecuteTestRegisterShiftedRegisterBranchNoPc(const ARMIR::Op& op,
                                                      u64 remaining_instructions,
                                                      IRBlockResult& result);
    template <u32 ShiftType, bool CheckRemaining, bool Profile>
    void ExecuteAddSubRegisterShiftedRegisterSetFlagsBranchNoPc(
        const ARMIR::Op& op, u64 remaining_instructions, IRBlockResult& result);
    template <u32 ShiftType, bool CheckRemaining, bool Profile>
    bool ExecuteLogicalRegisterShiftedRegisterSetFlagsBranchNoPc(
        const ARMIR::Op& op, u64 remaining_instructions, IRBlockResult& result);
    template <u32 ShiftType, bool CheckRemaining, bool Profile>
    bool ExecuteCarryArithmeticRegisterShiftedRegisterSetFlagsBranchNoPc(
        const ARMIR::Op& op, u64 remaining_instructions, IRBlockResult& result);
    template <bool Profile, bool BigEndian, u32 ShiftType, bool Load, bool ByteTransfer>
    void ExecuteLoadStoreRegisterNoPc(const ARMIR::Op& op, IRBlockResult& result);
    template <bool Profile, bool BigEndian, u32 ShiftType, bool Load, bool ByteTransfer>
    void ExecuteLoadStoreRegisterWriteback(const ARMIR::Op& op, IRBlockResult& result);
    template <bool Profile, bool BigEndian, bool Load, bool ByteTransfer, bool Writeback>
    void DispatchLoadStoreRegisterByShiftType(const ARMIR::Op& op, IRBlockResult& result);
    template <u32 ShiftType, bool CompareNegative, bool CheckRemaining, bool Profile>
    void ExecuteCompareShiftedRegisterBranchNoPc(const ARMIR::Op& op, u64 remaining_instructions,
                                                 IRBlockResult& result);
    template <u32 ShiftType, bool CheckRemaining, bool Profile>
    void ExecuteTestShiftedRegisterBranchNoPc(const ARMIR::Op& op, u64 remaining_instructions,
                                              IRBlockResult& result);
    template <u32 ShiftType>
    bool ExecuteLogicalShiftedRegisterNoPc(const ARMIR::Op& op);
    template <u32 ShiftType>
    bool ExecuteLogicalShiftedRegisterSetFlagsNoPc(const ARMIR::Op& op);
    template <u32 ShiftType, bool TestEqual>
    void ExecuteTestShiftedRegisterSetFlagsNoPc(const ARMIR::Op& op);
    template <u32 ShiftType, bool CheckRemaining, bool Profile>
    bool ExecuteLogicalShiftedRegisterSetFlagsBranchNoPc(const ARMIR::Op& op,
                                                         u64 remaining_instructions,
                                                         IRBlockResult& result);
    void ExecuteDataProcessingNoFlags(u32 data_opcode, u32 rn_value, u32 rd, u32 operand);
    void ExecuteDataProcessingSetFlags(u32 data_opcode, u32 rn_value, u32 rd, u32 operand,
                                       bool shifter_carry);

    std::unique_ptr<Kernel::SVCContext> svc_context;
    ARMIR::BlockCache block_cache;
    std::unique_ptr<ARMul_State> state;
    std::shared_ptr<Memory::PageTable> current_page_table;
    Memory::PageTable* current_page_table_raw{};
    // Per-page-table tag folded into BlockKey so translated blocks from
    // different processes coexist instead of being cleared on every switch.
    u64 current_block_tag{};
    u64 current_fastmem_page_table_generation{};
    FastmemCacheEntry current_fastmem_last_cache{};
    FastmemCacheEntry current_fastmem_previous_cache{};
    std::array<FastmemCacheEntry, FastmemCacheSize> current_fastmem_cache{};
    LazyFlags lazy_flags;
    bool current_big_endian{};
    u64 current_fastmem_hits{};
    u64 current_fastmem_fallbacks{};
    u64 current_fastmem_page_cache_hits{};
    u64 current_fastmem_page_cache_misses{};
    u64 current_lazy_flag_writes{};
    u64 current_lazy_flag_materializations{};
    u64 ir_fallback_count{};
#if defined(__aarch64__)
    // Cross-block chain table for the AArch64 executor; entries point into
    // this interpreter's block cache, so the table lives and dies with it.
    ARMAsm::ChainTable asm_chain_table{};
    // Reentrancy guard for the asm-vs-C++ differential verify mode.
    bool asm_verify_active{};
#endif
    u32 current_fastmem_cache_generation{1};
};

// Total guest instructions retired by ExecuteIRInstructions across all IR
// cores (C++ ops and asm fast-path ops both count here). The OHOS runtime
// samples this to report real-game guest MIPS.
extern std::atomic<u64> g_ir_guest_instructions;
// Wall-clock nanoseconds spent inside ExecuteIRInstructions — the ARM
// interpreter's share of the emulation thread. Lets device benchmarks
// quantify how much of the frame time an interpreter optimization can
// actually move.
extern std::atomic<u64> g_ir_time_ns;
// Sub-decomposition of ExecuteIRInstructions wall time: time inside
// TryExecuteBlock calls, time inside SVC handling, and block count.
extern std::atomic<u64> g_ir_blk_exec_ns;
extern std::atomic<u64> g_ir_svc_ns;
extern std::atomic<u64> g_ir_svc_count;
extern std::atomic<u64> g_ir_block_count;
extern std::atomic<u64> g_ir_lookup_ns;
extern std::atomic<u64> g_ir_link_current;
extern std::atomic<u64> g_ir_link_last;
extern std::atomic<u64> g_ir_link_slot;
extern std::atomic<u64> g_ir_link_miss;
extern std::atomic<u64> g_ir_acquire;
extern std::atomic<u64> g_ir_translations;
extern std::atomic<u64> g_ir_cache_clears;
extern std::atomic<u64> g_ir_invalidate_calls;
extern std::atomic<u64> g_ir_invalidate_erased;
// Optional per-opcode execution histogram (TryExecuteBlock ProfileOpcodes
// path). Enabled via the `op_profile` config key; counts live in the
// interpreter thread and are read single-threaded for dumps.
extern bool g_ir_profile_opcodes;
// Gates the per-block clock/atomic instrumentation above. Enabled together
// with `op_profile`; when false the interpreter loop performs no steady_clock
// reads or profiling counter updates.
extern bool g_ir_profile_blocks;
extern std::array<u64, ARMIR::OpcodeCount> g_ir_opcode_counts;
extern std::array<u64, ARMIR::OpcodeCount> g_ir_opcode_ticks;

} // namespace Core
