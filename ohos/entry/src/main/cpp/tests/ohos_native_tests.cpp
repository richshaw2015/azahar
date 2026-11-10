// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

// In-app Catch2 runner for the OHOS build.
//
// Retail devices do not allow the hdc shell to exec arbitrary binaries, so
// the standalone tests_ohos ELF cannot run there. Instead the same Catch2
// test sources are compiled into libazahar_ohos.so when ENABLE_OHOS_TESTS is
// on and invoked through the NAPI runNativeTests() export (triggered by
// `aa start --ps runNativeTests true`). Output is streamed line-by-line to
// hilog under the AzaharNativeTests tag as tests run, so progress (and the
// location of any hang or crash) is visible in the device log.

#include "common/logging/backend.h"

#include <catch2/catch_session.hpp>
#include <catch2/catch_test_case_info.hpp>
#include <catch2/internal/catch_stdstreams.hpp>
#include <catch2/reporters/catch_reporter_event_listener.hpp>
#include <catch2/reporters/catch_reporter_registrars.hpp>

#include <cstdio>

#include <hilog/log.h>

#include <string>

namespace {

constexpr unsigned int kLogDomain = 0x3203;
constexpr char kLogTag[] = "AzaharNativeTests";

void LogLine(const std::string& line) {
    // hilog truncates very long messages; emit one line per call.
    OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag, "%{public}s", line.c_str());
}

// streambuf that forwards every newline-terminated chunk to hilog in real
// time. Catch2 writes through Catch::cout(), which we redirect here.
class HilogStreamBuf : public std::streambuf {
public:
    HilogStreamBuf() {
        // Tee to a sandbox file as well: hilog's buffer rotates in seconds on
        // busy devices, which loses long suite summaries.
        file_ = std::fopen("/data/storage/el2/base/files/native_tests.log", "w");
    }
    ~HilogStreamBuf() override {
        if (file_)
            std::fclose(file_);
    }

protected:
    int_type overflow(int_type ch) override {
        if (ch == traits_type::eof()) {
            return traits_type::not_eof(ch);
        }
        const char c = static_cast<char>(ch);
        if (c == '\n') {
            FlushLine();
        } else {
            pending_.push_back(c);
            if (pending_.size() > 900) {
                FlushLine();
            }
        }
        return ch;
    }

    int sync() override {
        FlushLine();
        return 0;
    }

private:
    void FlushLine() {
        if (!pending_.empty()) {
            // Write to the file first: if the hilog socket blocks, the file
            // still records progress up to the exact point of the stall.
            if (file_) {
                std::fwrite(pending_.data(), 1, pending_.size(), file_);
                std::fputc('\n', file_);
                std::fflush(file_);
            }
            LogLine(pending_);
            pending_.clear();
        }
    }

    std::string pending_;
    std::FILE* file_{};
};

// Emit one line per test case start so a hang can be attributed to the exact
// test in progress even though the console reporter stays silent on success.
class ProgressListener : public Catch::EventListenerBase {
public:
    using EventListenerBase::EventListenerBase;
    void testCaseStarting(const Catch::TestCaseInfo& info) override {
        Catch::cout() << "=== running: " << info.name << "\n";
    }
};

CATCH_REGISTER_LISTENER(ProgressListener)

} // namespace

std::string AzaharOhosRunNativeTests(const std::string& filter) {
    Common::Log::EnableLoggingForTests();
    HilogStreamBuf hilog_buf;
    auto* old_buf = Catch::cout().rdbuf(&hilog_buf);

    LogLine("runNativeTests: session starting" +
            (filter.empty() ? std::string{} : " filter=" + filter));
    Catch::Session session;
    const char* argv[] = {"tests_ohos", filter.c_str()};
    const int rc = session.run(filter.empty() ? 1 : 2, argv);

    Catch::cout().rdbuf(old_buf);
    LogLine("native tests exit code: " + std::to_string(rc));
    return "exit=" + std::to_string(rc);
}

// ---------------------------------------------------------------------------
// Crash probe: runs the load/store fastmem test program directly (no Catch2)
// under a SIGSEGV handler that dumps the fault address + host registers so a
// bad asm memory access can be mapped back to the faulting instruction.
// Trigger: `aa start --ps asmCrashProbe true`.
// ---------------------------------------------------------------------------
#include <signal.h>
#include <ucontext.h>
#include <unistd.h>

#include "common/settings.h"
#include "core/arm/ir/arm_ir_interpreter.h"
#include "core/core.h"
#include "core/core_timing.h"
#include "tests/core/arm/arm_test_common.h"

#if defined(__aarch64__)
#include "core/arm/asm/arm_asm_exec.h"
#endif

namespace {

void CrashProbeSegv(int sig, siginfo_t* si, void* ucp) {
    auto* mc = &static_cast<ucontext_t*>(ucp)->uc_mcontext;
    uintptr_t run_addr = 0;
#if defined(__aarch64__)
    run_addr = reinterpret_cast<uintptr_t>(&citra_asm_run);
#endif
    OH_LOG_Print(LOG_APP, LOG_FATAL, kLogDomain, kLogTag,
                 "SEGV addr=%{public}p pc=%{public}llx asmrun=%{public}p "
                 "x8=%{public}llx x9=%{public}llx x16=%{public}llx x19=%{public}llx "
                 "x20=%{public}llx x24=%{public}llx x25=%{public}llx x27=%{public}llx x28=%{public}llx",
                 si->si_addr, (unsigned long long)mc->pc, (void*)run_addr,
                 (unsigned long long)mc->regs[8], (unsigned long long)mc->regs[9],
                 (unsigned long long)mc->regs[16], (unsigned long long)mc->regs[19],
                 (unsigned long long)mc->regs[20], (unsigned long long)mc->regs[24],
                 (unsigned long long)mc->regs[25], (unsigned long long)mc->regs[27],
                 (unsigned long long)mc->regs[28]);
    _exit(128 + sig);
}

} // namespace

std::string AzaharOhosAsmCrashProbe() {
    struct sigaction sa {};
    sa.sa_sigaction = CrashProbeSegv;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, nullptr);
    sigaction(SIGBUS, &sa, nullptr);

    LogLine("asmCrashProbe: building machine");
    ArmTests::TestEnvironment env(true);
    Core::Timing timer(1, 100, 0);
    auto cpu = std::make_unique<Core::ARM_IRInterpreter>(
        Core::System::GetInstance(), env.GetMemory(), USER32MODE, 0, timer.GetTimer(0));

    // iter41 of "randomized multi-instruction sequences" (mt19937 seed
    // 0x41534D21): the sequence that SIGSEGVs in the suite.
    const u32 program[] = {
        0xE0F34905, // sbcs r9, r3, r5, lsl #18
        0xE3996845, // ldr  r6, [r9, r5, lsr #16]
        0xE0DA590E, // adcs r5, r10, r14, lsl #18
        0xE0A57B07, // adc  r7, r5, r7, lsl #22
        0xE5916037, // ldr  r6, [r1, #0x37]
        0xE0202F05, // eor  r2, r0, r5, lsl #30
        0xE5C22028, // strb r2, [r2, #0x28]
        0xEAFFFFFE, // b .
    };
    for (size_t i = 0; i < sizeof(program) / sizeof(u32); ++i) {
        env.GetMemory().Write32(static_cast<u32>(i * 4), program[i]);
    }
    const u32 regs[15] = {0x12345678, 0x1000, 0x1004, 0x9ABCDEF0, 0xFFFF0000,
                          0x0000FFFF, 1,      0x80000000, 0x7FFFFFFF, 0xDEADBEEF,
                          3,         0x1555, 0xCAFEBABE, 0x1800, 0x40};
    for (int i = 0; i < 15; ++i) {
        cpu->SetReg(i, regs[i]);
    }
    cpu->SetCPSR(USER32MODE);
    cpu->SetPC(0);
    cpu->SetVFPSystemReg(VFP_FPEXC, 1U << 30);
    Settings::values.use_cpu_asm_interpreter.SetValue(true);
    Settings::values.cpu_asm_verify.SetValue(false);

    LogLine("asmCrashProbe: running");
    timer.GetTimer(0)->Advance();
    timer.GetTimer(0)->SetNextSlice(64);
    cpu->Run();
    LogLine("asmCrashProbe: survived the run");
    return "ok";
}
