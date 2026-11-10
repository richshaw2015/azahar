// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

// Differential tests for the AArch64 threaded IR executor
// (src/core/arm/asm). Every program is executed by three machines with
// identical initial state:
//   * ARM_IRInterpreter with use_cpu_asm_interpreter = true
//   * ARM_IRInterpreter with the setting off (pure C++ switch path)
//   * ARM_DynCom as an independent reference
// All general registers, CPSR, VFP/CP15 state and written memory must
// match bit-for-bit. The ARMAsmStats checks also prove the assembly path
// actually executed (programs that silently degrade to all-slow exits
// would otherwise pass while testing nothing).

#include <algorithm>
#include <array>
#include <chrono>
#include <limits>
#include <memory>
#include <random>
#include <vector>

#include <catch2/catch_all.hpp>
#include <fmt/format.h>

#include "core/arm/arm_interface.h"
#include "core/arm/dyncom/arm_dyncom.h"
#include "core/arm/ir/arm_ir_interpreter.h"
#include "core/core.h"
#include "common/settings.h"
#include "tests/core/arm/arm_test_common.h"

#if defined(__aarch64__)
#include "core/arm/asm/arm_asm_exec.h"
#endif

namespace ArmTests {

using namespace Core;

namespace {

struct AsmFlagGuard {
    AsmFlagGuard() : old(Settings::values.use_cpu_asm_interpreter.GetValue()) {
        Settings::values.use_cpu_asm_interpreter.SetValue(true);
    }
    ~AsmFlagGuard() {
        Settings::values.use_cpu_asm_interpreter.SetValue(old);
    }
    bool old;
};

struct Machine {
    explicit Machine(bool use_ir)
        : env(true), timer(1, 100, 0), cpu(use_ir
                                      ? std::unique_ptr<ARM_Interface>(
                                            std::make_unique<Core::ARM_IRInterpreter>(
                                                Core::System::GetInstance(), env.GetMemory(),
                                                USER32MODE, 0, timer.GetTimer(0)))
                                      : std::unique_ptr<ARM_Interface>(std::make_unique<ARM_DynCom>(
                                            Core::System::GetInstance(), env.GetMemory(),
                                            USER32MODE, 0, timer.GetTimer(0)))) {}

    void Seed(const std::array<u32, 15>& regs, u32 cpsr = USER32MODE, u32 pc = 0) {
        for (int i = 0; i < 15; ++i) {
            cpu->SetReg(i, regs[i]);
        }
        for (int i = 0; i < 64; ++i) {
            cpu->SetVFPReg(i, 0x3F000000U + static_cast<u32>(i) * 0x10000U);
        }
        cpu->SetVFPSystemReg(VFP_FPSCR, 0);
        cpu->SetVFPSystemReg(VFP_FPEXC, 1U << 30);
        cpu->SetCPSR(cpsr);
        cpu->SetPC(pc);
    }

    void RunInstructions(u64 count) {
        timer.GetTimer(0)->Advance();
        timer.GetTimer(0)->SetNextSlice(static_cast<s64>(count));
        cpu->Run();
    }

    TestEnvironment env;
    Core::Timing timer;
    std::unique_ptr<ARM_Interface> cpu;
};

void Compare(Machine& a, Machine& b) {
    for (int i = 0; i < 16; ++i) {
        CAPTURE(i);
        REQUIRE(a.cpu->GetReg(i) == b.cpu->GetReg(i));
    }
    REQUIRE(a.cpu->GetCPSR() == b.cpu->GetCPSR());
    for (int i = 0; i < 64; ++i) {
        CAPTURE(i);
        REQUIRE(a.cpu->GetVFPReg(i) == b.cpu->GetVFPReg(i));
    }
    REQUIRE(a.cpu->GetVFPSystemReg(VFP_FPSCR) == b.cpu->GetVFPSystemReg(VFP_FPSCR));
    REQUIRE(a.cpu->GetVFPSystemReg(VFP_FPEXC) == b.cpu->GetVFPSystemReg(VFP_FPEXC));
    for (u32 i = 0; i < CP15_REGISTER_COUNT; ++i) {
        CAPTURE(i);
        REQUIRE(a.cpu->GetCP15Register(static_cast<CP15Register>(i)) ==
                b.cpu->GetCP15Register(static_cast<CP15Register>(i)));
    }
    for (u32 addr : {0U, 4U, 0x1000U, 0x1004U, 0x1008U, 0x1800U, 0x1FFCU}) {
        REQUIRE(a.env.GetMemory().Read32(addr) == b.env.GetMemory().Read32(addr));
    }
}

// Runs one ARM program through asm-IR, plain-IR and DynCom and compares
// all three end states. `budget` is the instruction slice handed to
// Run(); pick a value >= the program length when the program does not
// loop, or smaller to exercise mid-block budget exits.
void RunArm(const std::vector<u32>& program, const std::array<u32, 15>& regs,
            u32 cpsr = USER32MODE, u64 budget = 0) {
    Machine dyn(false), ir(true), ir_asm(true);
    for (std::size_t i = 0; i < program.size(); ++i) {
        dyn.env.SetMemory32(static_cast<VAddr>(i * 4), program[i]);
        ir.env.SetMemory32(static_cast<VAddr>(i * 4), program[i]);
        ir_asm.env.SetMemory32(static_cast<VAddr>(i * 4), program[i]);
    }
    dyn.Seed(regs, cpsr);
    ir.Seed(regs, cpsr);
    ir_asm.Seed(regs, cpsr);
    const u64 slice = budget != 0 ? budget : static_cast<u64>(program.size()) + 8;
    dyn.RunInstructions(slice);
    ir.RunInstructions(slice);
    {
        AsmFlagGuard guard;
        ir_asm.RunInstructions(slice);
    }
    INFO("compare ir vs dyn");
    Compare(ir, dyn);
    INFO("compare asm vs dyn");
    Compare(ir_asm, dyn);
}

// Same for a Thumb-1 program (16-bit instructions).
void RunThumb(const std::vector<u16>& program, const std::array<u32, 15>& regs,
              u32 cpsr = USER32MODE | TBIT, u64 budget = 0) {
    Machine dyn(false), ir(true), ir_asm(true);
    for (std::size_t i = 0; i < program.size(); ++i) {
        dyn.env.SetMemory16(static_cast<VAddr>(i * 2), program[i]);
        ir.env.SetMemory16(static_cast<VAddr>(i * 2), program[i]);
        ir_asm.env.SetMemory16(static_cast<VAddr>(i * 2), program[i]);
    }
    dyn.Seed(regs, cpsr);
    ir.Seed(regs, cpsr);
    ir_asm.Seed(regs, cpsr);
    const u64 slice = budget != 0 ? budget : static_cast<u64>(program.size()) + 8;
    dyn.RunInstructions(slice);
    ir.RunInstructions(slice);
    {
        AsmFlagGuard guard;
        ir_asm.RunInstructions(slice);
    }
    Compare(ir, dyn);
    Compare(ir_asm, dyn);
}

std::array<u32, 15> BaseRegs() {
    std::array<u32, 15> r{};
    r[0] = 0x12345678;
    r[1] = 0x1000;  // data area
    r[2] = 0x1004;
    r[3] = 0x9ABCDEF0;
    r[4] = 0xFFFF0000;
    r[5] = 0x0000FFFF;
    r[6] = 1;
    r[7] = 0x80000000;
    r[8] = 0x7FFFFFFF;
    r[9] = 0xDEADBEEF;
    r[10] = 3;
    r[11] = 0x1555;
    r[12] = 0xCAFEBABE;
    r[13] = 0x1800; // sp
    r[14] = 0x40;   // lr
    return r;
}

} // namespace

TEST_CASE("ARM asm executor: integer ALU immediate/register families", "[arm_asm]") {
    const std::vector<u32> program = {
        0xE2800001, // add r0, r0, #1
        0xE2401002, // sub r1, r0, #2
        0xE20320FF, // and r2, r3, #0xFF
        0xE22440F0, // eor r4, r4, #0xF0
        0xE3855001, // orr r5, r5, #1
        0xE3E66000, // mvn r6, #0
        0xE0827003, // add r7, r2, r3
        0xE0478005, // sub r8, r7, r5
        0xE0099008, // and r9, r9, r8
        0xE02AA009, // eor r10, r10, r9
        0xE18BB00A, // orr r11, r11, r10
        0xE1CCC00B, // bic r12, r12, r11
        0xE26CD007, // rsb r13, r12, #7
        0xE08AE003, // adc r14, r10, r3
        0xE0CAE00B, // sbc r14, r10, r11
        0xE0EAE00B, // rsc r14, r10, r11
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());
}

TEST_CASE("ARM asm executor: flag-setting ops and carry chains", "[arm_asm]") {
    const std::vector<u32> program = {
        0xE3A000FF, // mov r0, #0xFF
        0xE2901001, // adds r1, r0, #1
        0xE0B22001, // adcs r2, r2, r1      (reads carry from adds)
        0xE2503001, // subs r3, r0, #1
        0xE0D34002, // sbcs r4, r3, r2
        0xE3520000, // cmp r2, #0
        0xE1705004, // cmn r0, r4
        0xE1506001, // cmp r0, r1
        0xE3507000, // cmp r0, #0
        0xE2608001, // rsb r8, r0, #1      (no flags)
        0xE1509001, // cmp r0, r1          (flags again)
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());
    // Repeat with several flag preconditions.
    for (u32 cpsr_base : {0x00000000U, 0xF0000000U, 0x50000000U, 0xA0000000U}) {
        RunArm(program, BaseRegs(), USER32MODE | cpsr_base);
    }
}

TEST_CASE("ARM asm executor: shifted operands", "[arm_asm]") {
    const std::vector<u32> program = {
        0xE1A00100, // mov r0, r0, lsl #2
        0xE1A01120, // mov r1, r0, lsr #2
        0xE1A01240, // mov r1, r0, asr #4
        0xE1A01380, // mov r1, r0, ror #7
        0xE1A01020, // mov r1, r0, lsr #32  (encoded lsr #0)
        0xE1A01040, // mov r1, r0, asr #32  (encoded asr #0)
        0xE1A01060, // mov r1, r0, rrx      (encoded ror #0)
        0xE0822103, // add r2, r2, r3, lsl #2
        0xE0423223, // sub r3, r2, r3, lsr #4
        0xE0024103, // and r4, r2, r3, lsl #2
        0xE1825003, // orr r5, r2, r3, lsl #2
        0xE0226103, // eor r6, r2, r3, lsl #2
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());
}

TEST_CASE("ARM asm executor: multiply families", "[arm_asm]") {
    const std::vector<u32> program = {
        0xE0030192, // mul r3, r2, r1       (cond check encoding: E0030092?)
        0xE0234192, // mla r3, r2, r1, r4
        0xE0850692, // umull r0, r5, r2, r6
        0xE0A51693, // umlal r1, r5, r3, r6
        0xE0C50692, // smull r0, r5, r2, r6
        0xE0E51693, // smlal r1, r5, r3, r6
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());
}

TEST_CASE("ARM asm executor: load/store fastmem", "[arm_asm]") {
    const std::vector<u32> program = {
        0xE3A02401, // mov r2, #0x1000
        0xE5823004, // str r3, [r2, #4]
        0xE5924004, // ldr r4, [r2, #4]
        0xE5C25008, // strb r5, [r2, #8]
        0xE5D26008, // ldrb r6, [r2, #8]
        0xE1C270B4, // strh r7, [r2, #4]
        0xE1D280B4, // ldrh r8, [r2, #4]
        0xE1D290D2, // ldrsb r9, [r2, #2]
        0xE1D2A0F2, // ldrsh r10, [r2, #2]
        0xE542B00C, // str r11, [r2, #-12]
        0xE552C00C, // ldrb r12, [r2, #-12]
        0xE592D000, // ldr r13, [r2]        (offset0)
        0xE582E000, // str r14, [r2]        (offset0)
        0xEAFFFFFE, // b .
    };
    auto regs = BaseRegs();
    regs[7] = 0xABCD;
    regs[11] = 0x99887766;
    RunArm(program, regs);
}

TEST_CASE("ARM asm executor: unaligned and page-edge memory", "[arm_asm]") {
    // Accesses spanning the 4 KiB fastmem page edge must take the slow
    // exit; the C++ path result must be identical.
    const std::vector<u32> program = {
        0xE3A02E01, // mov r2, #0x10
        0xE5923101, // ldr r3, [r2, #0x101]   unaligned word at 0x111
        0xE5824101, // str r4, [r2, #0x101]
        0xE5925FED, // ldr r5, [r2, #0xFED]   -> 0xFFD crosses into page 1
        0xE5826FEE, // str r6, [r2, #0xFEE]   -> 0xFFE crosses into page 1
        0xE1D27FEF, // ldrh r7, [r2, #0xFEF]  -> 0xFFF crosses into page 1
        0xEAFFFFFE, // b .
    };
    auto regs = BaseRegs();
    regs[3] = 0xDEAD0001;
    regs[4] = 0x0BADF00D;
    regs[6] = 0x11223344;
    RunArm(program, regs);
}

TEST_CASE("ARM asm executor: conditional branches and fused compares", "[arm_asm]") {
    // Loop: r0 counts down from 8; each iteration adds r1 to r2.
    const std::vector<u32> program = {
        0xE3A00008, // mov r0, #8
        0xE3A02000, // mov r2, #0
        0xE0822001, // add r2, r2, r1        loop:
        0xE2500001, // subs r0, r0, #1
        0x1AFFFFFC, // bne loop
        0xE3520005, // cmp r2, #5
        0x82833001, // addhi r3, r3, #1      (conditional op -> skip guard)
        0x93500000, // cmpls r0, #0
        0xE3540000, // cmp r4, #0
        0x0A000001, // beq skip
        0xE2855001, // add r5, r5, #1        (not taken when r4==0)
        0xEAFFFFFE, // skip: b .
    };
    auto regs = BaseRegs();
    regs[4] = 0;
    RunArm(program, regs);
    regs[4] = 7;
    RunArm(program, regs);
}

TEST_CASE("ARM asm executor: slow exit mid-block preserves state", "[arm_asm]") {
    // Fast ops, then an LDM (slow op), then more fast ops. The slow exit
    // must hand a consistent state (regs + lazy flags + pc) back to C++.
    const std::vector<u32> program = {
        0xE2800001, // add r0, r0, #1
        0xE2901001, // adds r1, r0, #1       (flags now live)
        0xE892000F, // ldm r2, {r0-r3}       SLOW
        0x22833001, // addcs r3, r3, #1      reads flags materialized at exit
        0xE0824003, // add r4, r2, r3
        0xE8950018, // ldm r5, {r3,r4}       SLOW again
        0xE5855004, // str r5, [r5, #4]
        0xEAFFFFFE, // b .
    };
    auto regs = BaseRegs();
    regs[2] = 0x1400; // ldm source
    regs[5] = 0x1800;
    RunArm(program, regs);
}

TEST_CASE("ARM asm executor: Thumb programs", "[arm_asm]") {
#if defined(__aarch64__)
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    const std::vector<u16> program = {
        0x2003,       // movs r0, #3
        0x3004,       // adds r0, #4
        0x1C08,       // adds r0, r1, #0
        0x1888,       // adds r0, r1, r2
        0x4008,       // ands r0, r1
        0x4048,       // eors r0, r1
        0x6008,       // str r0, [r1, #0]
        0x6808,       // ldr r0, [r1, #0]
        0x7008,       // strb r0, [r1, #0]
        0x7808,       // ldrb r0, [r1, #0]
        0x9001,       // str r0, [sp, #4]
        0x9801,       // ldr r0, [sp, #4]
        0xE7FE,       // b .
    };
    RunThumb(program, BaseRegs());
#if defined(__aarch64__)
    // Thumb ops decode to the shared Arm* IR and must run through the asm
    // executor too (v1.3); a zero delta would mean Thumb silently falls
    // back to the C++ interpreter.
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
#endif
}

TEST_CASE("ARM asm executor: thumb bl prefix/suffix", "[arm_asm]") {
    // bl = ThumbBranchLinkSetup + ThumbBranchLink pair. The suffix is a
    // block terminator; the asm handler must carry the staged lr across
    // the pair and hand the taken pc to the end record's chain probe.
    RunThumb(
        {
            0xF000, 0xF804, // bl +8             lr=4 -> target=0x0C ; lr:=5
            0x1C40,         // adds r0, r0, #1   (bx lr lands here)
            0xE7FE,         // b .
            0xBF00, 0xBF00, // padding
            0x1C49,         // adds r1, r1, #1   (0x0C)
            0x4770,         // bx lr            -> pc=4 (stays thumb)
        },
        BaseRegs());
    // Sign-extended prefix (S=1): a bl whose target resolves below the
    // setup pc exercises the negative-offset arm of tblsetup.
    RunThumb(
        {
            0xE006,         // b +12            -> 0x10
            0xBF00,         // nop   (0x02)
            0xBF00,         // nop   (0x04)
            0x1C49,         // adds r1, r1, #1  (0x06: bl target)
            0x4770,         // bx lr            -> lr=0x15 -> pc=0x14
            0xBF00, 0xBF00, 0xBF00, //          (0x0A-0x0E)
            0xF7FF,         // bl prefix S=1, imm10=0x7FF  (0x10)
            0xFFF9,         // bl suffix imm11=0x7F9       (0x12)
            0x1C40,         // adds r0, r0, #1  (0x14)
            0xE7FE,         // b .              (0x16)
        },
        BaseRegs());
}

TEST_CASE("ARM asm executor: chained self-loops", "[arm_asm]") {
    // Backward branches that target the block's own start_pc stay inside
    // the asm executor (op_chain / brachain / fused-chain handlers) instead
    // of exiting to C++ every iteration. Instruction accounting must match
    // the C++ block-boundary check exactly across both engines.
    RunArm(
        {
            0xE3A0000A, // mov r0, #10
            0xE3A01000, // mov r1, #0
            // loop (pc=8):
            0xE2811001, // add  r1, r1, #1
            0xE2500001, // subs r0, r0, #1
            0x1AFFFFFB, // bne  loop          target = block start -> chain
            0xEAFFFFFE, // b .
        },
        BaseRegs());
    RunArm(
        {
            0xE3A00003, // mov r0, #3
            // loop (pc=4):
            0xE2800001, // add r0, r0, #1
            0xE1A01002, // mov r1, r2
            0xEAFFFFFC, // b   loop          unconditional self-loop -> chain
            0xEAFFFFFE, // b .
        },
        BaseRegs(), USER32MODE, 4096);
    // Budget that ends mid-loop: the chained path must stop on the same
    // guest-instruction boundary as the C++ interpreter.
    RunArm(
        {
            0xE3A0000A, // mov r0, #10
            0xE3A01000, // mov r1, #0
            0xE2811001, // add  r1, r1, #1
            0xE2500001, // subs r0, r0, #1
            0x1AFFFFFB, // bne  loop
            0xEAFFFFFE, // b .
        },
        BaseRegs(), USER32MODE, 7);
}

TEST_CASE("ARM asm executor: cross-block chaining", "[arm_asm]") {
    // Two-block ping-pong: A branches forward to B, B loops back to A while
    // r4 != 0, then falls through to a spinning block. Every cross-block
    // transfer reaches the `end` record, which consults the chain table and
    // jumps straight into the target block's record stream instead of
    // returning to the C++ block-cache loop. Both engines must still agree
    // bit-for-bit, and instruction/budget accounting must be unchanged.
    std::array<u32, 15> regs = BaseRegs();
    regs[4] = 3; // three loop iterations
    RunArm(
        {
            0xE3A00000, // 0x00 a: mov  r0, #0
            0xE2811001, // 0x04    add  r1, r1, #1
            0xEA000000, // 0x08    b    0x10            cross-block forward
            0xEAFFFFFE, // 0x0C    b    .               (not reached)
            0xE0222001, // 0x10 b: eor  r2, r2, r1
            0xE1833002, // 0x14    orr  r3, r3, r2
            0xE2544001, // 0x18    subs r4, r4, #1
            0x1AFFFFF7, // 0x1C    bne  0x00            cross-block back-edge
            0xEAFFFFFE, // 0x20    b    .
        },
        regs, USER32MODE, 200);
    // Second pass: more iterations, still ending inside the `b .` spin.
    // The budget must land inside the terminal spin under every engine's
    // tick->instruction accounting, so it is deliberately oversized.
    regs[4] = 7;
    RunArm(
        {
            0xE3A00000, // a: mov  r0, #0
            0xE2811001, //    add  r1, r1, #1
            0xEA000000, //    b    0x10
            0xEAFFFFFE, //    b    .
            0xE0222001, // b: eor  r2, r2, r1
            0xE1833002, //    orr  r3, r3, r2
            0xE2544001, //    subs r4, r4, #1
            0x1AFFFFF7, //    bne  0x00
            0xEAFFFFFE, //    b    .
        },
        regs, USER32MODE, 300);
}

#if defined(__aarch64__)
TEST_CASE("ARM asm executor: cross-block chaining stats", "[arm_asm]") {
    // Prove the chain path actually runs: one asm run should consume many
    // block transitions. Without chaining, each 7-instruction A+B pair
    // would cost one citra_asm_run call each.
    const std::vector<u32> program = {
        0xE3A00000, // a: mov  r0, #0
        0xE2811001, //    add  r1, r1, #1
        0xEA000000, //    b    0x10
        0xEAFFFFFE, //    b    .
        0xE0222001, // b: eor  r2, r2, r1
        0xE1833002, //    orr  r3, r3, r2
        0xE2544001, //    subs r4, r4, #1
        0x1AFFFFF7, //    bne  0x00
        0xEAFFFFFE, //    b    .
    };
    Machine ir_asm(true);
    for (std::size_t i = 0; i < program.size(); ++i) {
        ir_asm.env.SetMemory32(static_cast<VAddr>(i * 4), program[i]);
    }
    std::array<u32, 15> regs = BaseRegs();
    regs[4] = 100;
    ir_asm.Seed(regs);
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
    const auto runs_before = Core::ARMAsm::g_asm_stats.runs.load();
    const auto hits_before = Core::ARMAsm::g_asm_stats.chain_hits.load();
    {
        AsmFlagGuard guard;
        ir_asm.RunInstructions(1000);
    }
    const auto ops = Core::ARMAsm::g_asm_stats.ops_executed.load() - ops_before;
    const auto runs = Core::ARMAsm::g_asm_stats.runs.load() - runs_before;
    const auto hits = Core::ARMAsm::g_asm_stats.chain_hits.load() - hits_before;
    INFO("chained ops=" << ops << " runs=" << runs << " hits=" << hits
                        << " miss=" << Core::ARMAsm::g_asm_stats.chain_misses.load());
    // Each A+B iteration executes 5 ops in assembly (mov/add/jmp + eor/orr;
    // the fused subs+bne exits to C++), so 100 iterations ≈ 500 ops. The
    // bound stays loose — it only proves the loop body ran in asm.
    REQUIRE(ops >= 400);
    REQUIRE(hits >= 50);   // block boundaries were crossed inside asm runs
    REQUIRE(ops > hits);   // sanity: chaining is per-boundary, not per-op
}

TEST_CASE("ARM asm executor: resident register blocks", "[arm_asm]") {
    // Every r0-r2 operand below hits a *_v* handler inside a resident
    // program; the r3+ ops and the fused subs+bne tail stay on the generic
    // handlers because they provably only touch regfile slots >= 3.
    const std::vector<u32> program = {
        0xE3A00000, // mov  r0, #0
        0xE0800001, // loop: add  r0, r0, r1
        0xE0812000, //       add  r2, r1, r0
        0xE2533001, //       subs r3, r3, #1
        0x1AFFFFFB, //       bne  loop
        0xE5850000, // str  r0, [r5]
        0xEAFFFFFE, // b .
    };
    auto regs = BaseRegs();
    regs[3] = 24;
    const auto res_before = Core::ARMAsm::g_asm_stats.resident_programs.load();
    RunArm(program, regs);
    INFO("resident_programs delta="
         << Core::ARMAsm::g_asm_stats.resident_programs.load() - res_before);
    REQUIRE(Core::ARMAsm::g_asm_stats.resident_programs.load() > res_before);
}

TEST_CASE("ARM asm executor: resident slow exit materialization", "[arm_asm]") {
    // Resident ops, then a slow-stub op (swp has no handler), then more
    // resident ops replayed by C++. The slow exit must store r0-r2 back to
    // the regfile so the C++ continuation observes them.
    const std::vector<u32> program = {
        0xE3A00077, // mov  r0, #0x77
        0xE2801002, // add  r1, r0, #2
        0xE1042093, // swp  r2, r3, [r4]   SLOW stub
        0xE0813000, // add  r3, r1, r0     reads resident r0/r1 via C++
        0xE5843000, // str  r3, [r4]
        0xEAFFFFFE, // b .
    };
    auto regs = BaseRegs();
    regs[4] = 0x1400;
    RunArm(program, regs);
}

TEST_CASE("ARM asm executor: resident operand aliasing", "[arm_asm]") {
    // rd == rn == rm on resident regs plus every resident/regfile operand
    // mix -- the *_v* handlers must read and write the right copy.
    const std::vector<u32> program = {
        0xE3A00005, // mov  r0, #5
        0xE0800000, // add  r0, r0, r0        res rd/rn/rm
        0xE1A01000, // mov  r1, r0           res dst, res src
        0xE0020000, // and  r0, r2, r0       res rd, mem rn, res rm
        0xE0210002, // eor  r0, r1, r2       all resident
        0xE2522003, // subs r2, r0, #3       res rd/rn + flag set
        0xE1500001, // cmp  r0, r1           resident compare
        0xE0850000, // add  r0, r5, r0       res rd, mem rn, res rm
        0xE3A02000, // mov  r2, #0
        0xE5943000, // ldr  r3, [r4]         mem dst variant-free
        0xE1A00003, // mov  r0, r3           res dst, mem src
        0xE5840004, // str  r0, [r4, #4]     res value, mem base
        0xE5942004, // ldr  r2, [r4, #4]     res dst, mem base
        0xEAFFFFFE, // b .
    };
    auto regs = BaseRegs();
    regs[2] = 0xFF;
    regs[4] = 0x1400;
    RunArm(program, regs);
}

TEST_CASE("ARM asm executor: resident to non-resident transition", "[arm_asm]") {
    // Block A is resident and branches to block B, which uses r0 as a mul
    // operand -- a family without *_v* handlers -- so B is non-resident.
    // The chain probe must refuse the resmask change and exit through END;
    // B then observes the correct regfile values.
    const std::vector<u32> program = {
        0xE3A00040, // A: mov  r0, #0x40
        0xEA000001, //    b    B
        0xEAFFFFFE, //    b .
        0xE0040391, // B: mul  r4, r1, r3    rm=1 <3 -> block non-resident
        0xE0855000, //    add  r5, r5, r0    reads r0 materialized at exit
        0xEAFFFFFE, //    b .
    };
    auto regs = BaseRegs();
    regs[1] = 3;
    regs[3] = 7;
    RunArm(program, regs);
}
#endif

TEST_CASE("ARM asm executor: Thumb 32-bit BL mixed sizes", "[arm_asm]") {
    // BL is the only 32-bit Thumb instruction on ARMv6K; it must advance
    // pc by 2 per halfword through the per-op guest_size field, update lr
    // and land on the right target. 16-bit ops surround it to exercise
    // mixed instruction sizes within one block sequence.
    const std::vector<u16> program = {
        0x2001,       // movs r0, #1
        0xF000, 0xF802, // bl +8 -> target 0xA, lr = 7
        0x2207,       // movs r2, #7        (skipped by the bl)
        0x2109,       // movs r1, #9        (skipped)
        0x4288,       // cmp r0, r1         1 vs seeded r1
        0xD001,       // beq +2             (not taken)
        0x2209,       // movs r2, #9
        0xE7FE,       // b .
    };
    RunThumb(program, BaseRegs());
}

#if defined(__aarch64__)
extern "C" void citra_asm_op_slow();
extern "C" void citra_asm_op_end();
#endif

TEST_CASE("ARM asm executor: Thumb BL prefix coverage", "[arm_asm]") {
    const std::vector<u16> full = {
        0x2001,              // movs r0, #1
        0xF000, 0xF802,      // bl +8
        0x2207,              // movs r2, #7
        0x2109,              // movs r1, #9
        0x4288,              // cmp r0, r1
        0xD001,              // beq +2
        0x2209,              // movs r2, #9
    };
    for (std::size_t len = 1; len <= full.size(); ++len) {
        std::vector<u16> program(full.begin(), full.begin() + len);
        program.push_back(0xE7FE); // b .
        CAPTURE(len);
        RunThumb(program, BaseRegs());
    }
}

TEST_CASE("ARM asm executor: randomized multi-instruction sequences", "[arm_asm]") {
    // Random ARM data-processing + load/store streams. The generator only
    // emits encodings the IR translator understands (cond=AL or a real
    // condition, valid opcode nibbles).
    std::mt19937 rng(0x41534D21U);
    for (u32 iter = 0; iter < 96; ++iter) {
        const u32 len = 4 + rng() % 20;
        std::vector<u32> program;
        for (u32 i = 0; i < len; ++i) {
            const u32 kind = rng() % 4;
            // rd must stay out of r1/r2: they seed the load/store bases
            // (0x1000/0x1004) and a polluted base can synthesize a
            // bit31-set address, which azahar's LUMA/MMIO alias path
            // asserts on for sub-word accesses.
            const u32 rn = rng() % 13, rd = 3 + rng() % 10, rm = rng() % 13;
            // Opcodes 8-11 are TST/TEQ/CMP/CMN which require S=1; with S=0
            // the same encodings mean MRS/MSR/misc space where the engines
            // legitimately diverge. Restrict to pure ALU opcodes.
            const u32 opc = (rng() % 4 == 0) ? 12 + rng() % 4 : rng() % 8;
            u32 insn;
            switch (kind) {
            case 0: // data processing immediate
                insn = 0xE0000000 | (opc << 21) | ((rng() & 1) << 20) | (rn << 16) |
                       (rd << 12) | (1U << 25) | (rng() & 0xFFF);
                break;
            case 1: // data processing register (shift imm only; bit4 must be 0
                    // or the encoding enters the reg-shift / extra-load-store
                    // space where the engines legitimately diverge)
                insn = 0xE0000000 | (opc << 21) | ((rng() & 1) << 20) | (rn << 16) |
                       (rd << 12) | (rng() & 0xF0F) | rm;
                break;
            case 2: // load/store immediate word, positive offset
                insn = 0xE4000000 | (1U << 24) | (1U << 23) | ((rng() & 1) << 20) |
                       (0x1 << 16) | (rd << 12) | (rng() & 0x7F);
                break;
            default: // load/store immediate byte, positive offset
                insn = 0xE4000000 | (1U << 22) | (1U << 24) | (1U << 23) |
                       ((rng() & 1) << 20) | (0x2 << 16) | (rd << 12) | (rng() & 0xFF);
                break;
            }
            program.push_back(insn);
        }
        program.push_back(0xEAFFFFFE); // b .
        CAPTURE(iter);
        {
            std::string dump;
            for (const u32 w : program) {
                dump += fmt::format("{:#x} ", w);
            }
            INFO("program: " + dump);
        }
        RunArm(program, BaseRegs());
    }
}

TEST_CASE("ARM asm executor: guarded conditional data processing", "[arm_asm]") {
    // cond != AL generic ArmDataProcessing{Register,Immediate}: guard record +
    // body. cmp r7,r8 (0x80000000 vs 0x7FFFFFFF) leaves N=0 Z=0 C=1 V=1, so
    // eq/mi/lo/ge fail while ne/lt/hi/pl pass. Exercises guard pass and skip,
    // shifted-reg bodies, flag-setting bodies and instruction counting.
    const std::vector<u32> program = {
        0xE1570008, // cmp r7, r8
        0x00840005, // addeq r0, r4, r5     (skip)
        0x10451006, // subne r1, r5, r6     (exec)
        0xB3A02099, // movlt r2, #0x99      (exec)
        0x41843005, // orrmi r3, r4, r5     (skip)
        0xA0239205, // eorge r9, r3, r5, lsl #4 (skip)
        0x31C4A006, // biccc r10, r4, r6    (skip)
        0x81E0B006, // mvnhi r11, r6        (exec)
        0x5094C007, // addspl r12, r4, r7   (exec, writes flags)
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());
    // Second seed flips the condition outcomes: everything inverts.
    auto regs = BaseRegs();
    regs[7] = 0x7FFFFFFF;
    regs[8] = 0x80000000;
    RunArm(program, regs);
}

TEST_CASE("ARM asm executor: guarded conditional multiplies", "[arm_asm]") {
    // cmp leaves C=1 Z=0: eq/lo skip, ne/hs execute.
    const std::vector<u32> program = {
        0xE1570008, // cmp r7, r8
        0x00000291, // muleq r0, r1, r2          (skip)
        0x10236594, // mlane r3, r4, r5, r6     (exec)
        0x20898291, // umullcs r8, r9, r1, r2   (exec)
        0x30EBA291, // smlalcc r10, r11, r1, r2 (skip)
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());
}

TEST_CASE("ARM asm executor: guarded conditional set-flags ops", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before = Core::ARMAsm::g_asm_stats
                                 .slow_op_counts[static_cast<size_t>(
                                     Core::ARMIR::Opcode::ArmDataProcessingRegister)]
                                 .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // cmp r7,r8 (0x80000000 vs 0x7FFFFFFF): N=0 Z=0 C=1 V=1, so
    // eq/cc/mi/vc/ls/ge/gt skip while ne/cs/pl/vs/hi/lt/le execute.
    // Everything below was a slow exit before: conditional set-flags
    // logical ops (-> logreg_s), shifted set-flags logical and
    // carry-arithmetic ops (-> logsh_s/carithsh_s/movs_shift) and
    // shifted compares (-> cmp_shift/cmn_shift).
    const std::vector<u32> program = {
        0xE1570008, // cmp r7, r8
        // Unshifted set-flags register forms.
        0x00143005, // andeqs r3, r4, r5          (skip)
        0x10376008, // eornes r6, r7, r8          (exec)
        0x519A900B, // orrpls r9, r10, r11       (exec)
        0x31DDC00E, // bicccs r12, r13, r14      (skip)
        0xA1B03004, // movsges r3, r4            (skip)
        0xB1F05006, // mvnlts r5, r6             (exec)
        0x81140005, // tsthi r4, r5              (exec)
        0x91360007, // teqls r6, r7              (skip)
        0xA0B43005, // adcvcs r3, r4, r5         (skip)
        0x20D76008, // sbcccs r6, r7, r8         (exec)
        0x80743005, // rsbhis r3, r4, r5         (exec)
        0x90F76008, // rscls r6, r7, r8          (skip)
        0x90543005, // subsls r3, r4, r5         (skip)
        0xA0976008, // addsges r6, r7, r8        (skip)
        0x91540005, // cmpls r4, r5              (skip)
        0x21760007, // cmncs r6, r7              (exec)
        // Shifted set-flags forms (logsh_s / movs_shift / carithsh_s /
        // cmp_shift / cmn_shift bodies behind a guard record).
        0x00143185, // andeqs r3, r4, r5, lsl #3 (skip)
        0x10376128, // eornes r6, r7, r8, lsr #2 (exec)
        0xA19A92EB, // orrges r9, r10, r11, ror #5 (skip)
        0xA1B03104, // movsges r3, r4, lsl #2    (skip)
        0xB1F051C6, // mvnlts r5, r6, asr #3     (exec)
        0x00B43085, // adceqs r3, r4, r5, lsl #1 (skip)
        0x20D762A8, // sbccs r6, r7, r8, lsr #5  (exec)
        0x809430C5, // addshis r3, r4, r5, asr #1 (exec)
        0x90743365, // rsbls r3, r4, r5, ror #6  (skip)
        0x40543325, // subsmis r3, r4, r5, lsr #6 (skip)
        0xA09762E8, // addsges r6, r7, r8, ror #5 (skip)
        0x91540265, // cmpls r4, r5, ror #4      (skip)
        0x217601C7, // cmncs r6, r7, asr #3      (exec)
        // shift_imm == 0 special forms: lsr/asr mean #32, ror means rrx.
        0x20376028, // eorcs r6, r7, r8, lsr #0 -> lsr #32 (exec)
        0x10143065, // andnes r3, r4, r5, ror #0 -> rrx    (exec)
        0x60543045, // subsvs r3, r4, r5, asr #0 -> asr #32 (exec)
        0x21540025, // cmphs r4, r5, lsr #0 -> lsr #32     (exec)
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());
    // Second seed flips every condition outcome.
    auto regs = BaseRegs();
    regs[7] = 0x7FFFFFFF;
    regs[8] = 0x80000000;
    RunArm(program, regs);
#if defined(__aarch64__)
    // The block must actually have run through asm, and none of the ops
    // above may still slow-exit.
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    INFO(fmt::format("slow op9 delta={}", Core::ARMAsm::g_asm_stats
                                             .slow_op_counts[static_cast<size_t>(
                                                 Core::ARMIR::Opcode::
                                                     ArmDataProcessingRegister)]
                                             .load() -
                                         slow_before));
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmDataProcessingRegister)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: shifted/compare ops join resident programs", "[arm_asm]") {
#if defined(__aarch64__)
    const auto res_before = Core::ARMAsm::g_asm_stats.resident_programs.load();
#endif
    // mov_lsl / add_shift_lsr / logsh_s_lsl / cmp_shift all read and write
    // only operand fields >= r3 here, so the whole block may run resident
    // with r0 held in a host register.
    const std::vector<u32> program = {
        0xE3A00005, // mov  r0, #5
        0xE1A03104, // mov  r3, r4, lsl #2
        0xE08650A7, // add  r5, r6, r7, lsr #1
        0xE019810A, // ands r8, r9, r10, lsl #2
        0xE15401C5, // cmp  r4, r5, asr #3
        0xE0800003, // add  r0, r0, r3
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.resident_programs.load() > res_before);
#endif
}

TEST_CASE("ARM asm executor: bl/bx/blx call and return", "[arm_asm]") {
    // bl -> func -> bx lr -> fallthrough -> spin. Exercises the link write,
    // register-indirect return, and the end-of-block chain/exit paths.
    const std::vector<u32> call = {
        0xEB000002, // bl 0x10
        0xE1A00006, // mov r0, r6
        0xE0801007, // add r1, r0, r7
        0xEAFFFFFE, // b .
        0xE0832004, // func: add r2, r3, r4   @0x10
        0xE12FFF1E, // bx lr                 @0x14
    };
    RunArm(call, BaseRegs());

    // blx r9 with r9 = 0x20 (ARM state target).
    const std::vector<u32> blx = {
        0xE12FFF39, // blx r9
        0xE1A00006, // mov r0, r6
        0xEAFFFFFE, // b .
        0xE320F000, // nop                    @0x0C..0x1C padding
        0xE320F000,
        0xE320F000,
        0xE320F000,
        0xE320F000,
        0xE3A05007, // mov r5, #7            @0x20
        0xE12FFF1E, // bx lr
    };
    auto regs = BaseRegs();
    regs[9] = 0x20;
    RunArm(blx, regs);
}

TEST_CASE("ARM asm executor: conditional bx taken/skipped", "[arm_asm]") {
    // bxeq/bxne behind a cmp: only one form returns; the other falls through.
    // cmp r7,r8 -> N=0 Z=0 C=1 V=1: bxne (cond 1) is taken, bxeq is not.
    const std::vector<u32> taken = {
        0xE1570008, // cmp r7, r8
        0x112FFF1E, // bxne lr    -> jump to r14
        0xE3A05001, // mov r5, #1 (unreached)
        0xEAFFFFFE, // b .
    };
    auto regs = BaseRegs();
    regs[14] = 0x0C; // lr -> the trailing b .
    RunArm(taken, regs);

    const std::vector<u32> skipped = {
        0xE1570008, // cmp r7, r8
        0x012FFF1E, // bxeq lr    -> condition fails, falls through
        0xE3A05002, // mov r5, #2
        0xEAFFFFFE, // b .
    };
    RunArm(skipped, regs);
}

TEST_CASE("ARM asm executor: literal pool loads and generic ldr/str", "[arm_asm]") {
    // rn==15 word loads use (pc & ~3) + 8 as the base; both loads hit the
    // instruction word at 0x10 (= 0xE3A05055). Also covers conditional
    // stm/ldm through the generic LoadStoreImmediate/LoadStoreMultiple ops.
    const std::vector<u32> program = {
        0xE59F0008, // ldr r0, [pc, #8]   -> [0x10]
        0xE59F1004, // ldr r1, [pc, #4]   -> [0x10]
        0xE3100001, // tst r0, #1         -> Z=0
        0x0A000001, // beq 0x18           (not taken)
        0xE3A05055, // mov r5, #0x55
        0xEA000000, // b 0x1C
        0xE3A05066, // mov r5, #0x66      (skipped)
        0xE1570008, // cmp r7, r8         -> N=0 Z=0 C=1 V=1
        0xA88D0003, // stmge sp, {r0, r1} (ge fails: skip)
        0xD91D000C, // ldmdble sp, {r2, r3} (le passes)
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());
}

TEST_CASE("ARM asm executor: ldm {...pc} epilogue chaining", "[arm_asm]") {
    // Store a code address then load it into pc: the asm ldm tail chains
    // straight into the target block like a return.
    const std::vector<u32> program = {
        0xE3A00011, // mov r0, #0x11
        0xE3A04022, // mov r4, #0x22
        0xE3A05034, // mov r5, #0x34
        0xE88D0031, // stm sp, {r0, r4, r5} -> [1800]=11 [1804]=22 [1808]=34
        0xE89D80C0, // ldm sp, {r6, r7, pc} -> r6=0x11 r7=0x22 pc=0x34
        0xE1A08008, // mov r8, r8  (filler, skipped)
        0xE1A08008, 0xE1A08008, 0xE1A08008,
        0xE1A08008, 0xE1A08008, 0xE1A08008,
        0xE1A08008, 0xE1A08008,
        0xE0868007, // add r8, r6, r7      @0x34
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());

    // Writeback form: stmdb sp!, {r4, r5} / ldmia sp!, {r6, pc}.
    const std::vector<u32> popret = {
        0xE3A05014, // mov r5, #0x14
        0xE3A04077, // mov r4, #0x77
        0xE92D0030, // stmdb sp!, {r4, r5}
        0xE8BD8040, // ldmia sp!, {r6, pc} -> r6=0x77, pc=0x14
        0xE1A08008, // mov r8, r8          (skipped)
        0xE2867001, // add r7, r6, #1      @0x14
        0xEAFFFFFE, // b .
    };
    RunArm(popret, BaseRegs());
}

TEST_CASE("ARM asm executor: fused test+branch flag semantics", "[arm_asm]") {
    // teq + bne fused op: r1 != r2 so the branch is taken; the compare must
    // also update only N/Z (C preserved from the preceding subs).
    const std::vector<u32> program = {
        0xE2544001, // subs r4, r4, #1   (borrow rules C; r4=0xFFFF0000 -> C=1)
        0xE1310002, // teq r1, r2
        0x1A000001, // bne 0x14          (taken)
        0xE3A05011, // mov r5, #0x11     (skipped)
        0xEA000000, // b 0x18
        0xE3A05022, // mov r5, #0x22     @0x14
        0xEAFFFFFE, // b .               @0x18
    };
    RunArm(program, BaseRegs());
    // Equal operands -> not taken, falls through to mov r5, #0x11.
    auto regs = BaseRegs();
    regs[2] = regs[1];
    RunArm(program, regs);
}

TEST_CASE("ARM asm executor: fused test+branch not-taken advances pc", "[arm_asm]") {
    // Regression for a missing fused-size argument: the not-taken tst+b path
    // advanced pc by zero, so the run re-entered the same fused record until
    // the budget drained -- both guest instructions were counted without
    // executing, and the loop counter lags far behind the other engines.
    const std::vector<u32> program = {
        0xE3A00C01, // mov r0, #0x100
        0xE3100080, // loop: tst r0, #0x80      (Z=0)
        0x0A000001, //       beq 0x14           (not taken)
        0xE2811001, //       add r1, r1, #1
        0xEAFFFFFB, //       b 0x04
        0xEAFFFFFE, // exit: b .
    };
    RunArm(program, BaseRegs(), USER32MODE, 200);
}

TEST_CASE("ARM asm executor: ldm {...pc} to a Thumb target", "[arm_asm]") {
    // Regression: the asm handler checked the loaded pc's Thumb bit AFTER
    // writeback and register loads; the MEMSLOW replay then re-executed the
    // LDM against the already-written state -- rn advanced twice and the
    // register list reloaded from a shifted base. The check now runs before
    // any guest-state mutation so C++ performs the mode switch cleanly.
    const std::vector<u32> program = {
        0xE8B18030, // ldmia r1!, {r4, r5, pc}  <- [1000]=r4 [1004]=r5 [1008]=pc
        0xEAFFFFFE, // b .                      (dead filler)
    };
    Machine dyn(false), ir(true), ir_asm(true);
    for (std::size_t i = 0; i < program.size(); ++i) {
        const VAddr a = static_cast<VAddr>(i * 4);
        dyn.env.SetMemory32(a, program[i]);
        ir.env.SetMemory32(a, program[i]);
        ir_asm.env.SetMemory32(a, program[i]);
    }
    for (Machine* m : {&dyn, &ir, &ir_asm}) {
        m->env.SetMemory32(0x1000, 0xAABB0004);
        m->env.SetMemory32(0x1004, 0xAABB0005);
        m->env.SetMemory32(0x1008, 0x41); // odd -> Thumb code at 0x40
        m->env.SetMemory16(0x40, 0x2609); // movs r6, #9
        m->env.SetMemory16(0x42, 0xE7FE); // b .
    }
    auto regs = BaseRegs(); // r1 = 0x1000
    dyn.Seed(regs);
    ir.Seed(regs);
    ir_asm.Seed(regs);
    dyn.RunInstructions(16);
    ir.RunInstructions(16);
    {
        AsmFlagGuard guard;
        ir_asm.RunInstructions(16);
    }
    Compare(ir, dyn);
    Compare(ir_asm, dyn);
}

TEST_CASE("ARM asm executor: Thumb pop {pc} stays in Thumb", "[arm_asm]") {
    // pop {r4, pc} with a Thumb target: same-mode so the handler may run the
    // load and chain; the C++/DynCom states must still match bit-for-bit.
    const u16 pgm[] = {0xBD10, 0xE7FE}; // pop {r4, pc}; b .
    Machine dyn(false), ir(true), ir_asm(true);
    for (std::size_t i = 0; i < 2; ++i) {
        const VAddr a = static_cast<VAddr>(i * 2);
        dyn.env.SetMemory16(a, pgm[i]);
        ir.env.SetMemory16(a, pgm[i]);
        ir_asm.env.SetMemory16(a, pgm[i]);
    }
    for (Machine* m : {&dyn, &ir, &ir_asm}) {
        m->env.SetMemory32(0x1000, 0x13572468); // popped r4
        m->env.SetMemory32(0x1004, 0x41);       // odd -> Thumb at 0x40
        m->env.SetMemory16(0x40, 0x2609);       // movs r6, #9
        m->env.SetMemory16(0x42, 0xE7FE);       // b .
    }
    auto regs = BaseRegs();
    regs[13] = 0x1000; // sp
    dyn.Seed(regs, USER32MODE | TBIT);
    ir.Seed(regs, USER32MODE | TBIT);
    ir_asm.Seed(regs, USER32MODE | TBIT);
    dyn.RunInstructions(16);
    ir.RunInstructions(16);
    {
        AsmFlagGuard guard;
        ir_asm.RunInstructions(16);
    }
    Compare(ir, dyn);
    Compare(ir_asm, dyn);
}

TEST_CASE("ARM asm executor: Thumb bx/blx to ARM mode switch", "[arm_asm]") {
    // Thumb bx r0 to an even (ARM) target flips TFlag; the asm handler must
    // bail cleanly so C++ performs the switch instead of chaining in Thumb.
    const u16 pgm[] = {0x4700, 0xE7FE}; // bx r0; b .
    Machine dyn(false), ir(true), ir_asm(true);
    for (std::size_t i = 0; i < 2; ++i) {
        const VAddr a = static_cast<VAddr>(i * 2);
        dyn.env.SetMemory16(a, pgm[i]);
        ir.env.SetMemory16(a, pgm[i]);
        ir_asm.env.SetMemory16(a, pgm[i]);
    }
    for (Machine* m : {&dyn, &ir, &ir_asm}) {
        m->env.SetMemory32(0x40, 0xE3A05055); // mov r5, #0x55
        m->env.SetMemory32(0x44, 0xEAFFFFFE); // b .
    }
    auto regs = BaseRegs();
    regs[0] = 0x40; // even -> ARM target
    dyn.Seed(regs, USER32MODE | TBIT);
    ir.Seed(regs, USER32MODE | TBIT);
    ir_asm.Seed(regs, USER32MODE | TBIT);
    dyn.RunInstructions(16);
    ir.RunInstructions(16);
    {
        AsmFlagGuard guard;
        ir_asm.RunInstructions(16);
    }
    Compare(ir, dyn);
    Compare(ir_asm, dyn);

    // Thumb blx r2 -> ARM function that returns via bx lr (lr has bit0 set,
    // so the return re-enters Thumb and continues past the call).
    const u16 pgm2[] = {0x4790, 0x2633, 0xE7FE}; // blx r2; movs r6,#0x33; b .
    Machine dyn2(false), ir2(true), ir_asm2(true);
    for (std::size_t i = 0; i < 3; ++i) {
        const VAddr a = static_cast<VAddr>(i * 2);
        dyn2.env.SetMemory16(a, pgm2[i]);
        ir2.env.SetMemory16(a, pgm2[i]);
        ir_asm2.env.SetMemory16(a, pgm2[i]);
    }
    for (Machine* m : {&dyn2, &ir2, &ir_asm2}) {
        m->env.SetMemory32(0x40, 0xE12FFF1E); // bx lr -> back to Thumb
    }
    auto regs2 = BaseRegs();
    regs2[2] = 0x40; // even -> ARM target
    dyn2.Seed(regs2, USER32MODE | TBIT);
    ir2.Seed(regs2, USER32MODE | TBIT);
    ir_asm2.Seed(regs2, USER32MODE | TBIT);
    dyn2.RunInstructions(24);
    ir2.RunInstructions(24);
    {
        AsmFlagGuard guard;
        ir_asm2.RunInstructions(24);
    }
    Compare(ir2, dyn2);
    Compare(ir_asm2, dyn2);
}

TEST_CASE("ARM asm executor: ARM blx #imm to Thumb round trip", "[arm_asm]") {
    // blx #imm is the interworking veneer a game hits on every ARM->Thumb
    // library call: it must run in assembly now (writes TFlag = 1 itself)
    // instead of truncating the run with a slow exit. The Thumb callee
    // returns through bx lr -> ARM (lr = 4 is even), which exercises the
    // mode-switching bx path in the same direction-counting sense.
    std::vector<u32> program(17, 0xE320F000); // nop padding
    program[0] = 0xFA00000E;                  // blx 0x40 -> Thumb, lr = 4
    program[1] = 0xE3A000AA;                  // mov r0, #0xAA  (after return)
    program[2] = 0xEAFFFFFE;                  // b .
    program[16] = 0x47702555;                 // @0x40: movs r5,#0x55 ; bx lr

    Machine dyn(false), ir(true), ir_asm(true);
    for (std::size_t i = 0; i < program.size(); ++i) {
        const VAddr a = static_cast<VAddr>(i * 4);
        dyn.env.SetMemory32(a, program[i]);
        ir.env.SetMemory32(a, program[i]);
        ir_asm.env.SetMemory32(a, program[i]);
    }
    dyn.Seed(BaseRegs());
    ir.Seed(BaseRegs());
    ir_asm.Seed(BaseRegs());
#if defined(__aarch64__)
    const auto slow_before = Core::ARMAsm::g_asm_stats.slow_exits.load();
#endif
    dyn.RunInstructions(24);
    ir.RunInstructions(24);
    {
        AsmFlagGuard guard;
        ir_asm.RunInstructions(24);
    }
    Compare(ir, dyn);
    Compare(ir_asm, dyn);
    // The whole round trip (blx imm -> Thumb movs -> bx lr -> ARM) executes
    // in assembly; a slow exit here would mean the mode-switch coverage
    // regressed to the C++ path.
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.slow_exits.load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: Thumb blx #imm to ARM round trip", "[arm_asm]") {
    // Thumb blx immediate (setup 0xF001 / suffix 0xE800): LR =
    // pc+4+(1<<12) = 0x1004, target = LR & ~3 = 0x1004, LR' = 5, TFlag = 0.
    // The ARM callee returns via bx lr -> Thumb (lr = 5 is odd), which the
    // bx handler now owns in assembly as well.
    const u16 pgm[] = {0xF001, 0xE800, 0x2633, 0xE7FE};
    Machine dyn(false), ir(true), ir_asm(true);
    for (std::size_t i = 0; i < 4; ++i) {
        const VAddr a = static_cast<VAddr>(i * 2);
        dyn.env.SetMemory16(a, pgm[i]);
        ir.env.SetMemory16(a, pgm[i]);
        ir_asm.env.SetMemory16(a, pgm[i]);
    }
    for (Machine* m : {&dyn, &ir, &ir_asm}) {
        m->env.SetMemory32(0x1004, 0xE3A05077); // mov r5, #0x77
        m->env.SetMemory32(0x1008, 0xE12FFF1E); // bx lr -> Thumb pc 4
    }
    dyn.Seed(BaseRegs(), USER32MODE | TBIT);
    ir.Seed(BaseRegs(), USER32MODE | TBIT);
    ir_asm.Seed(BaseRegs(), USER32MODE | TBIT);
#if defined(__aarch64__)
    const auto slow_before = Core::ARMAsm::g_asm_stats.slow_exits.load();
#endif
    dyn.RunInstructions(24);
    ir.RunInstructions(24);
    {
        AsmFlagGuard guard;
        ir_asm.RunInstructions(24);
    }
    Compare(ir, dyn);
    Compare(ir_asm, dyn);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.slow_exits.load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: ARM blx rm to Thumb round trip", "[arm_asm]") {
    // Register-form mode switch: blx r9 with an odd target enters Thumb
    // in assembly now; the callee returns via bx lr (even -> ARM).
    const std::vector<u32> program = {
        0xE12FFF39, // blx r9 -> Thumb @0x40, lr = 4
        0xE3A000AA, // mov r0, #0xAA   (after return)
        0xEAFFFFFE, // b .
        0xE320F000, 0xE320F000, 0xE320F000, 0xE320F000,
        0xE320F000, 0xE320F000, 0xE320F000, 0xE320F000,
        0xE320F000, 0xE320F000, 0xE320F000, 0xE320F000,
        0xE320F000, // pad to 0x40
        0x47702555, // @0x40: movs r5,#0x55 ; bx lr
    };
    auto regs = BaseRegs();
    regs[9] = 0x41; // odd -> Thumb
#if defined(__aarch64__)
    const auto slow_before = Core::ARMAsm::g_asm_stats.slow_exits.load();
#endif
    RunArm(program, regs);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.slow_exits.load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: chained self-loop preserves guest flags", "[arm_asm]") {
    // Regression for the chain-budget-check clobbering host NZCV: rrx at the
    // top of the loop reads guest C written by subs at the bottom; a
    // flag-clobbering budget check between iterations corrupts r0.
    const std::vector<u32> program = {
        0xE1A00060, // loop: mov r0, r0, rrx
        0xE2511001, //       subs r1, r1, #1
        0x1AFFFFFC, //       bne loop
        0xEAFFFFFE, // b .
    };
    auto regs = BaseRegs();
    regs[1] = 9;
    RunArm(program, regs, USER32MODE, 64);
}

TEST_CASE("ARM asm executor: conditional-skip distance with guarded ops", "[arm_asm]") {
    // Regression: the skip record's record-stream distance used to be
    // derived as run_length * sizeof(AsmOp), assuming one record per op.
    // Ops that stay conditional inside a skip span (non-convertible opcodes
    // or ops following a flag-writing op) now emit guard+body pairs, so the
    // distance must be patched against the real record layout. A short
    // distance lands mid-span and either skips an op (pc/count corruption)
    // or executes a body record unconditionally.

    // Skip lands on the strne BODY: the store must not run (cond fails) and
    // pc must not gain an extra +4 from the body's NEXT_A.
    const std::vector<u32> pgm = {
        0xE3A00000, // mov r0, #0
        0xE3500000, // cmp r0, #0        ; Z=1, NE fails -> skip taken
        0x12811001, // addne r1, r1, #1  ; run start (converted, 1 rec)
        0x12922002, // addnes r2, r2, #2 ; flag write (converted, 1 rec)
        0x15814000, // strne r4, [r1]    ; non-convertible -> guard+body
        0xE3A04009, // mov r4, #9        ; landing
        0xEAFFFFFE, // b .
    };
    RunArm(pgm, BaseRegs());

    // Skip lands on a GUARD record mid-span: re-evaluating the condition is
    // harmless for regs but double-counts the op's pc/instruction budget.
    const std::vector<u32> pgm2 = {
        0xE3A00000, // mov r0, #0
        0xE3500000, // cmp r0, #0
        0x12811001, // addne r1, r1, #1
        0x12922002, // addnes r2, r2, #2
        0x12833004, // addne r3, r3, #4  ; after flag write -> guard+body
        0x15814000, // strne r4, [r1]    ; -> guard+body
        0xE3A04009, // mov r4, #9
        0xEAFFFFFE, // b .
    };
    RunArm(pgm2, BaseRegs());

    // Same span with the condition passing (r0=1, NE true): every op,
    // converted or still conditional, must execute exactly once.
    auto regs = BaseRegs();
    regs[0] = 1;
    RunArm(pgm2, regs);
}

TEST_CASE("ARM asm executor: pc read after conditional-skip run", "[arm_asm]") {
    // Regression: pc-relative constants were folded at translate time using
    // the block.ops index i, but ConditionalSkip meta records carry
    // guest_size==0 and occupy an ops slot without an instruction. A
    // `mov rX, pc` / `add rX, pc, #imm` after a condskip run therefore read
    // pc 4 bytes too high per inserted record (MK7 boot hang: r1 held a pc
    // that was +4 and the wait loop never converged).
#if defined(__aarch64__)
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    const std::vector<u32> pgm = {
        0xE3500005, // cmp r0, #5
        0x03A03000, // moveq r3, #0      - condskip run of 2 (EQ)
        0x03A04000, // moveq r4, #0
        0xE1A0100F, // mov r1, pc        ; must read 0x0c+8 = 0x14
        0xE28F2004, // add r2, pc, #4    ; must read (0x10+8)+4 = 0x1c
        0x13A05000, // movne r5, #0      - condskip run of 2 (NE)
        0x13A06000, // movne r6, #0
        0xE1A0700F, // mov r7, pc        ; must read 0x1c+8 = 0x24
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> eq = BaseRegs();
    eq[0] = 5; // Z=1: EQ ops execute, NE ops skip
    RunArm(pgm, eq);
    RunArm(pgm, BaseRegs()); // Z=0: inverse polarity
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
#endif
}

// ---------------------------------------------------------------------------
// Benchmarks (real-device evidence for the refactor decision, doc §8.3)
// ---------------------------------------------------------------------------

// Best-of-`rounds` wall-clock seconds to execute `budget` guest instructions.
// A small warm-up slice runs first so block translation and page-table
// resolution are paid once outside the timed window.
double TimeRunSeconds(Machine& m, u64 budget, int rounds = 3) {
    m.RunInstructions(4096); // warm-up: translate blocks, prime caches
    double best = std::numeric_limits<double>::max();
    for (int i = 0; i < rounds; ++i) {
        const auto t0 = std::chrono::steady_clock::now();
        m.RunInstructions(budget);
        const auto t1 = std::chrono::steady_clock::now();
        best = std::min(best, std::chrono::duration<double>(t1 - t0).count());
    }
    return best;
}

// Times the same looping ARM program on DynCom, pure C++ IR and IR+ASM and
// prints a comparison table. Correctness for these same op shapes is already
// asserted by the differential tests above; here we only measure speed.
// The `fast` field reports how many guest instructions the asm executor
// actually consumed — proof the fast path ran rather than silently degrading.
void BenchArm(const char* label, const std::vector<u32>& program, u64 budget) {
    Machine dyn(false), ir(true), ir_asm(true);
    for (std::size_t i = 0; i < program.size(); ++i) {
        const VAddr a = static_cast<VAddr>(i * 4);
        dyn.env.SetMemory32(a, program[i]);
        ir.env.SetMemory32(a, program[i]);
        ir_asm.env.SetMemory32(a, program[i]);
    }
    const auto regs = BaseRegs();
    dyn.Seed(regs);
    ir.Seed(regs);
    ir_asm.Seed(regs);

    const double t_dyn = TimeRunSeconds(dyn, budget);
    // Force the flag off explicitly: if any earlier scope leaked it, `ir`
    // would silently take the asm path and invalidate the comparison.
    Settings::values.use_cpu_asm_interpreter.SetValue(false);
#if defined(__aarch64__)
    const auto ir_stat_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
    const double t_ir = TimeRunSeconds(ir, budget);
    const auto ir_stat_used = Core::ARMAsm::g_asm_stats.ops_executed.load() - ir_stat_before;
#else
    const double t_ir = TimeRunSeconds(ir, budget);
    const u64 ir_stat_used = 0;
#endif
    double t_asm;
    u64 fast_ops = 0;
    {
        AsmFlagGuard guard;
#if defined(__aarch64__)
        const auto before = Core::ARMAsm::g_asm_stats.ops_executed.load();
        t_asm = TimeRunSeconds(ir_asm, budget);
        fast_ops = Core::ARMAsm::g_asm_stats.ops_executed.load() - before;
#else
        t_asm = TimeRunSeconds(ir_asm, budget);
#endif
    }

    const double mips = static_cast<double>(budget) / 1e6;
    Catch::cout() << fmt::format(
        "[bench] {} budget={}M | dyncom {:.3f}s ({:.2f} MIPS) | ir {:.3f}s ({:.2f} "
        "MIPS) | ir+asm {:.3f}s ({:.2f} MIPS, fast={}) | speedup asm/ir {:.2f}x asm/dyn "
        "{:.2f}x\n",
        label, mips, t_dyn, mips / t_dyn, t_ir, mips / t_ir, t_asm, mips / t_asm,
        fast_ops, t_ir / t_asm, t_dyn / t_asm);
    // r0/pc after the run proves each engine executed real iterations
    // (loop counters differ legitimately if engines stop mid-block).
    Catch::cout() << fmt::format("[bench] {} r0: dyn={:#x} ir={:#x} asm={:#x} | pc: "
                                 "dyn={:#x} ir={:#x} asm={:#x} | ir_asm_ops={}\n",
                                 label, dyn.cpu->GetReg(0), ir.cpu->GetReg(0),
                                 ir_asm.cpu->GetReg(0), dyn.cpu->GetReg(15),
                                 ir.cpu->GetReg(15), ir_asm.cpu->GetReg(15), ir_stat_used);
}

// A block can hold up to MaxBlockInstructions(48) ops. Short loops put one
// branch every ~5 guest instructions, so each block entry pays the
// asm prologue/epilogue + C++ re-entry cost — real games behave the same.
// Long blocks amortize that overhead and expose the raw per-op dispatch win;
// both shapes matter for the refactor decision.
std::vector<u32> MakeLongBlock(const std::vector<u32>& pattern) {
    std::vector<u32> p;
    while (p.size() < 47) {
        const std::size_t n = std::min<std::size_t>(pattern.size(), 47 - p.size());
        p.insert(p.end(), pattern.begin(), pattern.begin() + n);
    }
    p.push_back(0xEAFFFFCF); // b 0  (pc=188 -> offset -49)
    return p;
}

TEST_CASE("ARM asm executor benchmark: ALU-dense loop", "[arm_asm][bench]") {
    const std::vector<u32> program = {
        0xE2800001, // loop: add r0, r0, #1
        0xE0811000, //       add r1, r1, r0
        0xE2422001, //       sub r2, r2, #1
        0xE1A03003, //       mov r3, r3
        0xE0844003, //       add r4, r4, r3
        0xEAFFFFF9, //       b loop
    };
    BenchArm("alu", program, 2000000);
}

TEST_CASE("ARM asm executor benchmark: load/store loop", "[arm_asm][bench]") {
    const std::vector<u32> program = {
        0xE5810000, // loop: str  r0, [r1, #0]
        0xE5912000, //       ldr  r2, [r1, #0]
        0xE5812004, //       str  r2, [r1, #4]
        0xE5D13007, //       ldrb r3, [r1, #7]
        0xE5C13008, //       strb r3, [r1, #8]
        0xE2800001, //       add  r0, r0, #1
        0xEAFFFFF8, //       b loop
    };
    BenchArm("mem", program, 2000000);
}

TEST_CASE("ARM asm executor benchmark: flag+branch loop", "[arm_asm][bench]") {
    const std::vector<u32> program = {
        0xE2500001, // loop: subs r0, r0, #1
        0xE2911002, //       adds r1, r1, #2
        0xE1500001, //       cmp  r0, r1
        0x1AFFFFFB, //       bne  loop
    };
    BenchArm("branch", program, 2000000);
}

TEST_CASE("ARM asm executor benchmark: multiply loop", "[arm_asm][bench]") {
    const std::vector<u32> program = {
        0xE0000291, // loop: mul   r0, r1, r2
        0xE0854796, //       umull r4, r5, r6, r7
        0xE028BA99, //       mla   r8, r9, r10, r11
        0xEAFFFFFB, //       b loop
    };
    BenchArm("mul", program, 2000000);
}

TEST_CASE("ARM asm executor benchmark: long ALU block", "[arm_asm][bench]") {
    const std::vector<u32> program = MakeLongBlock({
        0xE2800001, // add r0, r0, #1
        0xE0811000, // add r1, r1, r0
        0xE2422001, // sub r2, r2, #1
        0xE1A03003, // mov r3, r3
        0xE0844003, // add r4, r4, r3
        0xE1A05006, // mov r5, r6
    });
    BenchArm("long-alu", program, 2000000);
}

TEST_CASE("ARM asm executor benchmark: long mixed block", "[arm_asm][bench]") {
    const std::vector<u32> program = MakeLongBlock({
        0xE5810000, // str  r0, [r1, #0]
        0xE5912000, // ldr  r2, [r1, #0]
        0xE2800001, // add  r0, r0, #1
        0xE0223000, // eor  r3, r2, r0
        0xE5812004, // str  r2, [r1, #4]
        0xE5D13007, // ldrb r3, [r1, #7]
    });
    BenchArm("long-mix", program, 2000000);
}

// Two blocks branching to each other: the self-loop chain cannot fire
// (branch target != block start), so every iteration pays the C++ block
// re-entry + asm prologue. This isolates the per-op dispatch win from
// the chaining win.
TEST_CASE("ARM asm executor benchmark: cross-block loop", "[arm_asm][bench]") {
    const std::vector<u32> program = {
        0xE2800001, // a: add r0, r0, #1
        0xE0811000, //    add r1, r1, r0
        0xE2422001, //    sub r2, r2, #1
        0xEAFFFFFF, //    b 0x10
        0xE0233001, // b: eor r3, r3, r1
        0xE1844003, //    orr r4, r4, r3
        0xE0055004, //    and r5, r5, r4
        0xEAFFFFF7, //    b 0x0
    };
    BenchArm("xblock", program, 2000000);
}

// ---------------------------------------------------------------------------
// VFP host-FP fast path (src/core/arm/skyeye_common/vfp/vfp_host.cpp)
// ---------------------------------------------------------------------------

struct VfpFlagGuard {
    explicit VfpFlagGuard(bool v) : old(Settings::values.use_vfp_hostfp.GetValue()) {
        Settings::values.use_vfp_hostfp.SetValue(v);
    }
    ~VfpFlagGuard() {
        Settings::values.use_vfp_hostfp.SetValue(old);
    }
    bool old;
};

// VFP CDP encoder helpers, mirroring the field layout used by
// vfp_get_sd/sn/sm/dd/dn/dm in vfp_helper.h.
u32 VfpBinary(u32 fop, u32 d, u32 n, u32 m, bool dbl = false) {
    const u32 D = dbl ? (d >> 4) & 1 : d & 1;
    const u32 Vd = dbl ? d & 0xF : d >> 1;
    const u32 N = dbl ? (n >> 4) & 1 : n & 1;
    const u32 Vn = dbl ? n & 0xF : n >> 1;
    const u32 M = dbl ? (m >> 4) & 1 : m & 1;
    const u32 Vm = dbl ? m & 0xF : m >> 1;
    return 0xEE000A00 | fop | (dbl << 8) | (D << 22) | (Vn << 16) | (Vd << 12) |
           (N << 7) | (M << 5) | Vm;
}

u32 VfpExt(u32 opc4, u32 bit7, u32 d, u32 m, bool dbl = false) {
    const u32 D = dbl ? (d >> 4) & 1 : d & 1;
    const u32 Vd = dbl ? d & 0xF : d >> 1;
    const u32 M = dbl ? (m >> 4) & 1 : m & 1;
    const u32 Vm = dbl ? m & 0xF : m >> 1;
    return 0xEEB00A40 | (dbl << 8) | (opc4 << 16) | (D << 22) | (Vd << 12) |
           (bit7 << 7) | (M << 5) | Vm;
}

// VMOVI: move expanded imm8 into s/d register (decoded as VFPDataProcessing
// mode 1). imm8 = imm4H[19:16]<<4 | imm4L[3:0].
u32 VfpMovImm(u32 imm8, u32 d, bool dbl = false, u32 cond = 0xE) {
    const u32 D = dbl ? (d >> 4) & 1 : d & 1;
    const u32 Vd = dbl ? d & 0xF : d >> 1;
    return (cond << 28) | 0x0EB00A00 | (dbl << 8) | (D << 22) | (Vd << 12) |
           ((imm8 >> 4) << 16) | (imm8 & 0xF);
}

// Mixed-precision variant: the D and M operand field layouts and the sz bit
// are selected independently (needed by cvtd/cvts and the ftoi/itof forms
// whose operand precisions differ).
u32 VfpExtMix(u32 opc4, u32 bit7, u32 d, bool d_dbl, u32 m, bool m_dbl,
              bool sz) {
    const u32 D = d_dbl ? (d >> 4) & 1 : d & 1;
    const u32 Vd = d_dbl ? d & 0xF : d >> 1;
    const u32 M = m_dbl ? (m >> 4) & 1 : m & 1;
    const u32 Vm = m_dbl ? m & 0xF : m >> 1;
    return 0xEEB00A40 | (sz << 8) | (opc4 << 16) | (D << 22) | (Vd << 12) |
           (bit7 << 7) | (M << 5) | Vm;
}

// Runs `program` on: DynCom (oracle), pure C++ IR with BOTH fast paths off
// (asm + hostfp — the previous flag-leak lesson applies here too), and
// IR+ASM+hostfp. All VFP state must match bit-for-bit.
// DynCom's decoder drops every ARMVFP3-tagged pattern (arm_dyncom_dec.cpp:
// "3DS has no VFP3 support"), so VMOVI/VMOVR/vcvt(bff) fall through to the
// CDP wildcard and halt the machine. Programs containing such instructions
// must compare against the pure C++ IR reference only (use_dyn=false).
void RunVfp(const std::vector<u32>& program, const std::array<u32, 15>& regs,
            const std::array<u32, 64>& vfp, u32 fpscr = 0, u64 budget = 0,
            u32 cpsr = USER32MODE, bool use_dyn = true) {
    Machine dyn(false), ir(true), ir_asm(true);
    const auto seed = [&](Machine& m) {
        for (std::size_t i = 0; i < program.size(); ++i) {
            m.env.SetMemory32(static_cast<VAddr>(i * 4), program[i]);
        }
        m.Seed(regs, cpsr);
        for (int i = 0; i < 64; ++i) {
            m.cpu->SetVFPReg(i, vfp[i]);
        }
        m.cpu->SetVFPSystemReg(VFP_FPSCR, fpscr);
    };
    seed(dyn);
    seed(ir);
    seed(ir_asm);
    const u64 slice = budget != 0 ? budget : static_cast<u64>(program.size()) + 8;
    if (use_dyn) {
        dyn.RunInstructions(slice);
    }
    {
        VfpFlagGuard g(false);
        ir.RunInstructions(slice); // softfloat IR reference
    }
    {
        AsmFlagGuard ga;
        VfpFlagGuard gv(true); // ir_asm exercises asm + host fp fast path
        ir_asm.RunInstructions(slice);
    }
    Machine& ref = use_dyn ? dyn : ir;
    if (use_dyn) {
        INFO(fmt::format("pair=ir fpscr ir={:#x} dyn={:#x}",
                         ir.cpu->GetVFPSystemReg(VFP_FPSCR),
                         dyn.cpu->GetVFPSystemReg(VFP_FPSCR)));
        Compare(ir, dyn);
    }
    {
        INFO(fmt::format("pair=ir_asm fpscr ir_asm={:#x} ref={:#x}",
                         ir_asm.cpu->GetVFPSystemReg(VFP_FPSCR),
                         ref.cpu->GetVFPSystemReg(VFP_FPSCR)));
        Compare(ir_asm, ref);
    }
}

// Float bit patterns covering the whole operand-class space the fast path
// must handle or bounce: normals, -0, denormals, infinities, NaNs, and
// integer-pattern words for the itof/ftoi conversions.
std::array<u32, 64> VfpSeedRegs() {
    std::array<u32, 64> r{};
    const u32 vals[] = {
        0x3F800000u, 0xBFC00000u, 0x40490FDBu, 0x00800000u,
        0x7F7FFFFFu, 0x80000000u, 0x00000001u, 0x7F800000u,
        0x7FC00000u, 0x7F800001u, 0xFF800000u, 0x3DCCCCCDu,
        0x42C80000u, 0xC2C80000u, 0x00000000u, 0x3F000000u,
        0x447A0000u, 0x49742400u, 0x38D1B717u, 0xCF000000u,
        0x322BCC77u, 0x00800001u, 0x80800000u, 0x7F7FFFF0u,
    };
    for (int i = 0; i < 64; ++i) {
        r[i] = vals[i % 24];
    }
    return r;
}

// All-normal seed: every register holds a normal single-precision value, so
// double-precision views (adjacent word pairs) are normal too -- the vfpdp
// assembly handler must cover every op with zero slow exits.
std::array<u32, 64> VfpNormalRegs() {
    std::array<u32, 64> r{};
    const u32 vals[] = {
        0x3F800000u, // 1.0
        0xBFC00000u, // -1.5
        0x40490FDBu, // pi
        0x3E800000u, // 0.25
        0x3F000000u, // 0.5
        0x40000000u, // 2.0
        0x42C80000u, // 100.0
        0x3DCCCCCDu, // 0.1
        0x447A0000u, // 1000.0
        0xBF000000u, // -0.5
    };
    for (int i = 0; i < 64; ++i) {
        r[i] = vals[i % 10];
    }
    return r;
}

TEST_CASE("VFP hostfp: directed coverage of fast-path ops", "[vfp_host]") {
    const std::vector<u32> program = {
        VfpBinary(0x00300000, 8, 0, 1),  // vadd.f32 s8, s0, s1
        VfpBinary(0x00300040, 9, 0, 1),  // vsub.f32 s9, s0, s1
        VfpBinary(0x00200000, 10, 2, 3), // vmul.f32 s10, s2, s3
        VfpBinary(0x00800000, 11, 2, 3), // vdiv.f32 s11, s2, s3
        VfpBinary(0x00000000, 12, 0, 1), // vmla.f32 s12, s0, s1
        VfpBinary(0x00100000, 13, 0, 1), // vmls.f32 s13, s0, s1
        VfpBinary(0x00000040, 14, 0, 1), // vnmla.f32 s14, s0, s1
        VfpBinary(0x00100040, 15, 0, 1), // vnmls.f32 s15, s0, s1
        VfpBinary(0x00200040, 16, 2, 3), // vnmul.f32 s16, s2, s3
        VfpExt(0, 0, 17, 4),             // vmov.f32 s17, s4
        VfpExt(0, 1, 18, 4),             // vabs.f32 s18, s4
        VfpExt(1, 0, 19, 5),             // vneg.f32 s19, s5
        VfpExt(1, 1, 20, 8),             // vsqrt.f32 s20, s8  (positive normal)
        VfpExt(4, 0, 0, 1),              // vcmp.f32 s0, s1
        VfpExt(4, 1, 6, 7),              // vcmpe.f32 s6, s7   (denormal vs inf -> slow)
        VfpExt(5, 0, 5, 0),              // vcmpz.f32 s5       (-0.0)
        0xEEF76AC4,                      // vcvtd.f64 d22, s8  (dd dest field)
        0xEEF7BBC2,                      // vcvts.f32 s23, d2  (sd dest field)
        VfpExt(8, 0, 24, 14),            // fuito s24, s14-bits
        VfpExt(8, 1, 25, 15),            // fsito s25, s15-bits
        VfpExt(12, 1, 26, 12),           // ftouiz s26, s12
        VfpExt(13, 1, 27, 13),           // ftosiz s27, s13
        0xEAFFFFFE,                      // b .
    };
    const auto vfp = VfpSeedRegs();
    // RN, TZ and +INF rounding modes; TZ-mode ftoi coverage plus RM on the
    // arithmetic ops.
    RunVfp(program, BaseRegs(), vfp, 0);
    RunVfp(program, BaseRegs(), vfp, 0x00C00000);
    RunVfp(program, BaseRegs(), vfp, 0x00400000);
}

TEST_CASE("VFP hostfp: randomized op sequences incl. specials", "[vfp_host]") {
    std::mt19937 rng(0x5650A9U);
    const u32 fops[] = {0x00000000, 0x00100000, 0x00200000, 0x00300000,
                        0x00000040, 0x00100040, 0x00200040, 0x00300040,
                        0x00800000};
    const u32 exts[] = {
        0xEEB00A40, 0xEEB00AC0, 0xEEB10A40, 0xEEB10AC0, // cpy/abs/neg/sqrt
        0xEEB40A40, 0xEEB40AC0, 0xEEB50A40, 0xEEB50AC0, // cmp/cmpe/cmpz/cmpez
        0xEEB80A40, 0xEEB80AC0,                         // uito/sito
        0xEEBC0A40, 0xEEBC0AC0, 0xEEBD0A40, 0xEEBD0AC0, // toui/touiz/tosi/tosiz
    };
    for (u32 iter = 0; iter < 64; ++iter) {
        const u32 len = 6 + rng() % 14;
        std::vector<u32> program;
        for (u32 i = 0; i < len; ++i) {
            if (rng() % 3 == 0) {
                // FEXT unary op over random register fields; only Vd/Vm/M/D
                // operand bits may vary — the 101X and opc4 fields select the
                // operation and must stay fixed.
                const u32 sd = rng() % 32, sm = rng() % 32;
                u32 inst = exts[rng() % 14] | ((sd >> 1) << 12) |
                           ((sd & 1) << 22) | ((sm >> 1)) | ((sm & 1) << 5);
                // vcmpz/vcmpez require the Vm field to be zero; DynCom's
                // decoder rejects anything else and would legitimately stop.
                if (((inst >> 16) & 0xF) == 5) {
                    inst = (inst & ~0x3Fu) | 0x40;
                }
                program.push_back(inst);
            } else {
                program.push_back(
                    VfpBinary(fops[rng() % 9], rng() % 32, rng() % 32, rng() % 32));
            }
        }
        program.push_back(0xEAFFFFFE); // b .
        CAPTURE(iter);
        {
            std::string dump;
            for (const u32 w : program) {
                dump += fmt::format("{:#x} ", w);
            }
            INFO("program: " + dump);
        }
        RunVfp(program, BaseRegs(), VfpSeedRegs());
    }
}

TEST_CASE("ARM asm executor: VFP scalar data processing fast path", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before = Core::ARMAsm::g_asm_stats
                                 .slow_op_counts[static_cast<size_t>(
                                     Core::ARMIR::Opcode::ArmVFPDataProcessingAlways)]
                                 .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    const std::vector<u32> program = {
        VfpBinary(0x00200000, 4, 2, 6),                    // vmul.f32 s4,s2,s6
        VfpBinary(0x00300000, 8, 4, 2),                    // vadd.f32 s8,s4,s2
        VfpBinary(0x00300040, 10, 8, 6),                   // vsub.f32 s10,s8,s6
        VfpBinary(0x00800000, 12, 10, 2),                  // vdiv.f32 s12,s10,s2
        VfpBinary(0x00000000, 14, 2, 6),                   // vmla.f32 s14,s2,s6
        VfpBinary(0x00100000, 16, 4, 8),                   // vmls.f32 s16,s4,s8
        VfpBinary(0x00000040, 18, 6, 10),                  // vnmla.f32 s18,s6,s10
        VfpBinary(0x00100040, 20, 8, 12),                  // vnmls.f32 s20,s8,s12
        VfpBinary(0x00200040, 22, 2, 4),                   // vnmul.f32 s22,s2,s4
        // NOTE: vmov/fcpy register forms decode to the VMOVR mode-2 op, which
        // is intentionally not in the vfpdp subset -- do not include them here.
        VfpExt(0, 1, 26, 24),                              // vabs.f32 s26,s24
        VfpExt(1, 0, 28, 26),                              // vneg.f32 s28,s26
        VfpExt(1, 1, 30, 26),                              // vsqrt.f32 s30,s26
        VfpExt(4, 0, 4, 10),                               // vcmp.f32 s4,s10
        VfpExt(5, 0, 12, 0),                               // vcmpz.f32 s12
        VfpBinary(0x00200000, 0, 2, 4, true),              // vmul.f64 d0,d2,d4
        VfpBinary(0x00300000, 6, 0, 2, true),              // vadd.f64 d6,d0,d2
        VfpBinary(0x00300040, 8, 6, 4, true),              // vsub.f64 d8,d6,d4
        VfpBinary(0x00800000, 10, 8, 0, true),             // vdiv.f64 d10,d8,d0
        VfpBinary(0x00200040, 12, 2, 4, true),             // vnmul.f64 d12,d2,d4
        VfpExt(0, 1, 15, 12, true),                        // vabs.f64 d15,d12
        VfpExt(1, 0, 14, 15, true),                        // vneg.f64 d14,d15
        VfpExt(1, 1, 15, 15, true),                        // vsqrt.f64 d15,d15 (positive)
        VfpExt(4, 0, 8, 6, true),                          // vcmp.f64 d8,d6
        VfpExt(5, 0, 10, 0, true),                         // vcmpz.f64 d10
        VfpExtMix(7, 1, 11, true, 4, false, false),        // vcvtd.f64 d11,s4
        VfpExtMix(7, 1, 13, false, 11, true, true),        // vcvts.f32 s13,d11
        VfpExt(8, 0, 14, 30),                              // vuito.f32 s14,s30
        VfpExt(8, 1, 15, 31),                              // vsito.f32 s15,s31
        VfpExt(12, 1, 16, 8),                              // vtouiz.f32 s16,s8
        VfpExt(13, 1, 17, 9),                              // vtosiz.f32 s17,s9
        VfpExtMix(8, 0, 9, true, 28, false, true),         // vuito.f64 d9,s28
        VfpExtMix(8, 1, 10, true, 29, false, true),        // vsito.f64 d10,s29
        VfpExtMix(12, 1, 18, false, 11, true, true),       // vtouiz s18,d11
        VfpExtMix(13, 1, 19, false, 12, true, true),       // vtosiz s19,d12
        0xEAFFFFFE,                                        // b .
    };
    RunVfp(program, BaseRegs(), VfpNormalRegs());
#if defined(__aarch64__)
    // Every op above stays inside the normal-or-zero domain, so the vfpdp
    // handler must have covered the whole program without a single slow exit.
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    INFO(fmt::format("slow vfpdp inst={:#010x}",
                     static_cast<u32>(Core::ARMAsm::g_asm_stats.slow_vfpdp_inst.load())));
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmVFPDataProcessingAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: VFP vmov immediate/register moves", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmVFPDataProcessingAlways)]
            .load() +
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmVFPDataProcessing)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // DynCom cannot decode VFPv3 vmov(i)/(r) (see RunVfp comment): the pure
    // C++ IR path calling VMOVI/VMOVR in vfp.cpp is the reference here.
    const std::vector<u32> program = {
        VfpMovImm(0x70, 0),                 // vmov.f32 s0, #1.0
        VfpMovImm(0x00, 1),                 // vmov.f32 s1, #0.0
        VfpMovImm(0xB5, 31),                // vmov.f32 s31, #imm (odd reg)
        VfpMovImm(0x70, 4, true),           // vmov.f64 d4, #1.0
        VfpMovImm(0x3D, 15, true),          // vmov.f64 d15, #imm
        VfpExt(0, 0, 17, 0),                // vmov.f32 s17, s0   (VMOVR mode 2)
        VfpExt(0, 0, 26, 22),               // vmov.f32 s26, s22
        VfpExt(0, 0, 5, 4, true),           // vmov.f64 d5, d4
        VfpExt(0, 0, 8, 15, true),          // vmov.f64 d8, d15
        VfpExt(0, 0, 9, 9, true),           // vmov.f64 d9, d9 (self)
        // Predicated forms: EQ set vs clear must both match exactly.
        (VfpMovImm(0x70, 10, false, 0x0)),  // vmov eq .f32 s10,#1.0
        (VfpMovImm(0x70, 11, false, 0x1)),  // vmov ne .f32 s11,#1.0
        0xEAFFFFFE,                         // b .
    };
    RunVfp(program, BaseRegs(), VfpSeedRegs(), 0, 0, USER32MODE, false);
    RunVfp(program, BaseRegs(), VfpSeedRegs(), 0, 0, USER32MODE | ZBIT, false);
#if defined(__aarch64__)
    // The vfpmov handler covers VMOVI/VMOVR exactly -- no slow exits allowed.
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    const auto slow_after =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmVFPDataProcessingAlways)]
            .load() +
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmVFPDataProcessing)]
            .load();
    REQUIRE(slow_after == slow_before);
#endif
}

TEST_CASE("ARM asm executor: VFP data processing domain bounce", "[arm_asm]") {
    // Every operand/result class outside the normal-or-zero domain must take
    // the C++ fallback and still produce the reference state.
    std::array<u32, 64> vfp{};
    vfp[0] = 0x3F800000;  // 1.0
    vfp[2] = 0x00000001;  // denormal
    vfp[4] = 0x7F800000;  // +inf
    vfp[6] = 0x7FC00000;  // qNaN
    vfp[8] = 0x80000000;  // -0.0
    vfp[10] = 0x7F7FFFFF; // max float
    vfp[12] = 0xC0200000; // -2.5
    vfp[24] = 0x7F7FFFFF; // d12: two max-float words -> normal huge double
    vfp[25] = 0x7F7FFFFF;
    const std::vector<u32> program = {
        VfpBinary(0x00200000, 14, 0, 2),            // vmul.f32 s14,s0,s2  (denormal)
        VfpBinary(0x00300000, 15, 0, 6),            // vadd.f32 s15,s0,s6  (NaN)
        VfpBinary(0x00300040, 16, 4, 4),            // vsub.f32 inf-inf -> NaN
        VfpBinary(0x00800000, 17, 0, 8),            // vdiv.f32 1.0/-0.0 -> -inf
        VfpBinary(0x00200000, 18, 10, 10),          // vmul.f32 max*max -> +inf
        VfpExt(1, 1, 20, 6),                        // vsqrt.f32 NaN
        VfpExt(1, 1, 21, 0),                        // vsqrt.f32 1.0 (in-domain)
        VfpExt(4, 0, 0, 6),                         // vcmp.f32 vs NaN (unordered)
        VfpExt(4, 0, 0, 8),                         // vcmp.f32 vs -0.0 (equal)
        VfpExt(5, 0, 8, 0),                         // vcmpz.f32 -0.0
        VfpExt(12, 1, 22, 12),                      // vtouiz.f32 -2.5 (neg bounce)
        VfpExt(13, 1, 23, 12),                      // vtosiz.f32 -2.5 -> -2
        VfpBinary(0x00200000, 12, 12, 12, true),    // vmul.f64 d12*d12 -> +inf
        VfpBinary(0x00300000, 13, 12, 2, true),     // vadd.f64 d13 (inf operand)
        VfpExt(0, 0, 26, 22),                       // vmov.f32 s26,s22 -> VMOVR mode-2 slow
        0xEAFFFFFE,                                 // b .
    };
    RunVfp(program, BaseRegs(), vfp);
}

TEST_CASE("ARM asm executor: VFP non-RN/vector FPSCR modes stay slow", "[arm_asm]") {
    // Round-to-nearest scalar mode is the only domain the assembly covers;
    // everything else must bounce to C++ and still match DynCom.
    const std::vector<u32> program = {
        VfpBinary(0x00300000, 4, 0, 1),    // vadd.f32 s4,s0,s1
        VfpBinary(0x00200000, 6, 2, 3),    // vmul.f32 s6,s2,s3
        VfpExt(12, 0, 8, 4),               // vtoui.f32 s8,s4  (rmode-driven)
        VfpExt(13, 0, 9, 5),               // vtosi.f32 s9,s5
        0xEAFFFFFE,                        // b .
    };
    for (u32 fpscr : {0x00400000u, 0x00800000u, 0x00C00000u,
                      0x00020000u /* LEN=2 vector mode */}) {
        CAPTURE(fpscr);
        RunVfp(program, BaseRegs(), VfpNormalRegs(), fpscr);
    }
}

TEST_CASE("ARM asm executor: conditional VFP data processing", "[arm_asm]") {
    // Predicated VFP ops run as guard+body records; exercise both the passing
    // and failing sides of the condition.
    const std::vector<u32> p = {
        0x03A01005,                                       // moveq r1, #5
        (0x0u << 28) | (VfpBinary(0x00300000, 4, 0, 1) & 0x0FFFFFFF), // vaddeq.f32
        (0x1u << 28) | (VfpBinary(0x00200000, 6, 2, 3) & 0x0FFFFFFF), // vmulne.f32
        0xEAFFFFFE,                                       // b .
    };
    RunVfp(p, BaseRegs(), VfpNormalRegs(), 0, 0, USER32MODE | ZBIT);
    RunVfp(p, BaseRegs(), VfpNormalRegs(), 0, 0, USER32MODE);
}

TEST_CASE("ARM asm executor: standalone tst/teq immediate flag ops", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmTstImmediateNoPcAlways)]
            .load() +
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmTeqImmediateNoPcAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    const std::vector<u32> program = {
        0xE3120102, // tst r2, #0x80000000  -> Z=1, C=1 (imm carry)
        0x1A000000, // bne +8               (not taken: Z set)
        0xE3320000, // teq r2, #0           -> Z=0, C=old C=1 (rot==0 keeps C)
        0x1A000000, // bne +8               (taken: Z clear)
        0xE2803009, // add r3, r3, #9       (skipped)
        0xE0A55000, // adc r5, r5, #0       -> r5 += C(1) from the teq above
        0xE3170102, // tst r7, #0x80000000  -> N=1, Z=0
        0x4A000000, // bmi +8               (taken: N set)
        0xE2806007, // add r6, r6, #7       (skipped)
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    const auto slow_after =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmTstImmediateNoPcAlways)]
            .load() +
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmTeqImmediateNoPcAlways)]
            .load();
    REQUIRE(slow_after == slow_before);
#endif
}

TEST_CASE("ARM asm executor: vmrs/vmsr system register transfers", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmVFPSystemRegisterTransfer)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    const std::vector<u32> program = {
        0xE3A00480, // mov r0, #0x80000000 (imm8 0x80 ror 8)
        0xEEE10A10, // vmsr fpscr, r0
        0xEEF11A10, // vmrs r1, fpscr
        0xEEF1FA10, // vmrs apsr_nzcv, fpscr -> N=1 Z=C=V=0
        0x43A02007, // movmi r2, #7   (N set: executes)
        0x53A03009, // movpl r3, #9   (N set: skipped)
        0x1EF16A10, // vmrsne r6, fpscr   (Z clear: executes)
        0x0EF17A10, // vmrseq r7, fpscr   (Z clear: skipped)
        0xEEF08A10, // vmrs r8, fpsid
        0xEAFFFFFE, // b .
    };
    RunVfp(program, BaseRegs(), VfpSeedRegs(), 0);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmVFPSystemRegisterTransfer)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: mrs cpsr/spsr", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmMoveStatusToRegister)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    const std::vector<u32> program = {
        0xE10F0000, // mrs r0, cpsr
        0x010F2000, // mrseq r2, cpsr
        0x110F3000, // mrsne r3, cpsr
        0xE3A04001, // mov r4, #1
        0xEAFFFFFE, // b .
    };
    RunVfp(program, BaseRegs(), VfpSeedRegs(), 0, 0, USER32MODE | ZBIT);
    RunVfp(program, BaseRegs(), VfpSeedRegs(), 0, 0, USER32MODE);
    // SPSR only exists in privileged modes and Spsr_copy is otherwise
    // uninitialized. Seed it deterministically via "msr spsr_cxsf" (slow
    // path), then read it back through the asm mrs. DynCom's SPSR bank
    // handling differs, so this compares pure IR vs IR+ASM.
    const std::vector<u32> spsr_program = {
        0xE16FF004, // msr spsr_cxsf, r4
        0xE14F1000, // mrs r1, spsr
        0xEAFFFFFE, // b .
    };
    RunVfp(spsr_program, BaseRegs(), VfpSeedRegs(), 0, 0, SVC32MODE, false);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmMoveStatusToRegister)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: mrc p15 thread registers", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmCoprocessor15Transfer)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    const std::vector<u32> program = {
        0xEE1D0F50, // mrc p15, #0, r0, c13, c0, #2  (CP15_THREAD_UPRW)
        0xEE1D1F70, // mrc p15, #0, r1, c13, c0, #3  (CP15_THREAD_URO)
        0x1E1D3F50, // mrcne p15, #0, r3, c13, c0, #2
        0x0E1D4F70, // mrceq p15, #0, r4, c13, c0, #3
        0xEAFFFFFE, // b .
    };
    RunVfp(program, BaseRegs(), VfpSeedRegs(), 0, 0, USER32MODE | ZBIT);
    RunVfp(program, BaseRegs(), VfpSeedRegs(), 0, 0, USER32MODE);
    // Uncovered encodings (mrc into pc = flag copy, virtual-to-physical
    // write) exercise the C++ fallback from inside an asm-covered block.
    // DynCom's CP15 model differs for these, so the pure IR path is the
    // reference.
    const std::vector<u32> slow_ops = {
        0xEE1DFF50, // mrc p15, #0, pc, c13, c0, #2  (rd=15: stays slow)
        0xEE074F14, // mcr p15, #0, r4, c7, c4, #0   (v2p: stays slow)
        0xEAFFFFFE, // b .
    };
    RunVfp(slow_ops, BaseRegs(), VfpSeedRegs(), 0, 0, USER32MODE, false);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    // The asm prefix exits at the FIRST slow record; the rest of the block
    // runs in C++, so only the leading uncovered op is counted.
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmCoprocessor15Transfer)]
                .load() == slow_before + 1);
#endif
}

TEST_CASE("ARM asm executor: conditional register-offset load/store", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmLoadStoreRegister)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // r1 = 0x1000 data base, r2 = 0x1004, r3 = 0x9ABCDEF0, r6 = 1.
    // All addresses stay inside the mapped test pages so no op slow-exits.
    const std::vector<u32> program = {
        0x07910002, // ldreq r0, [r1, r2]
        0x17813186, // strne r3, [r1, r6, lsl #3]  -> writes 0x1008
        0x17C13006, // strbne r3, [r1, r6]         -> writes 0x1001
        0x07D17002, // ldrbeq r7, [r1, r2]
        0x27916186, // ldrcs r6, [r1, r6, lsl #3]  -> reads 0x1008 (r6 dead)
        0xEAFFFFFE, // b .
    };
    // Three flag seeds: each predicated op runs its pass and fail side.
    RunArm(program, BaseRegs(), USER32MODE | ZBIT);
    RunArm(program, BaseRegs(), USER32MODE);
    RunArm(program, BaseRegs(), USER32MODE | ZBIT | CBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmLoadStoreRegister)]
                .load() == slow_before);
#endif
}

TEST_CASE("VFP hostfp benchmark: f32 arithmetic loop", "[vfp_host][bench]") {
    const std::vector<u32> program = {
        // Convergent recurrence: every operand and result stays a normal
        // float, so the host fast path covers 100% of iterations.
        VfpBinary(0x00200000, 4, 4, 1),  // loop: vmul.f32 s4, s4, s1   (*0.5)
        VfpBinary(0x00300000, 4, 4, 2),  //       vadd.f32 s4, s4, s2   (+0.25)
        VfpBinary(0x00300040, 5, 4, 3),  //       vsub.f32 s5, s4, s3
        VfpBinary(0x00800000, 6, 2, 4),  //       vdiv.f32 s6, s2, s4
        VfpBinary(0x00000000, 7, 4, 1),  //       vmla.f32 s7, s4, s1   (accum)
        VfpBinary(0x00100000, 8, 4, 1),  //       vmls.f32 s8, s4, s1   (drain)
        VfpExt(0, 1, 9, 8),              //       vabs.f32 s9, s8
        VfpExt(1, 1, 10, 9),             //       vsqrt.f32 s10, s9
        VfpExt(1, 0, 11, 10),            //       vneg.f32 s11, s10
        VfpExt(4, 0, 4, 5),              //       vcmp.f32 s4, s5
        0xEAFFFFF4,                      //       b loop
    };
    // All-normal seeds so no instruction ever bounces to softfloat.
    std::array<u32, 64> vfp{};
    for (int i = 0; i < 64; ++i) {
        vfp[i] = 0x3F800000u; // 1.0f
    }
    vfp[1] = 0x3F000000u;  // 0.5f
    vfp[2] = 0x3E800000u;  // 0.25f
    vfp[3] = 0xBE000000u;  // -0.125f
    const u64 budget = 2000000;
    Machine dyn(false), ir(true), ir_fast(true);
    const auto setup = [&](Machine& m) {
        for (std::size_t i = 0; i < program.size(); ++i) {
            m.env.SetMemory32(static_cast<VAddr>(i * 4), program[i]);
        }
        m.Seed(BaseRegs());
        for (int i = 0; i < 64; ++i) {
            m.cpu->SetVFPReg(i, vfp[i]);
        }
        m.cpu->SetVFPSystemReg(VFP_FPSCR, 0);
    };
    setup(dyn);
    setup(ir);
    setup(ir_fast);

    const double t_dyn = TimeRunSeconds(dyn, budget);
    Settings::values.use_cpu_asm_interpreter.SetValue(false);
    double t_soft;
    {
        VfpFlagGuard g(false);
        t_soft = TimeRunSeconds(ir, budget);
    }
    double t_fast;
    {
        VfpFlagGuard gv(true); // isolate: host fp on, asm stays off
        t_fast = TimeRunSeconds(ir_fast, budget);
    }

    const double mips = static_cast<double>(budget) / 1e6;
    Catch::cout() << fmt::format(
        "[bench] vfp budget={}M | dyncom {:.3f}s ({:.2f} MIPS) | ir-softfp {:.3f}s "
        "({:.2f} MIPS) | ir-hostfp {:.3f}s ({:.2f} MIPS) | speedup host/soft {:.2f}x\n",
        mips, t_dyn, mips / t_dyn, t_soft, mips / t_soft, t_fast, mips / t_fast,
        t_soft / t_fast);
}

TEST_CASE("ARM asm executor stats prove the fast path ran", "[arm_asm]") {
#if defined(__aarch64__)
    const auto before = Core::ARMAsm::g_asm_stats.ops_executed.load();
    const std::vector<u32> program = {
        0xE2800001, // add r0, r0, #1
        0xE2811001, // add r1, r1, #1
        0xE2822001, // add r2, r2, #1
        0xEAFFFFFE, // b .
    };
    Machine dyn(false), ir(true), ir_asm(true);
    for (std::size_t i = 0; i < program.size(); ++i) {
        const VAddr a = static_cast<VAddr>(i * 4);
        dyn.env.SetMemory32(a, program[i]);
        ir.env.SetMemory32(a, program[i]);
        ir_asm.env.SetMemory32(a, program[i]);
    }
    const auto regs = BaseRegs();
    dyn.Seed(regs);
    ir.Seed(regs);
    ir_asm.Seed(regs);
    dyn.RunInstructions(4);
    ir.RunInstructions(4);
    {
        AsmFlagGuard guard;
        ir_asm.RunInstructions(4);
    }
    Compare(ir, dyn);
    Compare(ir_asm, dyn);
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > before);
#else
    SUCCEED("asm executor is ARM64-only");
#endif
}

TEST_CASE("ARM asm executor: register-offset load/store", "[arm_asm]") {
    // Word/byte register-offset forms with all four shift types, add/sub,
    // and the plain Add/Sub specialisations. r1=0x1000 is the data window.
    RunArm(
        {
            0xE1A02005, // mov r2, r5  (offset value 0x0000FFFF masked later)
            0xE2822004, // add r2, r2, #4
            0xE7910102, // ldr r0, [r1, r2, lsl #2]
            0xE7813102, // str r3, [r1, r2, lsl #2]
            0xE7510002, // ldrb r0, [r1, -r2]
            0xE7C14082, // strb r4, [r1, r2, lsl #1]
            0xE79111A2, // ldr r1, [r1, r2, lsr #3]
            0xE7950242, // ldr r0, [r5, r2, asr #4]
            0xE79512E2, // ldr r1, [r5, r2, ror #5]
            0xE7916102, // ldr r6, [r1, r2, lsl #2]
            0xE7A17002, // str r7, [r1, r2, lsl #0]  (plain rm)
        },
        BaseRegs());
}

TEST_CASE("ARM asm executor: halfword/signed register offsets", "[arm_asm]") {
    RunArm(
        {
            0xE1A02005, // mov r2, r5
            0xE1D100B2, // ldrh r0, [r1, r2]
            0xE1C130B2, // strh r3, [r1, r2]
            0xE15140D2, // ldrsb r4, [r1, -r2]
            0xE1D160F2, // ldrsh r6, [r1, r2]
            0xE1C170B2, // strh r7, [r1, r2]
            0xE1D100D2, // ldrsb r0, [r1, r2]
            0xE1D100F2, // ldrsh r0, [r1, r2]
        },
        BaseRegs());
}

TEST_CASE("ARM asm executor: writeback immediate forms", "[arm_asm]") {
    // Pre-indexed (!) and post-indexed writeback for word/byte/halfword and
    // the signed loads, including rd==rn aliases where the C++ order matters:
    // loads write rd first so the writeback wins; stores read rd before rn
    // is updated.
    RunArm(
        {
            0xE5B11008, // ldr r1, [r1, #8]!   rd==rn: wb overwrites loaded
            0xE5A11004, // str r1, [r1, #4]!   rd==rn: stores pre-wb value
            0xE5B12008, // ldr r2, [r1, #8]!
            0xE5A13004, // str r3, [r1, #4]!
            0xE4914004, // ldr r4, [r1], #4    post
            0xE4815004, // str r5, [r1], #4    post
            0xE4416004, // strb r6, [r1], #-4
            0xE5F17004, // ldrb r7, [r1, #4]!
            0xE5E18004, // strb r8, [r1, #4]!
            0xE1F190B6, // ldrh r9, [r1, #6]!
            0xE1E1A0B2, // strh r10, [r1, #2]!
            0xE1F1B0D4, // ldrsb r11, [r1, #4]!
            0xE1F1C0F4, // ldrsh r12, [r1, #4]!
            0xE0D100B4, // ldrh r0, [r1], #4
            0xE0C1D0B2, // strh r13, [r1], #2  (rn=13 not pc-relative; ok)
        },
        BaseRegs());
}

TEST_CASE("ARM asm executor: LDM/STM modes and edge cases", "[arm_asm]") {
    // All four addressing modes with/without writeback, a single-register
    // list, rn inside the stored list (must store the pre-writeback base),
    // and rn inside the loaded list (the load overwrites the writeback).
    RunArm(
        {
            0xE8AD000F, // stmia r13!, {r0-r3}
            0xE8BD000F, // ldmia r13!, {r0-r3}
            0xE92D000F, // stmdb r13!, {r0-r3}
            0xE93D000F, // ldmdb r13!, {r0-r3}
            0xE9AD0007, // stmib r13!, {r0-r2}
            0xE81D0007, // ldmda r13!, {r0-r2}
            0xE8AD6000, // stmia r13!, {r13, r14}  rn in list, wb
            0xE8BD2000, // ldmia r13!, {r13}       rn in list, wb
            0xE89D0020, // ldmia r13, {r5}         single, no wb
            0xE88D001F, // stmia r13, {r0-r4}      no wb
            0xE89D0FFF, // ldmia r13, {r0-r11}     12 regs, no wb
        },
        BaseRegs());
}

TEST_CASE("ARM asm executor: VFP load/store/multiple and transfers", "[arm_asm]") {
    // vldr/vstr s+d with both directions, vldm/vstm with writeback, plus
    // vmov/vmrs/vmsr register transfers.
    RunArm(
        {
            0xED910A00, // vldr s0, [r1]
            0xED911A03, // vldr s1, [r1, #12]
            0xED110A02, // vldr s0, [r1, #-8]
            0xED812A04, // vstr s2, [r1, #16]
            0xED910B00, // vldr d0, [r1]
            0xED913B04, // vldr d3, [r1, #16]
            0xED112B02, // vstr d2, [r1, #-8]
            0xECB10A04, // vldmia r1!, {s0-s3}
            0xECA10A04, // vstmia r1!, {s0-s3}
            0xECB10B04, // vldmia r1!, {d0-d1}
            0xECA10B04, // vstmia r1!, {d0-d1}
            0xEC910A08, // vldmia r1, {s0-s7}     no wb
            0xEE043A10, // vmov s3, r4           arm -> vfp
            0xEE101A12, // vmov r1, s2           vfp -> arm
            0xEEF13A10, // vmrs r3, fpscr
            0xEEE12A10, // vmsr fpscr, r2
        },
        BaseRegs());
}

TEST_CASE("ARM asm executor: randomized memory-op sequences", "[arm_asm]") {
    // Random mixes of the newly covered memory opcodes. Encodings are kept
    // inside the data window so both engines see identical memory; a few
    // deliberately touch page edges and unaligned addresses.
    // On this memory model a bit-31-set address takes the LUMA alias path
    // into FCRAM/MMIO and hits UNREACHABLE, so no generated address may
    // carry bit 31. Loads also copy memory contents into registers, so the
    // register pool is split: r1-r4 hold window bases (>=0x8000, seeded
    // each iteration) while r5-r11 hold small offsets (<=0xFF). LDM/STM
    // lists are restricted to r5-r11 and memory contents only ever hold
    // those small values, so loaded registers can never synthesize a
    // bit-31 address or reach the program words near address 0.
    std::mt19937 rng(0xC17A11);
    std::uniform_int_distribution<u32> reg(0, 11); // avoid r12-r14 writes
    std::uniform_int_distribution<u32> off(0, 60);
    std::uniform_int_distribution<u32> sh(0, 7);
    std::uniform_int_distribution<u32> st(0, 3);
    std::uniform_int_distribution<u32> list(1, 0x7F);
    for (int iter = 0; iter < 96; ++iter) {
        std::vector<u32> program;
        for (int i = 0; i < 12; ++i) {
            const u32 rn = 1 + reg(rng) % 4; // r1-r4: mapped window bases
            const u32 rdm = 5 + reg(rng) % 7; // r5-r11: small values only
            const u32 rm = 5 + reg(rng) % 7;
            switch (i % 8) {
            case 0: // ldr rd, [rn, rm, shift]
                program.push_back(0xE7900000 | (rn << 16) | (rdm << 12) |
                                  // keep rm<<shift inside the mapped page:
                                  // r<=0x100F, shift<=7 -> offset<=0x80780
                                  ((sh(rng) & 0x7) << 7) | (st(rng) << 5) | rm);
                break;
            case 1: // str rd, [rn, rm]
                program.push_back(0xE7800000 | (rn << 16) | (rdm << 12) | rm);
                break;
            case 2: // ldrb rd, [rn, -rm]
                program.push_back(0xE7500000 | (rn << 16) | (rdm << 12) | rm);
                break;
            case 3: // ldr rd, [rn, #off]!
                program.push_back(0xE5B00000 | (rn << 16) | (rdm << 12) |
                                  (off(rng) & 0xFFF));
                break;
            case 4: // str rd, [rn], #off
                program.push_back(0xE4800000 | (rn << 16) | (rdm << 12) |
                                  (off(rng) & 0xFFF));
                break;
            case 5: // ldrh rd, [rn, rm]
                program.push_back(0xE1D000B0 | (rn << 16) | (rdm << 12) | rm);
                break;
            case 6: // ldmia rn!, {r5-r11 subset}
                program.push_back(0xE8B00000 | (rn << 16) | (list(rng) << 5));
                break;
            default: // stmia rn!, {r5-r11 subset}
                program.push_back(0xE8A00000 | (rn << 16) | (list(rng) << 5));
                break;
            }
        }
        INFO(fmt::format("iter{}", iter));
        auto regs = BaseRegs();
        for (u32& r : regs) {
            r = 0x1000 + (r & 0xF);
        }
        for (u32 i = 1; i <= 4; ++i) {
            regs[i] = 0x8000 + i * 0x100;
        }
        for (u32 i = 5; i <= 11; ++i) {
            regs[i] = i * 0x10;
        }
        RunArm(program, regs);
    }
}

TEST_CASE("ARM asm executor: repeatedly futile blocks fall back to C++", "[arm_asm]") {
#if defined(__aarch64__)
    // qadd must run on the C++ path (no asm handler), so a block headed by
    // it bails from the executor after zero fast ops. Re-entering that
    // block every loop iteration would pay the run prologue for nothing;
    // after a few such runs the interpreter must stop entering asm for it
    // while chained jumps into it remain legal. The C++ handler falls
    // through to the next op, keeping [qadd, b] one block — an op whose
    // C++ case returns early (cps, setend) would split the loop into two
    // blocks and the branch-only block would chain back legally instead
    // of accumulating futile runs. State must still match DynCom.
    const std::vector<u32> program = {
        0xE1011051, // qadd r1, r1, r1
        0xEAFFFFFD, // b 0x00  (back to qadd)
    };
    Machine dyn(false), ir(true), ir_asm(true);
    for (std::size_t i = 0; i < program.size(); ++i) {
        const VAddr a = static_cast<VAddr>(i * 4);
        dyn.env.SetMemory32(a, program[i]);
        ir.env.SetMemory32(a, program[i]);
        ir_asm.env.SetMemory32(a, program[i]);
    }
    const auto regs = BaseRegs();
    dyn.Seed(regs);
    ir.Seed(regs);
    ir_asm.Seed(regs);
    const auto runs_before = Core::ARMAsm::g_asm_stats.runs.load();
    const auto skip_before = Core::ARMAsm::g_asm_stats.skipped_runs.load();
    dyn.RunInstructions(2000);
    ir.RunInstructions(2000);
    {
        AsmFlagGuard guard;
        ir_asm.RunInstructions(2000);
    }
    Compare(ir, dyn);
    Compare(ir_asm, dyn);
    const auto runs = Core::ARMAsm::g_asm_stats.runs.load() - runs_before;
    const auto skips = Core::ARMAsm::g_asm_stats.skipped_runs.load() - skip_before;
    INFO("asm runs=" << runs << " skipped=" << skips);
    // ~1000 loop iterations; without the bail-out guard that would be
    // ~1000 citra_asm_run calls. Allow slack for warm-up runs plus a few
    // boundary entries from other test traffic sharing the table.
    REQUIRE(runs <= 32);
    REQUIRE(skips >= 400);
#else
    SUCCEED("asm executor is ARM64-only");
#endif
}

TEST_CASE("ARM asm executor: conditional halfword load/store", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmLoadStoreHalfword)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // r1 = 0x1000 data base, r2 = 0x1004, r3 = store value, r9 = 0x1F00.
    auto regs = BaseRegs();
    regs[9] = 0x1F00;
    const std::vector<u32> program = {
        0x01D100B4, // ldrheq r0, [r1, #4]
        0x11C130B6, // strhne r3, [r1, #6]
        0x01D140D2, // ldrsbeq r4, [r1, #2]
        0x21D150F4, // ldrshcs r5, [r1, #4]
        0x01F100B4, // ldrheq r0, [r1, #4]!
        0x019170B2, // ldrheq r7, [r1, r2]
        0x119180D2, // ldrsbne r8, [r1, r2]
        0x01D98FBF, // ldrheq r8, [r9, #0xFF] -> 0x1FFF crosses page (slow)
        0xEAFFFFFE, // b .
    };
    // Three flag seeds: each predicated op runs its pass and fail side.
    RunArm(program, regs, USER32MODE | ZBIT);
    RunArm(program, regs, USER32MODE);
    RunArm(program, regs, USER32MODE | ZBIT | CBIT);
    // DynCom's addressing-mode table has no entry for post-indexed
    // halfword transfers (P=0,W=1) and executes a null handler, so cover
    // those IR-vs-ASM only.
    const std::vector<u32> post_program = {
        0x10E130B6, // strhne r3, [r1], #6
        0x10F140B2, // ldrhne r4, [r1], #2
        0xEAFFFFFE, // b .
    };
    Machine ir(true), ir_asm(true);
    for (std::size_t i = 0; i < post_program.size(); ++i) {
        ir.env.SetMemory32(static_cast<VAddr>(i * 4), post_program[i]);
        ir_asm.env.SetMemory32(static_cast<VAddr>(i * 4), post_program[i]);
    }
    ir.Seed(regs);
    ir_asm.Seed(regs);
    ir.RunInstructions(static_cast<u64>(post_program.size()) + 8);
    {
        AsmFlagGuard guard;
        ir_asm.RunInstructions(static_cast<u64>(post_program.size()) + 8);
    }
    Compare(ir_asm, ir);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    // Only the page-crossing ldrh bails to C++.
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmLoadStoreHalfword)]
                .load() >= slow_before + 1);
#endif
}

TEST_CASE("ARM asm executor: ldrex/strex word monitor semantics", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_ld_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmExclusiveLoad)]
            .load();
    const auto slow_st_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmExclusiveStore)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // r1 = 0x1000 data base, r2 = 0x1004 (same 8-byte granule), r3 = value.
    const std::vector<u32> program = {
        0xE5910000, // ldr r0, [r1]            -> seed 0x1000 contents into r0
        0xE1914F9F, // ldrex r4, [r1]
        0xE5813000, // str r3, [r1]            -> plain store: keeps monitor
        0xE1815F93, // strex r5, r3, [r1]      -> succeeds: r5 = 0, [0x1000] = r3
        0xE1816F93, // strex r6, r3, [r1]      -> fails (monitor consumed): r6 = 1
        0xE1927F9F, // ldrex r7, [r2]          -> 0x1004, same granule as 0x1000
        0xE1828F93, // strex r8, r3, [r2]      -> succeeds (granule match): r8 = 0
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    // Every exclusive op in the program is covered: no slow exits.
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmExclusiveLoad)]
                .load() == slow_ld_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmExclusiveStore)]
                .load() == slow_st_before);
#endif
}

TEST_CASE("ARM asm executor: conditional ldrex/strex", "[arm_asm]") {
    // Predicated forms run through guard records; both condition polarities
    // are seeded via ZBIT.
    const std::vector<u32> program = {
        0x01914F9F, // ldrexeq r4, [r1]
        0x11815F93, // strexne r5, r3, [r1]
        0x11826F93, // strexne r6, r3, [r2]
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs(), USER32MODE | ZBIT);
    RunArm(program, BaseRegs(), USER32MODE);
}

TEST_CASE("ARM asm executor: strex failure leaves monitor armed", "[arm_asm]") {
    // A failed STREX (different granule) must NOT clear the monitor: the
    // second STREX to the armed address still succeeds.
    const std::vector<u32> program = {
        0xE1914F9F, // ldrex r4, [r1]          -> arms granule 0x1000-0x1007
        0xE1885F93, // strex r5, r3, [r8]      -> 0x1800: miss, r5 = 1
        0xE1816F93, // strex r6, r3, [r1]      -> still armed: r6 = 0
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[8] = 0x1800; // second mapped page, different granule
    RunArm(program, regs);
}

TEST_CASE("ARM asm executor: clrex clears the monitor", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmClearExclusive)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // ldrex arms the granule, clrex disarms it: the following strex must
    // fail (rd = 1). A second ldrex re-arms and the last strex succeeds.
    const std::vector<u32> program = {
        0xE1914F9F, // ldrex r4, [r1]
        0xF57FF01F, // clrex
        0xE1815F93, // strex r5, r3, [r1]      -> fails: r5 = 1
        0xE1926F9F, // ldrex r6, [r2]
        0xF57FF01F, // clrex
        0xE1817F93, // strex r7, r3, [r1]      -> fails (re-arm was for 0x1004, then clrex): r7 = 1
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmClearExclusive)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: ldrex/strex byte-halfword stay slow", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_ld_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmExclusiveLoad)]
            .load();
#endif
    // Non-word exclusive forms are intentionally not assembled; they still
    // have to produce identical state via the C++ path.
    const std::vector<u32> program = {
        0xE1D14F9F, // ldrexb r4, [r1]
        0xE1F15F9F, // ldrexh r5, [r1]
        0xE1C16F93, // strexb r6, r3, [r1]
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());
#if defined(__aarch64__)
    // The asm prefix exits at the first slow record; ldrexb/ldrexh are the
    // covered-family ops that bounce to C++.
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmExclusiveLoad)]
                .load() == slow_ld_before + 1);
#endif
}

TEST_CASE("ARM asm executor: movs shifted-immediate flag synthesis", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmMoveShiftedRegisterSetFlagsAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // r3 = 0x9ABCDEF0. All four shift types plus every imm==0 special case
    // (LSL passthrough is a different op; LSR/ASR saturate, ROR becomes RRX).
    const std::vector<u32> program = {
        0xE1B04283, // movs r4, r3, lsl #5
        0xE1B053A3, // movs r5, r3, lsr #7
        0xE1B064C3, // movs r6, r3, asr #9
        0xE1B075E3, // movs r7, r3, ror #11
        0xE1B08023, // movs r8, r3, lsr #32
        0xE1B09043, // movs r9, r3, asr #32
        0xE1B0A063, // movs r10, r3, rrx
        0xE1B0B084, // movs r11, r4, lsl #1
        0xEAFFFFFE, // b .
    };
    // CBIT feeds RRX; VBIT must survive every flag write.
    RunArm(program, BaseRegs(), USER32MODE | CBIT | VBIT);
    RunArm(program, BaseRegs(), USER32MODE);
    RunArm(program, BaseRegs(), USER32MODE | ZBIT | NBIT | VBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmMoveShiftedRegisterSetFlagsAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: carry-arithmetic shifted register (no flags)",
          "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmArithmeticShiftedRegisterNoPcAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // ADC/SBC/RSC consume the incoming C; RSB does not. RRX shifts C in.
    const std::vector<u32> program = {
        0xE0A04203, // adc r4, r0, r3, lsl #4
        0xE0C15063, // sbc r5, r1, r3, rrx
        0xE0626443, // rsb r6, r2, r3, asr #8
        0xE0E07023, // rsc r7, r0, r3, lsr #32
        0xE0A048E3, // adc r4, r4, r3, ror #17
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0x7FFFFFF0;
    regs[2] = 0xDEADBEEF;
    RunArm(program, regs, USER32MODE | CBIT);
    RunArm(program, regs, USER32MODE);
    RunArm(program, regs, USER32MODE | CBIT | VBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmArithmeticShiftedRegisterNoPcAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: logical register-shifted set-flags", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::
                    ArmLogicalRegisterShiftedRegisterSetFlagsNoPcAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // Register-amount shifts: r5=0 (passthrough), r6=31, r7=32, r8=40,
    // r9=255 (&31 -> ror 31). Covers every saturation edge of the ARM
    // register-shift rules.
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0x12345678;
    regs[1] = 0x87654321;
    regs[2] = 0xDEADBEEF;
    regs[5] = 0;
    regs[6] = 31;
    regs[7] = 32;
    regs[8] = 40;
    regs[9] = 255;
    const std::vector<u32> program = {
        0xE0104513, // ands r4, r0, r3, lsl r5
        0xE031A633, // eors r10, r1, r3, lsr r6
        0xE192B753, // orrs r11, r2, r3, asr r7
        0xE1D1C973, // bics r12, r1, r3, ror r9
        0xE1F04813, // mvns r4, r3, lsl r8
        0xEAFFFFFE, // b .
    };
    RunArm(program, regs, USER32MODE | CBIT);
    RunArm(program, regs, USER32MODE | VBIT);
    RunArm(program, regs, USER32MODE);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::
                        ArmLogicalRegisterShiftedRegisterSetFlagsNoPcAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: fused add/sub-immediate branch", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmAddSubImmediateSetFlagsBranchNoPcAlways)]
            .load();
#endif
    // Forward branch: taken skips the mov.
    const std::vector<u32> program = {
        0xE2915008, // subs r5, r1, #8
        0x0A000000, // beq +0 -> index 3
        0xE3A05000, // mov r5, #0
        0xE3A06007, // mov r6, #7
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[1] = 8; // subs -> 0 -> Z -> taken
    RunArm(program, regs);
    regs[1] = 9; // not taken
    RunArm(program, regs);

    // Self-loop chain variant: adds r4, r0, #1 until r4 wraps to 0.
    const std::vector<u32> loop = {
        0xE2904001, // adds r4, r0, #1
        0x1AFFFFFD, // bne -12 -> block start (index 0)
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs2 = BaseRegs();
    regs2[0] = 0xFFFFFF00; // exits after 256 iterations
    RunArm(loop, regs2, USER32MODE, 700);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmAddSubImmediateSetFlagsBranchNoPcAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: fused logical-register branch", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmLogicalRegisterSetFlagsBranchNoPcAlways)]
            .load();
#endif
    const std::vector<u32> program = {
        0xE0104003, // ands r4, r0, r3
        0x0A000000, // beq +0 -> index 3
        0xE3A04000, // mov r4, #0
        0xE3A06007, // mov r6, #7
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0x0; // ands -> 0 -> Z -> taken
    RunArm(program, regs);
    regs[0] = 0xFFFFFFFF; // not taken
    RunArm(program, regs);
    // C and V must feed the branch from the PRE-op guest flags (logical ops
    // preserve both): seed them explicitly.
    RunArm(program, regs, USER32MODE | CBIT | VBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmLogicalRegisterSetFlagsBranchNoPcAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: conditional VFP load/store", "[arm_asm]") {
    // Conditional vldr/vstr/vldd/vstrd/vldm/vstm decode to the generic
    // ArmVFPLoadStore op; the translator repacks them onto the unconditional
    // vlds/vldd/vldm bodies behind a guard record. rn==15 loads fold the
    // literal-pool address; page-crossing transfers still exit to C++.
    const auto run = [](const std::vector<u32>& program, std::array<u32, 15> regs) {
        Machine dyn(false), ir(true), ir_asm(true);
        static constexpr std::pair<u32, u32> data[] = {
            {0x1000, 0x11223344}, {0x1004, 0x55667788}, {0x1008, 0x99AABBCC},
            {0x100C, 0xDDEEFF00}, {0x1010, 0x0BADF00D}, {0x1014, 0x600D600D},
            {0x1018, 0x13572468}, {0x101C, 0x24681357}, {0x1020, 0xDEADBEEF},
            {0x1024, 0xCAFEBABE}, {0x1FF0, 0x11111111}, {0x1FF4, 0x22222222},
            {0x1FF8, 0x33333333}, {0x1FFC, 0x44444444},
        };
        for (Machine* m : {&dyn, &ir, &ir_asm}) {
            for (std::size_t i = 0; i < program.size(); ++i) {
                m->env.SetMemory32(static_cast<VAddr>(i * 4), program[i]);
            }
            for (const auto& [a, v] : data) {
                m->env.SetMemory32(a, v);
            }
            m->Seed(regs);
        }
        const u64 slice = program.size() + 8;
        dyn.RunInstructions(slice);
        ir.RunInstructions(slice);
        {
            AsmFlagGuard g;
            ir_asm.RunInstructions(slice);
        }
        Compare(ir, dyn);
        Compare(ir_asm, dyn);
        for (u32 addr : {0x1000U, 0x100CU, 0x1020U, 0x1024U, 0x1040U, 0x1FF0U}) {
            CAPTURE(addr);
            REQUIRE(ir_asm.env.GetMemory().Read32(addr) ==
                    dyn.env.GetMemory().Read32(addr));
        }
    };

#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmVFPLoadStore)]
            .load();
#endif

    // Z=1 path: EQ forms execute, NE forms skip; covers single, double and
    // multiple transfers plus IA/DB writeback.
    const std::vector<u32> taken = {
        0xE3A00005, // mov r0, #5
        0xE3500005, // cmp r0, #5   -> Z=1
        0x0D910A01, // vldreq s0,  [r1, #4]    -> s0 = 0x55667788
        0x1DD10A02, // vldrne s1,  [r1, #8]    skipped
        0x0D811A03, // vstreq s2,  [r1, #12]   -> [0x100C] = s2
        0x1DC12A05, // vstrne s5,  [r1, #20]   skipped
        0x0D914B06, // vldrdeq d4, [r1, #24]   -> d4 = {[0x1018],[0x101C]}
        0x1D816B08, // vstrdne d6, [r1, #32]   skipped
        0x0CB24A04, // vldmiaeq r2!, {s8-s11}  -> s8..s11, r2 += 16
        0x1CA38A04, // vstmneia r3!, {s16-s19} skipped
        0x0D34AB06, // vldmdbeq r4!, {d10-d12} -> s20..s25 = [0x1000..0x1014]
        0x1D25EB06, // vstmdbne r5!, {d14-d16} skipped
        0xED9FAA00, // vldr s20, [pc, #0]      cond=AL -> vlds_lit, reads the
                    //                           `b .` word (0xEAFFFFFE)
        0xE3A07042, // mov r7, #0x42
        0xEAFFFFFE, // b .
    };
    auto regs = BaseRegs();
    regs[2] = 0x1000;
    regs[3] = 0x1080;
    regs[4] = 0x1018;
    regs[5] = 0x1040;
    run(taken, regs);

    // Z=0 path: the complements execute instead.
    std::vector<u32> skipped = taken;
    skipped[1] = 0xE3500006; // cmp r0, #6 -> Z=0
    run(skipped, regs);

    // Cross-page multiple transfer -> MEMSLOW replay through C++.
    const std::vector<u32> cross_page = {
        0xE3A00001, // mov r0, #1
        0xE3500001, // cmp r0, #1   -> Z=1
        0x0CB6CA08, // vldmiaeq r6!, {s24-s31} 0x1FF0 + 32B crosses the page
        0xEAFFFFFE, // b .
    };
    regs[6] = 0x1FF0;
    run(cross_page, regs);

#if defined(__aarch64__)
    // The only op51 slow exit is the cross-page vldm in the third program
    // (the pc-literal vldr decodes to ArmVFPLoadSingleFast and counts under
    // that opcode). It is hit once per asm-enabled machine, and whether the
    // `ir` machine also runs asm depends on the global setting — so assert
    // the minimum.
    REQUIRE(Core::ARMAsm::g_asm_stats
                    .slow_op_counts[static_cast<size_t>(
                        Core::ARMIR::Opcode::ArmVFPLoadStore)]
                    .load() >=
            slow_before + 1);
#endif
}

TEST_CASE("ARM asm executor: conditional ldrd/strd", "[arm_asm]") {
    // Conditional ldrd/strd decode to ArmLoadStoreDouble; the translator
    // repacks immediate-offset forms onto the unconditional ldrd/strd bodies
    // behind a guard record. Register offsets, rd>=14, rn==15 bases and the
    // rn==rd/rd+1 writeback-aliasing forms stay slow. Page-crossing pairs
    // exit to C++ through MEMSLOW.
    const auto run = [](const std::vector<u32>& program, std::array<u32, 15> regs) {
        Machine dyn(false), ir(true), ir_asm(true);
        static constexpr std::pair<u32, u32> data[] = {
            {0x1000, 0x11223344}, {0x1004, 0x55667788}, {0x1008, 0x99AABBCC},
            {0x100C, 0xDDEEFF00}, {0x1010, 0x0BADF00D}, {0x1014, 0x600D600D},
            {0x1018, 0x13572468}, {0x101C, 0x24681357}, {0x1020, 0xDEADBEEF},
            {0x1024, 0xCAFEBABE}, {0x1FF0, 0x11111111}, {0x1FF4, 0x22222222},
            {0x1FF8, 0x33333333}, {0x1FFC, 0x44444444},
        };
        for (Machine* m : {&dyn, &ir, &ir_asm}) {
            for (std::size_t i = 0; i < program.size(); ++i) {
                m->env.SetMemory32(static_cast<VAddr>(i * 4), program[i]);
            }
            for (const auto& [a, v] : data) {
                m->env.SetMemory32(a, v);
            }
            m->Seed(regs);
        }
        const u64 slice = program.size() + 8;
        dyn.RunInstructions(slice);
        ir.RunInstructions(slice);
        {
            AsmFlagGuard g;
            ir_asm.RunInstructions(slice);
        }
        Compare(ir, dyn);
        Compare(ir_asm, dyn);
        for (u32 addr : {0x1004U, 0x1008U, 0x1088U, 0x108CU, 0x1040U, 0x1044U}) {
            CAPTURE(addr);
            REQUIRE(ir_asm.env.GetMemory().Read32(addr) ==
                    dyn.env.GetMemory().Read32(addr));
        }
    };

#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmLoadStoreDouble)]
            .load();
#endif

    // Z=1 path: EQ forms execute, NE forms skip. Covers pre-indexed plain,
    // pre-indexed writeback and post-indexed transfers.
    const std::vector<u32> taken = {
        0xE3A00005, // mov r0, #5
        0xE3500005, // cmp r0, #5   -> Z=1
        0x01E4A0D8, // ldrdeq r10, [r4, #8]!   -> r10=[0x1020] r11=[0x1024], r4=0x1020
        0x01C141D0, // ldrdeq r4, [r1, #16]    -> r4=[0x1010] r5=[0x1014]
        0x11C181DC, // ldrdne r8, [r1, #28]    skipped
        0x01C260F4, // strdeq r6, [r2, #4]     -> [0x1004]=r6 [0x1008]=r7
        0x11C380F8, // strdne r8, [r3, #8]     skipped
        0xEAFFFFFE, // b .
    };
    auto regs = BaseRegs();
    regs[1] = 0x1000;
    regs[2] = 0x1000;
    regs[3] = 0x1080;
    regs[4] = 0x1018;
    regs[5] = 0x1040;
    regs[6] = 0xA5A5A5A5;
    regs[7] = 0x5A5A5A5A;
    run(taken, regs);

    // Z=0 path: the NE forms execute instead (r8/r9 freshly loaded feed the
    // strdne store).
    std::vector<u32> skipped = taken;
    skipped[1] = 0xE3500006; // cmp r0, #6 -> Z=0
    run(skipped, regs);

    // Post-indexed strd (P=0 writeback always applies). DynCom crashes on the
    // P=0,W=1 encoding, so the canonical P=0,W=0 form is used here.
    const std::vector<u32> post = {
        0xE3A00005, // mov r0, #5
        0xE3500005, // cmp r0, #5   -> Z=1
        0x00C560FC, // strdeq r6, [r5], #12    -> [0x1040]=r6 [0x1044]=r7, r5=0x104C
        0x10C1A0F8, // strdne r10, [r1], #8    skipped
        0xEAFFFFFE, // b .
    };
    run(post, regs);

#if defined(__aarch64__)
    // All emitted forms run through the ldrd/strd handlers behind guard
    // records. A cold page-cache miss (MEMSLOW) may replay the first data
    // access through C++; all data sits in one page, so at most one exit.
    REQUIRE(Core::ARMAsm::g_asm_stats
                    .slow_op_counts[static_cast<size_t>(
                        Core::ARMIR::Opcode::ArmLoadStoreDouble)]
                    .load() <= slow_before + 1);
#endif
}

TEST_CASE("ARM asm executor: VFP literal loads", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_s_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmVFPLoadSingleFast)]
            .load();
    const auto slow_ls_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmVFPLoadStore)]
            .load();
#endif
    // rn==15 vldr/vldrd fold the literal address (Reg15&~3)+8 at translate
    // time; both the unconditional fast forms and the conditional generic
    // ArmVFPLoadStore encoding are covered. Trailing words are data read by
    // the loads, never executed.
    const std::vector<u32> program = {
        0xE3A00005, // mov r0, #5              @0
        0xE3500005, // cmp r0, #5    -> Z=1   @4
        0xED9F0A02, // vldr s0, [pc, #8]      @8  -> reads @24
        0xED9F5B03, // vldrd d5, [pc, #12]    @12 -> reads @32/@36
        0x0DDF1A05, // vldreq s3, [pc, #20]   @16 -> reads @44 (taken)
        0x1D9F2A00, // vldrne s4, [pc, #0]    @20 -> reads @28 (skipped)
        0xEAFFFFFE, // b .                    @24  -> s0 = 0xEAFFFFFE
        0xCAFEBABE, //                        @28  -> s4 on the NE path
        0xAABBCCDD, //                        @32  -> d5 low
        0x12345678, //                        @36  -> d5 high
        0xDEADBEEF, //                        @40
        0x55667788, //                        @44  -> s3
    };
    { // Z=1: EQ literal taken, NE skipped
        std::array<u32, 15> regs = BaseRegs();
        RunArm(program, regs);
    }
    { // Z=0: complements execute
        std::vector<u32> p2 = program;
        p2[1] = 0xE3500006; // cmp r0, #6 -> Z=0
        RunArm(p2, BaseRegs());
    }
#if defined(__aarch64__)
    // The literal loads must not count as slow exits on either opcode.
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmVFPLoadSingleFast)]
                .load() == slow_s_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmVFPLoadStore)]
                .load() == slow_ls_before);
#endif
}

TEST_CASE("ARM asm executor: VFP load/store multiple resident base", "[arm_asm]") {
    // vldm/vstm take rn from a0 bits 8-11 (nibble 2). The checkable mask must
    // veto residency when rn is a resident register: mov writes r2 only in
    // the host copy, so a stale regfile slot would feed the transfer base.
    const auto run = [](const std::vector<u32>& program, std::array<u32, 15> regs) {
        Machine dyn(false), ir(true), ir_asm(true);
        for (Machine* m : {&dyn, &ir, &ir_asm}) {
            for (std::size_t i = 0; i < program.size(); ++i) {
                m->env.SetMemory32(static_cast<VAddr>(i * 4), program[i]);
            }
            m->env.SetMemory32(0x40, 0x11112222);
            m->env.SetMemory32(0x44, 0x33334444);
            m->env.SetMemory32(0x1000, 0xAAAA0000);
            m->env.SetMemory32(0x1004, 0xBBBB0001);
            m->Seed(regs);
        }
        const u64 slice = program.size() + 8;
        dyn.RunInstructions(slice);
        ir.RunInstructions(slice);
        {
            AsmFlagGuard g;
            ir_asm.RunInstructions(slice);
        }
        Compare(ir, dyn);
        Compare(ir_asm, dyn);
        REQUIRE(ir_asm.cpu->GetVFPReg(8) == 0x11112222);
        REQUIRE(ir_asm.cpu->GetVFPReg(9) == 0x33334444);
    };

    // rn=r2: the block must stay non-resident; on the buggy mask it went
    // resident and vldm read the stale seeded Reg[2]=0x1000 instead of 0x40.
    const std::vector<u32> resident_base = {
        0xE3A00011, // mov r0, #0x11         resident family
        0xE3A02040, // mov r2, #0x40         resident (host-reg copy only)
        0xEC924A02, // vldmia r2, {s8-s9}    rn=2 <3 -> vetoes residency
        0xEAFFFFFE, // b .
    };
    auto regs = BaseRegs();
    regs[2] = 0x1000;
#if defined(__aarch64__)
    const auto res_before = Core::ARMAsm::g_asm_stats.resident_programs.load();
#endif
    run(resident_base, regs);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.resident_programs.load() == res_before);
#endif

    // rn=r5 >=3: resident-safe; the same program shape should mark resident
    // now that vldm/vstm and the single/double forms are classified.
    const std::vector<u32> file_base = {
        0xE3A00011, // mov r0, #0x11
        0xE3A05040, // mov r5, #0x40
        0xEC954A02, // vldmia r5, {s8-s9}    rn=5 -> resident-safe
        0xEAFFFFFE, // b .
    };
#if defined(__aarch64__)
    const auto res_before2 = Core::ARMAsm::g_asm_stats.resident_programs.load();
#endif
    run(file_base, regs);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.resident_programs.load() > res_before2);
#endif
}

TEST_CASE("ARM asm executor: shifted logical-immediate full matrix", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmLogicalShiftedRegisterNoPcAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // AND/EOR/ORR/BIC/MOV/MVN x LSL/LSR/ASR/ROR immediate shifts (op196).
    // Non-zero amounts only: lsr/asr #0 saturate to 32 and ror #0 is RRX --
    // those stay slow by design.
    const std::vector<u32> program = {
        0xE0040083, // and r4, r0, r3, lsl #1
        0xE02154C3, // eor r5, r1, r3, asr #9
        0xE1826123, // orr r6, r2, r3, lsr #2
        0xE1C072C3, // bic r7, r0, r3, asr #5
        0xE1A081A3, // mov r8, r3, lsl #3
        0xE1E09263, // mvn r9, r3, ror #4
        0xE001A8E3, // and r10, r1, r3, ror #17
        0xE182B323, // orr r11, r2, r3, lsr #6
        0xE020C143, // eor r12, r0, r3, asr #2
        0xE1A0D703, // mov r13, r3, lsl #14
        0xE1E0E2C3, // mvn r14, r3, asr #5
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0x0F0F0F0F;
    regs[1] = 0x12345678;
    regs[2] = 0xDEADBEEF;
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | CBIT | VBIT);
    RunArm(program, regs, USER32MODE | NBIT | ZBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmLogicalShiftedRegisterNoPcAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: mov register-shifted (no flags)", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmMoveRegisterShiftedRegisterAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // mov rd, rm, <shift> rs (op101): ARM clamps register shift amounts
    // >= 32, unlike AArch64's 5-bit masked variable shifts.
    std::array<u32, 15> regs = BaseRegs();
    regs[3] = 0x87654321;
    regs[5] = 0;   // amount 0 -> passthrough
    regs[6] = 33;  // lsr 33 -> 0
    regs[7] = 32;  // asr 32 -> sign-fill
    regs[8] = 40;  // ror 40 -> rotate 8
    regs[9] = 31;  // lsl 31
    const std::vector<u32> program = {
        0xE1A04513, // mov r4, r3, lsl r5   (amt 0 -> rm)
        0xE1A06633, // mov r6, r3, lsr r6   (amt 33 -> 0)
        0xE1A07753, // mov r7, r3, asr r7   (amt 32 -> sign)
        0xE1A08873, // mov r8, r3, ror r8   (amt 40 -> ror 8)
        0xE1A0A933, // mov r10, r3, lsl r9  (amt 31)
        0xEAFFFFFE, // b .
    };
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | CBIT | VBIT | NBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmMoveRegisterShiftedRegisterAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: logical register set-flags (no shift)",
          "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmLogicalRegisterSetFlagsNoPcAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // ands/eors/tst/teq/orrs/movs/bics/mvns rd, rn, rm (op169): N/Z from the
    // result, C and V carried over from the pre-op guest flags.
    const std::vector<u32> program = {
        0xE0104003, // ands r4, r0, r3
        0xE0305003, // eors r5, r1, r3
        0xE1100003, // tst r0, r3
        0xE1300003, // teq r1, r3
        0xE1906003, // orrs r6, r2, r3
        0xE1B07003, // movs r7, r3
        0xE1D08003, // bics r8, r0, r3
        0xE1F09003, // mvns r9, r3
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0xFF00FF00;
    regs[1] = 0x0F0F0F0F;
    regs[2] = 0x55555555;
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | CBIT | VBIT);
    RunArm(program, regs, USER32MODE | NBIT | ZBIT | CBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmLogicalRegisterSetFlagsNoPcAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: fused logical-immediate branch", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmLogicalImmediateSetFlagsBranchNoPcAlways)]
            .load();
#endif
    // ands + beq: taken skips the mov (op222 forward fusion).
    const std::vector<u32> program = {
        0xE21040F0, // ands r4, r0, #0xF0
        0x0A000000, // beq +0 -> index 3
        0xE3A04000, // mov r4, #0
        0xE3A06007, // mov r6, #7
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0xF0; // ands -> 0xF0 -> not taken -> r4 = 0
    RunArm(program, regs);
    regs[0] = 0; // ands -> 0 -> Z -> taken -> r4 stays 0
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | CBIT | VBIT);

    // Rotated immediates produce a constant shifter carry (from_c == 0);
    // unrotated ones preserve the guest C (from_c == 1). Exercise both.
    const std::vector<u32> carries = {
        0xE3905102, // orrs r5, r1, #0x80000000  (rot=1 -> C=1 const)
        0x1A000000, // bne +0 -> index 3
        0xE3A05000, // mov r5, #0
        0xE3A06007, // mov r6, #7
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs2 = BaseRegs();
    regs2[1] = 1; // orrs -> 0x80000001 -> not taken
    RunArm(carries, regs2);
    regs2[1] = 0x80000000; // orrs -> 0x80000000 -> N=1 -> not taken
    RunArm(carries, regs2, USER32MODE);

    // movs r7, #0 + beq: Z=1 always; from_c==1 keeps old C for the branch.
    const std::vector<u32> movs_prog = {
        0xE3B07000, // movs r7, #0
        0x0A000000, // beq +0 -> index 3
        0xE3A07001, // mov r7, #1
        0xE3A06007, // mov r6, #7
        0xEAFFFFFE, // b .
    };
    RunArm(movs_prog, BaseRegs());
    RunArm(movs_prog, BaseRegs(), USER32MODE | CBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmLogicalImmediateSetFlagsBranchNoPcAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: logical immediate set-flags", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmLogicalImmediateSetFlagsNoPcAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // ands/eors/tst/teq/orrs/movs/bics/mvns rd, rn, #imm (op168). Rotated
    // immediates feed a constant shifter carry; unrotated ones keep guest C.
    const std::vector<u32> program = {
        0xE21040F0, // ands r4, r0, #0xF0        (from_c: keeps C)
        0xE2315001, // eors r5, r1, #1
        0xE31000FF, // tst r0, #0xFF
        0xE3310080, // teq r1, #0x80
        0xE3926102, // orrs r6, r2, #0x80000000 (rot=1 -> C=1 const)
        0xE3B07CFF, // movs r7, #0xFF000000     (rot=12 -> C=1 const)
        0xE3D0800F, // bics r8, r0, #0xF
        0xE3F09000, // mvns r9, #0
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0xFF00FF00;
    regs[1] = 0x0F0F0F0F;
    regs[2] = 0x55555555;
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | CBIT | VBIT);
    RunArm(program, regs, USER32MODE | NBIT | ZBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmLogicalImmediateSetFlagsNoPcAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: logical register-shifted (no flags)",
          "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmLogicalRegisterShiftedRegisterNoPcAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // and/eor/orr/bic rd, rn, rm <shift> rs (op206). Flag-free handlers must
    // leave host NZCV untouched -- the RunArm CPSR compare catches leaks.
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0xFF00FF00;
    regs[1] = 0x12345678;
    regs[2] = 0x0F0F0F0F;
    regs[3] = 0x87654321;
    regs[5] = 0;   // amount 0 -> rm passthrough
    regs[6] = 33;  // lsr >= 32 -> 0
    regs[7] = 32;  // asr >= 32 -> sign-fill
    regs[8] = 40;  // ror 40 -> rotate 8
    const std::vector<u32> program = {
        0xE0004513, // and r4, r0, r3, lsl r5   (amt 0 -> rm)
        0xE0216633, // eor r6, r1, r3, lsr r6   (amt 33 -> 0)
        0xE1827753, // orr r7, r2, r3, asr r7   (amt 32 -> sign)
        0xE1C08873, // bic r8, r0, r3, ror r8   (amt 40 -> ror 8)
        0xE0219533, // eor r9, r1, r3, lsr r5   (amt 0 -> rm)
        0xEAFFFFFE, // b .
    };
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | CBIT | VBIT | NBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmLogicalRegisterShiftedRegisterNoPcAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: data-processing write to pc", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmDataProcessingRegisterAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // mov pc, lr and the other non-flag result->pc forms become computed
    // branches: the raw result is stored to Reg[15] and the chain probe
    // hashes pc & ~3 (ARM execution addresses are word-aligned).
    const std::vector<u32> call_return = {
        0xEB000001, // bl +12
        0xE3A00001, // mov r0, #1        <- return site
        0xEAFFFFFE, // b .
        0xE3A01007, // mov r1, #7        <- bl target
        0xE1A0F00E, // mov pc, lr        -> pc 4
    };
    RunArm(call_return, BaseRegs());
    RunArm(call_return, BaseRegs(), USER32MODE | CBIT | VBIT);

    // Computed targets: plain register, shifted register, and arithmetic
    // results. Each program jumps to the `mov r1,#4` at pc 20.
    RunArm({
               0xE3A05014, // mov r5, #20
               0xE1A0F005, // mov pc, r5        -> pc 20
               0xE3A00001, // mov r0, #1        (unreached)
               0xE3A00002, // mov r0, #2        (unreached)
               0xE3A00003, // mov r0, #3        (unreached)
               0xE3A01004, // mov r1, #4        <- pc 20 target
               0xEAFFFFFE, // b .
           },
           BaseRegs());
    // Odd register targets still execute the word-aligned ARM address.
    RunArm({
               0xE3A05015, // mov r5, #21
               0xE1A0F005, // mov pc, r5        -> 21 & ~3 = 20
               0xE3A00001, 0xE3A00002, 0xE3A00003,
               0xE3A01004, // mov r1, #4        <- pc 20
               0xEAFFFFFE, // b .
           },
           BaseRegs());
    // Shifted-register and arithmetic results writing pc.
    RunArm({
               0xE3A0200A, // mov r2, #10
               0xE1A0F082, // mov pc, r2, lsl #1 -> pc 20
               0xE3A00001, 0xE3A00002, 0xE3A00003,
               0xE3A01004, // mov r1, #4        <- pc 20
               0xEAFFFFFE, // b .
           },
           BaseRegs());
    RunArm({
               0xE3A03008, // mov r3, #8
               0xE3A0400C, // mov r4, #12
               0xE083F004, // add pc, r3, r4    -> pc 20
               0xE3A00001, 0xE3A00002,
               0xE3A01004, // mov r1, #4        <- pc 20
               0xEAFFFFFE, // b .
           },
           BaseRegs());
    RunArm({
               0xE3A0301C, // mov r3, #28
               0xE3A04008, // mov r4, #8
               0xE043F004, // sub pc, r3, r4    -> pc 20
               0xE3A00001, 0xE3A00002,
               0xE3A01004, // mov r1, #4        <- pc 20
               0xEAFFFFFE, // b .
           },
           BaseRegs());
    RunArm({
               0xE3A03010, // mov r3, #16
               0xE3A04004, // mov r4, #4
               0xE183F004, // orr pc, r3, r4    -> pc 20
               0xE3A00001, 0xE3A00002,
               0xE3A01004, // mov r1, #4        <- pc 20
               0xEAFFFFFE, // b .
           },
           BaseRegs());
    // ror#0 == rrx needs the carry-in path: the handler bails to MEMSLOW and
    // C++ executes the op. C is clear here so rrx(40) -> pc 20.
    RunArm({
               0xE3A02028, // mov r2, #40
               0xE1A0F062, // mov pc, r2, rrx   -> pc 20 (slow op +1)
               0xE3A00001, 0xE3A00002, 0xE3A00003,
               0xE3A01004, // mov r1, #4        <- pc 20
               0xEAFFFFFE, // b .
           },
           BaseRegs());
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    // The rrx bail fires once per asm-enabled engine; on OHOS the plain-IR
    // machine also runs asm, so only require the slow path was hit.
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmDataProcessingRegisterAlways)]
                .load() > slow_before);
#endif
}

TEST_CASE("ARM asm executor: conditional data-processing write to pc",
          "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmDataProcessingRegister)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // moveq pc, lr and friends: a failed condition skips the dp_pc record and
    // execution continues; a passed condition stores the result and probes
    // the chain table. Both flag outcomes run through the same program.
    const std::vector<u32> program = {
        0xEB000001, // bl +12
        0xE3A00001, // mov r0, #1        <- return site
        0xEAFFFFFE, // b .
        0xE3520000, // cmp r2, #0
        0x01A0F00E, // moveq pc, lr      -> pc 4 when r2==0
        0xE3A01007, // mov r1, #7        <- cond-fail path
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> taken = BaseRegs();
    taken[2] = 0; // Z=1 -> the conditional return fires
    RunArm(program, taken);
    RunArm(program, taken, USER32MODE | CBIT | VBIT);
    std::array<u32, 15> skipped = BaseRegs();
    skipped[2] = 1; // Z=0 -> moveq falls through to mov r1,#7
    RunArm(program, skipped);
    // movne pc, lr: inverted polarity exercises the other guard outcome.
    const std::vector<u32> program_ne = {
        0xEB000001, // bl +12
        0xE3A00001, // mov r0, #1        <- return site
        0xEAFFFFFE, // b .
        0xE3520000, // cmp r2, #0
        0x11A0F00E, // movne pc, lr      -> pc 4 when r2!=0
        0xE3A01007, // mov r1, #7        <- cond-fail path
        0xEAFFFFFE, // b .
    };
    RunArm(program_ne, skipped);
    RunArm(program_ne, taken);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmDataProcessingRegister)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: arithmetic register-shifted and pc operand",
          "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmDataProcessingRegisterAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // alu_regsh (unconditional): the specialized register-shifted arithmetic
    // opcodes route through the same handler. Amount==0 and >=32 edges are
    // exercised by the seeded rs values.
    const std::vector<u32> regsh = {
        0xE0404513, // sub  r4, r0, r3, lsl r5
        0xE0804533, // add  r4, r0, r3, lsr r5
        0xE0A15613, // adc  r5, r1, r3, lsl r6   (r6=33 -> lsl>=32 -> 0)
        0xE0C06653, // sbc  r6, r0, r3, asr r6   (asr>=32 -> sign)
        0xE0617513, // rsb  r7, r1, r3, lsl r5
        0xE0E08613, // rsc  r8, r0, r3, lsl r6
        0xE0404573, // sub  r4, r0, r3, ror r5
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0x80000001;
    regs[1] = 0x7FFFFFFF;
    regs[3] = 0x80000000;
    regs[5] = 4;
    regs[6] = 33;
    RunArm(regsh, regs);
    RunArm(regsh, regs, USER32MODE | CBIT);
    RunArm(regsh, regs, USER32MODE | NBIT | ZBIT | VBIT);
    // alu_regsh (conditional): guard + body for cond regshift ops (op9).
    // Mixed conditions exercise both guard outcomes across flag seeds.
    const std::vector<u32> regsh_cond = {
        0x00404513, // subeq  r4, r0, r3, lsl r5
        0x10804533, // addne  r4, r0, r3, lsr r5
        0xA0A15613, // adcge  r5, r1, r3, lsl r6
        0xB0C06653, // sbclt  r6, r0, r3, asr r6
        0x40617513, // rsbmi  r7, r1, r3, lsl r5
        0x50E08613, // rscpl  r8, r0, r3, lsl r6
        0x00404573, // subeq  r4, r0, r3, ror r5
        0xEAFFFFFE, // b .
    };
    RunArm(regsh_cond, regs);
    RunArm(regsh_cond, regs, USER32MODE | CBIT);
    RunArm(regsh_cond, regs, USER32MODE | NBIT | ZBIT | CBIT | VBIT);
    RunArm(regsh_cond, regs, USER32MODE | NBIT);
    // Zero shift amount -> operand2 = rm unshifted for every type.
    std::array<u32, 15> zero_amt = regs;
    zero_amt[5] = 0;
    zero_amt[6] = 0;
    RunArm(regsh, zero_amt);
    // alu_rm_pc: rm==15 reads the op's pc constant (op_pc + 8), not Reg[15].
    const std::vector<u32> pc_op = {
        0xE1A0000F, // mov r0, pc        -> 0+8
        0xE082100F, // add r1, r2, pc    -> r2 + 12
        0xE044300F, // sub r3, r4, pc    -> r4 - 16
        0xE186500F, // orr r5, r6, pc    -> r6 | 20
        0xE008700F, // and r7, r8, pc    -> r8 & 24
        0xE02A900F, // eor r9, r10, pc   -> r10 ^ 28
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> pregs = BaseRegs();
    pregs[2] = 0x100;
    pregs[4] = 0x200;
    pregs[6] = 0xFF;
    pregs[8] = 0x3F;
    pregs[10] = 0x55;
    RunArm(pc_op, pregs);
    RunArm(pc_op, pregs, USER32MODE | CBIT | VBIT);
    // Conditional pc operands (op9): guard + alu_rm_pc on both outcomes.
    const std::vector<u32> pc_cond = {
        0x01A0000F, // moveq  r0, pc
        0x1082100F, // addne  r1, r2, pc
        0xA044300F, // subge  r3, r4, pc
        0xEAFFFFFE, // b .
    };
    RunArm(pc_cond, pregs);
    RunArm(pc_cond, pregs, USER32MODE | ZBIT);
    RunArm(pc_cond, pregs, USER32MODE | NBIT | VBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmDataProcessingRegisterAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: tst/teq register and immediate", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_tst_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmTstRegisterNoShiftNoPcAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // tst/teq with plain-register and rotated-immediate operands. Immediate
    // forms carry a decode-time shifter carry (rot!=0 -> result bit31);
    // register forms must preserve the incoming C and V.
    const std::vector<u32> program = {
        0xE1100001, // tst r0, r1
        0xE1320003, // teq r2, r3
        0xE31400FF, // tst r4, #0xFF
        0xE3350103, // teq r5, #0xC0000000  (shifter carry = 1)
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0xFF00FF00;
    regs[1] = 0x0FF00FF0;
    regs[2] = 0x12345678;
    regs[3] = 0x89ABCDEF;
    regs[4] = 0x0000007E;
    regs[5] = 0x40000001;
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | CBIT | VBIT);
    RunArm(program, regs, USER32MODE | NBIT | ZBIT | CBIT);
    RunArm(program, regs, USER32MODE | VBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmTstRegisterNoShiftNoPcAlways)]
                .load() == slow_tst_before);
#endif
}

TEST_CASE("ARM asm executor: multiply set-flags and long forms",
          "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_mul_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmMultiply)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // muls/mlas set N=bit31 and Z, keeping C+V; umulls/smlals set N=bit63 and
    // Z on the 64-bit result. Conditional muls run guard + body.
    const std::vector<u32> program = {
        0xE0004390, // mul    r4, r0, r3
        0xE0104390, // muls   r4, r0, r3
        0xE0215390, // mla    r5, r0, r3, r1
        0xE0315390, // mlas   r5, r0, r3, r1
        0xE0976291, // umulls r6, r7, r1, r2   (rd_lo=6 rd_hi=7)
        0xE0F98493, // smlals r8, r9, r3, r4   (rd_lo=8 rd_hi=9)
        0xE0A76291, // umlal  r6, r7, r1, r2
        0x00006291, // muleq  r6, r1, r2
        0x10106291, // mulnes r6, r1, r2
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0x80000001;
    regs[1] = 0xFFFFFFFF;
    regs[2] = 0x00010000;
    regs[3] = 0x00000002;
    regs[4] = 3;
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | CBIT | VBIT);
    RunArm(program, regs, USER32MODE | NBIT | ZBIT);
    RunArm(program, regs, USER32MODE | ZBIT | CBIT | VBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmMultiply)]
                .load() == slow_mul_before);
#endif
}

TEST_CASE("ARM asm executor: conditional immediate data processing set-flags",
          "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmDataProcessingImmediate)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // Conditional flag-setting immediate ops: logical writers reuse the
    // logimm_s body (carry repacked from arg1), tst/teq keep rd untouched,
    // rsbs/rscs use reversed-operand bodies. #0x80000000 exercises the
    // rotated-immediate shifter-carry path; the plain imm8 ops take the
    // carry-from-old-C path.
    const std::vector<u32> program = {
        0x021040FF, // andseq r4, r0, #0xFF
        0x223150F0, // eorcs  r5, r1, #0xF0
        0x1392600F, // orrne  r6, r2, #0x0F
        0x43D37003, // bicmi  r7, r3, #0x03
        0x03B08080, // movseq r8, #0x80
        0x13F09001, // mvnne  r9, #0x01
        0x031000FF, // tsteq  r0, #0xFF
        0x13310001, // teqne  r1, #0x01
        0x22704010, // rsbscs r4, r0, #0x10
        0x02B150F0, // adcseq r5, r1, #0xF0
        0x12D2600F, // sbcsne r6, r2, #0x0F
        0x42F37001, // rscsmi r7, r3, #0x01
        0x32104102, // andscc r4, r0, #0x80000000
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0xFF00FF00;
    regs[1] = 0x0F0F0F0F;
    regs[2] = 0x80000001;
    regs[3] = 0x12345678;
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | ZBIT);
    RunArm(program, regs, USER32MODE | NBIT | CBIT);
    RunArm(program, regs, USER32MODE | CBIT | VBIT);
    RunArm(program, regs, USER32MODE | NBIT | ZBIT | CBIT | VBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmDataProcessingImmediate)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: count leading zeros", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmCountLeadingZeros)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // clz rd, rm writes the leading-zero count without touching flags.
    // Conditional forms run guard + body on both pass and fail sides.
    const std::vector<u32> program = {
        0xE16F4F10, // clz   r4, r0   (0 -> 32)
        0xE16F5F11, // clz   r5, r1   (1 -> 31)
        0xE16F6F12, // clz   r6, r2   (0x80000000 -> 0)
        0xE16F7F13, // clz   r7, r3   (0x00F00000 -> 8)
        0xE16F1F14, // clz   r1, r4   (in-place chain)
        0x016F8F11, // clzeq r8, r1
        0x116F9F12, // clzne r9, r2
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0x00000000;
    regs[1] = 0x00000001;
    regs[2] = 0x80000000;
    regs[3] = 0x00F00000;
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | ZBIT);
    RunArm(program, regs, USER32MODE | NBIT | CBIT | VBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmCountLeadingZeros)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: immediate carry arithmetic set-flags",
          "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmArithmeticImmediateSetFlagsNoPcAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // Unconditional rsbs/adcs/sbcs/rscs rd, rn, #imm -- the full NZCV is
    // rewritten by the host flag-setting ALU ops. rsbs/rscs compute imm-rn.
    const std::vector<u32> program = {
        0xE2704010, // rsbs r4, r0, #0x10
        0xE2B150F0, // adcs r5, r1, #0xF0
        0xE2D2600F, // sbcs r6, r2, #0x0F
        0xE2F37001, // rscs r7, r3, #0x01
        0xE2D18000, // sbcs r8, r1, #0x00
        0xE2B09001, // adcs r9, r0, #0x01
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0x80000000;
    regs[1] = 0x7FFFFFFF;
    regs[2] = 0x00000000;
    regs[3] = 0xFFFFFFFF;
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | CBIT | VBIT);
    RunArm(program, regs, USER32MODE | NBIT | ZBIT);
    RunArm(program, regs, USER32MODE | ZBIT | CBIT | VBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmArithmeticImmediateSetFlagsNoPcAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: immediate carry arithmetic", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmArithmeticImmediateNoPcAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // Unconditional adc/sbc/rsc rd, rn, #imm -- read guest carry-in, write no
    // flags. Includes a rotated immediate (0x100 = imm8 1 ROR 8).
    const std::vector<u32> program = {
        0xE2A040FF, // adc r4, r0, #0xFF
        0xE2C15010, // sbc r5, r1, #0x10
        0xE2E260F0, // rsc r6, r2, #0xF0
        0xE2A37401, // adc r7, r3, #0x100
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0x00000010;
    regs[1] = 0x80000000;
    regs[2] = 0x00000020;
    regs[3] = 0x7FFFFFFF;
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | CBIT);
    RunArm(program, regs, USER32MODE | NBIT | ZBIT | VBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmArithmeticImmediateNoPcAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: addsub register set-flags + branch", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmAddSubRegisterSetFlagsBranchNoPcAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // Self-loop fused pair: subs + bne back to the block start exercises the
    // *chain handler family (taken pc == block.start_pc).
    const std::vector<u32> loop = {
        0xE0522003, // subs r2, r2, r3   @0
        0x1AFFFFFD, // bne @0            @4
        0xEAFFFFFE, // b .              @8 (reached when the loop falls out)
    };
    // Cross-block fused pair: the bne target @12 is a different block, so the
    // taken path uses the resolved-target (non-chain) handler family.
    const std::vector<u32> cross = {
        0xE0522003, // subs r2, r2, r3   @0
        0x1A000000, // bne @12           @4
        0xEAFFFFFE, // b .              @8  (fell out of the loop)
        0xE0904001, // adds r4, r0, r1   @12
        0xEAFFFFFA, // b @0              @16
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0x7FFFFFFF;
    regs[1] = 0x00000001;
    regs[2] = 0x00000030;
    regs[3] = 0x00000010;
    RunArm(loop, regs);
    RunArm(cross, regs);
    RunArm(loop, regs, USER32MODE | CBIT | VBIT);
    RunArm(cross, regs, USER32MODE | NBIT | ZBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmAddSubRegisterSetFlagsBranchNoPcAlways)]
            .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: compare shifted register + branch", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmCompareShiftedRegisterBranchNoPcAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // cmp rn, rm, lsr #n fused with a conditional branch; the branch target is
    // a different block so the resolved-target (non-chain) handlers run.
    const std::vector<u32> cross = {
        0xE0522003, // subs r2, r2, r3      @0
        0xE1520224, // cmp r2, r4, lsr #4   @4
        0x0A000000, // beq @16              @8
        0xEAFFFFFB, // b @0                @12
        0xEAFFFFFE, // b .                 @16
    };
    // Self-loop fused pair: cmp + bne back to the block start selects the
    // *chain handlers; r2 is seeded so the loop exits after two passes.
    const std::vector<u32> loop = {
        0xE0522003, // subs r2, r2, r3      @0
        0xE1520105, // cmp r2, r5, lsl #2   @4
        0x1AFFFFFC, // bne @0               @8
        0xEAFFFFFE, // b .                 @12
    };
    // cmn + cond-false path of the chain handler.
    const std::vector<u32> cmn = {
        0xE1720105, // cmn r2, r5, lsl #2   @0
        0x0AFFFFFD, // beq @0               @4
        0xEAFFFFFE, // b .                 @8
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[2] = 0x00000040;
    regs[3] = 0x00000010;
    regs[4] = 0x00000200; // r4>>4 == 0x20 -> cross exits when r2 reaches 0x20
    regs[5] = 0x00000008; // r5<<2 == 0x20 -> loop exits when r2 reaches 0x20
    RunArm(cross, regs);
    RunArm(loop, regs);
    RunArm(cmn, regs);
    RunArm(cross, regs, USER32MODE | CBIT | VBIT);
    RunArm(loop, regs, USER32MODE | NBIT | ZBIT);
    RunArm(cmn, regs, USER32MODE | CBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmCompareShiftedRegisterBranchNoPcAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: carry arithmetic shifted-register set-flags + "
          "branch",
          "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::
                    ArmCarryArithmeticShiftedRegisterSetFlagsBranchNoPcAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // Self-loop fused pair: sbcs (shifted operand) + bpl back to the block
    // start selects the *chain handlers; r3>>3 == 8 drains r2 into the
    // negative range in ~8 iterations.
    const std::vector<u32> loop = {
        0xE0D221A3, // sbcs r2, r2, r3, lsr #3  @0
        0x5AFFFFFD, // bpl @0                   @4
        0xEAFFFFFE, // b .                     @8
    };
    // Cross-block fused pair: adcs + bmi to a different block exercises the
    // resolved-target (non-chain) handlers, taken on the first pass.
    const std::vector<u32> cross = {
        0xE0B042C3, // adcs r4, r0, r3, asr #5  @0
        0x4A000000, // bmi @12                  @4
        0xEAFFFFFC, // b @0                    @8
        0xE0905001, // adds r5, r0, r1         @12
        0xEAFFFFFE, // b .                     @16
    };
    // rrx through the same fused path; the RRX operand and the adc carry-in
    // both consume the live C flag. beq is taken with C=1, not taken with
    // C=0 -- both exits terminate.
    const std::vector<u32> rrx = {
        0xE0B04061, // adcs r4, r0, r1, rrx     @0
        0x0A000000, // beq @12                  @4
        0xEAFFFFFE, // b .                     @8
        0xEAFFFFFE, // b .                     @12
    };
    // rscs fused pair (ror operand), bmi taken on the first pass.
    const std::vector<u32> rsc = {
        0xE0F22263, // rscs r2, r2, r3, ror #4  @0
        0x4A000000, // bmi @12                  @4
        0xEAFFFFFC, // b @0                    @8
        0xE0905001, // adds r5, r0, r1         @12
        0xEAFFFFFE, // b .                     @16
    };
    // rsbs fused pair, bpl taken (result is positive).
    const std::vector<u32> rsb = {
        0xE07171A3, // rsbs r7, r1, r3, lsr #3  @0
        0x5A000000, // bpl @12                  @4
        0xEAFFFFFE, // b .                     @8
        0xEAFFFFFE, // b .                     @12
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0x7FFFFFFF;
    regs[1] = 0x00000001;
    regs[2] = 0x00000040;
    regs[3] = 0x00000040;
    RunArm(loop, regs);
    RunArm(loop, regs, USER32MODE, 100);
    RunArm(cross, regs, USER32MODE | CBIT, 100);
    RunArm(rrx, regs, USER32MODE | CBIT, 100);
    RunArm(rsc, regs, USER32MODE, 100);
    RunArm(rsb, regs, USER32MODE, 100);
    RunArm(loop, regs, USER32MODE | CBIT | VBIT, 100);
    RunArm(cross, regs, USER32MODE | NBIT | ZBIT, 100);
    RunArm(rrx, regs, USER32MODE, 100);
    RunArm(rsb, regs, USER32MODE | CBIT, 100);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::
                    ArmCarryArithmeticShiftedRegisterSetFlagsBranchNoPcAlways)]
            .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: logical register-shifted set-flags + branch",
          "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::
                    ArmLogicalRegisterShiftedRegisterSetFlagsBranchNoPcAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // Self-loop fused pair: ands (register-shifted operand) + bne back to the
    // block start selects the *chain handlers; r3>>r5 keeps r2 nonzero for a
    // few passes until the result drains to zero.
    const std::vector<u32> loop = {
        0xE0122533, // ands r2, r2, r3, lsr r5  @0
        0x1AFFFFFD, // bne @0                   @4
        0xEAFFFFFE, // b .                     @8
    };
    // Cross-block fused pair: eors + bmi to a different block exercises the
    // resolved-target (non-chain) handlers.
    const std::vector<u32> cross = {
        0xE0304553, // eors r4, r0, r3, asr r5  @0
        0x4A000000, // bmi @12                 @4
        0xEAFFFFFC, // b @0                    @8
        0xE0905001, // adds r5, r0, r1         @12
        0xEAFFFFFE, // b .                     @16
    };
    // rs == 0: operand = rm unshifted and the shifter carry falls back to the
    // live C flag -- exercised with C both set and clear.
    const std::vector<u32> rs0 = {
        0xE1926513, // orrs r6, r2, r3, lsl r5  @0   (r5 == 0)
        0x2A000000, // bcs @12                  @4
        0xEAFFFFFC, // b @0                     @8
        0xE0905001, // adds r5, r0, r1          @12
        0xEAFFFFFE, // b .                      @16
    };
    // ror with rs % 32 == 0: operand = rm, carry = rm bit31.
    const std::vector<u32> ror0 = {
        0xE1D27573, // bics r7, r2, r3, ror r5  @0   (r5 == 32)
        0x5A000000, // bpl @12                  @4
        0xEAFFFFFC, // b @0                     @8
        0xE0905001, // adds r5, r0, r1          @12
        0xEAFFFFFE, // b .                      @16
    };
    // mvn path plus asr with rs >= 32 (sign-fill, carry = rm bit31).
    const std::vector<u32> mvn_asr32 = {
        0xE1F08533, // mvns r8, r3, lsr r5      @0
        0xE0129553, // ands r9, r2, r3, asr r5  @4   (r5 >= 32)
        0x6A000000, // bvs @16                  @8
        0xEAFFFFFB, // b @0                     @12
        0xEAFFFFFE, // b .                      @16
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[0] = 0x00000001;
    regs[2] = 0xFF00FF00;
    regs[3] = 0x8F0F0F0F;
    regs[5] = 0x00000004;
    RunArm(loop, regs);
    RunArm(cross, regs, USER32MODE | CBIT | VBIT, 100);
    RunArm(rs0, regs, USER32MODE | CBIT, 100);
    {
        auto r0 = regs;
        r0[5] = 0;
        RunArm(rs0, r0);
        RunArm(rs0, r0, USER32MODE | CBIT);
    }
    {
        auto r32 = regs;
        r32[5] = 32;
        RunArm(ror0, r32);
        RunArm(mvn_asr32, r32, USER32MODE | VBIT);
    }
    RunArm(loop, regs, USER32MODE | NBIT | ZBIT, 100);
    RunArm(cross, regs, USER32MODE, 100);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::
                    ArmLogicalRegisterShiftedRegisterSetFlagsBranchNoPcAlways)]
            .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: logical shifted-register set-flags",
          "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_lsl_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::
                    ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysLsl)]
            .load();
    const auto slow_ror_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::
                    ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysRor)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // All four shift specializations plus the imm==0 forms (lsl#0 keeps the
    // old C, lsr/asr #0 mean #32, ror#0 is RRX) and shifter-carry output.
    const std::vector<u32> program = {
        0xE0124103, // ands r4, r2, r3, lsl #2   @0
        0xE03251A3, // eors r5, r2, r3, lsr #3   @4
        0xE1926243, // orrs r6, r2, r3, asr #4   @8
        0xE1D272E3, // bics r7, r2, r3, ror #5   @12
        0xE0128003, // ands r8, r2, r3, lsl #0   @16
        0xE0129023, // ands r9, r2, r3, lsr #32  @20
        0xE012A043, // ands r10, r2, r3, asr #32 @24
        0xE012B063, // ands r11, r2, r3, rrx     @28
        0xEAFFFFFE, // b .                       @32
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[2] = 0xFF00FF00;
    regs[3] = 0x8F0F0F0F;
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | CBIT | VBIT);
    RunArm(program, regs, USER32MODE | NBIT | ZBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::
                    ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysLsl)]
            .load() == slow_lsl_before);
    REQUIRE(
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::
                    ArmLogicalShiftedRegisterSetFlagsNoPcAlwaysRor)]
            .load() == slow_ror_before);
#endif
}

TEST_CASE("ARM asm executor: carry arithmetic shifted-register set-flags",
          "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::
                    ArmArithmeticShiftedRegisterSetFlagsNoPcAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    const std::vector<u32> program = {
        0xE0B24103, // adcs r4, r2, r3, lsl #2   @0
        0xE0D251A3, // sbcs r5, r2, r3, lsr #3   @4
        0xE0F26263, // rscs r6, r2, r3, ror #4   @8
        0xE07272C3, // rsbs r7, r2, r3, asr #5   @12
        0xE0B28063, // adcs r8, r2, r3, rrx      @16
        0xE0D29023, // sbcs r9, r2, r3, lsr #32  @20
        0xEAFFFFFE, // b .                       @24
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[2] = 0x7F00FF00;
    regs[3] = 0x8F0F0F0F;
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | CBIT | VBIT);
    RunArm(program, regs, USER32MODE | NBIT | ZBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::
                    ArmArithmeticShiftedRegisterSetFlagsNoPcAlways)]
            .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: shifted-register compare", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmCompareShiftedRegisterNoPcAlways)]
            .load();
    const auto cmn_slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmCompareNegativeShiftedRegisterNoPcAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // Standalone cmp/cmn rn, rm, <shift> #imm covering lsl/lsr/asr/ror plus
    // the #0 special forms (lsr#32, asr#32, rrx -- the last reads guest C).
    const std::vector<u32> program = {
        0xE1520103, // cmp r2, r3, lsl #2
        0xE1520223, // cmp r2, r3, lsr #4
        0xE15202C3, // cmp r2, r3, asr #5
        0xE1520363, // cmp r2, r3, ror #6
        0xE1520063, // cmp r2, r3, rrx
        0xE1520023, // cmp r2, r3, lsr #32
        0xE1720103, // cmn r2, r3, lsl #2
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[2] = 0x80000040;
    regs[3] = 0x00001008;
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | CBIT);
    RunArm(program, regs, USER32MODE | NBIT | ZBIT | VBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmCompareShiftedRegisterNoPcAlways)]
                .load() == slow_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmCompareNegativeShiftedRegisterNoPcAlways)]
                .load() == cmn_slow_before);
#endif
}

TEST_CASE("ARM asm executor: pc-relative add/sub immediate", "[arm_asm]") {
#if defined(__aarch64__)
    const auto add_slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmAddImmediateAlways)]
            .load();
    const auto sub_slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmSubImmediateAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // add/sub rd, pc, #imm -- the rn==15 forms keep the *Always opcode.
    // Results fold to pc+8-constant moves; results are compared against the
    // reference engines so the constant math is verified directly.
    const std::vector<u32> program = {
        0xE28F40FF, // add r4, pc, #0xFF    @0
        0xE28F5401, // add r5, pc, #0x100   @4 (rotated immediate)
        0xE24F6080, // sub r6, pc, #0x80    @8
        0xE24F7040, // sub r7, pc, #0x40    @12
        0xEAFFFFFE, // b .                  @16
    };
    std::array<u32, 15> regs = BaseRegs();
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | CBIT | VBIT);
    RunArm(program, regs, USER32MODE | NBIT | ZBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmAddImmediateAlways)]
                .load() == add_slow_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmSubImmediateAlways)]
                .load() == sub_slow_before);
#endif
}

TEST_CASE("ARM asm executor: pc-operand register/logical forms", "[arm_asm]") {
#if defined(__aarch64__)
    const auto mov_slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmMoveRegisterAlways)]
            .load();
    const auto add_slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmAddRegisterAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // PC-operand forms: mov/add/sub/logical with rn or rm == 15, plus the
    // shifted-operand variants -- all fold the pc constant at translate time.
    const std::vector<u32> program = {
        0xE1A0400F, // mov r4, pc                @0
        0xE1A0518F, // mov r5, pc, lsl #3        @4
        0xE08F6003, // add r6, pc, r3            @8
        0xE082700F, // add r7, r2, pc            @12
        0xE04F8003, // sub r8, pc, r3            @16
        0xE042900F, // sub r9, r2, pc            @20
        0xE20FA0FF, // and r10, pc, #0xFF        @24
        0xE22FB401, // eor r11, pc, #0x100       @28
        0xE082C12F, // add r12, r2, pc, lsr #2   @32
        0xE042D24F, // sub r13, r2, pc, asr #4   @36
        0xEAFFFFFE, // b .                       @40
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[2] = 0x12345678;
    regs[3] = 0x00000F0F;
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | CBIT | VBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmMoveRegisterAlways)]
                .load() == mov_slow_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmAddRegisterAlways)]
                .load() == add_slow_before);
#endif
}

TEST_CASE("ARM asm executor: conditional literal loads", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmLoadStoreImmediate)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // Conditional literal-pool loads (rn==15) fold the address at translate
    // time. Trailing words are data the ldr reads, never executed.
    const std::vector<u32> program = {
        0xE3500000, // cmp r0, #0            @0
        0x059F300C, // ldreq r3, [pc, #12]  @4  -> reads @24
        0x159F4010, // ldrne r4, [pc, #16]  @8  -> reads @32
        0x45DF5008, // ldrbmi r5, [pc, #8]  @12 -> reads @28
        0xEAFFFFFE, // b .                  @16
        0x11223344, //                      @20 (data)
        0x55667788, //                      @24 (data)
        0xDEADBEEF, //                      @28 (data)
        0xAABBCCDD, //                      @32 (data)
    };
    {
        std::array<u32, 15> regs = BaseRegs(); // r0=0 -> EQ set
        RunArm(program, regs);
    }
    {
        std::array<u32, 15> regs = BaseRegs();
        regs[0] = 1; // r0=1 -> NE set
        RunArm(program, regs, USER32MODE | CBIT | VBIT);
    }
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmLoadStoreImmediate)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: movs/mvns register", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmMoveRegisterSetFlagsAlways)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // movs/mvns rd, rm update N/Z and keep C/V. Exercise both with seeds
    // whose low bit / top bit combinations flip N and Z each way.
    const std::vector<u32> program = {
        0xE1B04001, // movs r4, r1
        0xE1E05002, // mvns r5, r2
        0xE1B06003, // movs r6, r3
        0xE1E07004, // mvns r7, r4
        0xE1B01001, // movs r1, r1
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[1] = 0x80000000;
    regs[2] = 0xFFFFFFFF;
    regs[3] = 0x00000000;
    regs[4] = 0x00000001;
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | CBIT | VBIT);
    RunArm(program, regs, USER32MODE | NBIT | ZBIT);
    RunArm(program, regs, USER32MODE | ZBIT | CBIT | VBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmMoveRegisterSetFlagsAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: extend and reverse", "[arm_asm]") {
#if defined(__aarch64__)
    const auto slow_ext_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmExtend)]
            .load();
    const auto slow_rev_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmReverse)]
            .load();
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
#endif
    // uxtb/uxth/sxtb/sxth with rotate variants plus rev/rev16/revsh.
    // Conditional forms run guard + body on both sides.
    const std::vector<u32> program = {
        0xE6EF1071, // uxtb   r1, r1
        0xE6FF2072, // uxth   r2, r2
        0xE6AF3073, // sxtb   r3, r3
        0xE6BF4074, // sxth   r4, r4
        0xE6EF5475, // uxtb   r5, r5, ror #8
        0xE6AF6876, // sxtb   r6, r6, ror #16
        0xE6BF8C77, // sxth   r8, r7, ror #24
        0x06EF9079, // uxtbeq r9, r9
        0x16FF107A, // uxthne r1, r10
        0xEAFFFFFE, // b .
    };
    // rev forms: rev r11, r1 / rev16 r12, r2 / revsh r13, r3
    const std::vector<u32> rev_program = {
        0xE6BFBF31, // rev    r11, r1
        0xE6BFCFB2, // rev16  r12, r2
        0xE6FFDFB3, // revsh  r13, r3
        0x06BFEF34, // reveq  r14, r4
        0xEAFFFFFE, // b .
    };
    std::array<u32, 15> regs = BaseRegs();
    regs[1] = 0x12345678;
    regs[2] = 0x89ABCDEF;
    regs[3] = 0x0000FF80;
    regs[4] = 0xA5A5A5A5;
    regs[5] = 0x0000007F;
    regs[6] = 0x00800000;
    regs[7] = 0xFF00FF80;
    regs[9] = 0x000000EE;
    regs[10] = 0x00001234;
    RunArm(program, regs);
    RunArm(program, regs, USER32MODE | ZBIT);
    RunArm(rev_program, regs);
    RunArm(rev_program, regs, USER32MODE | NBIT | CBIT | VBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmExtend)]
                .load() == slow_ext_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmReverse)]
                .load() == slow_rev_before);
#endif
}

TEST_CASE("ARM asm executor: movs/mvns immediate set-flags", "[arm_asm]") {
#if defined(__aarch64__)
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
    const auto slow_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmMoveImmediateSetFlagsAlways)]
            .load();
#endif
    const std::vector<u32> program = {
        0xE3B000FF, // movs r0, #0xFF          rot==0 -> C preserved
        0xE3B01102, // movs r1, #0x80000000    rot!=0 -> C=bit31=1, N=1
        0xE3F03000, // mvns r3, #0             -> 0xFFFFFFFF, N=1
        0xE3F040FF, // mvns r4, #0xFF          -> 0xFFFFFF00, N=1
        0xE2A05000, // adc  r5, r5, #0         reads C left by movs r1
        0xE2B06001, // adcs r6, r6, #1         reads C left by mvns r4
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());
    // movs with rotation==0 must preserve C; rotated forms overwrite it.
    for (u32 cpsr_base : {0x00000000U, 0x20000000U, 0xF0000000U, 0x80000000U}) {
        RunArm(program, BaseRegs(), USER32MODE | cpsr_base);
    }
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmMoveImmediateSetFlagsAlways)]
                .load() == slow_before);
#endif
}

TEST_CASE("ARM asm executor: register-offset writeback load/store", "[arm_asm]") {
#if defined(__aarch64__)
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
    const auto slow_wb_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmStoreWordRegisterWriteback)]
            .load();
    const auto slow_ls_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmLoadStoreRegister)]
            .load();
#endif
    // rn=1 (0x1000), rm=2 (4). Offsets keep accesses inside the checked
    // data page; several land on addresses Compare() reads back.
    const std::vector<u32> program = {
        0xE7A13002, // str   r3, [r1, r2, lsl #0]!  [0x1004]=r3,    r1=0x1004
        0xE7314002, // ldr   r4, [r1, -r2]!         [0x1000] -> r4, r1=0x1000
        0xE6C15002, // strb  r5, [r1], r2           [0x1000]=r5,    r1=0x1004
        0xE6516002, // ldrb  r6, [r1], -r2          [0x1004] -> r6, r1=0x1000
        0xE1B170B2, // ldrh  r7, [r1, r2]!          [0x1004] -> r7, r1=0x1004
        0xE09180B2, // strh  r8, [r1], r2           [0x1004]=r8h,   r1=0x1008
        0xE01190F2, // ldrsh r9, [r1], -r2          s16[0x1008]->r9,r1=0x1004
        0xE1B1A0D2, // ldrsb r10,[r1, r2]!          s8[0x1008]->r10,r1=0x1008
        0x17A1B082, // strne r11,[r1, r2, lsl #1]!  [0x1010]=r11 when Z=0
        0x07A1C002, // streq r12,[r1, r2, lsl #0]!  [0x100C]=r12 when Z=1
        0xE3500000, // cmp   r0, #0
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());
    RunArm(program, BaseRegs(), USER32MODE | ZBIT);
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmStoreWordRegisterWriteback)]
                .load() == slow_wb_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmLoadStoreRegister)]
                .load() == slow_ls_before);
#endif
}

TEST_CASE("ARM asm executor: register set-flags carry/shifted arithmetic", "[arm_asm]") {
#if defined(__aarch64__)
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
    const auto slow_car_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmArithmeticRegisterSetFlagsNoPcAlways)]
            .load();
    const auto slow_addsh_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmAddShiftedRegisterSetFlagsNoPcAlways)]
            .load();
    const auto slow_movrs_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(
                Core::ARMIR::Opcode::ArmMoveRegisterShiftedRegisterSetFlagsAlways)]
            .load();
#endif
    const std::vector<u32> program = {
        0xE3A00001, // mov   r0, #1
        0xE0B13000, // adcs  r3, r1, r0         (op173: adc reg, S)
        0xE0D34000, // sbcs  r4, r3, r0
        0xE0765002, // rsbs  r5, r6, r2
        0xE0F87009, // rscs  r7, r8, r9
        0xE0910182, // adds  r0, r1, r2, lsl #3  (op193)
        0xE0565227, // subs  r5, r6, r7, lsr #4  (op194)
        0xE099804A, // adds  r8, r9, r10, asr #0 (ASR #32 corner)
        0xE05CB065, // subs  r11,r12, r5, ror #0 (RRX consumes C)
        0xE0900021, // adds  r0, r0, r1, lsr #0  (LSR #32 corner)
        0xE1B00211, // movs  r0, r1, lsl r2      (op102: movs reg-shift)
        0xE1B03654, // movs  r3, r4, asr r6
        0xEAFFFFFE, // b .
    };
    RunArm(program, BaseRegs());
    for (u32 cpsr_base : {0x00000000U, 0x20000000U, 0xF0000000U, 0x80000000U}) {
        RunArm(program, BaseRegs(), USER32MODE | cpsr_base);
    }
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmArithmeticRegisterSetFlagsNoPcAlways)]
                .load() == slow_car_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmAddShiftedRegisterSetFlagsNoPcAlways)]
                .load() == slow_addsh_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmMoveRegisterShiftedRegisterSetFlagsAlways)]
                .load() == slow_movrs_before);
#endif
}

// ldr pc, [rn, rm] — jump-table / pop-pc forms of ArmLoadStoreRegister with
// rd == 15. Covers unconditional, writeback, shifted and conditional
// register-offset forms, plus a target that flips TFlag (must bail to C++
// mid-record before any guest write).
TEST_CASE("ARM asm executor: register-offset loads to pc", "[arm_asm]") {
#if defined(__aarch64__)
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
    const auto slow_lsr_before =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmLoadStoreRegister)]
            .load();
#endif
    // mem[0x1400] = 0x14; ldr pc, [r1, r2] jumps to 0x14 in ARM state.
    RunArm(
        {
            0xE3A00014, // mov r0, #0x14
            0xE5810000, // str r0, [r1]
            0xE791F002, // ldr pc, [r1, r2]
            0xE3A03011, // mov r3, #0x11 (unreached)
            0xE3A03022, // mov r3, #0x22 (unreached)
            0xE3A03033, // mov r3, #0x33
            0xEAFFFFFE, // b .
        },
        {0, 0x1400, 0});
    // Post-indexed writeback: ldr pc, [r1], r2 — rn ends at base+offset.
    RunArm(
        {
            0xE3A00018, // mov r0, #0x18
            0xE5810000, // str r0, [r1]
            0xE691F002, // ldr pc, [r1], r2
            0xE3A03011, // mov r3, #0x11 (unreached)
            0xE3A03022, // mov r3, #0x22 (unreached)
            0xE3A03033, // mov r3, #0x33 (unreached)
            0xE3A03044, // mov r3, #0x44
            0xEAFFFFFE, // b .
        },
        {0, 0x1400, 0x400}); // r2 = 0x400 lands writeback at 0x1800
    // Pre-indexed shifted writeback: ldr pc, [r1, r2, lsl #2]!
    RunArm(
        {
            0xE3A00014, // mov r0, #0x14
            0xE5810000, // str r0, [r1]
            0xE7B1F102, // ldr pc, [r1, r2, lsl #2]!
            0xE3A03011, // mov r3, #0x11 (unreached)
            0xE3A03022, // mov r3, #0x22 (unreached)
            0xE3A03033, // mov r3, #0x33
            0xEAFFFFFE, // b .
        },
        {0, 0x13C0, 0x10}); // address 0x13C0 + 0x40 = 0x1400
    // Conditional: cmp sets Z so ldreq fires; a second program with
    // ldrne (Z clear) is skipped by the guard and falls through.
    RunArm(
        {
            0xE3A00014, // mov r0, #0x14
            0xE5810000, // str r0, [r1]
            0xE3520000, // cmp r2, #0
            0x0791F002, // ldreq pc, [r1, r2]
            0xE3A03011, // mov r3, #0x11 (unreached)
            0xE3A03022, // mov r3, #0x22 (unreached)
            0xE3A03033, // mov r3, #0x33
            0xEAFFFFFE, // b .
        },
        {0, 0x1400, 0});
    RunArm(
        {
            0xE3A00014, // mov r0, #0x14
            0xE5810000, // str r0, [r1]
            0xE3520001, // cmp r2, #1
            0x1791F002, // ldrne pc, [r1, r2] (skipped: Z clear)
            0xE3A03011, // mov r3, #0x11
            0xEAFFFFFE, // b .
        },
        {0, 0x1400, 0});
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmLoadStoreRegister)]
                .load() == slow_lsr_before);
#endif

    // Target with bit0 = 1 flips TFlag: the handler now owns the mode
    // switch (writes TFlag = 1, then the end probe misses on the
    // foreign-mode key), so no slow exit is taken and execution continues
    // in Thumb at 0x14.
#if defined(__aarch64__)
    const auto slow_lsr_mode =
        Core::ARMAsm::g_asm_stats
            .slow_op_counts[static_cast<size_t>(Core::ARMIR::Opcode::ArmLoadStoreRegister)]
            .load();
#endif
    RunArm(
        {
            0xE3A00015, // mov r0, #0x15 (Thumb target 0x14|1)
            0xE5810000, // str r0, [r1]
            0xE791F002, // ldr pc, [r1, r2]
            0xE3A03011, // mov r3, #0x11 (unreached)
            0xE3A03022, // mov r3, #0x22 (unreached)
            0xE7FEE7FE, // Thumb b . ; b . (executed in Thumb state)
        },
        {0, 0x1400, 0});
#if defined(__aarch64__)
    REQUIRE(Core::ARMAsm::g_asm_stats
                .slow_op_counts[static_cast<size_t>(
                    Core::ARMIR::Opcode::ArmLoadStoreRegister)]
                .load() == slow_lsr_mode);
#endif
}


TEST_CASE("ARM asm executor: fused carry-arith + conditional branch", "[arm_asm]") {
    // rsb/adc/sbc/rsc r?, r?, r? + b<cond>: the op227 fused form now runs a
    // single carbra record per pair. Covers all four data opcodes plus the
    // taken/not-taken paths; cmp seeds the carry flag for adcs/rscs.
    const std::vector<u32> program = {
        0xE1550006, // 0x00 cmp r5, r6
        0xE0B54006, // 0x04 adcs r4, r5, r6
        0x1A000001, // 0x08 bne 0x14
        0xE3A000AA, // 0x0C mov r0, #0xAA
        0xEAFFFFFE, // 0x10 b .
        0xE0D54006, // 0x14 sbcs r4, r5, r6
        0x3A000001, // 0x18 bcc 0x24
        0xE3A01011, // 0x1C mov r1, #0x11
        0xEAFFFFFE, // 0x20 b .
        0xE0754006, // 0x24 rsbs r4, r5, r6
        0xAA000001, // 0x28 bge 0x34
        0xE3A02022, // 0x2C mov r2, #0x22
        0xEAFFFFFE, // 0x30 b .
        0xE0F54006, // 0x34 rscs r4, r5, r6
        0x6A000001, // 0x38 bvs 0x44
        0xE3A03033, // 0x3C mov r3, #0x33
        0xEAFFFFFE, // 0x40 b .
        0xE3A07077, // 0x44 mov r7, #0x77
        0xEAFFFFFE, // 0x48 b .
    };
    auto regs = BaseRegs();
    regs[5] = 0x7FFFFFFF;
    regs[6] = 2;
    RunArm(program, regs);
    // Second pass with opposite carry/overflow edge behavior.
    regs[5] = 1;
    regs[6] = 0xFFFFFFFF;
    RunArm(program, regs);
}

TEST_CASE("ARM asm executor: fused carry-arith self-loop chain", "[arm_asm]") {
    // adcs/bcc back to the block start: exercises the carbrachain variant
    // (budget-checked self-loop). r5 accumulates r6 until the carry pops out
    // after exactly 16 iterations, then falls through to the exit.
    const std::vector<u32> program = {
        0xE3A05000, // 0x00 mov r5, #0
        0xE0955006, // 0x04 loop: adcs r5, r5, r6
        0x3AFFFFFD, // 0x08 bcc loop
        0xEAFFFFFE, // 0x0C b .
    };
    auto regs = BaseRegs();
    regs[6] = 0x10000000;
#ifdef __aarch64__
    const auto ops_before = Core::ARMAsm::g_asm_stats.ops_executed.load();
    RunArm(program, regs, USER32MODE, 64);
    REQUIRE(Core::ARMAsm::g_asm_stats.ops_executed.load() > ops_before);
#else
    RunArm(program, regs, USER32MODE, 64);
#endif
}

TEST_CASE("ARM asm executor: ldr pc via pc-relative register offset", "[arm_asm]") {
    // ldr pc, [pc, rm, lsl#2] -- the pc-relative jump-table form: base is the
    // constant (insn&~3)+8, rm supplies the index. Covers both taken targets
    // and a conditional (guarded) variant.
    const std::vector<u32> program = {
        0xE79FF100, // 0x00 ldr pc, [pc, r0, lsl #2]  (base = 0x08)
        0xEAFFFFFE, // 0x04 unreachable padding
        0x00000018, // 0x08 table[0] -> 0x18
        0x00000020, // 0x0C table[1] -> 0x20
        0xEAFFFFFE, // 0x10 unreachable padding
        0xEAFFFFFE, // 0x14 unreachable padding
        0xE3A03033, // 0x18 mov r3, #0x33
        0xEAFFFFFE, // 0x1C b .
        0xE3A04044, // 0x20 mov r4, #0x44
        0xEAFFFFFE, // 0x24 b .
    };
    auto regs = BaseRegs();
    regs[0] = 0;
    RunArm(program, regs);
    regs[0] = 1;
    RunArm(program, regs);

    // Conditional form: ldrcc pc, [pc, r1, lsl #2] executes only under CC.
    const std::vector<u32> cond_program = {
        0x379FF101, // 0x00 ldrcc pc, [pc, r1, lsl #2] (base = 0x08)
        0xEAFFFFFE, // 0x04 b . (not-taken landing)
        0x00000018, // 0x08 table[0] -> 0x18
        0xEAFFFFFE, // 0x0C b .
        0xEAFFFFFE, // 0x10 unreachable padding
        0xEAFFFFFE, // 0x14 unreachable padding
        0xE3A05055, // 0x18 mov r5, #0x55
        0xEAFFFFFE, // 0x1C b .
    };
    regs[1] = 0;
    RunArm(cond_program, regs, USER32MODE | CBIT); // CC false -> falls to b .
    RunArm(cond_program, regs, USER32MODE);        // CC true  -> table jump

    // ldr pc, [pc, #imm]: literal-pool absolute branch (rd==15, rn==15,
    // immediate offset). The address folds to a translate-time constant.
    const std::vector<u32> lit_program = {
        0xE59FF008, // 0x00 ldr pc, [pc, #8]   -> mem[0x10]
        0xEAFFFFFE, // 0x04 unreachable padding
        0xEAFFFFFE, // 0x08 unreachable padding
        0xEAFFFFFE, // 0x0C unreachable padding
        0x00000018, // 0x10 target -> 0x18
        0xEAFFFFFE, // 0x14 unreachable padding
        0xE3A06066, // 0x18 mov r6, #0x66
        0xEAFFFFFE, // 0x1C b .
    };
    RunArm(lit_program, regs);
}

TEST_CASE("ARM asm executor: str/strb pc via register offset", "[arm_asm]") {
    // str pc stores this instruction's own address (Reg[15] verbatim in the
    // IR); strb pc stores its low byte. Both are lsx=2 residual cases that
    // now store live w28 instead of exiting to C++.
    const std::vector<u32> program = {
        0xE781F002, // 0x00 str  pc, [r1, r2]        -> mem[0x1808]
        0xE7C1F102, // 0x04 strb pc, [r1, r2, lsl#2] -> mem[0x1840] low byte
        0xE7A1F002, // 0x08 str  pc, [r1, r2]!      -> mem[0x1808], r1 += 8
        0xEAFFFFFE, // 0x0C b .
    };
    auto regs = BaseRegs();
    regs[1] = 0x1800;
    regs[2] = 8;
    RunArm(program, regs);
}

TEST_CASE("ARM asm executor: stm including pc", "[arm_asm]") {
    // stm{..., pc} writes Reg[15]+8 for the pc slot. Covers IA and DB with
    // writeback; the stmpc handler appends the pc value in list order.
    const std::vector<u32> program = {
        0xE8A18090, // 0x00 stmia r1!, {r4, r7, pc}
        0xE92D8090, // 0x04 stmdb sp!, {r4, r7, pc}
        0xEAFFFFFE, // 0x08 b .
    };
    auto regs = BaseRegs();
    regs[1] = 0x17F8; // -> 0x17F8,0x17FC,0x1800 (0x1800 is compared)
    regs[4] = 0x44;
    regs[7] = 0x77;
    regs[13] = 0x2004; // stmdb -> 0x1FF8,0x1FFC,0x2000 (0x1FFC compared)
    RunArm(program, regs);
}

TEST_CASE("ARM asm executor: signed halfword multiplies", "[arm_asm]") {
    // smulxy / smlaxy / smlalxy in both halfword selections, including the
    // accumulate path's Q-flag set on signed overflow.
    const std::vector<u32> program = {
        0xE1630281, // 0x00 smulbb  r3, r1, r2
        0xE16302A1, // 0x04 smultb  r3, r1, r2
        0xE16302C1, // 0x08 smulbt  r3, r1, r2
        0xE16302E1, // 0x0C smultt  r3, r1, r2
        0xE1452281, // 0x10 smlabb  r4, r1, r2, r5
        0xE14522A1, // 0x14 smlatb  r4, r1, r2, r5
        0xE1476281, // 0x18 smlalbb r6, r7, r1, r2
        0xE14762E1, // 0x1C smlaltt r6, r7, r1, r2
        0xEAFFFFFE, // 0x20 b .
    };
    auto regs = BaseRegs();
    regs[1] = 0x80018002;
    regs[2] = 0x7FFF8001;
    regs[5] = 0x7FFFFFF0; // pushes smla* past the signed-overflow edge
    regs[6] = 0x11223344;
    regs[7] = 0x55667788;
    RunArm(program, regs);
}

TEST_CASE("ARM asm executor: cp15 privileged and unprivileged transfers", "[arm_asm]") {
    // Generic mrc/mcr coverage: translate-time index resolution, user-mode
    // gate on privileged registers, and the unprivileged barrier/TLS writes.
    // Note: Seed's SetCPSR does not update ARMul_State::Mode, so the "SVC"
    // passes below still observe the user-mode gate on both engines — the
    // point is that asm and the interpreters agree bit-for-bit either way.
    auto regs = BaseRegs();
    regs[3] = 0x12345678;
    const auto loop = 0xEAFFFFFE;
    for (u32 insn : {
             0xEE133110U, // mrc p15,0,r3,c0,c0,0    MAIN_ID (priv: reads 0 user)
             0xEE073F15U, // mcr p15,0,r3,c7,c5,0    I-cache inval (priv)
             0xEE073FBAU, // mcr p15,0,r3,c7,c10,5   DMB (unprivileged ok)
             0xEE0D3F50U, // mcr p15,0,r3,c13,c0,2   THREAD_UPRW (unprivileged)
             0xEE1D5F90U, // mrc p15,0,r5,c13,c0,4   THREAD_PRW (priv)
         }) {
        CAPTURE(insn);
        RunArm({insn, loop}, regs);
        RunArm({insn, loop}, regs, SVC32MODE);
    }
    RunArm(
        {
            0xEE133110, // 0x00 mrc p15,0,r3,c0,c0,0    MAIN_ID
            0xEE073F15, // 0x04 mcr p15,0,r3,c7,c5,0    I-cache inval (priv)
            0xEE073FBA, // 0x08 mcr p15,0,r3,c7,c10,5   DMB
            0xEE0D3F50, // 0x0C mcr p15,0,r3,c13,c0,2   THREAD_UPRW
            0xEE1D5F90, // 0x10 mrc p15,0,r5,c13,c0,4   THREAD_PRW
            loop,
        },
        regs);
    RunArm(
        {
            0xEE133110, 0xEE073F15, 0xEE073FBA, 0xEE0D3F50, 0xEE1D5F90, loop,
        },
        regs, SVC32MODE);
}

} // namespace ArmTests
