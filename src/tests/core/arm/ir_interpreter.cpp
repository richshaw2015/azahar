// Copyright Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#include <catch2/catch_test_macros.hpp>

#include <algorithm>
#include <array>
#include <bit>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>
#include <span>
#include <vector>

#include "common/memory_ref.h"
#include "common/settings.h"
#include "audio_core/sink_details.h"
#include "core/arm/arm_interface.h"
#include "core/arm/dyncom/arm_dyncom.h"
#include "core/arm/dyncom/arm_dyncom_dec.h"
#include "core/arm/ir/arm_ir_cache.h"
#include "core/arm/ir/arm_ir_interpreter.h"
#include "core/arm/skyeye_common/armstate.h"
#include "core/core.h"
#include "core/core_timing.h"
#include "core/frontend/emu_window.h"
#include "core/memory.h"

namespace {

constexpr u32 CodeBase = 0x00100000;
constexpr u32 DataBase = CodeBase + 0x8000;
constexpr u32 MappedSize = 0x10000;

class HeadlessWindow final : public Frontend::EmuWindow {
public:
    HeadlessWindow() {
        window_info.type = Frontend::WindowSystemType::Headless;
        UpdateCurrentFramebufferLayout(Core::kScreenTopWidth,
                                       Core::kScreenTopHeight + Core::kScreenBottomHeight);
    }

    void PollEvents() override {}
};

class InterpreterMachine {
public:
    explicit InterpreterMachine(bool use_ir, PrivilegeMode initial_mode = USER32MODE)
        : memory(system), timing(1, 100, 0) {
        page_table->Clear();
        memory.MapMemoryRegion(*page_table, CodeBase, MappedSize, MemoryRef(backing));
        memory.SetCurrentPageTable(page_table);
        if (use_ir) {
            cpu = std::make_unique<Core::ARM_IRInterpreter>(
                system, memory, initial_mode, 0, timing.GetTimer(0));
        } else {
            cpu = std::make_unique<Core::ARM_DynCom>(system, memory, initial_mode, 0,
                                                     timing.GetTimer(0));
        }
    }

    void Reset(const std::vector<u8>& memory_image, u32 instruction,
               const std::array<u32, 15>& registers, u32 cpsr, bool thumb = false,
               u32 pc = CodeBase) {
        std::copy(memory_image.begin(), memory_image.end(), backing->Vector().begin());
        const u32 code_offset = pc - CodeBase;
        if (thumb) {
            const u16 instruction16 = static_cast<u16>(instruction);
            std::memcpy(backing->Vector().data() + code_offset, &instruction16,
                        sizeof(instruction16));
        } else {
            std::memcpy(backing->Vector().data() + code_offset, &instruction, sizeof(instruction));
        }
        cpu->InvalidateCacheRange(pc, thumb ? 2 : 4);
        cpu->ClearExclusiveState();
        for (u32 index = 0; index < registers.size(); ++index) {
            cpu->SetReg(static_cast<int>(index), registers[index]);
        }
        for (int index = 0; index < 64; ++index) {
            cpu->SetVFPReg(index, 0x3F000000U + static_cast<u32>(index) * 0x10000U);
        }
        cpu->SetVFPSystemReg(VFP_FPSCR, 0);
        cpu->SetVFPSystemReg(VFP_FPEXC, 1U << 30);
        cpu->SetCPSR(cpsr);
        cpu->SetPC(pc);
    }

    void Step() {
        cpu->Step();
    }

    void ResetProgram(const std::vector<u8>& memory_image, std::span<const u32> instructions,
                      const std::array<u32, 15>& registers, u32 cpsr) {
        std::copy(memory_image.begin(), memory_image.end(), backing->Vector().begin());
        std::memcpy(backing->Vector().data(), instructions.data(), instructions.size_bytes());
        cpu->InvalidateCacheRange(CodeBase, instructions.size_bytes());
        cpu->ClearExclusiveState();
        for (u32 index = 0; index < registers.size(); ++index) {
            cpu->SetReg(static_cast<int>(index), registers[index]);
        }
        for (int index = 0; index < 64; ++index) {
            cpu->SetVFPReg(index, 0x3F000000U + static_cast<u32>(index) * 0x10000U);
        }
        cpu->SetVFPSystemReg(VFP_FPSCR, 0);
        cpu->SetVFPSystemReg(VFP_FPEXC, 1U << 30);
        cpu->SetCPSR(cpsr);
        cpu->SetPC(CodeBase);
    }

    void Run(u32 instruction_count) {
        const auto timer = timing.GetTimer(0);
        timer->Advance();
        timer->SetNextSlice(instruction_count);
        cpu->Run();
    }

    u64 GetIRFallbackCount() const {
        const auto* ir = dynamic_cast<const Core::ARM_IRInterpreter*>(cpu.get());
        return ir ? ir->GetIRFallbackCount() : 0;
    }

    Core::System system;
    Memory::MemorySystem memory;
    Core::Timing timing;
    std::shared_ptr<Memory::PageTable> page_table = std::make_shared<Memory::PageTable>();
    std::shared_ptr<BufferMem> backing = std::make_shared<BufferMem>(MappedSize);
    std::unique_ptr<Core::ARM_Interface> cpu;
};

class DifferentialFixture {
public:
    DifferentialFixture() {
        for (std::size_t i = 0; i < memory_image.size(); ++i) {
            memory_image[i] = static_cast<u8>((i * 37 + 11) & 0xFF);
        }
    }

    void Run(u32 instruction, const std::array<u32, 15>& registers, u32 cpsr,
             bool thumb = false, u32 pc = CodeBase) {
        INFO("instruction = 0x" << std::hex << instruction);
        INFO("initial cpsr = 0x" << std::hex << cpsr);
        dyncom.Reset(memory_image, instruction, registers, cpsr, thumb, pc);
        ir.Reset(memory_image, instruction, registers, cpsr, thumb, pc);
        const u64 fallback_count = ir.GetIRFallbackCount();
        dyncom.Step();
        ir.Step();

        for (int index = 0; index < 16; ++index) {
            INFO("register index = " << index);
            REQUIRE(ir.cpu->GetReg(index) == dyncom.cpu->GetReg(index));
        }
        REQUIRE(ir.cpu->GetCPSR() == dyncom.cpu->GetCPSR());
        for (int index = 0; index < 64; ++index) {
            INFO("VFP register index = " << index);
            REQUIRE(ir.cpu->GetVFPReg(index) == dyncom.cpu->GetVFPReg(index));
        }
        REQUIRE(ir.cpu->GetVFPSystemReg(VFP_FPSCR) ==
                dyncom.cpu->GetVFPSystemReg(VFP_FPSCR));
        REQUIRE(ir.cpu->GetVFPSystemReg(VFP_FPEXC) ==
                dyncom.cpu->GetVFPSystemReg(VFP_FPEXC));
        for (u32 index = 0; index < CP15_REGISTER_COUNT; ++index) {
            const auto reg = static_cast<CP15Register>(index);
            INFO("CP15 register index = " << index);
            REQUIRE(ir.cpu->GetCP15Register(reg) == dyncom.cpu->GetCP15Register(reg));
        }
        REQUIRE(ir.backing->Vector() == dyncom.backing->Vector());
        REQUIRE(ir.cpu->GetTimer().GetTicks() == dyncom.cpu->GetTimer().GetTicks());
        REQUIRE(ir.cpu->GetTimer().GetDowncount() == dyncom.cpu->GetTimer().GetDowncount());
        REQUIRE(ir.GetIRFallbackCount() == fallback_count);
    }

    InterpreterMachine dyncom{false};
    InterpreterMachine ir{true};
    std::vector<u8> memory_image = std::vector<u8>(MappedSize);
};

std::array<u32, 15> RandomRegisters(std::mt19937& random) {
    std::array<u32, 15> registers;
    std::generate(registers.begin(), registers.end(), [&] { return random(); });
    return registers;
}

u32 RandomCpsr(std::mt19937& random, bool thumb = false) {
    constexpr u32 NzcvMask = 0xF0000000;
    return USER32MODE | (random() & NzcvMask) | (thumb ? TBIT : 0);
}

u32 RandomExtendedCpsr(std::mt19937& random) {
    constexpr u32 StatusMask = 0xF80F0000;
    return USER32MODE | (random() & StatusMask);
}

constexpr u32 EncodeDataProcessingImmediate(u32 opcode, u32 rn, u32 rd, u32 immediate,
                                            u32 condition = ConditionCode::AL) {
    return (condition << 28) | (1U << 25) | (opcode << 21) | (1U << 20) | (rn << 16) |
           (rd << 12) | (immediate & 0xFFF);
}

constexpr u32 EncodeDataProcessingRegister(u32 opcode, u32 rn, u32 rd, u32 rm, u32 shift_type,
                                           u32 shift_amount, bool register_shift,
                                           u32 condition = ConditionCode::AL) {
    const u32 operand2 = register_shift
                             ? ((shift_amount & 0xF) << 8) | ((shift_type & 3) << 5) | 0x10 | rm
                             : ((shift_amount & 0x1F) << 7) | ((shift_type & 3) << 5) | rm;
    return (condition << 28) | (opcode << 21) | (1U << 20) | (rn << 16) | (rd << 12) |
           operand2;
}

constexpr u32 EncodeCP15Transfer(bool read, u32 crn, u32 rd, u32 crm, u32 opcode_1,
                                 u32 opcode_2, u32 condition = ConditionCode::AL) {
    return (condition << 28) | 0x0E000010U | ((opcode_1 & 7) << 21) |
           (static_cast<u32>(read) << 20) | ((crn & 0xF) << 16) | ((rd & 0xF) << 12) |
           (15U << 8) | ((opcode_2 & 7) << 5) | (crm & 0xF);
}

void CompareMachines(const InterpreterMachine& ir, const InterpreterMachine& dyncom) {
    INFO("IR PC = 0x" << std::hex << ir.cpu->GetPC());
    INFO("dyncom PC = 0x" << std::hex << dyncom.cpu->GetPC());
    INFO("IR CPSR = 0x" << std::hex << ir.cpu->GetCPSR());
    INFO("dyncom CPSR = 0x" << std::hex << dyncom.cpu->GetCPSR());
    INFO("IR downcount = " << std::dec << ir.cpu->GetTimer().GetDowncount());
    INFO("dyncom downcount = " << std::dec << dyncom.cpu->GetTimer().GetDowncount());
    for (int index = 0; index < 16; ++index) {
        INFO("register index = " << index);
        REQUIRE(ir.cpu->GetReg(index) == dyncom.cpu->GetReg(index));
    }
    REQUIRE(ir.cpu->GetCPSR() == dyncom.cpu->GetCPSR());
    for (int index = 0; index < 64; ++index) {
        INFO("VFP register index = " << index);
        REQUIRE(ir.cpu->GetVFPReg(index) == dyncom.cpu->GetVFPReg(index));
    }
    REQUIRE(ir.cpu->GetVFPSystemReg(VFP_FPSCR) ==
            dyncom.cpu->GetVFPSystemReg(VFP_FPSCR));
    REQUIRE(ir.cpu->GetVFPSystemReg(VFP_FPEXC) ==
            dyncom.cpu->GetVFPSystemReg(VFP_FPEXC));
    for (u32 index = 0; index < CP15_REGISTER_COUNT; ++index) {
        const auto reg = static_cast<CP15Register>(index);
        INFO("CP15 register index = " << index);
        REQUIRE(ir.cpu->GetCP15Register(reg) == dyncom.cpu->GetCP15Register(reg));
    }
    REQUIRE(ir.backing->Vector() == dyncom.backing->Vector());
    REQUIRE(ir.cpu->GetTimer().GetTicks() == dyncom.cpu->GetTimer().GetTicks());
    REQUIRE(ir.cpu->GetTimer().GetDowncount() == dyncom.cpu->GetTimer().GetDowncount());
    REQUIRE(ir.GetIRFallbackCount() == 0);
}

struct RomCP15Checkpoint {
    u32 step{};
    std::array<u32, CP15_REGISTER_COUNT> registers{};

    bool operator==(const RomCP15Checkpoint&) const = default;
};

struct RomRunResult {
    enum class Backend {
        Unknown,
        Dyncom,
        IRInterpreter,
    };

    Core::System::ResultStatus status{};
    u32 completed_loops{};
    s64 global_ticks{};
    Backend backend{};
    std::vector<Core::ARM_Interface::ThreadContext> contexts;
    std::vector<s64> loop_ticks;
    std::vector<std::vector<u64>> loop_core_ticks;
    std::vector<std::vector<Core::ARM_Interface::ThreadContext>> loop_contexts;
    std::vector<std::vector<RomCP15Checkpoint>> cp15_changes;
    u64 ir_fallback_count{};
};

RomRunResult RunRom(const std::string& path, bool use_ir, u32 loop_count) {
    auto& system = Core::System::GetInstance();
    system.Shutdown();

    Settings::values.use_cpu_jit = false;
    Settings::values.use_cpu_ir_interpreter = use_ir;
    Settings::values.graphics_api = Settings::GraphicsAPI::Software;
    Settings::values.output_type = AudioCore::SinkType::Null;
    Settings::values.audio_emulation = Settings::AudioEmulation::HLE;
    Settings::values.lle_applets = false;
    Settings::values.frame_limit = 0;
    Settings::values.init_clock = Settings::InitClock::FixedTime;
    Settings::values.init_time = 946681277ULL;
    Settings::values.init_ticks_type = Settings::InitTicks::Fixed;
    Settings::values.init_ticks_override = 0;
    Settings::values.async_fs_operations = false;

    HeadlessWindow window;
    RomRunResult result;
    result.status = system.Load(window, path);
    if (result.status != Core::System::ResultStatus::Success) {
        system.Shutdown();
        return result;
    }

    const auto& core = system.GetCore(0);
    if (dynamic_cast<const Core::ARM_IRInterpreter*>(&core)) {
        result.backend = RomRunResult::Backend::IRInterpreter;
    } else if (dynamic_cast<const Core::ARM_DynCom*>(&core)) {
        result.backend = RomRunResult::Backend::Dyncom;
    }
    result.cp15_changes.resize(system.GetNumCores());
    for (u32 core = 0; core < system.GetNumCores(); ++core) {
        auto& checkpoint = result.cp15_changes[core].emplace_back();
        for (u32 index = 0; index < CP15_REGISTER_COUNT; ++index) {
            checkpoint.registers[index] =
                system.GetCore(core).GetCP15Register(static_cast<CP15Register>(index));
        }
    }
    const bool single_step = std::getenv("AZAHAR_IR_TEST_SINGLE_STEP") != nullptr;
    for (; result.completed_loops < loop_count; ++result.completed_loops) {
        result.status = single_step ? system.SingleStep() : system.RunLoop();
        if (result.status != Core::System::ResultStatus::Success) {
            break;
        }
        result.loop_ticks.push_back(system.CoreTiming().GetGlobalTicks());
        auto& core_ticks = result.loop_core_ticks.emplace_back(system.GetNumCores());
        auto& contexts = result.loop_contexts.emplace_back(system.GetNumCores());
        for (u32 core = 0; core < system.GetNumCores(); ++core) {
            core_ticks[core] = system.GetCore(core).GetTimer().GetTicks();
            system.GetCore(core).SaveContext(contexts[core]);
            RomCP15Checkpoint checkpoint{.step = result.completed_loops + 1};
            for (u32 index = 0; index < CP15_REGISTER_COUNT; ++index) {
                checkpoint.registers[index] =
                    system.GetCore(core).GetCP15Register(static_cast<CP15Register>(index));
            }
            if (checkpoint.registers != result.cp15_changes[core].back().registers) {
                result.cp15_changes[core].push_back(std::move(checkpoint));
            }
        }
    }
    result.global_ticks = system.CoreTiming().GetGlobalTicks();
    result.contexts.resize(system.GetNumCores());
    for (u32 core = 0; core < system.GetNumCores(); ++core) {
        system.GetCore(core).SaveContext(result.contexts[core]);
        if (const auto* ir = dynamic_cast<const Core::ARM_IRInterpreter*>(&system.GetCore(core))) {
            result.ir_fallback_count += ir->GetIRFallbackCount();
        }
    }
    system.Shutdown();
    return result;
}

void CompareThreadContexts(const Core::ARM_Interface::ThreadContext& ir,
                           const Core::ARM_Interface::ThreadContext& dyncom) {
    REQUIRE(ir.cpu_registers == dyncom.cpu_registers);
    REQUIRE(ir.cpsr == dyncom.cpsr);
    REQUIRE(ir.fpu_registers == dyncom.fpu_registers);
    REQUIRE(ir.fpscr == dyncom.fpscr);
    REQUIRE(ir.fpexc == dyncom.fpexc);
}

} // namespace

TEST_CASE("ARM IR interpreter matches dyncom initial state", "[core][arm][ir]") {
    InterpreterMachine dyncom{false};
    InterpreterMachine ir{true};
    REQUIRE(ir.cpu->GetCPSR() == dyncom.cpu->GetCPSR());
}

TEST_CASE("ARM IR translator covers dyncom ARM decode space", "[core][arm][ir]") {
    std::mt19937 random{0x41524D36U};
    constexpr u32 sample_count = 1U << 20;
    u32 decoded_count = 0;
    for (u32 iteration = 0; iteration < sample_count; ++iteration) {
        const u32 instruction = random();
        int dyncom_index = -1;
        const ARMDecodeStatus decode_status = DecodeARMInstruction(instruction, &dyncom_index);
        CAPTURE(iteration, instruction, dyncom_index);
        if (decode_status != ARMDecodeStatus::SUCCESS) {
            REQUIRE_FALSE(Core::ARMIR::BlockCache::SupportsArmInstruction(instruction));
            continue;
        }
        decoded_count++;
        if (!IsARMInstructionDecodeSafe(instruction, dyncom_index)) {
            REQUIRE_FALSE(Core::ARMIR::BlockCache::SupportsArmInstruction(instruction));
            continue;
        }
        REQUIRE(Core::ARMIR::BlockCache::SupportsArmInstruction(instruction));
    }
    REQUIRE(decoded_count != 0);
}

TEST_CASE("ARM IR interpreter matches dyncom for undefined and unsafe encodings",
          "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x554E4446U};

    u32 undefined_arm = 0;
    for (;;) {
        undefined_arm = random();
        int dyncom_index = -1;
        if (DecodeARMInstruction(undefined_arm, &dyncom_index) == ARMDecodeStatus::FAILURE &&
            !Core::ARMIR::BlockCache::SupportsArmInstruction(undefined_arm)) {
            break;
        }
    }
    fixture.Run(undefined_arm, RandomRegisters(random), RandomCpsr(random));

    {
        InterpreterMachine dyncom{false};
        InterpreterMachine ir{true};
        std::vector<u8> memory_image(MappedSize);
        const std::array program = {0xE3A00001U, undefined_arm}; // MOV r0, #1; undefined
        auto registers = RandomRegisters(random);
        const u32 cpsr = RandomCpsr(random);
        dyncom.ResetProgram(memory_image, program, registers, cpsr);
        ir.ResetProgram(memory_image, program, registers, cpsr);
        dyncom.Run(program.size());
        ir.Run(program.size());
        CompareMachines(ir, dyncom);
        REQUIRE(ir.cpu->GetReg(0) == 1);
        REQUIRE(ir.cpu->GetPC() == CodeBase + 4);
    }

    fixture.Run(0xDE00U, RandomRegisters(random), RandomCpsr(random, true), true);
    fixture.Run(0xBA80U, RandomRegisters(random), RandomCpsr(random, true), true);

    constexpr std::array unsafe_arm = {
        0xEC6A8AF2U, // Invalid VSTM register list exceeds ExtReg[64].
        0xE06DF9FCU, // STRD with Rd=15 would read Reg[16].
        0xE1B1FF9FU, // LDREXD with Rd=15 would write Reg[16].
        0xE1A10F9FU, // STREXD with Rm=15 would read Reg[16].
    };
    for (const u32 instruction : unsafe_arm) {
        int dyncom_index = -1;
        CAPTURE(instruction);
        REQUIRE(DecodeARMInstruction(instruction, &dyncom_index) == ARMDecodeStatus::SUCCESS);
        REQUIRE_FALSE(IsARMInstructionDecodeSafe(instruction, dyncom_index));
        REQUIRE_FALSE(Core::ARMIR::BlockCache::SupportsArmInstruction(instruction));
        fixture.Run(instruction, RandomRegisters(random), RandomCpsr(random));
    }
}

TEST_CASE("ARM IR interpreter matches dyncom expanded ARM decode semantics",
          "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x45585044U};
    constexpr u32 target = CodeBase + 0x100;
    constexpr u32 arm_nop = 0xE1A00000;
    std::memcpy(fixture.memory_image.data() + (target - CodeBase), &arm_nop, sizeof(arm_nop));

    // Dyncom ignores architecturally fixed fields in these decoder entries.
    fixture.Run(0xE1634D11U, RandomRegisters(random), RandomCpsr(random)); // CLZ
    fixture.Run(0xE6B12D33U, RandomRegisters(random), RandomCpsr(random)); // REV
    fixture.Run(0xE6F12DB3U, RandomRegisters(random), RandomCpsr(random)); // REVSH
    auto registers = RandomRegisters(random);
    registers[1] = target;
    fixture.Run(0xE127C411U, registers, RandomCpsr(random)); // BX with ignored fields

    registers = RandomRegisters(random);
    registers[1] = DataBase + 0x100;
    fixture.Run(0xE1412D93U, registers, RandomCpsr(random)); // SWPB with ignored fields

    registers = RandomRegisters(random);
    registers[7] = DataBase + 0x100;
    fixture.Run(0xE1873A9FU, registers, RandomCpsr(random)); // STREX with ignored fields

    fixture.Run(0xE000019FU, RandomRegisters(random), RandomCpsr(random)); // MUL using PC
    fixture.Run(0xE128F00FU, RandomRegisters(random), RandomCpsr(random)); // MSR using PC
    fixture.Run(0xEED7CB1CU, RandomRegisters(random), RandomCpsr(random)); // generic CP11 MRC

    // Dyncom writes the base before a conflicting transfer reads or writes its register.
    registers = RandomRegisters(random);
    registers[1] = DataBase + 0x100;
    registers[2] = 4;
    fixture.Run(0xE7E11002U, registers, RandomCpsr(random)); // STRB r1, [r1, r2]!
    fixture.Run(0xE7F11002U, registers, RandomCpsr(random)); // LDRB r1, [r1, r2]!

    registers = RandomRegisters(random);
    registers[6] = DataBase + 0x100;
    fixture.Run(0xE0C657D8U, registers, RandomCpsr(random)); // LDRD r5, r6, [r6], #0x78
    fixture.Run(0xE0C657F8U, registers, RandomCpsr(random)); // STRD r5, r6, [r6], #0x78

    registers = RandomRegisters(random);
    registers[1] = DataBase + 0x100;
    fixture.Run(0xE8A10000U, registers, RandomCpsr(random)); // STMIA r1!, {}

    registers = RandomRegisters(random);
    registers[2] = DataBase + 0x200;
    registers[11] = 4;
    const u32 loaded_pc = target | 1;
    std::memcpy(fixture.memory_image.data() + (registers[2] - CodeBase), &loaded_pc,
                sizeof(loaded_pc));
    fixture.Run(0xE692F18BU, registers, RandomCpsr(random)); // LDR pc, [r2], r11, LSL #3
}

TEST_CASE("ARM IR interpreter matches dyncom data-processing exception return",
          "[core][arm][ir]") {
    InterpreterMachine dyncom{false, SVC32MODE};
    InterpreterMachine ir{true, SVC32MODE};
    std::vector<u8> memory_image(MappedSize);
    constexpr std::array program = {
        0xE16FF000U, // MSR SPSR_fsxc, r0
        0xE25EF004U, // SUBS pc, lr, #4
    };
    std::array<u32, 15> registers{};
    registers[0] = USER32MODE | 0xA0000000U;
    registers[14] = CodeBase + 0x104;
    dyncom.ResetProgram(memory_image, program, registers, SVC32MODE);
    ir.ResetProgram(memory_image, program, registers, SVC32MODE);
    dyncom.Run(program.size());
    ir.Run(program.size());
    CompareMachines(ir, dyncom);
    REQUIRE(ir.cpu->GetPC() == CodeBase + 0x100);
    REQUIRE(ir.cpu->GetCPSR() == registers[0]);
}

TEST_CASE("ARM IR interpreter matches dyncom data processing", "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x31A5A11U};

    for (u32 iteration = 0; iteration < 4096; ++iteration) {
        const u32 condition = random() % 16;
        const u32 opcode = random() % 16;
        const bool writes_flags_only = opcode >= 8 && opcode <= 11;
        const bool set_flags = writes_flags_only || ((random() & 1) != 0);
        const u32 rn = random() % 13;
        const u32 rd = writes_flags_only ? 0 : random() % 13;
        const bool immediate = (random() & 1) != 0;
        u32 operand2;
        if (immediate) {
            operand2 = ((random() % 16) << 8) | (random() & 0xFF);
        } else if ((random() & 1) != 0) {
            const u32 rm = random() % 13;
            operand2 = ((random() % 32) << 7) | ((random() % 4) << 5) | rm;
        } else {
            const u32 rm = random() % 13;
            const u32 rs = random() % 13;
            operand2 = (rs << 8) | ((random() % 4) << 5) | 0x10 | rm;
        }
        const u32 instruction = (condition << 28) | (static_cast<u32>(immediate) << 25) |
                                (opcode << 21) | (static_cast<u32>(set_flags) << 20) |
                                (rn << 16) | (rd << 12) | operand2;
        CAPTURE(iteration);
        fixture.Run(instruction, RandomRegisters(random), RandomCpsr(random));
    }
}

TEST_CASE("ARM IR interpreter matches dyncom multiply", "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x4D554C31U};

    for (u32 iteration = 0; iteration < 1024; ++iteration) {
        const u32 condition = random() % 16;
        const bool accumulate = (random() & 1) != 0;
        const bool set_flags = (random() & 1) != 0;
        const u32 rd = random() % 13;
        const u32 rn = random() % 13;
        const u32 rs = random() % 13;
        const u32 rm = random() % 13;
        const u32 instruction = (condition << 28) | (static_cast<u32>(accumulate) << 21) |
                                (static_cast<u32>(set_flags) << 20) | (rd << 16) | (rn << 12) |
                                (rs << 8) | 0x90 | rm;
        CAPTURE(iteration);
        fixture.Run(instruction, RandomRegisters(random), RandomCpsr(random));
    }
}

TEST_CASE("ARM IR interpreter matches dyncom single memory transfers", "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x4C445354U};

    for (u32 iteration = 0; iteration < 2048; ++iteration) {
        const u32 condition = random() % 16;
        const bool register_offset = (random() & 1) != 0;
        const bool pre_index = (random() & 1) != 0;
        const bool add = (random() & 1) != 0;
        const bool byte = (random() & 1) != 0;
        const bool writeback = (random() & 1) != 0;
        const bool load = (random() & 1) != 0;
        constexpr u32 rn = 1;
        constexpr u32 rd = 3;
        u32 offset;
        if (register_offset) {
            constexpr u32 rm = 2;
            offset = ((random() % 4) << 7) | rm;
        } else {
            offset = random() & 0x3F;
        }
        const u32 instruction = (condition << 28) | 0x04000000 |
                                (static_cast<u32>(register_offset) << 25) |
                                (static_cast<u32>(pre_index) << 24) |
                                (static_cast<u32>(add) << 23) |
                                (static_cast<u32>(byte) << 22) |
                                (static_cast<u32>(writeback) << 21) |
                                (static_cast<u32>(load) << 20) | (rn << 16) | (rd << 12) |
                                offset;
        auto registers = RandomRegisters(random);
        registers[rn] = DataBase + 0x100;
        registers[2] &= 0xF;
        CAPTURE(iteration);
        fixture.Run(instruction, registers, RandomCpsr(random));
    }
}

TEST_CASE("ARM IR interpreter matches dyncom branches", "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x4252414EU};

    for (u32 iteration = 0; iteration < 512; ++iteration) {
        const u32 condition = random() % 16;
        const bool link = (random() & 1) != 0;
        const u32 displacement = random() & 0xFF;
        const u32 instruction = (condition << 28) | 0x0A000000 |
                                (static_cast<u32>(link) << 24) | displacement;
        CAPTURE(iteration);
        fixture.Run(instruction, RandomRegisters(random), RandomCpsr(random));
    }
}

TEST_CASE("ARM IR interpreter matches dyncom halfword memory transfers", "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x48414C46U};

    for (u32 iteration = 0; iteration < 2048; ++iteration) {
        const u32 condition = random() % 16;
        const bool immediate_offset = (random() & 1) != 0;
        const bool pre_index = (random() & 1) != 0;
        const bool add = (random() & 1) != 0;
        const bool writeback = pre_index && ((random() & 1) != 0);
        const u32 transfer_type = 1 + random() % 3;
        const bool load = transfer_type != 1 || ((random() & 1) != 0);
        constexpr u32 rn = 1;
        constexpr u32 rd = 3;
        u32 offset;
        if (immediate_offset) {
            const u32 immediate = random() & 0x3F;
            offset = ((immediate & 0xF0) << 4) | (immediate & 0xF);
        } else {
            offset = 2;
        }
        const u32 instruction = (condition << 28) |
                                (static_cast<u32>(pre_index) << 24) |
                                (static_cast<u32>(add) << 23) |
                                (static_cast<u32>(immediate_offset) << 22) |
                                (static_cast<u32>(writeback) << 21) |
                                (static_cast<u32>(load) << 20) | (rn << 16) | (rd << 12) |
                                0x90 | ((transfer_type & 2) << 5) |
                                ((transfer_type & 1) << 5) | offset;
        auto registers = RandomRegisters(random);
        registers[rn] = DataBase + 0x100;
        registers[2] &= 0xF;
        CAPTURE(iteration);
        fixture.Run(instruction, registers, RandomCpsr(random));
    }
}

TEST_CASE("ARM IR interpreter matches dyncom load store multiple", "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x4C444D55U};

    for (u32 iteration = 0; iteration < 1024; ++iteration) {
        const u32 condition = random() % 16;
        const bool pre_index = (random() & 1) != 0;
        const bool add = (random() & 1) != 0;
        const bool writeback = (random() & 1) != 0;
        const bool load = (random() & 1) != 0;
        constexpr u32 rn = 12;
        const u32 register_list = (random() & 0xFF) | 1;
        const u32 instruction = (condition << 28) | 0x08000000 |
                                (static_cast<u32>(pre_index) << 24) |
                                (static_cast<u32>(add) << 23) |
                                (static_cast<u32>(writeback) << 21) |
                                (static_cast<u32>(load) << 20) | (rn << 16) | register_list;
        auto registers = RandomRegisters(random);
        registers[rn] = DataBase + 0x400;
        CAPTURE(iteration);
        fixture.Run(instruction, registers, RandomCpsr(random));
    }
}

TEST_CASE("ARM IR interpreter matches dyncom long multiply", "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x4D554C4CU};

    for (u32 iteration = 0; iteration < 1024; ++iteration) {
        const u32 condition = random() % 16;
        const bool signed_multiply = (random() & 1) != 0;
        const bool accumulate = (random() & 1) != 0;
        const bool set_flags = (random() & 1) != 0;
        const u32 rd_lo = random() % 13;
        u32 rd_hi = random() % 13;
        if (rd_hi == rd_lo) {
            rd_hi = (rd_hi + 1) % 13;
        }
        const u32 rs = random() % 13;
        const u32 rm = random() % 13;
        const u32 instruction = (condition << 28) | 0x00800090 |
                                (static_cast<u32>(signed_multiply) << 22) |
                                (static_cast<u32>(accumulate) << 21) |
                                (static_cast<u32>(set_flags) << 20) | (rd_hi << 16) |
                                (rd_lo << 12) | (rs << 8) | rm;
        CAPTURE(iteration);
        fixture.Run(instruction, RandomRegisters(random), RandomCpsr(random));
    }
}

TEST_CASE("ARM IR interpreter matches dyncom DSP and media instructions", "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x44535031U};
    constexpr std::array instructions = {
        0xE16F0F11U, 0xE6EF0071U, 0xE6FF0071U, 0xE6AF0071U, 0xE6BF0071U,
        0xE6E10072U, 0xE6F10072U, 0xE6A10072U, 0xE6B10072U, 0xE6BF0F31U,
        0xE6BF0FB1U, 0xE6FF0FB1U, 0xE6810412U, 0xE6810452U, 0xE6AB0011U,
        0xE6EC0011U, 0xE6AB0F31U, 0xE6EC0F31U, 0xE1020051U, 0xE1220051U,
        0xE1420051U, 0xE1620051U, 0xE6110F12U, 0xE6110F32U, 0xE6110F52U,
        0xE6110F72U, 0xE6110F92U, 0xE6110FF2U, 0xE6210F12U, 0xE6210F32U,
        0xE6210F52U, 0xE6210F72U, 0xE6210F92U, 0xE6210FF2U, 0xE6310F12U,
        0xE6310F32U, 0xE6310F52U, 0xE6310F72U, 0xE6310F92U, 0xE6310FF2U,
        0xE6510F12U, 0xE6510F32U, 0xE6510F52U, 0xE6510F72U, 0xE6510F92U,
        0xE6510FF2U, 0xE6610F12U, 0xE6610F32U, 0xE6610F52U, 0xE6610F72U,
        0xE6610F92U, 0xE6610FF2U, 0xE6710F12U, 0xE6710F32U, 0xE6710F52U,
        0xE6710F72U, 0xE6710F92U, 0xE6710FF2U, 0xE6810FB2U, 0xE780F211U,
        0xE7803211U, 0xE0410392U, 0xE1600281U, 0xE16002A1U, 0xE1003281U,
        0xE1410382U, 0xE700F211U, 0xE700F251U, 0xE7003211U, 0xE7003251U,
        0xE7410312U, 0xE7410352U, 0xE750F211U, 0xE7503211U, 0xE75032D1U,
    };

    for (const u32 instruction : instructions) {
        for (u32 iteration = 0; iteration < 32; ++iteration) {
            CAPTURE(instruction, iteration);
            fixture.Run(instruction, RandomRegisters(random), RandomExtendedCpsr(random));
        }
    }
}

TEST_CASE("ARM IR interpreter matches dyncom status and CP15 transfers", "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x53544154U};
    constexpr std::array instructions = {
        0xE10F0000U, // MRS r0, CPSR
        0xE128F001U, // MSR CPSR_f, r1
        0xF10C0080U, // CPSID i
        0xF1080080U, // CPSIE i
        0xF1010200U, // SETEND BE
        0xF1010000U, // SETEND LE
        0xEE1D0F50U, // MRC p15, 0, r0, c13, c0, 2
        0xEE0D0F50U, // MCR p15, 0, r0, c13, c0, 2
        0xF57FF01FU, // CLREX
        0xE320F000U, // NOP
        0xE320F001U, // YIELD
        0xE320F002U, // WFE
        0xE320F003U, // WFI
        0xE320F004U, // SEV
    };

    for (const u32 instruction : instructions) {
        for (u32 iteration = 0; iteration < 64; ++iteration) {
            CAPTURE(instruction, iteration);
            fixture.Run(instruction, RandomRegisters(random), RandomExtendedCpsr(random));
        }
    }
}

TEST_CASE("ARM IR interpreter matches dyncom CP15 register encodings", "[core][arm][ir]") {
    InterpreterMachine dyncom{false, SVC32MODE};
    InterpreterMachine ir{true, SVC32MODE};
    std::vector<u8> memory_image(MappedSize);
    std::mt19937 random{0x43503135U};

    struct CP15Encoding {
        u8 crn;
        u8 crm;
        u8 opcode_1;
        u8 opcode_2;
    };
    constexpr std::array read_encodings = {
        CP15Encoding{0, 0, 0, 0},  CP15Encoding{0, 0, 0, 1},
        CP15Encoding{0, 0, 0, 3},  CP15Encoding{0, 0, 0, 5},
        CP15Encoding{0, 1, 0, 0},  CP15Encoding{0, 1, 0, 1},
        CP15Encoding{0, 1, 0, 2},  CP15Encoding{0, 1, 0, 4},
        CP15Encoding{0, 1, 0, 5},  CP15Encoding{0, 1, 0, 6},
        CP15Encoding{0, 1, 0, 7},  CP15Encoding{0, 2, 0, 0},
        CP15Encoding{0, 2, 0, 1},  CP15Encoding{0, 2, 0, 2},
        CP15Encoding{0, 2, 0, 3},  CP15Encoding{0, 2, 0, 4},
        CP15Encoding{1, 0, 0, 0},  CP15Encoding{1, 0, 0, 1},
        CP15Encoding{1, 0, 0, 2},  CP15Encoding{2, 0, 0, 0},
        CP15Encoding{2, 0, 0, 1},  CP15Encoding{2, 0, 0, 2},
        CP15Encoding{3, 0, 0, 0},  CP15Encoding{5, 0, 0, 0},
        CP15Encoding{5, 0, 0, 1},  CP15Encoding{6, 0, 0, 0},
        CP15Encoding{6, 0, 0, 1},  CP15Encoding{7, 4, 0, 0},
        CP15Encoding{9, 0, 0, 0},  CP15Encoding{10, 0, 0, 0},
        CP15Encoding{10, 2, 0, 0}, CP15Encoding{10, 2, 0, 1},
        CP15Encoding{13, 0, 0, 0}, CP15Encoding{13, 0, 0, 1},
        CP15Encoding{13, 0, 0, 2}, CP15Encoding{13, 0, 0, 3},
        CP15Encoding{13, 0, 0, 4}, CP15Encoding{15, 12, 0, 0},
        CP15Encoding{15, 12, 0, 1}, CP15Encoding{15, 12, 0, 2},
        CP15Encoding{15, 12, 0, 3}, CP15Encoding{15, 5, 5, 2},
        CP15Encoding{15, 6, 5, 2}, CP15Encoding{15, 7, 5, 2},
        CP15Encoding{15, 1, 7, 0},
    };
    constexpr std::array write_encodings = {
        CP15Encoding{1, 0, 0, 0},  CP15Encoding{1, 0, 0, 1},
        CP15Encoding{1, 0, 0, 2},  CP15Encoding{2, 0, 0, 0},
        CP15Encoding{2, 0, 0, 1},  CP15Encoding{2, 0, 0, 2},
        CP15Encoding{3, 0, 0, 0},  CP15Encoding{5, 0, 0, 0},
        CP15Encoding{5, 0, 0, 1},  CP15Encoding{6, 0, 0, 0},
        CP15Encoding{6, 0, 0, 1},  CP15Encoding{7, 0, 0, 4},
        CP15Encoding{7, 5, 0, 0},  CP15Encoding{7, 5, 0, 1},
        CP15Encoding{7, 5, 0, 2},  CP15Encoding{7, 5, 0, 4},
        CP15Encoding{7, 5, 0, 6},  CP15Encoding{7, 5, 0, 7},
        CP15Encoding{7, 6, 0, 0},  CP15Encoding{7, 6, 0, 1},
        CP15Encoding{7, 6, 0, 2},  CP15Encoding{7, 7, 0, 0},
        CP15Encoding{7, 10, 0, 0}, CP15Encoding{7, 10, 0, 1},
        CP15Encoding{7, 10, 0, 2}, CP15Encoding{7, 10, 0, 4},
        CP15Encoding{7, 10, 0, 5}, CP15Encoding{7, 14, 0, 0},
        CP15Encoding{7, 14, 0, 1}, CP15Encoding{7, 14, 0, 2},
        CP15Encoding{8, 5, 0, 0},  CP15Encoding{8, 5, 0, 1},
        CP15Encoding{8, 5, 0, 2},  CP15Encoding{8, 5, 0, 3},
        CP15Encoding{8, 6, 0, 0},  CP15Encoding{8, 6, 0, 1},
        CP15Encoding{8, 6, 0, 2},  CP15Encoding{8, 6, 0, 3},
        CP15Encoding{8, 7, 0, 0},  CP15Encoding{8, 7, 0, 1},
        CP15Encoding{8, 7, 0, 2},  CP15Encoding{8, 7, 0, 3},
        CP15Encoding{9, 0, 0, 0},  CP15Encoding{10, 0, 0, 0},
        CP15Encoding{10, 2, 0, 0}, CP15Encoding{10, 2, 0, 1},
        CP15Encoding{13, 0, 0, 0}, CP15Encoding{13, 0, 0, 1},
        CP15Encoding{13, 0, 0, 2}, CP15Encoding{13, 0, 0, 3},
        CP15Encoding{13, 0, 0, 4}, CP15Encoding{15, 12, 0, 0},
        CP15Encoding{15, 12, 0, 1}, CP15Encoding{15, 12, 0, 2},
        CP15Encoding{15, 12, 0, 3}, CP15Encoding{15, 4, 5, 2},
        CP15Encoding{15, 4, 5, 4}, CP15Encoding{15, 5, 5, 2},
        CP15Encoding{15, 6, 5, 2}, CP15Encoding{15, 7, 5, 2},
        CP15Encoding{15, 1, 7, 0},
    };

    for (u32 index = 0; index < CP15_REGISTER_COUNT; ++index) {
        const auto reg = static_cast<CP15Register>(index);
        const u32 value = 0x51000000U + index * 0x10203U;
        dyncom.cpu->SetCP15Register(reg, value);
        ir.cpu->SetCP15Register(reg, value);
    }
    const auto run = [&](u32 instruction) {
        auto registers = RandomRegisters(random);
        dyncom.Reset(memory_image, instruction, registers, SVC32MODE | (random() & 0xF0000000U));
        ir.Reset(memory_image, instruction, registers, dyncom.cpu->GetCPSR());
        dyncom.Step();
        ir.Step();
        CAPTURE(instruction);
        CompareMachines(ir, dyncom);
    };

    for (const auto& encoding : read_encodings) {
        run(EncodeCP15Transfer(true, encoding.crn, 4, encoding.crm, encoding.opcode_1,
                               encoding.opcode_2));
    }
    for (const auto& encoding : write_encodings) {
        run(EncodeCP15Transfer(false, encoding.crn, 4, encoding.crm, encoding.opcode_1,
                               encoding.opcode_2));
    }
    run(EncodeCP15Transfer(true, 0, 15, 0, 0, 0)); // MRC to APSR flags

    for (u32 condition = 0; condition < ConditionCode::AL; ++condition) {
        for (u32 flag_index = 0; flag_index < 16; ++flag_index) {
            const u32 cpsr = SVC32MODE | (flag_index << 28);
            auto registers = RandomRegisters(random);
            const u32 instruction = EncodeCP15Transfer(
                (condition & 1) != 0, 13, 4, 0, 0, 2, condition);
            dyncom.Reset(memory_image, instruction, registers, cpsr);
            ir.Reset(memory_image, instruction, registers, cpsr);
            dyncom.Step();
            ir.Step();
            CAPTURE(condition, flag_index, instruction);
            CompareMachines(ir, dyncom);
        }
    }
}

TEST_CASE("ARM IR interpreter matches dyncom miscellaneous and no-op instructions",
          "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x46414C4CU};
    constexpr std::array instructions = {
        0xF5D1F000U, // PLD [r1]
        0xE1201273U, // BKPT #0x123
        0xEC410F00U, // MCRR p15, 0, r0, r1, c0
        0xEC510F00U, // MRRC p15, 0, r0, r1, c0
        0xEE000900U, // CDP p9, 0, c0, c0, c0, 0
    };

    for (const u32 instruction : instructions) {
        auto registers = RandomRegisters(random);
        registers[1] = DataBase + 0x100;
        CAPTURE(instruction);
        fixture.Run(instruction, registers, RandomCpsr(random));
    }
}

TEST_CASE("ARM IR interpreter matches dyncom swap and doubleword transfers", "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x4D454D32U};
    constexpr std::array instructions = {
        0xE1010092U, // SWP r0, r2, [r1]
        0xE1410092U, // SWPB r0, r2, [r1]
        0xE1C201D0U, // LDRD r0, r1, [r2, #16]
        0xE1C201F0U, // STRD r0, r1, [r2, #16]
    };

    for (const u32 instruction : instructions) {
        for (u32 iteration = 0; iteration < 128; ++iteration) {
            auto registers = RandomRegisters(random);
            registers[1] = DataBase + 0x100;
            registers[2] = DataBase + 0x200;
            if (instruction == 0xE1010092U || instruction == 0xE1410092U) {
                registers[1] = DataBase + 0x100;
                registers[2] = random();
            }
            CAPTURE(instruction, iteration);
            fixture.Run(instruction, registers, RandomCpsr(random));
        }
    }
}

TEST_CASE("ARM IR interpreter matches dyncom exclusive monitor sequences", "[core][arm][ir]") {
    InterpreterMachine dyncom{false};
    InterpreterMachine ir{true};
    std::vector<u8> memory_image(MappedSize);
    for (std::size_t i = 0; i < memory_image.size(); ++i) {
        memory_image[i] = static_cast<u8>((i * 29 + 7) & 0xFF);
    }
    std::array<u32, 15> registers{};
    registers[1] = DataBase + 0x100;
    registers[2] = 0x89ABCDEF;
    registers[3] = 0x01234567;
    registers[4] = DataBase + 0x200;

    const auto run_sequence = [&](std::span<const u32> program) {
        dyncom.ResetProgram(memory_image, program, registers, USER32MODE);
        ir.ResetProgram(memory_image, program, registers, USER32MODE);
        dyncom.Run(static_cast<u32>(program.size()));
        ir.Run(static_cast<u32>(program.size()));
        CompareMachines(ir, dyncom);
    };

    const std::array word = {0xE1910F9FU, 0xE1810F92U};
    const std::array byte = {0xE1D10F9FU, 0xE1C10F92U};
    const std::array halfword = {0xE1F10F9FU, 0xE1E10F92U};
    const std::array doubleword = {0xE1B40F9FU, 0xE1A40F92U};
    const std::array cleared = {0xE1910F9FU, 0xF57FF01FU, 0xE1810F92U};
    const std::array failed = {0xE1810F92U};
    run_sequence(word);
    run_sequence(byte);
    run_sequence(halfword);
    run_sequence(doubleword);
    run_sequence(cleared);
    run_sequence(failed);
}

TEST_CASE("ARM IR interpreter matches dyncom PC and branch exchange semantics", "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x42585043U};
    constexpr u32 target = CodeBase + 0x100;
    constexpr u32 arm_nop = 0xE1A00000;
    constexpr u16 thumb_nop = 0x46C0;
    std::memcpy(fixture.memory_image.data() + (target - CodeBase), &arm_nop, sizeof(arm_nop));

    for (const u32 instruction : {0xE1A0000FU, 0xE28F0004U, 0xE1A0F004U, 0xE12FFF14U,
                                  0xE12FFF34U}) {
        for (u32 iteration = 0; iteration < 64; ++iteration) {
            auto registers = RandomRegisters(random);
            registers[4] = target;
            CAPTURE(instruction, iteration);
            fixture.Run(instruction, registers, RandomCpsr(random));
        }
    }

    std::memcpy(fixture.memory_image.data() + (target - CodeBase), &thumb_nop,
                sizeof(thumb_nop));
    fixture.Run(0xFA00003EU, RandomRegisters(random), RandomCpsr(random)); // BLX immediate
    for (const u32 instruction : {0xE12FFF14U, 0xE12FFF34U}) {
        auto registers = RandomRegisters(random);
        registers[4] = target | 1;
        CAPTURE(instruction);
        fixture.Run(instruction, registers, RandomCpsr(random));
    }

    std::memcpy(fixture.memory_image.data() + (target - CodeBase), &arm_nop, sizeof(arm_nop));
    std::memcpy(fixture.memory_image.data() + (DataBase - CodeBase), &target, sizeof(target));
    auto registers = RandomRegisters(random);
    registers[1] = DataBase;
    fixture.Run(0xE591F000U, registers, RandomCpsr(random)); // LDR pc, [r1]
}

TEST_CASE("ARM IR interpreter matches dyncom multiple transfers with PC", "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x50434C44U};
    constexpr u32 target = CodeBase + 0x100;
    constexpr u32 arm_nop = 0xE1A00000;
    std::memcpy(fixture.memory_image.data() + (target - CodeBase), &arm_nop, sizeof(arm_nop));

    auto registers = RandomRegisters(random);
    registers[1] = DataBase + 0x200;
    fixture.Run(0xE8818001U, registers, RandomCpsr(random)); // STMIA r1, {r0,pc}

    constexpr u32 loaded_r0 = 0x13579BDF;
    std::memcpy(fixture.memory_image.data() + (registers[1] - CodeBase), &loaded_r0,
                sizeof(loaded_r0));
    std::memcpy(fixture.memory_image.data() + (registers[1] - CodeBase) + 4, &target,
                sizeof(target));
    fixture.Run(0xE8B18001U, registers, RandomCpsr(random)); // LDMIA r1!, {r0,pc}
}

TEST_CASE("ARM IR interpreter matches dyncom privileged return-state transfers",
          "[core][arm][ir]") {
    std::vector<u8> memory_image(MappedSize);

    SECTION("SRS stores LR and SPSR using the selected addressing mode") {
        InterpreterMachine dyncom{false, SVC32MODE};
        InterpreterMachine ir{true, SVC32MODE};
        constexpr std::array program = {
            0xE16FF000U, // MSR SPSR_fsxc, r0
            0xF96D0513U, // SRSDB sp!, #svc
        };
        std::array<u32, 15> registers{};
        registers[0] = USER32MODE | TBIT | 0xA0000000U;
        registers[13] = DataBase + 0x400;
        registers[14] = 0x12345678;
        dyncom.ResetProgram(memory_image, program, registers, SVC32MODE);
        ir.ResetProgram(memory_image, program, registers, SVC32MODE);
        dyncom.Run(program.size());
        ir.Run(program.size());
        CompareMachines(ir, dyncom);
    }

    SECTION("RFE restores CPSR and PC and performs writeback") {
        InterpreterMachine dyncom{false, SVC32MODE};
        InterpreterMachine ir{true, SVC32MODE};
        constexpr std::array program = {0xF8BD0A00U}; // RFEIA sp!
        constexpr u32 stack = DataBase + 0x500;
        constexpr u32 target = CodeBase + 0x100;
        constexpr u32 restored_cpsr = USER32MODE | 0x60000000U;
        std::memcpy(memory_image.data() + (stack - CodeBase), &restored_cpsr,
                    sizeof(restored_cpsr));
        std::memcpy(memory_image.data() + (stack - CodeBase) + 4, &target, sizeof(target));
        std::array<u32, 15> registers{};
        registers[13] = stack;
        dyncom.ResetProgram(memory_image, program, registers, SVC32MODE);
        ir.ResetProgram(memory_image, program, registers, SVC32MODE);
        dyncom.Step();
        ir.Step();
        CompareMachines(ir, dyncom);
    }

    SECTION("LDM exception return restores SPSR when loading PC") {
        InterpreterMachine dyncom{false, SVC32MODE};
        InterpreterMachine ir{true, SVC32MODE};
        constexpr std::array program = {
            0xE16FF000U, // MSR SPSR_fsxc, r0
            0xE8F18004U, // LDMIA r1!, {r2,pc}^
        };
        constexpr u32 stack = DataBase + 0x600;
        constexpr u32 target = CodeBase + 0x100;
        constexpr u32 restored_cpsr = USER32MODE | TBIT | 0xA0000000U;
        constexpr u32 loaded_r2 = 0xCAFEBABE;
        std::memcpy(memory_image.data() + (stack - CodeBase), &loaded_r2, sizeof(loaded_r2));
        std::memcpy(memory_image.data() + (stack - CodeBase) + 4, &target, sizeof(target));
        std::array<u32, 15> registers{};
        registers[0] = restored_cpsr;
        registers[1] = stack;
        dyncom.ResetProgram(memory_image, program, registers, SVC32MODE);
        ir.ResetProgram(memory_image, program, registers, SVC32MODE);
        dyncom.Run(program.size());
        ir.Run(program.size());
        CompareMachines(ir, dyncom);
    }
}

TEST_CASE("ARM IR interpreter matches dyncom big endian memory", "[core][arm][ir]") {
    InterpreterMachine dyncom{false};
    InterpreterMachine ir{true};
    std::vector<u8> memory_image(MappedSize);
    for (std::size_t i = 0; i < memory_image.size(); ++i) {
        memory_image[i] = static_cast<u8>(i * 13 + 3);
    }
    const std::array program = {
        0xF1010200U, // SETEND BE
        0xE5910000U, // LDR r0, [r1]
        0xE5810004U, // STR r0, [r1, #4]
        0xF1010000U, // SETEND LE
    };
    std::array<u32, 15> registers{};
    registers[1] = DataBase;
    dyncom.ResetProgram(memory_image, program, registers, USER32MODE);
    ir.ResetProgram(memory_image, program, registers, USER32MODE);
    dyncom.Run(program.size());
    ir.Run(program.size());
    CompareMachines(ir, dyncom);
}

TEST_CASE("ARM IR interpreter matches dyncom at memory and page boundaries",
          "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x50414745U};

    struct AccessCase {
        u32 instruction;
        u32 base_register;
        u32 address;
    };
    constexpr std::array access_cases = {
        AccessCase{0xE5910000U, 1, DataBase + 0xFFF}, // LDR r0, [r1]
        AccessCase{0xE5810000U, 1, DataBase + 0xFFF}, // STR r0, [r1]
        AccessCase{0xE1D100B0U, 1, DataBase + 0xFFF}, // LDRH r0, [r1]
        AccessCase{0xE1C100B0U, 1, DataBase + 0xFFF}, // STRH r0, [r1]
        AccessCase{0xE1D100D0U, 1, DataBase + 0xFFF}, // LDRSB r0, [r1]
        AccessCase{0xE1D100F0U, 1, DataBase + 0xFFF}, // LDRSH r0, [r1]
        AccessCase{0xE1C200D0U, 2, DataBase + 0xFFC}, // LDRD r0, r1, [r2]
        AccessCase{0xE1C200F0U, 2, DataBase + 0xFFC}, // STRD r0, r1, [r2]
        AccessCase{0xE8B2000BU, 2, DataBase + 0xFFC}, // LDMIA r2!, {r0,r1,r3}
        AccessCase{0xE8A2000BU, 2, DataBase + 0xFFC}, // STMIA r2!, {r0,r1,r3}
    };

    for (const u32 endian : {0U, static_cast<u32>(EBIT)}) {
        for (const auto& access : access_cases) {
            auto registers = RandomRegisters(random);
            registers[access.base_register] = access.address;
            CAPTURE(access.instruction, access.address, endian);
            fixture.Run(access.instruction, registers, USER32MODE | endian);
        }
    }

    for (u32 misalignment = 1; misalignment < 4; ++misalignment) {
        for (const u32 instruction : {0xE5910000U, 0xE5810000U}) {
            auto registers = RandomRegisters(random);
            registers[1] = DataBase + 0x100 + misalignment;
            CAPTURE(instruction, misalignment);
            fixture.Run(instruction, registers, RandomCpsr(random));
        }
    }
    for (const u32 instruction : {0xE1D100B0U, 0xE1C100B0U, 0xE1D100F0U}) {
        auto registers = RandomRegisters(random);
        registers[1] = DataBase + 0x101;
        CAPTURE(instruction);
        fixture.Run(instruction, registers, RandomCpsr(random));
    }
}

TEST_CASE("ARM IR interpreter matches dyncom Thumb arithmetic and memory", "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x5448554DU};

    for (u32 iteration = 0; iteration < 2048; ++iteration) {
        const u32 family = random() % 6;
        const u32 rd = random() % 8;
        u16 instruction;
        switch (family) {
        case 0:
        case 1:
        case 2:
        case 3:
            instruction = static_cast<u16>(0x2000 | (family << 11) | (rd << 8) |
                                           (random() & 0xFF));
            break;
        case 4:
            instruction = static_cast<u16>(0x4000 | ((random() % 16) << 6) |
                                           ((random() % 8) << 3) | rd);
            break;
        default: {
            const bool load = (random() & 1) != 0;
            const bool byte = (random() & 1) != 0;
            constexpr u32 rn = 1;
            instruction = static_cast<u16>(0x6000 | (static_cast<u32>(byte) << 12) |
                                           (static_cast<u32>(load) << 11) |
                                           ((random() % 8) << 6) | (rn << 3) | rd);
            break;
        }
        }
        auto registers = RandomRegisters(random);
        registers[1] = DataBase + 0x100;
        CAPTURE(iteration);
        fixture.Run(instruction, registers, RandomCpsr(random, true), true);
    }
}

TEST_CASE("ARM IR interpreter matches dyncom Thumb instruction families", "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x54484D42U};
    constexpr std::array arithmetic_instructions = {
        0x00C8U, 0x08C8U, 0x10C8U, 0x1888U, 0x1A88U, 0x1CC8U, 0x1EC8U,
        0x2011U, 0x2811U, 0x3011U, 0x3811U, 0x4008U, 0x4048U, 0x4088U,
        0x40C8U, 0x4108U, 0x4148U, 0x4188U, 0x41C8U, 0x4208U, 0x4248U,
        0x4288U, 0x42C8U, 0x4308U, 0x4348U, 0x4388U, 0x43C8U, 0x4488U,
        0x4588U, 0x4688U, 0xB208U, 0xB248U, 0xB288U, 0xB2C8U, 0xBA08U,
        0xBA48U, 0xBAC8U, 0x46C0U,
    };
    constexpr std::array memory_instructions = {
        0x5088U, 0x5288U, 0x5488U, 0x5688U, 0x5888U, 0x5A88U, 0x5C88U,
        0x5E88U, 0x6108U, 0x6908U, 0x7108U, 0x7908U, 0x8108U, 0x8908U,
        0x9004U, 0x9804U, 0xA00AU, 0xA804U, 0xB004U, 0xB084U, 0xB50FU,
        0xBC0FU, 0xC11DU, 0xC91DU,
    };

    for (const u32 instruction : arithmetic_instructions) {
        for (u32 iteration = 0; iteration < 64; ++iteration) {
            CAPTURE(instruction, iteration);
            fixture.Run(instruction, RandomRegisters(random), RandomCpsr(random, true), true);
        }
    }
    for (const u32 instruction : memory_instructions) {
        for (u32 iteration = 0; iteration < 64; ++iteration) {
            auto registers = RandomRegisters(random);
            registers[1] = DataBase + 0x100;
            registers[2] = 4;
            registers[13] = DataBase + 0x500;
            CAPTURE(instruction, iteration);
            fixture.Run(instruction, registers, RandomCpsr(random, true), true);
        }
    }
}

TEST_CASE("ARM IR interpreter matches dyncom for defined Thumb encoding space",
          "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x54484D45U};
    constexpr u32 target = CodeBase + 0x100;
    constexpr u32 test_pc = CodeBase + 0x4000;
    constexpr u32 stack = DataBase + 0x800;
    constexpr u32 arm_nop = 0xE1A00000;
    std::memcpy(fixture.memory_image.data() + (target - CodeBase), &arm_nop, sizeof(arm_nop));

    for (u32 raw_instruction = 0; raw_instruction <= 0xFFFF; ++raw_instruction) {
        const u16 instruction = static_cast<u16>(raw_instruction);
        const u32 family = instruction >> 11;

        // 0b1101 with cond=1110 is undefined and cond=1111 is SVC. SVC dispatch is
        // covered through system-level ROM tests rather than this isolated CPU fixture.
        if ((family == 26 || family == 27) && ((instruction >> 8) & 0xF) >= 0xE) {
            continue;
        }
        // ARMv6 defines only the even encodings in this BLX suffix family.
        if (family == 29 && (instruction & 1) != 0) {
            continue;
        }

        if (family == 8 && (instruction & 0x0400) != 0) {
            const u32 operation = (instruction >> 8) & 3;
            const u32 rd = (instruction & 7) | ((instruction >> 4) & 8);
            const u32 rs = (instruction >> 3) & 0xF;
            if (operation == 3 && ((instruction & 7) != 0 || rs == 15)) {
                continue;
            }
            if (operation == 0 && rd == 15 && rs == 15) {
                continue;
            }
        }

        if (family == 22 || family == 23) {
            const u32 special = instruction & 0x0F00;
            const bool supported_special =
                special == 0x0000 || special == 0x0200 || special == 0x0400 ||
                special == 0x0500 || special == 0x0600 || special == 0x0A00 ||
                special == 0x0C00 || special == 0x0D00;
            if (!supported_special) {
                continue;
            }
            if (special == 0x0A00 && ((instruction >> 6) & 3) == 2) {
                continue;
            }
            if ((special == 0x0400 || special == 0x0500 || special == 0x0C00 ||
                 special == 0x0D00) &&
                (instruction & 0x01FF) == 0) {
                continue;
            }
        }

        if ((family == 24 || family == 25) && (instruction & 0xFF) == 0) {
            continue;
        }
        if ((family == 24 || family == 25) &&
            ((instruction & (1U << ((instruction >> 8) & 7))) != 0)) {
            continue;
        }

        auto registers = RandomRegisters(random);
        registers[13] = stack;
        if (family == 29 || family == 31) {
            registers[14] = target | 1;
        }
        if (family == 8 && (instruction & 0x0400) != 0) {
            const u32 operation = (instruction >> 8) & 3;
            const u32 rd = (instruction & 7) | ((instruction >> 4) & 8);
            const u32 rs = (instruction >> 3) & 0xF;
            if (operation == 0 && rd == 15) {
                registers[rs] = 0;
            } else if (operation == 2 && rd == 15 && rs != 15) {
                registers[rs] = target;
            } else if (operation == 3) {
                registers[rs] = (instruction & 0x0080) != 0 ? target : (target | 1);
            }
        } else if (family == 10 || family == 11) {
            const u32 offset_register = (instruction >> 6) & 7;
            const u32 base_register = (instruction >> 3) & 7;
            if (offset_register == base_register) {
                registers[base_register] = (DataBase + 0x400) / 2;
            } else {
                registers[base_register] = DataBase + 0x400;
                registers[offset_register] = 4;
            }
        } else if (family >= 12 && family <= 17) {
            registers[(instruction >> 3) & 7] = DataBase + 0x400;
        } else if (family == 24 || family == 25) {
            registers[(instruction >> 8) & 7] = DataBase + 0x400;
        }

        if ((instruction & 0xFF00) == 0xBD00) {
            const u32 pc_offset = std::popcount(static_cast<u32>(instruction & 0xFF)) * 4;
            const u32 popped_pc = target | 1;
            std::memcpy(fixture.memory_image.data() + (stack - CodeBase) + pc_offset, &popped_pc,
                        sizeof(popped_pc));
        }

        CAPTURE(raw_instruction, family);
        fixture.Run(instruction, registers, RandomCpsr(random, true), true, test_pc);
    }
}

TEST_CASE("ARM IR interpreter matches dyncom Thumb control flow", "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x54484252U};
    constexpr u32 target = CodeBase + 0x10;
    constexpr u16 thumb_nop = 0x46C0;
    std::memcpy(fixture.memory_image.data() + (target - CodeBase), &thumb_nop,
                sizeof(thumb_nop));

    for (u32 condition = 0; condition < ConditionCode::AL; ++condition) {
        const u32 instruction = 0xD006 | (condition << 8);
        for (u32 flag_index = 0; flag_index < 16; ++flag_index) {
            auto registers = RandomRegisters(random);
            const u32 cpsr = USER32MODE | TBIT | (flag_index << 28);
            CAPTURE(condition, flag_index);
            fixture.Run(instruction, registers, cpsr, true);
        }
    }
    fixture.Run(0xE006, RandomRegisters(random), RandomCpsr(random, true), true);

    for (const u32 instruction : {0x4720U, 0x47A0U}) {
        auto registers = RandomRegisters(random);
        registers[4] = target | 1;
        CAPTURE(instruction);
        fixture.Run(instruction, registers, RandomCpsr(random, true), true);
    }

    constexpr u32 bl_instruction_pair = 0xF803F000;
    InterpreterMachine dyncom{false};
    InterpreterMachine ir{true};
    std::vector<u8> memory_image(MappedSize);
    std::memcpy(memory_image.data() + (target - CodeBase), &thumb_nop, sizeof(thumb_nop));
    std::array<u32, 15> registers{};
    dyncom.ResetProgram(memory_image, std::span{&bl_instruction_pair, 1}, registers,
                        USER32MODE | TBIT);
    ir.ResetProgram(memory_image, std::span{&bl_instruction_pair, 1}, registers,
                    USER32MODE | TBIT);
    dyncom.Run(2);
    ir.Run(2);
    CompareMachines(ir, dyncom);

    constexpr u32 popped_r0 = 0x12345678;
    const u32 popped_pc = target | 1;
    std::memcpy(fixture.memory_image.data() + (DataBase - CodeBase), &popped_r0,
                sizeof(popped_r0));
    std::memcpy(fixture.memory_image.data() + (DataBase - CodeBase) + 4, &popped_pc,
                sizeof(popped_pc));
    registers[13] = DataBase;
    fixture.Run(0xBD01, registers, USER32MODE | TBIT, true);
}

TEST_CASE("ARM IR interpreter handles Thumb hint and breakpoint encodings without fallback",
          "[core][arm][ir]") {
    InterpreterMachine ir{true};
    std::vector<u8> memory_image(MappedSize);
    std::array<u32, 15> registers{};

    for (u32 hint = 0; hint < 16; ++hint) {
        const u32 instruction = 0xBF00 | (hint << 4);
        CAPTURE(instruction);
        ir.Reset(memory_image, instruction, registers, USER32MODE | TBIT, true);
        ir.Step();
        REQUIRE(ir.cpu->GetPC() == CodeBase + 2);
        REQUIRE(ir.cpu->GetCPSR() == (USER32MODE | TBIT));
        REQUIRE(ir.GetIRFallbackCount() == 0);
    }

    for (const u32 instruction : {0xBE00U, 0xBE42U, 0xBEFFU}) {
        CAPTURE(instruction);
        ir.Reset(memory_image, instruction, registers, USER32MODE | TBIT, true);
        ir.Step();
        REQUIRE(ir.cpu->GetPC() == CodeBase + 2);
        REQUIRE(ir.cpu->GetCPSR() == (USER32MODE | TBIT));
        REQUIRE(ir.GetIRFallbackCount() == 0);
    }
}

TEST_CASE("ARM IR interpreter matches dyncom across optimized blocks", "[core][arm][ir]") {
    InterpreterMachine dyncom{false};
    InterpreterMachine ir{true};
    std::vector<u8> memory_image(MappedSize);
    std::mt19937 random{0x424C4F43U};
    for (std::size_t offset = 0; offset < memory_image.size(); offset += sizeof(u32)) {
        constexpr u32 nop = 0xE1A00000;
        std::memcpy(memory_image.data() + offset, &nop, sizeof(nop));
    }

    std::array<u32, 128> program;
    for (u32 index = 0; index < program.size(); ++index) {
        const u32 condition = random() % 15;
        const u32 opcode_choices[] = {0, 1, 2, 4, 8, 9, 10, 11, 12, 13, 14, 15};
        const u32 opcode = opcode_choices[random() % std::size(opcode_choices)];
        const bool writes_flags_only = opcode >= 8 && opcode <= 11;
        const bool set_flags = writes_flags_only || ((random() & 1) != 0);
        const u32 rn = random() % 13;
        const u32 rd = writes_flags_only ? 0 : random() % 13;
        const u32 operand2 = ((random() % 16) << 8) | (random() & 0xFF);
        program[index] = (condition << 28) | (1U << 25) | (opcode << 21) |
                         (static_cast<u32>(set_flags) << 20) | (rn << 16) | (rd << 12) |
                         operand2;
    }

    const auto registers = RandomRegisters(random);
    const u32 cpsr = RandomCpsr(random);
    dyncom.ResetProgram(memory_image, program, registers, cpsr);
    ir.ResetProgram(memory_image, program, registers, cpsr);
    dyncom.Run(program.size());
    ir.Run(program.size());
    CompareMachines(ir, dyncom);
}

TEST_CASE("ARM IR dense block cache survives collisions and code invalidation", "[core][arm][ir]") {
    InterpreterMachine machine{true};
    std::fill(machine.backing->Vector().begin(), machine.backing->Vector().end(), 0);

    Core::ARMIR::BlockCache cache;
    const auto first_key = Core::ARMIR::BlockCache::MakeKey(CodeBase, USER32MODE);
    const std::size_t first_slot = Core::ARMIR::BlockKeyHash{}(first_key) & 1023;
    Core::ARMIR::BlockKey collision_key{};
    for (u32 address = CodeBase + 0x100; address < CodeBase + MappedSize; address += 4) {
        const auto candidate = Core::ARMIR::BlockCache::MakeKey(address, USER32MODE);
        if ((Core::ARMIR::BlockKeyHash{}(candidate) & 1023) == first_slot) {
            collision_key = candidate;
            break;
        }
    }
    REQUIRE(collision_key.pc != 0);

    cache.GetOrTranslateBlock(first_key, machine.memory);
    cache.GetOrTranslateBlock(collision_key, machine.memory);
    const auto before_dense_lookup = cache.GetStats();
    cache.GetOrTranslateBlock(first_key, machine.memory);
    const auto after_dense_lookup = cache.GetStats();
    REQUIRE(after_dense_lookup.dense_hits == before_dense_lookup.dense_hits + 1);

    cache.InvalidateRange(first_key.pc, sizeof(u32));
    const auto before_retranslation = cache.GetStats();
    cache.GetOrTranslateBlock(first_key, machine.memory);
    const auto after_retranslation = cache.GetStats();
    REQUIRE(after_retranslation.translations == before_retranslation.translations + 1);
}

TEST_CASE("ARM IR interpreter matches dyncom VFP execution", "[core][arm][ir]") {
    InterpreterMachine dyncom{false};
    InterpreterMachine ir{true};
    std::vector<u8> memory_image(MappedSize);
    const std::array<u32, 10> program = {
        0xEE000A10, // VMOV s0, r0
        0xEE101A10, // VMOV r1, s0
        0xEE301A20, // VADD.F32 s2, s0, s1
        0xEE711A60, // VSUB.F32 s3, s2, s1
        0xEE212A21, // VMUL.F32 s4, s2, s3
        0xEEC22A01, // VDIV.F32 s5, s4, s2
        0xEEF42A61, // VCMP.F32 s5, s3
        0xEEF1FA10, // VMRS APSR_nzcv, FPSCR
        0xED822A04, // VSTR s4, [r2, #16]
        0xED923A04, // VLDR s6, [r2, #16]
    };
    std::array<u32, 15> registers{};
    registers[0] = 0x40000000; // 2.0f
    registers[2] = DataBase;
    dyncom.ResetProgram(memory_image, program, registers, USER32MODE);
    ir.ResetProgram(memory_image, program, registers, USER32MODE);
    dyncom.Run(program.size());
    ir.Run(program.size());
    CompareMachines(ir, dyncom);
}

TEST_CASE("ARM IR interpreter matches dyncom VFP instruction families", "[core][arm][ir]") {
    DifferentialFixture fixture;
    std::mt19937 random{0x56465033U};
    constexpr std::array instructions = {
        0xEEF10A10U, // VMRS r0, FPSCR
        0xEEE10A10U, // VMSR FPSCR, r0
        0xEC510B12U, // VMOV r0, r1, d2
        0xEC410B12U, // VMOV d2, r0, r1
        0xEEB00AE0U, // VABS.F32 s0, s1
        0xEEB10A60U, // VNEG.F32 s0, s1
        0xEEB10AE0U, // VSQRT.F32 s0, s1
        0xEEB70AE0U, // VCVT.F64.F32 d0, s1
        0xEEB70BC1U, // VCVT.F32.F64 s0, d1
        0xEEBD0AE0U, // VCVT.S32.F32 s0, s1
        0xEEB80AE0U, // VCVT.F32.S32 s0, s1
        0xED920B04U, // VLDR d0, [r2, #16]
        0xED820B04U, // VSTR d0, [r2, #16]
        0xECB20A04U, // VLDMIA r2!, {s0-s3}
        0xECA20A04U, // VSTMIA r2!, {s0-s3}
        0xEE310B02U, // VADD.F64 d0, d1, d2
        0xEE310B42U, // VSUB.F64 d0, d1, d2
        0xEE210B02U, // VMUL.F64 d0, d1, d2
        0xEE810B02U, // VDIV.F64 d0, d1, d2
        0xEEB40B41U, // VCMP.F64 d0, d1
    };

    for (const u32 instruction : instructions) {
        for (u32 iteration = 0; iteration < 64; ++iteration) {
            auto registers = RandomRegisters(random);
            registers[2] = DataBase + 0x100;
            CAPTURE(instruction, iteration);
            fixture.Run(instruction, registers, RandomCpsr(random));
        }
    }
}

TEST_CASE("ARM IR interpreter matches dyncom for fused compare branch loops", "[core][arm][ir]") {
    InterpreterMachine dyncom{false};
    InterpreterMachine ir{true};
    std::vector<u8> memory_image(MappedSize);
    for (std::size_t offset = 0; offset < memory_image.size(); offset += sizeof(u32)) {
        constexpr u32 nop = 0xE1A00000;
        std::memcpy(memory_image.data() + offset, &nop, sizeof(nop));
    }

    const std::array<u32, 6> program = {
        0xE3A00000, // MOV r0, #0
        0xE3A01020, // MOV r1, #32
        0xE2800001, // ADD r0, r0, #1
        0xE1500001, // CMP r0, r1
        0x1AFFFFFC, // BNE loop
        0xE1A02000, // MOV r2, r0
    };
    std::array<u32, 15> registers{};
    dyncom.ResetProgram(memory_image, program, registers, USER32MODE);
    ir.ResetProgram(memory_image, program, registers, USER32MODE);
    constexpr u32 executed_instructions = 2 + 32 * 3 + 1;
    dyncom.Run(executed_instructions);
    ir.Run(executed_instructions);
    CompareMachines(ir, dyncom);

    const std::array<u32, 6> shifted_program = {
        0xE3A00000, // MOV r0, #0
        0xE3A01020, // MOV r1, #32
        0xE2800002, // ADD r0, r0, #2
        0xE1500081, // CMP r0, r1, LSL #1
        0x1AFFFFFC, // BNE loop
        0xE1A02000, // MOV r2, r0
    };
    dyncom.ResetProgram(memory_image, shifted_program, registers, USER32MODE);
    ir.ResetProgram(memory_image, shifted_program, registers, USER32MODE);
    dyncom.Run(executed_instructions);
    ir.Run(executed_instructions);
    CompareMachines(ir, dyncom);
}

TEST_CASE("ARM IR interpreter matches dyncom for all fused flag branches", "[core][arm][ir]") {
    InterpreterMachine dyncom{false};
    InterpreterMachine ir{true};
    std::vector<u8> memory_image(MappedSize);
    constexpr u32 nop = 0xE1A00000;
    for (std::size_t offset = 0; offset < memory_image.size(); offset += sizeof(nop)) {
        std::memcpy(memory_image.data() + offset, &nop, sizeof(nop));
    }
    std::mt19937 random{0x46555345U};

    struct OperandForm {
        bool immediate;
        bool register_shift;
        u32 shift_type;
        u32 shift_amount;
    };
    constexpr std::array forms = {
        OperandForm{true, false, 0, 0},  OperandForm{false, false, 0, 0},
        OperandForm{false, false, 0, 3}, OperandForm{false, false, 1, 3},
        OperandForm{false, false, 2, 3}, OperandForm{false, false, 3, 3},
        OperandForm{false, false, 3, 0}, OperandForm{false, true, 0, 2},
        OperandForm{false, true, 1, 2},  OperandForm{false, true, 2, 2},
        OperandForm{false, true, 3, 2},
    };

    for (u32 opcode = 0; opcode < 16; ++opcode) {
        for (const OperandForm& form : forms) {
            for (u32 branch_condition = 0; branch_condition < ConditionCode::AL;
                 ++branch_condition) {
                const u32 flag_instruction =
                    form.immediate
                        ? EncodeDataProcessingImmediate(opcode, 0, 3, 0xA5)
                        : EncodeDataProcessingRegister(opcode, 0, 3, 1, form.shift_type,
                                                       form.shift_amount, form.register_shift);
                const std::array program = {
                    flag_instruction,
                    (branch_condition << 28) | 0x0A000000U,
                };
                const auto registers = RandomRegisters(random);
                const u32 cpsr = RandomCpsr(random);
                dyncom.ResetProgram(memory_image, program, registers, cpsr);
                ir.ResetProgram(memory_image, program, registers, cpsr);
                dyncom.Run(program.size());
                ir.Run(program.size());
                CAPTURE(opcode, form.immediate, form.register_shift, form.shift_type,
                        form.shift_amount, branch_condition);
                CompareMachines(ir, dyncom);
            }
        }
    }
}

TEST_CASE("ARM IR interpreter matches dyncom conditional skip blocks", "[core][arm][ir]") {
    InterpreterMachine dyncom{false};
    InterpreterMachine ir{true};
    std::vector<u8> memory_image(MappedSize);

    for (u32 condition = 0; condition < ConditionCode::AL; ++condition) {
        const std::array program = {
            EncodeDataProcessingImmediate(4, 0, 0, 1, condition),
            EncodeDataProcessingImmediate(2, 1, 1, 1, condition),
        };
        for (u32 flag_index = 0; flag_index < 16; ++flag_index) {
            std::array<u32, 15> registers{};
            registers[0] = 0xFFFFFFFF;
            registers[1] = 0;
            const u32 cpsr = USER32MODE | (flag_index << 28);
            dyncom.ResetProgram(memory_image, program, registers, cpsr);
            ir.ResetProgram(memory_image, program, registers, cpsr);
            dyncom.Run(program.size());
            ir.Run(program.size());
            CAPTURE(condition, flag_index);
            CompareMachines(ir, dyncom);
        }
    }
}

TEST_CASE("ARM IR interpreter matches dyncom after context save and load", "[core][arm][ir]") {
    SECTION("ARM context resumes with materialized lazy flags") {
        InterpreterMachine dyncom{false};
        InterpreterMachine ir{true};
        std::vector<u8> memory_image(MappedSize);
        constexpr std::array program = {
            0xE2900001U, // ADDS r0, r0, #1
            0xE2B11000U, // ADCS r1, r1, #0
            0xE0222000U, // EOR r2, r2, r0
            0xE2833005U, // ADD r3, r3, #5
        };
        std::array<u32, 15> registers{};
        registers[0] = 0xFFFFFFFF;
        registers[1] = 0x7FFFFFFF;
        registers[2] = 0xA5A5A5A5;
        registers[3] = 0x12345678;
        dyncom.ResetProgram(memory_image, program, registers, USER32MODE | (1U << 29));
        ir.ResetProgram(memory_image, program, registers, USER32MODE | (1U << 29));
        dyncom.Run(2);
        ir.Run(2);

        Core::ARM_Interface::ThreadContext dyncom_context;
        Core::ARM_Interface::ThreadContext ir_context;
        dyncom.cpu->SaveContext(dyncom_context);
        ir.cpu->SaveContext(ir_context);
        CompareThreadContexts(ir_context, dyncom_context);

        for (int index = 0; index < 15; ++index) {
            dyncom.cpu->SetReg(index, 0xD0000000U + static_cast<u32>(index));
            ir.cpu->SetReg(index, 0x10000000U + static_cast<u32>(index));
        }
        dyncom.cpu->SetCPSR(USER32MODE);
        ir.cpu->SetCPSR(USER32MODE | 0xF0000000U);
        dyncom.cpu->LoadContext(ir_context);
        ir.cpu->LoadContext(dyncom_context);
        dyncom.Run(2);
        ir.Run(2);
        CompareMachines(ir, dyncom);
    }

    SECTION("Thumb context preserves T and resumes at the halfword PC") {
        InterpreterMachine dyncom{false};
        InterpreterMachine ir{true};
        std::vector<u8> memory_image(MappedSize);
        constexpr u16 first = 0x2001;  // MOVS r0, #1
        constexpr u16 second = 0x3002; // ADDS r0, #2
        std::memcpy(memory_image.data() + sizeof(first), &second, sizeof(second));
        std::array<u32, 15> registers{};
        dyncom.Reset(memory_image, first, registers, USER32MODE | TBIT, true);
        ir.Reset(memory_image, first, registers, USER32MODE | TBIT, true);
        dyncom.Step();
        ir.Step();

        Core::ARM_Interface::ThreadContext dyncom_context;
        Core::ARM_Interface::ThreadContext ir_context;
        dyncom.cpu->SaveContext(dyncom_context);
        ir.cpu->SaveContext(ir_context);
        CompareThreadContexts(ir_context, dyncom_context);
        dyncom.cpu->SetCPSR(USER32MODE);
        ir.cpu->SetCPSR(USER32MODE);
        dyncom.cpu->LoadContext(ir_context);
        ir.cpu->LoadContext(dyncom_context);
        dyncom.Step();
        ir.Step();
        CompareMachines(ir, dyncom);
    }
}

TEST_CASE("ARM IR interpreter invalidates rewritten code like dyncom", "[core][arm][ir]") {
    InterpreterMachine dyncom{false};
    InterpreterMachine ir{true};
    std::vector<u8> memory_image(MappedSize);
    constexpr std::array initial_program = {
        0xE3A00001U, // MOV r0, #1
        0xE2800001U, // ADD r0, r0, #1
        0xE1A00000U, // NOP
    };
    std::array<u32, 15> registers{};
    dyncom.ResetProgram(memory_image, initial_program, registers, USER32MODE);
    ir.ResetProgram(memory_image, initial_program, registers, USER32MODE);
    dyncom.Step();
    ir.Step();
    CompareMachines(ir, dyncom);

    constexpr u32 rewritten_sub = 0xE2400001U; // SUB r0, r0, #1
    std::memcpy(dyncom.backing->Vector().data() + sizeof(u32), &rewritten_sub,
                sizeof(rewritten_sub));
    std::memcpy(ir.backing->Vector().data() + sizeof(u32), &rewritten_sub,
                sizeof(rewritten_sub));
    dyncom.cpu->InvalidateCacheRange(CodeBase + sizeof(u32), sizeof(u32));
    ir.cpu->InvalidateCacheRange(CodeBase + sizeof(u32), sizeof(u32));
    dyncom.cpu->SetPC(CodeBase + sizeof(u32));
    ir.cpu->SetPC(CodeBase + sizeof(u32));
    dyncom.cpu->SetReg(0, 10);
    ir.cpu->SetReg(0, 10);
    dyncom.Step();
    ir.Step();
    CompareMachines(ir, dyncom);
    REQUIRE(ir.cpu->GetReg(0) == 9);

    constexpr u32 rewritten_add = 0xE2800005U; // ADD r0, r0, #5
    std::memcpy(dyncom.backing->Vector().data() + sizeof(u32), &rewritten_add,
                sizeof(rewritten_add));
    std::memcpy(ir.backing->Vector().data() + sizeof(u32), &rewritten_add,
                sizeof(rewritten_add));
    dyncom.cpu->ClearInstructionCache();
    ir.cpu->ClearInstructionCache();
    dyncom.cpu->SetPC(CodeBase + sizeof(u32));
    ir.cpu->SetPC(CodeBase + sizeof(u32));
    dyncom.cpu->SetReg(0, 10);
    ir.cpu->SetReg(0, 10);
    dyncom.Step();
    ir.Step();
    CompareMachines(ir, dyncom);
    REQUIRE(ir.cpu->GetReg(0) == 15);
}

TEST_CASE("ARM IR interpreter refreshes fast memory after remapping", "[core][arm][ir]") {
    InterpreterMachine dyncom{false};
    InterpreterMachine ir{true};
    std::vector<u8> memory_image(MappedSize);
    constexpr std::array program = {
        0xE5910000U, // LDR r0, [r1]
        0xE5812004U, // STR r2, [r1, #4]
    };
    constexpr u32 data_address = DataBase + 0x80;
    constexpr u32 original_value = 0x11223344;
    constexpr u32 remapped_value = 0xA1B2C3D4;
    constexpr u32 stored_value = 0x55667788;
    std::memcpy(memory_image.data() + (data_address - CodeBase), &original_value,
                sizeof(original_value));
    std::array<u32, 15> registers{};
    registers[1] = data_address;
    registers[2] = stored_value;
    dyncom.ResetProgram(memory_image, program, registers, USER32MODE);
    ir.ResetProgram(memory_image, program, registers, USER32MODE);
    dyncom.Step();
    ir.Step();
    REQUIRE(dyncom.cpu->GetReg(0) == original_value);
    REQUIRE(ir.cpu->GetReg(0) == original_value);

    auto dyncom_remapped = std::make_shared<BufferMem>(Memory::CITRA_PAGE_SIZE);
    auto ir_remapped = std::make_shared<BufferMem>(Memory::CITRA_PAGE_SIZE);
    std::memcpy(dyncom_remapped->Vector().data() + 0x80, &remapped_value,
                sizeof(remapped_value));
    std::memcpy(ir_remapped->Vector().data() + 0x80, &remapped_value, sizeof(remapped_value));
    dyncom.memory.MapMemoryRegion(*dyncom.page_table, DataBase, Memory::CITRA_PAGE_SIZE,
                                  MemoryRef(dyncom_remapped));
    ir.memory.MapMemoryRegion(*ir.page_table, DataBase, Memory::CITRA_PAGE_SIZE,
                              MemoryRef(ir_remapped));
    dyncom.cpu->SetPC(CodeBase);
    ir.cpu->SetPC(CodeBase);
    dyncom.Run(program.size());
    ir.Run(program.size());
    CompareMachines(ir, dyncom);
    REQUIRE(ir.cpu->GetReg(0) == remapped_value);
    REQUIRE(ir_remapped->Vector() == dyncom_remapped->Vector());
    u32 observed_stored_value{};
    std::memcpy(&observed_stored_value, ir_remapped->Vector().data() + 0x84,
                sizeof(observed_stored_value));
    REQUIRE(observed_stored_value == stored_value);
}

TEST_CASE("ARM IR interpreter switches page tables like dyncom", "[core][arm][ir]") {
    InterpreterMachine dyncom{false};
    InterpreterMachine ir{true};
    std::vector<u8> memory_image(MappedSize);
    constexpr std::array program = {0xE5910000U}; // LDR r0, [r1]
    constexpr u32 data_address = DataBase + 0x100;
    constexpr u32 original_value = 0x10203040;
    constexpr u32 switched_value = 0x90807060;
    std::memcpy(memory_image.data() + (data_address - CodeBase), &original_value,
                sizeof(original_value));
    std::array<u32, 15> registers{};
    registers[1] = data_address;
    dyncom.ResetProgram(memory_image, program, registers, USER32MODE);
    ir.ResetProgram(memory_image, program, registers, USER32MODE);
    dyncom.Step();
    ir.Step();

    auto dyncom_page_table = std::make_shared<Memory::PageTable>();
    auto ir_page_table = std::make_shared<Memory::PageTable>();
    auto dyncom_switched = std::make_shared<BufferMem>(MappedSize);
    auto ir_switched = std::make_shared<BufferMem>(MappedSize);
    dyncom_page_table->Clear();
    ir_page_table->Clear();
    std::copy(dyncom.backing->Vector().begin(), dyncom.backing->Vector().end(),
              dyncom_switched->Vector().begin());
    std::copy(ir.backing->Vector().begin(), ir.backing->Vector().end(),
              ir_switched->Vector().begin());
    std::memcpy(dyncom_switched->Vector().data() + (data_address - CodeBase), &switched_value,
                sizeof(switched_value));
    std::memcpy(ir_switched->Vector().data() + (data_address - CodeBase), &switched_value,
                sizeof(switched_value));
    dyncom.memory.MapMemoryRegion(*dyncom_page_table, CodeBase, MappedSize,
                                  MemoryRef(dyncom_switched));
    ir.memory.MapMemoryRegion(*ir_page_table, CodeBase, MappedSize, MemoryRef(ir_switched));
    dyncom.memory.SetCurrentPageTable(dyncom_page_table);
    ir.memory.SetCurrentPageTable(ir_page_table);
    dyncom.cpu->SetPageTable(dyncom_page_table);
    ir.cpu->SetPageTable(ir_page_table);
    dyncom.cpu->SetPC(CodeBase);
    ir.cpu->SetPC(CodeBase);
    dyncom.Step();
    ir.Step();
    CompareMachines(ir, dyncom);
    REQUIRE(ir.cpu->GetReg(0) == switched_value);
    REQUIRE(ir_switched->Vector() == dyncom_switched->Vector());
}

TEST_CASE("ARM IR interpreter matches dyncom while booting a ROM", "[core][arm][ir][rom]") {
    const char* rom_path = std::getenv("AZAHAR_IR_TEST_ROM");
    if (!rom_path || rom_path[0] == '\0') {
        SKIP("AZAHAR_IR_TEST_ROM is not set");
    }

    u32 loop_count = 100;
    if (const char* loop_count_text = std::getenv("AZAHAR_IR_TEST_LOOPS")) {
        loop_count = static_cast<u32>(std::strtoul(loop_count_text, nullptr, 10));
    }
    REQUIRE(loop_count != 0);
    const RomRunResult dyncom = RunRom(rom_path, false, loop_count);
    INFO("ROM path = " << rom_path);
    INFO("dyncom load/run status = " << static_cast<u32>(dyncom.status));
    REQUIRE(dyncom.status == Core::System::ResultStatus::Success);
    REQUIRE(dyncom.backend == RomRunResult::Backend::Dyncom);
    REQUIRE(dyncom.completed_loops == loop_count);

    const bool repeat_dyncom = std::getenv("AZAHAR_IR_TEST_REPEAT_DYNCOM") != nullptr;
    const RomRunResult ir = RunRom(rom_path, !repeat_dyncom, loop_count);
    INFO("IR load/run status = " << static_cast<u32>(ir.status));
    REQUIRE(ir.status == Core::System::ResultStatus::Success);
    REQUIRE(ir.backend == (repeat_dyncom ? RomRunResult::Backend::Dyncom
                                        : RomRunResult::Backend::IRInterpreter));
    REQUIRE(ir.completed_loops == dyncom.completed_loops);
    REQUIRE(ir.ir_fallback_count == 0);
    if (std::getenv("AZAHAR_IR_TEST_SINGLE_STEP") != nullptr) {
        REQUIRE(ir.loop_ticks.size() == dyncom.loop_ticks.size());
        REQUIRE(ir.loop_core_ticks.size() == dyncom.loop_core_ticks.size());
        REQUIRE(ir.loop_contexts.size() == dyncom.loop_contexts.size());
        REQUIRE(ir.cp15_changes == dyncom.cp15_changes);
        for (std::size_t step = 0; step < ir.loop_ticks.size(); ++step) {
            CAPTURE(step);
            REQUIRE(ir.loop_ticks[step] == dyncom.loop_ticks[step]);
            REQUIRE(ir.loop_core_ticks[step].size() == dyncom.loop_core_ticks[step].size());
            REQUIRE(ir.loop_contexts[step].size() == dyncom.loop_contexts[step].size());
            for (std::size_t core = 0; core < ir.loop_core_ticks[step].size(); ++core) {
                CAPTURE(core);
                REQUIRE(ir.loop_core_ticks[step][core] == dyncom.loop_core_ticks[step][core]);
                CompareThreadContexts(ir.loop_contexts[step][core],
                                      dyncom.loop_contexts[step][core]);
            }
        }
        return;
    }
    if (std::getenv("AZAHAR_IR_TEST_ALLOW_NONDETERMINISM") != nullptr) {
        return;
    }
    INFO("IR global ticks = " << ir.global_ticks);
    INFO("dyncom global ticks = " << dyncom.global_ticks);
    REQUIRE(ir.loop_ticks.size() == dyncom.loop_ticks.size());
    REQUIRE(ir.loop_core_ticks.size() == dyncom.loop_core_ticks.size());
    REQUIRE(ir.loop_contexts.size() == dyncom.loop_contexts.size());
    std::size_t ir_loop = 0;
    std::size_t dyncom_loop = 0;
    std::size_t matched_checkpoints = 0;
    s64 latest_matched_ticks = 0;
    while (ir_loop < ir.loop_ticks.size() && dyncom_loop < dyncom.loop_ticks.size()) {
        if (ir.loop_ticks[ir_loop] < dyncom.loop_ticks[dyncom_loop]) {
            ++ir_loop;
            continue;
        }
        if (dyncom.loop_ticks[dyncom_loop] < ir.loop_ticks[ir_loop]) {
            ++dyncom_loop;
            continue;
        }

        const s64 checkpoint_ticks = ir.loop_ticks[ir_loop];
        CAPTURE(checkpoint_ticks, latest_matched_ticks, ir_loop, dyncom_loop);
        REQUIRE(ir.loop_core_ticks[ir_loop].size() ==
                dyncom.loop_core_ticks[dyncom_loop].size());
        REQUIRE(ir.loop_contexts[ir_loop].size() == dyncom.loop_contexts[dyncom_loop].size());
        for (std::size_t core = 0; core < ir.loop_core_ticks[ir_loop].size(); ++core) {
            CAPTURE(core);
            REQUIRE(ir.loop_core_ticks[ir_loop][core] ==
                    dyncom.loop_core_ticks[dyncom_loop][core]);
            CompareThreadContexts(ir.loop_contexts[ir_loop][core],
                                  dyncom.loop_contexts[dyncom_loop][core]);
        }
        latest_matched_ticks = checkpoint_ticks;
        ++matched_checkpoints;
        ++ir_loop;
        ++dyncom_loop;
    }
    INFO("matched emulated-time checkpoints = " << matched_checkpoints);
    INFO("latest matched ticks = " << latest_matched_ticks);
    REQUIRE(matched_checkpoints != 0);
    const s64 compared_ticks = std::min(ir.global_ticks, dyncom.global_ticks);
    REQUIRE(latest_matched_ticks >= compared_ticks - Core::Timing::MAX_SLICE_LENGTH * 2);

    if (ir.global_ticks == dyncom.global_ticks) {
        REQUIRE(ir.contexts.size() == dyncom.contexts.size());
        for (std::size_t core = 0; core < ir.contexts.size(); ++core) {
            CAPTURE(core);
            CompareThreadContexts(ir.contexts[core], dyncom.contexts[core]);
        }
    }
}
