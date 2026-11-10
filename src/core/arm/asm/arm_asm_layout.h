// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

// Shared constants for the AArch64 threaded IR executor.
// This header is consumed both by C++ (arm_asm_exec.h) and by the GNU
// assembler (arm_asm_exec.S via #include), so it must only contain
// preprocessor definitions -- no C++ declarations.

#pragma once

// ---------------------------------------------------------------------------
// AsmExecContext layout (see arm_asm_exec.h for the C++ struct).
// ---------------------------------------------------------------------------
#define ASMCTX_REGS 0        // u32*      guest register file (state->Reg.data())
#define ASMCTX_FLAGS4 8      // u32*      &state->NFlag (N,Z,C,V consecutive u32)
#define ASMCTX_LAZY 16       // void*     &lazy_flags (LazyFlags struct)
#define ASMCTX_PAGETBL 24    // u8*const* page_table->pointers.data()
#define ASMCTX_GUESTSIZE 32  // u32       guest instruction size (2 or 4)
#define ASMCTX_PC 36         // u32       guest pc (in/out)
#define ASMCTX_OPSEXEC 40    // u32       out: guest instructions executed
#define ASMCTX_EXITREASON 44 // u32       out: exit reason
#define ASMCTX_EXITINDEX 48  // u32       out: C++ op index for ASM_EXIT_SLOW
#define ASMCTX_BUDGET 52     // u32       in: guest-instruction budget for chained loops
#define ASMCTX_EXTREG 56     // u32*      state->ExtReg.data() (VFP register file)
#define ASMCTX_CHAIN 64      // AsmChainEntry* block-chain table (may be null)
#define ASMCTX_CPSRKEY 72    // u32       current block's cpsr_key bits
#define ASMCTX_CHAINHITS 76  // u32       out: cross-block chains taken
#define ASMCTX_CHAINMISS 80  // u32       out: chain table misses
#define ASMCTX_EXTAG 88      // u32*      &state->exclusive_tag
#define ASMCTX_EXSTATE 96    // u8*       &state->exclusive_state
#define ASMCTX_RESMASK 104   // u32       resident guest-reg mask (r0-r2 = 0x7)
#define ASMCTX_MISSKEY 108   // u32       out: chain miss: pc/cpsr_key mismatch
#define ASMCTX_MISSBUDGET 112// u32       out: chain miss: budget refused
#define ASMCTX_MISSRES 116   // u32       out: chain resyncs on resmask change
#define ASMCTX_MISSPCKEY 120 // u32       out: chain miss: pc hit, cpsr_key differs
#define ASMCTX_TFLAG 128     // u32*      &state->TFlag (mode-switch writers)
#define ASMCTX_SIZE 136

// Block-chain table: direct-mapped entries of 32 bytes
// {u32 pc, u32 cpsr_key, u64 code, u32 instrs, u32 resmask}.
#define ASMCHAIN_BITS 15
#define ASMCHAIN_SHIFT 5     // log2(entry size)
#define ASMCHAIN_PC 0
#define ASMCHAIN_CPSRKEY 4
#define ASMCHAIN_CODE 8
#define ASMCHAIN_INSTRS 16
#define ASMCHAIN_RES 20

// Resident-variant table families. The .S rodata table
// citra_asm_res_variants[family*64 + s0*16 + s1*4 + s2] maps a residency
// pattern to a variant handler; slot k is the guest register index at the
// family's k-th operand position (3 = regfile operand / absent slot).
#define RESV_MOV_IMM 0
#define RESV_MVN_IMM 1
#define RESV_LDRW_LIT 2
#define RESV_CMP_IMM 3
#define RESV_CMN_IMM 4
#define RESV_MOV_REG 5
#define RESV_MVN_REG 6
#define RESV_MOVS_REG 7
#define RESV_MVNS_REG 8
#define RESV_CMP_REG 9
#define RESV_CMN_REG 10
#define RESV_ADD_IMM 11
#define RESV_SUB_IMM 12
#define RESV_AND_IMM 13
#define RESV_EOR_IMM 14
#define RESV_ORR_IMM 15
#define RESV_BIC_IMM 16
#define RESV_ADC_IMM 17
#define RESV_SBC_IMM 18
#define RESV_RSB_IMM 19
#define RESV_RSC_IMM 20
#define RESV_ADDS_IMM 21
#define RESV_SUBS_IMM 22
#define RESV_ADCS_IMM 23
#define RESV_SBCS_IMM 24
#define RESV_RSBS_IMM 25
#define RESV_RSCS_IMM 26
#define RESV_LDRW_ADD 27
#define RESV_LDRW_SUB 28
#define RESV_STRW_ADD 29
#define RESV_STRW_SUB 30
#define RESV_ADD_REG 31
#define RESV_SUB_REG 32
#define RESV_AND_REG 33
#define RESV_EOR_REG 34
#define RESV_ORR_REG 35
#define RESV_BIC_REG 36
#define RESV_ADC_REG 37
#define RESV_SBC_REG 38
#define RESV_RSB_REG 39
#define RESV_RSC_REG 40
#define RESV_ADDS_REG 41
#define RESV_SUBS_REG 42
#define RESV_MOVS_IMM 43
#define RESV_COUNT 44

// LazyFlags field offsets (ARM_IRInterpreter::LazyFlags).
#define ASMLAZY_VALID 0      // bool
#define ASMLAZY_MASK 1       // u8
#define ASMLAZY_N 4          // u32
#define ASMLAZY_Z 8          // u32
#define ASMLAZY_C 12         // u32
#define ASMLAZY_V 16         // u32

// ---------------------------------------------------------------------------
// AsmOp record: { handler, a0, a1, a2, a3 } -- 40 bytes.
// ---------------------------------------------------------------------------
#define ASMOP_HANDLER 0
#define ASMOP_A0 8
#define ASMOP_A1 16
#define ASMOP_A2 24
#define ASMOP_A3 32
#define ASMOP_SIZE 40

// Exit reasons returned by citra_asm_run / stored in ASMCTX_EXITREASON.
#define ASM_EXIT_END 0  // consumed the whole op stream
#define ASM_EXIT_SLOW 1 // execute C++ op at ASMCTX_EXITINDEX, then continue

// CITRA_PAGE_BITS is 12 (see core/memory.h); keep in sync.
#define ASM_PAGE_BITS 12
#define ASM_PAGE_MASK 0xFFF
