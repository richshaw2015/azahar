// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

// AArch64 threaded executor for pre-decoded ARMIR ops.
//
// Model: each guest op is a 40-byte record { handler, a0, a1, a2, a3 }.
// citra_asm_run() dispatches records via an indirect branch at the end of
// each handler. Guest state lives in memory (ctx->regs points directly at
// ARMul_State::Reg), guest pc lives in w28, guest NZCV lives in the host
// NZCV flags (restored from lazy flags + state flags on entry, written back
// on exit). Ops that cannot be handled in assembly exit with
// ASM_EXIT_SLOW and are replayed by the C++ switch path.
//
// Register convention inside the executor:
//   x9   = instruction stream pointer (points just past current record)
//   x19  = ctx
//   w20  = guest instructions executed (low 32); bit 32 = flag-dirty
//   w21  = guest r0 (resident; regfile slot stale until exit)
//   w23  = last-page cache: guest page index of x27 (-1 = empty)
//   x24  = page_table->pointers base
//   x25  = guest register file base
//   w26  = guest r1 (resident)
//   x27  = last-page cache: host base pointer for page w23
//   w28  = guest pc
//   w18  = guest r2 (resident; platform register, free in userland)
//   The guest-instruction budget is reloaded from ctx at each chain check
//   (chained self-loop jumps exit at this count, matching the C++ per-block
//   `result.instructions` check).
//   x8, x10-x15, x16, x17 = scratch

#include "core/arm/asm/arm_asm_layout.h"

#define AR0 (ASMOP_A0 - ASMOP_SIZE)   // -32
#define AR1 (ASMOP_A1 - ASMOP_SIZE)   // -24
#define AR2 (ASMOP_A2 - ASMOP_SIZE)   // -16
#define AR3 (ASMOP_A3 - ASMOP_SIZE)   // -8

// Dispatch after an op that consumed one guest instruction. Per-op
// guest_size is carried in a3 (thumb-2 ops are 4 bytes inside thumb
// blocks), so the pc advance is not uniform across a program.
.macro NEXT_A
    add   x20, x20, #1
    ldr   w10, [x9, #AR3]
    add   w28, w28, w10
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.endm

// Dispatch without advancing pc or count (guard ops that pass through).
.macro NEXT_RAW
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.endm

// Jump to the shared slow-exit tail for this record's C++ op index.
// Mem handlers keep the index in a2.
// If this run already crossed a block boundary (chain_hits > 0), the slow
// record belongs to a *different* block than the one the C++ caller would
// resume. Fall back to ASM_EXIT_END instead: ctx.pc already points at the
// unexecuted op, so the block-cache loop re-dispatches from there exactly
// like a normal block exit.
.macro MEMSLOW
    ldr   w10, [x9, #AR2]
    str   w10, [x19, #ASMCTX_EXITINDEX]
    mov   w16, #ASM_EXIT_SLOW
    ldr   w11, [x19, #ASMCTX_CHAINHITS]
    cbz   w11, 1f
    mov   w16, #ASM_EXIT_END
1:  b     .Lasm_done
.endm

    .text
    .p2align 4
    .globl  citra_asm_run
    .type   citra_asm_run, %function
citra_asm_run:
    sub   sp, sp, #128
    stp   x29, x30, [sp]
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    stp   x21, x22, [sp, #32]
    stp   x23, x24, [sp, #48]
    stp   x25, x26, [sp, #64]
    stp   x27, x28, [sp, #80]
    str   x18, [sp, #96]           // platform register; resident runs clobber it

    mov   x19, x0
    mov   x9, x1
    mov   w20, #0                  // low 32 = count, bit 32 = flag-dirty
    // Last-page cache starts empty; an impossible page index forces the
    // first memory access down the miss path, which fills {w23,x27}. The
    // entry lives only inside this run, so page-table changes made by C++
    // code between runs can never leave a stale host pointer behind.
    mov   w23, #-1
    ldr   w28, [x19, #ASMCTX_PC]
    ldr   x24, [x19, #ASMCTX_PAGETBL]
    ldr   x25, [x19, #ASMCTX_REGS]
    ldr   x16, [x19, #ASMCTX_FLAGS4]
    ldr   x27, [x19, #ASMCTX_LAZY]
    ldr   x22, [x19, #ASMCTX_EXTREG]

    // Guest r0-r2 are register-resident only when ctx->resmask says so (the
    // translator only sets it for programs where every record is provably
    // safe against the stale regfile slots; resident runs materialize the
    // regs back on every exit).
    ldr   w10, [x19, #ASMCTX_RESMASK]
    tbz   w10, #0, 0f
    ldr   w21, [x25]               // r0 -> w21
0:  tbz   w10, #1, 1f
    ldr   w26, [x25, #4]           // r1 -> w26
1:  tbz   w10, #2, 2f
    ldr   w18, [x25, #8]           // r2 -> w18
2:

    // Pin the host FP environment to FPCR=0 (round-to-nearest, no FZ/DN/AHP,
    // no traps) for the duration of the run. The vfpdp handler only fast-
    // paths guest ops whose FPSCR rounding mode is RN and whose operands
    // are normal-or-zero, so this fixed environment reproduces the guest
    // behaviour exactly. The caller's FPCR is restored on every exit path.
    mrs   x10, fpcr
    str   x10, [sp, #104]
    msr   fpcr, xzr

    // Restore guest NZCV: prefer lazy fields selected by valid+mask, else
    // the materialized state->N/Z/C/VFlag fields.
    ldrb  w10, [x27, #ASMLAZY_VALID]
    ldrb  w11, [x27, #ASMLAZY_MASK]
    ldp   w12, w13, [x16]        // state N, Z
    ldp   w14, w15, [x16, #8]    // state C, V
    cbz   w10, 1f
    tbz   w11, #0, 2f
    ldr   w12, [x27, #ASMLAZY_N]
2:  tbz   w11, #1, 3f
    ldr   w13, [x27, #ASMLAZY_Z]
3:  tbz   w11, #2, 4f
    ldr   w14, [x27, #ASMLAZY_C]
4:  tbz   w11, #3, 5f
    ldr   w15, [x27, #ASMLAZY_V]
5:
1:  lsl   w12, w12, #31
    bfi   w12, w13, #30, #1
    bfi   w12, w14, #29, #1
    bfi   w12, w15, #28, #1
    msr   nzcv, x12

    ldr   x8, [x9], #ASMOP_SIZE
    br    x8

// ---------------------------------------------------------------------------
// Shared exit tail. Inputs: w16 = exit reason. Everything is materialized
// back through ctx before returning to C++.
// ---------------------------------------------------------------------------
.Lasm_done:
    ldr   w10, [x19, #ASMCTX_RESMASK]
    tbz   w10, #0, 0f
    str   w21, [x25]               // materialize resident r0
0:  tbz   w10, #1, 1f
    str   w26, [x25, #4]           // materialize resident r1
1:  tbz   w10, #2, 2f
    str   w18, [x25, #8]           // materialize resident r2
2:  str   w28, [x19, #ASMCTX_PC]
    str   w20, [x19, #ASMCTX_OPSEXEC]
    str   w16, [x19, #ASMCTX_EXITREASON]
    tbz   x20, #32, 1f
    ldr   x27, [x19, #ASMCTX_LAZY]
    mrs   x10, nzcv
    mov   w11, #1
    strb  w11, [x27, #ASMLAZY_VALID]
    ldrb  w12, [x27, #ASMLAZY_MASK]
    orr   w12, w12, #0xF
    strb  w12, [x27, #ASMLAZY_MASK]
    ubfx  w13, w10, #31, #1
    str   w13, [x27, #ASMLAZY_N]
    ubfx  w13, w10, #30, #1
    str   w13, [x27, #ASMLAZY_Z]
    ubfx  w13, w10, #29, #1
    str   w13, [x27, #ASMLAZY_C]
    ubfx  w13, w10, #28, #1
    str   w13, [x27, #ASMLAZY_V]
1:
    ldr   x10, [sp, #104]
    msr   fpcr, x10                // restore the caller's FP environment
    msr   fpsr, xzr                // leave no stale exception bits behind
    mov   w0, w16
    ldp   x29, x30, [sp]
    ldp   x19, x20, [sp, #16]
    ldp   x21, x22, [sp, #32]
    ldp   x23, x24, [sp, #48]
    ldp   x25, x26, [sp, #64]
    ldp   x27, x28, [sp, #80]
    ldr   x18, [sp, #96]
    add   sp, sp, #128
    ret
    .size citra_asm_run, . - citra_asm_run

// ---------------------------------------------------------------------------
// Control records
// ---------------------------------------------------------------------------
    .globl citra_asm_op_end
citra_asm_op_end:
    // Cross-block chaining: w28 already holds the next guest pc (set by the
    // terminating branch, or advanced past the last op for fall-through).
    // Hash it into the chain table; a hit jumps straight to that block's
    // record stream with all context registers still resident, skipping
    // the C++ block-cache round trip entirely.
    //
    // NZCV holds the guest flags, so the compares here run under a saved
    // copy: otherwise the flag writeback in .Lasm_done would store the
    // table-compare flags instead of the guest's.
    mrs   x16, nzcv
    ldr   x10, [x19, #ASMCTX_CHAIN]
    cbz   x10, 3f
    ubfx  w11, w28, #2, #ASMCHAIN_BITS
    add   x10, x10, x11, lsl #ASMCHAIN_SHIFT
    ldr   w12, [x19, #ASMCTX_CPSRKEY]
    ldp   w13, w14, [x10, #ASMCHAIN_PC]
    ldr   x15, [x10, #ASMCHAIN_CODE]
    cmp   w13, w28
    ccmp  w14, w12, #0, eq         // pc and cpsr_key must both match
    b.ne  .Lcm_key0
    ldr   w14, [x10, #ASMCHAIN_INSTRS]
    add   w14, w20, w14
    ldr   w17, [x19, #ASMCTX_BUDGET]
    cmp   w14, w17
    b.hi  .Lcm_bud0                // target block would overshoot the budget
    // Resident-register runs may only chain into programs holding the same
    // guest regs in host regs; a non-resident stream would read stale
    // regfile slots for r0-r2. A differing mask no longer forces a C++
    // round-trip: sync the differing r0-r2 slots in place (load on adopt,
    // store on release), adopt the target mask, and chain anyway.
    ldr   w14, [x10, #ASMCHAIN_RES]
    ldr   w17, [x19, #ASMCTX_RESMASK]
    cmp   w14, w17
    b.ne  .Lcm_rsync0
.Lcm_hit0:
    ldr   w10, [x19, #ASMCTX_CHAINHITS]
    add   w10, w10, #1
    str   w10, [x19, #ASMCTX_CHAINHITS]
    msr   nzcv, x16                // restore guest flags for the next block
    mov   x9, x15
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.Lcm_key0:
    ldr   w10, [x19, #ASMCTX_MISSKEY]
    add   w10, w10, #1
    str   w10, [x19, #ASMCTX_MISSKEY]
    cmp   w13, w28
    b.ne  2f                        // pc absent: cold entry or eviction
    ldr   w10, [x19, #ASMCTX_MISSPCKEY]
    add   w10, w10, #1
    str   w10, [x19, #ASMCTX_MISSPCKEY]  // same pc, different cpsr_key
    b     2f
.Lcm_bud0:
    ldr   w10, [x19, #ASMCTX_MISSBUDGET]
    add   w10, w10, #1
    str   w10, [x19, #ASMCTX_MISSBUDGET]
    b     2f
.Lcm_rsync0:
    eor   w11, w14, w17            // residency bits that differ
    tbz   w11, #0, .Lcm_r0d0
    tbz   w14, #0, .Lcm_r0s0
    ldr   w21, [x25]               // adopt r0 into host reg
    b     .Lcm_r0d0
.Lcm_r0s0:
    str   w21, [x25]               // release r0 to the regfile
.Lcm_r0d0:
    tbz   w11, #1, .Lcm_r0d1
    tbz   w14, #1, .Lcm_r0s1
    ldr   w26, [x25, #4]           // adopt r1
    b     .Lcm_r0d1
.Lcm_r0s1:
    str   w26, [x25, #4]           // release r1
.Lcm_r0d1:
    tbz   w11, #2, .Lcm_r0d2
    tbz   w14, #2, .Lcm_r0s2
    ldr   w18, [x25, #8]           // adopt r2
    b     .Lcm_r0d2
.Lcm_r0s2:
    str   w18, [x25, #8]           // release r2
.Lcm_r0d2:
    str   w14, [x19, #ASMCTX_RESMASK]
    ldr   w10, [x19, #ASMCTX_MISSRES]
    add   w10, w10, #1
    str   w10, [x19, #ASMCTX_MISSRES]  // count resyncs performed
    b     .Lcm_hit0
2:  ldr   w10, [x19, #ASMCTX_CHAINMISS]
    add   w10, w10, #1
    str   w10, [x19, #ASMCTX_CHAINMISS]
3:  msr   nzcv, x16                // restore guest flags for the writeback
    mov   w16, #ASM_EXIT_END
    b     .Lasm_done

    .globl citra_asm_op_slow
citra_asm_op_slow:
    // Same chained-block hazard as MEMSLOW: after a cross-block jump the
    // exit index names an op in the chained block, not the entry block the
    // C++ loop is iterating. Report END and let it resume at ctx.pc.
    ldr   w10, [x9, #AR0]
    str   w10, [x19, #ASMCTX_EXITINDEX]
    mov   w16, #ASM_EXIT_SLOW
    ldr   w11, [x19, #ASMCTX_CHAINHITS]
    cbz   w11, 1f
    mov   w16, #ASM_EXIT_END
1:  b     .Lasm_done

    .globl citra_asm_op_nop
citra_asm_op_nop:
    NEXT_A

// ---------------------------------------------------------------------------
// Data-processing write to pc (rd==15, no flag update): mov pc, lr and the
// other result->pc forms. The result is stored raw to Reg[15] (the IR keeps
// the unmasked value and masks it at dispatch); the chain-table probe uses
// pc & ~3 because ARM execution addresses are word-aligned. rn/rm==15 read a
// compile-time pc constant in a1 instead of the stale Reg[15] slot.
// a0 = data_opcode | rn<<4 | rm<<8 | shift_type<<12 | shift_imm<<14
// a1 = pc operand constant (op_pc + 8), used when rn==15 or rm==15
// a2 = C++ op index for MEMSLOW
// ---------------------------------------------------------------------------
    .globl citra_asm_op_dp_pc
citra_asm_op_dp_pc:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4              // rm index
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w17, w10, #8, #4
    sub   w17, w17, #15                 // rm==15 -> literal pc operand
    cbnz  w17, 1f
    mov   w12, w11
1:  ubfx  w14, w10, #14, #5             // shift_imm
    ubfx  w13, w10, #12, #2             // shift_type
    cbz   w14, .Ldpc_simm0
    and   w15, w13, #2
    cbnz  w15, 2f                       // asr/ror
    tbz   w13, #0, 3f                   // lsl
    lsr   w16, w12, w14                 // lsr #n
    b     .Ldpc_rn
2:  tbz   w13, #0, 4f
    ror   w16, w12, w14                 // ror #n
    b     .Ldpc_rn
4:  asr   w16, w12, w14                 // asr #n
    b     .Ldpc_rn
3:  lsl   w16, w12, w14
    b     .Ldpc_rn
.Ldpc_simm0:
    // shift_imm==0: lsl is identity, lsr/asr mean #32; rrx needs carry -- slow.
    cbz   w13, .Ldpc_pass
    sub   w15, w13, #3                  // flag-free dispatch: no host NZCV write
    cbz   w15, .Ldpc_slow               // ror#0 -> rrx (carry): keep on C++ path
    and   w15, w13, #2
    cbz   w15, 5f
    asr   w16, w12, #31                 // asr #0 -> all sign bits
    b     .Ldpc_rn
5:  mov   w16, wzr                      // lsr #0 -> zero
    b     .Ldpc_rn
.Ldpc_pass:
    mov   w16, w12
.Ldpc_rn:
    ubfx  w13, w10, #4, #4              // rn index
    ldr   w14, [x25, w13, uxtw #2]
    sub   w15, w13, #15                 // rn==15 -> literal pc operand
    cbnz  w15, 1f
    mov   w14, w11
1:  and   w15, w10, #0xF                // data_opcode
    tbz   w15, #3, .Ldpc_lo             // opcodes 8-15 write rd or are tests
    tbz   w15, #2, .Ldpc_slow           // tst/teq/cmp/cmn never write pc
    tbz   w15, #1, 2f                   // orr/mov
    tbz   w15, #0, 3f
    mvn   w28, w16                      // mvn pc, op2
    b     .Ldpc_done
3:  bic   w28, w14, w16                 // bic pc, rn, op2
    b     .Ldpc_done
2:  tbz   w15, #0, 4f
    mov   w28, w16                      // mov pc, op2  (the common return)
    b     .Ldpc_done
4:  orr   w28, w14, w16                 // orr pc, rn, op2
    b     .Ldpc_done
.Ldpc_lo:                               // opcodes 0-7
    tbz   w15, #2, .Ldpc_l0             // and/eor/sub/rsb
    tbz   w15, #1, 5f                   // add/adc
    tbz   w15, #0, 6f
    // rsc pc, rn, op2 = op2 - rn + C - 1
    mrs   x17, nzcv
    ubfx  w17, w17, #29, #1
    sub   w28, w16, w14
    add   w28, w28, w17
    sub   w28, w28, #1
    b     .Ldpc_done
6:  // sbc pc, rn, op2 = rn - op2 + C - 1
    mrs   x17, nzcv
    ubfx  w17, w17, #29, #1
    sub   w28, w14, w16
    add   w28, w28, w17
    sub   w28, w28, #1
    b     .Ldpc_done
5:  tbz   w15, #0, 6f
    // adc pc, rn, op2 = rn + op2 + C
    mrs   x17, nzcv
    ubfx  w17, w17, #29, #1
    add   w28, w14, w16
    add   w28, w28, w17
    b     .Ldpc_done
6:  add   w28, w14, w16                 // add pc, rn, op2
    b     .Ldpc_done
.Ldpc_l0:                               // and/eor/sub/rsb
    tbz   w15, #1, 7f
    tbz   w15, #0, 8f
    sub   w28, w16, w14                 // rsb pc, rn, op2 = op2 - rn
    b     .Ldpc_done
8:  sub   w28, w14, w16                 // sub pc, rn, op2
    b     .Ldpc_done
7:  tbz   w15, #0, 8f
    eor   w28, w14, w16
    b     .Ldpc_done
8:  and   w28, w14, w16
.Ldpc_done:
    str   w28, [x25, #60]               // Reg[15] = raw result
    add   x20, x20, #1
    // Chain-table probe on the execution pc (ARM: & ~3). Same lookup the
    // `end` record runs, except the hash key is masked before use.
    bic   w17, w28, #3
    mrs   x16, nzcv
    ldr   x10, [x19, #ASMCTX_CHAIN]
    cbz   x10, 3f
    ubfx  w11, w17, #2, #ASMCHAIN_BITS
    add   x10, x10, x11, lsl #ASMCHAIN_SHIFT
    ldr   w12, [x19, #ASMCTX_CPSRKEY]
    ldp   w13, w14, [x10, #ASMCHAIN_PC]
    ldr   x15, [x10, #ASMCHAIN_CODE]
    cmp   w13, w17
    ccmp  w14, w12, #0, eq
    b.ne  .Lcm_key1
    ldr   w14, [x10, #ASMCHAIN_INSTRS]
    add   w14, w20, w14
    ldr   w17, [x19, #ASMCTX_BUDGET]
    cmp   w14, w17
    b.hi  .Lcm_bud1                         // target block would overshoot budget
    ldr   w14, [x10, #ASMCHAIN_RES]
    ldr   w17, [x19, #ASMCTX_RESMASK]
    cmp   w14, w17
    b.ne  .Lcm_rsync1                       // resync r0-r2 slots in place
.Lcm_hit1:
    ldr   w10, [x19, #ASMCTX_CHAINHITS]
    add   w10, w10, #1
    str   w10, [x19, #ASMCTX_CHAINHITS]
    msr   nzcv, x16
    mov   x9, x15
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.Lcm_key1:
    ldr   w10, [x19, #ASMCTX_MISSKEY]
    add   w10, w10, #1
    str   w10, [x19, #ASMCTX_MISSKEY]
    cmp   w13, w17
    b.ne  2f                        // pc absent: cold entry or eviction
    ldr   w10, [x19, #ASMCTX_MISSPCKEY]
    add   w10, w10, #1
    str   w10, [x19, #ASMCTX_MISSPCKEY]  // same pc, different cpsr_key
    b     2f
.Lcm_bud1:
    ldr   w10, [x19, #ASMCTX_MISSBUDGET]
    add   w10, w10, #1
    str   w10, [x19, #ASMCTX_MISSBUDGET]
    b     2f
.Lcm_rsync1:
    eor   w11, w14, w17
    tbz   w11, #0, .Lcm_r1d0
    tbz   w14, #0, .Lcm_r1s0
    ldr   w21, [x25]
    b     .Lcm_r1d0
.Lcm_r1s0:
    str   w21, [x25]
.Lcm_r1d0:
    tbz   w11, #1, .Lcm_r1d1
    tbz   w14, #1, .Lcm_r1s1
    ldr   w26, [x25, #4]
    b     .Lcm_r1d1
.Lcm_r1s1:
    str   w26, [x25, #4]
.Lcm_r1d1:
    tbz   w11, #2, .Lcm_r1d2
    tbz   w14, #2, .Lcm_r1s2
    ldr   w18, [x25, #8]
    b     .Lcm_r1d2
.Lcm_r1s2:
    str   w18, [x25, #8]
.Lcm_r1d2:
    str   w14, [x19, #ASMCTX_RESMASK]
    ldr   w10, [x19, #ASMCTX_MISSRES]
    add   w10, w10, #1
    str   w10, [x19, #ASMCTX_MISSRES]
    b     .Lcm_hit1
2:  ldr   w10, [x19, #ASMCTX_CHAINMISS]
    add   w10, w10, #1
    str   w10, [x19, #ASMCTX_CHAINMISS]
3:  msr   nzcv, x16
    mov   w16, #ASM_EXIT_END
    b     .Lasm_done
.Ldpc_slow:
    MEMSLOW

// ---------------------------------------------------------------------------
// Move ops (non-flag variants)
// ---------------------------------------------------------------------------
    .globl citra_asm_op_mov_imm
citra_asm_op_mov_imm:               // a0 = rd, a1 = imm
    ldp   x10, x11, [x9, #AR0]
    and   w10, w10, #0xF
    str   w11, [x25, w10, uxtw #2]
    NEXT_A

    .globl citra_asm_op_mov_reg
citra_asm_op_mov_reg:               // a0 = rd | rm<<8
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #8, #4
    ldr   w11, [x25, w11, uxtw #2]
    and   w10, w10, #0xF
    str   w11, [x25, w10, uxtw #2]
    NEXT_A

    .globl citra_asm_op_mvn_reg
citra_asm_op_mvn_reg:               // a0 = rd | rm<<8
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #8, #4
    ldr   w11, [x25, w11, uxtw #2]
    mvn   w11, w11
    and   w10, w10, #0xF
    str   w11, [x25, w10, uxtw #2]
    NEXT_A

    .globl citra_asm_op_mvn_imm
citra_asm_op_mvn_imm:               // a0 = rd, a1 = imm
    ldp   x10, x11, [x9, #AR0]
    mvn   w11, w11
    and   w10, w10, #0xF
    str   w11, [x25, w10, uxtw #2]
    NEXT_A

// ---------------------------------------------------------------------------
// ALU immediate (non-flag): rd = rn OP imm
// ---------------------------------------------------------------------------
.macro ALU_IMM name, insn
    .globl citra_asm_op_\name
citra_asm_op_\name:                 // a0 = rd|rn<<8, a1 = imm
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    \insn w12, w12, w11
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A
.endm

ALU_IMM add_imm,  add
ALU_IMM sub_imm,  sub
ALU_IMM and_imm,  and
ALU_IMM eor_imm,  eor
ALU_IMM orr_imm,  orr
ALU_IMM bic_imm,  bic

// Carry-reading immediate ALU (non-flag): host C == guest C.
.macro ALUC_IMM name, insn
    .globl citra_asm_op_\name
citra_asm_op_\name:                 // a0 = rd|rn<<8, a1 = imm
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    \insn w12, w12, w11
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A
.endm

ALUC_IMM adc_imm, adc
ALUC_IMM sbc_imm, sbc

    .globl citra_asm_op_rsc_imm
citra_asm_op_rsc_imm:               // a0 = rd|rn<<8, a1 = imm ; rd = imm - rn - !C
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    sbc   w12, w11, w12
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A

    .globl citra_asm_op_rsb_imm
citra_asm_op_rsb_imm:               // a0 = rd|rn<<8, a1 = imm ; rd = imm - rn
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    sub   w12, w11, w12
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A

// ---------------------------------------------------------------------------
// ALU register (non-flag): rd = rn OP rm
// ---------------------------------------------------------------------------
.macro ALU_REG name, insn
    .globl citra_asm_op_\name
citra_asm_op_\name:                 // a0 = rd|rn<<8|rm<<16
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    \insn w12, w12, w13
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A
.endm

ALU_REG add_reg, add
ALU_REG sub_reg, sub
ALU_REG and_reg, and
ALU_REG eor_reg, eor
ALU_REG orr_reg, orr
ALU_REG bic_reg, bic
ALU_REG adc_reg, adc   // native C == guest C
ALU_REG sbc_reg, sbc

    .globl citra_asm_op_rsb_reg
citra_asm_op_rsb_reg:               // a0 = rd|rn<<8|rm<<16 ; rd = rm - rn
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    sub   w12, w13, w12
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A

    .globl citra_asm_op_rsc_reg
citra_asm_op_rsc_reg:               // rd = rm - rn - !C
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    sbc   w12, w13, w12
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A

// ---------------------------------------------------------------------------
// ALU flag-setting variants: adds/subs write host NZCV == guest flags.
// ---------------------------------------------------------------------------
.macro ALUF_IMM name, insn
    .globl citra_asm_op_\name
citra_asm_op_\name:                 // a0 = rd|rn<<8, a1 = imm
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    \insn w12, w12, w11
    orr   x20, x20, #0x100000000
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A
.endm

ALUF_IMM adds_imm, adds
ALUF_IMM subs_imm, subs
ALUF_IMM adcs_imm, adcs
ALUF_IMM sbcs_imm, sbcs

// Reversed-immediate flag ops: result = imm - rn [- !C]. The guest operand
// order is flipped versus ALUF_IMM, so the host subtracts rn from imm.
.macro ALUF_RIMM name, insn
    .globl citra_asm_op_\name
citra_asm_op_\name:                 // a0 = rd|rn<<8, a1 = imm
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    \insn w12, w11, w12
    orr   x20, x20, #0x100000000
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A
.endm

ALUF_RIMM rsbs_imm, subs
ALUF_RIMM rscs_imm, sbcs

.macro ALUF_REG name, insn
    .globl citra_asm_op_\name
citra_asm_op_\name:                 // a0 = rd|rn<<8|rm<<16
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    \insn w12, w12, w13
    orr   x20, x20, #0x100000000
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A
.endm

ALUF_REG adds_reg, adds
ALUF_REG subs_reg, subs

// ---------------------------------------------------------------------------
// Compare ops: set guest NZCV via host subs/adds, discard result.
// ---------------------------------------------------------------------------
.macro CMP_IMM name, insn
    .globl citra_asm_op_\name
citra_asm_op_\name:                 // a0 = rn, a1 = imm
    ldp   x10, x11, [x9, #AR0]
    and   w10, w10, #0xF
    ldr   w10, [x25, w10, uxtw #2]
    \insn wzr, w10, w11
    orr   x20, x20, #0x100000000
    NEXT_A
.endm

CMP_IMM cmp_imm, subs
CMP_IMM cmn_imm, adds

.macro CMP_REG name, insn
    .globl citra_asm_op_\name
citra_asm_op_\name:                 // a0 = rn|rm<<8
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #8, #4
    ldr   w11, [x25, w11, uxtw #2]
    and   w10, w10, #0xF
    ldr   w10, [x25, w10, uxtw #2]
    \insn wzr, w10, w11
    orr   x20, x20, #0x100000000
    NEXT_A
.endm

CMP_REG cmp_reg, subs
CMP_REG cmn_reg, adds

// ---------------------------------------------------------------------------
// MOV with immediate shifter: rd = rm SHIFT #amount (non-flag).
// amount==32 semantics for lsr/asr and rrx are separate handlers; the
// translator emits them when the encoded amount is 0 for those types.
// ---------------------------------------------------------------------------
.macro MOV_SHIFT name, insn
    .globl citra_asm_op_\name
citra_asm_op_\name:                 // a0 = rd|rm<<8|amount<<16
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #8, #4
    ldr   w11, [x25, w11, uxtw #2]
    ubfx  w12, w10, #16, #6
    \insn w11, w11, w12
    and   w10, w10, #0xF
    str   w11, [x25, w10, uxtw #2]
    NEXT_A
.endm

MOV_SHIFT mov_lsl, lsl
MOV_SHIFT mov_lsr, lsr
MOV_SHIFT mov_asr, asr
MOV_SHIFT mov_ror, ror

    .globl citra_asm_op_mov_lsr32
citra_asm_op_mov_lsr32:             // rd = 0
    ldr   w10, [x9, #AR0]
    and   w10, w10, #0xF
    str   wzr, [x25, w10, uxtw #2]
    NEXT_A

    .globl citra_asm_op_mov_asr32
citra_asm_op_mov_asr32:             // rd = sign-fill
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #8, #4
    ldr   w11, [x25, w11, uxtw #2]
    asr   w11, w11, #31
    and   w10, w10, #0xF
    str   w11, [x25, w10, uxtw #2]
    NEXT_A

    .globl citra_asm_op_mov_rrx
citra_asm_op_mov_rrx:               // rd = (C << 31) | rm >> 1, flags preserved
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #8, #4
    ldr   w11, [x25, w11, uxtw #2]
    cset  w13, cs
    extr  w11, w13, w11, #1
    and   w10, w10, #0xF
    str   w11, [x25, w10, uxtw #2]
    NEXT_A

// ---------------------------------------------------------------------------
// ALU with register operand shifted by immediate (non-flag):
// rd = rn OP (rm SHIFT #amount). lsr/asr/ror amount==0 encodings and rrx
// are handled by the translator as slow ops.
// ---------------------------------------------------------------------------
.macro ALU_SHIFT name, insn, shift
    .globl citra_asm_op_\name
citra_asm_op_\name:                 // a0 = rd|rn<<8|rm<<16|amount<<24
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    ubfx  w14, w10, #24, #5
    \shift w13, w13, w14
    \insn w12, w12, w13
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A
.endm

ALU_SHIFT add_shift_lsl, add, lsl
ALU_SHIFT add_shift_lsr, add, lsr
ALU_SHIFT add_shift_asr, add, asr
ALU_SHIFT add_shift_ror, add, ror
ALU_SHIFT sub_shift_lsl, sub, lsl
ALU_SHIFT sub_shift_lsr, sub, lsr
ALU_SHIFT sub_shift_asr, sub, asr
ALU_SHIFT sub_shift_ror, sub, ror
ALU_SHIFT and_shift_lsl, and, lsl
ALU_SHIFT and_shift_lsr, and, lsr
ALU_SHIFT and_shift_asr, and, asr
ALU_SHIFT and_shift_ror, and, ror
ALU_SHIFT eor_shift_lsl, eor, lsl
ALU_SHIFT eor_shift_lsr, eor, lsr
ALU_SHIFT eor_shift_asr, eor, asr
ALU_SHIFT eor_shift_ror, eor, ror
ALU_SHIFT orr_shift_lsl, orr, lsl
ALU_SHIFT orr_shift_lsr, orr, lsr
ALU_SHIFT orr_shift_asr, orr, asr
ALU_SHIFT orr_shift_ror, orr, ror
ALU_SHIFT bic_shift_lsl, bic, lsl
ALU_SHIFT bic_shift_lsr, bic, lsr
ALU_SHIFT bic_shift_asr, bic, asr
ALU_SHIFT bic_shift_ror, bic, ror
// mov/mvn are two-operand forms; ALU_SHIFT's three-operand shape does not
// apply. a0 = rd|rn<<8|rm<<16|amount<<24 (rn ignored).
.macro MOVN_SHIFT name, insn, shift
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldr   w10, [x9, #AR0]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    ubfx  w14, w10, #24, #5
    \shift w13, w13, w14
    \insn w12, w13
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A
.endm

MOVN_SHIFT mov_shift_lsl, mov, lsl
MOVN_SHIFT mov_shift_lsr, mov, lsr
MOVN_SHIFT mov_shift_asr, mov, asr
MOVN_SHIFT mov_shift_ror, mov, ror
MOVN_SHIFT mvn_shift_lsl, mvn, lsl
MOVN_SHIFT mvn_shift_lsr, mvn, lsr
MOVN_SHIFT mvn_shift_asr, mvn, asr
MOVN_SHIFT mvn_shift_ror, mvn, ror

// ---------------------------------------------------------------------------
// MOV with register-specified shift amount (ArmMoveRegisterShiftedRegister-
// Always, op101): rd = rm <shift> (rs & 0xFF). ARM semantics clamp amounts
// >= 32, unlike the AArch64 variable-shift instructions which mask to 5 bits.
// Flag-free throughout: these handlers must not disturb host NZCV.
// a0 = rd | rm<<8 | rs<<16. rd<15 is guaranteed by decode; rm/rs==15 are
// rejected by the translator (stale pc).
// ---------------------------------------------------------------------------
    .globl citra_asm_op_mov_rlsl
citra_asm_op_mov_rlsl:              // amount>=32 -> 0
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    and   w13, w13, #0xFF
    and   w14, w13, #0xE0
    cbnz  w14, 1f
    lsl   w12, w12, w13
    b     2f
1:  mov   w12, #0
2:  and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A

    .globl citra_asm_op_mov_rlsr
citra_asm_op_mov_rlsr:              // amount>=32 -> 0
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    and   w13, w13, #0xFF
    and   w14, w13, #0xE0
    cbnz  w14, 1f
    lsr   w12, w12, w13
    b     2f
1:  mov   w12, #0
2:  and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A

    .globl citra_asm_op_mov_rasr
citra_asm_op_mov_rasr:              // amount>=32 -> sign-fill
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    and   w13, w13, #0xFF
    and   w14, w13, #0xE0
    cbnz  w14, 1f
    asr   w12, w12, w13
    b     2f
1:  asr   w12, w12, #31
2:  and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A

    .globl citra_asm_op_mov_rror
citra_asm_op_mov_rror:              // rotate = amount & 31; ==0 keeps rm
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    ror   w12, w12, w13             // hardware masks to 5 bits == ARM rotate
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A

// ---------------------------------------------------------------------------
// MUL (non-flag): rd = rm * rs
// ---------------------------------------------------------------------------
    .globl citra_asm_op_mul
citra_asm_op_mul:                   // a0 = rd|rm<<8|rs<<16
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    mul   w12, w12, w13
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A

    .globl citra_asm_op_mla
citra_asm_op_mla:                   // a0 = rd|rm<<8|rs<<16|rn<<24
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    ubfx  w14, w10, #24, #4
    ldr   w14, [x25, w14, uxtw #2]
    madd  w12, w12, w13, w14
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A

// Flag-setting mul/mla: N=bit31, Z=result==0, C+V preserved (ARM MUL{S}
// leaves C unaffected; the IR's SetLazyNZFlags matches). Guest flags live
// in host NZCV, so old C+V are re-merged after computing N/Z.
    .globl citra_asm_op_muls
citra_asm_op_muls:                  // a0 = rd|rm<<8|rs<<16
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    mul   w12, w12, w13
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    b     .Lmul_nz

    .globl citra_asm_op_mlas
citra_asm_op_mlas:                  // a0 = rd|rm<<8|rs<<16|rn<<24
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    ubfx  w14, w10, #24, #4
    ldr   w14, [x25, w14, uxtw #2]
    madd  w12, w12, w13, w14
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
.Lmul_nz:                           // w12 = 32-bit result
    and   w17, w12, #0x80000000     // N
    cbnz  w12, 1f
    orr   w17, w17, #0x40000000     // Z
1:  mrs   x14, nzcv
    and   w14, w14, #0x30000000     // keep old C+V
    orr   w17, w17, w14
    msr   nzcv, x17
    orr   x20, x20, #0x100000000
    NEXT_A

// movs/mvns rd, rm (ArmMoveRegisterSetFlagsAlways / ArmMoveNotRegisterSetFlagsAlways):
// N/Z from the result, C+V preserved -- shared tail at .Lmul_nz.
    .globl citra_asm_op_movs_reg
citra_asm_op_movs_reg:              // a0 = rd|rm<<8
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    b     .Lmul_nz

    .globl citra_asm_op_mvns_reg
citra_asm_op_mvns_reg:              // a0 = rd|rm<<8
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    mvn   w12, w12
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    b     .Lmul_nz

// Flag-setting multiply-long: N=bit63 of the 64-bit result, Z=result==0.
    .globl citra_asm_op_mulls
citra_asm_op_mulls:                 // a0 = rd_lo|rd_hi<<8|rs<<16|rm<<24
    ldp   x14, x15, [x9, #AR0]      // a1 = signed<<0 | accumulate<<1
    ubfx  w10, w15, #0, #1           // signed
    ubfx  w11, w15, #1, #1           // accumulate
    ubfx  w12, w14, #24, #4          // rm
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w14, #16, #4          // rs
    ldr   w13, [x25, w13, uxtw #2]
    cbz   w10, 1f
    sxtw  x12, w12
    sxtw  x13, w13
1:  mul   x10, x12, x13
    cbz   w11, 2f
    and   w12, w14, #0xF             // rd_lo
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w14, #8, #4           // rd_hi
    ldr   w13, [x25, w13, uxtw #2]
    orr   x12, x12, x13, lsl #32
    add   x10, x10, x12
2:  and   w12, w14, #0xF
    str   w10, [x25, w12, uxtw #2]
    ubfx  w12, w14, #8, #4
    lsr   x16, x10, #32
    str   w16, [x25, w12, uxtw #2]
    lsr   x17, x10, #63              // N = bit63
    lsl   w17, w17, #31
    cbnz  x10, 1f
    orr   w17, w17, #0x40000000     // Z
1:  mrs   x14, nzcv
    and   w14, w14, #0x30000000     // keep old C+V
    orr   w17, w17, w14
    msr   nzcv, x17
    orr   x20, x20, #0x100000000
    NEXT_A

// ---------------------------------------------------------------------------
// Multiply-long, non-flag (UMULL/UMLAL/SMULL/SMLAL).
// a0 = rd_lo | rd_hi<<8 | rs<<16 | rm<<24 (mirrors IR arg1)
// a1 = signed<<0 | accumulate<<1
// ---------------------------------------------------------------------------
    .globl citra_asm_op_mull
citra_asm_op_mull:
    ldp   x14, x15, [x9, #AR0]
    ubfx  w10, w15, #0, #1           // signed
    ubfx  w11, w15, #1, #1           // accumulate
    ubfx  w12, w14, #24, #4          // rm
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w14, #16, #4          // rs
    ldr   w13, [x25, w13, uxtw #2]
    cbz   w10, 1f
    sxtw  x12, w12
    sxtw  x13, w13
1:  mul   x10, x12, x13
    cbz   w11, 2f
    and   w12, w14, #0xF             // rd_lo
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w14, #8, #4           // rd_hi
    ldr   w13, [x25, w13, uxtw #2]
    orr   x12, x12, x13, lsl #32
    add   x10, x10, x12
2:  and   w12, w14, #0xF
    str   w10, [x25, w12, uxtw #2]
    ubfx  w12, w14, #8, #4
    lsr   x10, x10, #32
    str   w10, [x25, w12, uxtw #2]
    NEXT_A

// ---------------------------------------------------------------------------
// Signed halfword multiplies (ArmSignedHalfwordMultiply, op59).
// Non-long forms: a1 = rd | rm<<8 | rs<<16 | rn<<24; product =
// sxh(rm,x)*sxh(rs,y); accumulate adds Reg[rn] and sets Q (Cpsr bit27) on
// signed overflow. Long forms: a1 = rd_lo | rd_hi<<8 | rn<<16 | rm<<24;
// rd_hi:rd_lo += sxh(rn,x)*sxh(rm,y). Cpsr sits at x22+260.
// ---------------------------------------------------------------------------
.macro SMULH xh, yh
    .globl citra_asm_op_smulh_\xh\yh
citra_asm_op_smulh_\xh\yh:
    ldr   w11, [x9, #AR1]
    ubfx  w12, w11, #8, #4
    ldr   w12, [x25, w12, uxtw #2]   // rm
    sbfx  w12, w12, #(\xh*16), #16
    ubfx  w13, w11, #16, #4
    ldr   w13, [x25, w13, uxtw #2]   // rs
    sbfx  w13, w13, #(\yh*16), #16
    mul   w14, w12, w13
    and   w11, w11, #0xF
    str   w14, [x25, w11, uxtw #2]
    NEXT_A
.endm

.macro SMLAH xh, yh
    .globl citra_asm_op_smlah_\xh\yh
citra_asm_op_smlah_\xh\yh:
    ldr   w11, [x9, #AR1]
    ubfx  w12, w11, #8, #4
    ldr   w12, [x25, w12, uxtw #2]   // rm
    sbfx  w12, w12, #(\xh*16), #16
    ubfx  w13, w11, #16, #4
    ldr   w13, [x25, w13, uxtw #2]   // rs
    sbfx  w13, w13, #(\yh*16), #16
    mul   w14, w12, w13              // product (s32, exact)
    ubfx  w15, w11, #24, #4
    ldr   w15, [x25, w15, uxtw #2]   // rn accumulator
    add   w16, w14, w15
    eor   w17, w14, w16              // signed overflow: (a^s)&(b^s) < 0
    eor   w12, w15, w16
    and   w17, w17, w12
    tbz   w17, #31, 1f
    ldr   w17, [x22, #260]           // state->Cpsr
    orr   w17, w17, #(1 << 27)       // Q flag
    str   w17, [x22, #260]
1:  and   w11, w11, #0xF
    str   w16, [x25, w11, uxtw #2]
    NEXT_A
.endm

.macro SMLALH xh, yh
    .globl citra_asm_op_smlalh_\xh\yh
citra_asm_op_smlalh_\xh\yh:
    ldr   w11, [x9, #AR1]
    ubfx  w12, w11, #16, #4
    ldr   w12, [x25, w12, uxtw #2]   // rn
    sbfx  w12, w12, #(\xh*16), #16
    ubfx  w13, w11, #24, #4
    ldr   w13, [x25, w13, uxtw #2]   // rm
    sbfx  w13, w13, #(\yh*16), #16
    and   w14, w11, #0xF
    ldr   w14, [x25, w14, uxtw #2]   // rd_lo
    ubfx  w15, w11, #8, #4
    ldr   w15, [x25, w15, uxtw #2]   // rd_hi
    orr   x14, x14, x15, lsl #32
    smaddl x14, w12, w13, x14        // accum64 + s32*s32
    and   w12, w11, #0xF
    str   w14, [x25, w12, uxtw #2]
    lsr   x14, x14, #32
    ubfx  w12, w11, #8, #4
    str   w14, [x25, w12, uxtw #2]
    NEXT_A
.endm

SMULH 0, 0
SMULH 0, 1
SMULH 1, 0
SMULH 1, 1
SMLAH 0, 0
SMLAH 0, 1
SMLAH 1, 0
SMLAH 1, 1
SMLALH 0, 0
SMLALH 0, 1
SMLALH 1, 0
SMLALH 1, 1

// ---------------------------------------------------------------------------
// Load/store immediate (little-endian fastmem path).
// a0 = rd|rn<<8, a1 = offset magnitude, a2 = C++ op index.
// Slow on: null page pointer (unmapped/MMIO/rasterizer-cached), page-span
// crossing. ARM unaligned word loads/stores use plain unaligned accesses,
// matching MemorySystem::ReadUnaligned semantics (no rotate).
// ---------------------------------------------------------------------------
// NOTE: nothing in the fast path may set host flags (cmp/tst/ands/...)
// because NZCV carries live guest state. Bounds checks use flag-free
// idiom: (offset - limit) in a scratch reg, then tbz/tbnz/cbz/cbnz.
// Last-page cache (1-entry fastmem TLB): {w23 = guest page index,
// x27 = host page base}. Hit path costs ubfx+sub+cbnz before the access,
// same instruction count as the table lookup but removes the dependent
// page-table load from the access's address chain. On a miss the tail
// loads the table entry, null-checks it (same slow condition as before),
// and fills the cache. The entry is per-run only, so page-table changes
// between runs cannot leave a stale host pointer.
.macro PGHIT name, idxreg, tmp
    sub   \tmp, \idxreg, w23
    cbnz  \tmp, .Lmiss_\name
.endm

.macro PGMISS name, idxreg, ptrreg
.Lmiss_\name:
    ldr   \ptrreg, [x24, \idxreg, uxtw #3]
    cbz   \ptrreg, .Lslow_\name
    mov   w23, \idxreg
    mov   x27, \ptrreg
    b     .Ldo_\name
.endm

.macro LDR_IMM name, size, ldop, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    \addop w12, w12, w11            // guest addr
    and   w13, w12, #ASM_PAGE_MASK
.if \size > 1
    sub   w15, w13, #(0x1001 - \size)
    tbz   w15, #31, .Lslow_\name    // offset > PAGE - size -> slow
.endif
    ubfx  w14, w12, #ASM_PAGE_BITS, #20
    PGHIT \name, w14, w15
.Ldo_\name:
    \ldop w15, [x27, w13, uxtw]
    and   w10, w10, #0xF
    str   w15, [x25, w10, uxtw #2]
    NEXT_A
    PGMISS \name, w14, x14
.Lslow_\name:
    MEMSLOW
.endm

.macro STR_IMM name, size, stop, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    \addop w12, w12, w11            // guest addr
    and   w13, w12, #ASM_PAGE_MASK
.if \size > 1
    sub   w15, w13, #(0x1001 - \size)
    tbz   w15, #31, .Lslow_\name    // offset > PAGE - size -> slow
.endif
    ubfx  w14, w12, #ASM_PAGE_BITS, #20
    PGHIT \name, w14, w15
.Ldo_\name:
    and   w10, w10, #0xF
    ldr   w15, [x25, w10, uxtw #2]
    \stop w15, [x27, w13, uxtw]
    NEXT_A
    PGMISS \name, w14, x14
.Lslow_\name:
    MEMSLOW
.endm

// Literal-pool load: a0 = rd, a1 = guest absolute address (folded
// pc-relative constant), a2 = C++ op index.
.macro LDR_LIT name, size, ldop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    and   w13, w11, #ASM_PAGE_MASK
.if \size > 1
    sub   w15, w13, #(0x1001 - \size)
    tbz   w15, #31, .Lslow_\name    // offset > PAGE - size -> slow
.endif
    ubfx  w14, w11, #ASM_PAGE_BITS, #20
    PGHIT \name, w14, w15
.Ldo_\name:
    \ldop w15, [x27, w13, uxtw]
    and   w10, w10, #0xF
    str   w15, [x25, w10, uxtw #2]
    NEXT_A
    PGMISS \name, w14, x14
.Lslow_\name:
    MEMSLOW
.endm

LDR_LIT ldrw_lit, 4, ldr
LDR_LIT ldrb_lit, 1, ldrb
LDR_LIT ldrh_lit, 2, ldrh
LDR_LIT ldrsb_lit, 1, ldrsb
LDR_LIT ldrsh_lit, 2, ldrsh
LDR_IMM ldrw_add, 4, ldr, add
LDR_IMM ldrw_sub, 4, ldr, sub
LDR_IMM ldrb_add, 1, ldrb, add
LDR_IMM ldrb_sub, 1, ldrb, sub
LDR_IMM ldrh_add, 2, ldrh, add
LDR_IMM ldrh_sub, 2, ldrh, sub
STR_IMM strw_add, 4, str, add
STR_IMM strw_sub, 4, str, sub
STR_IMM strb_add, 1, strb, add
STR_IMM strb_sub, 1, strb, sub
STR_IMM strh_add, 2, strh, add
STR_IMM strh_sub, 2, strh, sub

// Sign-extending loads share the same fastmem skeleton.
LDR_IMM ldrsb_add, 1, ldrsb, add
LDR_IMM ldrsb_sub, 1, ldrsb, sub
LDR_IMM ldrsh_add, 2, ldrsh, add
LDR_IMM ldrsh_sub, 2, ldrsh, sub

// ---------------------------------------------------------------------------
// Direct jump: a0 = target record pointer, a1 = target guest pc.
// Covers unconditional direct branches; translator resolves in-block targets
// and points out-of-block targets at the end record.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_jmp
citra_asm_op_jmp:
    ldp   x10, x11, [x9, #AR0]
    mov   w28, w11
    mov   x9, x10
    add   x20, x20, #1
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8

// Conditional direct branch (ArmBranch, non-link forms).
// a0 = taken record, a1 = taken pc. Not-taken: pc/count advance one insn.
.macro BRA cond
    .globl citra_asm_op_bra_\cond
citra_asm_op_bra_\cond:
    b.\cond 1f
    NEXT_A
1:  ldp   x10, x11, [x9, #AR0]
    mov   w28, w11
    mov   x9, x10
    add   x20, x20, #1
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.endm

BRA eq
BRA ne
BRA cs
BRA cc
BRA mi
BRA pl
BRA vs
BRA vc
BRA hi
BRA ls
BRA ge
BRA lt
BRA gt
BRA le

// ---------------------------------------------------------------------------
// Block-boundary chaining for self-loop branches (target == block.start_pc).
// Instead of exiting to C++ for the next block lookup, the taken path jumps
// straight back to record 0 -- same data flow, no re-entry cost. The budget
// check (`w20 >= budget`) replicates the C++ `result.instructions` boundary
// check that runs once per block iteration, so instruction accounting stays
// identical to the switch interpreter.
//
// NOTE: per-iteration NirqSig/IBIT preemption is intentionally not checked
// here -- the deferral is bounded by this run's budget, matching the
// IsTightSelfBranch fast path the C++ loop already uses for `b .` blocks.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_chain
citra_asm_op_chain:               // a0 = block-start record, a1 = taken pc,
                                  // a2 = block guest-instruction count
    ldp   x10, x11, [x9, #AR0]
    ldr   w17, [x9, #AR2]
    mov   w28, w11
    add   x20, x20, #1
    // Chain only while another *whole* block iteration still fits the
    // budget; a partial iteration must fall back to the C++
    // CheckRemaining path. Flag-free arithmetic: host NZCV still carries
    // the guest lazy flags.
    ldr   w16, [x19, #ASMCTX_BUDGET]
    sub   w16, w16, w20
    sub   w16, w16, w17
    tbnz  w16, #31, .Lasm_budget_exit
    mov   x9, x10
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8

.macro BRA_CHAIN cond
    .globl citra_asm_op_brachain_\cond
citra_asm_op_brachain_\cond:      // a0 = block-start record, a1 = taken pc,
                                  // a2 = block guest-instruction count
    b.\cond 1f
    NEXT_A
1:  ldp   x10, x11, [x9, #AR0]
    ldr   w17, [x9, #AR2]
    mov   w28, w11
    add   x20, x20, #1
    ldr   w16, [x19, #ASMCTX_BUDGET]
    sub   w16, w16, w20
    sub   w16, w16, w17
    tbnz  w16, #31, .Lasm_budget_exit
    mov   x9, x10
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.endm

BRA_CHAIN eq
BRA_CHAIN ne
BRA_CHAIN cs
BRA_CHAIN cc
BRA_CHAIN mi
BRA_CHAIN pl
BRA_CHAIN vs
BRA_CHAIN vc
BRA_CHAIN hi
BRA_CHAIN ls
BRA_CHAIN ge
BRA_CHAIN lt
BRA_CHAIN gt
BRA_CHAIN le

.Lasm_budget_exit:
    mov   w16, #ASM_EXIT_END
    b     .Lasm_done

// ---------------------------------------------------------------------------
// Fused compare + conditional branch.
// a0 = rn | fused_guest_size<<16, a1 = imm, a2 = taken record, a3 = taken pc
// Two guest instructions counted on either path.
// ---------------------------------------------------------------------------
.macro CMPBRA cond
    .globl citra_asm_op_cmpbra_\cond
citra_asm_op_cmpbra_\cond:
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #16, #8
    and   w10, w10, #0xF
    ldr   w10, [x25, w10, uxtw #2]
    ldr   w12, [x9, #AR1]
    cmp   w10, w12
    orr   x20, x20, #0x100000000
    b.\cond 1f
    add   w28, w28, w11
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
1:  ldp   x10, x11, [x9, #AR2]
    mov   w28, w11
    mov   x9, x10
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8

    .globl citra_asm_op_cmnbra_\cond
citra_asm_op_cmnbra_\cond:
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #16, #8
    and   w10, w10, #0xF
    ldr   w10, [x25, w10, uxtw #2]
    ldr   w12, [x9, #AR1]
    cmn   w10, w12
    orr   x20, x20, #0x100000000
    b.\cond 1f
    add   w28, w28, w11
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
1:  ldp   x10, x11, [x9, #AR2]
    mov   w28, w11
    mov   x9, x10
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.endm

CMPBRA eq
CMPBRA ne
CMPBRA cs
CMPBRA cc
CMPBRA mi
CMPBRA pl
CMPBRA vs
CMPBRA vc
CMPBRA hi
CMPBRA ls
CMPBRA ge
CMPBRA lt
CMPBRA gt
CMPBRA le

// Fused register compare + conditional branch.
// a0 = rn|rm<<8|fused_guest_size<<16, a1 = taken record, a2 = taken pc
.macro CMPRBRA cond, insn, suffix
    .globl citra_asm_op_cmprbra_\cond\suffix
citra_asm_op_cmprbra_\cond\suffix:
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #16, #8
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    and   w10, w10, #0xF
    ldr   w10, [x25, w10, uxtw #2]
    \insn wzr, w10, w12
    orr   x20, x20, #0x100000000
    b.\cond 1f
    add   w28, w28, w11
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
1:  ldp   x10, x11, [x9, #AR1]
    mov   w28, w11
    mov   x9, x10
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.endm

.irp cond, eq, ne, cs, cc, mi, pl, vs, vc, hi, ls, ge, lt, gt, le
CMPRBRA \cond, subs,
.endr
.irp cond, eq, ne, cs, cc, mi, pl, vs, vc, hi, ls, ge, lt, gt, le
CMPRBRA \cond, adds, _cmn
.endr

// ---------------------------------------------------------------------------
// Chained variants of the fused compare+branch family for self-loops.
// Same operand layout as the non-chained versions; the taken path jumps to
// the block-start record after the budget check instead of exiting.
// ---------------------------------------------------------------------------
.macro CMPBRA_CHAIN cond
    .globl citra_asm_op_cmpbrachain_\cond
citra_asm_op_cmpbrachain_\cond:
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #16, #8
    and   w10, w10, #0xF
    ldr   w10, [x25, w10, uxtw #2]
    ldr   w12, [x9, #AR1]
    cmp   w10, w12
    orr   x20, x20, #0x100000000
    b.\cond 1f
    add   w28, w28, w11
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
1:  ldp   x10, x11, [x9, #AR2]
    mov   w28, w11
    add   x20, x20, #2
    // Chain only while another whole block iteration fits the budget;
    // a0[31:24] carries the block's guest-instruction count.
    ldr   w17, [x9, #AR0]
    lsr   w17, w17, #24
    ldr   w16, [x19, #ASMCTX_BUDGET]
    sub   w16, w16, w20
    sub   w16, w16, w17
    tbnz  w16, #31, .Lasm_budget_exit
    mov   x9, x10
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8

    .globl citra_asm_op_cmnbrachain_\cond
citra_asm_op_cmnbrachain_\cond:
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #16, #8
    and   w10, w10, #0xF
    ldr   w10, [x25, w10, uxtw #2]
    ldr   w12, [x9, #AR1]
    cmn   w10, w12
    orr   x20, x20, #0x100000000
    b.\cond 1f
    add   w28, w28, w11
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
1:  ldp   x10, x11, [x9, #AR2]
    mov   w28, w11
    add   x20, x20, #2
    // Chain only while another whole block iteration fits the budget;
    // a0[31:24] carries the block's guest-instruction count.
    ldr   w17, [x9, #AR0]
    lsr   w17, w17, #24
    ldr   w16, [x19, #ASMCTX_BUDGET]
    sub   w16, w16, w20
    sub   w16, w16, w17
    tbnz  w16, #31, .Lasm_budget_exit
    mov   x9, x10
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.endm

CMPBRA_CHAIN eq
CMPBRA_CHAIN ne
CMPBRA_CHAIN cs
CMPBRA_CHAIN cc
CMPBRA_CHAIN mi
CMPBRA_CHAIN pl
CMPBRA_CHAIN vs
CMPBRA_CHAIN vc
CMPBRA_CHAIN hi
CMPBRA_CHAIN ls
CMPBRA_CHAIN ge
CMPBRA_CHAIN lt
CMPBRA_CHAIN gt
CMPBRA_CHAIN le

.macro CMPRBRA_CHAIN cond, insn, suffix
    .globl citra_asm_op_cmprbrachain_\cond\suffix
citra_asm_op_cmprbrachain_\cond\suffix:
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #16, #8
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    and   w10, w10, #0xF
    ldr   w10, [x25, w10, uxtw #2]
    \insn wzr, w10, w12
    orr   x20, x20, #0x100000000
    b.\cond 1f
    add   w28, w28, w11
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
1:  ldp   x10, x11, [x9, #AR1]
    mov   w28, w11
    add   x20, x20, #2
    // Chain only while another whole block iteration fits the budget;
    // a0[31:24] carries the block's guest-instruction count.
    ldr   w17, [x9, #AR0]
    lsr   w17, w17, #24
    ldr   w16, [x19, #ASMCTX_BUDGET]
    sub   w16, w16, w20
    sub   w16, w16, w17
    tbnz  w16, #31, .Lasm_budget_exit
    mov   x9, x10
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.endm

.irp cond, eq, ne, cs, cc, mi, pl, vs, vc, hi, ls, ge, lt, gt, le
CMPRBRA_CHAIN \cond, subs,
.endr
.irp cond, eq, ne, cs, cc, mi, pl, vs, vc, hi, ls, ge, lt, gt, le
CMPRBRA_CHAIN \cond, adds, _cmn
.endr

// ---------------------------------------------------------------------------
// Conditional guard: b.<cond> pass-through, else skip run_length records.
// a0 = run_length * ASMOP_SIZE (record skip bytes)
// a1 = pc skip bytes, a2 = run_length (guest instruction count)
// ---------------------------------------------------------------------------
.macro CONDSKIP cond
    .globl citra_asm_op_skip_\cond
citra_asm_op_skip_\cond:
    b.\cond 1f
    ldp   x10, x11, [x9, #AR0]
    ldr   w12, [x9, #AR2]
    add   x9, x9, x10
    add   w28, w28, w11
    add   x20, x20, w12, uxtw
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
1:  NEXT_RAW
.endm

CONDSKIP eq
CONDSKIP ne
CONDSKIP cs
CONDSKIP cc
CONDSKIP mi
CONDSKIP pl
CONDSKIP vs
CONDSKIP vc
CONDSKIP hi
CONDSKIP ls
CONDSKIP ge
CONDSKIP lt
CONDSKIP gt
CONDSKIP le

// ---------------------------------------------------------------------------
// Register-offset load/store (shifted rm).
// a0 = rd|rn<<8|rm<<16, a1 = shift_type|shift_imm<<8, a2 = C++ op index.
// Translator rejects rn/rm/rd==15 and shift_imm==0 with shift_type!=0
// (those encodings have special guest semantics in the IR).
// ---------------------------------------------------------------------------
.macro SHIFT_RM   // in: w13 = rm value, w11 = a1; out: w13 shifted; uses w15
    ubfx  w15, w11, #8, #5          // shift_imm
    tbz   w11, #0, 10f              // types 0 (lsl) / 2 (asr)
    tbz   w11, #1, 12f              // type 1 = lsr
    ror   w13, w13, w15             // type 3 = ror
    b     19f
10: tbz   w11, #1, 11f
    asr   w13, w13, w15             // type 2
    b     19f
11: lsl   w13, w13, w15             // type 0
    b     19f
12: lsr   w13, w13, w15             // type 1
19:
.endm

.macro LDR_REG name, size, ldop, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    SHIFT_RM
    \addop w12, w12, w13
    and   w13, w12, #ASM_PAGE_MASK
.if \size > 1
    sub   w15, w13, #(0x1001 - \size)
    tbz   w15, #31, .Lslow_\name
.endif
    ubfx  w14, w12, #ASM_PAGE_BITS, #20
    PGHIT \name, w14, w15
.Ldo_\name:
    \ldop w15, [x27, w13, uxtw]
    and   w10, w10, #0xF
    str   w15, [x25, w10, uxtw #2]
    NEXT_A
    PGMISS \name, w14, x14
.Lslow_\name:
    MEMSLOW
.endm

.macro STR_REG name, size, stop, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    SHIFT_RM
    \addop w12, w12, w13
    and   w13, w12, #ASM_PAGE_MASK
.if \size > 1
    sub   w15, w13, #(0x1001 - \size)
    tbz   w15, #31, .Lslow_\name
.endif
    ubfx  w14, w12, #ASM_PAGE_BITS, #20
    PGHIT \name, w14, w15
.Ldo_\name:
    and   w10, w10, #0xF
    ldr   w15, [x25, w10, uxtw #2]
    \stop w15, [x27, w13, uxtw]
    NEXT_A
    PGMISS \name, w14, x14
.Lslow_\name:
    MEMSLOW
.endm

LDR_REG ldrw_reg_add, 4, ldr, add
LDR_REG ldrw_reg_sub, 4, ldr, sub
STR_REG strw_reg_add, 4, str, add
STR_REG strw_reg_sub, 4, str, sub
LDR_REG ldrb_reg_add, 1, ldrb, add
LDR_REG ldrb_reg_sub, 1, ldrb, sub
STR_REG strb_reg_add, 1, strb, add
STR_REG strb_reg_sub, 1, strb, sub

// ---------------------------------------------------------------------------
// Register-offset halfword/signed load/store -- no shift, rm is a plain
// register index in a1. a0 = rd|rn<<8, a1 = rm, a2 = C++ op index.
// ---------------------------------------------------------------------------
.macro LDR_RH name, size, ldop, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    and   w13, w11, #0xF
    ldr   w13, [x25, w13, uxtw #2]
    \addop w12, w12, w13
    and   w13, w12, #ASM_PAGE_MASK
.if \size > 1
    sub   w15, w13, #(0x1001 - \size)
    tbz   w15, #31, .Lslow_\name
.endif
    ubfx  w14, w12, #ASM_PAGE_BITS, #20
    PGHIT \name, w14, w15
.Ldo_\name:
    \ldop w15, [x27, w13, uxtw]
    and   w10, w10, #0xF
    str   w15, [x25, w10, uxtw #2]
    NEXT_A
    PGMISS \name, w14, x14
.Lslow_\name:
    MEMSLOW
.endm

.macro STR_RH name, size, stop, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    and   w13, w11, #0xF
    ldr   w13, [x25, w13, uxtw #2]
    \addop w12, w12, w13
    and   w13, w12, #ASM_PAGE_MASK
.if \size > 1
    sub   w15, w13, #(0x1001 - \size)
    tbz   w15, #31, .Lslow_\name
.endif
    ubfx  w14, w12, #ASM_PAGE_BITS, #20
    PGHIT \name, w14, w15
.Ldo_\name:
    and   w10, w10, #0xF
    ldr   w15, [x25, w10, uxtw #2]
    \stop w15, [x27, w13, uxtw]
    NEXT_A
    PGMISS \name, w14, x14
.Lslow_\name:
    MEMSLOW
.endm

LDR_RH ldrh_reg_add, 2, ldrh, add
LDR_RH ldrh_reg_sub, 2, ldrh, sub
STR_RH strh_reg_add, 2, strh, add
STR_RH strh_reg_sub, 2, strh, sub
LDR_RH ldrsb_reg_add, 1, ldrsb, add
LDR_RH ldrsb_reg_sub, 1, ldrsb, sub
LDR_RH ldrsh_reg_add, 2, ldrsh, add
LDR_RH ldrsh_reg_sub, 2, ldrsh, sub

// ---------------------------------------------------------------------------
// Immediate-offset load/store with writeback.
// a0 = rd|rn<<8|add<<16|pre<<17, a1 = offset, a2 = C++ op index.
// Ordering matches the C++ cases: the access reads/writes rd (or memory)
// before rn receives the writeback value, so rd==rn stores the old value
// on stores and the writeback wins on loads.
// ---------------------------------------------------------------------------
.macro LDR_IMM_WB name, size, ldop, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]   // base
    \addop w13, w12, w11             // writeback value
    tbz   w10, #17, .Lpost_\name
    mov   w14, w13                   // pre: address = wb
    b     .Laddr_\name
.Lpost_\name:
    mov   w14, w12                   // post: address = base
.Laddr_\name:
    and   w15, w14, #ASM_PAGE_MASK
.if \size > 1
    sub   w16, w15, #(0x1001 - \size)
    tbz   w16, #31, .Lslow_\name
.endif
    ubfx  w16, w14, #ASM_PAGE_BITS, #20
    PGHIT \name, w16, w17
.Ldo_\name:
    \ldop w15, [x27, w15, uxtw]
    and   w16, w10, #0xF
    str   w15, [x25, w16, uxtw #2]   // rd = mem
    ubfx  w16, w10, #8, #4
    str   w13, [x25, w16, uxtw #2]   // rn = wb
    NEXT_A
    PGMISS \name, w16, x16
.Lslow_\name:
    MEMSLOW
.endm

.macro STR_IMM_WB name, size, stop, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]   // base
    \addop w13, w12, w11             // writeback value
    tbz   w10, #17, .Lpost_\name
    mov   w14, w13
    b     .Laddr_\name
.Lpost_\name:
    mov   w14, w12
.Laddr_\name:
    and   w15, w14, #ASM_PAGE_MASK
.if \size > 1
    sub   w16, w15, #(0x1001 - \size)
    tbz   w16, #31, .Lslow_\name
.endif
    ubfx  w16, w14, #ASM_PAGE_BITS, #20
    PGHIT \name, w16, w17
.Ldo_\name:
    add   x16, x27, w15, uxtw        // final address
    and   w15, w10, #0xF
    ldr   w15, [x25, w15, uxtw #2]   // rd value (old rn when rd==rn)
    \stop w15, [x16]
    ubfx  w16, w10, #8, #4
    str   w13, [x25, w16, uxtw #2]   // rn = wb
    NEXT_A
    PGMISS \name, w16, x16
.Lslow_\name:
    MEMSLOW
.endm

STR_IMM_WB strw_wb, 4, str, add
STR_IMM_WB strw_wb_sub, 4, str, sub
LDR_IMM_WB ldrw_wb, 4, ldr, add
LDR_IMM_WB ldrw_wb_sub, 4, ldr, sub
STR_IMM_WB strb_wb, 1, strb, add
STR_IMM_WB strb_wb_sub, 1, strb, sub
LDR_IMM_WB ldrb_wb, 1, ldrb, add
LDR_IMM_WB ldrb_wb_sub, 1, ldrb, sub
STR_IMM_WB strh_wb, 2, strh, add
STR_IMM_WB strh_wb_sub, 2, strh, sub
LDR_IMM_WB ldrh_wb, 2, ldrh, add
LDR_IMM_WB ldrh_wb_sub, 2, ldrh, sub
LDR_IMM_WB ldrsb_wb, 1, ldrsb, add
LDR_IMM_WB ldrsb_wb_sub, 1, ldrsb, sub
LDR_IMM_WB ldrsh_wb, 2, ldrsh, add
LDR_IMM_WB ldrsh_wb_sub, 2, ldrsh, sub

// ---------------------------------------------------------------------------
// Register-offset word/byte load/store with writeback
// (Arm{Load,Store}{Word,Byte}RegisterWriteback, ops 123-126).
// a0 = rd|rn<<8|rm<<16|add<<20|pre<<21, a1 = shift_type|shift_imm<<8.
// Same ordering as the immediate writeback forms: the access reads/writes rd
// (or memory) before rn receives the writeback value. rd==rn and the
// LSR#0/ASR#0/ROR#0 offset forms are excluded upstream.
// ---------------------------------------------------------------------------
.macro LDR_REG_WB name, size, ldop, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]   // base rn
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]   // rm
    SHIFT_RM                         // w13 = shifted offset; uses w11, w15
    \addop w13, w12, w13             // writeback value
    tbz   w10, #21, .Lpost_\name
    mov   w14, w13                   // pre: address = wb
    b     .Laddr_\name
.Lpost_\name:
    mov   w14, w12                   // post: address = base
.Laddr_\name:
    and   w15, w14, #ASM_PAGE_MASK
.if \size > 1
    sub   w16, w15, #(0x1001 - \size)
    tbz   w16, #31, .Lslow_\name
.endif
    ubfx  w16, w14, #ASM_PAGE_BITS, #20
    PGHIT \name, w16, w17
.Ldo_\name:
    \ldop w15, [x27, w15, uxtw]
    and   w16, w10, #0xF
    str   w15, [x25, w16, uxtw #2]   // rd = mem
    ubfx  w16, w10, #8, #4
    str   w13, [x25, w16, uxtw #2]   // rn = wb
    NEXT_A
    PGMISS \name, w16, x16
.Lslow_\name:
    MEMSLOW
.endm

.macro STR_REG_WB name, size, stop, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]   // base rn
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]   // rm
    SHIFT_RM                         // w13 = shifted offset; uses w11, w15
    \addop w13, w12, w13             // writeback value
    tbz   w10, #21, .Lpost_\name
    mov   w14, w13
    b     .Laddr_\name
.Lpost_\name:
    mov   w14, w12
.Laddr_\name:
    and   w15, w14, #ASM_PAGE_MASK
.if \size > 1
    sub   w16, w15, #(0x1001 - \size)
    tbz   w16, #31, .Lslow_\name
.endif
    ubfx  w16, w14, #ASM_PAGE_BITS, #20
    PGHIT \name, w16, w17
.Ldo_\name:
    add   x16, x27, w15, uxtw        // final address
    and   w15, w10, #0xF
    ldr   w15, [x25, w15, uxtw #2]   // rd value
    \stop w15, [x16]
    ubfx  w16, w10, #8, #4
    str   w13, [x25, w16, uxtw #2]   // rn = wb
    NEXT_A
    PGMISS \name, w16, x16
.Lslow_\name:
    MEMSLOW
.endm

LDR_REG_WB ldrw_reg_wb, 4, ldr, add
LDR_REG_WB ldrw_reg_wb_sub, 4, ldr, sub
STR_REG_WB strw_reg_wb, 4, str, add
STR_REG_WB strw_reg_wb_sub, 4, str, sub
LDR_REG_WB ldrb_reg_wb, 1, ldrb, add
LDR_REG_WB ldrb_reg_wb_sub, 1, ldrb, sub
STR_REG_WB strb_reg_wb, 1, strb, add
STR_REG_WB strb_reg_wb_sub, 1, strb, sub

// ---------------------------------------------------------------------------
// str{,b} pc, [rn, rm{, shift}] / writeback forms (ArmLoadStoreRegister with
// rd==15, lsx=2). The C++ reference stores state->Reg[15] verbatim -- the
// current instruction's own address -- which is exactly live w28.
// a0 = rd(15)|rn<<8|rm<<16|add<<20|pre<<21|wb<<22, a1 = shift, a2 = op index.
// ---------------------------------------------------------------------------
.macro STR_REG_PC name, size, stop, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]
    SHIFT_RM
    \addop w12, w12, w13
    and   w13, w12, #ASM_PAGE_MASK
.if \size > 1
    sub   w15, w13, #(0x1001 - \size)
    tbz   w15, #31, .Lslow_\name
.endif
    ubfx  w14, w12, #ASM_PAGE_BITS, #20
    PGHIT \name, w14, w15
.Ldo_\name:
    \stop w28, [x27, w13, uxtw]
    NEXT_A
    PGMISS \name, w14, x14
.Lslow_\name:
    MEMSLOW
.endm

.macro STR_REG_PC_WB name, size, stop, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]   // base rn
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]   // rm
    SHIFT_RM                         // w13 = shifted offset; uses w11, w15
    \addop w13, w12, w13             // writeback value
    tbz   w10, #21, .Lpost_\name
    mov   w14, w13
    b     .Laddr_\name
.Lpost_\name:
    mov   w14, w12
.Laddr_\name:
    and   w15, w14, #ASM_PAGE_MASK
.if \size > 1
    sub   w16, w15, #(0x1001 - \size)
    tbz   w16, #31, .Lslow_\name
.endif
    ubfx  w16, w14, #ASM_PAGE_BITS, #20
    PGHIT \name, w16, w17
.Ldo_\name:
    add   x16, x27, w15, uxtw        // final address
    \stop w28, [x16]
    ubfx  w16, w10, #8, #4
    str   w13, [x25, w16, uxtw #2]   // rn = wb
    NEXT_A
    PGMISS \name, w16, x16
.Lslow_\name:
    MEMSLOW
.endm

STR_REG_PC strw_pc_reg_add, 4, str, add
STR_REG_PC strw_pc_reg_sub, 4, str, sub
STR_REG_PC strb_pc_reg_add, 1, strb, add
STR_REG_PC strb_pc_reg_sub, 1, strb, sub
STR_REG_PC_WB strw_pc_reg_wb, 4, str, add
STR_REG_PC_WB strw_pc_reg_wb_sub, 4, str, sub
STR_REG_PC_WB strb_pc_reg_wb, 1, strb, add
STR_REG_PC_WB strb_pc_reg_wb_sub, 1, strb, sub

// ---------------------------------------------------------------------------
// ldr pc, [rn, rm{, shift}] (with optional writeback) -- jump-table and
// pop-pc forms of ArmLoadStoreRegister with rd == 15. Same a0/a1 layout as
// LDR_REG_WB: a0 = rd(15)|rn<<8|rm<<16|add<<20|pre<<21|wb<<22, a1 = shift.
// A loaded target whose bit0 differs from the current mode flips TFlag; the
// mode check runs BEFORE any guest write so MEMSLOW replays cleanly.
// Writeback (rn = base +/- offset) applies even for the pc load, matching
// the C++ `writes_back && (!load || rd != rn)` rule.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_ldrw_pc
citra_asm_op_ldrw_pc:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]   // base rn
    ubfx  w13, w10, #16, #4
    ldr   w13, [x25, w13, uxtw #2]   // rm
    SHIFT_RM                         // w13 = shifted offset; uses w11, w15
    tbz   w10, #20, .Lpcs_lpc
    add   w13, w12, w13              // writeback value
    b     .Lpcb_lpc
.Lpcs_lpc:
    sub   w13, w12, w13
.Lpcb_lpc:
    tbz   w10, #21, .Lpost_lpc
    mov   w14, w13                   // pre: address = wb value
    b     .Laddr_lpc
.Lpost_lpc:
    mov   w14, w12                   // post: address = old base
.Laddr_lpc:
    and   w15, w14, #ASM_PAGE_MASK
    sub   w16, w15, #(0x1001 - 4)
    tbz   w16, #31, .Lslow_lpcw
    ubfx  w16, w14, #ASM_PAGE_BITS, #20
    PGHIT lpcw, w16, w17
.Ldo_lpcw:
    ldr   w15, [x27, w15, uxtw]      // branch target word
    ldr   x16, [x19, #ASMCTX_TFLAG]
    and   w17, w15, #1
    str   w17, [x16]                 // TFlag = target bit0
    ldr   w16, [x19, #ASMCTX_CPSRKEY]
    bfi   w16, w17, #5, #1           // cpsr_key follows the new mode so the
    str   w16, [x19, #ASMCTX_CPSRKEY]// end probe can chain into it
    tbz   w10, #22, .Lnowb_lpc
    ubfx  w16, w10, #8, #4
    str   w13, [x25, w16, uxtw #2]   // rn = writeback
.Lnowb_lpc:
    bic   w28, w15, #1               // Reg[15] = target & ~1
    add   x20, x20, #1
    b     citra_asm_op_end
    PGMISS lpcw, w16, x16
.Lslow_lpcw:
    MEMSLOW

// ---------------------------------------------------------------------------
// ldr pc, [pc, rm{, shift}] / ldr pc, [pc, #imm] -- pc-relative jump-table
// and literal-pool absolute-branch forms (rd == 15, rn == 15). a1 carries
// the translate-time base ((insn&~3)+8) or, without the index flag, the
// absolute literal address. a0 = rm | shift_type<<8 | shift_imm<<16 |
// add<<24 | has_index<<25; a2 = C++ op index for MEMSLOW. Writeback is
// impossible: rd == rn == 15 suppresses it in the C++ model. Mode-switch
// handling mirrors ldrw_pc.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_ldrw_pc_lit
citra_asm_op_ldrw_pc_lit:
    ldp   x10, x11, [x9, #AR0]
    mov   w14, w11                   // literal base / absolute address
    tbz   w10, #25, .Laddr_lpclit
    and   w12, w10, #0xF
    ldr   w13, [x25, w12, uxtw #2]   // rm index value
    ubfx  w11, w10, #8, #14          // shift word (type|imm<<8) for SHIFT_RM
    SHIFT_RM                         // w13 = shifted offset; uses w11, w15
    tbz   w10, #24, .Lpcs_lpclit
    add   w14, w14, w13
    b     .Laddr_lpclit
.Lpcs_lpclit:
    sub   w14, w14, w13
.Laddr_lpclit:
    and   w15, w14, #ASM_PAGE_MASK
    sub   w16, w15, #(0x1001 - 4)
    tbz   w16, #31, .Lslow_lpclit
    ubfx  w16, w14, #ASM_PAGE_BITS, #20
    PGHIT lpclit, w16, w17
.Ldo_lpclit:
    ldr   w15, [x27, w15, uxtw]      // branch target word
    ldr   x16, [x19, #ASMCTX_TFLAG]
    and   w17, w15, #1
    str   w17, [x16]                 // TFlag = target bit0
    ldr   w16, [x19, #ASMCTX_CPSRKEY]
    bfi   w16, w17, #5, #1           // cpsr_key follows the new mode so the
    str   w16, [x19, #ASMCTX_CPSRKEY]// end probe can chain into it
    bic   w28, w15, #1               // Reg[15] = target & ~1
    add   x20, x20, #1
    b     citra_asm_op_end
    PGMISS lpclit, w16, x16
.Lslow_lpclit:
    MEMSLOW

// ---------------------------------------------------------------------------
// ldr pc, [rn, #imm]{!} / [rn], #imm -- immediate-offset jump loads
// (ArmLoadStoreImmediate, rd == 15). a0 = rn | add<<4 | pre<<5 | wb<<6;
// a1 = imm; a2 = C++ op index. Writeback mirrors ldrw_pc; rn == 15 keeps the
// slow path (ldrw_pc_lit covers pc-relative forms). Mode-switch handling
// mirrors ldrw_pc.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_ldrw_pc_imm
citra_asm_op_ldrw_pc_imm:
    ldp   x10, x11, [x9, #AR0]
    and   w12, w10, #0xF
    ldr   w12, [x25, w12, uxtw #2]   // base rn
    tbz   w10, #4, .Lpcs_lpcim
    add   w13, w12, w11              // writeback value
    b     .Lpcb_lpcim
.Lpcs_lpcim:
    sub   w13, w12, w11
.Lpcb_lpcim:
    tbz   w10, #5, .Lpost_lpcim
    mov   w14, w13                   // pre: address = wb value
    b     .Laddr_lpcim
.Lpost_lpcim:
    mov   w14, w12                   // post: address = old base
.Laddr_lpcim:
    and   w15, w14, #ASM_PAGE_MASK
    sub   w16, w15, #(0x1001 - 4)
    tbz   w16, #31, .Lslow_lpcim
    ubfx  w16, w14, #ASM_PAGE_BITS, #20
    PGHIT lpcim, w16, w17
.Ldo_lpcim:
    ldr   w15, [x27, w15, uxtw]      // branch target word
    ldr   x16, [x19, #ASMCTX_TFLAG]
    and   w17, w15, #1
    str   w17, [x16]                 // TFlag = target bit0
    ldr   w16, [x19, #ASMCTX_CPSRKEY]
    bfi   w16, w17, #5, #1           // cpsr_key follows the new mode so the
    str   w16, [x19, #ASMCTX_CPSRKEY]// end probe can chain into it
    tbz   w10, #6, .Lnowb_lpcim
    and   w16, w10, #0xF
    str   w13, [x25, w16, uxtw #2]   // rn = writeback
.Lnowb_lpcim:
    bic   w28, w15, #1               // Reg[15] = target & ~1
    add   x20, x20, #1
    b     citra_asm_op_end
    PGMISS lpcim, w16, x16
.Lslow_lpcim:
    MEMSLOW

// ---------------------------------------------------------------------------
// Register-offset halfword/signed load/store with writeback
// (Arm{Load,Store}HalfwordRegisterWriteback, ArmLoadSigned{Byte,Halfword}
// RegisterWriteback, ops 131-134). Halfword register offsets carry no shift:
// a0 = rd|rn<<8|add<<16|pre<<17, a1 = rm index.
// ---------------------------------------------------------------------------
.macro LDR_RH_WB name, size, ldop, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]   // base rn
    and   w13, w11, #0xF
    ldr   w13, [x25, w13, uxtw #2]   // rm offset
    \addop w13, w12, w13             // writeback value
    tbz   w10, #17, .Lpost_\name
    mov   w14, w13                   // pre: address = wb
    b     .Laddr_\name
.Lpost_\name:
    mov   w14, w12                   // post: address = base
.Laddr_\name:
    and   w15, w14, #ASM_PAGE_MASK
.if \size > 1
    sub   w16, w15, #(0x1001 - \size)
    tbz   w16, #31, .Lslow_\name
.endif
    ubfx  w16, w14, #ASM_PAGE_BITS, #20
    PGHIT \name, w16, w17
.Ldo_\name:
    \ldop w15, [x27, w15, uxtw]
    and   w16, w10, #0xF
    str   w15, [x25, w16, uxtw #2]   // rd = mem
    ubfx  w16, w10, #8, #4
    str   w13, [x25, w16, uxtw #2]   // rn = wb
    NEXT_A
    PGMISS \name, w16, x16
.Lslow_\name:
    MEMSLOW
.endm

.macro STR_RH_WB name, stop, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]   // base rn
    and   w13, w11, #0xF
    ldr   w13, [x25, w13, uxtw #2]   // rm offset
    \addop w13, w12, w13             // writeback value
    tbz   w10, #17, .Lpost_\name
    mov   w14, w13
    b     .Laddr_\name
.Lpost_\name:
    mov   w14, w12
.Laddr_\name:
    and   w15, w14, #ASM_PAGE_MASK
    sub   w16, w15, #(0x1001 - 2)
    tbz   w16, #31, .Lslow_\name
    ubfx  w16, w14, #ASM_PAGE_BITS, #20
    PGHIT \name, w16, w17
.Ldo_\name:
    add   x16, x27, w15, uxtw        // final address
    and   w15, w10, #0xF
    ldr   w15, [x25, w15, uxtw #2]   // rd value
    \stop w15, [x16]
    ubfx  w16, w10, #8, #4
    str   w13, [x25, w16, uxtw #2]   // rn = wb
    NEXT_A
    PGMISS \name, w16, x16
.Lslow_\name:
    MEMSLOW
.endm

LDR_RH_WB ldrh_reg_wb, 2, ldrh, add
LDR_RH_WB ldrh_reg_wb_sub, 2, ldrh, sub
STR_RH_WB strh_reg_wb, strh, add
STR_RH_WB strh_reg_wb_sub, strh, sub
LDR_RH_WB ldrsb_reg_wb, 1, ldrsb, add
LDR_RH_WB ldrsb_reg_wb_sub, 1, ldrsb, sub
LDR_RH_WB ldrsh_reg_wb, 2, ldrsh, add
LDR_RH_WB ldrsh_reg_wb_sub, 2, ldrsh, sub

// ---------------------------------------------------------------------------
// ldrd/strd fast forms (ArmLoadDoubleFast/ArmStoreDoubleFast).
// Immediate offsets only; register offsets fall back.
// a0 = rd|rn<<8|add<<16|pre<<18|wb<<19 (bit17 immediate_offset assumed set),
// a1 = offset, a2 = C++ op index.
// ---------------------------------------------------------------------------
.macro LDRD name, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]   // base
    \addop w13, w12, w11             // wb value
    tbz   w10, #18, .Lpost_\name
    mov   w14, w13                   // pre: address = wb
    b     .Laddr_\name
.Lpost_\name:
    mov   w14, w12                   // post: address = base
.Laddr_\name:
    and   w15, w14, #ASM_PAGE_MASK
    sub   w16, w15, #0xFF9           // page offset + 8 <= 4096 required
    tbz   w16, #31, .Lslow_\name
    ubfx  w16, w14, #ASM_PAGE_BITS, #20
    ldr   x16, [x24, w16, uxtw #3]
    cbz   x16, .Lslow_\name
    add   x16, x16, w15, uxtw        // final address
    ldr   w15, [x16]
    ldr   w17, [x16, #4]
    and   w16, w10, #0xF
    str   w15, [x25, w16, uxtw #2]   // rd
    add   w16, w16, #1
    str   w17, [x25, w16, uxtw #2]   // rd+1
    tbz   w10, #19, .Lnowb_\name
    ubfx  w16, w10, #8, #4
    str   w13, [x25, w16, uxtw #2]   // rn = wb
.Lnowb_\name:
    NEXT_A
.Lslow_\name:
    MEMSLOW
.endm

.macro STRD name, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]   // base
    \addop w13, w12, w11             // wb value
    tbz   w10, #18, .Lpost_\name
    mov   w14, w13
    b     .Laddr_\name
.Lpost_\name:
    mov   w14, w12
.Laddr_\name:
    and   w15, w14, #ASM_PAGE_MASK
    sub   w16, w15, #0xFF9
    tbz   w16, #31, .Lslow_\name
    ubfx  w16, w14, #ASM_PAGE_BITS, #20
    ldr   x16, [x24, w16, uxtw #3]
    cbz   x16, .Lslow_\name
    add   x16, x16, w15, uxtw        // final address
    and   w15, w10, #0xF
    ldr   w17, [x25, w15, uxtw #2]   // rd
    add   w15, w15, #1
    ldr   w14, [x25, w15, uxtw #2]   // rd+1
    str   w17, [x16]
    str   w14, [x16, #4]
    tbz   w10, #19, .Lnowb_\name
    ubfx  w16, w10, #8, #4
    str   w13, [x25, w16, uxtw #2]
.Lnowb_\name:
    NEXT_A
.Lslow_\name:
    MEMSLOW
.endm

LDRD ldrd, add
LDRD ldrd_sub, sub
STRD strd, add
STRD strd_sub, sub

// ---------------------------------------------------------------------------
// VFP single/double load/store (ArmVFPLoad/StoreSingle/DoubleFast).
// a0 = ext_reg|rn<<8, a1 = offset, a2 = C++ op index. x22 = ExtReg base.
// ---------------------------------------------------------------------------
.macro VLDR name, size, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    \addop w12, w12, w11
    and   w13, w12, #ASM_PAGE_MASK
.if \size > 4
    sub   w15, w13, #(0x1001 - \size)
    tbz   w15, #31, .Lslow_\name
.endif
    ubfx  w14, w12, #ASM_PAGE_BITS, #20
    ldr   x14, [x24, w14, uxtw #3]
    cbz   x14, .Lslow_\name
.if \size > 4
    ldr   x15, [x14, w13, uxtw]
.else
    ldr   w15, [x14, w13, uxtw]
.endif
    and   w10, w10, #0x3F
    lsl   w10, w10, #2               // ExtReg byte offset
.if \size > 4
    str   x15, [x22, w10, uxtw]
.else
    str   w15, [x22, w10, uxtw]
.endif
    NEXT_A
.Lslow_\name:
    MEMSLOW
.endm

.macro VSTR name, size, addop
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    \addop w12, w12, w11
    and   w13, w12, #ASM_PAGE_MASK
.if \size > 4
    sub   w15, w13, #(0x1001 - \size)
    tbz   w15, #31, .Lslow_\name
.endif
    ubfx  w14, w12, #ASM_PAGE_BITS, #20
    ldr   x14, [x24, w14, uxtw #3]
    cbz   x14, .Lslow_\name
    and   w10, w10, #0x3F
    lsl   w10, w10, #2               // ExtReg byte offset
.if \size > 4
    ldr   x15, [x22, w10, uxtw]
    str   x15, [x14, w13, uxtw]
.else
    ldr   w15, [x22, w10, uxtw]
    str   w15, [x14, w13, uxtw]
.endif
    NEXT_A
.Lslow_\name:
    MEMSLOW
.endm

VLDR vlds_add, 4, add
VLDR vlds_sub, 4, sub
VSTR vsts_add, 4, add
VSTR vsts_sub, 4, sub
VLDR vldd_add, 8, add
VLDR vldd_sub, 8, sub
VSTR vstd_add, 8, add
VSTR vstd_sub, 8, sub

// Literal-pool VFP load: a0 = ext_reg, a1 = guest absolute address (folded
// pc-relative constant), a2 = C++ op index. rn==15 pc-relative stores stay
// on the slow path.
.macro VLDR_LIT name, size
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    and   w13, w11, #ASM_PAGE_MASK
.if \size > 4
    sub   w15, w13, #(0x1001 - \size)
    tbz   w15, #31, .Lslow_\name
.endif
    ubfx  w14, w11, #ASM_PAGE_BITS, #20
    ldr   x14, [x24, w14, uxtw #3]
    cbz   x14, .Lslow_\name
.if \size > 4
    ldr   x15, [x14, w13, uxtw]
.else
    ldr   w15, [x14, w13, uxtw]
.endif
    and   w10, w10, #0x3F
    lsl   w10, w10, #2               // ExtReg byte offset
.if \size > 4
    str   x15, [x22, w10, uxtw]
.else
    str   w15, [x22, w10, uxtw]
.endif
    NEXT_A
.Lslow_\name:
    MEMSLOW
.endm

VLDR_LIT vlds_lit, 4
VLDR_LIT vldd_lit, 8

// ---------------------------------------------------------------------------
// VFP multiple load/store (ArmVFPLoadMultipleFast/ArmVFPStoreMultipleFast).
// a0 = ext_reg|rn<<8|add<<17|wb<<18, a1 = byte count, a2 = C++ op index.
// Single/double is irrelevant here: consecutive ExtReg words are copied.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_vldm
citra_asm_op_vldm:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]   // base
    mov   w13, w12
    tbz   w10, #17, 1f
    b     2f
1:  sub   w13, w12, w11              // !add: addr = base - bytes
2:  and   w14, w13, #ASM_PAGE_MASK
    add   w14, w14, w11
    sub   w14, w14, #1
    lsr   w14, w14, #12              // offset + bytes > 4096 -> slow
    cbnz  w14, .Lslow_vldm
    ubfx  w14, w13, #ASM_PAGE_BITS, #20
    ldr   x14, [x24, w14, uxtw #3]
    cbz   x14, .Lslow_vldm
    and   w13, w13, #ASM_PAGE_MASK
    add   x14, x14, w13, uxtw        // src
    and   w13, w10, #0x3F            // ext_reg
    add   x16, x22, w13, uxtw #2     // dst
    mov   w15, w11                   // bytes left
    cbz   w15, .Lvldm_done
.Lvldm_loop:
    ldr   w17, [x14], #4
    str   w17, [x16], #4
    sub   w15, w15, #4
    cbnz  w15, .Lvldm_loop
.Lvldm_done:
    tbz   w10, #18, .Lvldm_nowb
    tbz   w10, #17, .Lvldm_wbsub
    add   w14, w12, w11
    b     .Lvldm_wbset
.Lvldm_wbsub:
    sub   w14, w12, w11
.Lvldm_wbset:
    ubfx  w13, w10, #8, #4
    str   w14, [x25, w13, uxtw #2]
.Lvldm_nowb:
    NEXT_A
.Lslow_vldm:
    MEMSLOW

    .globl citra_asm_op_vstm
citra_asm_op_vstm:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]   // base
    mov   w13, w12
    tbz   w10, #17, 1f
    b     2f
1:  sub   w13, w12, w11              // !add: addr = base - bytes
2:  and   w14, w13, #ASM_PAGE_MASK
    add   w14, w14, w11
    sub   w14, w14, #1
    lsr   w14, w14, #12              // offset + bytes > 4096 -> slow
    cbnz  w14, .Lslow_vstm
    ubfx  w14, w13, #ASM_PAGE_BITS, #20
    ldr   x14, [x24, w14, uxtw #3]
    cbz   x14, .Lslow_vstm
    and   w13, w13, #ASM_PAGE_MASK
    add   x16, x14, w13, uxtw        // dst
    and   w13, w10, #0x3F            // ext_reg
    add   x14, x22, w13, uxtw #2     // src
    mov   w15, w11                   // bytes left
    cbz   w15, .Lvstm_done
.Lvstm_loop:
    ldr   w17, [x14], #4
    str   w17, [x16], #4
    sub   w15, w15, #4
    cbnz  w15, .Lvstm_loop
.Lvstm_done:
    tbz   w10, #18, .Lvstm_nowb
    tbz   w10, #17, .Lvstm_wbsub
    add   w14, w12, w11
    b     .Lvstm_wbset
.Lvstm_wbsub:
    sub   w14, w12, w11
.Lvstm_wbset:
    ubfx  w13, w10, #8, #4
    str   w14, [x25, w13, uxtw #2]
.Lvstm_nowb:
    NEXT_A
.Lslow_vstm:
    MEMSLOW

// ---------------------------------------------------------------------------
// LDM/STM fast (ArmLoadMultipleFast/ArmStoreMultipleFast).
// a0 = rn|wb<<4|add<<5|pre<<6, a1 = mask&0x7FFF|count<<20, a2 = C++ op index.
// Loads write back rn before the loop (a listed rn is overwritten by its
// loaded value, matching C++); stores keep old_base in w17 so a listed rn
// stores the pre-writeback value.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_ldm
citra_asm_op_ldm:
    ldp   x10, x11, [x9, #AR0]
    and   w12, w10, #0xF
    ldr   w12, [x25, w12, uxtw #2]   // old_base
    ubfx  w14, w11, #20, #8
    lsl   w14, w14, #2               // transfer bytes
    tbz   w10, #5, .Lldm_sub
    tbz   w10, #6, .Lldm_ia
    add   w13, w12, #4               // IB
    b     .Lldm_addr
.Lldm_ia:
    mov   w13, w12                   // IA
    b     .Lldm_addr
.Lldm_sub:
    sub   w13, w12, w14
    tbz   w10, #6, .Lldm_da
    b     .Lldm_addr                 // DB
.Lldm_da:
    add   w13, w13, #4               // DA
.Lldm_addr:
    and   w15, w13, #ASM_PAGE_MASK
    add   w15, w15, w14
    sub   w15, w15, #1
    lsr   w15, w15, #12              // offset + bytes > 4096 -> slow
    cbnz  w15, .Lslow_ldm
    ubfx  w15, w13, #ASM_PAGE_BITS, #20
    ldr   x15, [x24, w15, uxtw #3]
    cbz   x15, .Lslow_ldm
    tbz   w10, #4, .Lldm_nowb        // writeback before loads (C++ order)
    tbz   w10, #5, .Lldm_wbsub
    add   w16, w12, w14
    b     .Lldm_wbset
.Lldm_wbsub:
    sub   w16, w12, w14
.Lldm_wbset:
    and   w12, w10, #0xF
    str   w16, [x25, w12, uxtw #2]
.Lldm_nowb:
    and   w12, w13, #ASM_PAGE_MASK
    add   x12, x15, w12, uxtw        // src ptr
    and   w14, w11, #0xFFFF          // register mask
    cbz   w14, .Lldm_done
.Lldm_loop:
    rbit  w15, w14
    clz   w15, w15                   // lowest set register
    ldr   w16, [x12], #4
    str   w16, [x25, w15, uxtw #2]
    sub   w15, w14, #1
    and   w14, w14, w15              // clear lowest bit
    cbnz  w14, .Lldm_loop
.Lldm_done:
    NEXT_A
.Lslow_ldm:
    MEMSLOW

    .globl citra_asm_op_stm
citra_asm_op_stm:
    ldp   x10, x11, [x9, #AR0]
    and   w12, w10, #0xF
    ldr   w12, [x25, w12, uxtw #2]   // old_base
    mov   w17, w12
    ubfx  w14, w11, #20, #8
    lsl   w14, w14, #2               // transfer bytes
    tbz   w10, #5, .Lstm_sub
    tbz   w10, #6, .Lstm_ia
    add   w13, w12, #4               // IB
    b     .Lstm_addr
.Lstm_ia:
    mov   w13, w12                   // IA
    b     .Lstm_addr
.Lstm_sub:
    sub   w13, w12, w14
    tbz   w10, #6, .Lstm_da
    b     .Lstm_addr                 // DB
.Lstm_da:
    add   w13, w13, #4               // DA
.Lstm_addr:
    and   w15, w13, #ASM_PAGE_MASK
    add   w15, w15, w14
    sub   w15, w15, #1
    lsr   w15, w15, #12              // offset + bytes > 4096 -> slow
    cbnz  w15, .Lslow_stm
    ubfx  w15, w13, #ASM_PAGE_BITS, #20
    ldr   x15, [x24, w15, uxtw #3]
    cbz   x15, .Lslow_stm
    tbz   w10, #4, .Lstm_nowb        // writeback before stores (C++ order)
    tbz   w10, #5, .Lstm_wbsub
    add   w16, w12, w14
    b     .Lstm_wbset
.Lstm_wbsub:
    sub   w16, w12, w14
.Lstm_wbset:
    and   w12, w10, #0xF
    str   w16, [x25, w12, uxtw #2]
.Lstm_nowb:
    and   w12, w13, #ASM_PAGE_MASK
    add   x12, x15, w12, uxtw        // dst ptr
    and   w14, w11, #0xFFFF          // register mask
    cbz   w14, .Lstm_done
    and   w13, w10, #0xF             // rn (for old_base substitution)
.Lstm_loop:
    rbit  w15, w14
    clz   w15, w15
    eor   w16, w15, w13
    cbnz  w16, .Lstm_reg
    mov   w16, w17                   // reg == rn: store pre-writeback base
    b     .Lstm_store
.Lstm_reg:
    ldr   w16, [x25, w15, uxtw #2]
.Lstm_store:
    str   w16, [x12], #4
    sub   w15, w14, #1
    and   w14, w14, w15
    cbnz  w14, .Lstm_loop
.Lstm_done:
    NEXT_A
.Lslow_stm:
    MEMSLOW

// ---------------------------------------------------------------------------
// stm{...} including pc (ArmLoadStoreMultiple, store with reg_mask bit15).
// Same engine as citra_asm_op_stm; the loop stores Reg[15]+8 (w28+8) for
// the pc slot, matching the C++ reference.
// a1 carries the full 16-bit register mask.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_stmpc
citra_asm_op_stmpc:
    ldp   x10, x11, [x9, #AR0]
    and   w12, w10, #0xF
    ldr   w12, [x25, w12, uxtw #2]   // old_base
    mov   w17, w12
    ubfx  w14, w11, #20, #8
    lsl   w14, w14, #2               // transfer bytes
    tbz   w10, #5, .Lstmpc_sub
    tbz   w10, #6, .Lstmpc_ia
    add   w13, w12, #4               // IB
    b     .Lstmpc_addr
.Lstmpc_ia:
    mov   w13, w12                   // IA
    b     .Lstmpc_addr
.Lstmpc_sub:
    sub   w13, w12, w14
    tbz   w10, #6, .Lstmpc_da
    b     .Lstmpc_addr               // DB
.Lstmpc_da:
    add   w13, w13, #4               // DA
.Lstmpc_addr:
    and   w15, w13, #ASM_PAGE_MASK
    add   w15, w15, w14
    sub   w15, w15, #1
    lsr   w15, w15, #12              // offset + bytes > 4096 -> slow
    cbnz  w15, .Lslow_stmpc
    ubfx  w15, w13, #ASM_PAGE_BITS, #20
    ldr   x15, [x24, w15, uxtw #3]
    cbz   x15, .Lslow_stmpc
    tbz   w10, #4, .Lstmpc_nowb      // writeback before stores (C++ order)
    tbz   w10, #5, .Lstmpc_wbsub
    add   w16, w12, w14
    b     .Lstmpc_wbset
.Lstmpc_wbsub:
    sub   w16, w12, w14
.Lstmpc_wbset:
    and   w12, w10, #0xF
    str   w16, [x25, w12, uxtw #2]
.Lstmpc_nowb:
    and   w12, w13, #ASM_PAGE_MASK
    add   x12, x15, w12, uxtw        // dst ptr
    and   w14, w11, #0xFFFF          // register mask
    cbz   w14, .Lstmpc_done
    and   w13, w10, #0xF             // rn (for old_base substitution)
.Lstmpc_loop:
    rbit  w15, w14
    clz   w15, w15
    eor   w16, w15, #0xF           // flag-free reg==15 test (NZCV is guest)
    cbz   w16, .Lstmpc_pc
    eor   w16, w15, w13
    cbnz  w16, .Lstmpc_reg
    mov   w16, w17                   // reg == rn: store pre-writeback base
    b     .Lstmpc_store
.Lstmpc_pc:
    add   w16, w28, #8               // pc slot: Reg[15] + 8 (C++ semantics)
    b     .Lstmpc_store
.Lstmpc_reg:
    ldr   w16, [x25, w15, uxtw #2]
.Lstmpc_store:
    str   w16, [x12], #4
    sub   w15, w14, #1
    and   w14, w14, w15
    cbnz  w14, .Lstmpc_loop
.Lstmpc_done:
    NEXT_A
.Lslow_stmpc:
    MEMSLOW

// ---------------------------------------------------------------------------
// VFP register transfer (ArmVFPRegisterTransferAlways).
// a0 = to_arm|pair<<1|rt<<8|rt2<<12|ext_reg<<16, a2 = C++ op index.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_vfp_xfr
citra_asm_op_vfp_xfr:
    ldr   w10, [x9, #AR0]
    tbz   w10, #0, .Lxfr_from
    ubfx  w11, w10, #16, #6          // ext_reg
    ldr   w12, [x22, w11, uxtw #2]
    ubfx  w13, w10, #8, #4           // rt
    str   w12, [x25, w13, uxtw #2]
    tbz   w10, #1, .Lxfr_done
    add   w11, w11, #1
    ldr   w12, [x22, w11, uxtw #2]
    ubfx  w13, w10, #12, #4          // rt2
    str   w12, [x25, w13, uxtw #2]
    b     .Lxfr_done
.Lxfr_from:
    ubfx  w11, w10, #16, #6
    ubfx  w13, w10, #8, #4
    ldr   w12, [x25, w13, uxtw #2]
    str   w12, [x22, w11, uxtw #2]
    tbz   w10, #1, .Lxfr_done
    ubfx  w13, w10, #12, #4
    ldr   w12, [x25, w13, uxtw #2]
    add   w11, w11, #1
    str   w12, [x22, w11, uxtw #2]
.Lxfr_done:
    NEXT_A

// ---------------------------------------------------------------------------
// VFP system register transfer (ArmVFPSystemRegisterTransfer). Guard records
// carry the predicate when cond != AL.
// a0 = read<<0|vfp_reg<<4|rt<<8|to_nzcv<<16, a2 = C++ op index.
// state->VFP[] sits 7 words below ExtReg: vfp_base = x22 - 28.
// to_nzcv covers "vmrs apsr_nzcv, fpscr" (rt==15 read of FPSCR): the flag
// nibble lands in the host NZCV, which is authoritative during the run.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_vfp_sys
citra_asm_op_vfp_sys:
    ldr   w10, [x9, #AR0]
    sub   x14, x22, #28              // state->VFP
    tbz   w10, #0, .Lsys_w
    ubfx  w11, w10, #4, #4           // vfp_reg
    ldr   w12, [x14, w11, uxtw #2]
    tbnz  w10, #16, .Lsys_nzcv
    ubfx  w13, w10, #8, #4           // rt
    str   w12, [x25, w13, uxtw #2]
    NEXT_A
.Lsys_nzcv:
    and   w12, w12, #0xF0000000      // FPSCR NZCV field -> guest flags
    msr   nzcv, x12
    orr   x20, x20, #0x100000000     // guest flags dirty: write back on exit
    NEXT_A
.Lsys_w:
    ubfx  w13, w10, #8, #4           // rt
    ldr   w12, [x25, w13, uxtw #2]
    ubfx  w11, w10, #4, #4
    str   w12, [x14, w11, uxtw #2]
    NEXT_A

// ---------------------------------------------------------------------------
// MRS (ArmMoveStatusToRegister). a0 = rd | spsr<<4; rd==15 stays slow.
// CPSR/Spsr_copy sit at +260/+264 above ExtReg. For CPSR the live guest NZCV
// is merged into the top nibble (matching C++ SaveFlagsToCpsr + read).
// ---------------------------------------------------------------------------
    .globl citra_asm_op_mrs
citra_asm_op_mrs:
    ldr   w10, [x9, #AR0]
    tbz   w10, #4, .Lmrs_cpsr
    ldr   w12, [x22, #264]           // Spsr_copy
    b     .Lmrs_store
.Lmrs_cpsr:
    mrs   x13, nzcv
    lsr   w13, w13, #28
    ldr   w12, [x22, #260]           // Cpsr
    bfi   w12, w13, #28, #4
.Lmrs_store:
    and   w11, w10, #0xF             // rd
    str   w12, [x25, w11, uxtw #2]
    NEXT_A

// ---------------------------------------------------------------------------
// MRC p15 TLS reads (ArmCoprocessor15Transfer). Only the unprivileged
// c13/c0/op2={2,3} thread registers are covered; every other encoding stays
// on the C++ path (privileged regs, writes, rd==15 flag writes).
// a0 = rd | uro<<4. CP15[] sits 91 words below ExtReg: cp15_base = x22 - 364,
// CP15_THREAD_UPRW=69, CP15_THREAD_URO=70.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_cp15_tls
citra_asm_op_cp15_tls:
    ldr   w10, [x9, #AR0]
    sub   x14, x22, #364             // state->CP15
    ubfx  w11, w10, #4, #1           // 0=UPRW, 1=URO
    add   w11, w11, #69
    ldr   w12, [x14, w11, uxtw #2]
    and   w11, w10, #0xF             // rd
    str   w12, [x25, w11, uxtw #2]
    NEXT_A

// ---------------------------------------------------------------------------
// Generic cp15 register read/write (ArmCoprocessor15Transfer non-TLS forms).
// The (crn,op1,crm,op2) tuple is resolved to a CP15[] index at translate time;
// a0 = rd | (index | priv<<7)<<8 where priv is bit15 of a0 (mirrors
// Cp15Read/WriteIndex's bit7 convention). The privilege gate reads
// state->Mode (x22+272) exactly like ARMul_State::InAPrivilegedMode — the
// Cpsr mode bits in cpsr_key are NOT equivalent (SetCPSR does not update
// Mode). USER32MODE=0x10: privileged-only reads return 0 and writes are
// ignored in user mode. Comparisons are flag-free (eor+cbz) to preserve
// guest NZCV.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_cp15_rd
citra_asm_op_cp15_rd:
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #8, #8           // index | priv<<7
    tbz   w11, #7, 2f                // user-readable entry
    ldr   w12, [x22, #272]           // state->Mode
    eor   w12, w12, #0x10            // USER32MODE
    cbz   w12, 1f                    // user mode: unmapped read returns 0
2:  and   w11, w11, #0x7F
    sub   x14, x22, #364             // state->CP15
    ldr   w12, [x14, w11, uxtw #2]
    b     3f
1:  mov   w12, #0
3:  and   w11, w10, #0xF
    str   w12, [x25, w11, uxtw #2]
    NEXT_A

    .globl citra_asm_op_cp15_wr
citra_asm_op_cp15_wr:
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #8, #8           // index | priv<<7
    tbz   w11, #7, 2f                // user-writable entry
    ldr   w12, [x22, #272]           // state->Mode
    eor   w12, w12, #0x10            // USER32MODE
    cbz   w12, 3f                    // user mode: write ignored
2:  and   w13, w10, #0xF             // rd
    eor   w12, w13, #0xF
    cbnz  w12, 4f
    mov   w12, w28                   // rd==15: raw Reg[15] (this op's pc)
    b     5f
4:  ldr   w12, [x25, w13, uxtw #2]
5:  and   w11, w11, #0x7F
    sub   x14, x22, #364
    str   w12, [x14, w11, uxtw #2]
3:  NEXT_A

// ---------------------------------------------------------------------------
// Exclusive load/store word (ArmExclusiveLoad/Store, size==0 only; byte/half/
// double stay slow). a0 = rd|rn<<8|rm<<16, a2 = C++ op index.
// Monitor state lives at ctx->excl_tag/excl_state (the ARMul_State fields sit
// behind instruction_cache so their offsets are not stable for .S).
// No compare instructions here: host NZCV still holds the guest flags, so the
// monitor match uses eor+cbnz instead of cmp.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_ldrex
citra_asm_op_ldrex:
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #8, #4           // rn
    ldr   w12, [x25, w11, uxtw #2]   // address = Reg[rn]
    // SetExclusiveMemoryAddress(address): tag = addr & ~7, state = true.
    and   w13, w12, #0xFFFFFFF8
    ldr   x14, [x19, #ASMCTX_EXTAG]
    str   w13, [x14]
    ldr   x14, [x19, #ASMCTX_EXSTATE]
    mov   w15, #1
    strb  w15, [x14]
    and   w13, w12, #ASM_PAGE_MASK
    sub   w15, w13, #(0x1001 - 4)    // page-crossing -> slow
    tbz   w15, #31, .Lldrex_slow
    ubfx  w14, w12, #ASM_PAGE_BITS, #20
    ldr   x14, [x24, w14, uxtw #3]
    cbz   x14, .Lldrex_slow
    ldr   w15, [x14, w13, uxtw]
    and   w10, w10, #0xF             // rd
    str   w15, [x25, w10, uxtw #2]
    NEXT_A
.Lldrex_slow:
    MEMSLOW

    .globl citra_asm_op_strex
citra_asm_op_strex:
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #8, #4           // rn
    ldr   w12, [x25, w11, uxtw #2]   // address = Reg[rn]
    // IsExclusiveMemoryAccess: state && tag == (address & ~7)
    ldr   x14, [x19, #ASMCTX_EXSTATE]
    ldrb  w15, [x14]
    cbz   w15, .Lstrex_fail
    ldr   x14, [x19, #ASMCTX_EXTAG]
    ldr   w16, [x14]
    and   w13, w12, #0xFFFFFFF8
    eor   w16, w16, w13
    cbnz  w16, .Lstrex_fail
    // Resolve the fastmem page BEFORE clearing the monitor: a miss replays
    // the whole STREX in C++, which must still observe the armed state.
    and   w13, w12, #ASM_PAGE_MASK
    sub   w15, w13, #(0x1001 - 4)
    tbz   w15, #31, .Lstrex_slow
    ubfx  w14, w12, #ASM_PAGE_BITS, #20
    ldr   x14, [x24, w14, uxtw #3]
    cbz   x14, .Lstrex_slow
    // UnsetExclusiveMemoryAddress(): tag = ~0, state = false
    ldr   x15, [x19, #ASMCTX_EXTAG]
    mov   w16, #-1
    str   w16, [x15]
    ldr   x15, [x19, #ASMCTX_EXSTATE]
    strb  wzr, [x15]
    ubfx  w16, w10, #16, #4          // rm
    ldr   w15, [x25, w16, uxtw #2]
    str   w15, [x14, w13, uxtw]
    and   w10, w10, #0xF             // rd = 0 (success)
    str   wzr, [x25, w10, uxtw #2]
    NEXT_A
.Lstrex_fail:
    and   w10, w10, #0xF             // rd = 1 (monitor not armed)
    mov   w15, #1
    str   w15, [x25, w10, uxtw #2]
    NEXT_A
.Lstrex_slow:
    MEMSLOW

    .globl citra_asm_op_clrex
citra_asm_op_clrex:               // UnsetExclusiveMemoryAddress (ArmClearExclusive)
    ldr   x14, [x19, #ASMCTX_EXTAG]
    mov   w15, #-1
    str   w15, [x14]
    ldr   x14, [x19, #ASMCTX_EXSTATE]
    strb  wzr, [x14]
    NEXT_A

    .globl citra_asm_op_clz
citra_asm_op_clz:                 // a0 = rd|rm<<8 (ArmCountLeadingZeros)
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    clz   w12, w12
    and   w10, w10, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A

// uxtb/uxth/sxtb/sxth rd, rm{, ror #rot*8} (ArmExtend, op18).
// a0 = cond|signed<<8|halfword<<9|rotate<<10 (cond nibble unused here),
// a1 = rd|rm<<8. Flag-free.
    .globl citra_asm_op_ext
citra_asm_op_ext:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w11, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #10, #2            // rotate 0-3
    lsl   w13, w13, #3
    ror   w12, w12, w13
    tbz   w10, #9, .Lext_byte
    tbz   w10, #8, 1f
    sxth  w12, w12
    b     .Lext_st
1:  uxth  w12, w12
    b     .Lext_st
.Lext_byte:
    tbz   w10, #8, 1f
    sxtb  w12, w12
    b     .Lext_st
1:  uxtb  w12, w12
.Lext_st:
    and   w10, w11, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A

// rev/rev16/revsh rd, rm (ArmReverse, op19). Type 3 (rbit) is gated out by
// the translator (its C++ case needs_fallback anyway).
// a0 = cond|type<<8, a1 = rd|rm<<8. Flag-free.
    .globl citra_asm_op_rev
citra_asm_op_rev:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w11, #8, #4
    ldr   w12, [x25, w12, uxtw #2]
    tbnz  w10, #8, .Lrev_r16           // type 1 -> rev16
    tbz   w10, #9, .Lrev_rev           // type 0 -> rev
    rev16 w12, w12                     // type 2 -> revsh: rev16 + sign-extend
    sxth  w12, w12
    b     .Lrev_st
.Lrev_r16:
    rev16 w12, w12
    b     .Lrev_st
.Lrev_rev:
    rev   w12, w12
.Lrev_st:
    and   w10, w11, #0xF
    str   w12, [x25, w10, uxtw #2]
    NEXT_A

// ---------------------------------------------------------------------------
// Condition guard: emitted before a body record for predicated (cond != AL)
// guest ops. When the guest condition fails, the guarded record is skipped
// and the op still consumes one guest instruction (matches the C++ generic
// handlers' AdvancePC path). a0 = guarded op's guest_size.
// NZCV still holds the guest flags at this point: flag-dirty tracking only
// matters for writeback, so evaluating the condition here is safe.
// ---------------------------------------------------------------------------
.macro GUARD cond
    .globl citra_asm_op_guard_\cond
citra_asm_op_guard_\cond:
    b.\cond 1f
    add   x20, x20, #1
    ldr   w10, [x9, #AR0]
    add   w28, w28, w10
    add   x9, x9, #ASMOP_SIZE        // skip the guarded record
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
1:  NEXT_RAW
.endm

GUARD eq
GUARD ne
GUARD cs
GUARD cc
GUARD mi
GUARD pl
GUARD vs
GUARD vc
GUARD hi
GUARD ls
GUARD ge
GUARD lt
GUARD gt
GUARD le

// ---------------------------------------------------------------------------
// Branch with link (ArmBranch with the link bit): r14 = a1, pc = a0, then
// run the block-end chain lookup on the new pc.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_bl
citra_asm_op_bl:                    // a0 = target pc, a1 = link value
    ldp   x10, x11, [x9, #AR0]
    mov   w28, w10
    str   w11, [x25, #56]           // Reg[14]
    add   x20, x20, #1
    b     citra_asm_op_end

// ---------------------------------------------------------------------------
// Branch exchange (ArmBranchExchange[Always]). a0 = rm, a2 = C++ op index.
// The handler owns the mode switch: TFlag = target & 1 is written directly
// so a Thumb target no longer exits slow. A mode-changing branch then runs
// the end record's chain probe under the entry block's cpsr_key, which can
// never match the opposite-mode target -- the probe misses and the C++ loop
// re-enters the block cache with the live TFlag.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_bx
citra_asm_op_bx:
    ldr   w10, [x9, #AR0]
    ldr   w11, [x25, w10, uxtw #2]  // target
    ldr   x12, [x19, #ASMCTX_TFLAG]
    and   w13, w11, #1
    str   w13, [x12]                // TFlag = target bit0
    // Keep the run's cpsr_key in step: only the T bit differs between
    // modes, so key = (key & ~TBIT) | (newT << 5). The end probe can then
    // chain straight into a foreign-mode block instead of round-tripping
    // through C++ on every interworking branch.
    ldr   w12, [x19, #ASMCTX_CPSRKEY]
    bfi   w12, w13, #5, #1
    str   w12, [x19, #ASMCTX_CPSRKEY]
    bic   w28, w11, #1              // Reg[15] = target & ~1
    add   x20, x20, #1
    b     citra_asm_op_end

// ---------------------------------------------------------------------------
// Branch-link exchange by register (ArmBranchLinkExchange register forms).
// a0 = rm, a1 = link value, a2 = C++ op index. Mode switches handled in
// place as in citra_asm_op_bx.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_blx
citra_asm_op_blx:
    // The link value is computed from live w28 rather than a prebaked
    // constant: Reg[14] must be pc_of_this_op + guest_size (|1 under Thumb),
    // and in mixed-size Thumb blocks a translate-time (i+1)*guest_size
    // estimate would be wrong.
    ldr   w10, [x9, #AR0]
    ldr   w12, [x25, w10, uxtw #2]  // target
    ldr   w13, [x9, #AR3]           // this op's guest_size (chains may have
                                    // crossed modes; ASMCTX_GUESTSIZE is the
                                    // run-entry block's, not this block's)
    add   w14, w28, w13             // link = pc + guest_size
    ldr   w15, [x19, #ASMCTX_CPSRKEY]
    ubfx  w15, w15, #5, #1          // current T bit (post-chain mode)
    orr   w14, w14, w15             // link |= TFlag
    ldr   x10, [x19, #ASMCTX_TFLAG]
    and   w11, w12, #1
    str   w11, [x10]                // TFlag = target bit0
    ldr   w10, [x19, #ASMCTX_CPSRKEY]
    bfi   w10, w11, #5, #1          // cpsr_key T bit follows the new mode
    str   w10, [x19, #ASMCTX_CPSRKEY]
    bic   w28, w12, #1              // Reg[15] = target & ~1
    str   w14, [x25, #56]
    add   x20, x20, #1
    b     citra_asm_op_end

// ---------------------------------------------------------------------------
// ARM blx #imm (ArmBranchLinkExchange immediate form): always enters Thumb.
// a0 = target (prebaked pc+8+offset+H), a1 = link (prebaked pc+4).
// ---------------------------------------------------------------------------
    .globl citra_asm_op_blxi
citra_asm_op_blxi:
    ldr   w10, [x9, #AR0]           // target
    ldr   w11, [x9, #AR1]           // link value
    str   w11, [x25, #56]           // Reg[14]
    ldr   x12, [x19, #ASMCTX_TFLAG]
    mov   w13, #1
    str   w13, [x12]                // TFlag = 1 (Thumb)
    ldr   w13, [x19, #ASMCTX_CPSRKEY]
    orr   w13, w13, #0x20           // cpsr_key T bit = 1
    str   w13, [x19, #ASMCTX_CPSRKEY]
    mov   w28, w10                  // Reg[15] = target (keeps bit1)
    add   x20, x20, #1
    b     citra_asm_op_end

// ---------------------------------------------------------------------------
// Thumb blx #imm (ThumbBranchLinkExchange): always enters ARM state.
// a0 = offset << 1. target = (Reg[14] + a0) & ~3; Reg[14] = (pc + 2) | 1.
// The old LR is read before the new link is stored.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_tblx
citra_asm_op_tblx:
    ldr   w10, [x9, #AR0]           // offset
    ldr   w11, [x25, #56]           // old Reg[14]
    add   w12, w28, #2
    orr   w12, w12, #1              // link = (pc + 2) | 1
    add   w11, w11, w10
    bic   w28, w11, #3              // Reg[15] = (old_lr + off) & ~3
    str   w12, [x25, #56]           // Reg[14] = link
    ldr   x13, [x19, #ASMCTX_TFLAG]
    str   wzr, [x13]                // TFlag = 0 (ARM)
    ldr   w13, [x19, #ASMCTX_CPSRKEY]
    bic   w13, w13, #0x20           // cpsr_key T bit = 0
    str   w13, [x19, #ASMCTX_CPSRKEY]
    add   x20, x20, #1
    b     citra_asm_op_end

// ---------------------------------------------------------------------------
// Thumb bl prefix (ThumbBranchLinkSetup): Reg[14] = pc_of_op + 4 + a0.
// a0 = sign-extended high offset half. Mid-block op; w28 is this op's pc.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_tblsetup
citra_asm_op_tblsetup:
    ldr   w10, [x9, #AR0]
    add   w11, w28, #4
    add   w11, w11, w10
    str   w11, [x25, #56]          // Reg[14]
    NEXT_A

// ---------------------------------------------------------------------------
// Thumb bl suffix (ThumbBranchLink, always block-terminal and always stays
// in Thumb state): target = Reg[14] + a0; Reg[14] = (pc_of_op + 2) | 1;
// pc = target & ~1. Counts the op then falls into the end record's chain
// probe, matching every other block terminator.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_tblink
citra_asm_op_tblink:
    ldr   w10, [x9, #AR0]          // low offset half
    ldr   w11, [x25, #56]          // Reg[14] staged by the setup half
    add   w12, w28, #2
    orr   w12, w12, #1             // next lr
    add   w11, w11, w10            // target
    bic   w28, w11, #1             // pc = target & ~1
    str   w12, [x25, #56]
    add   x20, x20, #1
    b     citra_asm_op_end

// ---------------------------------------------------------------------------
// Generic immediate-offset word load/store (ArmLoadWordImmediate /
// ArmStoreWordImmediate). These are the PC-operand forms: rn==15 is a
// literal-pool access whose base is (w28 & ~3) + guest_size*2, matching
// ReadAddressRegister. rd==15 keeps its quirky C++ semantics and goes slow.
// a0 = rd|rn<<8|add<<16, a1 = imm, a2 = C++ op index, a3 = guest_size.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_ldrw_gen
citra_asm_op_ldrw_gen:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4          // rn
    sub   w15, w12, #15
    cbnz  w15, 1f
    ldr   w15, [x9, #AR3]           // guest_size
    and   w12, w28, #0xFFFFFFFC
    add   w12, w12, w15, lsl #1     // pc operand base
    b     2f
1:  ldr   w12, [x25, w12, uxtw #2]
2:  tbz   w10, #16, 3f
    add   w12, w12, w11
    b     4f
3:  sub   w12, w12, w11
4:  and   w13, w12, #ASM_PAGE_MASK
    sub   w15, w13, #(0x1001 - 4)
    tbz   w15, #31, .Lslow_lgen
    ubfx  w14, w12, #ASM_PAGE_BITS, #20
    ldr   x14, [x24, w14, uxtw #3]
    cbz   x14, .Lslow_lgen
    ldr   w15, [x14, w13, uxtw]
    and   w10, w10, #0xF            // rd
    sub   w13, w10, #15
    cbz   w13, .Lslow_lgen          // ldr pc: C++ writes then advances pc
    str   w15, [x25, w10, uxtw #2]
    NEXT_A
.Lslow_lgen:
    MEMSLOW

    .globl citra_asm_op_strw_gen
citra_asm_op_strw_gen:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4          // rn
    sub   w15, w12, #15
    cbnz  w15, 1f
    ldr   w15, [x9, #AR3]
    and   w12, w28, #0xFFFFFFFC
    add   w12, w12, w15, lsl #1
    b     2f
1:  ldr   w12, [x25, w12, uxtw #2]
2:  tbz   w10, #16, 3f
    add   w12, w12, w11
    b     4f
3:  sub   w12, w12, w11
4:  and   w13, w12, #ASM_PAGE_MASK
    sub   w15, w13, #(0x1001 - 4)
    tbz   w15, #31, .Lslow_sgen
    ubfx  w14, w12, #ASM_PAGE_BITS, #20
    ldr   x14, [x24, w14, uxtw #3]
    cbz   x14, .Lslow_sgen
    and   w10, w10, #0xF            // rd
    sub   w15, w10, #15
    cbz   w15, .Lslow_sgen          // str pc stores pc+8 in C++
    ldr   w15, [x25, w10, uxtw #2]
    str   w15, [x14, w13, uxtw]
    NEXT_A
.Lslow_sgen:
    MEMSLOW

// ---------------------------------------------------------------------------
// LDM including pc (ArmLoadMultipleWithPcFast). Same addressing/writeback
// order as citra_asm_op_ldm; the pc word is the highest register so it is
// read last, then chained like any other indirect jump. A Thumb target
// (bit0 set) exits slow so C++ can flip TFlag.
// a0 = rn|wb<<4|add<<5|pre<<6, a1 = mask&0x7FFF|count<<20, a2 = op index.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_ldmpc
citra_asm_op_ldmpc:
    ldp   x10, x11, [x9, #AR0]
    and   w12, w10, #0xF
    ldr   w12, [x25, w12, uxtw #2]   // old_base
    ubfx  w14, w11, #20, #8
    lsl   w14, w14, #2               // transfer bytes (incl. pc word)
    tbz   w10, #5, .Llpc_sub
    tbz   w10, #6, .Llpc_ia
    add   w13, w12, #4               // IB
    b     .Llpc_addr
.Llpc_ia:
    mov   w13, w12                   // IA
    b     .Llpc_addr
.Llpc_sub:
    sub   w13, w12, w14
    tbz   w10, #6, .Llpc_da
    b     .Llpc_addr                 // DB
.Llpc_da:
    add   w13, w13, #4               // DA
.Llpc_addr:
    and   w15, w13, #ASM_PAGE_MASK
    add   w15, w15, w14
    sub   w15, w15, #1
    lsr   w15, w15, #12
    cbnz  w15, .Lslow_lpc
    ubfx  w15, w13, #ASM_PAGE_BITS, #20
    ldr   x15, [x24, w15, uxtw #3]
    cbz   x15, .Lslow_lpc
    and   w16, w13, #ASM_PAGE_MASK
    add   x13, x15, w16, uxtw        // src ptr
    // Peek at the pc word BEFORE any guest writeback so the address-range
    // checks above still bail to C++ cleanly. The mode switch itself is
    // owned here: TFlag = pc_word & 1, and the end probe misses on a real
    // mode change because it runs under the entry block's cpsr_key.
    sub   w15, w14, #4
    ldr   w17, [x13, w15, uxtw]      // pc word: highest reg = last transfer
    ldr   x15, [x19, #ASMCTX_TFLAG]
    and   w16, w17, #1
    str   w16, [x15]                 // TFlag = pc bit0
    ldr   w15, [x19, #ASMCTX_CPSRKEY]
    bfi   w15, w16, #5, #1           // cpsr_key follows the new mode
    str   w15, [x19, #ASMCTX_CPSRKEY]
    tbz   w10, #4, .Llpc_nowb        // writeback before loads (C++ order)
    tbz   w10, #5, .Llpc_wbsub
    add   w16, w12, w14
    b     .Llpc_wbset
.Llpc_wbsub:
    sub   w16, w12, w14
.Llpc_wbset:
    and   w12, w10, #0xF
    str   w16, [x25, w12, uxtw #2]
.Llpc_nowb:
    and   w14, w11, #0x7FFF          // registers below pc
    cbz   w14, .Llpc_pc
.Llpc_loop:
    rbit  w15, w14
    clz   w15, w15
    ldr   w16, [x13], #4
    str   w16, [x25, w15, uxtw #2]
    sub   w15, w14, #1
    and   w14, w14, w15
    cbnz  w14, .Llpc_loop
.Llpc_pc:
    bic   w28, w17, #1               // Reg[15] = target & ~1
    add   x20, x20, #1
    b     citra_asm_op_end
.Lslow_lpc:
    MEMSLOW

// ---------------------------------------------------------------------------
// Fused test + conditional branch (ArmTestImmediateBranchNoPcAlways /
// ArmTestRegisterBranchNoPcAlways): teq/tst then b.<cond>. The compare must
// not touch the guest's C/V, so host NZCV is rebuilt field by field:
//   N = bit31(result), Z = result==0, C = shifter carry or guest C,
//   V = preserved guest V.
// a0 packs the C++ arg0 fields; a1 = imm (tstrbra reads rm from a0 instead),
// a2 = taken pc. Counts two guest instructions on either path.
// ---------------------------------------------------------------------------
.macro TSTBRA cond, infix, isreg
    .globl citra_asm_op_tst\infix\()bra_\cond
citra_asm_op_tst\infix\()bra_\cond:
    ldr   w10, [x9, #AR0]
.if \isreg
    and   w11, w10, #0xF
    ldr   w11, [x25, w11, uxtw #2]
    ubfx  w12, w10, #4, #4          // rm
    ldr   w12, [x25, w12, uxtw #2]
.else
    and   w11, w10, #0xF
    ldr   w11, [x25, w11, uxtw #2]
    ldr   w12, [x9, #AR1]           // imm
.endif
.if \isreg
    tbz   w10, #8, 1f               // test_equal flag at bit8 for reg form
.else
    tbz   w10, #4, 1f               // bit4 for imm form
.endif
    eor   w13, w11, w12
    b     2f
1:  and   w13, w11, w12
2:  mrs   x14, nzcv                 // guest flags before clobbering
    lsr   w15, w13, #31
    lsl   w15, w15, #31             // n
    subs  w16, w13, #0              // sets host z (discarded below)
    cset  w16, eq
    bfi   w15, w16, #30, #1         // z
.if \isreg
    ubfx  w16, w14, #29, #1         // reg form: carry is always guest C
.else
    tbz   w10, #6, 3f
    ubfx  w16, w14, #29, #1         // carry from guest C
    b     4f
3:  ubfx  w16, w10, #5, #1          // shifter carry constant
4:
.endif
    bfi   w15, w16, #29, #1         // c
    ubfx  w16, w14, #28, #1         // guest V
    bfi   w15, w16, #28, #1
    msr   nzcv, x15
    orr   x20, x20, #0x100000000
    b.\cond 5f
    ldr   w12, [x9, #AR3]
    add   w28, w28, w12
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
5:  ldr   w11, [x9, #AR2]
    mov   w28, w11
    add   x20, x20, #2
    b     citra_asm_op_end
.endm

.irp cond, eq, ne, cs, cc, mi, pl, vs, vc, hi, ls, ge, lt, gt, le
TSTBRA \cond, , 0
TSTBRA \cond, r, 1
.endr

// ---------------------------------------------------------------------------
// Standalone TST/TEQ with immediate, flags only
// (ArmTstImmediateNoPcAlways / ArmTeqImmediateNoPcAlways).
// a0 = rn | carry<<8 | nz_only<<9 (arg0 bits0-1), a1 = imm.
// Host NZCV is rebuilt field by field: nz_only (SetLazyNZFlags) keeps the
// old C+V; logical (SetLazyLogicalFlags) installs the shifter carry and
// keeps V.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_tst_imm_f
citra_asm_op_tst_imm_f:
    ldp   x10, x11, [x9, #AR0]
    and   w12, w10, #0xF
    ldr   w12, [x25, w12, uxtw #2]
    and   w13, w12, w11
    b     .Ltst_imm_flags
    .globl citra_asm_op_teq_imm_f
citra_asm_op_teq_imm_f:
    ldp   x10, x11, [x9, #AR0]
    and   w12, w10, #0xF
    ldr   w12, [x25, w12, uxtw #2]
    eor   w13, w12, w11
.Ltst_imm_flags:
    mrs   x14, nzcv                 // old guest flags (C and V survive)
    and   w15, w13, #0x80000000     // N
    cbnz  w13, 1f
    orr   w15, w15, #0x40000000     // Z
1:  ubfx  w16, w14, #29, #1         // nz_only keeps the old C
    tbnz  w10, #9, 2f
    ubfx  w16, w10, #8, #1          // logical: shifter carry constant
2:  orr   w15, w15, w16, lsl #29
    ubfx  w16, w14, #28, #1         // V always preserved
    orr   w15, w15, w16, lsl #28
    msr   nzcv, x15
    orr   x20, x20, #0x100000000
    NEXT_A

// ---------------------------------------------------------------------------
// VFP scalar data processing (ArmVFPDataProcessing[Always], mode 0 only).
// Mirrors VfpHost::TryExecute's safe domain exactly: guest FPSCR must select
// scalar mode (LEN==0) and round-to-nearest (the run pins host FPCR=RN);
// operands and results must be normal-or-zero -- everything else slow-exits
// so the C++ softfloat path computes the reference result. Host FPSR
// exception bits merge into the guest FPSCR on success (mask 0x9F); the
// FCMP family replaces the FPSCR NZCV field from the host compare.
//   a0 = raw VFP instruction word
//   a1 = sd | sn<<5 | sm<<10 | dd<<15 | dn<<20 | dm<<25 (vfp_get_* indices)
//   a2 = C++ op index
// FPSCR is VFP[1]: state->VFP sits 7 words below ExtReg -> [x22, #-24].
// ---------------------------------------------------------------------------
// "normal or zero" classification without touching guest NZCV: exponent in
// [1,max-1] is normal; exp==0 requires mantissa==0 (zero); exp==max is
// inf/nan. Non-domain inputs branch to .Lslow_vfpdp.
.macro VFPDOM32 wr, wt
    ubfx  \wt, \wr, #23, #8
    sub   \wt, \wt, #1
    and   \wt, \wt, #0xFF
    sub   \wt, \wt, #0xFE
    tbnz  \wt, #31, 98f           // exponent in [1,254]: normal
    ubfx  \wt, \wr, #23, #8
    cbnz  \wt, .Lslow_vfpdp       // exponent 0xFF: inf/nan
    lsl   \wt, \wr, #9
    cbnz  \wt, .Lslow_vfpdp       // exponent 0 with mantissa: denormal
98:
.endm

.macro VFPDOM64 xr, xt
    ubfx  \xt, \xr, #52, #11
    sub   \xt, \xt, #1
    and   \xt, \xt, #0x7FF
    sub   \xt, \xt, #0x7FE
    tbnz  \xt, #63, 98f           // exponent in [1,2046]: normal
    ubfx  \xt, \xr, #52, #11
    cbnz  \xt, .Lslow_vfpdp       // exponent 0x7FF: inf/nan
    lsl   \xt, \xr, #12
    cbnz  \xt, .Lslow_vfpdp       // denormal
98:
.endm

// ExtReg[sn] -> s0, ExtReg[sm] -> s1, both domain-checked (bits in w13/w14).
.macro VFPLD_S
    ubfx  w12, w11, #5, #5          // sn
    ldr   w13, [x22, w12, uxtw #2]
    VFPDOM32 w13, w15
    ubfx  w12, w11, #10, #5         // sm
    ldr   w14, [x22, w12, uxtw #2]
    VFPDOM32 w14, w15
    fmov  s0, w13
    fmov  s1, w14
.endm

// ExtReg[dn*2..] -> d0, ExtReg[dm*2..] -> d1, both domain-checked.
.macro VFPLD_D
    ubfx  w12, w11, #20, #5         // dn
    ldr   x13, [x22, w12, uxtw #3]
    VFPDOM64 x13, x15
    ubfx  w12, w11, #25, #5         // dm
    ldr   x14, [x22, w12, uxtw #3]
    VFPDOM64 x14, x15
    fmov  d0, x13
    fmov  d1, x14
.endm

// f32 result in s2 -> ExtReg[sd]; FPSR exception bits merge into FPSCR.
.macro VFPST_S
    fmov  w12, s2
    mrs   x15, fpsr
    VFPDOM32 w12, w16
    b     .Lvfpdp_store_s
.endm

// f64 result in d2 -> ExtReg[dd*2..]; FPSR exception bits merge into FPSCR.
.macro VFPST_D
    fmov  x12, d2
    mrs   x15, fpsr
    VFPDOM64 x12, x16
    b     .Lvfpdp_store_d
.endm

// Single-precision MAC: the guest keeps a wider internal product that a
// host fma cannot reproduce, so (as in vfp_host) the product is computed in
// double -- a 24x24-bit product is exact -- then narrowed once to single.
// \op selects the accumulate form: mac dd+prod, msc prod-dd, nmac dd-prod,
// nmsc -(dd+prod).
.macro VFPMAC_S op
    VFPLD_S
    and   w12, w11, #0x1F           // sd operand
    ldr   w16, [x22, w12, uxtw #2]
    VFPDOM32 w16, w15
    fcvt  d0, s0                    // n as double (exact widening)
    fcvt  d1, s1                    // m as double
    fmov  s3, w16
    fcvt  d3, s3                    // d as double
    msr   fpsr, xzr
    fmul  d0, d0, d1                // prod: exact in double
.ifc "\op","msc"
    fsub  d2, d0, d3                // prod - dd
.endif
.ifc "\op","nmac"
    fsub  d2, d3, d0                // dd - prod
.endif
.ifc "\op","mac"
    fadd  d2, d3, d0                // dd + prod
.endif
.ifc "\op","nmsc"
    fadd  d2, d3, d0                // negated after narrowing below
.endif
    fcvt  s2, d2                    // narrowing: may raise OFC/UFC/IXC
.ifc "\op","nmsc"
    fneg  s2, s2
.endif
    VFPST_S
.endm

    .globl citra_asm_op_vfpdp
citra_asm_op_vfpdp:
    ldp   x10, x11, [x9, #AR0]
    ldr   w12, [x22, #-24]          // guest FPSCR
    ubfx  w13, w12, #16, #8         // LEN[2:0] .. RMODE fields
    and   w14, w13, #0x07
    cbnz  w14, .Lslow_vfpdp         // LEN != 0: vector mode -> slow
    and   w14, w13, #0xC0
    cbnz  w14, .Lslow_vfpdp         // RMODE != RN -> slow (host FPCR is RN)
    tbnz  w10, #8, .Lvfpdp_d

// ---- single precision ---------------------------------------------------
.Lvfpdp_s:
    ubfx  w12, w10, #20, #4
    bic   w12, w12, #4              // fop bits {23,21,20} (inst bit22 drops)
    ubfx  w13, w10, #6, #1
    orr   w12, w12, w13, lsl #2     // FOP index: 0-8 binary, 15 = FOP_EXT
    sub   w13, w12, #15
    cbz   w13, .Lvfpdp_s_ext
    sub   w13, w12, #9
    tbz   w13, #31, .Lslow_vfpdp    // idx 9-14: unreachable encodings
    adr   x14, .Lvfpdp_s_tab
    ldr   w15, [x14, w12, uxtw #2]
    add   x15, x14, w15, sxtw
    br    x15

.Ls_fmac:
    VFPMAC_S mac
.Ls_fmsc:
    VFPMAC_S msc
.Ls_fnmac:
    VFPMAC_S nmac
.Ls_fnmsc:
    VFPMAC_S nmsc
.Ls_fmul:
    VFPLD_S
    msr   fpsr, xzr
    fmul  s2, s0, s1
    VFPST_S
.Ls_fnmul:
    VFPLD_S
    msr   fpsr, xzr
    fmul  s2, s0, s1
    fneg  s2, s2
    VFPST_S
.Ls_fadd:
    VFPLD_S
    msr   fpsr, xzr
    fadd  s2, s0, s1
    VFPST_S
.Ls_fsub:
    VFPLD_S
    msr   fpsr, xzr
    fsub  s2, s0, s1
    VFPST_S
.Ls_fdiv:
    VFPLD_S
    msr   fpsr, xzr
    fdiv  s2, s0, s1
    VFPST_S

// ---- single-precision extension ops -------------------------------------
.Lvfpdp_s_ext:
    ubfx  w12, w10, #15, #5
    and   w12, w12, #0x1E           // FEXT index bits (inst>>15)&0x1E
    ubfx  w13, w10, #7, #1
    orr   w12, w12, w13             // 0-31
    adr   x14, .Lvfpdp_s_ext_tab
    ldr   w15, [x14, w12, uxtw #2]
    add   x15, x14, w15, sxtw
    br    x15

.Ls_fcpy:                           // FCPY: raw copy, no domain check
    ubfx  w12, w11, #10, #5
    ldr   w13, [x22, w12, uxtw #2]
    and   w14, w11, #0x1F
    str   w13, [x22, w14, uxtw #2]
    NEXT_A
.Ls_fabs:
    ubfx  w12, w11, #10, #5
    ldr   w13, [x22, w12, uxtw #2]
    and   w13, w13, #0x7FFFFFFF
    and   w14, w11, #0x1F
    str   w13, [x22, w14, uxtw #2]
    NEXT_A
.Ls_fneg:
    ubfx  w12, w11, #10, #5
    ldr   w13, [x22, w12, uxtw #2]
    eor   w13, w13, #0x80000000
    and   w14, w11, #0x1F
    str   w13, [x22, w14, uxtw #2]
    NEXT_A
.Ls_fsqrt:
    ubfx  w12, w11, #10, #5
    ldr   w13, [x22, w12, uxtw #2]
    VFPDOM32 w13, w15
    fmov  s0, w13
    msr   fpsr, xzr
    fsqrt s2, s0
    VFPST_S
.Ls_fcmp:                           // FCMP/FCMPE: sd vs sm -> FPSCR NZCV
    and   w12, w11, #0x1F
    ldr   w13, [x22, w12, uxtw #2]  // d operand
    VFPDOM32 w13, w15
    ubfx  w12, w11, #10, #5
    ldr   w14, [x22, w12, uxtw #2]  // m operand
    VFPDOM32 w14, w15
    fmov  s0, w13
    fmov  s1, w14
    mrs   x16, nzcv                 // preserve guest flags across fcmp
    fcmp  s0, s1
    mrs   x15, nzcv                 // host compare flags == guest NZCV
    msr   nzcv, x16
    b     .Lvfpdp_cmp_store
.Ls_fcmpz:                          // FCMPZ/FCMPEZ: sd vs +0.0
    and   w12, w11, #0x1F
    ldr   w13, [x22, w12, uxtw #2]
    VFPDOM32 w13, w15
    fmov  s0, w13
    mrs   x16, nzcv
    fcmp  s0, #0.0
    mrs   x15, nzcv
    msr   nzcv, x16
    b     .Lvfpdp_cmp_store
.Ls_fcvtd:                          // FCVTD: s -> d widening, exact
    ubfx  w12, w11, #10, #5
    ldr   w13, [x22, w12, uxtw #2]
    VFPDOM32 w13, w15
    fmov  s0, w13
    fcvt  d2, s0
    fmov  x12, d2
    ubfx  w16, w11, #15, #5         // dd
    str   x12, [x22, w16, uxtw #3]
    NEXT_A
.Ls_fuito:                          // FUITO: u32 in sm -> float sd
    ubfx  w12, w11, #10, #5
    ldr   w13, [x22, w12, uxtw #2]
    msr   fpsr, xzr
    ucvtf s2, w13
    fmov  w12, s2
    mrs   x15, fpsr
    b     .Lvfpdp_store_s
.Ls_fsito:                          // FSITO: s32 -> float sd
    ubfx  w12, w11, #10, #5
    ldr   w13, [x22, w12, uxtw #2]
    msr   fpsr, xzr
    scvtf s2, w13
    fmov  w12, s2
    mrs   x15, fpsr
    b     .Lvfpdp_store_s
.Ls_ftouiz:                         // FTOUIZ: float sm -> u32 sd (RZ)
    ubfx  w12, w11, #10, #5
    ldr   w13, [x22, w12, uxtw #2]
    VFPDOM32 w13, w15
    tbz   w13, #31, 1f              // sign clear: fine
    lsl   w14, w13, #1
    cbnz  w14, .Lslow_vfpdp         // negative nonzero: saturation diverges
1:  fmov  s0, w13
    msr   fpsr, xzr
    fcvtzu w12, s0
    mrs   x15, fpsr
    b     .Lvfpdp_store_s
.Ls_ftosiz:                         // FTOSIZ: float sm -> s32 sd (RZ)
    ubfx  w12, w11, #10, #5
    ldr   w13, [x22, w12, uxtw #2]
    VFPDOM32 w13, w15
    fmov  s0, w13
    msr   fpsr, xzr
    fcvtzs w12, s0
    mrs   x15, fpsr
    b     .Lvfpdp_store_s

// ---- double precision ----------------------------------------------------
.Lvfpdp_d:
    ubfx  w12, w10, #20, #4
    bic   w12, w12, #4
    ubfx  w13, w10, #6, #1
    orr   w12, w12, w13, lsl #2
    sub   w13, w12, #15
    cbz   w13, .Lvfpdp_d_ext
    sub   w13, w12, #9
    tbz   w13, #31, .Lslow_vfpdp    // idx 9-14: unreachable encodings
    // Double MACs (idx 0,1,4,5) keep a wider internal product no host type
    // reproduces -> table maps them to slow, matching vfp_host.
    adr   x14, .Lvfpdp_d_tab
    ldr   w15, [x14, w12, uxtw #2]
    add   x15, x14, w15, sxtw
    br    x15

.Ld_fmul:
    VFPLD_D
    msr   fpsr, xzr
    fmul  d2, d0, d1
    VFPST_D
.Ld_fnmul:
    VFPLD_D
    msr   fpsr, xzr
    fmul  d2, d0, d1
    fneg  d2, d2
    VFPST_D
.Ld_fadd:
    VFPLD_D
    msr   fpsr, xzr
    fadd  d2, d0, d1
    VFPST_D
.Ld_fsub:
    VFPLD_D
    msr   fpsr, xzr
    fsub  d2, d0, d1
    VFPST_D
.Ld_fdiv:
    VFPLD_D
    msr   fpsr, xzr
    fdiv  d2, d0, d1
    VFPST_D

// ---- double-precision extension ops --------------------------------------
.Lvfpdp_d_ext:
    ubfx  w12, w10, #15, #5
    and   w12, w12, #0x1E
    ubfx  w13, w10, #7, #1
    orr   w12, w12, w13
    adr   x14, .Lvfpdp_d_ext_tab
    ldr   w15, [x14, w12, uxtw #2]
    add   x15, x14, w15, sxtw
    br    x15

.Ld_fcpy:                           // FCPYD: raw copy
    ubfx  w12, w11, #25, #5         // dm
    ldr   x13, [x22, w12, uxtw #3]
    ubfx  w14, w11, #15, #5         // dd
    str   x13, [x22, w14, uxtw #3]
    NEXT_A
.Ld_fabs:
    ubfx  w12, w11, #25, #5
    ldr   x13, [x22, w12, uxtw #3]
    and   x13, x13, #0x7FFFFFFFFFFFFFFF
    ubfx  w14, w11, #15, #5
    str   x13, [x22, w14, uxtw #3]
    NEXT_A
.Ld_fneg:
    ubfx  w12, w11, #25, #5
    ldr   x13, [x22, w12, uxtw #3]
    eor   x13, x13, #0x8000000000000000
    ubfx  w14, w11, #15, #5
    str   x13, [x22, w14, uxtw #3]
    NEXT_A
.Ld_fsqrt:
    ubfx  w12, w11, #25, #5
    ldr   x13, [x22, w12, uxtw #3]
    VFPDOM64 x13, x15
    fmov  d0, x13
    msr   fpsr, xzr
    fsqrt d2, d0
    VFPST_D
.Ld_fcmp:                           // FCMPD/FCMPED: dd vs dm -> FPSCR NZCV
    ubfx  w12, w11, #15, #5         // dd operand
    ldr   x13, [x22, w12, uxtw #3]
    VFPDOM64 x13, x15
    ubfx  w12, w11, #25, #5         // dm operand
    ldr   x14, [x22, w12, uxtw #3]
    VFPDOM64 x14, x15
    fmov  d0, x13
    fmov  d1, x14
    mrs   x16, nzcv
    fcmp  d0, d1
    mrs   x15, nzcv
    msr   nzcv, x16
    b     .Lvfpdp_cmp_store
.Ld_fcmpz:                          // FCMPZD/FCMPEZD: dd vs +0.0
    ubfx  w12, w11, #15, #5
    ldr   x13, [x22, w12, uxtw #3]
    VFPDOM64 x13, x15
    fmov  d0, x13
    mrs   x16, nzcv
    fcmp  d0, #0.0
    mrs   x15, nzcv
    msr   nzcv, x16
    b     .Lvfpdp_cmp_store
.Ld_fcvts:                          // FCVTS: d -> s narrowing, may raise
    ubfx  w12, w11, #25, #5         // dm
    ldr   x13, [x22, w12, uxtw #3]
    VFPDOM64 x13, x15
    fmov  d0, x13
    msr   fpsr, xzr
    fcvt  s2, d0
    fmov  w12, s2
    mrs   x15, fpsr
    VFPDOM32 w12, w16
    b     .Lvfpdp_store_s
.Ld_fuito:                          // FUITOD: u32 in sm -> double dd
    ubfx  w12, w11, #10, #5
    ldr   w13, [x22, w12, uxtw #2]
    msr   fpsr, xzr
    ucvtf d2, w13
    fmov  x12, d2
    mrs   x15, fpsr
    b     .Lvfpdp_store_d
.Ld_fsito:                          // FSITOD: s32 -> double dd
    ubfx  w12, w11, #10, #5
    ldr   w13, [x22, w12, uxtw #2]
    msr   fpsr, xzr
    scvtf d2, w13
    fmov  x12, d2
    mrs   x15, fpsr
    b     .Lvfpdp_store_d
.Ld_ftouiz:                         // FTOUIZD: double dm -> u32 sd
    ubfx  w12, w11, #25, #5
    ldr   x13, [x22, w12, uxtw #3]
    VFPDOM64 x13, x15
    tbz   x13, #63, 1f
    lsl   x14, x13, #1
    cbnz  x14, .Lslow_vfpdp         // negative nonzero -> slow
1:  fmov  d0, x13
    msr   fpsr, xzr
    fcvtzu w12, d0
    mrs   x15, fpsr
    b     .Lvfpdp_store_s
.Ld_ftosiz:                         // FTOSIZD: double dm -> s32 sd
    ubfx  w12, w11, #25, #5
    ldr   x13, [x22, w12, uxtw #3]
    VFPDOM64 x13, x15
    fmov  d0, x13
    msr   fpsr, xzr
    fcvtzs w12, d0
    mrs   x15, fpsr
    b     .Lvfpdp_store_s

// ---- shared tails --------------------------------------------------------
.Lvfpdp_store_s:                    // w12 = f32/int result, w15 = fpsr
    mov   w16, #0x9F                // FPSR cumulative-exception bits
    and   w15, w15, w16
    ldr   w16, [x22, #-24]
    orr   w16, w16, w15
    str   w16, [x22, #-24]
    and   w16, w11, #0x1F           // sd
    str   w12, [x22, w16, uxtw #2]
    NEXT_A
.Lvfpdp_store_d:                    // x12 = f64 result, w15 = fpsr
    mov   w16, #0x9F
    and   w15, w15, w16
    ldr   w16, [x22, #-24]
    orr   w16, w16, w15
    str   w16, [x22, #-24]
    ubfx  w16, w11, #15, #5         // dd
    str   x12, [x22, w16, uxtw #3]
    NEXT_A
.Lvfpdp_cmp_store:                  // x15 = host nzcv produced by fcmp
    ldr   w16, [x22, #-24]
    and   w16, w16, #0x0FFFFFFF     // keep non-NZCV fields
    and   w15, w15, #0xF0000000     // fcmp result is already NZCV-shaped
    orr   w16, w16, w15
    str   w16, [x22, #-24]
    NEXT_A
.Lslow_vfpdp:
    MEMSLOW

// ---- dispatch tables (entries are offsets from the table base) ------------
    .p2align 2
.Lvfpdp_s_tab:                      // FOP index -> single-precision body
    .word .Ls_fmac  - .Lvfpdp_s_tab // 0 FMAC
    .word .Ls_fmsc  - .Lvfpdp_s_tab // 1 FMSC
    .word .Ls_fmul  - .Lvfpdp_s_tab // 2 FMUL
    .word .Ls_fadd  - .Lvfpdp_s_tab // 3 FADD
    .word .Ls_fnmac - .Lvfpdp_s_tab // 4 FNMAC
    .word .Ls_fnmsc - .Lvfpdp_s_tab // 5 FNMSC
    .word .Ls_fnmul - .Lvfpdp_s_tab // 6 FNMUL
    .word .Ls_fsub  - .Lvfpdp_s_tab // 7 FSUB
    .word .Ls_fdiv  - .Lvfpdp_s_tab // 8 FDIV
.Lvfpdp_d_tab:                      // FOP index -> double-precision body
    .word .Lslow_vfpdp - .Lvfpdp_d_tab // 0 FMACD: no host equivalent
    .word .Lslow_vfpdp - .Lvfpdp_d_tab // 1 FMSCD
    .word .Ld_fmul  - .Lvfpdp_d_tab // 2 FMULD
    .word .Ld_fadd  - .Lvfpdp_d_tab // 3 FADDD
    .word .Lslow_vfpdp - .Lvfpdp_d_tab // 4 FNMACD
    .word .Lslow_vfpdp - .Lvfpdp_d_tab // 5 FNMSCD
    .word .Ld_fnmul - .Lvfpdp_d_tab // 6 FNMULD
    .word .Ld_fsub  - .Lvfpdp_d_tab // 7 FSUBD
    .word .Ld_fdiv  - .Lvfpdp_d_tab // 8 FDIVD
.Lvfpdp_s_ext_tab:                  // FEXT index -> single-precision body
    .word .Ls_fcpy      - .Lvfpdp_s_ext_tab // 0 FCPYS
    .word .Ls_fabs      - .Lvfpdp_s_ext_tab // 1 FABSS
    .word .Ls_fneg      - .Lvfpdp_s_ext_tab // 2 FNEGS
    .word .Ls_fsqrt     - .Lvfpdp_s_ext_tab // 3 FSQRTS
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 4
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 5
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 6
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 7
    .word .Ls_fcmp      - .Lvfpdp_s_ext_tab // 8 FCMPS
    .word .Ls_fcmp      - .Lvfpdp_s_ext_tab // 9 FCMPES
    .word .Ls_fcmpz     - .Lvfpdp_s_ext_tab // 10 FCMPZS
    .word .Ls_fcmpz     - .Lvfpdp_s_ext_tab // 11 FCMPEZS
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 12
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 13
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 14
    .word .Ls_fcvtd     - .Lvfpdp_s_ext_tab // 15 FCVTD s->d
    .word .Ls_fuito     - .Lvfpdp_s_ext_tab // 16 FUITOS
    .word .Ls_fsito     - .Lvfpdp_s_ext_tab // 17 FSITOS
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 18
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 19
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 20
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 21
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 22
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 23
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 24 FTOUI (needs rmode==RZ)
    .word .Ls_ftouiz    - .Lvfpdp_s_ext_tab // 25 FTOUIZS
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 26 FTOSI (needs rmode==RZ)
    .word .Ls_ftosiz    - .Lvfpdp_s_ext_tab // 27 FTOSIZS
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 28
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 29
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 30
    .word .Lslow_vfpdp  - .Lvfpdp_s_ext_tab // 31
.Lvfpdp_d_ext_tab:                  // FEXT index -> double-precision body
    .word .Ld_fcpy      - .Lvfpdp_d_ext_tab // 0 FCPYD
    .word .Ld_fabs      - .Lvfpdp_d_ext_tab // 1 FABSD
    .word .Ld_fneg      - .Lvfpdp_d_ext_tab // 2 FNEGD
    .word .Ld_fsqrt     - .Lvfpdp_d_ext_tab // 3 FSQRTD
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 4
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 5
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 6
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 7
    .word .Ld_fcmp      - .Lvfpdp_d_ext_tab // 8 FCMPD
    .word .Ld_fcmp      - .Lvfpdp_d_ext_tab // 9 FCMPED
    .word .Ld_fcmpz     - .Lvfpdp_d_ext_tab // 10 FCMPZD
    .word .Ld_fcmpz     - .Lvfpdp_d_ext_tab // 11 FCMPEZD
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 12
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 13
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 14
    .word .Ld_fcvts     - .Lvfpdp_d_ext_tab // 15 FCVTS d->s
    .word .Ld_fuito     - .Lvfpdp_d_ext_tab // 16 FUITOD
    .word .Ld_fsito     - .Lvfpdp_d_ext_tab // 17 FSITOD
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 18
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 19
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 20
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 21
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 22
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 23
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 24 FTOUID (needs rmode==RZ)
    .word .Ld_ftouiz    - .Lvfpdp_d_ext_tab // 25 FTOUIZD
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 26 FTOSID (needs rmode==RZ)
    .word .Ld_ftosiz    - .Lvfpdp_d_ext_tab // 27 FTOSIZD
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 28
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 29
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 30
    .word .Lslow_vfpdp  - .Lvfpdp_d_ext_tab // 31

// ---------------------------------------------------------------------------
// VFP register moves (ArmVFPDataProcessing[Always] modes 1 and 2).
// VMOVI writes a decoded constant, VMOVR copies register bits -- neither can
// raise FP exceptions nor depend on rounding, so the whole space is exact.
//   a0 = d | m<<5 | single<<10 | is_imm<<11
//   a1 = immediate (VMOVI only)
//   a2 = C++ op index
// Double forms act on the ExtReg word pair: low word = 2d, high = 2d+1.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_vfpmov
citra_asm_op_vfpmov:
    ldp   x10, x11, [x9, #AR0]          // packed | imm-or-m
    and   w12, w10, #0x1F               // d
    tbz   w10, #11, 1f
    // VMOVI
    tbz   w10, #10, 2f
    str   w11, [x22, w12, uxtw #2]      // single: ExtReg[d] = imm
    NEXT_A
2:  add   x12, x22, w12, uxtw #3
    stp   wzr, w11, [x12]               // double: ExtReg[2d]=0, [2d+1]=imm
    NEXT_A
1:  // VMOVR
    ubfx  w13, w10, #5, #5              // m
    tbz   w10, #10, 3f
    ldr   w14, [x22, w13, uxtw #2]      // single: ExtReg[d] = ExtReg[m]
    str   w14, [x22, w12, uxtw #2]
    NEXT_A
3:  add   x13, x22, w13, uxtw #3        // double: word-pair copy
    add   x12, x22, w12, uxtw #3
    ldr   x14, [x13]
    str   x14, [x12]
    NEXT_A

// ---------------------------------------------------------------------------
// Shifted-immediate MOVS (ArmMoveShiftedRegisterSetFlagsAlways, op92).
// a0 = rd | rm<<8, a1 = shift_type | shift_imm<<8.
// Guest flags land in host NZCV: N/Z from the shifted value, C = shifter
// carry, V preserved from the old flags word.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_movs_shift
citra_asm_op_movs_shift:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4              // rm
    ldr   w12, [x25, w12, uxtw #2]
    lsr   w14, w11, #8                  // shift_imm
    and   w11, w11, #3                  // shift_type
    mrs   x15, nzcv                     // old flags (V keep; C feeds RRX/LSL#0)
    cbz   w14, .Lms_imm0
    cmp   w11, #1
    b.eq  .Lms_lsr
    b.lo  .Lms_lsl
    cmp   w11, #2
    b.eq  .Lms_asr
    // ROR #n: value = ror(rm,n), C = rm bit (n-1)
    sub   w16, w14, #1
    lsr   w16, w12, w16
    and   w16, w16, #1
    ror   w13, w12, w14
    b     .Lms_compose
.Lms_lsl:
    mov   w16, #32
    sub   w16, w16, w14
    lsr   w16, w12, w16
    and   w16, w16, #1                  // C = rm bit (32-n)
    lsl   w13, w12, w14
    b     .Lms_compose
.Lms_lsr:
    sub   w16, w14, #1
    lsr   w16, w12, w16
    and   w16, w16, #1                  // C = rm bit (n-1)
    lsr   w13, w12, w14
    b     .Lms_compose
.Lms_asr:
    sub   w16, w14, #1
    lsr   w16, w12, w16
    and   w16, w16, #1
    asr   w13, w12, w14
    b     .Lms_compose
.Lms_imm0:
    cmp   w11, #1
    b.eq  .Lms_lsr0
    b.lo  .Lms_lsl0
    cmp   w11, #2
    b.eq  .Lms_asr0
    // RRX: value = (oldC << 31) | (rm >> 1), C = rm bit 0
    lsr   w13, w12, #1
    ubfx  w16, w15, #29, #1
    orr   w13, w13, w16, lsl #31
    and   w16, w12, #1
    b     .Lms_compose
.Lms_lsl0:
    mov   w13, w12                      // value = rm, C preserved
    ubfx  w16, w15, #29, #1
    b     .Lms_compose
.Lms_lsr0:
    mov   w13, #0                       // value = 0, C = rm bit 31
    lsr   w16, w12, #31
    b     .Lms_compose
.Lms_asr0:
    asr   w13, w12, #31                 // value = sign-fill
    lsr   w16, w12, #31
.Lms_compose:
    and   w17, w10, #0xF                // rd
    str   w13, [x25, w17, uxtw #2]
    and   w17, w13, #0x80000000         // N
    cbnz  w13, 1f
    orr   w17, w17, #0x40000000         // Z
1:  orr   w17, w17, w16, lsl #29        // C
    and   w15, w15, #0x10000000         // V preserved
    orr   w17, w17, w15
    msr   nzcv, x17
    orr   x20, x20, #0x100000000
    NEXT_A

// ---------------------------------------------------------------------------
// MoveImmediateSetFlags (ArmMoveImmediateSetFlagsAlways, op296): rd := a1.
// a0 = rd | shifter_carry<<8 | shifter_carry_from_c_flag<<9, a1 = imm value.
// N/Z from the value; C = from_c_flag ? old C : shifter_carry; V preserved.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_movs_imm
citra_asm_op_movs_imm:
    ldp   x10, x11, [x9, #AR0]
    mrs   x15, nzcv
    ubfx  w16, w10, #8, #1              // shifter carry
    tbz   w10, #9, 1f
    ubfx  w16, w15, #29, #1             // from_c_flag -> keep old C
1:  and   w17, w10, #0xF                // rd
    str   w11, [x25, w17, uxtw #2]
.Lmovi_s_flags:                         // shared tail: w11 value, w16 C, x15 old NZCV
    and   w17, w11, #0x80000000         // N
    cbnz  w11, 2f
    orr   w17, w17, #0x40000000         // Z
2:  orr   w17, w17, w16, lsl #29        // C
    and   w15, w15, #0x10000000         // V preserved
    orr   w17, w17, w15
    msr   nzcv, x17
    orr   x20, x20, #0x100000000
    NEXT_A

// ---------------------------------------------------------------------------
// Carry-arithmetic with immediate-shifted operand, no flags
// (ArmArithmeticShiftedRegisterNoPcAlways, op198): ADC/SBC/RSC/RSB.
// a0 = data_opcode | rd<<8 | rn<<12 | rm<<16, a1 = shift_type | shift_imm<<8.
// Plain adds/subs keep host NZCV holding the guest flags; the carry-in is
// sampled with mrs before any flag-writing op.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_carith_shift
citra_asm_op_carith_shift:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #16, #4             // rm
    ldr   w12, [x25, w12, uxtw #2]
    lsr   w14, w11, #8                  // shift_imm
    and   w11, w11, #3                  // shift_type
    mrs   x15, nzcv
    ubfx  w16, w15, #29, #1             // old C (RRX input + ADC/SBC/RSC)
    // NOTE: this handler must keep host NZCV untouched -- it is a no-flags
    // guest op and host NZCV still holds the live guest flags. All dispatch
    // below uses only flag-free insns (cbz/tbz/logical/shifts/adds).
    cbz   w14, .Lca_imm0
    tbz   w11, #1, .Lca_shift01
    tbz   w11, #0, .Lca_asr
    ror   w13, w12, w14
    b     .Lca_op
.Lca_shift01:
    tbz   w11, #0, .Lca_lsl
    lsr   w13, w12, w14
    b     .Lca_op
.Lca_lsl:
    lsl   w13, w12, w14
    b     .Lca_op
.Lca_asr:
    asr   w13, w12, w14
    b     .Lca_op
.Lca_imm0:
    tbz   w11, #1, .Lca_imm0_01
    tbz   w11, #0, .Lca_asr0
    lsr   w13, w12, #1                  // RRX
    orr   w13, w13, w16, lsl #31
    b     .Lca_op
.Lca_imm0_01:
    tbz   w11, #0, .Lca_lsl0
    mov   w13, #0                       // LSR #32
    b     .Lca_op
.Lca_lsl0:
    mov   w13, w12
    b     .Lca_op
.Lca_asr0:
    asr   w13, w12, #31
.Lca_op:
    ubfx  w17, w10, #12, #4             // rn
    ldr   w17, [x25, w17, uxtw #2]
    and   w14, w10, #0xF                // data_opcode in {3,5,6,7}
    tbz   w14, #0, .Lca_sbc             // even -> SBC(6)
    tbz   w14, #2, .Lca_rsb             // 3 -> RSB
    tbz   w14, #1, .Lca_adc             // 5 -> ADC; 7 falls through -> RSC
    mvn   w17, w17                      // RSC (7): shifted + ~rn + C
    add   w13, w13, w17
    add   w13, w13, w16
    b     .Lca_store
.Lca_rsb:                               // RSB (3): shifted - rn
    sub   w13, w13, w17
    b     .Lca_store
.Lca_adc:                               // rn + shifted + C
    add   w13, w13, w17
    add   w13, w13, w16
    b     .Lca_store
.Lca_sbc:                               // rn + ~shifted + C
    mvn   w13, w13
    add   w13, w17, w13
    add   w13, w13, w16
.Lca_store:
    ubfx  w14, w10, #8, #4              // rd
    str   w13, [x25, w14, uxtw #2]
    NEXT_A

// ---------------------------------------------------------------------------
// Logical op with register-amount shifted operand + flags
// (ArmLogicalRegisterShiftedRegisterSetFlagsNoPcAlways, op207).
// a0 = data_opcode, a1 = rd | rn<<8 | rm<<16 | rs<<24, a2 = shift_type.
// Shift amount = Reg[rs] & 0xFF with the ARM register-shift saturation rules.
// Flags: N/Z from result, C = shifter carry, V preserved. TST/TEQ skip the
// rd write.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_logregs_s
citra_asm_op_logregs_s:
    ldp   x10, x11, [x9, #AR0]
    ldr   w14, [x9, #AR2]               // shift_type
    ubfx  w12, w11, #16, #4             // rm
    ldr   w12, [x25, w12, uxtw #2]      // rm value
    ubfx  w13, w11, #24, #4             // rs
    ldr   w13, [x25, w13, uxtw #2]
    and   w13, w13, #0xFF               // shift_amount
    mrs   x15, nzcv                     // old flags
    cbnz  w13, 1f
    mov   w16, w12                      // amount==0: value = rm
    ubfx  w17, w15, #29, #1             // C preserved
    b     .Llrs_have
1:  and   w14, w14, #3
    cmp   w14, #1
    b.eq  .Llrs_lsr
    b.lo  .Llrs_lsl
    cmp   w14, #2
    b.eq  .Llrs_asr
    // ROR: rotate = amount & 31
    and   w17, w13, #31
    cbnz  w17, 2f
    mov   w16, w12                      // rotate==0: value = rm
    lsr   w17, w12, #31                 // C = rm bit 31
    b     .Llrs_have
2:  ror   w16, w12, w17
    sub   w13, w17, #1
    lsr   w17, w12, w13
    and   w17, w17, #1
    b     .Llrs_have
.Llrs_lsl:
    cmp   w13, #32
    b.hs  3f
    mov   w16, #32
    sub   w17, w16, w13
    lsr   w17, w12, w17
    and   w17, w17, #1
    lsl   w16, w12, w13
    b     .Llrs_have
3:  mov   w16, #0
    mov   w17, #0
    cmp   w13, #32
    b.ne  .Llrs_have
    and   w17, w12, #1                  // amount==32: C = rm bit 0
    b     .Llrs_have
.Llrs_lsr:
    cmp   w13, #32
    b.hs  4f
    sub   w17, w13, #1
    lsr   w17, w12, w17
    and   w17, w17, #1
    lsr   w16, w12, w13
    b     .Llrs_have
4:  mov   w16, #0
    mov   w17, #0
    cmp   w13, #32
    b.ne  .Llrs_have
    lsr   w17, w12, #31                 // amount==32: C = rm bit 31
    b     .Llrs_have
.Llrs_asr:
    cmp   w13, #32
    b.hs  5f
    sub   w17, w13, #1
    lsr   w17, w12, w17
    and   w17, w17, #1
    asr   w16, w12, w13
    b     .Llrs_have
5:  asr   w16, w12, #31                 // value = sign-fill
    lsr   w17, w12, #31
.Llrs_have:
    // w16 = shifted operand, w17 = shifter carry, w15 = old flags
    ubfx  w13, w11, #8, #4              // rn
    ldr   w13, [x25, w13, uxtw #2]
    and   w14, w10, #0xF                // data_opcode
    cmp   w14, #1
    b.eq  .Llrs_eor
    cmp   w14, #8
    b.eq  .Llrs_tst
    cmp   w14, #9
    b.eq  .Llrs_teq
    cmp   w14, #12
    b.eq  .Llrs_orr
    cmp   w14, #13
    b.eq  .Llrs_mov
    cmp   w14, #14
    b.eq  .Llrs_bic
    cmp   w14, #15
    b.eq  .Llrs_mvn
    and   w14, w13, w16                 // AND (0)
    b     .Llrs_res
.Llrs_eor:
    eor   w14, w13, w16
    b     .Llrs_res
.Llrs_tst:
    and   w14, w13, w16
    b     .Llrs_flags
.Llrs_teq:
    eor   w14, w13, w16
    b     .Llrs_flags
.Llrs_orr:
    orr   w14, w13, w16
    b     .Llrs_res
.Llrs_mov:
    mov   w14, w16
    b     .Llrs_res
.Llrs_bic:
    bic   w14, w13, w16
    b     .Llrs_res
.Llrs_mvn:
    mvn   w14, w16
.Llrs_res:
    and   w13, w11, #0xF                // rd
    str   w14, [x25, w13, uxtw #2]
.Llrs_flags:
    and   w13, w14, #0x80000000         // N
    cbnz  w14, 1f
    orr   w13, w13, #0x40000000         // Z
1:  orr   w13, w13, w17, lsl #29        // C = shifter carry
    and   w15, w15, #0x10000000         // V preserved
    orr   w13, w13, w15
    msr   nzcv, x13
    orr   x20, x20, #0x100000000
    NEXT_A

// ---------------------------------------------------------------------------
// Fused add/sub-immediate set-flags + conditional branch
// (ArmAddSubImmediateSetFlagsBranchNoPcAlways, op218).
// a0 = rd | rn<<4 | subtract<<8 | fused_guest_size<<16
// a1 = imm, a2 = taken record, a3 = taken pc. Host adds/subs produce the
// exact NZCV the guest needs (incl. the imm==0 carry corner).
// ---------------------------------------------------------------------------
.macro ASIBRA chain, cond
    .globl citra_asm_op_asibra\chain\()_\cond
citra_asm_op_asibra\chain\()_\cond:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #16, #8             // fused guest size
    ubfx  w13, w10, #4, #4              // rn
    ldr   w13, [x25, w13, uxtw #2]
    tbnz  w10, #8, 1f
    adds  w14, w13, w11
    b     2f
1:  subs  w14, w13, w11
2:  and   w15, w10, #0xF                // rd
    str   w14, [x25, w15, uxtw #2]
    orr   x20, x20, #0x100000000
    b.\cond 3f
    add   w28, w28, w12
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
3:  ldp   x10, x11, [x9, #AR2]
    mov   w28, w11
    add   x20, x20, #2
.ifc \chain,chain
    ldr   w17, [x9, #AR0]
    lsr   w17, w17, #24            // block guest-instruction count
    ldr   w16, [x19, #ASMCTX_BUDGET]
    sub   w16, w16, w20
    sub   w16, w16, w17
    tbz   w16, #31, 88f
    b     .Lasm_budget_exit
88:
.endif
    mov   x9, x10
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.endm

ASIBRA ,eq
ASIBRA ,ne
ASIBRA ,cs
ASIBRA ,cc
ASIBRA ,mi
ASIBRA ,pl
ASIBRA ,vs
ASIBRA ,vc
ASIBRA ,hi
ASIBRA ,ls
ASIBRA ,ge
ASIBRA ,lt
ASIBRA ,gt
ASIBRA ,le
ASIBRA chain,eq
ASIBRA chain,ne
ASIBRA chain,cs
ASIBRA chain,cc
ASIBRA chain,mi
ASIBRA chain,pl
ASIBRA chain,vs
ASIBRA chain,vc
ASIBRA chain,hi
ASIBRA chain,ls
ASIBRA chain,ge
ASIBRA chain,lt
ASIBRA chain,gt
ASIBRA chain,le

// ---------------------------------------------------------------------------
// Fused add/sub-register set-flags + conditional branch
// (ArmAddSubRegisterSetFlagsBranchNoPcAlways, op219).
// a0 = rd | rn<<4 | rm<<8 | sub<<12 | fused_guest_size<<16 | block_instrs<<24
// a2 = taken record, a3 = taken pc.
// ---------------------------------------------------------------------------
.macro ASRBRA chain, cond
    .globl citra_asm_op_asrbra\chain\()_\cond
citra_asm_op_asrbra\chain\()_\cond:
    ldr   w10, [x9, #AR0]
    ubfx  w12, w10, #16, #8             // fused guest size
    ubfx  w13, w10, #4, #4              // rn
    ldr   w13, [x25, w13, uxtw #2]
    ubfx  w14, w10, #8, #4              // rm
    ldr   w14, [x25, w14, uxtw #2]
    tbnz  w10, #12, 1f
    adds  w14, w13, w14
    b     2f
1:  subs  w14, w13, w14
2:  and   w15, w10, #0xF                // rd
    str   w14, [x25, w15, uxtw #2]
    orr   x20, x20, #0x100000000
    b.\cond 3f
    add   w28, w28, w12
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
3:  ldp   x10, x11, [x9, #AR2]
    mov   w28, w11
    add   x20, x20, #2
.ifc \chain,chain
    ldr   w17, [x9, #AR0]
    lsr   w17, w17, #24            // block guest-instruction count
    ldr   w16, [x19, #ASMCTX_BUDGET]
    sub   w16, w16, w20
    sub   w16, w16, w17
    tbz   w16, #31, 88f
    b     .Lasm_budget_exit
88:
.endif
    mov   x9, x10
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.endm

ASRBRA ,eq
ASRBRA ,ne
ASRBRA ,cs
ASRBRA ,cc
ASRBRA ,mi
ASRBRA ,pl
ASRBRA ,vs
ASRBRA ,vc
ASRBRA ,hi
ASRBRA ,ls
ASRBRA ,ge
ASRBRA ,lt
ASRBRA ,gt
ASRBRA ,le
ASRBRA chain,eq
ASRBRA chain,ne
ASRBRA chain,cs
ASRBRA chain,cc
ASRBRA chain,mi
ASRBRA chain,pl
ASRBRA chain,vs
ASRBRA chain,vc
ASRBRA chain,hi
ASRBRA chain,ls
ASRBRA chain,ge
ASRBRA chain,lt
ASRBRA chain,gt
ASRBRA chain,le

// ---------------------------------------------------------------------------
// Fused cmp/cmn shifted-register + conditional branch
// (ArmCompareShiftedRegisterBranchNoPcAlways, op212).
// a0 = rn | rm<<4 | cmn<<8 | fused_guest_size<<16 | block_instrs<<24
// a1 = shift_type | shift_imm<<8, a2 = taken record, a3 = taken pc.
// The shift tree is flag-free so the only NZCV write is the compare itself;
// RRX reuses the live guest C captured before it.
// ---------------------------------------------------------------------------
.macro CMPSBRA chain, cond
    .globl citra_asm_op_cmpsbra\chain\()_\cond
citra_asm_op_cmpsbra\chain\()_\cond:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #4, #4              // rm
    ldr   w12, [x25, w12, uxtw #2]
    lsr   w14, w11, #8                  // shift_imm
    and   w11, w11, #3                  // shift_type
    mrs   x15, nzcv
    ubfx  w16, w15, #29, #1             // old C (RRX input)
    cbz   w14, 40f
    tbz   w11, #1, 41f
    tbz   w11, #0, 43f
    ror   w13, w12, w14
    b     50f
41: tbz   w11, #0, 42f
    lsr   w13, w12, w14
    b     50f
42: lsl   w13, w12, w14
    b     50f
43: asr   w13, w12, w14
    b     50f
40: tbz   w11, #1, 44f
    tbz   w11, #0, 45f
    lsr   w13, w12, #1                  // RRX
    orr   w13, w13, w16, lsl #31
    b     50f
44: tbz   w11, #0, 46f
    mov   w13, #0                       // LSR #32
    b     50f
46: mov   w13, w12                      // LSL #0
    b     50f
45: asr   w13, w12, #31                 // ASR #32
50: and   w17, w10, #0xF                // rn
    ldr   w17, [x25, w17, uxtw #2]
    tbnz  w10, #8, 51f
    subs  wzr, w17, w13
    b     52f
51: adds  wzr, w17, w13
52: orr   x20, x20, #0x100000000
    b.\cond 60f
    ubfx  w11, w10, #16, #8             // fused guest size
    add   w28, w28, w11
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
60: ldp   x10, x11, [x9, #AR2]
    mov   w28, w11
    add   x20, x20, #2
.ifc \chain,chain
    ldr   w17, [x9, #AR0]
    lsr   w17, w17, #24            // block guest-instruction count
    ldr   w16, [x19, #ASMCTX_BUDGET]
    sub   w16, w16, w20
    sub   w16, w16, w17
    tbz   w16, #31, 61f
    b     .Lasm_budget_exit
61:
.endif
    mov   x9, x10
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.endm

CMPSBRA ,eq
CMPSBRA ,ne
CMPSBRA ,cs
CMPSBRA ,cc
CMPSBRA ,mi
CMPSBRA ,pl
CMPSBRA ,vs
CMPSBRA ,vc
CMPSBRA ,hi
CMPSBRA ,ls
CMPSBRA ,ge
CMPSBRA ,lt
CMPSBRA ,gt
CMPSBRA ,le
CMPSBRA chain,eq
CMPSBRA chain,ne
CMPSBRA chain,cs
CMPSBRA chain,cc
CMPSBRA chain,mi
CMPSBRA chain,pl
CMPSBRA chain,vs
CMPSBRA chain,vc
CMPSBRA chain,hi
CMPSBRA chain,ls
CMPSBRA chain,ge
CMPSBRA chain,lt
CMPSBRA chain,gt
CMPSBRA chain,le

// ---------------------------------------------------------------------------
// Fused adc/sbc/rsc/rsb shifted-register set-flags + conditional branch
// (ArmCarryArithmeticShiftedRegisterSetFlagsBranchNoPcAlways, op228).
// a0 = data_opcode | rd<<4 | rn<<8 | rm<<12 | fused_guest_size<<16 |
//      block_instrs<<24, a1 = shift_type | shift_imm<<8,
// a2 = taken record, a3 = taken pc.
// The shift tree is flag-free; the guest carry-in lives in the host C flag
// captured by the early mrs and restored via msr before the flag-setting op.
// RRX (shift_type==3, imm==0) reuses that captured C.
// ---------------------------------------------------------------------------
.macro CASRBRA chain, cond
    .globl citra_asm_op_casrbra\chain\()_\cond
citra_asm_op_casrbra\chain\()_\cond:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #12, #4             // rm
    ldr   w12, [x25, w12, uxtw #2]
    lsr   w14, w11, #8                  // shift_imm
    and   w11, w11, #3                  // shift_type
    mrs   x15, nzcv
    ubfx  w16, w15, #29, #1             // old C (RRX input)
    cbz   w14, 40f
    tbz   w11, #1, 41f
    tbz   w11, #0, 43f
    ror   w13, w12, w14
    b     50f
41: tbz   w11, #0, 42f
    lsr   w13, w12, w14
    b     50f
42: lsl   w13, w12, w14
    b     50f
43: asr   w13, w12, w14
    b     50f
40: tbz   w11, #1, 44f
    tbz   w11, #0, 45f
    lsr   w13, w12, #1                  // RRX
    orr   w13, w13, w16, lsl #31
    b     50f
44: tbz   w11, #0, 46f
    mov   w13, #0                       // LSR #32
    b     50f
46: mov   w13, w12                      // LSL #0
    b     50f
45: asr   w13, w12, #31                 // ASR #32
50: ubfx  w17, w10, #8, #4              // rn
    ldr   w17, [x25, w17, uxtw #2]
    and   w12, w10, #0xF                // data_opcode (w18 stays resident r2)
    cmp   w12, #5
    b.eq  63f
    b.hs  64f
    // rsb: operand + ~rn + 1  (carry-in forced, C input unused)
    mvn   w17, w17
    orr   w15, w15, #(1 << 29)
    msr   nzcv, x15
    adcs  w14, w13, w17
    b     70f
63: // adc: rn + operand + C
    msr   nzcv, x15
    adcs  w14, w17, w13
    b     70f
64: cmp   w12, #6
    b.ne  65f
    // sbc: rn + ~operand + C
    mvn   w13, w13
    msr   nzcv, x15
    adcs  w14, w17, w13
    b     70f
65: // rsc: operand + ~rn + C
    mvn   w17, w17
    msr   nzcv, x15
    adcs  w14, w13, w17
70: ubfx  w17, w10, #4, #4              // rd (a0 bits4-7; bits0-3 = data_op)
    str   w14, [x25, w17, uxtw #2]
    orr   x20, x20, #0x100000000
    b.\cond 71f
    ubfx  w11, w10, #16, #8             // fused guest size
    add   w28, w28, w11
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
71: ldp   x10, x11, [x9, #AR2]
    mov   w28, w11
    add   x20, x20, #2
.ifc \chain,chain
    ldr   w17, [x9, #AR0]
    lsr   w17, w17, #24            // block guest-instruction count
    ldr   w16, [x19, #ASMCTX_BUDGET]
    sub   w16, w16, w20
    sub   w16, w16, w17
    tbz   w16, #31, 72f
    b     .Lasm_budget_exit
72:
.endif
    mov   x9, x10
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.endm

CASRBRA ,eq
CASRBRA ,ne
CASRBRA ,cs
CASRBRA ,cc
CASRBRA ,mi
CASRBRA ,pl
CASRBRA ,vs
CASRBRA ,vc
CASRBRA ,hi
CASRBRA ,ls
CASRBRA ,ge
CASRBRA ,lt
CASRBRA ,gt
CASRBRA ,le
CASRBRA chain,eq
CASRBRA chain,ne
CASRBRA chain,cs
CASRBRA chain,cc
CASRBRA chain,mi
CASRBRA chain,pl
CASRBRA chain,vs
CASRBRA chain,vc
CASRBRA chain,hi
CASRBRA chain,ls
CASRBRA chain,ge
CASRBRA chain,lt
CASRBRA chain,gt
CASRBRA chain,le

// ---------------------------------------------------------------------------
// Fused rsb/adc/sbc/rsc rd, rn, rm (no shift) set-flags + conditional branch
// (ArmCarryArithmeticRegisterSetFlagsBranchNoPcAlways, op227).
// a0 = data_opcode | rd<<4 | rn<<8 | rm<<12 | fused_guest_size<<16 |
//      block_instrs<<24, a2 = taken record, a3 = taken pc.
// Same carry-in discipline as CASRBRA: mrs snapshots guest NZCV and msr
// restores it just before the flag-setting adcs.
// ---------------------------------------------------------------------------
.macro CARBRA chain, cond
    .globl citra_asm_op_carbra\chain\()_\cond
citra_asm_op_carbra\chain\()_\cond:
    ldr   w10, [x9, #AR0]
    ubfx  w13, w10, #12, #4             // rm
    ldr   w13, [x25, w13, uxtw #2]      // operand
    ubfx  w17, w10, #8, #4              // rn
    ldr   w17, [x25, w17, uxtw #2]
    mrs   x15, nzcv
    and   w12, w10, #0xF                // data_opcode
    cmp   w12, #5
    b.eq  63f
    b.hs  64f
    // rsb (3): operand + ~rn + 1 (carry-in forced, C input unused)
    mvn   w17, w17
    orr   w15, w15, #(1 << 29)
    msr   nzcv, x15
    adcs  w14, w13, w17
    b     70f
63: // adc (5): rn + operand + C
    msr   nzcv, x15
    adcs  w14, w17, w13
    b     70f
64: cmp   w12, #6
    b.ne  65f
    // sbc (6): rn + ~operand + C
    mvn   w13, w13
    msr   nzcv, x15
    adcs  w14, w17, w13
    b     70f
65: // rsc (7): operand + ~rn + C
    mvn   w17, w17
    msr   nzcv, x15
    adcs  w14, w13, w17
70: ubfx  w17, w10, #4, #4              // rd
    str   w14, [x25, w17, uxtw #2]
    orr   x20, x20, #0x100000000
    b.\cond 71f
    ubfx  w11, w10, #16, #8             // fused guest size
    add   w28, w28, w11
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
71: ldp   x10, x11, [x9, #AR2]
    mov   w28, w11
    add   x20, x20, #2
.ifc \chain,chain
    ldr   w17, [x9, #AR0]
    lsr   w17, w17, #24            // block guest-instruction count
    ldr   w16, [x19, #ASMCTX_BUDGET]
    sub   w16, w16, w20
    sub   w16, w16, w17
    tbz   w16, #31, 72f
    b     .Lasm_budget_exit
72:
.endif
    mov   x9, x10
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.endm

CARBRA ,eq
CARBRA ,ne
CARBRA ,cs
CARBRA ,cc
CARBRA ,mi
CARBRA ,pl
CARBRA ,vs
CARBRA ,vc
CARBRA ,hi
CARBRA ,ls
CARBRA ,ge
CARBRA ,lt
CARBRA ,gt
CARBRA ,le
CARBRA chain,eq
CARBRA chain,ne
CARBRA chain,cs
CARBRA chain,cc
CARBRA chain,mi
CARBRA chain,pl
CARBRA chain,vs
CARBRA chain,vc
CARBRA chain,hi
CARBRA chain,ls
CARBRA chain,ge
CARBRA chain,lt
CARBRA chain,gt
CARBRA chain,le

// ---------------------------------------------------------------------------
// Standalone rsb/adc/sbc/rsc rd, rn, rm, <shift> #imm, set flags
// (ArmArithmeticShiftedRegisterSetFlagsNoPcAlways, op199).
// a0 = data_opcode | shift_type<<8 | shift_imm<<16,
// a1 = rd | rn<<8 | rm<<16, a2 = C++ op index.
// Same carry-in discipline as CASRBRA: the early mrs snapshots guest NZCV
// and msr restores it just before the flag-setting add.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_carithsh_s
citra_asm_op_carithsh_s:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w11, #16, #4             // rm
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w14, w10, #16, #5             // shift_imm
    ubfx  w13, w10, #8, #2              // shift_type
    mrs   x15, nzcv
    ubfx  w16, w15, #29, #1             // old C (RRX input)
    cbz   w14, 40f
    tbz   w13, #1, 41f
    tbz   w13, #0, 43f
    ror   w13, w12, w14
    b     50f
41: tbz   w13, #0, 42f
    lsr   w13, w12, w14
    b     50f
42: lsl   w13, w12, w14
    b     50f
43: asr   w13, w12, w14
    b     50f
40: tbz   w13, #1, 44f
    tbz   w13, #0, 45f
    lsr   w13, w12, #1                  // RRX
    orr   w13, w13, w16, lsl #31
    b     50f
44: tbz   w13, #0, 46f
    mov   w13, #0                       // LSR #32
    b     50f
46: mov   w13, w12                      // LSL #0
    b     50f
45: asr   w13, w12, #31                 // ASR #32
50: ubfx  w17, w11, #8, #4              // rn
    ldr   w17, [x25, w17, uxtw #2]
    and   w12, w10, #0xF                // data_opcode (w18 stays resident r2)
    cmp   w12, #4
    b.eq  62f
    b.hs  66f
    cmp   w12, #3
    b.ne  61f
    // rsb: operand + ~rn + 1  (carry-in forced, C input unused)
    mvn   w17, w17
    orr   w15, w15, #(1 << 29)
    msr   nzcv, x15
    adcs  w14, w13, w17
    b     70f
61: // subs: rn + ~operand + 1  (carry-in forced to 1)
    mvn   w13, w13
    orr   w15, w15, #(1 << 29)
    msr   nzcv, x15
    adcs  w14, w17, w13
    b     70f
62: // adds: rn + operand  (all flags recomputed; carry-in unused)
    adds  w14, w17, w13
    b     70f
66: cmp   w12, #5
    b.eq  63f
    b.hs  64f
    // unreachable under current decode (data_opcode in {2..7})
    mov   w14, w17
    b     70f
63: // adc: rn + operand + C
    msr   nzcv, x15
    adcs  w14, w17, w13
    b     70f
64: cmp   w12, #6
    b.ne  65f
    // sbc: rn + ~operand + C
    mvn   w13, w13
    msr   nzcv, x15
    adcs  w14, w17, w13
    b     70f
65: // rsc: operand + ~rn + C
    mvn   w17, w17
    msr   nzcv, x15
    adcs  w14, w13, w17
70: and   w17, w11, #0xF                // rd
    str   w14, [x25, w17, uxtw #2]
    orr   x20, x20, #0x100000000
    NEXT_A

// ---------------------------------------------------------------------------
// Standalone cmp/cmn rn, rm, <shift> #imm
// (ArmCompareShiftedRegisterNoPcAlways / CompareNegative variant, op192/195).
// a0 = rn | rm<<8, a1 = shift_type | shift_imm<<8.
// Flag-free shift tree (RRX consumes the live guest C), then the compare
// writes host NZCV == guest flags.
// ---------------------------------------------------------------------------
.macro CMPSH name, insn
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4              // rm
    ldr   w12, [x25, w12, uxtw #2]
    lsr   w14, w11, #8                  // shift_imm
    and   w11, w11, #3                  // shift_type
    mrs   x15, nzcv
    ubfx  w16, w15, #29, #1             // old C (RRX input)
    cbz   w14, 40f
    tbz   w11, #1, 41f
    tbz   w11, #0, 43f
    ror   w13, w12, w14
    b     50f
41: tbz   w11, #0, 42f
    lsr   w13, w12, w14
    b     50f
42: lsl   w13, w12, w14
    b     50f
43: asr   w13, w12, w14
    b     50f
40: tbz   w11, #1, 44f
    tbz   w11, #0, 45f
    lsr   w13, w12, #1                  // RRX
    orr   w13, w13, w16, lsl #31
    b     50f
44: tbz   w11, #0, 46f
    mov   w13, #0                       // LSR #32
    b     50f
46: mov   w13, w12                      // LSL #0
    b     50f
45: asr   w13, w12, #31                 // ASR #32
50: and   w17, w10, #0xF                // rn
    ldr   w17, [x25, w17, uxtw #2]
    \insn wzr, w17, w13
    orr   x20, x20, #0x100000000
    NEXT_A
.endm

CMPSH cmp_shift, subs
CMPSH cmn_shift, adds

// ---------------------------------------------------------------------------
// Logical shifted-register set-flags
// (ArmLogicalShiftedRegisterSetFlagsNoPcAlways{Lsl,Lsr,Asr,Ror}, op230-233).
// a0 = data_opcode | shift_imm<<8, a1 = rd | rn<<8 | rm<<16,
// a2 = C++ op index. tst/teq are decoded to their own opcodes, so every
// data_opcode here writes rd. Flags: N/Z from result, C = shifter carry
// (old C for lsl#0 and the rrx input), V preserved.
// ---------------------------------------------------------------------------
.macro LOGSH_S name, st
    .globl citra_asm_op_\name
citra_asm_op_\name:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w11, #16, #4             // rm
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w14, w10, #8, #5              // shift_imm
    mrs   x15, nzcv
    ubfx  w16, w15, #29, #1             // old C (lsl#0 / rrx input)
.if \st == 0
    cbz   w14, 1f                       // lsl #0: operand = rm, carry = old C
    lsl   w13, w12, w14
    neg   w17, w14                      // lsr by (32 - n)
    lsr   w17, w12, w17
    and   w16, w17, #1                  // carry = rm bit(32-n)
    b     2f
1:  mov   w13, w12
    b     2f
.elseif \st == 1
    cbz   w14, 1f                       // lsr #0 -> lsr #32
    lsr   w13, w12, w14
    sub   w17, w14, #1
    lsr   w17, w12, w17
    and   w16, w17, #1                  // carry = rm bit(n-1)
    b     2f
1:  mov   w13, #0
    lsr   w16, w12, #31                 // carry = rm bit31
    b     2f
.elseif \st == 2
    cbz   w14, 1f                       // asr #0 -> asr #32
    asr   w13, w12, w14
    sub   w17, w14, #1
    lsr   w17, w12, w17
    and   w16, w17, #1
    b     2f
1:  asr   w13, w12, #31                 // sign-fill
    lsr   w16, w12, #31
    b     2f
.else
    cbz   w14, 1f                       // ror #0 -> rrx
    ror   w13, w12, w14
    lsr   w16, w13, #31                 // carry = result bit31
    b     2f
1:  and   w17, w12, #1                  // rrx carry = rm bit0
    lsr   w13, w12, #1
    orr   w13, w13, w16, lsl #31
    mov   w16, w17
    b     2f
.endif
2:  // w13 = shifted operand, w16 = shifter carry, x15 = old guest NZCV
    ubfx  w17, w11, #8, #4              // rn
    ldr   w17, [x25, w17, uxtw #2]
    and   w12, w10, #0xF                // data_opcode (w18 stays resident r2)
    cmp   w12, #12
    b.lo  3f                            // and/eor
    b.eq  4f                            // orr
    cmp   w12, #14
    b.eq  5f                            // bic
    b.lo  6f                            // mov
    mvn   w14, w13                      // mvn
    b     7f
6:  mov   w14, w13
    b     7f
5:  bic   w14, w17, w13
    b     7f
4:  orr   w14, w17, w13
    b     7f
3:  cmp   w12, #1
    b.eq  8f
    and   w14, w17, w13                 // and
    b     7f
8:  eor   w14, w17, w13                 // eor
7:  and   w17, w11, #0xF                // rd
    str   w14, [x25, w17, uxtw #2]
    and   w17, w14, #0x80000000         // N
    cmp   w14, #0                       // host Z only; x15 kept intact
    cset  w12, eq
    orr   w17, w17, w12, lsl #30        // Z
    orr   w17, w17, w16, lsl #29        // C = shifter carry
    ubfx  w12, w15, #28, #1             // V preserved
    orr   w17, w17, w12, lsl #28
    msr   nzcv, x17
    orr   x20, x20, #0x100000000
    NEXT_A
.endm

LOGSH_S logsh_s_lsl, 0
LOGSH_S logsh_s_lsr, 1
LOGSH_S logsh_s_asr, 2
LOGSH_S logsh_s_ror, 3

// ---------------------------------------------------------------------------
// Fused logical-register set-flags + conditional branch
// (ArmLogicalRegisterSetFlagsBranchNoPcAlways, op223).
// a0 = data_opcode | rd<<4 | rn<<8 | rm<<12 | fused_guest_size<<16
// a1 = taken record, a2 = taken pc.
// Flags: N/Z from result, C and V preserved from the pre-op guest flags
// (logical ops keep C/V); branch evaluated on the composed flags.
// ---------------------------------------------------------------------------
.macro LOGRBRA chain, cond
    .globl citra_asm_op_logrbra\chain\()_\cond
citra_asm_op_logrbra\chain\()_\cond:
    ldr   w10, [x9, #AR0]
    ubfx  w11, w10, #16, #8             // fused guest size
    ubfx  w12, w10, #8, #4              // rn
    ubfx  w13, w10, #12, #4             // rm
    ldr   w12, [x25, w12, uxtw #2]
    ldr   w13, [x25, w13, uxtw #2]
    mrs   x14, nzcv                     // old flags (C,V preserved)
    and   w15, w10, #0xF                // data_opcode
    cmp   w15, #1
    b.eq  .Llr_\chain\()_\cond\()_eor
    cmp   w15, #12
    b.eq  .Llr_\chain\()_\cond\()_orr
    cmp   w15, #13
    b.eq  .Llr_\chain\()_\cond\()_mov
    cmp   w15, #14
    b.eq  .Llr_\chain\()_\cond\()_bic
    cmp   w15, #15
    b.eq  .Llr_\chain\()_\cond\()_mvn
    and   w16, w12, w13                 // AND (0)
    b     .Llr_\chain\()_\cond\()_res
.Llr_\chain\()_\cond\()_eor:
    eor   w16, w12, w13
    b     .Llr_\chain\()_\cond\()_res
.Llr_\chain\()_\cond\()_orr:
    orr   w16, w12, w13
    b     .Llr_\chain\()_\cond\()_res
.Llr_\chain\()_\cond\()_mov:
    mov   w16, w13
    b     .Llr_\chain\()_\cond\()_res
.Llr_\chain\()_\cond\()_bic:
    bic   w16, w12, w13
    b     .Llr_\chain\()_\cond\()_res
.Llr_\chain\()_\cond\()_mvn:
    mvn   w16, w13
.Llr_\chain\()_\cond\()_res:
    ubfx  w15, w10, #4, #4              // rd
    str   w16, [x25, w15, uxtw #2]
    and   w17, w16, #0x80000000         // N
    cbnz  w16, 1f
    orr   w17, w17, #0x40000000         // Z
1:  and   w15, w14, #0x30000000         // keep old C+V
    orr   w17, w17, w15
    msr   nzcv, x17
    orr   x20, x20, #0x100000000
    b.\cond 2f
    add   w28, w28, w11
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
2:  ldp   x10, x11, [x9, #AR1]
    mov   w28, w11
    add   x20, x20, #2
.ifc \chain,chain
    ldr   w17, [x9, #AR0]
    lsr   w17, w17, #24            // block guest-instruction count
    ldr   w16, [x19, #ASMCTX_BUDGET]
    sub   w16, w16, w20
    sub   w16, w16, w17
    tbz   w16, #31, 88f
    b     .Lasm_budget_exit
88:
.endif
    mov   x9, x10
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.endm

LOGRBRA ,eq
LOGRBRA ,ne
LOGRBRA ,cs
LOGRBRA ,cc
LOGRBRA ,mi
LOGRBRA ,pl
LOGRBRA ,vs
LOGRBRA ,vc
LOGRBRA ,hi
LOGRBRA ,ls
LOGRBRA ,ge
LOGRBRA ,lt
LOGRBRA ,gt
LOGRBRA ,le
LOGRBRA chain,eq
LOGRBRA chain,ne
LOGRBRA chain,cs
LOGRBRA chain,cc
LOGRBRA chain,mi
LOGRBRA chain,pl
LOGRBRA chain,vs
LOGRBRA chain,vc
LOGRBRA chain,hi
LOGRBRA chain,ls
LOGRBRA chain,ge
LOGRBRA chain,lt
LOGRBRA chain,gt
LOGRBRA chain,le

// ---------------------------------------------------------------------------
// Fused logical register-shifted-register set-flags + conditional branch
// (ArmLogicalRegisterShiftedRegisterSetFlagsBranchNoPcAlways, op224):
// AND/EOR/ORR/BIC/MVN rd, rn, rm, <shift> rs + cond branch.
// a0 = data | rd<<4 | rn<<8 | rm<<12 | rs<<16;
// a1 = shift_type | fused_guest_size<<8 | block_instrs<<16;
// a2 = taken record, a3 = taken pc.
// Flags: N/Z from result, C = shifter carry-out (old C when rs&0xFF == 0),
// V preserved; the branch evaluates the composed flags.
// ---------------------------------------------------------------------------
.macro LOGRSHBRA chain, cond
    .globl citra_asm_op_logrshbra\chain\()_\cond
citra_asm_op_logrshbra\chain\()_\cond:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #12, #4             // rm
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w10, #16, #4             // rs
    ldr   w13, [x25, w13, uxtw #2]
    and   w13, w13, #0xFF               // shift amount
    mrs   x15, nzcv                     // old guest flags
    ubfx  w16, w15, #29, #1             // old C (default shifter carry)
    and   w14, w11, #3                  // shift_type
    cbz   w13, .Lrsl_\chain\()_\cond\()_nosh
    cmp   w14, #1
    b.lo  .Lrsl_\chain\()_\cond\()_lsl
    b.eq  .Lrsl_\chain\()_\cond\()_lsr
    cmp   w14, #2
    b.eq  .Lrsl_\chain\()_\cond\()_asr
    and   w17, w13, #31                 // ROR: rotate = n % 32
    cbz   w17, .Lrsl_\chain\()_\cond\()_ror0
    ror   w14, w12, w17
    lsr   w16, w14, #31                 // carry = result bit31
    b     .Lrsl_\chain\()_\cond\()_opd
.Lrsl_\chain\()_\cond\()_ror0:
    mov   w14, w12
    lsr   w16, w12, #31                 // n%32==0: operand=rm, carry=bit31
    b     .Lrsl_\chain\()_\cond\()_opd
.Lrsl_\chain\()_\cond\()_lsl:
    cmp   w13, #32
    b.hs  .Lrsl_\chain\()_\cond\()_lsl32
    lsl   w14, w12, w13
    neg   w17, w13
    lsr   w17, w12, w17
    and   w16, w17, #1                  // carry = rm bit(32-n)
    b     .Lrsl_\chain\()_\cond\()_opd
.Lrsl_\chain\()_\cond\()_lsl32:
    mov   w14, #0
    and   w16, w12, #1
    cmp   w13, #32
    csel  w16, w16, wzr, eq             // n==32: rm bit0; n>32: 0
    b     .Lrsl_\chain\()_\cond\()_opd
.Lrsl_\chain\()_\cond\()_lsr:
    cmp   w13, #32
    b.hs  .Lrsl_\chain\()_\cond\()_lsr32
    lsr   w14, w12, w13
    sub   w17, w13, #1
    lsr   w17, w12, w17
    and   w16, w17, #1                  // carry = rm bit(n-1)
    b     .Lrsl_\chain\()_\cond\()_opd
.Lrsl_\chain\()_\cond\()_lsr32:
    mov   w14, #0
    lsr   w16, w12, #31
    cmp   w13, #32
    csel  w16, w16, wzr, eq             // n==32: rm bit31; n>32: 0
    b     .Lrsl_\chain\()_\cond\()_opd
.Lrsl_\chain\()_\cond\()_asr:
    cmp   w13, #32
    b.hs  .Lrsl_\chain\()_\cond\()_asr32
    asr   w14, w12, w13
    sub   w17, w13, #1
    lsr   w17, w12, w17
    and   w16, w17, #1
    b     .Lrsl_\chain\()_\cond\()_opd
.Lrsl_\chain\()_\cond\()_asr32:
    asr   w14, w12, #31                 // n>=32: sign-fill
    lsr   w16, w12, #31
    b     .Lrsl_\chain\()_\cond\()_opd
.Lrsl_\chain\()_\cond\()_nosh:
    mov   w14, w12                      // rs==0: operand=rm, carry=old C
.Lrsl_\chain\()_\cond\()_opd:
    // w14 = shifted operand, w16 = shifter carry, x15 = old guest NZCV
    ubfx  w17, w10, #8, #4              // rn
    ldr   w17, [x25, w17, uxtw #2]
    and   w12, w10, #0xF                // data_opcode (w18 stays resident r2)
    cmp   w12, #12
    b.lo  .Lrsl_\chain\()_\cond\()_lo   // and/eor
    b.eq  .Lrsl_\chain\()_\cond\()_orr
    cmp   w12, #14
    b.eq  .Lrsl_\chain\()_\cond\()_bic
    b.lo  .Lrsl_\chain\()_\cond\()_res  // mov: result = operand
    mvn   w14, w14                      // mvn
    b     .Lrsl_\chain\()_\cond\()_res
.Lrsl_\chain\()_\cond\()_lo:
    cmp   w12, #1
    b.eq  .Lrsl_\chain\()_\cond\()_eor
    and   w14, w17, w14
    b     .Lrsl_\chain\()_\cond\()_res
.Lrsl_\chain\()_\cond\()_eor:
    eor   w14, w17, w14
    b     .Lrsl_\chain\()_\cond\()_res
.Lrsl_\chain\()_\cond\()_orr:
    orr   w14, w17, w14
    b     .Lrsl_\chain\()_\cond\()_res
.Lrsl_\chain\()_\cond\()_bic:
    bic   w14, w17, w14
.Lrsl_\chain\()_\cond\()_res:
    ubfx  w17, w10, #4, #4              // rd
    str   w14, [x25, w17, uxtw #2]
    and   w17, w14, #0x80000000         // N
    cmp   w14, #0
    cset  w12, eq
    orr   w17, w17, w12, lsl #30        // Z
    orr   w17, w17, w16, lsl #29        // C = shifter carry
    ubfx  w12, w15, #28, #1             // V preserved
    orr   w17, w17, w12, lsl #28
    msr   nzcv, x17
    orr   x20, x20, #0x100000000
    b.\cond 60f
    ubfx  w11, w11, #8, #8              // fused guest size
    add   w28, w28, w11
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
60: ldp   x10, x11, [x9, #AR2]
    mov   w28, w11
    add   x20, x20, #2
.ifc \chain,chain
    ldr   w17, [x9, #AR1]
    lsr   w17, w17, #16            // block guest-instruction count
    ldr   w16, [x19, #ASMCTX_BUDGET]
    sub   w16, w16, w20
    sub   w16, w16, w17
    tbz   w16, #31, 88f
    b     .Lasm_budget_exit
88:
.endif
    mov   x9, x10
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.endm

LOGRSHBRA ,eq
LOGRSHBRA ,ne
LOGRSHBRA ,cs
LOGRSHBRA ,cc
LOGRSHBRA ,mi
LOGRSHBRA ,pl
LOGRSHBRA ,vs
LOGRSHBRA ,vc
LOGRSHBRA ,hi
LOGRSHBRA ,ls
LOGRSHBRA ,ge
LOGRSHBRA ,lt
LOGRSHBRA ,gt
LOGRSHBRA ,le
LOGRSHBRA chain,eq
LOGRSHBRA chain,ne
LOGRSHBRA chain,cs
LOGRSHBRA chain,cc
LOGRSHBRA chain,mi
LOGRSHBRA chain,pl
LOGRSHBRA chain,vs
LOGRSHBRA chain,vc
LOGRSHBRA chain,hi
LOGRSHBRA chain,ls
LOGRSHBRA chain,ge
LOGRSHBRA chain,lt
LOGRSHBRA chain,gt
LOGRSHBRA chain,le

// ---------------------------------------------------------------------------
// Logical register op with flags, no shift (ArmLogicalRegisterSetFlags-
// NoPcAlways, op169): AND/EOR/TST/TEQ/ORR/MOV/BIC/MVN rd, rn, rm. N/Z come
// from the result; C and V keep their pre-op guest values (no shifter).
// a0 = data_opcode, a1 = rd | rn<<8 | rm<<16. TST/TEQ skip the rd store.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_logreg_s
citra_asm_op_logreg_s:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w11, #8, #4              // rn
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w11, #16, #4             // rm
    ldr   w13, [x25, w13, uxtw #2]
    mrs   x14, nzcv                     // old flags (C,V preserved)
    and   w15, w10, #0xF                // data_opcode
    cmp   w15, #1
    b.eq  .Llgs_eor
    cmp   w15, #8
    b.eq  .Llgs_tst
    cmp   w15, #9
    b.eq  .Llgs_teq
    cmp   w15, #12
    b.eq  .Llgs_orr
    cmp   w15, #13
    b.eq  .Llgs_mov
    cmp   w15, #14
    b.eq  .Llgs_bic
    cmp   w15, #15
    b.eq  .Llgs_mvn
    and   w16, w12, w13                 // AND (0)
    b     .Llgs_res
.Llgs_eor:
    eor   w16, w12, w13
    b     .Llgs_res
.Llgs_tst:
    and   w16, w12, w13
    b     .Llgs_flags
.Llgs_teq:
    eor   w16, w12, w13
    b     .Llgs_flags
.Llgs_orr:
    orr   w16, w12, w13
    b     .Llgs_res
.Llgs_mov:
    mov   w16, w13
    b     .Llgs_res
.Llgs_bic:
    bic   w16, w12, w13
    b     .Llgs_res
.Llgs_mvn:
    mvn   w16, w13
.Llgs_res:
    and   w15, w11, #0xF                // rd
    str   w16, [x25, w15, uxtw #2]
.Llgs_flags:
    and   w17, w16, #0x80000000         // N
    cbnz  w16, 1f
    orr   w17, w17, #0x40000000         // Z
1:  and   w15, w14, #0x30000000         // keep old C+V
    orr   w17, w17, w15
    msr   nzcv, x17
    orr   x20, x20, #0x100000000
    NEXT_A

// ---------------------------------------------------------------------------
// Fused logical-immediate set-flags + conditional branch
// (ArmLogicalImmediateSetFlagsBranchNoPcAlways, op222):
// AND/EOR/ORR/MOV/BIC/MVN rd, rn, #imm + cond branch.
// a0 = data_opcode | rd<<4 | rn<<8 | carry<<12 | carry_from_c<<13 |
//      fused_guest_size<<16 | block_instrs<<24
// a1 = imm32, a2 = taken record, a3 = taken pc.
// N/Z from result; C = shifter carry (const) or preserved guest C; V kept.
// ---------------------------------------------------------------------------
.macro LOGIBRA chain, cond
    .globl citra_asm_op_logibra\chain\()_\cond
citra_asm_op_logibra\chain\()_\cond:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w12, w10, #8, #4              // rn
    ldr   w12, [x25, w12, uxtw #2]
    mrs   x14, nzcv                     // old flags (before dispatch clobbers)
    and   w15, w10, #0xF                // data_opcode
    cmp   w15, #1
    b.eq  .Lli_\chain\()_\cond\()_eor
    cmp   w15, #12
    b.eq  .Lli_\chain\()_\cond\()_orr
    cmp   w15, #13
    b.eq  .Lli_\chain\()_\cond\()_mov
    cmp   w15, #14
    b.eq  .Lli_\chain\()_\cond\()_bic
    cmp   w15, #15
    b.eq  .Lli_\chain\()_\cond\()_mvn
    and   w16, w12, w11                 // AND (0)
    b     .Lli_\chain\()_\cond\()_res
.Lli_\chain\()_\cond\()_eor:
    eor   w16, w12, w11
    b     .Lli_\chain\()_\cond\()_res
.Lli_\chain\()_\cond\()_orr:
    orr   w16, w12, w11
    b     .Lli_\chain\()_\cond\()_res
.Lli_\chain\()_\cond\()_mov:
    mov   w16, w11
    b     .Lli_\chain\()_\cond\()_res
.Lli_\chain\()_\cond\()_bic:
    bic   w16, w12, w11
    b     .Lli_\chain\()_\cond\()_res
.Lli_\chain\()_\cond\()_mvn:
    mvn   w16, w11
.Lli_\chain\()_\cond\()_res:
    ubfx  w15, w10, #4, #4              // rd
    str   w16, [x25, w15, uxtw #2]
    and   w17, w16, #0x80000000         // N
    cbnz  w16, 1f
    orr   w17, w17, #0x40000000         // Z
1:  tbz   w10, #13, 2f                  // carry_from_c?
    and   w15, w14, #0x20000000         // C = old guest C
    b     3f
2:  ubfx  w15, w10, #12, #1             // C = const shifter carry
    lsl   w15, w15, #29
3:  orr   w17, w17, w15
    and   w15, w14, #0x10000000         // keep old V
    orr   w17, w17, w15
    msr   nzcv, x17
    orr   x20, x20, #0x100000000
    b.\cond 4f
    ubfx  w11, w10, #16, #8             // fused guest size
    add   w28, w28, w11
    add   x20, x20, #2
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
4:  ldp   x10, x11, [x9, #AR2]
    mov   w28, w11
    add   x20, x20, #2
.ifc \chain,chain
    ldr   w17, [x9, #AR0]
    lsr   w17, w17, #24            // block guest-instruction count
    ldr   w16, [x19, #ASMCTX_BUDGET]
    sub   w16, w16, w20
    sub   w16, w16, w17
    tbz   w16, #31, 88f
    b     .Lasm_budget_exit
88:
.endif
    mov   x9, x10
    ldr   x8, [x9], #ASMOP_SIZE
    br    x8
.endm

LOGIBRA ,eq
LOGIBRA ,ne
LOGIBRA ,cs
LOGIBRA ,cc
LOGIBRA ,mi
LOGIBRA ,pl
LOGIBRA ,vs
LOGIBRA ,vc
LOGIBRA ,hi
LOGIBRA ,ls
LOGIBRA ,ge
LOGIBRA ,lt
LOGIBRA ,gt
LOGIBRA ,le
LOGIBRA chain,eq
LOGIBRA chain,ne
LOGIBRA chain,cs
LOGIBRA chain,cc
LOGIBRA chain,mi
LOGIBRA chain,pl
LOGIBRA chain,vs
LOGIBRA chain,vc
LOGIBRA chain,hi
LOGIBRA chain,ls
LOGIBRA chain,ge
LOGIBRA chain,lt
LOGIBRA chain,gt
LOGIBRA chain,le

// ---------------------------------------------------------------------------
// Logical immediate op with flags (ArmLogicalImmediateSetFlagsNoPcAlways,
// op168): AND/EOR/TST/TEQ/ORR/MOV/BIC/MVN rd, rn, #imm. N/Z from result;
// C = shifter carry (const) or preserved guest C (from_c); V preserved.
// a0 = data_opcode | carry<<8 | carry_from_c<<9; a1 = rd | rn<<8; a2 = imm.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_logimm_s
citra_asm_op_logimm_s:
    ldp   x10, x11, [x9, #AR0]
    ldr   w16, [x9, #AR2]               // imm
    ubfx  w12, w11, #8, #4              // rn
    ldr   w12, [x25, w12, uxtw #2]
    mrs   x14, nzcv                     // old flags (before dispatch clobbers)
    and   w15, w10, #0xF                // data_opcode
    cmp   w15, #1
    b.eq  .Llgi_eor
    cmp   w15, #8
    b.eq  .Llgi_tst
    cmp   w15, #9
    b.eq  .Llgi_teq
    cmp   w15, #12
    b.eq  .Llgi_orr
    cmp   w15, #13
    b.eq  .Llgi_mov
    cmp   w15, #14
    b.eq  .Llgi_bic
    cmp   w15, #15
    b.eq  .Llgi_mvn
    and   w16, w12, w16                 // AND (0)
    b     .Llgi_res
.Llgi_eor:
    eor   w16, w12, w16
    b     .Llgi_res
.Llgi_tst:
    and   w16, w12, w16
    b     .Llgi_flags
.Llgi_teq:
    eor   w16, w12, w16
    b     .Llgi_flags
.Llgi_orr:
    orr   w16, w12, w16
    b     .Llgi_res
.Llgi_mov:                              // result = imm
    b     .Llgi_res
.Llgi_bic:
    bic   w16, w12, w16
    b     .Llgi_res
.Llgi_mvn:
    mvn   w16, w16
.Llgi_res:
    and   w15, w11, #0xF                // rd
    str   w16, [x25, w15, uxtw #2]
.Llgi_flags:
    and   w17, w16, #0x80000000         // N
    cbnz  w16, 1f
    orr   w17, w17, #0x40000000         // Z
1:  tbz   w10, #9, 2f                   // carry_from_c?
    and   w15, w14, #0x20000000         // C = old guest C
    b     3f
2:  ubfx  w15, w10, #8, #1              // C = const shifter carry
    lsl   w15, w15, #29
3:  orr   w17, w17, w15
    and   w15, w14, #0x10000000         // keep old V
    orr   w17, w17, w15
    msr   nzcv, x17
    orr   x20, x20, #0x100000000
    NEXT_A

// ---------------------------------------------------------------------------
// Logical register-shifted-by-register op, no flags
// (ArmLogicalRegisterShiftedRegisterNoPcAlways, op206):
// AND/EOR/ORR/MOV/BIC/MVN rd, rn, rm <shift> (rs & 0xFF). Flag-free.
// a0 = data_opcode, a1 = rd | rn<<8 | rm<<16 | rs<<24, a2 = shift_type.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_logregsh
citra_asm_op_logregsh:
    ldp   x10, x11, [x9, #AR0]
    ldr   w14, [x9, #AR2]               // shift_type
    ubfx  w12, w11, #16, #4             // rm
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w11, #24, #4             // rs
    ldr   w13, [x25, w13, uxtw #2]
    and   w13, w13, #0xFF               // amount
    cbz   w13, .Llgsh_amt0              // amount==0 -> rm
    // flag-free 4-way dispatch on w14&3
    and   w15, w14, #2
    cbnz  w15, .Llgsh_hi
    and   w15, w14, #1
    cbnz  w15, .Llgsh_lsr
    // LSL
    and   w15, w13, #0xE0
    cbnz  w15, .Llgsh_zero              // >=32 -> 0
    lsl   w12, w12, w13
    b     .Llgsh_shifted
.Llgsh_lsr:
    and   w15, w13, #0xE0
    cbnz  w15, .Llgsh_zero              // >=32 -> 0
    lsr   w12, w12, w13
    b     .Llgsh_shifted
.Llgsh_hi:
    and   w15, w14, #1
    cbnz  w15, .Llgsh_ror
    // ASR
    and   w15, w13, #0xE0
    cbnz  w15, .Llgsh_sign              // >=32 -> sign-fill
    asr   w12, w12, w13
    b     .Llgsh_shifted
.Llgsh_ror:
    ror   w12, w12, w13                 // hw masks to 5 bits == ARM rotate
    b     .Llgsh_shifted
.Llgsh_zero:
    mov   w12, #0
    b     .Llgsh_shifted
.Llgsh_sign:
    asr   w12, w12, #31
    b     .Llgsh_shifted
.Llgsh_amt0:
.Llgsh_shifted:                         // w12 = shifted operand
    ubfx  w13, w11, #8, #4              // rn
    ldr   w13, [x25, w13, uxtw #2]
    and   w15, w10, #0xF                // data_opcode; flag-free dispatch
    tbnz  w15, #3, .Llgsh_hi2
    tbnz  w15, #0, .Llgsh_eor           // 1
    and   w12, w13, w12                 // AND (0)
    b     .Llgsh_store
.Llgsh_eor:
    eor   w12, w13, w12
    b     .Llgsh_store
.Llgsh_hi2:
    tbz   w15, #0, .Llgsh_even          // 12/14
    tbnz  w15, #1, .Llgsh_mvn           // 15
    b     .Llgsh_store                  // 13: mov -> w12 already
.Llgsh_even:
    tbnz  w15, #1, .Llgsh_bic           // 14
    orr   w12, w13, w12                 // 12: ORR
    b     .Llgsh_store
.Llgsh_bic:
    bic   w12, w13, w12
    b     .Llgsh_store
.Llgsh_mvn:
    mvn   w12, w12
.Llgsh_store:
    and   w15, w11, #0xF                // rd
    str   w12, [x25, w15, uxtw #2]
    NEXT_A

// ---------------------------------------------------------------------------
// Non-flag data-processing leftovers (op48/op9 residual forms and the
// specialized register-shifted arithmetic opcodes).
// alu_regsh: rd = rn OP (rm <shift> Reg[rs]&0xFF); all register indices < 15.
//   a0 = data | shift_type<<8, a1 = rd|rn<<8|rm<<16|rs<<24, a2 = C++ op index
// alu_rm_pc: rd = rn OP pc_const -- rm==15 reads the op's pc constant
//            (Reg[15] slot is stale). No shift; rn<15.
//   a0 = data | pc_const<<32, a1 = rd|rn<<8|rm<<16, a2 = C++ op index
// Both write the result to rd and continue; MEMSLOW replays via a2.
// ---------------------------------------------------------------------------
    .globl citra_asm_op_alu_regsh
citra_asm_op_alu_regsh:
    ldp   x10, x11, [x9, #AR0]
    ubfx  w14, w10, #8, #2              // shift_type
    ubfx  w12, w11, #16, #4             // rm index
    ldr   w12, [x25, w12, uxtw #2]
    ubfx  w13, w11, #24, #4             // rs index
    ldr   w13, [x25, w13, uxtw #2]
    and   w13, w13, #0xFF               // shift amount
    cbz   w13, .Lalu_shared             // amount==0 -> rm
    // flag-free 4-way dispatch, ARM >=32 semantics
    and   w15, w14, #2
    cbnz  w15, .Lalu_sh_hi
    and   w15, w14, #1
    cbnz  w15, .Lalu_sh_lsr
    and   w15, w13, #0xE0               // lsl
    cbnz  w15, .Lalu_sh_zero
    lsl   w12, w12, w13
    b     .Lalu_shared
.Lalu_sh_lsr:
    and   w15, w13, #0xE0
    cbnz  w15, .Lalu_sh_zero
    lsr   w12, w12, w13
    b     .Lalu_shared
.Lalu_sh_hi:
    and   w15, w14, #1
    cbnz  w15, .Lalu_sh_ror
    and   w15, w13, #0xE0               // asr
    cbnz  w15, .Lalu_sh_sign
    asr   w12, w12, w13
    b     .Lalu_shared
.Lalu_sh_ror:
    ror   w12, w12, w13                 // hw masks to 5 bits == ARM rotate
    b     .Lalu_shared
.Lalu_sh_zero:
    mov   w12, #0
    b     .Lalu_shared
.Lalu_sh_sign:
    asr   w12, w12, #31
    b     .Lalu_shared

    .globl citra_asm_op_alu_rm_pc
citra_asm_op_alu_rm_pc:
    ldp   x10, x11, [x9, #AR0]
    lsr   x12, x10, #32                 // operand2 = pc constant
    // fall into the shared ALU tail
.Lalu_shared:                           // w12 = operand2
    ubfx  w13, w11, #8, #4              // rn index
    ldr   w13, [x25, w13, uxtw #2]
    and   w15, w10, #0xF                // data_opcode; flag-free tree
    tbz   w15, #3, .Lalu_lo
    tbz   w15, #2, .Lalu_slow           // 8-11 test ops never reach here
    tbz   w15, #1, .Lalu_orr_mov
    tbz   w15, #0, .Lalu_bic
    mvn   w12, w12                      // 15: mvn
    b     .Lalu_store
.Lalu_bic:
    bic   w12, w13, w12                 // 14
    b     .Lalu_store
.Lalu_orr_mov:
    tbz   w15, #0, .Lalu_orr
    b     .Lalu_store                   // 13: mov -> w12 already op2
.Lalu_orr:
    orr   w12, w13, w12                 // 12
    b     .Lalu_store
.Lalu_lo:                               // 0-7
    tbz   w15, #2, .Lalu_l0
    tbz   w15, #1, .Lalu_add_adc        // 4,5
    tbz   w15, #0, .Lalu_sbc
    mrs   x17, nzcv                     // 7: rsc = op2 - rn + C - 1
    ubfx  w17, w17, #29, #1
    sub   w12, w12, w13
    add   w12, w12, w17
    sub   w12, w12, #1
    b     .Lalu_store
.Lalu_sbc:                              // 6: rn - op2 + C - 1
    mrs   x17, nzcv
    ubfx  w17, w17, #29, #1
    sub   w12, w13, w12
    add   w12, w12, w17
    sub   w12, w12, #1
    b     .Lalu_store
.Lalu_add_adc:
    tbz   w15, #0, .Lalu_add
    mrs   x17, nzcv                     // 5: adc = rn + op2 + C
    ubfx  w17, w17, #29, #1
    add   w12, w13, w12
    add   w12, w12, w17
    b     .Lalu_store
.Lalu_add:
    add   w12, w13, w12                 // 4
    b     .Lalu_store
.Lalu_l0:                               // 0-3
    tbz   w15, #1, .Lalu_and_eor
    tbz   w15, #0, .Lalu_sub
    sub   w12, w12, w13                 // 3: rsb = op2 - rn
    b     .Lalu_store
.Lalu_sub:
    sub   w12, w13, w12                 // 2
    b     .Lalu_store
.Lalu_and_eor:
    tbz   w15, #0, .Lalu_and
    eor   w12, w13, w12                 // 1
    b     .Lalu_store
.Lalu_and:
    and   w12, w13, w12                 // 0
.Lalu_store:
    and   w14, w11, #0xF                // rd
    str   w12, [x25, w14, uxtw #2]
    NEXT_A
.Lalu_slow:
    MEMSLOW

// ===========================================================================
// Resident-register variants (v1.1). Inside a program whose resmask covers
// r0-r2, the resident host regs are authoritative and the regfile slots for
// r0-r2 are stale; the translator only selects these *_v* handlers for ops
// that touch resident regs (all-regfile operand mixes keep the generic
// handler). Names encode per-slot residency: digit 0-2 = resident guest
// reg, 3 = regfile operand. a0/a1 packing is identical to the generic
// handler, so a regfile operand still extracts its index from the record.
// ===========================================================================

// Load operand slot: g < 3 selects the resident host register, otherwise
// extract the a0 nibble at bit \sh and read the regfile. w10 must hold a0
// in the regfile case; w16 is the index scratch.
.macro RESL dst, g, sh
.if \g == 0
    mov   \dst, w21
.elseif \g == 1
    mov   \dst, w26
.elseif \g == 2
    mov   \dst, w18
.else
    ubfx  w16, w10, #\sh, #4
    ldr   \dst, [x25, w16, uxtw #2]
.endif
.endm

// Store operand slot, same residency encoding as RESL.
.macro RESS src, g, sh
.if \g == 0
    mov   w21, \src
.elseif \g == 1
    mov   w26, \src
.elseif \g == 2
    mov   w18, \src
.else
    ubfx  w16, w10, #\sh, #4
    str   \src, [x25, w16, uxtw #2]
.endif
.endm

// ---- rd = imm (a0 = rd, a1 = imm) -------------------------------------
.irp rd,0,1,2
citra_asm_op_mov_imm_v\rd:
    ldr   w11, [x9, #AR1]
    RESS  w11, \rd, 0
    NEXT_A
.endr
.irp rd,0,1,2
citra_asm_op_mvn_imm_v\rd:
    ldr   w11, [x9, #AR1]
    mvn   w11, w11
    RESS  w11, \rd, 0
    NEXT_A
.endr

// movs rd, #imm (ArmMoveImmediateSetFlagsAlways): same flag semantics as the
// generic handler; only the rd store changes under residency.
.irp rd,0,1,2
citra_asm_op_movs_imm_v\rd:
    ldp   x10, x11, [x9, #AR0]
    mrs   x15, nzcv
    ubfx  w16, w10, #8, #1
    tbz   w10, #9, 1f
    ubfx  w16, w15, #29, #1
1:  RESS  w11, \rd, 0
    b     .Lmovi_s_flags
.endr

// ---- cmp/cmn rn, #imm (a0 = rn, a1 = imm) --------------------------------
.irp rn,0,1,2
citra_asm_op_cmp_imm_v\rn:
    ldr   w11, [x9, #AR1]
    RESL  w12, \rn, 0
    subs  wzr, w12, w11
    orr   x20, x20, #0x100000000
    NEXT_A
citra_asm_op_cmn_imm_v\rn:
    ldr   w11, [x9, #AR1]
    RESL  w12, \rn, 0
    adds  wzr, w12, w11
    orr   x20, x20, #0x100000000
    NEXT_A
.endr

// ---- ldr rd, [lit] (a0 = rd, a1 = guest absolute addr) ------------------
// Same fastmem skeleton as LDR_LIT; rd is always resident in a variant.
.irp rd,0,1,2
citra_asm_op_ldrw_lit_v\rd:
    ldr   w11, [x9, #AR1]
    and   w13, w11, #ASM_PAGE_MASK
    sub   w15, w13, #(0x1001 - 4)
    tbz   w15, #31, .Lslow_lwlit_v\rd
    ubfx  w14, w11, #ASM_PAGE_BITS, #20
    sub   w15, w14, w23
    cbnz  w15, .Lmiss_lwlit_v\rd
.Ldo_lwlit_v\rd:
    ldr   w15, [x27, w13, uxtw]
    RESS  w15, \rd, 0
    NEXT_A
.Lmiss_lwlit_v\rd:
    ldr   x14, [x24, w14, uxtw #3]
    cbz   x14, .Lslow_lwlit_v\rd
    mov   w23, w14
    mov   x27, x14
    b     .Ldo_lwlit_v\rd
.Lslow_lwlit_v\rd:
    MEMSLOW
.endr

// ---- rd = rn OP imm (a0 = rd|rn<<8, a1 = imm) ----------------------------
.macro V_ALU_IMM name, insn, rd, rn
    .globl citra_asm_op_\name\()_v\rd\rn
    .hidden citra_asm_op_\name\()_v\rd\rn
citra_asm_op_\name\()_v\rd\rn:
.if (\rd > 2) | (\rn > 2)
    ldr   w10, [x9, #AR0]
.endif
    ldr   w11, [x9, #AR1]
    RESL  w12, \rn, 8
    \insn w12, w12, w11
    RESS  w12, \rd, 0
    NEXT_A
.endm

// Reversed order: rd = imm OP rn (rsb/rsc).
.macro V_ALU_RIMM name, insn, rd, rn
    .globl citra_asm_op_\name\()_v\rd\rn
    .hidden citra_asm_op_\name\()_v\rd\rn
citra_asm_op_\name\()_v\rd\rn:
.if (\rd > 2) | (\rn > 2)
    ldr   w10, [x9, #AR0]
.endif
    ldr   w11, [x9, #AR1]
    RESL  w12, \rn, 8
    \insn w12, w11, w12
    RESS  w12, \rd, 0
    NEXT_A
.endm

// Flag-setting forms: host NZCV = guest flags.
.macro V_ALUF_IMM name, insn, rd, rn
    .globl citra_asm_op_\name\()_v\rd\rn
    .hidden citra_asm_op_\name\()_v\rd\rn
citra_asm_op_\name\()_v\rd\rn:
.if (\rd > 2) | (\rn > 2)
    ldr   w10, [x9, #AR0]
.endif
    ldr   w11, [x9, #AR1]
    RESL  w12, \rn, 8
    \insn w12, w12, w11
    orr   x20, x20, #0x100000000
    RESS  w12, \rd, 0
    NEXT_A
.endm

.macro V_ALUF_RIMM name, insn, rd, rn
    .globl citra_asm_op_\name\()_v\rd\rn
    .hidden citra_asm_op_\name\()_v\rd\rn
citra_asm_op_\name\()_v\rd\rn:
.if (\rd > 2) | (\rn > 2)
    ldr   w10, [x9, #AR0]
.endif
    ldr   w11, [x9, #AR1]
    RESL  w12, \rn, 8
    \insn w12, w11, w12
    orr   x20, x20, #0x100000000
    RESS  w12, \rd, 0
    NEXT_A
.endm

.irp rd,0,1,2,3
  .irp rn,0,1,2,3
    .if (\rd < 3) | (\rn < 3)
    V_ALU_IMM  add_imm, add, \rd, \rn
    V_ALU_IMM  sub_imm, sub, \rd, \rn
    V_ALU_IMM  and_imm, and, \rd, \rn
    V_ALU_IMM  eor_imm, eor, \rd, \rn
    V_ALU_IMM  orr_imm, orr, \rd, \rn
    V_ALU_IMM  bic_imm, bic, \rd, \rn
    V_ALU_IMM  adc_imm, adc, \rd, \rn
    V_ALU_IMM  sbc_imm, sbc, \rd, \rn
    V_ALU_RIMM rsb_imm, sub, \rd, \rn
    V_ALU_RIMM rsc_imm, sbc, \rd, \rn
    V_ALUF_IMM  adds_imm, adds, \rd, \rn
    V_ALUF_IMM  subs_imm, subs, \rd, \rn
    V_ALUF_IMM  adcs_imm, adcs, \rd, \rn
    V_ALUF_IMM  sbcs_imm, sbcs, \rd, \rn
    V_ALUF_RIMM rsbs_imm, subs, \rd, \rn
    V_ALUF_RIMM rscs_imm, sbcs, \rd, \rn
    .endif
  .endr
.endr

// ---- rd = rn OP rm (a0 = rd|rn<<8|rm<<16) -------------------------------
.macro V_ALU_REG name, insn, rd, rn, rm
    .globl citra_asm_op_\name\()_v\rd\rn\rm
    .hidden citra_asm_op_\name\()_v\rd\rn\rm
citra_asm_op_\name\()_v\rd\rn\rm:
.if (\rd > 2) | (\rn > 2) | (\rm > 2)
    ldr   w10, [x9, #AR0]
.endif
    RESL  w12, \rn, 8
    RESL  w13, \rm, 16
    \insn w12, w12, w13
    RESS  w12, \rd, 0
    NEXT_A
.endm

// Reversed: rd = rm OP rn (rsb/rsc reg forms).
.macro V_ALU_RREG name, insn, rd, rn, rm
    .globl citra_asm_op_\name\()_v\rd\rn\rm
    .hidden citra_asm_op_\name\()_v\rd\rn\rm
citra_asm_op_\name\()_v\rd\rn\rm:
.if (\rd > 2) | (\rn > 2) | (\rm > 2)
    ldr   w10, [x9, #AR0]
.endif
    RESL  w12, \rn, 8
    RESL  w13, \rm, 16
    \insn w12, w13, w12
    RESS  w12, \rd, 0
    NEXT_A
.endm

.macro V_ALUF_REG name, insn, rd, rn, rm
    .globl citra_asm_op_\name\()_v\rd\rn\rm
    .hidden citra_asm_op_\name\()_v\rd\rn\rm
citra_asm_op_\name\()_v\rd\rn\rm:
.if (\rd > 2) | (\rn > 2) | (\rm > 2)
    ldr   w10, [x9, #AR0]
.endif
    RESL  w12, \rn, 8
    RESL  w13, \rm, 16
    \insn w12, w12, w13
    orr   x20, x20, #0x100000000
    RESS  w12, \rd, 0
    NEXT_A
.endm

.irp rd,0,1,2,3
  .irp rn,0,1,2,3
    .irp rm,0,1,2,3
      .if (\rd < 3) | (\rn < 3) | (\rm < 3)
      V_ALU_REG  add_reg, add, \rd, \rn, \rm
      V_ALU_REG  sub_reg, sub, \rd, \rn, \rm
      V_ALU_REG  and_reg, and, \rd, \rn, \rm
      V_ALU_REG  eor_reg, eor, \rd, \rn, \rm
      V_ALU_REG  orr_reg, orr, \rd, \rn, \rm
      V_ALU_REG  bic_reg, bic, \rd, \rn, \rm
      V_ALU_REG  adc_reg, adc, \rd, \rn, \rm
      V_ALU_REG  sbc_reg, sbc, \rd, \rn, \rm
      V_ALU_RREG rsb_reg, sub, \rd, \rn, \rm
      V_ALU_RREG rsc_reg, sbc, \rd, \rn, \rm
      V_ALUF_REG adds_reg, adds, \rd, \rn, \rm
      V_ALUF_REG subs_reg, subs, \rd, \rn, \rm
      .endif
    .endr
  .endr
.endr

// ---- rd = rm / ~rm (a0 = rd|rm<<8) --------------------------------------
.macro V_MOV_REG name, inv, rd, rm
    .globl citra_asm_op_\name\()_v\rd\rm
    .hidden citra_asm_op_\name\()_v\rd\rm
citra_asm_op_\name\()_v\rd\rm:
.if (\rd > 2) | (\rm > 2)
    ldr   w10, [x9, #AR0]
.endif
    RESL  w12, \rm, 8
.if \inv
    mvn   w12, w12
.endif
    RESS  w12, \rd, 0
    NEXT_A
.endm

// movs/mvns: N/Z from result via the shared flag tail, C+V preserved.
.macro V_MOVS_REG name, inv, rd, rm
    .globl citra_asm_op_\name\()_v\rd\rm
    .hidden citra_asm_op_\name\()_v\rd\rm
citra_asm_op_\name\()_v\rd\rm:
.if (\rd > 2) | (\rm > 2)
    ldr   w10, [x9, #AR0]
.endif
    RESL  w12, \rm, 8
.if \inv
    mvn   w12, w12
.endif
    RESS  w12, \rd, 0
    b     .Lmul_nz
.endm

.irp rd,0,1,2,3
  .irp rm,0,1,2,3
    .if (\rd < 3) | (\rm < 3)
    V_MOV_REG  mov_reg, 0, \rd, \rm
    V_MOV_REG  mvn_reg, 1, \rd, \rm
    V_MOVS_REG movs_reg, 0, \rd, \rm
    V_MOVS_REG mvns_reg, 1, \rd, \rm
    .endif
  .endr
.endr

// ---- cmp/cmn rn, rm (a0 = rn|rm<<8, flags only) --------------------------
.macro V_CMP_REG name, insn, rn, rm
    .globl citra_asm_op_\name\()_v\rn\rm
    .hidden citra_asm_op_\name\()_v\rn\rm
citra_asm_op_\name\()_v\rn\rm:
.if (\rn > 2) | (\rm > 2)
    ldr   w10, [x9, #AR0]
.endif
    RESL  w12, \rn, 0
    RESL  w13, \rm, 8
    \insn wzr, w12, w13
    orr   x20, x20, #0x100000000
    NEXT_A
.endm

.irp rn,0,1,2,3
  .irp rm,0,1,2,3
    .if (\rn < 3) | (\rm < 3)
    V_CMP_REG cmp_reg, subs, \rn, \rm
    V_CMP_REG cmn_reg, adds, \rn, \rm
    .endif
  .endr
.endr

// ---- ldr/str rd, [rn, #imm] (a0 = rd|rn<<8, a1 = offset) -----------------
// Same last-page fastmem skeleton as LDR_IMM/STR_IMM.
.macro V_LDR_IMM name, size, ldop, addop, rd, rn
    .globl citra_asm_op_\name\()_v\rd\rn
    .hidden citra_asm_op_\name\()_v\rd\rn
citra_asm_op_\name\()_v\rd\rn:
.if (\rd > 2) | (\rn > 2)
    ldr   w10, [x9, #AR0]
.endif
    ldr   w11, [x9, #AR1]
    RESL  w12, \rn, 8
    \addop w12, w12, w11
    and   w13, w12, #ASM_PAGE_MASK
.if \size > 1
    sub   w15, w13, #(0x1001 - \size)
    tbz   w15, #31, .Lslow_\name\()_v\rd\rn
.endif
    ubfx  w14, w12, #ASM_PAGE_BITS, #20
    sub   w15, w14, w23
    cbnz  w15, .Lmiss_\name\()_v\rd\rn
.Ldo_\name\()_v\rd\rn:
    \ldop w15, [x27, w13, uxtw]
    RESS  w15, \rd, 0
    NEXT_A
.Lmiss_\name\()_v\rd\rn:
    ldr   x14, [x24, w14, uxtw #3]
    cbz   x14, .Lslow_\name\()_v\rd\rn
    mov   w23, w14
    mov   x27, x14
    b     .Ldo_\name\()_v\rd\rn
.Lslow_\name\()_v\rd\rn:
    MEMSLOW
.endm

.macro V_STR_IMM name, size, stop, addop, rd, rn
    .globl citra_asm_op_\name\()_v\rd\rn
    .hidden citra_asm_op_\name\()_v\rd\rn
citra_asm_op_\name\()_v\rd\rn:
.if (\rd > 2) | (\rn > 2)
    ldr   w10, [x9, #AR0]
.endif
    ldr   w11, [x9, #AR1]
    RESL  w12, \rn, 8
    \addop w12, w12, w11
    and   w13, w12, #ASM_PAGE_MASK
.if \size > 1
    sub   w15, w13, #(0x1001 - \size)
    tbz   w15, #31, .Lslow_\name\()_v\rd\rn
.endif
    ubfx  w14, w12, #ASM_PAGE_BITS, #20
    sub   w15, w14, w23
    cbnz  w15, .Lmiss_\name\()_v\rd\rn
.Ldo_\name\()_v\rd\rn:
    RESL  w15, \rd, 0
    \stop w15, [x27, w13, uxtw]
    NEXT_A
.Lmiss_\name\()_v\rd\rn:
    ldr   x14, [x24, w14, uxtw #3]
    cbz   x14, .Lslow_\name\()_v\rd\rn
    mov   w23, w14
    mov   x27, x14
    b     .Ldo_\name\()_v\rd\rn
.Lslow_\name\()_v\rd\rn:
    MEMSLOW
.endm

.irp rd,0,1,2,3
  .irp rn,0,1,2,3
    .if (\rd < 3) | (\rn < 3)
    V_LDR_IMM ldrw_add, 4, ldr, add, \rd, \rn
    V_LDR_IMM ldrw_sub, 4, ldr, sub, \rd, \rn
    V_STR_IMM strw_add, 4, str, add, \rd, \rn
    V_STR_IMM strw_sub, 4, str, sub, \rd, \rn
    .endif
  .endr
.endr

// ---------------------------------------------------------------------------
// Variant selection table, consulted by the translator only for programs
// where resmask != 0. Index = RESV_* family * 64 + s0*16 + s1*4 + s2, where
// sk = min(guest reg index at operand slot k, 3); 3 = regfile operand or
// absent slot. Entries are 0 where no variant exists (all-regfile combos
// and absent slots) -- the generic handler is correct for those.
// ---------------------------------------------------------------------------
.macro RESV1 name
.irp s0,0,1,2,3
  .irp s1,0,1,2,3
    .irp s2,0,1,2,3
      .if (\s1 == 3) & (\s2 == 3) & (\s0 < 3)
        .word citra_asm_op_\name\()_v\s0 - .
      .else
        .word 0
      .endif
    .endr
  .endr
.endr
.endm

.macro RESV2 name
.irp s0,0,1,2,3
  .irp s1,0,1,2,3
    .irp s2,0,1,2,3
      .if (\s2 == 3) & ((\s0 < 3) | (\s1 < 3))
        .word citra_asm_op_\name\()_v\s0\s1 - .
      .else
        .word 0
      .endif
    .endr
  .endr
.endr
.endm

.macro RESV3 name
.irp s0,0,1,2,3
  .irp s1,0,1,2,3
    .irp s2,0,1,2,3
      .if (\s0 < 3) | (\s1 < 3) | (\s2 < 3)
        .word citra_asm_op_\name\()_v\s0\s1\s2 - .
      .else
        .word 0
      .endif
    .endr
  .endr
.endr
.endm

    .section .rodata
    .p2align 2
    .globl citra_asm_res_variants
citra_asm_res_variants:
    RESV1 mov_imm          // RESV_MOV_IMM
    RESV1 mvn_imm          // RESV_MVN_IMM
    RESV1 ldrw_lit         // RESV_LDRW_LIT
    RESV1 cmp_imm          // RESV_CMP_IMM
    RESV1 cmn_imm          // RESV_CMN_IMM
    RESV2 mov_reg          // RESV_MOV_REG
    RESV2 mvn_reg          // RESV_MVN_REG
    RESV2 movs_reg         // RESV_MOVS_REG
    RESV2 mvns_reg         // RESV_MVNS_REG
    RESV2 cmp_reg          // RESV_CMP_REG
    RESV2 cmn_reg          // RESV_CMN_REG
    RESV2 add_imm          // RESV_ADD_IMM
    RESV2 sub_imm          // RESV_SUB_IMM
    RESV2 and_imm          // RESV_AND_IMM
    RESV2 eor_imm          // RESV_EOR_IMM
    RESV2 orr_imm          // RESV_ORR_IMM
    RESV2 bic_imm          // RESV_BIC_IMM
    RESV2 adc_imm          // RESV_ADC_IMM
    RESV2 sbc_imm          // RESV_SBC_IMM
    RESV2 rsb_imm          // RESV_RSB_IMM
    RESV2 rsc_imm          // RESV_RSC_IMM
    RESV2 adds_imm         // RESV_ADDS_IMM
    RESV2 subs_imm         // RESV_SUBS_IMM
    RESV2 adcs_imm         // RESV_ADCS_IMM
    RESV2 sbcs_imm         // RESV_SBCS_IMM
    RESV2 rsbs_imm         // RESV_RSBS_IMM
    RESV2 rscs_imm         // RESV_RSCS_IMM
    RESV2 ldrw_add         // RESV_LDRW_ADD
    RESV2 ldrw_sub         // RESV_LDRW_SUB
    RESV2 strw_add         // RESV_STRW_ADD
    RESV2 strw_sub         // RESV_STRW_SUB
    RESV3 add_reg          // RESV_ADD_REG
    RESV3 sub_reg          // RESV_SUB_REG
    RESV3 and_reg          // RESV_AND_REG
    RESV3 eor_reg          // RESV_EOR_REG
    RESV3 orr_reg          // RESV_ORR_REG
    RESV3 bic_reg          // RESV_BIC_REG
    RESV3 adc_reg          // RESV_ADC_REG
    RESV3 sbc_reg          // RESV_SBC_REG
    RESV3 rsb_reg          // RESV_RSB_REG
    RESV3 rsc_reg          // RESV_RSC_REG
    RESV3 adds_reg         // RESV_ADDS_REG
    RESV3 subs_reg         // RESV_SUBS_REG
    RESV1 movs_imm         // RESV_MOVS_IMM
