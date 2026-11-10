// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

// Translates an ARMIR::Block into a threaded-code program for
// citra_asm_run. Most IR ops become exactly one 40-byte record; predicated
// ops emit a guard record plus a body record, and conditional-skip records
// carry a record-stream distance patched once the full layout is known.
// Records the handler set cannot execute become ASM_EXIT_SLOW stubs that
// carry the IR op index so the C++ interpreter can replay them.

#include <utility>
#include <vector>

#include "core/arm/asm/arm_asm_exec.h"
#include "core/arm/asm/arm_asm_layout.h"
#include "core/arm/skyeye_common/vfp/vfp_helper.h"
#include "common/settings.h"

namespace Core::ARMAsm {

extern "C" {
#define H(name) void citra_asm_op_##name()
H(end);
H(slow);
H(nop);
H(mov_imm);
H(mov_reg);
H(mvn_reg);
H(mvn_imm);
H(add_imm);
H(sub_imm);
H(and_imm);
H(eor_imm);
H(orr_imm);
H(bic_imm);
H(rsb_imm);
H(adc_imm);
H(sbc_imm);
H(rsc_imm);
H(add_reg);
H(sub_reg);
H(and_reg);
H(eor_reg);
H(orr_reg);
H(bic_reg);
H(adc_reg);
H(sbc_reg);
H(rsb_reg);
H(rsc_reg);
H(adds_imm);
H(subs_imm);
H(adcs_imm);
H(sbcs_imm);
H(rsbs_imm);
H(rscs_imm);
H(adds_reg);
H(subs_reg);
H(cmp_imm);
H(cmn_imm);
H(cmp_reg);
H(cmn_reg);
H(mov_lsl);
H(mov_lsr);
H(mov_asr);
H(mov_ror);
H(mov_lsr32);
H(mov_asr32);
H(mov_rrx);
H(add_shift_lsl);
H(add_shift_lsr);
H(add_shift_asr);
H(add_shift_ror);
H(sub_shift_lsl);
H(sub_shift_lsr);
H(sub_shift_asr);
H(sub_shift_ror);
H(and_shift_lsl);
H(and_shift_lsr);
H(and_shift_asr);
H(and_shift_ror);
H(eor_shift_lsl);
H(eor_shift_lsr);
H(eor_shift_asr);
H(eor_shift_ror);
H(orr_shift_lsl);
H(orr_shift_lsr);
H(orr_shift_asr);
H(orr_shift_ror);
H(bic_shift_lsl);
H(bic_shift_lsr);
H(bic_shift_asr);
H(bic_shift_ror);
H(mov_shift_lsl);
H(mov_shift_lsr);
H(mov_shift_asr);
H(mov_shift_ror);
H(mvn_shift_lsl);
H(mvn_shift_lsr);
H(mvn_shift_asr);
H(mvn_shift_ror);
H(mul);
H(mla);
H(mull);
H(smulh_00);
H(smulh_01);
H(smulh_10);
H(smulh_11);
H(smlah_00);
H(smlah_01);
H(smlah_10);
H(smlah_11);
H(smlalh_00);
H(smlalh_01);
H(smlalh_10);
H(smlalh_11);
H(muls);
H(mlas);
H(mulls);
H(ldrw_lit);
H(ldrb_lit);
H(ldrh_lit);
H(ldrsb_lit);
H(ldrsh_lit);
H(ldrw_add);
H(ldrw_sub);
H(ldrb_add);
H(ldrb_sub);
H(ldrh_add);
H(ldrh_sub);
H(strw_add);
H(strw_sub);
H(strb_add);
H(strb_sub);
H(strh_add);
H(strh_sub);
H(ldrsb_add);
H(ldrsb_sub);
H(ldrsh_add);
H(ldrsh_sub);
H(jmp);
H(chain);
H(brachain_eq);
H(brachain_ne);
H(brachain_cs);
H(brachain_cc);
H(brachain_mi);
H(brachain_pl);
H(brachain_vs);
H(brachain_vc);
H(brachain_hi);
H(brachain_ls);
H(brachain_ge);
H(brachain_lt);
H(brachain_gt);
H(brachain_le);
H(bra_eq);
H(bra_ne);
H(bra_cs);
H(bra_cc);
H(bra_mi);
H(bra_pl);
H(bra_vs);
H(bra_vc);
H(bra_hi);
H(bra_ls);
H(bra_ge);
H(bra_lt);
H(bra_gt);
H(bra_le);
H(cmpbra_eq);
H(cmpbra_ne);
H(cmpbra_cs);
H(cmpbra_cc);
H(cmpbra_mi);
H(cmpbra_pl);
H(cmpbra_vs);
H(cmpbra_vc);
H(cmpbra_hi);
H(cmpbra_ls);
H(cmpbra_ge);
H(cmpbra_lt);
H(cmpbra_gt);
H(cmpbra_le);
H(cmnbra_eq);
H(cmnbra_ne);
H(cmnbra_cs);
H(cmnbra_cc);
H(cmnbra_mi);
H(cmnbra_pl);
H(cmnbra_vs);
H(cmnbra_vc);
H(cmnbra_hi);
H(cmnbra_ls);
H(cmnbra_ge);
H(cmnbra_lt);
H(cmnbra_gt);
H(cmnbra_le);
H(cmprbra_eq);
H(cmprbra_ne);
H(cmprbra_cs);
H(cmprbra_cc);
H(cmprbra_mi);
H(cmprbra_pl);
H(cmprbra_vs);
H(cmprbra_vc);
H(cmprbra_hi);
H(cmprbra_ls);
H(cmprbra_ge);
H(cmprbra_lt);
H(cmprbra_gt);
H(cmprbra_le);
H(cmprbra_eq_cmn);
H(cmprbra_ne_cmn);
H(cmprbra_cs_cmn);
H(cmprbra_cc_cmn);
H(cmprbra_mi_cmn);
H(cmprbra_pl_cmn);
H(cmprbra_vs_cmn);
H(cmprbra_vc_cmn);
H(cmprbra_hi_cmn);
H(cmprbra_ls_cmn);
H(cmprbra_ge_cmn);
H(cmprbra_lt_cmn);
H(cmprbra_gt_cmn);
H(cmprbra_le_cmn);
H(cmpbrachain_eq);
H(cmpbrachain_ne);
H(cmpbrachain_cs);
H(cmpbrachain_cc);
H(cmpbrachain_mi);
H(cmpbrachain_pl);
H(cmpbrachain_vs);
H(cmpbrachain_vc);
H(cmpbrachain_hi);
H(cmpbrachain_ls);
H(cmpbrachain_ge);
H(cmpbrachain_lt);
H(cmpbrachain_gt);
H(cmpbrachain_le);
H(cmnbrachain_eq);
H(cmnbrachain_ne);
H(cmnbrachain_cs);
H(cmnbrachain_cc);
H(cmnbrachain_mi);
H(cmnbrachain_pl);
H(cmnbrachain_vs);
H(cmnbrachain_vc);
H(cmnbrachain_hi);
H(cmnbrachain_ls);
H(cmnbrachain_ge);
H(cmnbrachain_lt);
H(cmnbrachain_gt);
H(cmnbrachain_le);
H(cmprbrachain_eq);
H(cmprbrachain_ne);
H(cmprbrachain_cs);
H(cmprbrachain_cc);
H(cmprbrachain_mi);
H(cmprbrachain_pl);
H(cmprbrachain_vs);
H(cmprbrachain_vc);
H(cmprbrachain_hi);
H(cmprbrachain_ls);
H(cmprbrachain_ge);
H(cmprbrachain_lt);
H(cmprbrachain_gt);
H(cmprbrachain_le);
H(cmprbrachain_eq_cmn);
H(cmprbrachain_ne_cmn);
H(cmprbrachain_cs_cmn);
H(cmprbrachain_cc_cmn);
H(cmprbrachain_mi_cmn);
H(cmprbrachain_pl_cmn);
H(cmprbrachain_vs_cmn);
H(cmprbrachain_vc_cmn);
H(cmprbrachain_hi_cmn);
H(cmprbrachain_ls_cmn);
H(cmprbrachain_ge_cmn);
H(cmprbrachain_lt_cmn);
H(cmprbrachain_gt_cmn);
H(cmprbrachain_le_cmn);
H(skip_eq);
H(skip_ne);
H(skip_cs);
H(skip_cc);
H(skip_mi);
H(skip_pl);
H(skip_vs);
H(skip_vc);
H(skip_hi);
H(skip_ls);
H(skip_ge);
H(skip_lt);
H(skip_gt);
H(skip_le);
H(ldrw_reg_add);
H(ldrw_reg_sub);
H(strw_reg_add);
H(strw_pc_reg_add);
H(strw_pc_reg_sub);
H(strb_pc_reg_add);
H(strb_pc_reg_sub);
H(strw_pc_reg_wb);
H(strw_pc_reg_wb_sub);
H(strb_pc_reg_wb);
H(strb_pc_reg_wb_sub);
H(strw_reg_sub);
H(ldrb_reg_add);
H(ldrb_reg_sub);
H(strb_reg_add);
H(strb_reg_sub);
H(ldrh_reg_add);
H(ldrh_reg_sub);
H(strh_reg_add);
H(strh_reg_sub);
H(ldrsb_reg_add);
H(ldrsb_reg_sub);
H(ldrsh_reg_add);
H(ldrsh_reg_sub);
H(ldrw_wb);
H(ldrw_wb_sub);
H(strw_wb);
H(strw_wb_sub);
H(ldrb_wb);
H(ldrb_wb_sub);
H(strb_wb);
H(strb_wb_sub);
H(ldrh_wb);
H(ldrh_wb_sub);
H(strh_wb);
H(strh_wb_sub);
H(ldrsb_wb);
H(ldrsb_wb_sub);
H(ldrsh_wb);
H(ldrsh_wb_sub);
H(ldrw_reg_wb);
H(ldrw_reg_wb_sub);
H(strw_reg_wb);
H(strw_reg_wb_sub);
H(ldrb_reg_wb);
H(ldrb_reg_wb_sub);
H(strb_reg_wb);
H(strb_reg_wb_sub);
H(ldrh_reg_wb);
H(ldrh_reg_wb_sub);
H(strh_reg_wb);
H(strh_reg_wb_sub);
H(ldrsb_reg_wb);
H(ldrsb_reg_wb_sub);
H(ldrsh_reg_wb);
H(ldrsh_reg_wb_sub);
H(ldrw_pc);
H(ldrw_pc_lit);
H(ldrw_pc_imm);
H(movs_imm);
H(ldrd);
H(ldrd_sub);
H(strd);
H(strd_sub);
H(vlds_add);
H(vlds_sub);
H(vsts_add);
H(vsts_sub);
H(vldd_add);
H(vldd_sub);
H(vstd_add);
H(vstd_sub);
H(vlds_lit);
H(vldd_lit);
H(vldm);
H(vstm);
H(ldm);
H(stm);
H(stmpc);
H(vfp_xfr);
H(vfp_sys);
H(bl);
H(bx);
H(blx);
H(blxi);
H(ldrw_gen);
H(strw_gen);
H(ldmpc);
H(guard_eq);
H(guard_ne);
H(guard_cs);
H(guard_cc);
H(guard_mi);
H(guard_pl);
H(guard_vs);
H(guard_vc);
H(guard_hi);
H(guard_ls);
H(guard_ge);
H(guard_lt);
H(guard_gt);
H(guard_le);
H(tstbra_eq);
H(tstbra_ne);
H(tstbra_cs);
H(tstbra_cc);
H(tstbra_mi);
H(tstbra_pl);
H(tstbra_vs);
H(tstbra_vc);
H(tstbra_hi);
H(tstbra_ls);
H(tstbra_ge);
H(tstbra_lt);
H(tstbra_gt);
H(tstbra_le);
H(tstrbra_eq);
H(tstrbra_ne);
H(tstrbra_cs);
H(tstrbra_cc);
H(tstrbra_mi);
H(tstrbra_pl);
H(tstrbra_vs);
H(tstrbra_vc);
H(tstrbra_hi);
H(tstrbra_ls);
H(tstrbra_ge);
H(tstrbra_lt);
H(tstrbra_gt);
H(tstrbra_le);
H(tst_imm_f);
H(teq_imm_f);
H(vfpdp);
H(vfpmov);
H(mrs);
H(cp15_tls);
H(cp15_rd);
H(cp15_wr);
H(ldrex);
H(strex);
H(movs_shift);
H(carith_shift);
H(logregs_s);
H(logreg_s);
H(logimm_s);
H(logregsh);
H(clrex);
H(clz);
H(movs_reg);
H(mvns_reg);
H(ext);
H(rev);
H(dp_pc);
H(alu_regsh);
H(alu_rm_pc);
H(mov_rlsl);
H(mov_rlsr);
H(mov_rasr);
H(mov_rror);
#define HCOND(name)                                                                            \
    H(name##_eq);                                                                              \
    H(name##_ne);                                                                              \
    H(name##_cs);                                                                              \
    H(name##_cc);                                                                              \
    H(name##_mi);                                                                              \
    H(name##_pl);                                                                              \
    H(name##_vs);                                                                              \
    H(name##_vc);                                                                              \
    H(name##_hi);                                                                              \
    H(name##_ls);                                                                              \
    H(name##_ge);                                                                              \
    H(name##_lt);                                                                              \
    H(name##_gt);                                                                              \
    H(name##_le);
HCOND(asibra)
HCOND(asibrachain)
HCOND(asrbra)
HCOND(asrbrachain)
HCOND(cmpsbra)
HCOND(cmpsbrachain)
H(logsh_s_lsl);
H(logsh_s_lsr);
H(logsh_s_asr);
H(logsh_s_ror);
H(carithsh_s);
HCOND(casrbra)
HCOND(casrbrachain)
HCOND(carbra)
HCOND(carbrachain)
H(cmp_shift);
H(cmn_shift);
HCOND(logrbra)
HCOND(logrbrachain)
HCOND(logrshbra)
HCOND(logrshbrachain)
HCOND(logibra)
HCOND(logibrachain)
H(tblsetup);
H(tblink);
H(tblx);
#undef HCOND
#undef H
// Resident-variant table emitted by arm_asm_exec.S: [RESV_* family * 64 +
// s0*16 + s1*4 + s2] -> variant handler (or 0 = keep the generic handler).
// Offset table emitted by the .S (each entry = variant handler - its own
// slot address, so .rodata stays reloc-free under --warn-shared-textrel).
extern const s32 citra_asm_res_variants[];
}

namespace {

using ARMIR::Opcode;

#define COND_LIST(name)                                                                        \
    citra_asm_op_##name##_eq, citra_asm_op_##name##_ne, citra_asm_op_##name##_cs,                \
        citra_asm_op_##name##_cc, citra_asm_op_##name##_mi, citra_asm_op_##name##_pl,            \
        citra_asm_op_##name##_vs, citra_asm_op_##name##_vc, citra_asm_op_##name##_hi,            \
        citra_asm_op_##name##_ls, citra_asm_op_##name##_ge, citra_asm_op_##name##_lt,            \
        citra_asm_op_##name##_gt, citra_asm_op_##name##_le

// condition-code 0..13 -> handler
constexpr void (*kBraHandlers[14])() = {COND_LIST(bra)};
constexpr void (*kBraChainHandlers[14])() = {COND_LIST(brachain)};
constexpr void (*kCmpBraHandlers[14])() = {COND_LIST(cmpbra)};
constexpr void (*kCmnBraHandlers[14])() = {COND_LIST(cmnbra)};
constexpr void (*kCmpRBraHandlers[14])() = {COND_LIST(cmprbra)};
constexpr void (*kSkipHandlers[14])() = {COND_LIST(skip)};

// cmprbra_<cond>_cmn symbols are ordered identically.
constexpr void (*kCmnRBraCmnHandlers[14])() = {
    citra_asm_op_cmprbra_eq_cmn, citra_asm_op_cmprbra_ne_cmn, citra_asm_op_cmprbra_cs_cmn,
    citra_asm_op_cmprbra_cc_cmn, citra_asm_op_cmprbra_mi_cmn, citra_asm_op_cmprbra_pl_cmn,
    citra_asm_op_cmprbra_vs_cmn, citra_asm_op_cmprbra_vc_cmn, citra_asm_op_cmprbra_hi_cmn,
    citra_asm_op_cmprbra_ls_cmn, citra_asm_op_cmprbra_ge_cmn, citra_asm_op_cmprbra_lt_cmn,
    citra_asm_op_cmprbra_gt_cmn, citra_asm_op_cmprbra_le_cmn};

// Self-loop chain variants (taken pc == block.start_pc -> jump to record 0).
constexpr void (*kGuardHandlers[14])() = {COND_LIST(guard)};
constexpr void (*kTstBraHandlers[14])() = {COND_LIST(tstbra)};
constexpr void (*kTstRBraHandlers[14])() = {COND_LIST(tstrbra)};

constexpr void (*kCmpBraChainHandlers[14])() = {COND_LIST(cmpbrachain)};
constexpr void (*kCmnBraChainHandlers[14])() = {COND_LIST(cmnbrachain)};
constexpr void (*kCmpRBraChainHandlers[14])() = {COND_LIST(cmprbrachain)};
constexpr void (*kCmnRBraChainCmnHandlers[14])() = {
    citra_asm_op_cmprbrachain_eq_cmn, citra_asm_op_cmprbrachain_ne_cmn,
    citra_asm_op_cmprbrachain_cs_cmn, citra_asm_op_cmprbrachain_cc_cmn,
    citra_asm_op_cmprbrachain_mi_cmn, citra_asm_op_cmprbrachain_pl_cmn,
    citra_asm_op_cmprbrachain_vs_cmn, citra_asm_op_cmprbrachain_vc_cmn,
    citra_asm_op_cmprbrachain_hi_cmn, citra_asm_op_cmprbrachain_ls_cmn,
    citra_asm_op_cmprbrachain_ge_cmn, citra_asm_op_cmprbrachain_lt_cmn,
    citra_asm_op_cmprbrachain_gt_cmn, citra_asm_op_cmprbrachain_le_cmn};

constexpr void (*kAsiBraHandlers[14])() = {COND_LIST(asibra)};
constexpr void (*kAsiBraChainHandlers[14])() = {COND_LIST(asibrachain)};
constexpr void (*kAsrBraHandlers[14])() = {COND_LIST(asrbra)};
constexpr void (*kAsrBraChainHandlers[14])() = {COND_LIST(asrbrachain)};
constexpr void (*kCmpsBraHandlers[14])() = {COND_LIST(cmpsbra)};
constexpr void (*kCmpsBraChainHandlers[14])() = {COND_LIST(cmpsbrachain)};
constexpr void (*kCasrBraHandlers[14])() = {COND_LIST(casrbra)};
constexpr void (*kCasrBraChainHandlers[14])() = {COND_LIST(casrbrachain)};
constexpr void (*kCarBraHandlers[14])() = {COND_LIST(carbra)};
constexpr void (*kCarBraChainHandlers[14])() = {COND_LIST(carbrachain)};

// op59 signed-halfword multiplies: [x_high<<1 | y_high] order.
constexpr void (*kSmulHHandlers[4])() = {citra_asm_op_smulh_00, citra_asm_op_smulh_01,
                                         citra_asm_op_smulh_10, citra_asm_op_smulh_11};
constexpr void (*kSmlaHHandlers[4])() = {citra_asm_op_smlah_00, citra_asm_op_smlah_01,
                                         citra_asm_op_smlah_10, citra_asm_op_smlah_11};
constexpr void (*kSmlalHHandlers[4])() = {citra_asm_op_smlalh_00, citra_asm_op_smlalh_01,
                                          citra_asm_op_smlalh_10, citra_asm_op_smlalh_11};
constexpr void (*kLogRBraHandlers[14])() = {COND_LIST(logrbra)};
constexpr void (*kLogRBraChainHandlers[14])() = {COND_LIST(logrbrachain)};
constexpr void (*kLogRsBraHandlers[14])() = {COND_LIST(logrshbra)};
constexpr void (*kLogRsBraChainHandlers[14])() = {COND_LIST(logrshbrachain)};
constexpr void (*kLogIBraHandlers[14])() = {COND_LIST(logibra)};
constexpr void (*kLogIBraChainHandlers[14])() = {COND_LIST(logibrachain)};

// shift_type 0..3 -> mov reg-shifted handler
constexpr void (*kMovRShiftHandlers[4])() = {citra_asm_op_mov_rlsl, citra_asm_op_mov_rlsr,
                                             citra_asm_op_mov_rasr, citra_asm_op_mov_rror};

// ---------------------------------------------------------------------------
// Resident-register program classification (v1.1).
//
// A program may hold guest r0-r2 in host registers for the whole run only
// when every record is provably safe against the stale regfile slots
// (nothing syncs resident regs mid-run, so one unsafe op poisons the whole
// program). Three categories exist:
//  - "clean" handlers never touch the GPR file;
//  - "variant" families swap to *_v* handlers that keep resident operands
//    in the host registers, looked up in citra_asm_res_variants;
//  - "checkable" handlers are safe when every operand nibble encodes a
//    register >= 3 (they only reach untouched regfile slots then).
// ---------------------------------------------------------------------------

// generic handler -> variant family + a0 bit-shift per operand slot
// (255 = slot absent). Slot order matches the .S variant name suffixes.
struct ResFamSpec {
    void (*handler)();
    u8 fam;
    u8 sh[3];
};
constexpr u8 kResNoSlot = 0xFF;
constexpr ResFamSpec kResFams[] = {
    {citra_asm_op_mov_imm, RESV_MOV_IMM, {0, kResNoSlot, kResNoSlot}},
    {citra_asm_op_mvn_imm, RESV_MVN_IMM, {0, kResNoSlot, kResNoSlot}},
    {citra_asm_op_ldrw_lit, RESV_LDRW_LIT, {0, kResNoSlot, kResNoSlot}},
    {citra_asm_op_cmp_imm, RESV_CMP_IMM, {0, kResNoSlot, kResNoSlot}},
    {citra_asm_op_cmn_imm, RESV_CMN_IMM, {0, kResNoSlot, kResNoSlot}},
    {citra_asm_op_mov_reg, RESV_MOV_REG, {0, 8, kResNoSlot}},
    {citra_asm_op_mvn_reg, RESV_MVN_REG, {0, 8, kResNoSlot}},
    {citra_asm_op_movs_reg, RESV_MOVS_REG, {0, 8, kResNoSlot}},
    {citra_asm_op_mvns_reg, RESV_MVNS_REG, {0, 8, kResNoSlot}},
    {citra_asm_op_cmp_reg, RESV_CMP_REG, {0, 8, kResNoSlot}},
    {citra_asm_op_cmn_reg, RESV_CMN_REG, {0, 8, kResNoSlot}},
    {citra_asm_op_add_imm, RESV_ADD_IMM, {0, 8, kResNoSlot}},
    {citra_asm_op_sub_imm, RESV_SUB_IMM, {0, 8, kResNoSlot}},
    {citra_asm_op_and_imm, RESV_AND_IMM, {0, 8, kResNoSlot}},
    {citra_asm_op_eor_imm, RESV_EOR_IMM, {0, 8, kResNoSlot}},
    {citra_asm_op_orr_imm, RESV_ORR_IMM, {0, 8, kResNoSlot}},
    {citra_asm_op_bic_imm, RESV_BIC_IMM, {0, 8, kResNoSlot}},
    {citra_asm_op_adc_imm, RESV_ADC_IMM, {0, 8, kResNoSlot}},
    {citra_asm_op_sbc_imm, RESV_SBC_IMM, {0, 8, kResNoSlot}},
    {citra_asm_op_rsb_imm, RESV_RSB_IMM, {0, 8, kResNoSlot}},
    {citra_asm_op_rsc_imm, RESV_RSC_IMM, {0, 8, kResNoSlot}},
    {citra_asm_op_adds_imm, RESV_ADDS_IMM, {0, 8, kResNoSlot}},
    {citra_asm_op_subs_imm, RESV_SUBS_IMM, {0, 8, kResNoSlot}},
    {citra_asm_op_adcs_imm, RESV_ADCS_IMM, {0, 8, kResNoSlot}},
    {citra_asm_op_sbcs_imm, RESV_SBCS_IMM, {0, 8, kResNoSlot}},
    {citra_asm_op_rsbs_imm, RESV_RSBS_IMM, {0, 8, kResNoSlot}},
    {citra_asm_op_rscs_imm, RESV_RSCS_IMM, {0, 8, kResNoSlot}},
    {citra_asm_op_ldrw_add, RESV_LDRW_ADD, {0, 8, kResNoSlot}},
    {citra_asm_op_ldrw_sub, RESV_LDRW_SUB, {0, 8, kResNoSlot}},
    {citra_asm_op_strw_add, RESV_STRW_ADD, {0, 8, kResNoSlot}},
    {citra_asm_op_strw_sub, RESV_STRW_SUB, {0, 8, kResNoSlot}},
    {citra_asm_op_add_reg, RESV_ADD_REG, {0, 8, 16}},
    {citra_asm_op_sub_reg, RESV_SUB_REG, {0, 8, 16}},
    {citra_asm_op_and_reg, RESV_AND_REG, {0, 8, 16}},
    {citra_asm_op_eor_reg, RESV_EOR_REG, {0, 8, 16}},
    {citra_asm_op_orr_reg, RESV_ORR_REG, {0, 8, 16}},
    {citra_asm_op_bic_reg, RESV_BIC_REG, {0, 8, 16}},
    {citra_asm_op_adc_reg, RESV_ADC_REG, {0, 8, 16}},
    {citra_asm_op_sbc_reg, RESV_SBC_REG, {0, 8, 16}},
    {citra_asm_op_rsb_reg, RESV_RSB_REG, {0, 8, 16}},
    {citra_asm_op_rsc_reg, RESV_RSC_REG, {0, 8, 16}},
    {citra_asm_op_adds_reg, RESV_ADDS_REG, {0, 8, 16}},
    {citra_asm_op_subs_reg, RESV_SUBS_REG, {0, 8, 16}},
    {citra_asm_op_movs_imm, RESV_MOVS_IMM, {0, kResNoSlot, kResNoSlot}},
};

const ResFamSpec* ResFamOf(void (*handler)()) {
    for (const ResFamSpec& spec : kResFams) {
        if (spec.handler == handler) {
            return &spec;
        }
    }
    return nullptr;
}

// Handlers that provably never touch guest GPRs. Guard/branch/skip
// cond-families are matched by table membership; the rest are singletons.
// (ldm/stm are not here -- they need the register-mask check below.)
bool ResCleanHandler(void (*handler)()) {
    static constexpr void (*kClean[])() = {
        citra_asm_op_end,   citra_asm_op_slow,   citra_asm_op_nop,
        citra_asm_op_jmp,   citra_asm_op_chain,  citra_asm_op_bl,
        citra_asm_op_blxi,  citra_asm_op_tblx,
        citra_asm_op_tblsetup, citra_asm_op_tblink, citra_asm_op_clrex,
        citra_asm_op_vfpdp, citra_asm_op_vfpmov,
        citra_asm_op_vlds_lit, citra_asm_op_vldd_lit,
    };
    for (void (*h)() : kClean) {
        if (h == handler) {
            return true;
        }
    }
    for (void (*h)() : kBraHandlers) {
        if (h == handler) {
            return true;
        }
    }
    for (void (*h)() : kBraChainHandlers) {
        if (h == handler) {
            return true;
        }
    }
    for (void (*h)() : kGuardHandlers) {
        if (h == handler) {
            return true;
        }
    }
    for (void (*h)() : kSkipHandlers) {
        if (h == handler) {
            return true;
        }
    }
    return false;
}

// Checkable spec: safe when every operand nibble selected by the masks is
// >= 3. Each mask bit selects a 4-bit operand field in a0/a1 (bit n =
// nibble n = bits [4n+3:4n]). ldm_mask additionally requires (a1 & 7) == 0
// so the ldm/stm register list cannot name a resident register.
struct ResCheckSpec {
    void (*handler)();
    u8 a0_nib;
    u8 a1_nib;
    bool ldm_mask;
};
constexpr ResCheckSpec kResCheckable[] = {
    {citra_asm_op_bx, 0b1, 0, false},
    {citra_asm_op_blx, 0b1, 0, false},
    {citra_asm_op_dp_pc, 0b110, 0, false},
    {citra_asm_op_mul, 0b10101, 0, false},
    {citra_asm_op_muls, 0b10101, 0, false},
    {citra_asm_op_mla, 0b1010101, 0, false},
    {citra_asm_op_mlas, 0b1010101, 0, false},
    {citra_asm_op_mull, 0b1010101, 0, false},
    {citra_asm_op_mulls, 0b1010101, 0, false},
    {citra_asm_op_clz, 0b101, 0, false},
    {citra_asm_op_ext, 0, 0b101, false},
    {citra_asm_op_rev, 0, 0b101, false},
    {citra_asm_op_mov_lsr32, 0b101, 0, false},
    {citra_asm_op_mov_asr32, 0b101, 0, false},
    {citra_asm_op_mov_rrx, 0b101, 0, false},
    {citra_asm_op_mov_rlsl, 0b10101, 0, false},
    {citra_asm_op_mov_rlsr, 0b10101, 0, false},
    {citra_asm_op_mov_rasr, 0b10101, 0, false},
    {citra_asm_op_mov_rror, 0b10101, 0, false},
    {citra_asm_op_movs_shift, 0b101, 0, false},
    {citra_asm_op_carith_shift, 0b11100, 0, false},
    {citra_asm_op_carithsh_s, 0, 0b10101, false},
    {citra_asm_op_logregs_s, 0, 0b1010101, false},
    {citra_asm_op_logreg_s, 0, 0b10101, false},
    {citra_asm_op_logregsh, 0, 0b1010101, false},
    {citra_asm_op_logimm_s, 0, 0b101, false},
    {citra_asm_op_alu_regsh, 0, 0b1010101, false},
    {citra_asm_op_alu_rm_pc, 0, 0b101, false},
    {citra_asm_op_mrs, 0b1, 0, false},
    {citra_asm_op_vfp_sys, 0b100, 0, false},
    {citra_asm_op_vfp_xfr, 0b1100, 0, false},
    {citra_asm_op_ldrex, 0b101, 0, false},
    {citra_asm_op_strex, 0b10101, 0, false},
    {citra_asm_op_ldrw_gen, 0b101, 0, false},
    {citra_asm_op_strw_gen, 0b101, 0, false},
    {citra_asm_op_tst_imm_f, 0b1, 0, false},
    {citra_asm_op_teq_imm_f, 0b1, 0, false},
    {citra_asm_op_ldrb_add, 0b101, 0, false},
    {citra_asm_op_ldrb_sub, 0b101, 0, false},
    {citra_asm_op_strb_add, 0b101, 0, false},
    {citra_asm_op_strb_sub, 0b101, 0, false},
    {citra_asm_op_ldrh_add, 0b101, 0, false},
    {citra_asm_op_ldrh_sub, 0b101, 0, false},
    {citra_asm_op_strh_add, 0b101, 0, false},
    {citra_asm_op_strh_sub, 0b101, 0, false},
    {citra_asm_op_ldrsb_add, 0b101, 0, false},
    {citra_asm_op_ldrsb_sub, 0b101, 0, false},
    {citra_asm_op_ldrsh_add, 0b101, 0, false},
    {citra_asm_op_ldrsh_sub, 0b101, 0, false},
    {citra_asm_op_ldrb_lit, 0b1, 0, false},
    {citra_asm_op_ldrh_lit, 0b1, 0, false},
    {citra_asm_op_ldrsb_lit, 0b1, 0, false},
    {citra_asm_op_ldrsh_lit, 0b1, 0, false},
    {citra_asm_op_ldrw_reg_add, 0b10101, 0, false},
    {citra_asm_op_ldrw_reg_sub, 0b10101, 0, false},
    {citra_asm_op_strw_reg_add, 0b10101, 0, false},
    {citra_asm_op_strw_reg_sub, 0b10101, 0, false},
    {citra_asm_op_ldrb_reg_add, 0b10101, 0, false},
    {citra_asm_op_ldrb_reg_sub, 0b10101, 0, false},
    {citra_asm_op_strb_reg_add, 0b10101, 0, false},
    {citra_asm_op_strb_reg_sub, 0b10101, 0, false},
    {citra_asm_op_ldrh_reg_add, 0b101, 0b1, false},
    {citra_asm_op_ldrh_reg_sub, 0b101, 0b1, false},
    {citra_asm_op_strh_reg_add, 0b101, 0b1, false},
    {citra_asm_op_strh_reg_sub, 0b101, 0b1, false},
    {citra_asm_op_ldrsb_reg_add, 0b101, 0b1, false},
    {citra_asm_op_ldrsb_reg_sub, 0b101, 0b1, false},
    {citra_asm_op_ldrsh_reg_add, 0b101, 0b1, false},
    {citra_asm_op_ldrsh_reg_sub, 0b101, 0b1, false},
    {citra_asm_op_ldrw_wb, 0b101, 0, false},
    {citra_asm_op_ldrw_wb_sub, 0b101, 0, false},
    {citra_asm_op_strw_wb, 0b101, 0, false},
    {citra_asm_op_strw_wb_sub, 0b101, 0, false},
    {citra_asm_op_ldrb_wb, 0b101, 0, false},
    {citra_asm_op_ldrb_wb_sub, 0b101, 0, false},
    {citra_asm_op_strb_wb, 0b101, 0, false},
    {citra_asm_op_strb_wb_sub, 0b101, 0, false},
    {citra_asm_op_ldrh_wb, 0b101, 0, false},
    {citra_asm_op_ldrh_wb_sub, 0b101, 0, false},
    {citra_asm_op_strh_wb, 0b101, 0, false},
    {citra_asm_op_strh_wb_sub, 0b101, 0, false},
    {citra_asm_op_ldrsb_wb, 0b101, 0, false},
    {citra_asm_op_ldrsb_wb_sub, 0b101, 0, false},
    {citra_asm_op_ldrsh_wb, 0b101, 0, false},
    {citra_asm_op_ldrsh_wb_sub, 0b101, 0, false},
    {citra_asm_op_ldrd, 0b101, 0, false},
    {citra_asm_op_ldrd_sub, 0b101, 0, false},
    {citra_asm_op_strd, 0b101, 0, false},
    {citra_asm_op_strd_sub, 0b101, 0, false},
    // *_reg_wb (word/byte): a0 = rd|rn<<8|rm<<16|add<<20|pre<<21.
    {citra_asm_op_ldrw_reg_wb, 0b10101, 0, false},
    {citra_asm_op_ldrw_reg_wb_sub, 0b10101, 0, false},
    {citra_asm_op_strw_reg_wb, 0b10101, 0, false},
    {citra_asm_op_strw_reg_wb_sub, 0b10101, 0, false},
    {citra_asm_op_ldrb_reg_wb, 0b10101, 0, false},
    {citra_asm_op_ldrb_reg_wb_sub, 0b10101, 0, false},
    {citra_asm_op_strb_reg_wb, 0b10101, 0, false},
    {citra_asm_op_strb_reg_wb_sub, 0b10101, 0, false},
    // ldrw_pc: rd is the pc slot; only rn (a0 nibble 2) and rm (nibble 4)
    // can be resident.
    {citra_asm_op_ldrw_pc, 0b10100, 0, false},
    // ldrw_pc_lit: rm is the only guest operand (a0 nibble 0).
    {citra_asm_op_ldrw_pc_lit, 0b1, 0, false},
    // ldrw_pc_imm: rn is the only guest operand (a0 nibble 0).
    {citra_asm_op_ldrw_pc_imm, 0b1, 0, false},
    // *_reg_wb (halfword/signed): a0 = rd|rn<<8|add<<16|pre<<17, a1 = rm.
    {citra_asm_op_ldrh_reg_wb, 0b101, 0b1, false},
    {citra_asm_op_ldrh_reg_wb_sub, 0b101, 0b1, false},
    {citra_asm_op_strh_reg_wb, 0b101, 0b1, false},
    {citra_asm_op_strh_reg_wb_sub, 0b101, 0b1, false},
    {citra_asm_op_ldrsb_reg_wb, 0b101, 0b1, false},
    {citra_asm_op_ldrsb_reg_wb_sub, 0b101, 0b1, false},
    {citra_asm_op_ldrsh_reg_wb, 0b101, 0b1, false},
    {citra_asm_op_ldrsh_reg_wb_sub, 0b101, 0b1, false},
    {citra_asm_op_vlds_add, 0b100, 0, false},
    {citra_asm_op_vlds_sub, 0b100, 0, false},
    {citra_asm_op_vsts_add, 0b100, 0, false},
    {citra_asm_op_vsts_sub, 0b100, 0, false},
    {citra_asm_op_vldd_add, 0b100, 0, false},
    {citra_asm_op_vldd_sub, 0b100, 0, false},
    {citra_asm_op_vstd_add, 0b100, 0, false},
    {citra_asm_op_vstd_sub, 0b100, 0, false},
    {citra_asm_op_vldm, 0b100, 0, false},
    {citra_asm_op_vstm, 0b100, 0, false},
    {citra_asm_op_ldm, 0b1, 0, true},
    {citra_asm_op_stm, 0b1, 0, true},
    {citra_asm_op_ldmpc, 0b1, 0, true},
    // MOV_SHIFT: a0 = rd|rm<<8|amount<<16.
    {citra_asm_op_mov_lsl, 0b101, 0, false},
    {citra_asm_op_mov_lsr, 0b101, 0, false},
    {citra_asm_op_mov_asr, 0b101, 0, false},
    {citra_asm_op_mov_ror, 0b101, 0, false},
    // CMPSH: a0 = rn|rm<<8 (compares write no rd).
    {citra_asm_op_cmp_shift, 0b101, 0, false},
    {citra_asm_op_cmn_shift, 0b101, 0, false},
    // cp15 TLS read: a0 low nibble is the rd destination.
    {citra_asm_op_cp15_tls, 0b1, 0, false},
    // LOGSH_S: a1 = rd|rn<<8|rm<<16.
    {citra_asm_op_logsh_s_lsl, 0, 0b10101, false},
    {citra_asm_op_logsh_s_lsr, 0, 0b10101, false},
    {citra_asm_op_logsh_s_asr, 0, 0b10101, false},
    {citra_asm_op_logsh_s_ror, 0, 0b10101, false},
    // ALU_SHIFT: a0 = rd|rn<<8|rm<<16|amount<<24.
    {citra_asm_op_add_shift_lsl, 0b10101, 0, false},
    {citra_asm_op_add_shift_lsr, 0b10101, 0, false},
    {citra_asm_op_add_shift_asr, 0b10101, 0, false},
    {citra_asm_op_add_shift_ror, 0b10101, 0, false},
    {citra_asm_op_sub_shift_lsl, 0b10101, 0, false},
    {citra_asm_op_sub_shift_lsr, 0b10101, 0, false},
    {citra_asm_op_sub_shift_asr, 0b10101, 0, false},
    {citra_asm_op_sub_shift_ror, 0b10101, 0, false},
    {citra_asm_op_and_shift_lsl, 0b10101, 0, false},
    {citra_asm_op_and_shift_lsr, 0b10101, 0, false},
    {citra_asm_op_and_shift_asr, 0b10101, 0, false},
    {citra_asm_op_and_shift_ror, 0b10101, 0, false},
    {citra_asm_op_eor_shift_lsl, 0b10101, 0, false},
    {citra_asm_op_eor_shift_lsr, 0b10101, 0, false},
    {citra_asm_op_eor_shift_asr, 0b10101, 0, false},
    {citra_asm_op_eor_shift_ror, 0b10101, 0, false},
    {citra_asm_op_orr_shift_lsl, 0b10101, 0, false},
    {citra_asm_op_orr_shift_lsr, 0b10101, 0, false},
    {citra_asm_op_orr_shift_asr, 0b10101, 0, false},
    {citra_asm_op_orr_shift_ror, 0b10101, 0, false},
    {citra_asm_op_bic_shift_lsl, 0b10101, 0, false},
    {citra_asm_op_bic_shift_lsr, 0b10101, 0, false},
    {citra_asm_op_bic_shift_asr, 0b10101, 0, false},
    {citra_asm_op_bic_shift_ror, 0b10101, 0, false},
    // MOVN_SHIFT: same a0 layout but rn is ignored (two-operand form).
    {citra_asm_op_mov_shift_lsl, 0b10001, 0, false},
    {citra_asm_op_mov_shift_lsr, 0b10001, 0, false},
    {citra_asm_op_mov_shift_asr, 0b10001, 0, false},
    {citra_asm_op_mov_shift_ror, 0b10001, 0, false},
    {citra_asm_op_mvn_shift_lsl, 0b10001, 0, false},
    {citra_asm_op_mvn_shift_lsr, 0b10001, 0, false},
    {citra_asm_op_mvn_shift_asr, 0b10001, 0, false},
    {citra_asm_op_mvn_shift_ror, 0b10001, 0, false},
    // str pc: rd is the constant 15; rn/rm are the checked operand nibbles.
    {citra_asm_op_strw_pc_reg_add, 0b10101, 0, false},
    {citra_asm_op_strw_pc_reg_sub, 0b10101, 0, false},
    {citra_asm_op_strb_pc_reg_add, 0b10101, 0, false},
    {citra_asm_op_strb_pc_reg_sub, 0b10101, 0, false},
    {citra_asm_op_strw_pc_reg_wb, 0b10101, 0, false},
    {citra_asm_op_strw_pc_reg_wb_sub, 0b10101, 0, false},
    {citra_asm_op_strb_pc_reg_wb, 0b10101, 0, false},
    {citra_asm_op_strb_pc_reg_wb_sub, 0b10101, 0, false},
    // stm {...pc}: rn in a0 nibble0; register list in a1 (ldm_mask rule).
    {citra_asm_op_stmpc, 0b1, 0, true},
    // cp15 rd/wr: rd in a0 nibble0.
    {citra_asm_op_cp15_rd, 0b1, 0, false},
    {citra_asm_op_cp15_wr, 0b1, 0, false},
    // signed-halfword multiplies: a1 carries rd|rm<<8|rs<<16|rn<<24
    // (non-long) or rd_lo|rd_hi<<8|rn<<16|rm<<24 (long) -> nibbles 0,2,4,6.
    {citra_asm_op_smulh_00, 0, 0b01010101, false},
    {citra_asm_op_smulh_01, 0, 0b01010101, false},
    {citra_asm_op_smulh_10, 0, 0b01010101, false},
    {citra_asm_op_smulh_11, 0, 0b01010101, false},
    {citra_asm_op_smlah_00, 0, 0b01010101, false},
    {citra_asm_op_smlah_01, 0, 0b01010101, false},
    {citra_asm_op_smlah_10, 0, 0b01010101, false},
    {citra_asm_op_smlah_11, 0, 0b01010101, false},
    {citra_asm_op_smlalh_00, 0, 0b01010101, false},
    {citra_asm_op_smlalh_01, 0, 0b01010101, false},
    {citra_asm_op_smlalh_10, 0, 0b01010101, false},
    {citra_asm_op_smlalh_11, 0, 0b01010101, false},
};

// Fused compare/test+branch cond-families: same nibble-masking rule on a0.
struct ResCondCheckable {
    void (*const*handlers)();
    u8 a0_nib;
};
constexpr ResCondCheckable kResCondCheckable[] = {
    {kCmpBraHandlers, 0b1},      {kCmpBraChainHandlers, 0b1},
    {kCmnBraHandlers, 0b1},      {kCmnBraChainHandlers, 0b1},
    {kCmpRBraHandlers, 0b101},   {kCmnRBraCmnHandlers, 0b101},
    {kCmpRBraChainHandlers, 0b101}, {kCmnRBraChainCmnHandlers, 0b101},
    {kTstBraHandlers, 0b1},      {kTstRBraHandlers, 0b11},
    {kAsiBraHandlers, 0b11},     {kAsiBraChainHandlers, 0b11},
    {kAsrBraHandlers, 0b111},    {kAsrBraChainHandlers, 0b111},
    {kCmpsBraHandlers, 0b11},    {kCmpsBraChainHandlers, 0b11},
    {kCasrBraHandlers, 0b11110}, {kCasrBraChainHandlers, 0b11110},
    {kCarBraHandlers, 0b1110},  {kCarBraChainHandlers, 0b1110},
    {kLogRBraHandlers, 0b1110},  {kLogRBraChainHandlers, 0b1110},
    {kLogRsBraHandlers, 0b11110}, {kLogRsBraChainHandlers, 0b11110},
    {kLogIBraHandlers, 0b110},   {kLogIBraChainHandlers, 0b110},
};

bool ResNibblesSafe(u64 value, u8 nib_mask) {
    for (u8 n = 0; n < 8; ++n) {
        if (((nib_mask >> n) & 1) && ((value >> (4 * n)) & 0xF) < 3) {
            return false;
        }
    }
    return true;
}

// True when `handler` (with the emitted record's a0/a1) cannot observe or
// corrupt resident-register state.
bool ResCheckableSafe(void (*handler)(), u64 a0, u64 a1) {
    for (const ResCheckSpec& spec : kResCheckable) {
        if (spec.handler != handler) {
            continue;
        }
        if (spec.ldm_mask && (a1 & 7)) {
            return false;
        }
        return ResNibblesSafe(a0, spec.a0_nib) && ResNibblesSafe(a1, spec.a1_nib);
    }
    for (const ResCondCheckable& spec : kResCondCheckable) {
        for (u32 c = 0; c < 14; ++c) {
            if (spec.handlers[c] == handler) {
                return ResNibblesSafe(a0, spec.a0_nib);
            }
        }
    }
    return false;
}

// Variant handler for a variant-family record, or 0 when the operand mix
// stays on the generic handler (all regfile operands) / is impossible.
u64 ResVariantOf(const ResFamSpec& fam, u64 a0) {
    u32 key = 0;
    u32 scale = 16; // s0*16 + s1*4 + s2
    for (u32 k = 0; k < 3; ++k) {
        const u32 idx =
            fam.sh[k] == kResNoSlot ? 3 : std::min<u32>((a0 >> fam.sh[k]) & 0xF, 3);
        key += idx * scale;
        scale /= 4;
    }
    const s32* slot = &citra_asm_res_variants[fam.fam * 64 + key];
    return *slot ? reinterpret_cast<u64>(reinterpret_cast<const u8*>(slot) + *slot) : 0;
}

constexpr u32 kArmCondAl = 14;

// ARMul_State field offsets the .S handlers bake in relative to the ExtReg
// base pointer (x22). VFP[] and CP15[] precede ExtReg; Cpsr/Spsr_copy follow
// it after u32 Emulate.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Winvalid-offsetof"
static_assert(static_cast<std::ptrdiff_t>(offsetof(ARMul_State, VFP)) -
                      static_cast<std::ptrdiff_t>(offsetof(ARMul_State, ExtReg)) ==
                  -28,
              "vfp_sys/cp15_tls assume VFP[0] is 7 words below ExtReg");
static_assert(static_cast<std::ptrdiff_t>(offsetof(ARMul_State, CP15)) -
                      static_cast<std::ptrdiff_t>(offsetof(ARMul_State, ExtReg)) ==
                  -364,
              "cp15_tls assumes CP15[0] is 91 words below ExtReg");
static_assert(static_cast<std::ptrdiff_t>(offsetof(ARMul_State, Cpsr)) -
                      static_cast<std::ptrdiff_t>(offsetof(ARMul_State, ExtReg)) ==
                  260,
              "mrs assumes Cpsr is 260 bytes above ExtReg");
static_assert(static_cast<std::ptrdiff_t>(offsetof(ARMul_State, Spsr_copy)) -
                      static_cast<std::ptrdiff_t>(offsetof(ARMul_State, ExtReg)) ==
                  264,
              "mrs assumes Spsr_copy is 264 bytes above ExtReg");
static_assert(static_cast<std::ptrdiff_t>(offsetof(ARMul_State, Mode)) -
                      static_cast<std::ptrdiff_t>(offsetof(ARMul_State, ExtReg)) ==
                  272,
              "cp15_rd/cp15_wr assume Mode is 272 bytes above ExtReg");
static_assert(CP15_THREAD_UPRW == 69 && CP15_THREAD_URO == 70,
              "cp15_tls bakes in the thread-register CP15 indices");
#pragma GCC diagnostic pop

ARMIR::AsmOp MakeRecord(void (*handler)(), u64 a0 = 0, u64 a1 = 0, u64 a2 = 0, u64 a3 = 0) {
    return ARMIR::AsmOp{.handler = reinterpret_cast<u64>(handler), .a0 = a0, .a1 = a1, .a2 = a2, .a3 = a3};
}

ARMIR::AsmOp MakeSlow(u32 op_index) {
    return MakeRecord(citra_asm_op_slow, op_index);
}

// Maps data_opcode -> non-flag immediate handler for the "arithmetic"
// IR families. Returns nullptr when the opcode needs a slow exit.
// Value of operand2 when the shifted operand register is the pc: the pc
// constant is known at translate time, so the shift folds. RRX
// (shift_type==3 && shift_imm==0) reads the live C flag -- not foldable.
u32 FoldShiftedPcConst(u32 pc_const, u32 shift_type, u32 shift_imm) {
    switch (shift_type) {
    case 0:
        return pc_const << shift_imm;
    case 1:
        return shift_imm == 0 ? 0 : pc_const >> shift_imm;
    case 2:
        return static_cast<u32>(static_cast<s32>(pc_const) >>
                                (shift_imm == 0 ? 31 : shift_imm));
    default:
        return (pc_const >> shift_imm) | (pc_const << (32 - shift_imm));
    }
}

void (*ArithImmHandler(u32 data_opcode))() {
    switch (data_opcode) {
    case 2:
        return citra_asm_op_sub_imm;
    case 3:
        return citra_asm_op_rsb_imm;
    case 4:
        return citra_asm_op_add_imm;
    case 5:
        return citra_asm_op_adc_imm;
    case 6:
        return citra_asm_op_sbc_imm;
    case 7:
        return citra_asm_op_rsc_imm;
    default:
        return nullptr; // logical immediates are handled separately
    }
}

void (*ArithRegHandler(u32 data_opcode))() {
    switch (data_opcode) {
    case 2:
        return citra_asm_op_sub_reg;
    case 3:
        return citra_asm_op_rsb_reg;
    case 4:
        return citra_asm_op_add_reg;
    case 5:
        return citra_asm_op_adc_reg;
    case 6:
        return citra_asm_op_sbc_reg;
    case 7:
        return citra_asm_op_rsc_reg;
    default:
        return nullptr;
    }
}

void (*LogicalImmHandler(u32 data_opcode))() {
    switch (data_opcode) {
    case 0:
        return citra_asm_op_and_imm;
    case 1:
        return citra_asm_op_eor_imm;
    case 12:
        return citra_asm_op_orr_imm;
    case 14:
        return citra_asm_op_bic_imm;
    default:
        return nullptr; // 13/15 (mov/mvn) handled separately
    }
}

void (*LogicalRegHandler(u32 data_opcode))() {
    switch (data_opcode) {
    case 0:
        return citra_asm_op_and_reg;
    case 1:
        return citra_asm_op_eor_reg;
    case 12:
        return citra_asm_op_orr_reg;
    case 14:
        return citra_asm_op_bic_reg;
    default:
        return nullptr;
    }
}

// Handler for "rd = rn OP (rm SHIFT #amount)" with a separate shift
// dispatch. amount==0 encodings of lsr/asr/ror have non-standard operand
// semantics in the IR; those become slow exits.
void (*ShiftedAluHandler(u32 data_opcode, u32 shift_type))() {
    if (data_opcode == 4) { // ADD
        switch (shift_type) {
        case 0:
            return citra_asm_op_add_shift_lsl;
        case 1:
            return citra_asm_op_add_shift_lsr;
        case 2:
            return citra_asm_op_add_shift_asr;
        case 3:
            return citra_asm_op_add_shift_ror;
        }
    } else if (data_opcode == 2) { // SUB
        switch (shift_type) {
        case 0:
            return citra_asm_op_sub_shift_lsl;
        case 1:
            return citra_asm_op_sub_shift_lsr;
        case 2:
            return citra_asm_op_sub_shift_asr;
        case 3:
            return citra_asm_op_sub_shift_ror;
        }
    } else if (data_opcode == 0) { // AND
        switch (shift_type) {
        case 0:
            return citra_asm_op_and_shift_lsl;
        case 1:
            return citra_asm_op_and_shift_lsr;
        case 2:
            return citra_asm_op_and_shift_asr;
        case 3:
            return citra_asm_op_and_shift_ror;
        }
    } else if (data_opcode == 1) { // EOR
        switch (shift_type) {
        case 0:
            return citra_asm_op_eor_shift_lsl;
        case 1:
            return citra_asm_op_eor_shift_lsr;
        case 2:
            return citra_asm_op_eor_shift_asr;
        case 3:
            return citra_asm_op_eor_shift_ror;
        }
    } else if (data_opcode == 12) { // ORR
        switch (shift_type) {
        case 0:
            return citra_asm_op_orr_shift_lsl;
        case 1:
            return citra_asm_op_orr_shift_lsr;
        case 2:
            return citra_asm_op_orr_shift_asr;
        case 3:
            return citra_asm_op_orr_shift_ror;
        }
    } else if (data_opcode == 13) { // MOV (rn ignored)
        switch (shift_type) {
        case 0:
            return citra_asm_op_mov_shift_lsl;
        case 1:
            return citra_asm_op_mov_shift_lsr;
        case 2:
            return citra_asm_op_mov_shift_asr;
        case 3:
            return citra_asm_op_mov_shift_ror;
        }
    } else if (data_opcode == 14) { // BIC
        switch (shift_type) {
        case 0:
            return citra_asm_op_bic_shift_lsl;
        case 1:
            return citra_asm_op_bic_shift_lsr;
        case 2:
            return citra_asm_op_bic_shift_asr;
        case 3:
            return citra_asm_op_bic_shift_ror;
        }
    } else if (data_opcode == 15) { // MVN (rn ignored)
        switch (shift_type) {
        case 0:
            return citra_asm_op_mvn_shift_lsl;
        case 1:
            return citra_asm_op_mvn_shift_lsr;
        case 2:
            return citra_asm_op_mvn_shift_asr;
        case 3:
            return citra_asm_op_mvn_shift_ror;
        }
    }
    return nullptr;
}

struct Builder {
    // Tag bit marking an a0/a1/a2 field as an unresolved record reference.
    // Immediates are 32-bit so bit63 can never collide with real args.
    static constexpr u64 kSentinelBit = u64{1} << 63;
    // kSentinelBit|0 -> terminator record; kSentinelBit|(index+1) -> record.
    static constexpr u64 kEndTarget = kSentinelBit;
    // kSentinelBit|kBlockStartIndex -> record 0 (self-loop chain target).
    static constexpr u64 kBlockStartIndex = 0xFFFFFFFE;
    static constexpr u64 kBlockStartTarget = kSentinelBit | kBlockStartIndex;

    std::vector<ARMIR::AsmOp> ops;

    // Record reference for a branch to guest_pc. Cross-block targets exit
    // to the terminator: the C++ loop re-enters the block cache, which
    // preserves per-block instruction-budget checks exactly like the switch
    // interpreter. A branch whose target is this block's own start_pc is a
    // self-loop and jumps back to record 0 through a *chain handler that
    // replicates the same budget check in assembly.
    static u64 ResolveTarget(u32 /*target_pc*/) {
        return kEndTarget;
    }

    void Finish() {
        ops.push_back(MakeRecord(citra_asm_op_end));
        ARMIR::AsmOp* const base = ops.data();
        ARMIR::AsmOp* const end = base + ops.size() - 1;
        for (ARMIR::AsmOp& rec : ops) {
            for (u64* field : {&rec.a0, &rec.a1, &rec.a2}) {
                const u64 v = *field;
                if ((v & kSentinelBit) == 0) {
                    continue;
                }
                const u64 index = v & ~kSentinelBit;
                if (index == kBlockStartIndex) {
                    *field = reinterpret_cast<u64>(base);
                } else {
                    *field = reinterpret_cast<u64>(index == 0 ? end : base + index - 1);
                }
            }
        }
    }
};

} // namespace

std::shared_ptr<ARMIR::AsmProgram> BuildProgram(const ARMIR::Block& block) {
    Builder b{};
    const std::size_t count = block.ops.size();
    const u32 asm_mask = Settings::values.cpu_asm_mask.GetValue();
    b.ops.reserve(count + 1);

    // Record-stream layout tracking. Conditional-skip records jump over the
    // skipped ops by a *record byte* distance -- an op that emits more than
    // one record (guard+body) would otherwise misalign the landing point.
    std::vector<u32> first_rec_of_op(count);
    std::vector<std::pair<u32, u32>> pending_skips; // {skip rec idx, landing op idx}
    // block.ops may contain zero-size meta records (ConditionalSkip runs,
    // guest_size == 0) that occupy an ops slot but no guest instruction.
    // All pc-relative constants must therefore accumulate guest_size rather
    // than scaling the ops index i.
    u64 instr_off = 0;

    for (std::size_t i = 0; i < count; ++i) {
        const ARMIR::Op& op = block.ops[i];
        first_rec_of_op[i] = static_cast<u32>(b.ops.size());
        ARMIR::AsmOp rec = MakeSlow(static_cast<u32>(i));
        const u64 instr_addr_i = block.start_pc + instr_off;
        instr_off += op.guest_size;
        // Translate-time pc operand constant used by the *Always opcodes:
        // ReadDataRegister returns (Reg[15] & ~1) + guest_size*2.
        [[maybe_unused]] const u32 pc_const_i =
            static_cast<u32>(instr_addr_i + 2ULL * op.guest_size);
        // ReadAddressRegister instead returns (Reg[15] & ~3) + guest_size*2
        // (literal-pool addressing rounds down to a 4-byte boundary).
        [[maybe_unused]] const u32 pc_addr_i =
            static_cast<u32>((instr_addr_i & ~3ULL) + 2ULL * op.guest_size);

        switch (op.opcode) {
        // -- unconditional direct branch ---------------------------------
        case Opcode::ArmBranchAlways:
            // Self-loop (target == this block's start) stays in assembly:
            // jump back to record 0 instead of exiting to C++ every
            // iteration. The chain handler enforces the per-block budget.
            if (op.arg0 == block.start_pc) {
                rec = MakeRecord(citra_asm_op_chain, Builder::kBlockStartTarget,
                                 op.arg0, block.guest_instruction_count);
            } else {
                rec = MakeRecord(citra_asm_op_jmp, Builder::ResolveTarget(op.arg0), op.arg0);
            }
            break;
        // -- conditional direct branch --------------------------------------
        case Opcode::ArmBranch: {
            const u32 cond = op.arg1 & 0xF;
            const bool links = (op.arg2 & 1) != 0;
            // The C++ handler ends the block unconditionally; the not-taken
            // path in asm falls through to the next record, which is only
            // equivalent when this op is the block's last.
            if (i != count - 1) {
                break;
            }
            if (!links) {
                if (cond < kArmCondAl && (asm_mask & kAsmMaskCondBranch)) {
                    if (op.arg0 == block.start_pc) {
                        rec = MakeRecord(kBraChainHandlers[cond], Builder::kBlockStartTarget,
                                         op.arg0, block.guest_instruction_count);
                    } else {
                        rec = MakeRecord(kBraHandlers[cond], Builder::ResolveTarget(op.arg0),
                                         op.arg0);
                    }
                }
            } else if ((asm_mask & kAsmMaskLinkBranch) &&
                       (asm_mask & kAsmMaskLinkBl)) {
                const u64 link = op.arg2 & ~1u;
                if (cond == kArmCondAl) {
                    rec = MakeRecord(citra_asm_op_bl, op.arg0, link);
                } else if (cond < kArmCondAl) {
                    b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
                    rec = MakeRecord(citra_asm_op_bl, op.arg0, link);
                }
            }
            break;
        }
        // -- branch exchange --------------------------------------------------
        // rm==15 reads the live pc, which asm keeps in w28 only: slow-exit.
        case Opcode::ArmBranchExchange: {
            const u32 cond = op.arg0 & 0xF;
            const u32 rm = op.arg1 & 0xF;
            if (rm == 15 || i != count - 1 || !(asm_mask & kAsmMaskLinkBranch) ||
                !(asm_mask & kAsmMaskLinkBx)) {
                break;
            }
            if (cond == kArmCondAl) {
                rec = MakeRecord(citra_asm_op_bx, rm, 0, i);
            } else if (cond < kArmCondAl) {
                b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
                rec = MakeRecord(citra_asm_op_bx, rm, 0, i);
            }
            break;
        }
        case Opcode::ArmBranchExchangeAlways: {
            const u32 rm = op.arg1 & 0xF;
            if (rm != 15 && (asm_mask & kAsmMaskLinkBranch) &&
                (asm_mask & kAsmMaskLinkBx)) {
                rec = MakeRecord(citra_asm_op_bx, rm, 0, i);
            }
            break;
        }
        case Opcode::ArmBranchLinkExchange: {
            const u32 cond = op.arg0 & 0xF;
            const bool immediate_target = ((op.arg0 >> 8) & 1) != 0;
            const u32 rm = op.arg1 & 0xF;
            if (!(asm_mask & kAsmMaskLinkBranch) || !(asm_mask & kAsmMaskLinkBlx)) {
                break;
            }
            if (immediate_target) {
                // ARM blx #imm always enters Thumb; the handler writes TFlag
                // and the end probe misses on the foreign-mode target.
                rec = MakeRecord(citra_asm_op_blxi, op.arg1, op.arg2, i);
                break;
            }
            if (rm == 15 || i != count - 1) {
                break;
            }
            const u64 link =
                instr_addr_i + op.guest_size + (block.thumb ? 1 : 0);
            if (cond == kArmCondAl) {
                rec = MakeRecord(citra_asm_op_blx, rm, link, i, op.guest_size);
            } else if (cond < kArmCondAl) {
                b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
                rec = MakeRecord(citra_asm_op_blx, rm, link, i, op.guest_size);
            }
            break;
        }
        case Opcode::ArmBranchLinkExchangeRegisterAlways: {
            const u32 rm = op.arg1 & 0xF;
            if (rm != 15 && (asm_mask & kAsmMaskLinkBranch) &&
                (asm_mask & kAsmMaskLinkBlx)) {
                const u64 link =
                    instr_addr_i + op.guest_size + (block.thumb ? 1 : 0);
                rec = MakeRecord(citra_asm_op_blx, rm, link, i, op.guest_size);
            }
            break;
        }
        // -- Thumb blx #imm (ThumbBranchLinkExchange): Thumb -> ARM. Always
        // block-terminal; the handler switches TFlag itself and lets the end
        // probe miss on the ARM target.
        case Opcode::ThumbBranchLinkExchange:
            if (asm_mask & kAsmMaskThumbLink) {
                rec = MakeRecord(citra_asm_op_tblx, op.arg0, 0, i);
            }
            break;
        // -- Thumb bl prefix/suffix --------------------------------------------
        case Opcode::ThumbBranchLinkSetup:
            if (asm_mask & kAsmMaskThumbLink) {
                rec = MakeRecord(citra_asm_op_tblsetup, op.arg0);
            }
            break;
        case Opcode::ThumbBranchLink:
            if (asm_mask & kAsmMaskThumbLink) {
                rec = MakeRecord(citra_asm_op_tblink, op.arg0);
            }
            break;
        // -- fused test + branch ---------------------------------------------
        case Opcode::ArmTestImmediateBranchNoPcAlways: {
            const u32 cond = (op.arg0 >> 8) & 0xF;
            if (cond < kArmCondAl && i == count - 1 && (asm_mask & kAsmMaskFusedBranch)) {
                // a3 = fused op's guest_size: the not-taken path advances pc
                // past BOTH the compare and the branch.
                rec = MakeRecord(kTstBraHandlers[cond], op.arg0, op.arg1, op.arg2,
                                 op.guest_size);
            }
            break;
        }
        case Opcode::ArmTestRegisterBranchNoPcAlways: {
            const u32 cond = (op.arg0 >> 12) & 0xF;
            if (cond < kArmCondAl && i == count - 1 && (asm_mask & kAsmMaskFusedBranch)) {
                rec = MakeRecord(kTstRBraHandlers[cond], op.arg0, 0, op.arg1,
                                 op.guest_size);
            }
            break;
        }
        // -- generic immediate-offset word load/store -------------------------
        // PC-operand forms (literal pool via rn==15) are handled inside the
        // gen handlers; rd==15 keeps its C++ semantics via a slow exit.
        case Opcode::ArmLoadWordImmediate:
            if (asm_mask & kAsmMaskMemPc) {
                rec = MakeRecord(citra_asm_op_ldrw_gen, op.arg1, op.arg2, i);
            }
            break;
        case Opcode::ArmStoreWordImmediate:
            if (asm_mask & kAsmMaskMemPc) {
                rec = MakeRecord(citra_asm_op_strw_gen, op.arg1, op.arg2, i);
            }
            break;
        // -- LDM including pc --------------------------------------------------
        case Opcode::ArmLoadMultipleWithPcFast: {
            const u32 rn = op.arg1 & 0xF;
            const u32 reg_mask = (op.arg1 >> 8) & 0xFFFF;
            if (rn != 15 && (reg_mask & 0x8000) != 0 && (asm_mask & kAsmMaskMemPc)) {
                rec = MakeRecord(citra_asm_op_ldmpc,
                                 rn | ((op.arg0 & 1) << 4) |
                                     (((op.arg0 >> 1) & 1) << 5) |
                                     (((op.arg0 >> 2) & 1) << 6),
                                 (reg_mask & 0x7FFF) |
                                         (static_cast<u64>(op.arg2) << 20),
                                 i);
            }
            break;
        }
        // -- generic conditional data-processing (register) --------------------
        // cond != AL ops become guard + body records. Register-shift and PC
        // operands stay slow, as do flag-setting forms whose C flag needs the
        // shifter carry (logical ops) or the SPSR-restore path (rd==15).
        case Opcode::ArmDataProcessingRegister: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 cond = (op.arg0 >> 8) & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const bool set_flags = ((op.arg1 >> 20) & 1) != 0;
            const u32 shift_type = op.arg2 & 0x3;
            const bool reg_shift = ((op.arg2 >> 16) & 1) != 0;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            const bool writes_rd = !(data_opcode == 8 || data_opcode == 9 ||
                                   data_opcode == 10 || data_opcode == 11);
            if (writes_rd && rd == 15 && cond < kArmCondAl && !set_flags &&
                !reg_shift && (asm_mask & kAsmMaskGuard) &&
                (asm_mask & kAsmMaskGuardDpReg)) {
                // Conditional result->pc (moveq pc, lr and friends): the guard
                // skips the dp_pc record when the condition fails; a passed
                // condition stores the raw result and chain-probes pc & ~3.
                const u64 pc_const =
                    (rn == 15 || rm == 15) ? instr_addr_i + 2ULL * op.guest_size : 0;
                b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
                rec = MakeRecord(citra_asm_op_dp_pc,
                                 static_cast<u64>(data_opcode) | (rn << 4) |
                                     (rm << 8) | (static_cast<u64>(shift_type) << 12) |
                                     (static_cast<u64>(shift_imm) << 14),
                                 pc_const, static_cast<u64>(i));
                break;
            }
            if (cond < kArmCondAl && !set_flags && (asm_mask & kAsmMaskGuard) &&
                (asm_mask & kAsmMaskGuardDpReg)) {
                if (writes_rd && reg_shift && rd != 15 && rn != 15 && rm != 15 &&
                    shift_imm != 15) {
                    // Conditional register-shifted op (sublt rX, rN, rM, lsl rS):
                    // shift_imm holds rs. guard + alu_regsh.
                    b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
                    rec = MakeRecord(
                        citra_asm_op_alu_regsh,
                        static_cast<u64>(data_opcode) |
                            (static_cast<u64>(shift_type) << 8),
                        static_cast<u64>(rd) | (rn << 8) |
                            (static_cast<u64>(rm) << 16) |
                            (static_cast<u64>(shift_imm) << 24),
                        static_cast<u64>(i));
                    break;
                }
                if (writes_rd && !reg_shift && rm == 15 && rn != 15 && rd != 15 &&
                    shift_type == 0 && shift_imm == 0) {
                    // Conditional pc-operand op: guard + alu_rm_pc.
                    const u64 pc_const = instr_addr_i + 2ULL * op.guest_size;
                    b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
                    rec = MakeRecord(citra_asm_op_alu_rm_pc,
                                     static_cast<u64>(data_opcode) | (pc_const << 32),
                                     static_cast<u64>(rd) | (rn << 8) |
                                         (static_cast<u64>(rm) << 16),
                                     static_cast<u64>(i));
                    break;
                }
            }
            if (cond >= kArmCondAl || reg_shift || rd == 15 || rn == 15 || rm == 15 ||
                !(asm_mask & kAsmMaskGuard) || !(asm_mask & kAsmMaskGuardDpReg)) {
                break;
            }
            void (*body)() = nullptr;
            u64 a0 = 0;
            u64 a1 = 0;
            u64 a2 = 0;
            if (!set_flags) {
                if (shift_imm == 0 && shift_type == 0) {
                    if (data_opcode == 13) {
                        body = citra_asm_op_mov_reg;
                        a0 = rd | (rm << 8);
                    } else if (data_opcode == 15) {
                        body = citra_asm_op_mvn_reg;
                        a0 = rd | (rm << 8);
                    } else if (auto* h = ArithRegHandler(data_opcode)) {
                        body = h;
                        a0 = op.arg1 & 0xFFFFFu;
                    } else if (auto* h = LogicalRegHandler(data_opcode)) {
                        body = h;
                        a0 = op.arg1 & 0xFFFFFu;
                    }
                } else if (data_opcode == 13) {
                    a0 = rd | (rm << 8) | (static_cast<u64>(shift_imm) << 16);
                    switch (shift_type) {
                    case 0:
                        body = citra_asm_op_mov_lsl;
                        break;
                    case 1:
                        body = shift_imm != 0 ? citra_asm_op_mov_lsr : citra_asm_op_mov_lsr32;
                        break;
                    case 2:
                        body = shift_imm != 0 ? citra_asm_op_mov_asr : citra_asm_op_mov_asr32;
                        break;
                    case 3:
                        body = shift_imm != 0 ? citra_asm_op_mov_ror : citra_asm_op_mov_rrx;
                        break;
                    }
                } else if (shift_imm != 0 || shift_type == 0) {
                    if (auto* h = ShiftedAluHandler(data_opcode, shift_type)) {
                        body = h;
                        a0 = (op.arg1 & 0xFFFFFu) | (static_cast<u64>(shift_imm) << 24);
                    }
                }
            } else if (shift_imm == 0 && shift_type == 0) {
                switch (data_opcode) {
                case 2:
                    body = citra_asm_op_subs_reg;
                    a0 = op.arg1 & 0xFFFFFu;
                    break;
                case 4:
                    body = citra_asm_op_adds_reg;
                    a0 = op.arg1 & 0xFFFFFu;
                    break;
                case 10:
                    body = citra_asm_op_cmp_reg;
                    a0 = rn | (rm << 8);
                    break;
                case 11:
                    body = citra_asm_op_cmn_reg;
                    a0 = rn | (rm << 8);
                    break;
                default:
                    if (data_opcode != 3 && (data_opcode < 5 || data_opcode > 7)) {
                        // ands/eors/tst/teq/orrs/movs/bics/mvns rd, rn, rm:
                        // same body the unconditional
                        // ArmDataProcessingRegisterAlways path uses.
                        body = citra_asm_op_logreg_s;
                        a0 = op.arg0;
                        a1 = op.arg1;
                        a2 = static_cast<u64>(i);
                    } else {
                        // rsbs/adcs/sbcs/rscs rd, rn, rm: an unshifted
                        // operand is LSL#0, which carithsh_s already
                        // implements as operand = rm.
                        body = citra_asm_op_carithsh_s;
                        a0 = data_opcode;
                        a1 = op.arg1;
                        a2 = static_cast<u64>(i);
                    }
                    break;
                }
            } else {
                // Shifted set-flags forms reuse the Always-family bodies;
                // tst/teq shifted (8,9) has no handler anywhere and stays slow.
                if (data_opcode == 0 || data_opcode == 1 || data_opcode == 12 ||
                    data_opcode == 14 || data_opcode == 15) {
                    static void (*const kLogShS[])() = {
                        citra_asm_op_logsh_s_lsl, citra_asm_op_logsh_s_lsr,
                        citra_asm_op_logsh_s_asr, citra_asm_op_logsh_s_ror};
                    body = kLogShS[shift_type];
                    a0 = data_opcode | (op.arg2 & 0x1F00);
                    a1 = op.arg1;
                    a2 = static_cast<u64>(i);
                } else if (data_opcode == 13) {
                    body = citra_asm_op_movs_shift;
                    a0 = rd | (rm << 8);
                    a1 = op.arg2 & 0xFFFF;
                } else if (data_opcode >= 2 && data_opcode <= 7) {
                    // subs/adds/rsb/adc/sbc/rsc shifted set-flags.
                    body = citra_asm_op_carithsh_s;
                    a0 = data_opcode | ((op.arg2 & 0x3) << 8) |
                         ((op.arg2 & 0x1F00) << 8);
                    a1 = op.arg1;
                    a2 = static_cast<u64>(i);
                } else if (data_opcode == 10 || data_opcode == 11) {
                    body = data_opcode == 10 ? citra_asm_op_cmp_shift
                                             : citra_asm_op_cmn_shift;
                    a0 = rn | (rm << 8);
                    a1 = op.arg2 & 0xFFFF;
                }
            }
            if (!body) {
                break;
            }
            b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
            rec = MakeRecord(body, a0, a1, a2);
            break;
        }
        // -- generic conditional data-processing (immediate) -------------------
        case Opcode::ArmDataProcessingImmediate: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 cond = (op.arg0 >> 8) & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool set_flags = ((op.arg1 >> 16) & 1) != 0;
            if (cond >= kArmCondAl || rd == 15 || rn == 15 ||
                !(asm_mask & kAsmMaskGuard) || !(asm_mask & kAsmMaskGuardDpImm)) {
                break;
            }
            void (*body)() = nullptr;
            u64 a0 = 0;
            if (!set_flags) {
                if (data_opcode == 13) {
                    body = citra_asm_op_mov_imm;
                    a0 = rd;
                } else if (data_opcode == 15) {
                    body = citra_asm_op_mvn_imm;
                    a0 = rd;
                } else if (auto* h = ArithImmHandler(data_opcode)) {
                    body = h;
                    a0 = rd | (rn << 8);
                } else if (auto* h = LogicalImmHandler(data_opcode)) {
                    body = h;
                    a0 = rd | (rn << 8);
                }
            } else {
                switch (data_opcode) {
                case 2:
                    body = citra_asm_op_subs_imm;
                    a0 = rd | (rn << 8);
                    break;
                case 3:
                    body = citra_asm_op_rsbs_imm;
                    a0 = rd | (rn << 8);
                    break;
                case 4:
                    body = citra_asm_op_adds_imm;
                    a0 = rd | (rn << 8);
                    break;
                case 5:
                    body = citra_asm_op_adcs_imm;
                    a0 = rd | (rn << 8);
                    break;
                case 6:
                    body = citra_asm_op_sbcs_imm;
                    a0 = rd | (rn << 8);
                    break;
                case 7:
                    body = citra_asm_op_rscs_imm;
                    a0 = rd | (rn << 8);
                    break;
                case 10:
                    body = citra_asm_op_cmp_imm;
                    a0 = rn;
                    break;
                case 11:
                    body = citra_asm_op_cmn_imm;
                    a0 = rn;
                    break;
                default:
                    break;
                }
                // Conditional logical set-flags immediates (ands/eors/orrs/
                // bics/movs/mvns + tst/teq) share the op168 body: repack the
                // shifter-carry bits out of arg1 into its a0 layout.
                if (!body &&
                    (data_opcode == 0 || data_opcode == 1 || data_opcode == 8 ||
                     data_opcode == 9 || data_opcode == 12 || data_opcode == 13 ||
                     data_opcode == 14 || data_opcode == 15) &&
                    (asm_mask & kAsmMaskLogicFlag)) {
                    b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
                    rec = MakeRecord(citra_asm_op_logimm_s,
                                     data_opcode | (((op.arg1 >> 17) & 1) << 8) |
                                         (((op.arg1 >> 18) & 1) << 9),
                                     rd | (rn << 8), op.arg2);
                    break;
                }
            }
            if (!body) {
                break;
            }
            b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
            rec = MakeRecord(body, a0, op.arg2);
            break;
        }
        // -- generic unconditional data-processing (register) -----------------
        // ArmDataProcessingRegisterAlways (op48): the decode catch-all for AL
        // data-processing ops that hit no specialized opcode -- mostly
        // register-shifted forms and set-flag forms outside the fast sets.
        // Same arg layout as ArmDataProcessingRegister minus the condition:
        // arg0 = data_opcode, arg1 = rd|rn<<8|rm<<16|S<<20,
        // arg2 = shift_type|shift<<8|reg_shift<<16. PC operands, unhandled
        // shifted set-flags forms and rd==15 test-op payloads stay slow.
        case Opcode::ArmDataProcessingRegisterAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const bool set_flags = ((op.arg1 >> 20) & 1) != 0;
            const u32 shift_type = op.arg2 & 0x3;
            const bool reg_shift = ((op.arg2 >> 16) & 1) != 0;
            const u32 shift_amt = (op.arg2 >> 8) & 0x1F;
            const bool writes_rd =
                !(data_opcode == 8 || data_opcode == 9 || data_opcode == 10 ||
                  data_opcode == 11);
            if (!(asm_mask & kAsmMaskGuardDpReg)) {
                break;
            }
            void (*body)() = nullptr;
            u64 a0 = 0;
            u64 a1 = 0;
            u64 a2 = 0;
            if (writes_rd && rd == 15) {
                // Result->pc ops (mov pc, lr and friends): the dp_pc handler
                // stores the raw result to Reg[15] and chain-probes pc & ~3.
                // Flag writers need the SPSR-restore path; register-shift
                // amounts and rm==15 shifted forms stay on the C++ side.
                if (set_flags || reg_shift) {
                    break;
                }
                a0 = static_cast<u64>(data_opcode) | (rn << 4) | (rm << 8) |
                     (static_cast<u64>(shift_type) << 12) |
                     (static_cast<u64>(shift_amt) << 14);
                a1 = (rn == 15 || rm == 15) ? instr_addr_i + 2ULL * op.guest_size
                                          : 0;
                rec = MakeRecord(citra_asm_op_dp_pc, a0, a1, static_cast<u64>(i));
                break;
            }
            if (!set_flags && writes_rd && rm == 15 && rn != 15 && rd != 15 &&
                !reg_shift && shift_type == 0 && shift_amt == 0) {
                // rm==15 with no shift (mov rX, pc; add rX, rN, pc ...):
                // operand2 is this op's pc constant; Reg[15] is stale.
                const u64 pc_const = instr_addr_i + 2ULL * op.guest_size;
                rec = MakeRecord(
                    citra_asm_op_alu_rm_pc,
                    static_cast<u64>(data_opcode) | (pc_const << 32),
                    static_cast<u64>(rd) | (rn << 8) | (static_cast<u64>(rm) << 16),
                    static_cast<u64>(i));
                break;
            }
            if (rn == 15 || rm == 15) {
                break;
            }
            if (!reg_shift) {
                const u32 shift_imm = shift_amt;
                if (!set_flags) {
                    if (shift_imm == 0 && shift_type == 0) {
                        if (data_opcode == 13) {
                            body = citra_asm_op_mov_reg;
                            a0 = rd | (rm << 8);
                        } else if (data_opcode == 15) {
                            body = citra_asm_op_mvn_reg;
                            a0 = rd | (rm << 8);
                        } else if (auto* h = ArithRegHandler(data_opcode)) {
                            body = h;
                            a0 = op.arg1 & 0xFFFFFu;
                        } else if (auto* h = LogicalRegHandler(data_opcode)) {
                            body = h;
                            a0 = op.arg1 & 0xFFFFFu;
                        }
                    } else if (data_opcode == 13) {
                        a0 = rd | (rm << 8) | (static_cast<u64>(shift_imm) << 16);
                        switch (shift_type) {
                        case 0:
                            body = citra_asm_op_mov_lsl;
                            break;
                        case 1:
                            body = shift_imm != 0 ? citra_asm_op_mov_lsr
                                                  : citra_asm_op_mov_lsr32;
                            break;
                        case 2:
                            body = shift_imm != 0 ? citra_asm_op_mov_asr
                                                  : citra_asm_op_mov_asr32;
                            break;
                        case 3:
                            body = shift_imm != 0 ? citra_asm_op_mov_ror
                                                  : citra_asm_op_mov_rrx;
                            break;
                        }
                    } else if (shift_imm != 0 || shift_type == 0) {
                        if (auto* h = ShiftedAluHandler(data_opcode, shift_type)) {
                            body = h;
                            a0 = (op.arg1 & 0xFFFFFu) |
                                 (static_cast<u64>(shift_imm) << 24);
                        } else if (data_opcode == 3 ||
                                   (data_opcode >= 5 && data_opcode <= 7)) {
                            body = citra_asm_op_carith_shift;
                            a0 = static_cast<u64>(data_opcode) | (rd << 8) |
                                 (rn << 12) | (rm << 16);
                            a1 = op.arg2;
                        }
                    }
                } else if (shift_imm == 0 && shift_type == 0) {
                    switch (data_opcode) {
                    case 2:
                        body = citra_asm_op_subs_reg;
                        a0 = op.arg1 & 0xFFFFFu;
                        break;
                    case 4:
                        body = citra_asm_op_adds_reg;
                        a0 = op.arg1 & 0xFFFFFu;
                        break;
                    case 10:
                        body = citra_asm_op_cmp_reg;
                        a0 = rn | (rm << 8);
                        break;
                    case 11:
                        body = citra_asm_op_cmn_reg;
                        a0 = rn | (rm << 8);
                        break;
                    default:
                        // AND/EOR/TST/TEQ/ORR/MOV/BIC/MVN with plain rm.
                        if (data_opcode != 3 && (data_opcode < 5 || data_opcode > 7)) {
                            body = citra_asm_op_logreg_s;
                            a0 = op.arg0;
                            a1 = op.arg1;
                            a2 = static_cast<u64>(i);
                        }
                        break;
                    }
                } else if (data_opcode == 13) {
                    // movs rd, rm, <shift> #n; a0 = rd|rm<<8,
                    // a1 = shift_type|shift_imm<<8.
                    body = citra_asm_op_movs_shift;
                    a0 = rd | (rm << 8);
                    a1 = op.arg2 & 0xFFFFu;
                }
            } else {
                const u32 rs = (op.arg2 >> 8) & 0xF;
                if (rs == 15) {
                    break;
                }
                if (!set_flags) {
                    if (data_opcode == 13) {
                        body = kMovRShiftHandlers[shift_type];
                        a0 = rd | (rm << 8) | (static_cast<u64>(rs) << 16);
                    } else if (data_opcode == 0 || data_opcode == 1 ||
                               data_opcode == 12 || data_opcode == 14 ||
                               data_opcode == 15) {
                        // Same a1 layout as op206: rd|rn<<8|rm<<16|rs<<24.
                        body = citra_asm_op_logregsh;
                        a0 = op.arg0;
                        a1 = (op.arg1 & 0xFFFFFu) | (static_cast<u64>(rs) << 24);
                        a2 = shift_type;
                    }
                } else if (data_opcode != 2 && data_opcode != 3 &&
                           data_opcode != 4 && data_opcode != 5 &&
                           data_opcode != 6 && data_opcode != 7 &&
                           data_opcode != 10 && data_opcode != 11) {
                    // Same a1 layout as op207: rd|rn<<8|rm<<16|rs<<24.
                    body = citra_asm_op_logregs_s;
                    a0 = op.arg0;
                    a1 = (op.arg1 & 0xFFFFFu) | (static_cast<u64>(rs) << 24);
                    a2 = shift_type;
                }
            }
            if (!body) {
                break;
            }
            rec = MakeRecord(body, a0, a1, a2, i);
            break;
        }
        // -- generic conditional multiply --------------------------------------
        case Opcode::ArmMultiply: {
            const u32 cond = op.arg0 & 0xF;
            const bool accumulate = ((op.arg0 >> 8) & 1) != 0;
            const bool set_flags = ((op.arg0 >> 9) & 1) != 0;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rs = (op.arg1 >> 16) & 0xF;
            const u32 rm = (op.arg1 >> 24) & 0xF;
            if (cond >= kArmCondAl || rd == 15 || rm == 15 || rs == 15 ||
                (accumulate && rn == 15) || !(asm_mask & kAsmMaskGuard) ||
                !(asm_mask & kAsmMaskGuardMul)) {
                break;
            }
            b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
            void (*body)() =
                accumulate ? (set_flags ? citra_asm_op_mlas : citra_asm_op_mla)
                           : (set_flags ? citra_asm_op_muls : citra_asm_op_mul);
            if (accumulate) {
                rec = MakeRecord(body, rd | (rm << 8) | (rs << 16) |
                                           (static_cast<u64>(rn) << 24));
            } else {
                rec = MakeRecord(body, rd | (rm << 8) | (rs << 16));
            }
            break;
        }
        case Opcode::ArmMultiplyLong: {
            const u32 cond = op.arg0 & 0xF;
            const bool set_flags = ((op.arg0 >> 10) & 1) != 0;
            const u32 rd_lo = op.arg1 & 0xF;
            const u32 rd_hi = (op.arg1 >> 8) & 0xF;
            const u32 rs = (op.arg1 >> 16) & 0xF;
            const u32 rm = (op.arg1 >> 24) & 0xF;
            if (cond >= kArmCondAl || rd_lo == 15 || rd_hi == 15 || rs == 15 ||
                rm == 15 || !(asm_mask & kAsmMaskGuard) ||
                !(asm_mask & kAsmMaskGuardMul)) {
                break;
            }
            b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
            rec = MakeRecord(set_flags ? citra_asm_op_mulls : citra_asm_op_mull,
                             op.arg1, (op.arg0 >> 8) & 0x3);
            break;
        }
        // -- signed halfword multiplies (op59): smulxy / smlaxy / smlalxy ----
        // x_high selects rm/rn's top half, y_high selects rs/rm's top half;
        // both are decode-time constants baked into the handler suffix.
        case Opcode::ArmSignedHalfwordMultiply: {
            const u32 cond = op.arg0 & 0xF;
            const bool accumulate = ((op.arg0 >> 8) & 1) != 0;
            const bool long_result = ((op.arg0 >> 9) & 1) != 0;
            const u32 xy = ((op.arg0 >> 10) & 1) * 2 + ((op.arg0 >> 11) & 1);
            const u32 regs = static_cast<u32>(op.arg1 & 0xFFFFFFFF);
            const bool any_pc = long_result
                                    ? ((regs & 0xF) == 15 || ((regs >> 8) & 0xF) == 15 ||
                                       ((regs >> 16) & 0xF) == 15 ||
                                       ((regs >> 24) & 0xF) == 15)
                                    : ((regs & 0xF) == 15 || ((regs >> 8) & 0xF) == 15 ||
                                       ((regs >> 16) & 0xF) == 15 ||
                                       (accumulate && ((regs >> 24) & 0xF) == 15));
            // ArmSignedHalfwordMultiply has no *Always twin: cond==AL is the
            // common encoding and emits a bare record.
            if (cond > kArmCondAl || any_pc || !(asm_mask & kAsmMaskGuardMul)) {
                break;
            }
            if (cond != kArmCondAl) {
                if (!(asm_mask & kAsmMaskGuard)) {
                    break;
                }
                b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
            }
            void (*body)() = long_result ? kSmlalHHandlers[xy]
                                         : (accumulate ? kSmlaHHandlers[xy]
                                                       : kSmulHHandlers[xy]);
            rec = MakeRecord(body, 0, op.arg1, i);
            break;
        }
        // -- generic conditional immediate load/store --------------------------
        // Covers the non-privileged forms: plain non-writeback ops use the
        // simple bodies, writeback ops (pre- or post-indexed) use the _wb
        // bodies. Unprivileged transfers, PC operands, and rd==rn writeback
        // (whose C++ store/writeback semantics differ from the _wb bodies)
        // stay on the slow path.
        case Opcode::ArmLoadStoreImmediate: {
            const u32 cond = (op.arg0 >> 8) & 0xF;
            const bool load = (op.arg0 & 1) != 0;
            const bool byte_transfer = (op.arg0 & 2) != 0;
            const bool unprivileged = ((op.arg0 >> 2) & 1) != 0;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool writes_back = ((op.arg1 >> 18) & 1) != 0;
            if (load && !byte_transfer && !unprivileged && !writes_back &&
                rd == 15 && rn == 15 && (asm_mask & kAsmMaskGuardLdSt)) {
                // ldr pc, [pc, #imm]: literal-pool absolute branch. The
                // pre-indexed address folds to a translate-time constant.
                const bool pre_indexed_i = ((op.arg1 >> 17) & 1) != 0;
                const bool add_offset_i = ((op.arg1 >> 16) & 1) != 0;
                if (pre_indexed_i && (cond == kArmCondAl || (asm_mask & kAsmMaskGuard))) {
                    const u32 lit_addr = add_offset_i ? pc_addr_i + op.arg2
                                                      : pc_addr_i - op.arg2;
                    if (cond != kArmCondAl) {
                        b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
                    }
                    // a0 nibble 0 feeds the resident-safety nibble check;
                    // 15 keeps it inert since the immediate form never
                    // dereferences rm.
                    rec = MakeRecord(citra_asm_op_ldrw_pc_lit, 15, lit_addr, i);
                }
                break;
            }
            if (load && !byte_transfer && !unprivileged && rd == 15 && rn != 15 &&
                (asm_mask & kAsmMaskGuardLdSt) &&
                (cond == kArmCondAl || (asm_mask & kAsmMaskGuard))) {
                // ldr pc, [rn, #imm]{!} / [rn], #imm: indirect jump through a
                // register base with an immediate offset.
                const bool add_offset_i = ((op.arg1 >> 16) & 1) != 0;
                const bool pre_indexed_i = ((op.arg1 >> 17) & 1) != 0;
                if (cond != kArmCondAl) {
                    b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
                }
                rec = MakeRecord(citra_asm_op_ldrw_pc_imm,
                                 rn | (add_offset_i << 4) | (pre_indexed_i << 5) |
                                     (writes_back << 6),
                                 op.arg2, i);
                break;
            }
            if (cond >= kArmCondAl || unprivileged || rd == 15 ||
                (writes_back && rd == rn) || !(asm_mask & kAsmMaskGuard) ||
                !(asm_mask & kAsmMaskGuardLdSt)) {
                break;
            }
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 17) & 1) != 0;
            if (rn == 15) {
                // Conditional literal load: the address is a translate-time
                // constant. Post-indexed/writeback/unprivileged keep C++
                // semantics.
                if (load && pre_indexed && !writes_back) {
                    const u32 lit_addr = add_offset ? pc_addr_i + op.arg2
                                                    : pc_addr_i - op.arg2;
                    b.ops.push_back(
                        MakeRecord(kGuardHandlers[cond], op.guest_size));
                    rec = MakeRecord(byte_transfer ? citra_asm_op_ldrb_lit
                                                   : citra_asm_op_ldrw_lit,
                                     rd, lit_addr, i);
                }
                break;
            }
            void (*body)() = nullptr;
            if (!writes_back) {
                if (load) {
                    body = byte_transfer
                               ? (add_offset ? citra_asm_op_ldrb_add : citra_asm_op_ldrb_sub)
                               : (add_offset ? citra_asm_op_ldrw_add : citra_asm_op_ldrw_sub);
                } else {
                    body = byte_transfer
                               ? (add_offset ? citra_asm_op_strb_add : citra_asm_op_strb_sub)
                               : (add_offset ? citra_asm_op_strw_add : citra_asm_op_strw_sub);
                }
            } else if (load) {
                body = byte_transfer ? (add_offset ? citra_asm_op_ldrb_wb
                                                  : citra_asm_op_ldrb_wb_sub)
                                     : (add_offset ? citra_asm_op_ldrw_wb
                                                  : citra_asm_op_ldrw_wb_sub);
            } else {
                body = byte_transfer ? (add_offset ? citra_asm_op_strb_wb
                                                  : citra_asm_op_strb_wb_sub)
                                     : (add_offset ? citra_asm_op_strw_wb
                                                  : citra_asm_op_strw_wb_sub);
            }
            b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
            rec = MakeRecord(body, writes_back ? (op.arg1 & 0x3FFFF) : op.arg1, op.arg2, i);
            break;
        }
        // -- generic conditional register-offset load/store -------------------
        // arg0 = load|byte<<1|unpriv<<2|cond<<8; arg1 = rd|rn<<8|rm<<16|
        // add<<20|pre<<21|wb<<22; arg2 = shift_type|shift_imm<<8. Only the
        // plain non-writeback forms map onto the *_reg_add/sub bodies (add is
        // carried by the handler, so arg1 is masked to 20 bits). Unprivileged
        // transfers, PC operands and writeback variants stay slow.
        case Opcode::ArmLoadStoreRegister: {
            const u32 cond = (op.arg0 >> 8) & 0xF;
            const bool load = (op.arg0 & 1) != 0;
            const bool byte_transfer = (op.arg0 & 2) != 0;
            const bool unprivileged = ((op.arg0 >> 2) & 1) != 0;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const bool add = ((op.arg1 >> 20) & 1) != 0;
            const bool writes_back = ((op.arg1 >> 22) & 1) != 0;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            if (load && !byte_transfer && rd == 15 && rn == 15 && !unprivileged &&
                rm != 15 && !(shift_imm == 0 && shift_type != 0) &&
                (asm_mask & kAsmMaskGuardLdSt) &&
                (cond == kArmCondAl || (asm_mask & kAsmMaskGuard))) {
                // ldr pc, [pc, rm{, shift}]: pc-relative jump-table form.
                // The base is the translate-time constant (insn&~3)+8; rm
                // supplies the runtime index. rd == rn == 15 makes
                // writeback impossible in the C++ model.
                if (cond != kArmCondAl) {
                    b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
                }
                rec = MakeRecord(citra_asm_op_ldrw_pc_lit,
                                 rm | ((op.arg2 & 0x1F03) << 8) |
                                     (static_cast<u64>(add) << 24) | (1u << 25),
                                 pc_addr_i, i);
                break;
            }
            if (unprivileged || rn == 15 || rm == 15 ||
                (shift_imm == 0 && shift_type != 0) ||
                !(asm_mask & kAsmMaskGuardLdSt)) {
                break;
            }
            if (rd == 15) {
                // ldr pc, [rn, rm{, shift}]: jump-table / pop-pc forms. The
                // handler loads the target word, bails to C++ on a mode
                // change before any guest write, applies writeback to rn,
                // sets w28 and runs the chain probe. Byte loads to pc keep
                // the slow path; stores of pc store live w28 verbatim.
                void (*pch)() = nullptr;
                if (load) {
                    if (!byte_transfer) {
                        pch = citra_asm_op_ldrw_pc;
                    }
                } else {
                    pch = byte_transfer
                              ? (add ? (writes_back ? citra_asm_op_strb_pc_reg_wb
                                                    : citra_asm_op_strb_pc_reg_add)
                                     : (writes_back ? citra_asm_op_strb_pc_reg_wb_sub
                                                    : citra_asm_op_strb_pc_reg_sub))
                              : (add ? (writes_back ? citra_asm_op_strw_pc_reg_wb
                                                    : citra_asm_op_strw_pc_reg_add)
                                     : (writes_back ? citra_asm_op_strw_pc_reg_wb_sub
                                                    : citra_asm_op_strw_pc_reg_sub));
                }
                if (!pch) {
                    break;
                }
                if (cond != kArmCondAl) {
                    if (!(asm_mask & kAsmMaskGuard)) {
                        break;
                    }
                    b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
                }
                rec = MakeRecord(pch, op.arg1 & 0xFFFFFF, op.arg2, i);
                break;
            }
            // rd==rn writeback stores emit the writeback value as store data
            // in the C++ reference; keep those on the slow path.
            if (writes_back && rd == rn) {
                break;
            }
            void (*body)() = nullptr;
            if (load) {
                body = byte_transfer
                           ? (add ? (writes_back ? citra_asm_op_ldrb_reg_wb
                                                 : citra_asm_op_ldrb_reg_add)
                                  : (writes_back ? citra_asm_op_ldrb_reg_wb_sub
                                                 : citra_asm_op_ldrb_reg_sub))
                           : (add ? (writes_back ? citra_asm_op_ldrw_reg_wb
                                                 : citra_asm_op_ldrw_reg_add)
                                  : (writes_back ? citra_asm_op_ldrw_reg_wb_sub
                                                 : citra_asm_op_ldrw_reg_sub));
            } else {
                body = byte_transfer
                           ? (add ? (writes_back ? citra_asm_op_strb_reg_wb
                                                 : citra_asm_op_strb_reg_add)
                                  : (writes_back ? citra_asm_op_strb_reg_wb_sub
                                                 : citra_asm_op_strb_reg_sub))
                           : (add ? (writes_back ? citra_asm_op_strw_reg_wb
                                                 : citra_asm_op_strw_reg_add)
                                  : (writes_back ? citra_asm_op_strw_reg_wb_sub
                                                 : citra_asm_op_strw_reg_sub));
            }
            if (cond != kArmCondAl) {
                if (!(asm_mask & kAsmMaskGuard)) {
                    break;
                }
                b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
            }
            rec = MakeRecord(body, op.arg1 & 0xFFFFFF, op.arg2, i);
            break;
        }
        // -- generic conditional halfword load/store --------------------------
        // arg0 = cond|load<<8|type<<9; arg1 = rd|rn<<8|add<<16|imm<<17|pre<<18|
        // wb<<19; arg2 = byte offset or rm. Plain pre-indexed forms map onto
        // the *_add/sub bodies, writeback forms (pre or post) onto the *_wb
        // bodies once arg1 is repacked to the rd|rn<<8|add<<16|pre<<17 layout.
        // Post-indexed non-writeback (unprivileged) encodings, PC operands,
        // rd==rn writeback (whose C++ store/writeback semantics differ) and
        // register-offset writeback forms stay slow.
        case Opcode::ArmLoadStoreHalfword: {
            const u32 cond = op.arg0 & 0xF;
            const bool load = ((op.arg0 >> 8) & 1) != 0;
            const u32 transfer_type = (op.arg0 >> 9) & 0x3;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool add_offset = ((op.arg1 >> 16) & 1) != 0;
            const bool immediate_offset = ((op.arg1 >> 17) & 1) != 0;
            const bool pre_indexed = ((op.arg1 >> 18) & 1) != 0;
            const bool writes_back = ((op.arg1 >> 19) & 1) != 0;
            if (rd == 15 || rn == 15 || transfer_type == 0 ||
                (!load && transfer_type != 1) || !(asm_mask & kAsmMaskGuardLdSt)) {
                break;
            }
            void (*body)() = nullptr;
            u64 a0 = 0;
            u64 a1 = 0;
            if (immediate_offset) {
                if (!writes_back) {
                    if (!pre_indexed) {
                        break; // unprivileged: C++ uses base with no writeback
                    }
                    a0 = rd | (rn << 8);
                    a1 = op.arg2;
                    if (load) {
                        body =
                            transfer_type == 1
                                ? (add_offset ? citra_asm_op_ldrh_add : citra_asm_op_ldrh_sub)
                            : transfer_type == 2
                                ? (add_offset ? citra_asm_op_ldrsb_add : citra_asm_op_ldrsb_sub)
                                : (add_offset ? citra_asm_op_ldrsh_add
                                              : citra_asm_op_ldrsh_sub);
                    } else {
                        body = add_offset ? citra_asm_op_strh_add : citra_asm_op_strh_sub;
                    }
                } else {
                    if (rd == rn) {
                        break;
                    }
                    a0 = rd | (rn << 8) | ((op.arg1 >> 16) & 1) << 16 | (pre_indexed << 17);
                    a1 = op.arg2;
                    if (load) {
                        body =
                            transfer_type == 1
                                ? (add_offset ? citra_asm_op_ldrh_wb : citra_asm_op_ldrh_wb_sub)
                            : transfer_type == 2
                                ? (add_offset ? citra_asm_op_ldrsb_wb
                                              : citra_asm_op_ldrsb_wb_sub)
                                : (add_offset ? citra_asm_op_ldrsh_wb
                                              : citra_asm_op_ldrsh_wb_sub);
                    } else {
                        body =
                            add_offset ? citra_asm_op_strh_wb : citra_asm_op_strh_wb_sub;
                    }
                }
            } else {
                const u32 rm = op.arg2 & 0xF;
                if (writes_back || !pre_indexed || rm == 15) {
                    break;
                }
                a0 = rd | (rn << 8);
                a1 = rm;
                if (load) {
                    body = transfer_type == 1
                               ? (add_offset ? citra_asm_op_ldrh_reg_add
                                             : citra_asm_op_ldrh_reg_sub)
                           : transfer_type == 2
                               ? (add_offset ? citra_asm_op_ldrsb_reg_add
                                             : citra_asm_op_ldrsb_reg_sub)
                               : (add_offset ? citra_asm_op_ldrsh_reg_add
                                             : citra_asm_op_ldrsh_reg_sub);
                } else {
                    body = add_offset ? citra_asm_op_strh_reg_add
                                      : citra_asm_op_strh_reg_sub;
                }
            }
            if (cond != kArmCondAl) {
                // NV (0xF) has no guard handler; keep it on the C++ path.
                if (cond >= kArmCondAl || !(asm_mask & kAsmMaskGuard)) {
                    break;
                }
                b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
            }
            rec = MakeRecord(body, a0, a1, i);
            break;
        }
        // -- generic conditional load/store multiple ---------------------------
        // User-bank (S-bit) lists and stm lists containing pc stay slow; the
        // rest repack onto the fast ldm/stm/ldmpc bodies behind a guard.
        case Opcode::ArmLoadStoreMultiple: {
            const u32 cond = op.arg0 & 0xF;
            const bool load = ((op.arg0 >> 8) & 1) != 0;
            const bool user_mode = ((op.arg0 >> 12) & 1) != 0;
            const u32 rn = op.arg1 & 0xF;
            const u32 reg_mask = (op.arg1 >> 8) & 0xFFFF;
            // cond==AL still lands here when the pc is in the register list
            // (the *Fast specialized opcodes only take pc-free AL forms).
            if (cond > kArmCondAl || user_mode || rn == 15 ||
                !(asm_mask & kAsmMaskGuardLdSt)) {
                break;
            }
            if (cond != kArmCondAl && !(asm_mask & kAsmMaskGuard)) {
                break;
            }
            void (*body)() = nullptr;
            u32 list = reg_mask;
            if (load) {
                body = (reg_mask & 0x8000) ? citra_asm_op_ldmpc : citra_asm_op_ldm;
            } else {
                body = (reg_mask & 0x8000) ? citra_asm_op_stmpc : citra_asm_op_stm;
            }
            if (body != citra_asm_op_stmpc) {
                list &= 0x7FFF;
            }
            if (cond != kArmCondAl) {
                b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
            }
            rec = MakeRecord(body,
                             rn | (((op.arg0 >> 9) & 1) << 4) |
                                 (((op.arg0 >> 10) & 1) << 5) | (((op.arg0 >> 11) & 1) << 6),
                             list | (static_cast<u64>(op.arg2) << 20), i);
            break;
        }
        // -- hints --------------------------------------------------------
        case Opcode::ArmHint: {
            rec = MakeRecord(citra_asm_op_nop);
            break;
        }
        // op74/75: add/sub rd, pc, #imm -- the *Always opcode only survives
        // SelectNoPcDataOpcode when rn==15, and the pc operand is a
        // translate-time constant ((pc & ~1) + guest_size*2), so the whole
        // result folds to an immediate move.
        case Opcode::ArmAddImmediateAlways:
        case Opcode::ArmSubImmediateAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            if (rn != 15 || rd == 15) {
                break;
            }
            const u64 pc_const = instr_addr_i + 2ULL * op.guest_size;
            const u32 value =
                op.opcode == Opcode::ArmAddImmediateAlways
                    ? static_cast<u32>(pc_const) + op.arg2
                    : static_cast<u32>(pc_const) - op.arg2;
            rec = MakeRecord(citra_asm_op_mov_imm, rd, value);
            break;
        }
        // -- PC-operand register/logical forms ---------------------------
        // The *Always opcodes only reach the translator when an operand is
        // the pc (rn or rm == 15); the pc operand is a translate-time
        // constant so non-flag results fold to immediates.
        case Opcode::ArmMoveRegisterAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            if (rm == 15 && rd != 15) {
                rec = MakeRecord(citra_asm_op_mov_imm, rd, pc_const_i);
            } else if (rd != 15 && rm != 15) {
                rec = MakeRecord(citra_asm_op_mov_reg, rd | (rm << 8));
            }
            break;
        }
        case Opcode::ArmAddRegisterAlways:
        case Opcode::ArmSubRegisterAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const bool is_sub = op.opcode == Opcode::ArmSubRegisterAlways;
            if (rd == 15 || (rn == 15 && rm == 15) || (rn != 15 && rm != 15)) {
                break;
            }
            if (rn == 15) {
                // rd = pc_const OP rm -- commutative add folds to add_imm;
                // sub becomes imm - rm == rsb_imm.
                rec = MakeRecord(is_sub ? citra_asm_op_rsb_imm
                                        : citra_asm_op_add_imm,
                                 rd | (rm << 8), pc_const_i);
            } else {
                // rd = rn OP pc_const
                rec = MakeRecord(is_sub ? citra_asm_op_sub_imm
                                        : citra_asm_op_add_imm,
                                 rd | (rn << 8), pc_const_i);
            }
            break;
        }
        case Opcode::ArmLogicalImmediateAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            if (rn != 15 || rd == 15) {
                break;
            }
            switch (op.arg0 & 0xF) {
            case 0:  rec = MakeRecord(citra_asm_op_mov_imm, rd, pc_const_i & op.arg2); break;
            case 1:  rec = MakeRecord(citra_asm_op_mov_imm, rd, pc_const_i ^ op.arg2); break;
            case 12: rec = MakeRecord(citra_asm_op_mov_imm, rd, pc_const_i | op.arg2); break;
            case 13: rec = MakeRecord(citra_asm_op_mov_imm, rd, op.arg2); break;
            case 14: rec = MakeRecord(citra_asm_op_mov_imm, rd, pc_const_i & ~op.arg2); break;
            case 15: rec = MakeRecord(citra_asm_op_mvn_imm, rd, op.arg2); break;
            default: break;
            }
            break;
        }
        // -- moves (rd!=15 guaranteed by caller check) --------------------
        case Opcode::ArmMoveImmediateAlways: {
            const u32 rd = op.arg1 & 0xF;
            if (rd != 15) {
                rec = MakeRecord(citra_asm_op_mov_imm, rd, op.arg2);
            }
            break;
        }
        // -- movs/mvns rd, #imm (ArmMoveImmediateSetFlagsAlways, op296) -----
        // arg0 = shifter_carry | shifter_carry_from_c_flag<<1, arg1 = rd,
        // arg2 = rotated immediate value. Emitted for every movs/mvns #imm
        // (Thumb movs #imm decodes here), previously always slow.
        case Opcode::ArmMoveImmediateSetFlagsAlways: {
            const u32 rd = op.arg1 & 0xF;
            if (rd == 15) {
                break;
            }
            rec = MakeRecord(citra_asm_op_movs_imm,
                             rd | ((op.arg0 & 0x3) << 8), op.arg2, i);
            break;
        }
        case Opcode::ArmMoveNotRegisterAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            if (rd != 15 && rm != 15) {
                rec = MakeRecord(citra_asm_op_mvn_reg, rd | (rm << 8));
            }
            break;
        }
        case Opcode::ArmMoveShiftedRegisterAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            if (rd == 15) {
                break;
            }
            if (rm == 15) {
                // mov rd, pc, <shift> -- constant-foldable unless RRX.
                if (shift_type != 3 || shift_imm != 0) {
                    rec = MakeRecord(citra_asm_op_mov_imm, rd,
                                     FoldShiftedPcConst(pc_const_i, shift_type,
                                                        shift_imm));
                }
                break;
            }
            const u32 packed = rd | (rm << 8) | (shift_imm << 16);
            switch (shift_type) {
            case 0:
                rec = MakeRecord(citra_asm_op_mov_lsl, packed);
                break;
            case 1:
                rec = MakeRecord(shift_imm == 0 ? citra_asm_op_mov_lsr32
                                               : citra_asm_op_mov_lsr,
                                 packed);
                break;
            case 2:
                rec = MakeRecord(shift_imm == 0 ? citra_asm_op_mov_asr32
                                               : citra_asm_op_mov_asr,
                                 packed);
                break;
            case 3:
                rec = MakeRecord(shift_imm == 0 ? citra_asm_op_mov_rrx
                                               : citra_asm_op_mov_ror,
                                 packed);
                break;
            }
            break;
        }
        // op93/94: add/sub rd, rn, pc, <shift> -- rm==15 shifts a constant,
        // so the result is rn +/- a folded immediate. rn==15 (the shift
        // applies to a runtime rm instead) stays on the C++ path.
        case Opcode::ArmAddShiftedRegisterAlways:
        case Opcode::ArmSubShiftedRegisterAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            if (rd == 15 || rn == 15 || rm != 15 ||
                (shift_type == 3 && shift_imm == 0)) {
                break;
            }
            const u32 operand =
                FoldShiftedPcConst(pc_const_i, shift_type, shift_imm);
            rec = MakeRecord(op.opcode == Opcode::ArmAddShiftedRegisterAlways
                                 ? citra_asm_op_add_imm
                                 : citra_asm_op_sub_imm,
                             rd | (rn << 8), operand);
            break;
        }
        // -- immediate ALU (NoPc) -----------------------------------------
        case Opcode::ArmAddImmediateNoPcAlways:
            rec = MakeRecord(citra_asm_op_add_imm, op.arg1, op.arg2);
            break;
        case Opcode::ArmSubImmediateNoPcAlways:
            rec = MakeRecord(citra_asm_op_sub_imm, op.arg1, op.arg2);
            break;
        case Opcode::ArmAddImmediateSetFlagsNoPcAlways:
            rec = MakeRecord(citra_asm_op_adds_imm, op.arg1, op.arg2);
            break;
        case Opcode::ArmSubImmediateSetFlagsNoPcAlways:
            rec = MakeRecord(citra_asm_op_subs_imm, op.arg1, op.arg2);
            break;
        case Opcode::ArmCompareImmediateNoPcAlways:
            rec = MakeRecord(citra_asm_op_cmp_imm, op.arg1 & 0xF, op.arg2);
            break;
        case Opcode::ArmCompareNegativeImmediateNoPcAlways:
            rec = MakeRecord(citra_asm_op_cmn_imm, op.arg1 & 0xF, op.arg2);
            break;
        case Opcode::ArmCompareZeroImmediateNoPcAlways:
            rec = MakeRecord(citra_asm_op_cmp_imm, op.arg1 & 0xF, 0);
            break;
        // -- register ALU (NoPc) ------------------------------------------
        case Opcode::ArmAddRegisterNoPcAlways:
            rec = MakeRecord(citra_asm_op_add_reg, op.arg1);
            break;
        case Opcode::ArmSubRegisterNoPcAlways:
            rec = MakeRecord(citra_asm_op_sub_reg, op.arg1);
            break;
        case Opcode::ArmAddRegisterSetFlagsNoPcAlways:
            rec = MakeRecord(citra_asm_op_adds_reg, op.arg1);
            break;
        case Opcode::ArmSubRegisterSetFlagsNoPcAlways:
            rec = MakeRecord(citra_asm_op_subs_reg, op.arg1);
            break;
        case Opcode::ArmCompareRegisterNoPcAlways:
            rec = MakeRecord(citra_asm_op_cmp_reg, op.arg1);
            break;
        case Opcode::ArmCompareNegativeRegisterNoPcAlways:
            rec = MakeRecord(citra_asm_op_cmn_reg, op.arg1);
            break;
        // op192/195: cmp/cmn rn, rm, <shift> #imm -- a0 = rn|rm<<8,
        // a1 = shift_type|shift_imm<<8. NoPc decode keeps rn/rm < 15.
        case Opcode::ArmCompareShiftedRegisterNoPcAlways:
            rec = MakeRecord(citra_asm_op_cmp_shift, op.arg1, op.arg2);
            break;
        case Opcode::ArmCompareNegativeShiftedRegisterNoPcAlways:
            rec = MakeRecord(citra_asm_op_cmn_shift, op.arg1, op.arg2);
            break;
        // op230-233: logical shifted-register set-flags, specialized per
        // shift type. a0 carries data_opcode | shift_imm<<8; the shift_type
        // low bits of arg2 are redundant with the opcode.
        case Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysLsl:
            rec = MakeRecord(citra_asm_op_logsh_s_lsl,
                             (op.arg0 & 0xF) | (op.arg2 & 0x1F00), op.arg1, i);
            break;
        case Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysLsr:
            rec = MakeRecord(citra_asm_op_logsh_s_lsr,
                             (op.arg0 & 0xF) | (op.arg2 & 0x1F00), op.arg1, i);
            break;
        case Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysAsr:
            rec = MakeRecord(citra_asm_op_logsh_s_asr,
                             (op.arg0 & 0xF) | (op.arg2 & 0x1F00), op.arg1, i);
            break;
        case Opcode::ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysRor:
            rec = MakeRecord(citra_asm_op_logsh_s_ror,
                             (op.arg0 & 0xF) | (op.arg2 & 0x1F00), op.arg1, i);
            break;
        // op199: rsb/adc/sbc/rsc rd, rn, rm, <shift> #imm, set flags.
        case Opcode::ArmArithmeticShiftedRegisterSetFlagsNoPcAlways:
            rec = MakeRecord(citra_asm_op_carithsh_s,
                             (op.arg0 & 0xF) | ((op.arg2 & 0x3) << 8) |
                                 ((op.arg2 & 0x1F00) << 8),
                             op.arg1, i);
            break;
        // op173: rsb/adc/sbc/rsc rd, rn, rm, set flags (no shift). The
        // handler's LSL#0 path leaves the rm operand untouched.
        case Opcode::ArmArithmeticRegisterSetFlagsNoPcAlways:
            rec = MakeRecord(citra_asm_op_carithsh_s, op.arg0 & 0xF, op.arg1, i);
            break;
        // op193/194: adds/subs rd, rn, rm, <shift> #imm, set flags. Same
        // record shape as op199; the handler covers the imm==0 corner
        // forms (LSR#32/ASR#32/RRX) itself.
        case Opcode::ArmAddShiftedRegisterSetFlagsNoPcAlways:
            rec = MakeRecord(citra_asm_op_carithsh_s,
                             4 | ((op.arg2 & 0x3) << 8) | ((op.arg2 & 0x1F00) << 8),
                             op.arg1, i);
            break;
        case Opcode::ArmSubShiftedRegisterSetFlagsNoPcAlways:
            rec = MakeRecord(citra_asm_op_carithsh_s,
                             2 | ((op.arg2 & 0x3) << 8) | ((op.arg2 & 0x1F00) << 8),
                             op.arg1, i);
            break;
        // -- logical immediate/register (NoPc) ----------------------------
        case Opcode::ArmLogicalImmediateNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            if (data_opcode == 13) {
                rec = MakeRecord(citra_asm_op_mov_imm, rd, op.arg2);
            } else if (data_opcode == 15) {
                rec = MakeRecord(citra_asm_op_mvn_imm, rd, op.arg2);
            } else if (auto* h = LogicalImmHandler(data_opcode)) {
                rec = MakeRecord(h, op.arg1, op.arg2);
            }
            break;
        }
        case Opcode::ArmLogicalRegisterNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            if (data_opcode == 13) {
                rec = MakeRecord(citra_asm_op_mov_reg, rd | (rm << 8));
            } else if (data_opcode == 15) {
                rec = MakeRecord(citra_asm_op_mvn_reg, rd | (rm << 8));
            } else if (auto* h = LogicalRegHandler(data_opcode)) {
                rec = MakeRecord(h, op.arg1);
            }
            break;
        }
        // -- generic arithmetic/logical families --------------------------
        case Opcode::ArmArithmeticImmediateNoPcAlways: {
            if (auto* h = ArithImmHandler(op.arg0 & 0xF)) {
                rec = MakeRecord(h, op.arg1, op.arg2);
            }
            break;
        }
        case Opcode::ArmArithmeticRegisterNoPcAlways: {
            if (auto* h = ArithRegHandler(op.arg0 & 0xF)) {
                rec = MakeRecord(h, op.arg1);
            }
            break;
        }
        // -- shifted-register ALU (NoPc) ----------------------------------
        case Opcode::ArmAddShiftedRegisterNoPcAlways:
        case Opcode::ArmSubShiftedRegisterNoPcAlways:
        case Opcode::ArmLogicalShiftedRegisterNoPcAlways: {
            const u32 data_opcode = op.opcode == Opcode::ArmAddShiftedRegisterNoPcAlways
                                        ? 4
                                        : op.opcode == Opcode::ArmSubShiftedRegisterNoPcAlways
                                              ? 2
                                              : op.arg0 & 0xF;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            // amount==0 for lsr/asr means 32; ror#0 means rrx. Slow.
            if (shift_imm == 0 && shift_type != 0) {
                break;
            }
            if (auto* h = ShiftedAluHandler(data_opcode, shift_type)) {
                const u32 rd = op.arg1 & 0xF;
                const u32 rn = (op.arg1 >> 8) & 0xF;
                const u32 rm = (op.arg1 >> 16) & 0xF;
                rec = MakeRecord(h, rd | (rn << 8) | (rm << 16) | (shift_imm << 24));
            }
            break;
        }
        // -- multiply ------------------------------------------------------
        case Opcode::ArmMultiplyAlways: {
            const bool accumulate = ((op.arg0 >> 8) & 1) != 0;
            const bool set_flags = ((op.arg0 >> 9) & 1) != 0;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rs = (op.arg1 >> 16) & 0xF;
            const u32 rm = (op.arg1 >> 24) & 0xF;
            // Any r15 operand reads the live guest pc in C++ but stale
            // memory in asm; slow-exit.
            if (rd != 15 && rn != 15 && rs != 15 && rm != 15) {
                void (*body)() =
                    accumulate ? (set_flags ? citra_asm_op_mlas : citra_asm_op_mla)
                               : (set_flags ? citra_asm_op_muls : citra_asm_op_mul);
                if (accumulate) {
                    rec = MakeRecord(body,
                                     rd | (rm << 8) | (rs << 16) | (rn << 24));
                } else {
                    rec = MakeRecord(body, rd | (rm << 8) | (rs << 16));
                }
            }
            break;
        }
        case Opcode::ArmMultiplyLongAlways: {
            const bool sign = ((op.arg0 >> 8) & 1) != 0;
            const bool accumulate = ((op.arg0 >> 9) & 1) != 0;
            const bool set_flags = ((op.arg0 >> 10) & 1) != 0;
            const u32 rd_lo = op.arg1 & 0xF;
            const u32 rd_hi = (op.arg1 >> 8) & 0xF;
            const u32 rs = (op.arg1 >> 16) & 0xF;
            const u32 rm = (op.arg1 >> 24) & 0xF;
            // r15 operands diverge (stale pc), and rd_lo==rd_hi diverges on
            // writeback order (C++ writes hi then lo, asm lo then hi).
            const bool any_pc = rd_lo == 15 || rd_hi == 15 || rs == 15 || rm == 15;
            if (!any_pc && rd_lo != rd_hi) {
                rec = MakeRecord(
                    set_flags ? citra_asm_op_mulls : citra_asm_op_mull, op.arg1,
                    (sign ? 1 : 0) | (accumulate ? 2 : 0));
            }
            break;
        }
        // -- fused compare + conditional branch -----------------------------
        case Opcode::ArmCompareImmediateBranchNoPcAlways: {
            const u32 rn = op.arg0 & 0xF;
            const bool negative = ((op.arg0 >> 4) & 1) != 0;
            const u32 cond = (op.arg0 >> 8) & 0xF;
            // Block-terminating like ArmBranch: require last op.
            if (cond < kArmCondAl && i == count - 1 && (asm_mask & kAsmMaskFusedBranch)) {
                const bool self_loop = op.arg2 == block.start_pc;
                rec = MakeRecord(
                    self_loop
                        ? (negative ? kCmnBraChainHandlers[cond]
                                    : kCmpBraChainHandlers[cond])
                        : (negative ? kCmnBraHandlers[cond] : kCmpBraHandlers[cond]),
                    rn | (static_cast<u64>(op.guest_size) << 16) |
                        (static_cast<u64>(block.guest_instruction_count) << 24),
                    op.arg1,
                    self_loop ? Builder::kBlockStartTarget
                              : Builder::ResolveTarget(op.arg2),
                    op.arg2);
            }
            break;
        }
        case Opcode::ArmCompareRegisterBranchNoPcAlways: {
            const u32 rn = op.arg0 & 0xF;
            const u32 rm = (op.arg0 >> 4) & 0xF;
            const bool negative = ((op.arg0 >> 8) & 1) != 0;
            const u32 cond = (op.arg0 >> 12) & 0xF;
            // Block-terminating like ArmBranch: require last op.
            if (cond < kArmCondAl && i == count - 1 && (asm_mask & kAsmMaskFusedBranch)) {
                const bool self_loop = op.arg1 == block.start_pc;
                rec = MakeRecord(
                    self_loop
                        ? (negative ? kCmnRBraChainCmnHandlers[cond]
                                    : kCmpRBraChainHandlers[cond])
                        : (negative ? kCmnRBraCmnHandlers[cond]
                                    : kCmpRBraHandlers[cond]),
                    rn | (rm << 8) | (static_cast<u64>(op.guest_size) << 16) |
                        (static_cast<u64>(block.guest_instruction_count) << 24),
                    self_loop ? Builder::kBlockStartTarget
                              : Builder::ResolveTarget(op.arg1),
                    op.arg1);
            }
            break;
        }
        // -- conditional skip ------------------------------------------------
        // a0 (record-stream skip distance) is patched after the whole block is
        // translated: guarded ops emit two records, so the distance cannot be
        // derived from the IR op count here.
        case Opcode::ArmConditionalSkip: {
            const u32 cond = op.arg0 & 0xF;
            if (cond < kArmCondAl) {
                rec = MakeRecord(kSkipHandlers[cond], 0, op.arg2, op.arg1);
                pending_skips.emplace_back(first_rec_of_op[i],
                                           static_cast<u32>(i + 1 + op.arg1));
            }
            break;
        }
        case Opcode::ArmConditionalSkipEq:
        case Opcode::ArmConditionalSkipNe:
        case Opcode::ArmConditionalSkipCs:
        case Opcode::ArmConditionalSkipCc:
        case Opcode::ArmConditionalSkipMi:
        case Opcode::ArmConditionalSkipPl:
        case Opcode::ArmConditionalSkipVs:
        case Opcode::ArmConditionalSkipVc:
        case Opcode::ArmConditionalSkipHi:
        case Opcode::ArmConditionalSkipLs:
        case Opcode::ArmConditionalSkipGe:
        case Opcode::ArmConditionalSkipLt:
        case Opcode::ArmConditionalSkipGt:
        case Opcode::ArmConditionalSkipLe: {
            const u32 cond =
                static_cast<u32>(op.opcode) - static_cast<u32>(Opcode::ArmConditionalSkipEq);
            rec = MakeRecord(kSkipHandlers[cond], 0, op.arg2, op.arg1);
            pending_skips.emplace_back(first_rec_of_op[i],
                                       static_cast<u32>(i + 1 + op.arg1));
            break;
        }
        // -- immediate load/store --------------------------------------------
        case Opcode::ArmLoadWordImmediateNoPc:
            rec = MakeRecord(((op.arg1 >> 16) & 1) ? citra_asm_op_ldrw_add : citra_asm_op_ldrw_sub,
                             op.arg1 & 0xFFFF, op.arg2, i);
            break;
        case Opcode::ArmStoreWordImmediateNoPc:
            rec = MakeRecord(((op.arg1 >> 16) & 1) ? citra_asm_op_strw_add : citra_asm_op_strw_sub,
                             op.arg1 & 0xFFFF, op.arg2, i);
            break;
        case Opcode::ArmLoadWordImmediateNoPcAdd:
            rec = MakeRecord(citra_asm_op_ldrw_add, op.arg1, op.arg2, i);
            break;
        case Opcode::ArmLoadWordImmediateNoPcSub:
            rec = MakeRecord(citra_asm_op_ldrw_sub, op.arg1, op.arg2, i);
            break;
        case Opcode::ArmLoadWordImmediateNoPcOffset0:
            rec = MakeRecord(citra_asm_op_ldrw_add, op.arg1, 0, i);
            break;
        case Opcode::ArmStoreWordImmediateNoPcAdd:
            rec = MakeRecord(citra_asm_op_strw_add, op.arg1, op.arg2, i);
            break;
        case Opcode::ArmStoreWordImmediateNoPcSub:
            rec = MakeRecord(citra_asm_op_strw_sub, op.arg1, op.arg2, i);
            break;
        case Opcode::ArmStoreWordImmediateNoPcOffset0:
            rec = MakeRecord(citra_asm_op_strw_add, op.arg1, 0, i);
            break;
        case Opcode::ArmLoadByteImmediateNoPc:
            rec = MakeRecord(((op.arg1 >> 16) & 1) ? citra_asm_op_ldrb_add : citra_asm_op_ldrb_sub,
                             op.arg1 & 0xFFFF, op.arg2, i);
            break;
        case Opcode::ArmStoreByteImmediateNoPc:
            rec = MakeRecord(((op.arg1 >> 16) & 1) ? citra_asm_op_strb_add : citra_asm_op_strb_sub,
                             op.arg1 & 0xFFFF, op.arg2, i);
            break;
        case Opcode::ArmLoadByteImmediateNoPcAdd:
            rec = MakeRecord(citra_asm_op_ldrb_add, op.arg1, op.arg2, i);
            break;
        case Opcode::ArmLoadByteImmediateNoPcSub:
            rec = MakeRecord(citra_asm_op_ldrb_sub, op.arg1, op.arg2, i);
            break;
        case Opcode::ArmLoadByteImmediateNoPcOffset0:
            rec = MakeRecord(citra_asm_op_ldrb_add, op.arg1, 0, i);
            break;
        case Opcode::ArmStoreByteImmediateNoPcAdd:
            rec = MakeRecord(citra_asm_op_strb_add, op.arg1, op.arg2, i);
            break;
        case Opcode::ArmStoreByteImmediateNoPcSub:
            rec = MakeRecord(citra_asm_op_strb_sub, op.arg1, op.arg2, i);
            break;
        case Opcode::ArmStoreByteImmediateNoPcOffset0:
            rec = MakeRecord(citra_asm_op_strb_add, op.arg1, 0, i);
            break;
        case Opcode::ArmLoadHalfwordImmediateNoPc:
            rec = MakeRecord(((op.arg1 >> 16) & 1) ? citra_asm_op_ldrh_add : citra_asm_op_ldrh_sub,
                             op.arg1 & 0xFFFF, op.arg2, i);
            break;
        case Opcode::ArmStoreHalfwordImmediateNoPc:
            rec = MakeRecord(((op.arg1 >> 16) & 1) ? citra_asm_op_strh_add : citra_asm_op_strh_sub,
                             op.arg1 & 0xFFFF, op.arg2, i);
            break;
        case Opcode::ArmLoadHalfwordImmediateNoPcAdd:
            rec = MakeRecord(citra_asm_op_ldrh_add, op.arg1, op.arg2, i);
            break;
        case Opcode::ArmLoadHalfwordImmediateNoPcSub:
            rec = MakeRecord(citra_asm_op_ldrh_sub, op.arg1, op.arg2, i);
            break;
        case Opcode::ArmLoadHalfwordImmediateNoPcOffset0:
            rec = MakeRecord(citra_asm_op_ldrh_add, op.arg1, 0, i);
            break;
        case Opcode::ArmStoreHalfwordImmediateNoPcAdd:
            rec = MakeRecord(citra_asm_op_strh_add, op.arg1, op.arg2, i);
            break;
        case Opcode::ArmStoreHalfwordImmediateNoPcSub:
            rec = MakeRecord(citra_asm_op_strh_sub, op.arg1, op.arg2, i);
            break;
        case Opcode::ArmStoreHalfwordImmediateNoPcOffset0:
            rec = MakeRecord(citra_asm_op_strh_add, op.arg1, 0, i);
            break;
        case Opcode::ArmLoadSignedByteImmediateNoPc:
            rec = MakeRecord(((op.arg1 >> 16) & 1) ? citra_asm_op_ldrsb_add : citra_asm_op_ldrsb_sub,
                             op.arg1 & 0xFFFF, op.arg2, i);
            break;
        case Opcode::ArmLoadSignedByteImmediateNoPcAdd:
            rec = MakeRecord(citra_asm_op_ldrsb_add, op.arg1, op.arg2, i);
            break;
        case Opcode::ArmLoadSignedByteImmediateNoPcSub:
            rec = MakeRecord(citra_asm_op_ldrsb_sub, op.arg1, op.arg2, i);
            break;
        case Opcode::ArmLoadSignedByteImmediateNoPcOffset0:
            rec = MakeRecord(citra_asm_op_ldrsb_add, op.arg1, 0, i);
            break;
        case Opcode::ArmLoadSignedHalfwordImmediateNoPc:
            rec = MakeRecord(((op.arg1 >> 16) & 1) ? citra_asm_op_ldrsh_add : citra_asm_op_ldrsh_sub,
                             op.arg1 & 0xFFFF, op.arg2, i);
            break;
        case Opcode::ArmLoadSignedHalfwordImmediateNoPcAdd:
            rec = MakeRecord(citra_asm_op_ldrsh_add, op.arg1, op.arg2, i);
            break;
        case Opcode::ArmLoadSignedHalfwordImmediateNoPcSub:
            rec = MakeRecord(citra_asm_op_ldrsh_sub, op.arg1, op.arg2, i);
            break;
        case Opcode::ArmLoadSignedHalfwordImmediateNoPcOffset0:
            rec = MakeRecord(citra_asm_op_ldrsh_add, op.arg1, 0, i);
            break;
        // -- register-offset load/store (shifted rm) ----------------------
        // arg1 = rd|rn<<8|rm<<16|add<<20, arg2 = shift_type|shift_imm<<8.
        // r15 operands read the live guest pc in C++; shift_imm==0 for
        // lsr/asr/ror has special semantics. Both slow-exit.
        case Opcode::ArmLoadWordRegisterNoPc:
        case Opcode::ArmStoreWordRegisterNoPc:
        case Opcode::ArmLoadByteRegisterNoPc:
        case Opcode::ArmStoreByteRegisterNoPc: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const bool add = (op.arg1 >> 20) & 1;
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            if (rd == 15 || rn == 15 || rm == 15 ||
                (shift_imm == 0 && shift_type != 0)) {
                break;
            }
            void (*h)() = nullptr;
            switch (op.opcode) {
            case Opcode::ArmLoadWordRegisterNoPc:
                h = add ? citra_asm_op_ldrw_reg_add : citra_asm_op_ldrw_reg_sub;
                break;
            case Opcode::ArmStoreWordRegisterNoPc:
                h = add ? citra_asm_op_strw_reg_add : citra_asm_op_strw_reg_sub;
                break;
            case Opcode::ArmLoadByteRegisterNoPc:
                h = add ? citra_asm_op_ldrb_reg_add : citra_asm_op_ldrb_reg_sub;
                break;
            default:
                h = add ? citra_asm_op_strb_reg_add : citra_asm_op_strb_reg_sub;
                break;
            }
            rec = MakeRecord(h, op.arg1 & 0xFFFFF, op.arg2, i);
            break;
        }
        // Plain rm add/sub forms: no shift, reuse the shifted handlers with
        // a1 = 0 (lsl #0).
        case Opcode::ArmLoadWordRegisterNoPcAdd:
        case Opcode::ArmLoadWordRegisterNoPcSub:
        case Opcode::ArmStoreWordRegisterNoPcAdd:
        case Opcode::ArmStoreWordRegisterNoPcSub:
        case Opcode::ArmLoadByteRegisterNoPcAdd:
        case Opcode::ArmLoadByteRegisterNoPcSub:
        case Opcode::ArmStoreByteRegisterNoPcAdd:
        case Opcode::ArmStoreByteRegisterNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            if (rd == 15 || rn == 15 || rm == 15) {
                break;
            }
            void (*h)() = nullptr;
            switch (op.opcode) {
            case Opcode::ArmLoadWordRegisterNoPcAdd:
                h = citra_asm_op_ldrw_reg_add;
                break;
            case Opcode::ArmLoadWordRegisterNoPcSub:
                h = citra_asm_op_ldrw_reg_sub;
                break;
            case Opcode::ArmStoreWordRegisterNoPcAdd:
                h = citra_asm_op_strw_reg_add;
                break;
            case Opcode::ArmStoreWordRegisterNoPcSub:
                h = citra_asm_op_strw_reg_sub;
                break;
            case Opcode::ArmLoadByteRegisterNoPcAdd:
                h = citra_asm_op_ldrb_reg_add;
                break;
            case Opcode::ArmLoadByteRegisterNoPcSub:
                h = citra_asm_op_ldrb_reg_sub;
                break;
            case Opcode::ArmStoreByteRegisterNoPcAdd:
                h = citra_asm_op_strb_reg_add;
                break;
            default:
                h = citra_asm_op_strb_reg_sub;
                break;
            }
            rec = MakeRecord(h, op.arg1 & 0xFFFFF, 0, i);
            break;
        }
        // -- register-offset halfword/signed (plain rm, no shift) ---------
        // arg1 = rd|rn<<8|add<<16, arg2 = rm.
        case Opcode::ArmLoadHalfwordRegisterNoPc:
        case Opcode::ArmStoreHalfwordRegisterNoPc:
        case Opcode::ArmLoadSignedByteRegisterNoPc:
        case Opcode::ArmLoadSignedHalfwordRegisterNoPc:
        case Opcode::ArmLoadHalfwordRegisterNoPcAdd:
        case Opcode::ArmLoadHalfwordRegisterNoPcSub:
        case Opcode::ArmStoreHalfwordRegisterNoPcAdd:
        case Opcode::ArmStoreHalfwordRegisterNoPcSub:
        case Opcode::ArmLoadSignedByteRegisterNoPcAdd:
        case Opcode::ArmLoadSignedByteRegisterNoPcSub:
        case Opcode::ArmLoadSignedHalfwordRegisterNoPcAdd:
        case Opcode::ArmLoadSignedHalfwordRegisterNoPcSub: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = op.arg2 & 0xF;
            if (rd == 15 || rn == 15 || rm == 15) {
                break;
            }
            // Generic forms carry add at arg1 bit16; the Add/Sub specialisations
            // encode direction in the opcode name instead.
            const bool add =
                op.opcode == Opcode::ArmLoadHalfwordRegisterNoPc ||
                        op.opcode == Opcode::ArmStoreHalfwordRegisterNoPc ||
                        op.opcode == Opcode::ArmLoadSignedByteRegisterNoPc ||
                        op.opcode == Opcode::ArmLoadSignedHalfwordRegisterNoPc
                    ? (op.arg1 >> 16) & 1
                    : op.opcode == Opcode::ArmLoadHalfwordRegisterNoPcAdd ||
                          op.opcode == Opcode::ArmStoreHalfwordRegisterNoPcAdd ||
                          op.opcode == Opcode::ArmLoadSignedByteRegisterNoPcAdd ||
                          op.opcode == Opcode::ArmLoadSignedHalfwordRegisterNoPcAdd;
            void (*h)() = nullptr;
            switch (op.opcode) {
            case Opcode::ArmLoadHalfwordRegisterNoPc:
            case Opcode::ArmLoadHalfwordRegisterNoPcAdd:
            case Opcode::ArmLoadHalfwordRegisterNoPcSub:
                h = add ? citra_asm_op_ldrh_reg_add : citra_asm_op_ldrh_reg_sub;
                break;
            case Opcode::ArmStoreHalfwordRegisterNoPc:
            case Opcode::ArmStoreHalfwordRegisterNoPcAdd:
            case Opcode::ArmStoreHalfwordRegisterNoPcSub:
                h = add ? citra_asm_op_strh_reg_add : citra_asm_op_strh_reg_sub;
                break;
            case Opcode::ArmLoadSignedByteRegisterNoPc:
            case Opcode::ArmLoadSignedByteRegisterNoPcAdd:
            case Opcode::ArmLoadSignedByteRegisterNoPcSub:
                h = add ? citra_asm_op_ldrsb_reg_add : citra_asm_op_ldrsb_reg_sub;
                break;
            default:
                h = add ? citra_asm_op_ldrsh_reg_add : citra_asm_op_ldrsh_reg_sub;
                break;
            }
            rec = MakeRecord(h, op.arg1 & 0xFFFF, rm, i);
            break;
        }
        // -- immediate-offset load/store with writeback --------------------
        // arg1 = rd|rn<<8|add<<16|pre<<17, arg2 = offset. rn==15 reads the
        // live pc in C++; rd==15 writes/stores stale pc. Both slow-exit.
        case Opcode::ArmLoadWordImmediateWriteback:
        case Opcode::ArmStoreWordImmediateWriteback:
        case Opcode::ArmLoadByteImmediateWriteback:
        case Opcode::ArmStoreByteImmediateWriteback:
        case Opcode::ArmLoadHalfwordImmediateWriteback:
        case Opcode::ArmStoreHalfwordImmediateWriteback:
        case Opcode::ArmLoadSignedByteImmediateWriteback:
        case Opcode::ArmLoadSignedHalfwordImmediateWriteback: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            if (rd == 15 || rn == 15) {
                break;
            }
            const bool add = (op.arg1 >> 16) & 1;
            void (*h)() = nullptr;
            switch (op.opcode) {
            case Opcode::ArmLoadWordImmediateWriteback:
                h = add ? citra_asm_op_ldrw_wb : citra_asm_op_ldrw_wb_sub;
                break;
            case Opcode::ArmStoreWordImmediateWriteback:
                h = add ? citra_asm_op_strw_wb : citra_asm_op_strw_wb_sub;
                break;
            case Opcode::ArmLoadByteImmediateWriteback:
                h = add ? citra_asm_op_ldrb_wb : citra_asm_op_ldrb_wb_sub;
                break;
            case Opcode::ArmStoreByteImmediateWriteback:
                h = add ? citra_asm_op_strb_wb : citra_asm_op_strb_wb_sub;
                break;
            case Opcode::ArmLoadHalfwordImmediateWriteback:
                h = add ? citra_asm_op_ldrh_wb : citra_asm_op_ldrh_wb_sub;
                break;
            case Opcode::ArmStoreHalfwordImmediateWriteback:
                h = add ? citra_asm_op_strh_wb : citra_asm_op_strh_wb_sub;
                break;
            case Opcode::ArmLoadSignedByteImmediateWriteback:
                h = add ? citra_asm_op_ldrsb_wb : citra_asm_op_ldrsb_wb_sub;
                break;
            default:
                h = add ? citra_asm_op_ldrsh_wb : citra_asm_op_ldrsh_wb_sub;
                break;
            }
            rec = MakeRecord(h, op.arg1 & 0x3FFFF, op.arg2, i);
            break;
        }
        // -- register-offset load/store with writeback (ops 123-126) --------
        // arg1 = rd|rn<<8|rm<<16|add<<20|pre<<21, arg2 = shift_type|imm<<8.
        // Decode guarantees rd/rn/rm != 15 and rd != rn. The LSR#0/ASR#0/
        // ROR#0 offset encodings carry shifted-address semantics the shared
        // SHIFT_RM sequence does not reproduce, so they stay slow.
        case Opcode::ArmLoadWordRegisterWriteback:
        case Opcode::ArmStoreWordRegisterWriteback:
        case Opcode::ArmLoadByteRegisterWriteback:
        case Opcode::ArmStoreByteRegisterWriteback: {
            const u32 shift_type = op.arg2 & 0x3;
            const u32 shift_imm = (op.arg2 >> 8) & 0x1F;
            if (shift_imm == 0 && shift_type != 0) {
                break;
            }
            const bool load = op.opcode == Opcode::ArmLoadWordRegisterWriteback ||
                              op.opcode == Opcode::ArmLoadByteRegisterWriteback;
            const bool byte_transfer =
                op.opcode == Opcode::ArmLoadByteRegisterWriteback ||
                op.opcode == Opcode::ArmStoreByteRegisterWriteback;
            const bool add = (op.arg1 >> 20) & 1;
            void (*h)() = nullptr;
            if (load) {
                h = byte_transfer
                        ? (add ? citra_asm_op_ldrb_reg_wb : citra_asm_op_ldrb_reg_wb_sub)
                        : (add ? citra_asm_op_ldrw_reg_wb : citra_asm_op_ldrw_reg_wb_sub);
            } else {
                h = byte_transfer
                        ? (add ? citra_asm_op_strb_reg_wb : citra_asm_op_strb_reg_wb_sub)
                        : (add ? citra_asm_op_strw_reg_wb : citra_asm_op_strw_reg_wb_sub);
            }
            rec = MakeRecord(h, op.arg1, op.arg2, i);
            break;
        }
        // -- register-offset halfword/signed writeback (ops 131-134) --------
        // arg1 = rd|rn<<8|add<<16|pre<<17, arg2 = rm index (no shift).
        // rm==15 would read the stale pc slot in asm, so it stays slow.
        case Opcode::ArmLoadHalfwordRegisterWriteback:
        case Opcode::ArmStoreHalfwordRegisterWriteback:
        case Opcode::ArmLoadSignedByteRegisterWriteback:
        case Opcode::ArmLoadSignedHalfwordRegisterWriteback: {
            if ((op.arg2 & 0xF) == 15) {
                break;
            }
            const bool add = (op.arg1 >> 16) & 1;
            void (*h)() = nullptr;
            switch (op.opcode) {
            case Opcode::ArmLoadHalfwordRegisterWriteback:
                h = add ? citra_asm_op_ldrh_reg_wb : citra_asm_op_ldrh_reg_wb_sub;
                break;
            case Opcode::ArmStoreHalfwordRegisterWriteback:
                h = add ? citra_asm_op_strh_reg_wb : citra_asm_op_strh_reg_wb_sub;
                break;
            case Opcode::ArmLoadSignedByteRegisterWriteback:
                h = add ? citra_asm_op_ldrsb_reg_wb : citra_asm_op_ldrsb_reg_wb_sub;
                break;
            default:
                h = add ? citra_asm_op_ldrsh_reg_wb : citra_asm_op_ldrsh_reg_wb_sub;
                break;
            }
            rec = MakeRecord(h, op.arg1, op.arg2, i);
            break;
        }
        // -- ldrd/strd (conditional forms repack onto the fast bodies) -------
        // arg0 = cond, arg1 = rd|rn<<8|add<<16|imm<<17|pre<<18|wb<<19,
        // arg2 = offset (immediate forms only; register offsets stay slow).
        case Opcode::ArmLoadStoreDouble: {
            const u32 cond = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool load = ((op.arg0 >> 8) & 1) != 0;
            const bool immediate_offset = (op.arg1 >> 17) & 1;
            const bool add = (op.arg1 >> 16) & 1;
            const bool writes_back = (op.arg1 >> 19) & 1;
            // The fast bodies cannot express the rn==rd/rd+1 writeback aliasing
            // (store reads Reg[rd] pre-writeback, load suppresses wb entirely).
            if (cond >= kArmCondAl || !(asm_mask & kAsmMaskGuard) ||
                !(asm_mask & kAsmMaskGuardLdSt) || !immediate_offset || rd >= 14 ||
                rn == 15 || (writes_back && (rn == rd || rn == rd + 1))) {
                break;
            }
            void (*h)() = nullptr;
            if (load) {
                h = add ? citra_asm_op_ldrd : citra_asm_op_ldrd_sub;
            } else {
                h = add ? citra_asm_op_strd : citra_asm_op_strd_sub;
            }
            b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
            rec = MakeRecord(h, op.arg1 & 0xFFFFF, op.arg2, i);
            break;
        }
        // -- ldrd/strd (immediate offsets only) ----------------------------
        // arg1 = rd|rn<<8|add<<16|imm<<17|pre<<18|wb<<19, arg2 = offset.
        case Opcode::ArmLoadDoubleFast:
        case Opcode::ArmStoreDoubleFast: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const bool immediate_offset = (op.arg1 >> 17) & 1;
            const bool add = (op.arg1 >> 16) & 1;
            // rd+1 must stay a data register; rn==15 reads the live pc.
            if (!immediate_offset || rd >= 14 || rn == 15) {
                break;
            }
            void (*h)() = nullptr;
            if (op.opcode == Opcode::ArmLoadDoubleFast) {
                h = add ? citra_asm_op_ldrd : citra_asm_op_ldrd_sub;
            } else {
                h = add ? citra_asm_op_strd : citra_asm_op_strd_sub;
            }
            rec = MakeRecord(h, op.arg1 & 0xFFFFF, op.arg2, i);
            break;
        }
        // -- LDM/STM ---------------------------------------------------------
        // arg0 = wb|add<<1|pre<<2, arg1 = rn|list<<8, arg2 = register count.
        case Opcode::ArmLoadMultipleFast:
        case Opcode::ArmStoreMultipleFast: {
            const bool writeback = op.arg0 & 1;
            const bool add = (op.arg0 >> 1) & 1;
            const bool pre = (op.arg0 >> 2) & 1;
            const u32 rn = op.arg1 & 0xF;
            const u32 register_list = (op.arg1 >> 8) & 0x7FFF;
            const u32 count = op.arg2;
            if (rn == 15 || register_list == 0 || count > 15) {
                break;
            }
            rec = MakeRecord(op.opcode == Opcode::ArmLoadMultipleFast ? citra_asm_op_ldm
                                                                      : citra_asm_op_stm,
                             rn | (writeback << 4) | (add << 5) | (pre << 6),
                             register_list | (count << 20), i);
            break;
        }
        // -- VFP load/store --------------------------------------------------
        // arg0 bit0 = add; arg1 = rn|ext_reg<<8; arg2 = offset.
        case Opcode::ArmVFPLoadSingleFast:
        case Opcode::ArmVFPStoreSingleFast:
        case Opcode::ArmVFPLoadDoubleFast:
        case Opcode::ArmVFPStoreDoubleFast: {
            const bool add = op.arg0 & 1;
            const u32 rn = op.arg1 & 0xF;
            const u32 ext_reg = (op.arg1 >> 8) & 0x3F;
            const bool is_double = op.opcode == Opcode::ArmVFPLoadDoubleFast ||
                                   op.opcode == Opcode::ArmVFPStoreDoubleFast;
            const bool is_load = op.opcode == Opcode::ArmVFPLoadSingleFast ||
                                 op.opcode == Opcode::ArmVFPLoadDoubleFast;
            if (rn == 15) {
                // Literal-pool load: ReadAddressRegister returns
                // (Reg[15] & ~3) + guest_size*2, a translate-time constant.
                if (is_load && !(is_double && ext_reg + 2 > 64)) {
                    const u32 lit_addr =
                        add ? pc_addr_i + op.arg2 : pc_addr_i - op.arg2;
                    rec = MakeRecord(is_double ? citra_asm_op_vldd_lit
                                               : citra_asm_op_vlds_lit,
                                     ext_reg, lit_addr, i);
                }
                break;
            }
            if (is_double && ext_reg + 2 > 64) {
                break;
            }
            void (*h)() = nullptr;
            switch (op.opcode) {
            case Opcode::ArmVFPLoadSingleFast:
                h = add ? citra_asm_op_vlds_add : citra_asm_op_vlds_sub;
                break;
            case Opcode::ArmVFPStoreSingleFast:
                h = add ? citra_asm_op_vsts_add : citra_asm_op_vsts_sub;
                break;
            case Opcode::ArmVFPLoadDoubleFast:
                h = add ? citra_asm_op_vldd_add : citra_asm_op_vldd_sub;
                break;
            default:
                h = add ? citra_asm_op_vstd_add : citra_asm_op_vstd_sub;
                break;
            }
            rec = MakeRecord(h, ext_reg | (rn << 8), op.arg2, i);
            break;
        }
        // -- generic conditional VFP load/store -------------------------------
        // arg0 = cond | load<<8 | single<<9 | add<<10 | multiple<<11 | wb<<12;
        // arg1 = rn|ext_reg<<8; arg2 = byte offset (single/double) or transfer
        // size (multiple). The decode only emits this for cond != AL, so it is
        // repacked onto the unconditional fast bodies behind a guard record:
        // multiple -> vldm/vstm, single -> vlds/vsts, double -> vldd/vstd.
        // rn==15 loads fold the literal-pool address; stores/multiple/
        // writeback forms stay slow.
        case Opcode::ArmVFPLoadStore: {
            const u32 cond = op.arg0 & 0xF;
            const bool load = ((op.arg0 >> 8) & 1) != 0;
            const bool single = ((op.arg0 >> 9) & 1) != 0;
            const bool add = ((op.arg0 >> 10) & 1) != 0;
            const bool multiple = ((op.arg0 >> 11) & 1) != 0;
            const bool wb = ((op.arg0 >> 12) & 1) != 0;
            const u32 rn = op.arg1 & 0xF;
            const u32 ext_reg = (op.arg1 >> 8) & 0x3F;
            const u32 bytes = op.arg2;
            if (cond >= kArmCondAl || !(asm_mask & kAsmMaskGuard) ||
                !(asm_mask & kAsmMaskGuardLdSt)) {
                break;
            }
            if (rn == 15) {
                // Conditional literal-pool load: the C++ interpreter uses
                // (Reg[15] & ~3) + 8 here, a translate-time constant.
                // Multiple/writeback forms and stores stay slow.
                if (load && !multiple && !wb &&
                    (single || ext_reg + 2 <= 64)) {
                    const u32 lit_base =
                        static_cast<u32>((instr_addr_i & ~3ULL) + 8ULL);
                    const u32 lit_addr = add ? lit_base + op.arg2
                                             : lit_base - op.arg2;
                    b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
                    rec = MakeRecord(single ? citra_asm_op_vlds_lit
                                            : citra_asm_op_vldd_lit,
                                     ext_reg, lit_addr, i);
                }
                break;
            }
            if (multiple ? (bytes == 0 || (bytes & 3) != 0 || ext_reg + bytes / 4 > 64)
                         : (!single && ext_reg + 2 > 64)) {
                break;
            }
            void (*body)() = nullptr;
            u64 a0 = 0;
            if (multiple) {
                body = load ? citra_asm_op_vldm : citra_asm_op_vstm;
                a0 = ext_reg | (rn << 8) | (static_cast<u64>(add) << 17) |
                     (static_cast<u64>(wb) << 18);
            } else if (single) {
                body = load ? (add ? citra_asm_op_vlds_add : citra_asm_op_vlds_sub)
                            : (add ? citra_asm_op_vsts_add : citra_asm_op_vsts_sub);
                a0 = ext_reg | (rn << 8);
            } else {
                body = load ? (add ? citra_asm_op_vldd_add : citra_asm_op_vldd_sub)
                            : (add ? citra_asm_op_vstd_add : citra_asm_op_vstd_sub);
                a0 = ext_reg | (rn << 8);
            }
            b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
            rec = MakeRecord(body, a0, op.arg2, i);
            break;
        }
        // arg0 = single|add<<1|wb<<2, arg1 = rn|ext_reg<<8, arg2 = bytes.
        case Opcode::ArmVFPLoadMultipleFast:
        case Opcode::ArmVFPStoreMultipleFast: {
            const bool add = (op.arg0 >> 1) & 1;
            const bool wb = (op.arg0 >> 2) & 1;
            const u32 rn = op.arg1 & 0xF;
            const u32 ext_reg = (op.arg1 >> 8) & 0x3F;
            const u32 bytes = op.arg2;
            if (rn == 15 || bytes == 0 || (bytes & 3) != 0 ||
                ext_reg + bytes / 4 > 64) {
                break;
            }
            rec = MakeRecord(op.opcode == Opcode::ArmVFPLoadMultipleFast
                                 ? citra_asm_op_vldm
                                 : citra_asm_op_vstm,
                             ext_reg | (rn << 8) | (add << 17) | (wb << 18), bytes, i);
            break;
        }
        // -- VFP register transfer -------------------------------------------
        // arg0 = to_arm<<8|pair<<9; arg1 = rt|rt2<<8 (non-pair: ext_reg<<8);
        // arg2 = ext_reg (pair only). pc operands slow-exit.
        case Opcode::ArmVFPRegisterTransferAlways: {
            const bool to_arm = (op.arg0 >> 8) & 1;
            const bool pair = (op.arg0 >> 9) & 1;
            const u32 rt = op.arg1 & 0xF;
            const u32 rt2 = (op.arg1 >> 8) & 0xF;
            const u32 ext_reg = pair ? op.arg2 : ((op.arg1 >> 8) & 0x3F);
            if (rt == 15 || (pair && rt2 == 15) || ext_reg + (pair ? 2 : 1) > 64) {
                break;
            }
            rec = MakeRecord(citra_asm_op_vfp_xfr,
                             to_arm | (pair << 1) | (rt << 8) | (rt2 << 12) |
                                 (static_cast<u64>(ext_reg) << 16),
                             0, i);
            break;
        }
        // -- VFP system register transfer ------------------------------------
        // arg0 = cond|read<<8; arg1 = vfp_reg|rt<<8. Asm covers the
        // directly-indexed VFP[] cases: reads {0,1,6,7}, write {1}, plus
        // "vmrs apsr_nzcv, fpscr" (read FPSCR with rt==15) which lands the
        // flag nibble in the host NZCV. Reads of 8/9/10 are privileged-gated
        // (user mode emits no result) and writes likewise, so they stay on
        // the slow path; the case-7 encoding maps to MVFR0 = VFP[5].
        case Opcode::ArmVFPSystemRegisterTransfer: {
            const u32 condition = op.arg0 & 0xF;
            const bool read = (op.arg0 >> 8) & 1;
            const u32 vfp_reg = op.arg1 & 0xF;
            const u32 rt = (op.arg1 >> 8) & 0xF;
            if (!(asm_mask & kAsmMaskSysReg)) {
                break;
            }
            u32 vfp_index = 0;
            bool to_nzcv = false;
            if (read) {
                switch (vfp_reg) {
                case 0:
                    vfp_index = 0; // VFP_FPSID
                    break;
                case 1:
                    vfp_index = 1; // VFP_FPSCR
                    break;
                case 6:
                    vfp_index = 6; // VFP_MVFR1
                    break;
                case 7:
                    vfp_index = 5; // VFP_MVFR0
                    break;
                default:
                    vfp_index = 0xFF;
                    break;
                }
                // rt==15 is only legal for the FPSCR->APSR_nzcv transfer;
                // other VFP system registers have no flag-alias semantics.
                if (rt == 15) {
                    if (vfp_index != 1) {
                        break;
                    }
                    to_nzcv = true;
                }
            } else {
                if (vfp_reg == 1 && rt != 15) {
                    vfp_index = 1; // VFP_FPSCR
                } else {
                    break;
                }
            }
            if (vfp_index == 0xFF) {
                break;
            }
            if (condition != kArmCondAl) {
                if (!(asm_mask & kAsmMaskGuard)) {
                    break;
                }
                b.ops.push_back(MakeRecord(kGuardHandlers[condition], op.guest_size));
            }
            rec = MakeRecord(citra_asm_op_vfp_sys,
                             read | (vfp_index << 4) | (rt << 8) |
                                 (static_cast<u64>(to_nzcv) << 16),
                             0, i);
            break;
        }
        // -- MRS: move CPSR/SPSR to a general register -----------------------
        // arg0 = cond|spsr<<8; arg1 = rd. rd==15 stays slow (the generic C++
        // path writes Reg[15], which interacts with pc tracking). CPSR reads
        // merge the live host NZCV into the stored CPSR's top nibble.
        case Opcode::ArmMoveStatusToRegister: {
            const u32 condition = op.arg0 & 0xF;
            const bool source_spsr = (op.arg0 >> 8) & 1;
            const u32 rd = op.arg1 & 0xF;
            if (!(asm_mask & kAsmMaskSysReg) || rd == 15) {
                break;
            }
            if (condition != kArmCondAl) {
                if (!(asm_mask & kAsmMaskGuard)) {
                    break;
                }
                b.ops.push_back(MakeRecord(kGuardHandlers[condition], op.guest_size));
            }
            rec = MakeRecord(citra_asm_op_mrs,
                             rd | (static_cast<u64>(source_spsr) << 4), 0, i);
            break;
        }
        // -- CP15 transfer -----------------------------------------------------
        // arg0 = cond|read<<8; arg1 = rd|crn<<8|crm<<16; arg2 = op1|op2<<8.
        // Only the hot unprivileged TLS reads (mrc p15,#0,rd,c13,c0,{2,3})
        // run in asm; writes, privileged registers and rd==15 flag writes
        // keep the C++ implementation.
        case Opcode::ArmCoprocessor15Transfer: {
            const u32 condition = op.arg0 & 0xF;
            const bool read = (op.arg0 >> 8) & 1;
            const u32 rd = op.arg1 & 0xF;
            const u32 crn = (op.arg1 >> 8) & 0xF;
            const u32 crm = (op.arg1 >> 16) & 0xF;
            const u32 opcode_1 = op.arg2 & 0x7;
            const u32 opcode_2 = (op.arg2 >> 8) & 0x7;
            const bool tls_read = read && rd != 15 && crn == 13 && crm == 0 &&
                                  opcode_1 == 0 && (opcode_2 == 2 || opcode_2 == 3);
            if (!(asm_mask & kAsmMaskSysReg)) {
                break;
            }
            if (condition != kArmCondAl && !(asm_mask & kAsmMaskGuard)) {
                break;
            }
            if (tls_read) {
                if (condition != kArmCondAl) {
                    b.ops.push_back(MakeRecord(kGuardHandlers[condition], op.guest_size));
                }
                rec = MakeRecord(citra_asm_op_cp15_tls,
                                 rd | (static_cast<u64>(opcode_2 == 3) << 4), 0, i);
                break;
            }
            // Generic register transfer: resolve the (crn,op1,crm,op2) tuple
            // to a CP15[] index now. mrc-to-pc (flag copy) and the
            // unimplemented v2p write stay on the C++ path.
            const int index = read ? Cp15ReadIndex(crn, opcode_1, crm, opcode_2)
                                   : Cp15WriteIndex(crn, opcode_1, crm, opcode_2);
            const bool unmapped = index < 0;
            const bool v2p_write = !read && crn == 7 && opcode_1 == 0 && crm == 4 &&
                                   opcode_2 == 0;
            if (v2p_write || (read && (unmapped || rd == 15))) {
                break;
            }
            if (condition != kArmCondAl) {
                b.ops.push_back(MakeRecord(kGuardHandlers[condition], op.guest_size));
            }
            if (unmapped) {
                // Unmapped privileged writes are silently ignored.
                rec = MakeRecord(citra_asm_op_nop, 0, 0, i);
                break;
            }
            rec = MakeRecord(read ? citra_asm_op_cp15_rd : citra_asm_op_cp15_wr,
                             rd | (static_cast<u64>(index & 0xFF) << 8), 0, i);
            break;
        }
        // -- exclusive load/store --------------------------------------------
        // arg0 = cond|size<<8; arg1 = rd|rn<<8|rm<<16. Only the word form
        // (size==0: LDREX/STREX) is covered; byte/half/double and PC operand
        // encodings stay slow. Conditional ops get a guard record.
        case Opcode::ArmExclusiveLoad:
        case Opcode::ArmExclusiveStore: {
            const u32 condition = op.arg0 & 0xF;
            const u32 size = (op.arg0 >> 8) & 0x3;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const bool load = op.opcode == Opcode::ArmExclusiveLoad;
            if (size != 0 || rd == 15 || rn == 15 || (!load && rm == 15) ||
                !(asm_mask & kAsmMaskExclusive)) {
                break;
            }
            if (condition != kArmCondAl) {
                if (!(asm_mask & kAsmMaskGuard)) {
                    break;
                }
                b.ops.push_back(MakeRecord(kGuardHandlers[condition], op.guest_size));
            }
            rec = MakeRecord(load ? citra_asm_op_ldrex : citra_asm_op_strex,
                             op.arg1, 0, i);
            break;
        }
        // ArmClearExclusive (op5): fixed encoding 0xF57FF01F, unconditional.
        case Opcode::ArmClearExclusive:
            if (asm_mask & kAsmMaskExclusive) {
                rec = MakeRecord(citra_asm_op_clrex);
            }
            break;
        // ArmCountLeadingZeros (op17): clz rd, rm. Predicated forms use the
        // guard+body pattern; rm/rd == 15 stay slow (stale-PC read / raw
        // Reg[15] write semantics).
        case Opcode::ArmCountLeadingZeros: {
            const u32 cond = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            if (cond > kArmCondAl || rd == 15 || rm == 15) {
                break;
            }
            if (cond == kArmCondAl) {
                rec = MakeRecord(citra_asm_op_clz, op.arg1);
                break;
            }
            if (!(asm_mask & kAsmMaskGuard)) {
                break;
            }
            b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
            rec = MakeRecord(citra_asm_op_clz, op.arg1);
            break;
        }
        // ArmExtend (op18): uxtb/uxth/sxtb/sxth rd, rm{, ror}. rm==15 reads a
        // stale pc; rd==15 keeps the raw Reg[15]-write semantics on C++.
        case Opcode::ArmExtend: {
            const u32 cond = op.arg0 & 0xF;
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            if (cond > kArmCondAl || rd == 15 || rm == 15) {
                break;
            }
            if (cond < kArmCondAl && !(asm_mask & kAsmMaskGuard)) {
                break;
            }
            if (cond < kArmCondAl) {
                b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
            }
            rec = MakeRecord(citra_asm_op_ext, op.arg0, op.arg1);
            break;
        }
        // ArmReverse (op19): rev/rev16/revsh. Type 3 (rbit) stays slow.
        case Opcode::ArmReverse: {
            const u32 cond = op.arg0 & 0xF;
            const u32 type = (op.arg0 >> 8) & 0x3;
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            if (cond > kArmCondAl || type > 2 || rd == 15 || rm == 15) {
                break;
            }
            if (cond < kArmCondAl && !(asm_mask & kAsmMaskGuard)) {
                break;
            }
            if (cond < kArmCondAl) {
                b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
            }
            rec = MakeRecord(citra_asm_op_rev, op.arg0, op.arg1);
            break;
        }
        // -- shifted-operand flag writers ---------------------------------------
        // ArmMoveShiftedRegisterSetFlagsAlways (op92): movs rd, rm, shift_imm.
        // AL-only by construction (decode rejects other conditions).
        case Opcode::ArmMoveShiftedRegisterSetFlagsAlways: {
            if (!(asm_mask & kAsmMaskShiftFlags)) {
                break;
            }
            rec = MakeRecord(citra_asm_op_movs_shift, op.arg1, op.arg2, i);
            break;
        }
        // ArmArithmeticShiftedRegisterNoPcAlways (op198): ADC/SBC/RSC/RSB with
        // immediate-shifted rm, no flag write. arg0 = data_opcode.
        case Opcode::ArmArithmeticShiftedRegisterNoPcAlways: {
            if (!(asm_mask & kAsmMaskShiftFlags)) {
                break;
            }
            const u32 data_opcode = op.arg0 & 0xF;
            if (data_opcode != 3 && data_opcode != 5 && data_opcode != 6 &&
                data_opcode != 7) {
                break;
            }
            const u64 rd = op.arg1 & 0xF;
            const u64 rn = (op.arg1 >> 8) & 0xF;
            const u64 rm = (op.arg1 >> 16) & 0xF;
            rec = MakeRecord(citra_asm_op_carith_shift,
                             data_opcode | (rd << 8) | (rn << 12) | (rm << 16),
                             op.arg2, i);
            break;
        }
        // ArmLogicalRegisterShiftedRegisterSetFlagsNoPcAlways (op207):
        // AND/EOR/TST/TEQ/ORR/MOV/BIC/MVN with shift amount from Reg[rs]&0xFF.
        case Opcode::ArmLogicalRegisterShiftedRegisterSetFlagsNoPcAlways: {
            if (!(asm_mask & kAsmMaskShiftFlags)) {
                break;
            }
            const u32 data_opcode = op.arg0 & 0xF;
            const bool logical_ok = data_opcode == 0 || data_opcode == 1 ||
                                    data_opcode == 8 || data_opcode == 9 ||
                                    data_opcode == 12 || data_opcode == 13 ||
                                    data_opcode == 14 || data_opcode == 15;
            const u32 rd = op.arg1 & 0xF;
            if (!logical_ok || rd == 15) {
                break;
            }
            rec = MakeRecord(citra_asm_op_logregs_s, op.arg0, op.arg1, op.arg2);
            break;
        }
        // ArmArithmeticImmediateSetFlagsNoPcAlways (op171): rsbs/adcs/sbcs/
        // rscs rd, rn, #imm -- decode guarantees {3,5,6,7} and rn/rd != 15.
        // arg0 = data_opcode, arg1 = rd|rn<<8, arg2 = imm.
        case Opcode::ArmArithmeticImmediateSetFlagsNoPcAlways: {
            if (!(asm_mask & kAsmMaskShiftFlags)) {
                break;
            }
            void (*h)() = nullptr;
            switch (op.arg0 & 0xF) {
            case 3:
                h = citra_asm_op_rsbs_imm;
                break;
            case 5:
                h = citra_asm_op_adcs_imm;
                break;
            case 6:
                h = citra_asm_op_sbcs_imm;
                break;
            case 7:
                h = citra_asm_op_rscs_imm;
                break;
            default:
                break;
            }
            if (!h) {
                break;
            }
            rec = MakeRecord(h, op.arg1, op.arg2);
            break;
        }
        // ArmMoveRegisterShiftedRegisterAlways (op101): mov rd, rm, <shift> rs
        // with rs from a register. arg1 = rd | rm<<8 | rs<<16, arg2 = shift.
        // rm/rs==15 read a stale pc in asm; rd<15 is guaranteed by decode.
        case Opcode::ArmMoveRegisterShiftedRegisterAlways: {
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 rs = (op.arg1 >> 16) & 0xF;
            if (rm == 15 || rs == 15 || !(asm_mask & kAsmMaskShiftFlags)) {
                break;
            }
            rec = MakeRecord(kMovRShiftHandlers[op.arg2 & 0x3], op.arg1);
            break;
        }
        // ArmMoveRegisterShiftedRegisterSetFlagsAlways (op102): movs variant
        // of the above. logregs_s already implements data_opcode 13 (its rn
        // load is unused for mov) -- repack arg1 with rn=15 filler. Decode
        // guarantees rm/rs != 15; rd == 15 would jump and stays slow.
        case Opcode::ArmMoveRegisterShiftedRegisterSetFlagsAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            const u32 rs = (op.arg1 >> 16) & 0xF;
            if (rd == 15 || !(asm_mask & kAsmMaskShiftFlags)) {
                break;
            }
            rec = MakeRecord(citra_asm_op_logregs_s, 13,
                             rd | (15 << 8) | (rm << 16) | (rs << 24), op.arg2);
            break;
        }
        // ArmLogicalRegisterSetFlagsNoPcAlways (op169):
        // AND/EOR/TST/TEQ/ORR/MOV/BIC/MVN rd, rn, rm with flag update.
        // arg0 = data_opcode, arg1 = rd | rn<<8 | rm<<16. Plain register
        // operand, so C is preserved rather than shifter-derived.
        case Opcode::ArmLogicalRegisterSetFlagsNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const bool logical_ok = data_opcode == 0 || data_opcode == 1 ||
                                    data_opcode == 8 || data_opcode == 9 ||
                                    data_opcode == 12 || data_opcode == 13 ||
                                    data_opcode == 14 || data_opcode == 15;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            if (!logical_ok || rd == 15 || rn == 15 || rm == 15 ||
                !(asm_mask & kAsmMaskLogicFlag)) {
                break;
            }
            rec = MakeRecord(citra_asm_op_logreg_s, op.arg0, op.arg1, i);
            break;
        }
        // ArmLogicalImmediateSetFlagsNoPcAlways (op168):
        // AND/EOR/TST/TEQ/ORR/MOV/BIC/MVN rd, rn, #imm with flag update.
        // arg0 = data | carry<<8 | carry_from_c<<9, arg1 = rd|rn<<8,
        // arg2 = imm -- the handler reads exactly this layout.
        case Opcode::ArmLogicalImmediateSetFlagsNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const bool logical_ok = data_opcode == 0 || data_opcode == 1 ||
                                    data_opcode == 8 || data_opcode == 9 ||
                                    data_opcode == 12 || data_opcode == 13 ||
                                    data_opcode == 14 || data_opcode == 15;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            if (!logical_ok || rd == 15 || rn == 15 ||
                !(asm_mask & kAsmMaskLogicFlag)) {
                break;
            }
            rec = MakeRecord(citra_asm_op_logimm_s, op.arg0, op.arg1, op.arg2);
            break;
        }
        // ArmLogicalRegisterShiftedRegisterNoPcAlways (op206):
        // AND/EOR/ORR/MOV/BIC/MVN rd, rn, rm <shift> (rs & 0xFF), no flags.
        // arg1 = rd | rn<<8 | rm<<16 | rs<<24; rm/rs==15 read a stale pc.
        case Opcode::ArmLogicalRegisterShiftedRegisterNoPcAlways: {
            const u32 data_opcode = op.arg0 & 0xF;
            const bool logical_ok = data_opcode == 0 || data_opcode == 1 ||
                                    data_opcode == 12 || data_opcode == 13 ||
                                    data_opcode == 14 || data_opcode == 15;
            const u32 rd = op.arg1 & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rs = (op.arg1 >> 24) & 0xF;
            if (!logical_ok || rd == 15 || rn == 15 || rm == 15 || rs == 15 ||
                !(asm_mask & kAsmMaskShiftFlags)) {
                break;
            }
            rec = MakeRecord(citra_asm_op_logregsh, op.arg0, op.arg1, op.arg2);
            break;
        }
        // ArmSub/Add/ArithmeticRegisterShiftedRegisterNoPcAlways:
        // non-flag rd = rn OP (rm <shift> Reg[rs]&0xFF) for data ops 2-7.
        // arg1 = rd | rn<<8 | rm<<16 | rs<<24, arg2 = shift_type -- the
        // alu_regsh handler's a0 packs the data opcode plus the shift type.
        case Opcode::ArmSubRegisterShiftedRegisterNoPcAlways:
        case Opcode::ArmAddRegisterShiftedRegisterNoPcAlways:
        case Opcode::ArmArithmeticRegisterShiftedRegisterNoPcAlways: {
            const u32 rm = (op.arg1 >> 16) & 0xF;
            const u32 rs = (op.arg1 >> 24) & 0xF;
            const u32 rn = (op.arg1 >> 8) & 0xF;
            const u32 rd = op.arg1 & 0xF;
            if (rd == 15 || rn == 15 || rm == 15 || rs == 15 ||
                !(asm_mask & kAsmMaskGuardDpReg)) {
                break;
            }
            const u32 data_opcode =
                op.opcode == Opcode::ArmSubRegisterShiftedRegisterNoPcAlways  ? 2
                : op.opcode == Opcode::ArmAddRegisterShiftedRegisterNoPcAlways ? 4
                                                                             : op.arg0 & 0xF;
            rec = MakeRecord(citra_asm_op_alu_regsh,
                             static_cast<u64>(data_opcode) |
                                 (static_cast<u64>(op.arg2 & 0x3) << 8),
                             op.arg1, static_cast<u64>(i));
            break;
        }
        // ArmMoveRegisterSetFlagsAlways / ArmMoveNotRegisterSetFlagsAlways
        // (op297/298): movs/mvns rd, rm -- N/Z from the result, C/V kept.
        // arg1 = rd | rm<<8.
        case Opcode::ArmMoveRegisterSetFlagsAlways:
        case Opcode::ArmMoveNotRegisterSetFlagsAlways: {
            const u32 rd = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            if (rd == 15 || rm == 15 || !(asm_mask & kAsmMaskLogicFlag)) {
                break;
            }
            rec = MakeRecord(
                op.opcode == Opcode::ArmMoveRegisterSetFlagsAlways
                    ? citra_asm_op_movs_reg
                    : citra_asm_op_mvns_reg,
                op.arg1);
            break;
        }
        // ArmTst/TeqRegisterNoShiftNoPcAlways (op300/301): tst/teq rn, rm --
        // flags-only logical tests; C/V carry over from the current flags.
        // arg1 = rn | rm<<8 -> repack to logreg_s layout (rd|rn<<8|rm<<16).
        case Opcode::ArmTstRegisterNoShiftNoPcAlways:
        case Opcode::ArmTeqRegisterNoShiftNoPcAlways: {
            const u32 rn = op.arg1 & 0xF;
            const u32 rm = (op.arg1 >> 8) & 0xF;
            if (rn == 15 || rm == 15 || !(asm_mask & kAsmMaskLogicFlag)) {
                break;
            }
            const u64 data =
                op.opcode == Opcode::ArmTstRegisterNoShiftNoPcAlways ? 8 : 9;
            rec = MakeRecord(citra_asm_op_logreg_s, data,
                             static_cast<u64>(rn) << 8 |
                                 (static_cast<u64>(rm) << 16),
                             static_cast<u64>(i));
            break;
        }
        // -- fused set-flags + conditional branch -------------------------------
        // op218: adds/subs rn, #imm + cond branch; terminates the block like
        // the cmp+branch fusions. a0 is repacked to keep the branch condition
        // in the handler name and the fused guest size at bits 16-23.
        case Opcode::ArmAddSubImmediateSetFlagsBranchNoPcAlways: {
            const u32 cond = (op.arg0 >> 12) & 0xF;
            if (cond < kArmCondAl && i == count - 1 &&
                (asm_mask & (kAsmMaskAluBranch | kAsmMaskFusedBranch)) ==
                    (kAsmMaskAluBranch | kAsmMaskFusedBranch)) {
                const bool self_loop = op.arg2 == block.start_pc;
                const u64 rd = op.arg0 & 0xF;
                const u64 rn = (op.arg0 >> 4) & 0xF;
                const u64 sub = (op.arg0 >> 8) & 1;
                rec = MakeRecord(
                    self_loop ? kAsiBraChainHandlers[cond] : kAsiBraHandlers[cond],
                    rd | (rn << 4) | (sub << 8) |
                        (static_cast<u64>(op.guest_size) << 16) |
                        (static_cast<u64>(block.guest_instruction_count) << 24),
                    op.arg1,
                    self_loop ? Builder::kBlockStartTarget : Builder::ResolveTarget(op.arg2),
                    op.arg2);
            }
            break;
        }
        // op219: adds/subs rd, rn, rm + cond branch -- register-operand
        // sibling of op218. a0 = rd | rn<<4 | rm<<8 | sub<<12 |
        // fused_size<<16 | block_instrs<<24; a2 = taken record, a3 = taken pc.
        case Opcode::ArmAddSubRegisterSetFlagsBranchNoPcAlways: {
            const u32 cond = (op.arg0 >> 16) & 0xF;
            if (cond < kArmCondAl && i == count - 1 &&
                (asm_mask & (kAsmMaskAluBranch | kAsmMaskFusedBranch)) ==
                    (kAsmMaskAluBranch | kAsmMaskFusedBranch)) {
                const bool self_loop = op.arg1 == block.start_pc;
                rec = MakeRecord(
                    self_loop ? kAsrBraChainHandlers[cond] : kAsrBraHandlers[cond],
                    (op.arg0 & 0xFFFF) |
                        (static_cast<u64>(op.guest_size) << 16) |
                        (static_cast<u64>(block.guest_instruction_count) << 24),
                    0,
                    self_loop ? Builder::kBlockStartTarget : Builder::ResolveTarget(op.arg1),
                    op.arg1);
            }
            break;
        }
        // op212: cmp/cmn rn, rm, <shift> #imm + cond branch.
        // a0 = rn | rm<<4 | cmn<<8 | fused_size<<16 | block_instrs<<24;
        // a1 = shift_type|shift_imm<<8; a2 = taken record, a3 = taken pc.
        case Opcode::ArmCompareShiftedRegisterBranchNoPcAlways: {
            const u32 cond = (op.arg0 >> 12) & 0xF;
            if (cond < kArmCondAl && i == count - 1 &&
                (asm_mask & (kAsmMaskAluBranch | kAsmMaskFusedBranch)) ==
                    (kAsmMaskAluBranch | kAsmMaskFusedBranch)) {
                const bool self_loop = op.arg1 == block.start_pc;
                rec = MakeRecord(
                    self_loop ? kCmpsBraChainHandlers[cond] : kCmpsBraHandlers[cond],
                    (op.arg0 & 0x1FF) |
                        (static_cast<u64>(op.guest_size) << 16) |
                        (static_cast<u64>(block.guest_instruction_count) << 24),
                    op.arg2,
                    self_loop ? Builder::kBlockStartTarget : Builder::ResolveTarget(op.arg1),
                    op.arg1);
            }
            break;
        }
        // op227: rsb/adc/sbc/rsc rd, rn, rm + cond branch -- non-shifted
        // sibling of op228. a0 = data|rd<<4|rn<<8|rm<<12|fused<<16|block<<24;
        // a2 = taken record, a3 = taken pc.
        case Opcode::ArmCarryArithmeticRegisterSetFlagsBranchNoPcAlways: {
            const u32 cond = (op.arg0 >> 16) & 0xF;
            if (cond < kArmCondAl && i == count - 1 &&
                (asm_mask & (kAsmMaskAluBranch | kAsmMaskFusedBranch)) ==
                    (kAsmMaskAluBranch | kAsmMaskFusedBranch)) {
                const bool self_loop = op.arg1 == block.start_pc;
                rec = MakeRecord(
                    self_loop ? kCarBraChainHandlers[cond] : kCarBraHandlers[cond],
                    (op.arg0 & 0xFFFF) |
                        (static_cast<u64>(op.guest_size) << 16) |
                        (static_cast<u64>(block.guest_instruction_count) << 24),
                    0,
                    self_loop ? Builder::kBlockStartTarget : Builder::ResolveTarget(op.arg1),
                    op.arg1);
            }
            break;
        }
        // op228: rsb/adc/sbc/rsc rd, rn, rm, <shift> #imm + cond branch.
        case Opcode::ArmCarryArithmeticShiftedRegisterSetFlagsBranchNoPcAlways: {
            const u32 cond = (op.arg0 >> 16) & 0xF;
            if (cond < kArmCondAl && i == count - 1 &&
                (asm_mask & (kAsmMaskAluBranch | kAsmMaskFusedBranch)) ==
                    (kAsmMaskAluBranch | kAsmMaskFusedBranch)) {
                const bool self_loop = op.arg1 == block.start_pc;
                rec = MakeRecord(
                    self_loop ? kCasrBraChainHandlers[cond] : kCasrBraHandlers[cond],
                    (op.arg0 & 0xFFFF) |
                        (static_cast<u64>(op.guest_size) << 16) |
                        (static_cast<u64>(block.guest_instruction_count) << 24),
                    op.arg2,
                    self_loop ? Builder::kBlockStartTarget : Builder::ResolveTarget(op.arg1),
                    op.arg1);
            }
            break;
        }
        // op223: and/eor/orr/mov/bic/mvn rd, rn, rm + cond branch.
        case Opcode::ArmLogicalRegisterSetFlagsBranchNoPcAlways: {
            const u32 cond = (op.arg0 >> 16) & 0xF;
            const u32 data_opcode = op.arg0 & 0xF;
            const bool logical_ok = data_opcode == 0 || data_opcode == 1 ||
                                    data_opcode == 12 || data_opcode == 13 ||
                                    data_opcode == 14 || data_opcode == 15;
            if (cond < kArmCondAl && logical_ok && i == count - 1 &&
                (asm_mask & (kAsmMaskAluBranch | kAsmMaskFusedBranch)) ==
                    (kAsmMaskAluBranch | kAsmMaskFusedBranch)) {
                const bool self_loop = op.arg1 == block.start_pc;
                const u64 rd = (op.arg0 >> 4) & 0xF;
                const u64 rn = (op.arg0 >> 8) & 0xF;
                const u64 rm = (op.arg0 >> 12) & 0xF;
                rec = MakeRecord(
                    self_loop ? kLogRBraChainHandlers[cond] : kLogRBraHandlers[cond],
                    data_opcode | (rd << 4) | (rn << 8) | (rm << 12) |
                        (static_cast<u64>(op.guest_size) << 16) |
                        (static_cast<u64>(block.guest_instruction_count) << 24),
                    self_loop ? Builder::kBlockStartTarget : Builder::ResolveTarget(op.arg1),
                    op.arg1);
            }
            break;
        }
        // op224: and/eor/orr/bic/mvn rd, rn, rm, <shift> rs + cond branch.
        // a0 = data | rd<<4 | rn<<8 | rm<<12 | rs<<16;
        // a1 = shift_type | fused_size<<8 | block_instrs<<16;
        // a2 = taken record, a3 = taken pc.
        case Opcode::ArmLogicalRegisterShiftedRegisterSetFlagsBranchNoPcAlways: {
            const u32 cond = (op.arg0 >> 20) & 0xF;
            if (cond < kArmCondAl && i == count - 1 &&
                (asm_mask & (kAsmMaskAluBranch | kAsmMaskFusedBranch)) ==
                    (kAsmMaskAluBranch | kAsmMaskFusedBranch)) {
                const bool self_loop = op.arg1 == block.start_pc;
                rec = MakeRecord(
                    self_loop ? kLogRsBraChainHandlers[cond] : kLogRsBraHandlers[cond],
                    op.arg0 & 0xFFFFF,
                    (op.arg2 & 0xFF) | (static_cast<u64>(op.guest_size) << 8) |
                        (static_cast<u64>(block.guest_instruction_count) << 16),
                    self_loop ? Builder::kBlockStartTarget : Builder::ResolveTarget(op.arg1),
                    op.arg1);
            }
            break;
        }
        // op222: and/eor/orr/mov/bic/mvn rd, rn, #imm + cond branch.
        // a0 = data | rd<<4 | rn<<8 | carry<<12 | carry_from_c<<13 |
        //      fused_size<<16 | block_instrs<<24; a1 = imm;
        // a2 = taken record, a3 = taken pc.
        case Opcode::ArmLogicalImmediateSetFlagsBranchNoPcAlways: {
            const u32 cond = (op.arg0 >> 12) & 0xF;
            const u32 data_opcode = op.arg0 & 0xF;
            const bool logical_ok = data_opcode == 0 || data_opcode == 1 ||
                                    data_opcode == 12 || data_opcode == 13 ||
                                    data_opcode == 14 || data_opcode == 15;
            const u32 rn = (op.arg0 >> 8) & 0xF;
            if (cond < kArmCondAl && logical_ok && rn != 15 && i == count - 1 &&
                (asm_mask & (kAsmMaskAluBranch | kAsmMaskFusedBranch)) ==
                    (kAsmMaskAluBranch | kAsmMaskFusedBranch)) {
                const bool self_loop = op.arg2 == block.start_pc;
                const u64 rd = (op.arg0 >> 4) & 0xF;
                const u64 carry = (op.arg0 >> 16) & 1;
                const u64 carry_from_c = (op.arg0 >> 17) & 1;
                rec = MakeRecord(
                    self_loop ? kLogIBraChainHandlers[cond] : kLogIBraHandlers[cond],
                    data_opcode | (rd << 4) | (static_cast<u64>(rn) << 8) |
                        (carry << 12) | (carry_from_c << 13) |
                        (static_cast<u64>(op.guest_size) << 16) |
                        (static_cast<u64>(block.guest_instruction_count) << 24),
                    op.arg1,
                    self_loop ? Builder::kBlockStartTarget : Builder::ResolveTarget(op.arg2),
                    op.arg2);
            }
            break;
        }
        // -- standalone TST/TEQ with immediate ---------------------------------
        // arg0 = shifter_carry | from_c_flag<<1, arg1 = rn, arg2 = imm.
        case Opcode::ArmTstImmediateNoPcAlways:
        case Opcode::ArmTeqImmediateNoPcAlways: {
            if (!(asm_mask & kAsmMaskLogicFlag) || op.arg1 >= 15) {
                break;
            }
            const u64 a0 = op.arg1 | ((op.arg0 & 1) << 8) | (((op.arg0 >> 1) & 1) << 9);
            rec = MakeRecord(op.opcode == Opcode::ArmTstImmediateNoPcAlways
                                 ? citra_asm_op_tst_imm_f
                                 : citra_asm_op_teq_imm_f,
                             a0, op.arg2, i);
            break;
        }
        // -- VFP scalar data processing ----------------------------------------
        // Mode-0 ops (raw instruction word in arg1) map to the vfpdp handler,
        // which runs the host-FP subset of VfpHost::TryExecute and slow-exits
        // anything outside its normal-or-zero scalar domain. VMOVI/VMOVR
        // (modes 1/2) are unconditional bit moves with no FP semantics, so the
        // vfpmov handler covers them exactly -- no domain check needed.
        case Opcode::ArmVFPDataProcessing:
        case Opcode::ArmVFPDataProcessingAlways: {
            const u32 mode = (op.arg0 >> 8) & 3;
            const u32 cond = op.arg0 & 0xF;
            if (!(asm_mask & kAsmMaskVfpDp) || mode == 3) {
                break;
            }
            if (mode == 0) {
                const u32 inst = static_cast<u32>(op.arg1);
                const u64 packed = static_cast<u64>(vfp_get_sd(inst)) |
                                   (static_cast<u64>(vfp_get_sn(inst)) << 5) |
                                   (static_cast<u64>(vfp_get_sm(inst)) << 10) |
                                   (static_cast<u64>(vfp_get_dd(inst)) << 15) |
                                   (static_cast<u64>(vfp_get_dn(inst)) << 20) |
                                   (static_cast<u64>(vfp_get_dm(inst)) << 25);
                if (cond != kArmCondAl) {
                    if (!(asm_mask & kAsmMaskGuard)) {
                        break;
                    }
                    b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
                }
                rec = MakeRecord(citra_asm_op_vfpdp, inst, packed, i);
                break;
            }
            // VMOVI (mode 1) / VMOVR (mode 2): a0 = d | m<<5 | single<<10 |
            // imm<<11, a1 = arg2 (immediate for VMOVI, m for VMOVR -- the
            // handler only consults a1 on the immediate path).
            const u64 packed = (op.arg1 & 0x1F) | ((op.arg2 & 0x1F) << 5) |
                               (((op.arg0 >> 10) & 1) << 10) |
                               (static_cast<u64>(mode == 1) << 11);
            if (cond != kArmCondAl) {
                if (!(asm_mask & kAsmMaskGuard)) {
                    break;
                }
                b.ops.push_back(MakeRecord(kGuardHandlers[cond], op.guest_size));
            }
            rec = MakeRecord(citra_asm_op_vfpmov, packed, op.arg2, i);
            break;
        }
        default:
            break;
        }

        b.ops.push_back(rec);
        // a3 carries the per-op guest_size for NEXT_A dispatch, except for
        // the fused-branch families where a3 is the taken pc.
        if (op.opcode != Opcode::ArmCompareImmediateBranchNoPcAlways &&
            op.opcode != Opcode::ArmAddSubImmediateSetFlagsBranchNoPcAlways &&
            op.opcode != Opcode::ArmAddSubRegisterSetFlagsBranchNoPcAlways &&
            op.opcode != Opcode::ArmCompareShiftedRegisterBranchNoPcAlways &&
            op.opcode != Opcode::ArmLogicalImmediateSetFlagsBranchNoPcAlways &&
            op.opcode != Opcode::ArmCarryArithmeticRegisterSetFlagsBranchNoPcAlways &&
            op.opcode != Opcode::ArmCarryArithmeticShiftedRegisterSetFlagsBranchNoPcAlways &&
            op.opcode !=
                Opcode::ArmLogicalRegisterShiftedRegisterSetFlagsBranchNoPcAlways) {
            b.ops.back().a3 = op.guest_size;
        }
    }

    // Resident-register selection (v1.1): the program may hold guest r0-r2
    // in host registers for the whole run only when every record is
    // provably safe against the stale regfile slots. Variant-family records
    // then swap to their *_v* handler; one unsafe op leaves the whole
    // program non-resident (nothing syncs resident regs mid-run).
    u32 resmask = 0;
    if (asm_mask & kAsmMaskResident) {
        // Variant swaps are staged, not applied: one unsafe op later in the
        // block leaves resmask = 0, and a stale *_v* record would corrupt
        // resident registers the entry never loaded.
        std::vector<std::pair<u32, u64>> staged;
        bool all_safe = true;
        for (u32 i = 0; i < count && all_safe; ++i) {
            const u32 body_idx =
                (i + 1 < count ? first_rec_of_op[i + 1]
                               : static_cast<u32>(b.ops.size())) - 1;
            ARMIR::AsmOp& rec = b.ops[body_idx];
            void (*handler)() = reinterpret_cast<void (*)()>(rec.handler);
            if (const ResFamSpec* fam = ResFamOf(handler)) {
                if (const u64 variant = ResVariantOf(*fam, rec.a0)) {
                    staged.emplace_back(body_idx, variant);
                }
                continue;
            }
            if (!ResCleanHandler(handler) &&
                !ResCheckableSafe(handler, rec.a0, rec.a1)) {
                all_safe = false;
            }
        }
        if (all_safe && !staged.empty()) {
            for (const auto& [idx, variant] : staged) {
                b.ops[idx].handler = variant;
            }
            resmask = 0x7;
            ++g_asm_stats.resident_programs;
        }
    }

    // Patch conditional-skip record distances now that the full record layout
    // is known. The skip handler runs with x9 already advanced past the skip
    // record, so the distance is relative to the record after it. A landing op
    // index past the block end resolves to the trailing `end` record.
    for (const auto& [skip_idx, landing_op] : pending_skips) {
        const u32 target =
            landing_op < count ? first_rec_of_op[landing_op] : static_cast<u32>(b.ops.size());
        b.ops[skip_idx].a0 = static_cast<u64>(target - (skip_idx + 1)) * sizeof(ARMIR::AsmOp);
    }

    b.Finish();

    auto program = std::make_shared<ARMIR::AsmProgram>();
    program->ops = std::move(b.ops);
    program->resmask = resmask;
    return program;
}

} // namespace Core::ARMAsm
