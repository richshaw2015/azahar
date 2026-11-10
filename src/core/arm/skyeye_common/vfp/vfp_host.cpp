// Copyright 2025 Citra Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#include <bit>
#include <optional>
#include <type_traits>
#include "common/common_types.h"
#include "core/arm/skyeye_common/armstate.h"
#include "core/arm/skyeye_common/vfp/asm_vfp.h"
#include "core/arm/skyeye_common/vfp/vfp.h"
#include "core/arm/skyeye_common/vfp/vfp_helper.h"
#include "core/arm/skyeye_common/vfp/vfp_host.h"

#if defined(__aarch64__)

namespace VfpHost {
namespace {

// AArch64 FPSR cumulative-exception bits share the VFP FPSCR layout:
// IOC=bit0 DZC=bit1 OFC=bit2 UFC=bit3 IXC=bit4 IDC=bit7.
constexpr u64 kHostExcMask = 0x9F;

u64 ReadFpcr() {
    u64 v;
    asm volatile("mrs %0, fpcr" : "=r"(v));
    return v;
}

void WriteFpcr(u64 v) {
    asm volatile("msr fpcr, %0" ::"r"(v));
}

u64 ReadFpsr() {
    u64 v;
    asm volatile("mrs %0, fpsr" : "=r"(v));
    return v;
}

void WriteFpsr(u64 v) {
    asm volatile("msr fpsr, %0" ::"r"(v));
}

// RAII host FP environment: mirror the guest rounding mode into FPCR and
// clear FPSR exception bits before the op, then restore the process-default
// FPCR on scope exit so the emulator's own floating-point code never sees
// guest state. Denormal/NaN inputs and outputs are all bounced to the
// softfloat path, so FZ and DN are never observable and stay clear.
struct FpEnv {
    explicit FpEnv(u32 fpscr) : saved_fpcr(ReadFpcr()) {
        WriteFpcr(fpscr & FPSCR_RMODE_MASK);
        WriteFpsr(0);
    }
    ~FpEnv() {
        WriteFpcr(saved_fpcr);
    }
    u32 Exc() const {
        return static_cast<u32>(ReadFpsr() & kHostExcMask);
    }
    u64 saved_fpcr;
};

// "Normal or zero" domain: exponent neither denormal(0 with mantissa) nor
// inf/nan(255). This is the only operand/result class handled on the host.
bool IsNormalOrZeroF32(u32 bits) {
    const u32 e = bits & 0x7F800000u;
    return e != 0x7F800000u && (e != 0 || (bits & 0x007FFFFFu) == 0);
}

bool IsNormalOrZeroF64(u64 bits) {
    const u64 e = bits & 0x7FF0000000000000ull;
    return e != 0x7FF0000000000000ull && (e != 0 || (bits & 0x000FFFFFFFFFFFFFull) == 0);
}

// Every FP-producing instruction is a volatile asm: without `volatile` the
// compiler may sink/hoist it across the msr/mrs FPSR accesses (it does not
// model the FP flags as a side effect), which silently loses exception bits.
// Volatile asm statements are never reordered relative to each other, so the
// op stays pinned between WriteFpsr(0) and ReadFpsr().
#define FP_BINOP(name, type, opc)                                                              \
    type name(type a, type b) {                                                                \
        type r;                                                                                \
        asm volatile(opc : "=w"(r) : "w"(a), "w"(b));                                          \
        return r;                                                                              \
    }

FP_BINOP(FAddF32, float, "fadd %s0, %s1, %s2")
FP_BINOP(FSubF32, float, "fsub %s0, %s1, %s2")
FP_BINOP(FMulF32, float, "fmul %s0, %s1, %s2")
FP_BINOP(FDivF32, float, "fdiv %s0, %s1, %s2")
FP_BINOP(FAddF64, double, "fadd %d0, %d1, %d2")
FP_BINOP(FSubF64, double, "fsub %d0, %d1, %d2")
FP_BINOP(FMulF64, double, "fmul %d0, %d1, %d2")
FP_BINOP(FDivF64, double, "fdiv %d0, %d1, %d2")

float FSqrtF32(float a) {
    float r;
    asm volatile("fsqrt %s0, %s1" : "=w"(r) : "w"(a));
    return r;
}

double FSqrtF64(double a) {
    double r;
    asm volatile("fsqrt %d0, %d1" : "=w"(r) : "w"(a));
    return r;
}

// Widening s->d is exact and never raises; narrowing d->s rounds per FPCR.
double FCvtSD(float a) {
    double r;
    asm volatile("fcvt %d0, %s1" : "=w"(r) : "w"(a));
    return r;
}

float FCvtDS(double a) {
    float r;
    asm volatile("fcvt %s0, %d1" : "=w"(r) : "w"(a));
    return r;
}

// Integer <-> float; conversion direction and element size encoded directly.
float UcvtfF32(u32 v) {
    float r;
    asm volatile("ucvtf %s0, %w1" : "=w"(r) : "r"(v));
    return r;
}

float ScvtfF32(s32 v) {
    float r;
    asm volatile("scvtf %s0, %w1" : "=w"(r) : "r"(v));
    return r;
}

double UcvtfF64(u32 v) {
    double r;
    asm volatile("ucvtf %d0, %w1" : "=w"(r) : "r"(v));
    return r;
}

double ScvtfF64(s32 v) {
    double r;
    asm volatile("scvtf %d0, %w1" : "=w"(r) : "r"(v));
    return r;
}

u32 FcvtzuF32(float f) {
    u32 r;
    asm volatile("fcvtzu %w0, %s1" : "=r"(r) : "w"(f));
    return r;
}

s32 FcvtzsF32(float f) {
    s32 r;
    asm volatile("fcvtzs %w0, %s1" : "=r"(r) : "w"(f));
    return r;
}

u32 FcvtzuF64(double f) {
    u32 r;
    asm volatile("fcvtzu %w0, %d1" : "=r"(r) : "w"(f));
    return r;
}

s32 FcvtzsF64(double f) {
    s32 r;
    asm volatile("fcvtzs %w0, %d1" : "=r"(r) : "w"(f));
    return r;
}

u64 GetDouble(const ARMul_State* state, unsigned int reg) {
    return (static_cast<u64>(state->ExtReg[reg * 2 + 1]) << 32) | state->ExtReg[reg * 2];
}

void PutDouble(ARMul_State* state, unsigned int reg, u64 val) {
    state->ExtReg[reg * 2] = static_cast<u32>(val);
    state->ExtReg[reg * 2 + 1] = static_cast<u32>(val >> 32);
}

// fcmp result: ZC equal, N less, C greater. NaN is filtered by callers.
u32 CompareBits(float a, float b) {
    if (a == b)
        return FPSCR_ZFLAG | FPSCR_CFLAG;
    return a < b ? FPSCR_NFLAG : FPSCR_CFLAG;
}

u32 CompareBits(double a, double b) {
    if (a == b)
        return FPSCR_ZFLAG | FPSCR_CFLAG;
    return a < b ? FPSCR_NFLAG : FPSCR_CFLAG;
}

// Binary op selection, mirrored on fops[] order in vfpsingle.cpp.
enum class BinaryOp {
    Mac,  // sd = sd + sn*sm
    Msc,  // sd = sn*sm - sd
    Mul,
    Add,
    Nmac, // sd = sd - sn*sm
    Nmsc, // sd = -(sd + sn*sm)
    Nmul, // sd = -(sn*sm)
    Sub,
    Div,
};

std::optional<BinaryOp> DecodeBinaryOp(u32 inst) {
    switch (inst & FOP_MASK) {
    case FOP_FMAC:
        return BinaryOp::Mac;
    case FOP_FMSC:
        return BinaryOp::Msc;
    case FOP_FMUL:
        return BinaryOp::Mul;
    case FOP_FADD:
        return BinaryOp::Add;
    case FOP_FNMAC:
        return BinaryOp::Nmac;
    case FOP_FNMSC:
        return BinaryOp::Nmsc;
    case FOP_FNMUL:
        return BinaryOp::Nmul;
    case FOP_FSUB:
        return BinaryOp::Sub;
    case FOP_FDIV:
        return BinaryOp::Div;
    default:
        return std::nullopt;
    }
}

bool IsMacOp(BinaryOp b) {
    return b == BinaryOp::Mac || b == BinaryOp::Msc || b == BinaryOp::Nmac ||
           b == BinaryOp::Nmsc;
}

// Typed wrappers so the templated RunBinary resolves to the right width.
float OpAdd(float a, float b) {
    return FAddF32(a, b);
}
double OpAdd(double a, double b) {
    return FAddF64(a, b);
}
float OpSub(float a, float b) {
    return FSubF32(a, b);
}
double OpSub(double a, double b) {
    return FSubF64(a, b);
}
float OpMul(float a, float b) {
    return FMulF32(a, b);
}
double OpMul(double a, double b) {
    return FMulF64(a, b);
}
float OpDiv(float a, float b) {
    return FDivF32(a, b);
}
double OpDiv(double a, double b) {
    return FDivF64(a, b);
}
float OpSqrt(float a) {
    return FSqrtF32(a);
}
double OpSqrt(double a) {
    return FSqrtF64(a);
}

// The VFP accumulate ops keep an internal wider product, not a fused FMA.
// Double precision reproduces that intermediate almost exactly (a 24x24-bit
// product fits in 53 bits), which is far closer to the softfloat path than
// either an f32-rounded intermediate or a fused fmadd.
float MacResult(BinaryOp b, float d, float n, float m) {
    const double prod = FMulF64(FCvtSD(n), FCvtSD(m));
    const double dd = FCvtSD(d);
    float r;
    switch (b) {
    case BinaryOp::Mac:
        r = FCvtDS(FAddF64(dd, prod));
        break;
    case BinaryOp::Msc:
        r = FCvtDS(FSubF64(prod, dd));
        break;
    case BinaryOp::Nmac:
        r = FCvtDS(FSubF64(dd, prod));
        break;
    default:
        r = FCvtDS(FAddF64(dd, prod));
        return std::bit_cast<float>(std::bit_cast<u32>(r) ^ 0x80000000u);
    }
    return r;
}

template <typename F>
F RunBinary(BinaryOp b, F d, F n, F m) {
    if constexpr (std::is_same_v<F, float>) {
        if (IsMacOp(b))
            return MacResult(b, d, n, m);
    }
    switch (b) {
    case BinaryOp::Mul:
        return OpMul(n, m);
    case BinaryOp::Add:
        return OpAdd(n, m);
    case BinaryOp::Nmul: {
        // Sign-flip is exact and needs no FP ordering constraints.
        const F p = OpMul(n, m);
        if constexpr (std::is_same_v<F, float>) {
            return std::bit_cast<float>(std::bit_cast<u32>(p) ^ 0x80000000u);
        } else {
            return std::bit_cast<double>(std::bit_cast<u64>(p) ^ 0x8000000000000000ull);
        }
    }
    case BinaryOp::Sub:
        return OpSub(n, m);
    default:
        return OpDiv(n, m);
    }
}

// ---- single precision ----

std::optional<u32> RunSingle(ARMul_State* state, u32 inst, u32 fpscr) {
    const u32 op = inst & FOP_MASK;

    if (op != FOP_EXT) {
        const auto bin = DecodeBinaryOp(inst);
        if (!bin)
            return std::nullopt;

        const unsigned int sd = vfp_get_sd(inst);
        const unsigned int sn = vfp_get_sn(inst);
        const unsigned int sm = vfp_get_sm(inst);
        const u32 n_bits = state->ExtReg[sn];
        const u32 m_bits = state->ExtReg[sm];
        if (!IsNormalOrZeroF32(n_bits) || !IsNormalOrZeroF32(m_bits))
            return std::nullopt;
        const u32 d_bits = state->ExtReg[sd];
        if (IsMacOp(*bin) && !IsNormalOrZeroF32(d_bits))
            return std::nullopt;

        FpEnv env(fpscr);
        const float r = RunBinary(*bin, std::bit_cast<float>(d_bits),
                                   std::bit_cast<float>(n_bits), std::bit_cast<float>(m_bits));
        const u32 exc = env.Exc();
        const u32 r_bits = std::bit_cast<u32>(r);
        if (!IsNormalOrZeroF32(r_bits))
            return std::nullopt;
        state->ExtReg[sd] = r_bits;
        return exc;
    }

    const u32 sd = vfp_get_sd(inst);
    const u32 sm = vfp_get_sm(inst);
    switch (FEXT_TO_IDX(inst)) {
    case 0: // FCPY
        state->ExtReg[sd] = state->ExtReg[sm];
        return 0;
    case 1: // FABS
        state->ExtReg[sd] = state->ExtReg[sm] & 0x7FFFFFFFu;
        return 0;
    case 2: // FNEG
        state->ExtReg[sd] = state->ExtReg[sm] ^ 0x80000000u;
        return 0;
    case 3: { // FSQRT
        const u32 m_bits = state->ExtReg[sm];
        if (!IsNormalOrZeroF32(m_bits))
            return std::nullopt;
        FpEnv env(fpscr);
        const float r = FSqrtF32(std::bit_cast<float>(m_bits));
        const u32 exc = env.Exc();
        const u32 r_bits = std::bit_cast<u32>(r);
        if (!IsNormalOrZeroF32(r_bits))
            return std::nullopt;
        state->ExtReg[sd] = r_bits;
        return exc;
    }
    case 8:      // FCMP
    case 9: {    // FCMPE
        const u32 d_bits = state->ExtReg[sd];
        const u32 m_bits = state->ExtReg[sm];
        // Bounce anything outside the normal-or-zero domain: NaN affects the
        // FCMP/FCMPE IOC distinction, and softfloat reports IDC for denormal
        // inputs which the host compare cannot reproduce.
        if (!IsNormalOrZeroF32(d_bits) || !IsNormalOrZeroF32(m_bits))
            return std::nullopt;
        return CompareBits(std::bit_cast<float>(d_bits), std::bit_cast<float>(m_bits));
    }
    case 10:     // FCMPZ
    case 11: {   // FCMPEZ
        const u32 d_bits = state->ExtReg[sd];
        if (!IsNormalOrZeroF32(d_bits))
            return std::nullopt;
        return CompareBits(std::bit_cast<float>(d_bits), 0.0f);
    }
    case 15: { // FCVTD: s -> d
        const u32 m_bits = state->ExtReg[sm];
        if (!IsNormalOrZeroF32(m_bits))
            return std::nullopt;
        const double r = FCvtSD(std::bit_cast<float>(m_bits));
        PutDouble(state, vfp_get_dd(inst), std::bit_cast<u64>(r));
        return 0;
    }
    case 16: { // FUITO: u32 -> s
        const u32 m_bits = state->ExtReg[sm];
        FpEnv env(fpscr);
        const float r = UcvtfF32(m_bits);
        const u32 exc = env.Exc();
        state->ExtReg[sd] = std::bit_cast<u32>(r);
        return exc;
    }
    case 17: { // FSITO: s32 -> s
        const s32 m_val = static_cast<s32>(state->ExtReg[sm]);
        FpEnv env(fpscr);
        const float r = ScvtfF32(m_val);
        const u32 exc = env.Exc();
        state->ExtReg[sd] = std::bit_cast<u32>(r);
        return exc;
    }
    case 24:   // FTOUI
    case 25: { // FTOUIZ
        if (FEXT_TO_IDX(inst) == 24 && (fpscr & FPSCR_RMODE_MASK) != FPSCR_ROUND_TOZERO)
            return std::nullopt;
        const u32 m_bits = state->ExtReg[sm];
        if (!IsNormalOrZeroF32(m_bits))
            return std::nullopt;
        // Negative nonzero inputs diverge between guest and host saturation.
        if ((m_bits & 0x80000000u) != 0 && (m_bits & 0x7FFFFFFFu) != 0)
            return std::nullopt;
        FpEnv env(fpscr);
        const u32 r = FcvtzuF32(std::bit_cast<float>(m_bits));
        const u32 exc = env.Exc();
        state->ExtReg[sd] = r;
        return exc;
    }
    case 26:   // FTOSI
    case 27: { // FTOSIZ
        if (FEXT_TO_IDX(inst) == 26 && (fpscr & FPSCR_RMODE_MASK) != FPSCR_ROUND_TOZERO)
            return std::nullopt;
        const u32 m_bits = state->ExtReg[sm];
        if (!IsNormalOrZeroF32(m_bits))
            return std::nullopt;
        FpEnv env(fpscr);
        const s32 r = FcvtzsF32(std::bit_cast<float>(m_bits));
        const u32 exc = env.Exc();
        state->ExtReg[sd] = static_cast<u32>(r);
        return exc;
    }
    default:
        return std::nullopt;
    }
}

// ---- double precision ----

std::optional<u32> RunDouble(ARMul_State* state, u32 inst, u32 fpscr) {
    const u32 op = inst & FOP_MASK;

    if (op != FOP_EXT) {
        const auto bin = DecodeBinaryOp(inst);
        // Double-precision MACs keep a wider intermediate product in softfloat
        // that no host type can reproduce; always take the reference path.
        if (!bin || IsMacOp(*bin))
            return std::nullopt;

        const unsigned int dd = vfp_get_dd(inst);
        const unsigned int dn = vfp_get_dn(inst);
        const unsigned int dm = vfp_get_dm(inst);
        const u64 n_bits = GetDouble(state, dn);
        const u64 m_bits = GetDouble(state, dm);
        if (!IsNormalOrZeroF64(n_bits) || !IsNormalOrZeroF64(m_bits))
            return std::nullopt;

        FpEnv env(fpscr);
        const double r = RunBinary(*bin, 0.0, std::bit_cast<double>(n_bits),
                                   std::bit_cast<double>(m_bits));
        const u32 exc = env.Exc();
        const u64 r_bits = std::bit_cast<u64>(r);
        if (!IsNormalOrZeroF64(r_bits))
            return std::nullopt;
        PutDouble(state, dd, r_bits);
        return exc;
    }

    const u32 dd = vfp_get_dd(inst);
    const u32 dm = vfp_get_dm(inst);
    const u32 sd = vfp_get_sd(inst);
    const u32 sm = vfp_get_sm(inst);
    switch (FEXT_TO_IDX(inst)) {
    case 0: // FCPY
        PutDouble(state, dd, GetDouble(state, dm));
        return 0;
    case 1: // FABS
        PutDouble(state, dd, GetDouble(state, dm) & ~0x8000000000000000ull);
        return 0;
    case 2: // FNEG
        PutDouble(state, dd, GetDouble(state, dm) ^ 0x8000000000000000ull);
        return 0;
    case 3: { // FSQRT
        const u64 m_bits = GetDouble(state, dm);
        if (!IsNormalOrZeroF64(m_bits))
            return std::nullopt;
        FpEnv env(fpscr);
        const double r = FSqrtF64(std::bit_cast<double>(m_bits));
        const u32 exc = env.Exc();
        const u64 r_bits = std::bit_cast<u64>(r);
        if (!IsNormalOrZeroF64(r_bits))
            return std::nullopt;
        PutDouble(state, dd, r_bits);
        return exc;
    }
    case 8:      // FCMP
    case 9: {    // FCMPE
        const u64 d_bits = GetDouble(state, dd);
        const u64 m_bits = GetDouble(state, dm);
        if (!IsNormalOrZeroF64(d_bits) || !IsNormalOrZeroF64(m_bits))
            return std::nullopt;
        return CompareBits(std::bit_cast<double>(d_bits), std::bit_cast<double>(m_bits));
    }
    case 10:     // FCMPZ
    case 11: {   // FCMPEZ
        const u64 d_bits = GetDouble(state, dd);
        if (!IsNormalOrZeroF64(d_bits))
            return std::nullopt;
        return CompareBits(std::bit_cast<double>(d_bits), 0.0);
    }
    case 15: { // FCVTS: d -> s
        const u64 m_bits = GetDouble(state, dm);
        if (!IsNormalOrZeroF64(m_bits))
            return std::nullopt;
        FpEnv env(fpscr);
        const float r = FCvtDS(std::bit_cast<double>(m_bits));
        const u32 exc = env.Exc();
        const u32 r_bits = std::bit_cast<u32>(r);
        if (!IsNormalOrZeroF32(r_bits))
            return std::nullopt;
        state->ExtReg[sd] = r_bits;
        return exc;
    }
    case 16: { // FUITO: u32 -> d
        const u32 m_bits = state->ExtReg[sm];
        FpEnv env(fpscr);
        const double r = UcvtfF64(m_bits);
        const u32 exc = env.Exc();
        PutDouble(state, dd, std::bit_cast<u64>(r));
        return exc;
    }
    case 17: { // FSITO: s32 -> d
        const s32 m_val = static_cast<s32>(state->ExtReg[sm]);
        FpEnv env(fpscr);
        const double r = ScvtfF64(m_val);
        const u32 exc = env.Exc();
        PutDouble(state, dd, std::bit_cast<u64>(r));
        return exc;
    }
    case 24:   // FTOUI
    case 25: { // FTOUIZ
        if (FEXT_TO_IDX(inst) == 24 && (fpscr & FPSCR_RMODE_MASK) != FPSCR_ROUND_TOZERO)
            return std::nullopt;
        const u64 m_bits = GetDouble(state, dm);
        if (!IsNormalOrZeroF64(m_bits))
            return std::nullopt;
        if ((m_bits & 0x8000000000000000ull) != 0 && (m_bits & 0x7FFFFFFFFFFFFFFFull) != 0)
            return std::nullopt;
        FpEnv env(fpscr);
        const u32 r = FcvtzuF64(std::bit_cast<double>(m_bits));
        const u32 exc = env.Exc();
        state->ExtReg[sd] = r;
        return exc;
    }
    case 26:   // FTOSI
    case 27: { // FTOSIZ
        if (FEXT_TO_IDX(inst) == 26 && (fpscr & FPSCR_RMODE_MASK) != FPSCR_ROUND_TOZERO)
            return std::nullopt;
        const u64 m_bits = GetDouble(state, dm);
        if (!IsNormalOrZeroF64(m_bits))
            return std::nullopt;
        FpEnv env(fpscr);
        const s32 r = FcvtzsF64(std::bit_cast<double>(m_bits));
        const u32 exc = env.Exc();
        state->ExtReg[sd] = static_cast<u32>(r);
        return exc;
    }
    default:
        return std::nullopt;
    }
}

} // namespace

std::optional<u32> TryExecute(ARMul_State* state, u32 inst, u32 fpscr) {
    // Scalar only: real games never use the VFP vector-mode fields.
    if ((fpscr & FPSCR_LENGTH_MASK) != 0) {
        g_host_misses.fetch_add(1, std::memory_order_relaxed);
        return std::nullopt;
    }
    const auto r = ((inst >> 8) & 1) != 0 ? RunDouble(state, inst, fpscr)
                                          : RunSingle(state, inst, fpscr);
    (r ? g_host_hits : g_host_misses).fetch_add(1, std::memory_order_relaxed);
    return r;
}

} // namespace VfpHost

#else

namespace VfpHost {

std::optional<u32> TryExecute(ARMul_State*, u32, u32) {
    return std::nullopt;
}

} // namespace VfpHost

#endif
