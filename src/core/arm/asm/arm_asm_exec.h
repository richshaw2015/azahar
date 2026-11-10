// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#pragma once

#include <array>
#include <atomic>
#include <memory>
#include "common/common_types.h"
#include "core/arm/ir/arm_ir_cache.h"

namespace Core::ARMAsm {

// Execution context handed to citra_asm_run. All guest state is referenced
// by pointer so the assembly code reads/writes ARMul_State and LazyFlags in
// place -- no copies either direction. Field offsets are baked into the
// assembly (ASMCTX_* defines in arm_asm_layout.h); do not reorder.
struct ExecContext {
    u32* regs;                  // state->Reg.data()
    u32* flags4;                // &state->NFlag (N,Z,C,V consecutive u32)
    void* lazy;                 // &lazy_flags (ARM_IRInterpreter::LazyFlags)
    u8* const* pagetable;       // page_table->pointers.data()
    u32 guest_size;             // default guest instruction size (2 or 4)
    u32 pc;                     // in: starting pc / out: pc at exit
    u32 ops_executed;           // out: guest instructions consumed
    u32 exit_reason;            // out: ASM_EXIT_*
    u32 exit_index;             // out: C++ op index for ASM_EXIT_SLOW
    u32 budget;                 // in: max guest instructions this run may consume
                                //     (enforced at chained block-boundary jumps)
    u32* extreg;                // state->ExtReg.data() (VFP register file)
    const void* chain;          // per-interpreter block-chain table, may be null
    u32 cpsr_key;               // BlockKey::cpsr_key of the block under execution
    u32 chain_hits;             // out: cross-block chains taken this run
    u32 chain_misses;           // out: chain lookups that fell back to C++
    u32* excl_tag;              // state->exclusive_tag (local monitor address)
    u8* excl_state;             // state->exclusive_state (monitor armed flag)
    u32 resmask;                // bitmask of guest regs held in resident host
                                // registers for this program (r0-r2 = 0x7, 0 = none)
    u32 miss_key;               // out: chain misses from pc/cpsr_key mismatch
    u32 miss_budget;            // out: chain misses refused by the budget check
    u32 miss_res;               // out: chain misses refused by resmask mismatch
    u32 miss_pckey;             // out: subset of miss_key where the pc matched
                                //     (same address, different cpsr_key/tag)
    u32* tflag;                 // &state->TFlag -- written by mode-switching
                                //     handlers (bx/blx/ldm-pc to a different
                                //     instruction set)
};
static_assert(sizeof(ExecContext) == 136);

enum class ExitReason : u32 {
    EndOfBlock = 0,
    SlowOp = 1,
};

// Settings::values.cpu_asm_mask bits -- runtime gates for bisecting handler
// families against real workloads. A cleared bit keeps that family on the
// C++ slow path. Default ~0u enables everything.
enum : u32 {
    kAsmMaskChain = 1u << 0,       // cross-block chain table
    kAsmMaskCondBranch = 1u << 1,  // bra_*/brachain_* conditional ArmBranch
    kAsmMaskLinkBranch = 1u << 2,  // bl/bx/blx records
    kAsmMaskFusedBranch = 1u << 3, // fused compare/test + conditional branch
    kAsmMaskGuard = 1u << 4,       // guard+body records for predicated ops
    kAsmMaskMemPc = 1u << 5,       // literal-pool ldrw/strw_gen + ldm{...,pc}
    // Finer-grained guard sub-families for bisection.
    kAsmMaskGuardDpReg = 1u << 6,  // ArmDataProcessingRegister
    kAsmMaskGuardDpImm = 1u << 7,  // ArmDataProcessingImmediate
    kAsmMaskGuardMul = 1u << 8,    // ArmMultiply / ArmMultiplyLong
    kAsmMaskGuardLdSt = 1u << 9,   // ArmLoadStoreImmediate / ArmLoadStoreMultiple
    // Finer-grained link-branch sub-families for bisection (bit2 must also
    // be set for these to take effect).
    kAsmMaskLinkBl = 1u << 10,     // ArmBranch with link bit (bl)
    kAsmMaskLinkBx = 1u << 11,     // ArmBranchExchange[Always] (bx reg)
    kAsmMaskLinkBlx = 1u << 12,    // ArmBranchLinkExchange[RegisterAlways] (blx reg)
    kAsmMaskVfpDp = 1u << 13,      // ArmVFPDataProcessing[Always] host-FP subset
    kAsmMaskLogicFlag = 1u << 14,  // standalone tst/teq immediate flag ops
    // System-register transfers: MRS (cpsr/spsr), vmrs apsr_nzcv,fpscr /
    // conditional VFP system-register forms, and the unprivileged CP15
    // thread-register MRC reads.
    kAsmMaskSysReg = 1u << 15,
    // Word-size LDREX/STREX (the ldrex/strex spin-lock fast path).
    kAsmMaskExclusive = 1u << 16,
    // Shifted-operand flag writers: MOVS imm-shift (op92), logical ops with
    // register-amount shift + flags (op207), ADC/SBC/RSC/RSB imm-shift (op198).
    kAsmMaskShiftFlags = 1u << 17,
    // Fused set-flags + conditional branch ops beyond cmp/tst (op218 adds/
    // subs-imm+branch, op223 logic-reg+branch).
    kAsmMaskAluBranch = 1u << 18,
    // Thumb bl prefix/suffix pair (ThumbBranchLinkSetup + ThumbBranchLink).
    // The suffix is a block terminator and stays in Thumb state, so it can
    // hand straight to the end record's chain probe.
    kAsmMaskThumbLink = 1u << 19,
    // Guest r0-r2 residency in host registers for proven-safe programs.
    kAsmMaskResident = 1u << 20,
};

// Translates an IR block into a threaded-code program. Ops the v1 handler
// set cannot execute become ASM_EXIT_SLOW records; branch targets resolve
// to the terminator so the caller re-enters the block cache (identical to
// the switch interpreter's per-block flow).
std::shared_ptr<ARMIR::AsmProgram> BuildProgram(const ARMIR::Block& block);

// Lightweight counters for tests/benchmarks to prove the assembly path was
// actually taken (as opposed to every op exiting slow).
struct Stats {
    std::atomic<u64> programs_built{0};
    // Programs built with the guest r0-r2 resident-register mask.
    std::atomic<u64> resident_programs{0};
    std::atomic<u64> runs{0};
    std::atomic<u64> ops_executed{0};
    std::atomic<u64> slow_exits{0};
    std::atomic<u64> chain_hits{0};
    std::atomic<u64> chain_misses{0};
    // Chain-miss reason split: table slot key mismatch (cold or evicted),
    // run-budget refusal, and resident-register mask mismatch.
    std::atomic<u64> miss_key{0};
    std::atomic<u64> miss_budget{0};
    std::atomic<u64> miss_res{0};
    // Subset of miss_key where the table entry's pc matched but cpsr_key
    // differed (Thumb/ARM or page-table-tag variants of the same address).
    std::atomic<u64> miss_pckey{0};
    // Registrations that overwrote a live entry with a different pc
    // (direct-mapped hash collisions). Compare against miss_key to tell
    // collision misses from cold-start misses.
    std::atomic<u64> chain_evictions{0};
    // Block entries refused because the block's record stream kept
    // slow-exiting within the first few instructions (Block::asm_bad_runs).
    std::atomic<u64> skipped_runs{0};
    // Per-opcode count of ASM_EXIT_SLOW exits (index = ARMIR::Opcode value).
    // Identifies which unsupported ops dominate run truncation on real loads.
    std::array<std::atomic<u64>, 512> slow_op_counts;
    // Diagnostics for slow-exit debugging: the raw guest instruction word of
    // the most recently slow-exited VFP data-processing op (arg1 for that
    // opcode family is the encoded instruction).
    std::atomic<u64> slow_vfpdp_inst{0};
    // Packed (start_pc << 32) | arg2 of the last vfpdp slow exit.
    std::atomic<u64> slow_vfpdp_arg0{0};
    // Packed (opcode << 40) | (guest_size << 32) | exit_index.
    std::atomic<u64> slow_vfpdp_meta{0};
    // cpu_asm_verify diagnostics: runs replayed by the C++ engine, how many
    // diverged in registers/CPSR, how many could not be replayed fully
    // (fallback/stop before covering the span), and details of the first
    // divergence (block pc, field id, asm/cpp values).
    std::atomic<u64> verify_runs{0};
    std::atomic<u64> verify_mismatches{0};
    std::atomic<u64> verify_truncated{0};
    // Runs skipped because the span is not airtight-verifiable (asm store
    // present or chained beyond the entry block).
    std::atomic<u64> verify_skipped{0};
    std::atomic<u32> verify_first_pc{0};
    std::atomic<u32> verify_first_key{0};
    std::atomic<u32> verify_first_field{0};
    std::atomic<u32> verify_first_asm{0};
    std::atomic<u32> verify_first_cpp{0};
    // Debug-only ring of block op dumps for the most recent mismatches.
    // Plain array (not atomic); only written by the emu thread in verify mode
    // and read by the stats dumper — worst case is a torn print.
    char verify_dumps[4][768]{};
    // Composition histogram for ArmDataProcessingRegister(Always) slow exits:
    // bucket = (rn==15) | (rm==15)<<1 | set_flags<<2 | reg_shift<<3.
    std::array<std::atomic<u64>, 16> slow_dp_reg;
    // Composition histogram for ArmLoadStoreRegister slow exits:
    // 0 unprivileged | 1 writeback | 2 rd==15 | 3 rn==15 | 4 rm==15 |
    // 5 zero-amount lsr/asr/ror shift form.
    std::array<std::atomic<u64>, 8> slow_lsx_reason;
    // Composition histogram for ArmVFPLoadStore slow exits:
    // 0 rn==15 non-literal form | 1 multiple with bad/overflowing byte count
    // | 2 double-transfer ext_reg overflow | 3 cond/mask reject.
    std::array<std::atomic<u64>, 8> slow_vls_reason;
    // Last-slow dump for ArmMultiply residual analysis: same packing as the
    // vfpdp probe (inst = arg0<<32|arg1, arg0 = start_pc<<32|arg2,
    // meta = opcode<<40 | guest_size<<32 | exit_index).
    std::atomic<u64> slow_probe_inst{0};
    std::atomic<u64> slow_probe_arg0{0};
    std::atomic<u64> slow_probe_meta{0};
    // Memory-op slow-exit probe: the live base-register value (Reg[rn]) of
    // the most recent memory-op bail, to classify the failing guest region.
    std::atomic<u64> slow_mem_rn{0};
    // Second word of the same probe: raw arg1 (packing varies per opcode).
    std::atomic<u64> slow_mem_a1{0};
};
inline Stats g_asm_stats;

// Cross-block chain table: direct-mapped map from BlockKey {pc, cpsr_key}
// to a translated program's record stream. The `end` record consults it on
// every block exit; hits stay in assembly, misses fall back to the C++
// block-cache loop. The table is owned per-interpreter (its entries point
// into that interpreter's block cache) and must be cleared whenever the
// block cache drops blocks so no stale code pointer survives.
// Layout fixed for the .S side: 32 bytes per entry, fields at offsets
// pc=0, cpsr_key=4, code=8, instrs=16, resmask=20 (see ASMCHAIN_* in
// arm_asm_layout.h).
// `instrs` is the block's guest_instruction_count: a chained block only
// executes whole, so the chain is refused when it would overshoot the
// run budget (matching ExecuteAsmPrefix's whole-block budget check).
// `resmask` lets a chain jump only into a program with the same resident
// register set -- a resident run keeps r0-r2 authoritative in host regs,
// so a non-resident stream would observe stale regfile slots.
struct ChainEntry {
    u32 pc{~0u};
    u32 cpsr_key{~0u};
    u64 code{};
    u32 instrs{};
    u32 resmask{};
    u64 pad1{};
};
static_assert(sizeof(ChainEntry) == 32);
constexpr u32 kChainTableBits = 15; // must match ASMCHAIN_BITS
constexpr std::size_t kChainTableSize = std::size_t{1} << kChainTableBits;
using ChainTable = std::array<ChainEntry, kChainTableSize>;

inline void RegisterChainEntry(ChainTable& table, u32 pc, u32 cpsr_key,
                               const ARMIR::AsmOp* code, u32 instrs, u32 resmask) {
    ChainEntry& e = table[(pc >> 2) & (kChainTableSize - 1)];
    if (e.pc != pc && e.pc != ~0u) {
        ++g_asm_stats.chain_evictions;
    }
    e.resmask = resmask;
    e.cpsr_key = cpsr_key;
    e.code = reinterpret_cast<u64>(code);
    e.instrs = instrs;
    e.pc = pc; // store pc last so a racing reader can't match a half entry
}

inline void ClearChainTable(ChainTable& table) {
    for (ChainEntry& e : table) {
        e.pc = ~0u;
        e.code = 0;
    }
}

} // namespace Core::ARMAsm

extern "C" u32 citra_asm_run(Core::ARMAsm::ExecContext* ctx, const Core::ARMIR::AsmOp* ip);
