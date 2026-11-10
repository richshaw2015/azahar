// Copyright 2025 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the LICENSE.txt file included.

#include <catch2/catch_test_macros.hpp>

#include "common/hacks/hack_manager.h"

using namespace Common::Hacks;

TEST_CASE("Hacks[UnknownTitleDefaults]", "[common]") {
    constexpr u64 unknown_title = 0x0004000000000000;
    for (HackType type :
         {HackType::SKIP_SLOW_DRAW, HackType::CPU_USAGE_LIMIT, HackType::FMV_HACK,
          HackType::FORCE_NEW_3DS}) {
        REQUIRE(hack_manager.GetHack(type, unknown_title) == nullptr);
        REQUIRE(hack_manager.GetHackAllowMode(type, unknown_title) == HackAllowMode::ALLOW);
    }
}

TEST_CASE("Hacks[MmjQuirkTitles]", "[common]") {
    // Tales of the Abyss: skip_slow_draw + display_transfer fixup
    REQUIRE(hack_manager.GetHackAllowMode(HackType::SKIP_SLOW_DRAW, 0x0004000000061300) ==
            HackAllowMode::FORCE);
    REQUIRE(hack_manager.GetHackAllowMode(HackType::DISPLAY_TRANSFER_FIXUP, 0x0004000000061300) ==
            HackAllowMode::FORCE);
    REQUIRE(hack_manager.GetHackAllowMode(HackType::SKIP_SLOW_DRAW, 0x000400000018E900) ==
            HackAllowMode::FORCE); // My Hero Academia

    // Mario Kart 7: skip_texture_copy
    REQUIRE(hack_manager.GetHackAllowMode(HackType::SKIP_TEXTURE_COPY, 0x0004000000030800) ==
            HackAllowMode::FORCE);

    // Lord of Magna: cpu_usage_limit + skip_cpu_write
    REQUIRE(hack_manager.GetHackAllowMode(HackType::CPU_USAGE_LIMIT, 0x0004000000164300) ==
            HackAllowMode::FORCE);
    REQUIRE(hack_manager.GetHackAllowMode(HackType::SKIP_CPU_WRITE, 0x0004000000164300) ==
            HackAllowMode::FORCE);

    // Danball Senki WARS: y2r skip conversion
    REQUIRE(hack_manager.GetHackAllowMode(HackType::Y2R_SKIP_CONVERSION, 0x00040000000F4000) ==
            HackAllowMode::FORCE);

    // Star Fox 64: disable clip planes
    REQUIRE(hack_manager.GetHackAllowMode(HackType::DISABLE_CLIP_PLANES, 0x0004000000030400) ==
            HackAllowMode::FORCE);

    // Attack on Titan: force linear filter
    REQUIRE(hack_manager.GetHackAllowMode(HackType::FORCE_LINEAR_FILTER, 0x00040000000DF800) ==
            HackAllowMode::FORCE);

    // Xenoblade Chronicles 3D: force New 3DS
    REQUIRE(hack_manager.GetHackAllowMode(HackType::FORCE_NEW_3DS, 0x000400000F700100) ==
            HackAllowMode::FORCE);

    // Luigi's Mansion: Dark Moon — FMV hack, cpu limit, skip texture copy, new 3DS
    REQUIRE(hack_manager.GetHackAllowMode(HackType::FMV_HACK, 0x00040000000D0000) ==
            HackAllowMode::FORCE);
    REQUIRE(hack_manager.GetHackAllowMode(HackType::CPU_USAGE_LIMIT, 0x00040000000D0000) ==
            HackAllowMode::FORCE);
    REQUIRE(hack_manager.GetHackAllowMode(HackType::SKIP_TEXTURE_COPY, 0x00040000000D0000) ==
            HackAllowMode::FORCE);
    REQUIRE(hack_manager.GetHackAllowMode(HackType::FORCE_NEW_3DS, 0x00040000000D0000) ==
            HackAllowMode::FORCE);
}

TEST_CASE("Hacks[CpuLimitShiftData]", "[common]") {
    const auto* hack = hack_manager.GetHack(HackType::CPU_USAGE_LIMIT, 0x000400000007C700);
    REQUIRE(hack != nullptr);
    const auto* data = static_cast<const CpuLimitData*>(hack->hack_data);
    REQUIRE(data != nullptr);
    // Mario Tennis Open uses the {2,4,2,2} pattern.
    REQUIRE(data->shifts == std::array<u32, 4>{2, 4, 2, 2});

    hack = hack_manager.GetHack(HackType::CPU_USAGE_LIMIT, 0x000400000008FE00);
    REQUIRE(hack != nullptr);
    data = static_cast<const CpuLimitData*>(hack->hack_data);
    REQUIRE(data != nullptr);
    // 1001 Spikes uses the default {1,4,2,2} pattern.
    REQUIRE(data->shifts == std::array<u32, 4>{1, 4, 2, 2});

    hack = hack_manager.GetHack(HackType::CPU_USAGE_LIMIT, 0x000400000F700800);
    REQUIRE(hack != nullptr);
    data = static_cast<const CpuLimitData*>(hack->hack_data);
    REQUIRE(data != nullptr);
    // The Binding of Isaac: Rebirth uses the {1,1,1,1} pattern.
    REQUIRE(data->shifts == std::array<u32, 4>{1, 1, 1, 1});
}

TEST_CASE("Hacks[PerfQuirkClassification]", "[common]") {
    // Speed-vs-accuracy quirks gated behind the game_perf_hacks setting.
    for (const HackType type :
         {HackType::CPU_USAGE_LIMIT, HackType::SKIP_SLOW_DRAW, HackType::SKIP_CPU_WRITE,
          HackType::SKIP_TEXTURE_COPY, HackType::Y2R_SKIP_CONVERSION,
          HackType::DISABLE_CLIP_PLANES, HackType::FORCE_LINEAR_FILTER}) {
        REQUIRE(IsPerfQuirk(type));
    }

    // Compatibility quirks that must keep applying unconditionally.
    for (const HackType type : {HackType::FORCE_NEW_3DS, HackType::DISPLAY_TRANSFER_FIXUP,
                                HackType::FMV_HACK, HackType::ACCURATE_MULTIPLICATION,
                                HackType::RIGHT_EYE_DISABLE}) {
        REQUIRE_FALSE(IsPerfQuirk(type));
    }
}

TEST_CASE("Hacks[AccurateMulConflictResolution]", "[common]") {
    // Titles MMJ ran with accurate_mul=FAST but Azahar requires for correct
    // rendering must keep the upstream FORCE entry, not the ported DISALLOW.
    for (const u64 title_id : {0x0004000000033400ull, 0x0004000000033500ull,
                               0x0004000000033600ull, // Ocarina of Time 3D
                               0x00040000001B8F00ull, 0x00040000001B9000ull,
                               0x0004000000194B00ull, // M&L: Superstar Saga
                               0x00040000001D1400ull, 0x00040000001D1500ull,
                               0x00040000001CA900ull, // M&L: Bowser's Inside Story
                               0x0004000000132600ull, 0x0004000000132700ull,
                               0x0004000000132800ull}) { // M&L: Paper Jam
        REQUIRE(hack_manager.GetHackAllowMode(HackType::ACCURATE_MULTIPLICATION, title_id) ==
                HackAllowMode::FORCE);
    }

    // Non-conflicting MMJ FAST titles are ported as DISALLOW.
    for (const u64 title_id :
         {0x0004000000030000ull,                    // Kid Icarus
          0x000400000007AD00ull,                    // New SMB 2
          0x00040000001D1800ull, 0x00040000001D1900ull,
          0x00040000001D1A00ull}) {                 // Luigi's Mansion
        REQUIRE(hack_manager.GetHackAllowMode(HackType::ACCURATE_MULTIPLICATION, title_id) ==
                HackAllowMode::DISALLOW);
    }
}
