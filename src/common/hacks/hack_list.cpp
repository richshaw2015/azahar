// Copyright 2024-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#include "common/hacks/hack_manager.h"

namespace Common::Hacks {

// Per-core downcount shift patterns used by the Citra-MMJ cpu_usage_limit database.
// Most titles use the default {1,4,2,2}; a few want all cores limited equally or a
// heavier limit on the main core.
static CpuLimitData cpu_limit_default;                 // {1, 4, 2, 2}
static CpuLimitData cpu_limit_equal{{1, 1, 1, 1}};     // all cores lightly limited
static CpuLimitData cpu_limit_main_core{{2, 4, 2, 2}}; // core 0 limited harder

HackManager hack_manager = {
    .entries = {

        // The following games cannot use the right eye disable hack due to the way they
        // handle rendering.
        {HackType::RIGHT_EYE_DISABLE,
         HackEntry{
             .mode = HackAllowMode::DISALLOW,
             // clang-format off
             .affected_title_ids =
                 {
                     // Luigi's Mansion
                     0x00040000001D1900,
                     0x00040000001D1A00,

                     // Luigi's Mansion 2
                     0x0004000000055F00,
                     0x0004000000076500,
                     0x0004000000076400,
                     0x00040000000D0000,

                     // Rayman Origins
                     0x000400000005A500,
                     0x0004000000084400,
                     0x0004000000057600,

                     // Minecraft: New Nintendo 3DS Edition
                     0x00040000001B8700, // USA
                     0x000400000017CA00, // EUR
                     0x000400000017FD00, // JPN
                 },
             // clang-format on
         }},

        // The following games require accurate multiplication to render properly.
        {HackType::ACCURATE_MULTIPLICATION,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // The Legend of Zelda: Ocarina of Time 3D
                     0x0004000000033400, // JPN
                     0x0004000000033500, // USA
                     0x0004000000033600, // EUR
                     0x000400000008F800, // KOR
                     0x000400000008F900, // CHI

                     // Mario & Luigi: Superstar Saga + Bowsers Minions
                     0x00040000001B8F00, // USA
                     0x00040000001B9000, // EUR
                     0x0004000000194B00, // JPN

                     // Mario & Luigi: Bowsers Inside Story + Bowser Jrs Journey
                     0x00040000001D1400, // USA
                     0x00040000001D1500, // EUR
                     0x00040000001CA900, // JPN

                     // Mario & Luigi: Paper Jam
                     0x0004000000132600, // JPN
                     0x0004000000132700, // USA
                     0x0004000000132800, // EUR
                     0x000400000018A100, // EUR (Demo)
                 },
             // clang-format on
         }},

        {HackType::DECRYPTION_AUTHORIZED,
         HackEntry{
             .mode = HackAllowMode::ALLOW,
             // clang-format off
             .affected_title_ids =
                 {
                     // NIM
                     0x0004013000002C02, // Normal
                     0x0004013000002C03, // Safe mode
                     0x0004013020002C03, // New 3DS safe mode

                     // DLP
                     0x0004013000002802,
                 },
             // clang-format on
         }},

        {HackType::ONLINE_LLE_REQUIRED,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // eShop
                     0x0004001000020900, // JPN
                     0x0004001000021900, // USA
                     0x0004001000022900, // EUR
                     0x0004001000027900, // KOR
                     0x0004001000028900, // TWN

                     // System Settings
                     0x0004001000020000, // JPN
                     0x0004001000021000, // USA
                     0x0004001000022000, // EUR
                     0x0004001000026000, // CHN
                     0x0004001000027000, // KOR
                     0x0004001000028000, // TWN

                     // Nintendo Network ID Settings
                     0x000400100002BF00, // JPN
                     0x000400100002C000, // USA
                     0x000400100002C100, // EUR

                     // System Settings
                     0x0004003000008202, // JPN
                     0x0004003000008F02, // USA
                     0x0004003000009802, // EUR
                     0x000400300000A102, // CHN
                     0x000400300000A902, // KOR
                     0x000400300000B102, // TWN

                     // Pretendo Network's Nimbus
                     0x000400000D40D200,
                 },
             // clang-format on
         }},

        {HackType::REGION_FROM_SECURE,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // eShop
                     0x0004001000020900, // JPN
                     0x0004001000021900, // USA
                     0x0004001000022900, // EUR
                     0x0004001000027900, // KOR
                     0x0004001000028900, // TWN

                     // System Settings
                     0x0004001000020000, // JPN
                     0x0004001000021000, // USA
                     0x0004001000022000, // EUR
                     0x0004001000026000, // CHN
                     0x0004001000027000, // KOR
                     0x0004001000028000, // TWN

                     // Nintendo Network ID Settings
                     0x000400100002BF00, // JPN
                     0x000400100002C000, // USA
                     0x000400100002C100, // EUR

                     // System Settings
                     0x0004003000008202, // JPN
                     0x0004003000008F02, // USA
                     0x0004003000009802, // EUR
                     0x000400300000A102, // CHN
                     0x000400300000A902, // KOR
                     0x000400300000B102, // TWN

                     // NIM
                     0x0004013000002C02, // Normal
                     0x0004013000002C03, // Safe mode
                     0x0004013020002C03, // New 3DS safe mode

                     // ACT
                     0x0004013000003802, // Normal

                     // FRD
                     0x0004013000003202, // Normal
                     0x0004013000003203, // Safe mode
                     0x0004013020003203, // New 3DS safe mode
                 },
             // clang-format on
         }},
        {HackType::REQUIRES_SHADER_FIXUP,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids = {},
             // clang-format on
         }},
        {HackType::SPOOF_FRIEND_CODE_SEED,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // Luigi's Mansion 3ds
                     0x00040000001D1800, // JPN
                     0x00040000001D1900, // USA
                     0x00040000001D1A00, // EUR
                 },
             // clang-format on
         }},
        {HackType::DELAY_TEXTURE_COPY_COMPLETION,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // Super Mario 3D Land
                     0x0004000000054100, // JPN
                     0x0004000000054000, // USA
                     0x0004000000053F00, // EUR
                     0x0004000000089E00, // CHN
                     0x0004000000089D00, // KOR
                 },
             // clang-format on
         }},

        // ---------------------------------------------------------------------
        // Per-title compatibility quirks ported from the Citra-MMJ game database
        // (LoadOverrides in MMJ's core.cpp plus its config-games.ini). Titles
        // listed here keep the semantics of the corresponding MMJ setting; see
        // System::ApplyPerProgramHacks for how each quirk is applied.
        //
        // Merge note: local fork additions — keep this whole section at the END
        // of the entries list so upstream merges only ever conflict here.
        // ---------------------------------------------------------------------

        {HackType::CPU_USAGE_LIMIT,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // 1001 Spikes
                     0x000400000008FE00,
                     // Lord of Magna: Maiden Heaven
                     0x0004000000120900,
                     0x0004000000164300,
                     0x0004000000165500,
                     // The Alliance Alive
                     0x00040000001CCD00,
                     0x00040000001B4500,
                     // EX Troopers
                     0x0004000000053700,
                     // Castlevania: Lords of Shadow - Mirror of Fate
                     0x00040000000BAC00,
                     0x000400000009E500,
                     0x0004000000096600,
                     // Mario Golf: World Tour
                     0x00040000000DCD00,
                     0x00040000000A5300,
                     0x00040000000DCE00,
                     // Super Street Fighter IV
                     0x0004000000030500,
                     0x0004000000032D00,
                     0x0004000000033C00,
                     // Metal Gear Solid: Snake Eater 3D
                     0x000400000007A000,
                     0x0004000000082400,
                     0x0004000000081E00,
                     // New Love Plus
                     0x00040000000F4E00,
                 },
             // clang-format on
             .hack_data = &cpu_limit_default,
         }},
        {HackType::CPU_USAGE_LIMIT,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // The Binding of Isaac: Rebirth
                     0x000400000F700800, // USA
                     0x000400000F701700, // JPN
                     0x000400000F700900, // EUR
                     // Futuridium EP Deluxe
                     0x000400000F705C00,
                 },
             // clang-format on
             .hack_data = &cpu_limit_equal,
         }},
        {HackType::CPU_USAGE_LIMIT,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // Mario Tennis Open
                     0x000400000007C700,
                     0x000400000007C800,
                     0x0004000000064D00,
                     0x00040000000B9100,
                     // Luigi's Mansion: Dark Moon
                     0x00040000000D0000,
                     0x0004000000076400,
                     0x0004000000055F00,
                     0x0004000000076500,
                     // Shin Megami Tensei: Devil Survivor Overclocked
                     0x0004000000038800,
                     0x000400000009C000,
                     // Heroes of Ruin
                     0x0004000000075100,
                 },
             // clang-format on
             .hack_data = &cpu_limit_main_core,
         }},

        // Titles whose FMV playback stalls without an inflated per-slice tick cost.
        // (Citra-MMJ config-games.ini [use_fmv_hack])
        {HackType::FMV_HACK,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // Castlevania: Lords of Shadow - Mirror of Fate
                     0x00040000000BAC00,
                     0x000400000009E500,
                     0x0004000000096600,
                     // Luigi's Mansion: Dark Moon
                     0x00040000000D0000,
                     0x0004000000076400,
                     0x0004000000055F00,
                     0x0004000000076500,
                     // Zombie Panic in Wonderland DX
                     0x000400000012E000,
                     0x0004000000167A00,
                     0x00040000000F5600,
                 },
             // clang-format on
         }},

        {HackType::SKIP_SLOW_DRAW,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // Tales of the Abyss / Pac-Man Party 3D
                     0x0004000000068B00,
                     0x0004000000061300,
                     0x000400000004A700,
                     0x000400000005D700,
                     // New Atelier Rorona
                     0x000400000015CB00,
                     // My Hero Academia
                     0x000400000018E900,
                     // Dragon Quest Monsters Joker 3
                     0x000400000016AD00,
                     // Dragon Quest Monsters Joker 3 Professional
                     0x00040000001ACB00,
                 },
             // clang-format on
         }},

        // (Citra-MMJ config-games.ini [skip_cpu_write])
        {HackType::SKIP_CPU_WRITE,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // Lord of Magna: Maiden Heaven
                     0x0004000000120900,
                     0x0004000000164300,
                     0x0004000000165500,
                 },
             // clang-format on
         }},

        {HackType::SKIP_TEXTURE_COPY,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // Mario Kart 7
                     0x000400000008B400,
                     0x0004000000030600,
                     0x0004000000030800,
                     0x0004000000030700,
                     // Kid Icarus: Uprising
                     0x0004000000030000,
                     0x0004000000030100,
                     0x0004000000030200,
                     // Metroid Prime: Federation Force
                     0x0004000000175200,
                     0x000400000016CE00,
                     0x000400000016E300,
                     // Batman: Arkham Origins Blackgate
                     0x00040000000D6B00,
                     0x00040000000D7000,
                     // Luigi's Mansion: Dark Moon
                     0x00040000000D0000,
                     0x0004000000076400,
                     0x0004000000055F00,
                     0x0004000000076500,
                     // Professor Layton and the Miracle Mask
                     0x00040000000A8500,
                     0x0004000000031F00,
                     // Professor Layton and the Miracle Mask Plus
                     0x00040000000C9200,
                 },
             // clang-format on
         }},

        {HackType::Y2R_SKIP_CONVERSION,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // Danball Senki W Chou Custom / Danball Senki WARS
                     0x00040000000DCA00,
                     0x00040000000F4000,
                 },
             // clang-format on
         }},

        {HackType::DISABLE_CLIP_PLANES,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // Star Fox 64 3D
                     0x0004000000049100,
                     0x0004000000030400,
                     0x0004000000049000,
                     // Picross 2
                     0x0004000000187E00,
                     0x0004000000187D00,
                     0x0004000000169A00,
                     // Art of Balance
                     0x000400000008FF00,
                     0x000400000008F000,
                     0x00040000000E8900,
                 },
             // clang-format on
         }},

        {HackType::FORCE_LINEAR_FILTER,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // Attack on Titan
                     0x00040000001AA200,
                     0x0004000000131E00,
                     0x0004000000134500,
                     0x0004000000152000,
                     0x00040000000DF800,
                 },
             // clang-format on
         }},

        {HackType::DISPLAY_TRANSFER_FIXUP,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // Tales of the Abyss / Pac-Man Party 3D
                     0x0004000000068B00,
                     0x0004000000061300,
                     0x000400000004A700,
                     0x000400000005D700,
                 },
             // clang-format on
         }},

        {HackType::FORCE_NEW_3DS,
         HackEntry{
             .mode = HackAllowMode::FORCE,
             // clang-format off
             .affected_title_ids =
                 {
                     // Xenoblade Chronicles 3D
                     0x000400000F700000,
                     0x000400000F700100,
                     0x000400000F700200,
                     // Fire Emblem Warriors
                     0x000400000F70CC00,
                     0x000400000F70CD00,
                     0x000400000F70C100,
                     // The Binding of Isaac: Rebirth
                     0x000400000F700800,
                     0x000400000F701700,
                     0x000400000F700900,
                     // Donkey Kong Country Returns 3D
                     0x00040000000CCE00,
                     0x00040000000CC000,
                     0x00040000000CCF00,
                     // Sonic Boom: Shattered Crystal
                     0x0004000000127500,
                     0x000400000014AE00,
                     0x000400000012C200,
                     // Sonic Boom: Fire & Ice
                     0x0004000000161300,
                     0x0004000000170700,
                     0x0004000000164700,
                     // Sonic & All-Stars Racing Transformed
                     0x00040000000B3500,
                     0x000400000008FC00,
                     // Minecraft
                     0x00040000001B8700,
                     // Hyperlight EX
                     0x000400000F707F00,
                     // 1001 Spikes
                     0x000400000008FE00,
                     // Mario Tennis Open
                     0x000400000007C700,
                     0x000400000007C800,
                     0x0004000000064D00,
                     0x00040000000B9100,
                     // Mario Golf: World Tour
                     0x00040000000DCD00,
                     0x00040000000A5300,
                     0x00040000000DCE00,
                     // Terraria
                     0x0004000000193500,
                     0x000400000016A900,
                     0x000400000016A600,
                     // Luigi's Mansion: Dark Moon
                     0x00040000000D0000,
                     0x0004000000076400,
                     0x0004000000055F00,
                     0x0004000000076500,
                     // Art Academy: Lessons for Everyone
                     0x0004000000095700,
                     0x0004000000095800,
                     0x0004000000084F00,
                     // Futuridium EP Deluxe
                     0x000400000F705C00,
                 },
             // clang-format on
         }},

        // Citra-MMJ ran these titles with shaders_accurate_mul=FAST for speed.
        // Titles that Azahar already marks ACCURATE_MULTIPLICATION=FORCE
        // (Ocarina of Time 3D, M&L: Superstar Saga, M&L: Bowser's Inside Story,
        // M&L: Paper Jam) are intentionally not listed here: correct rendering
        // wins over the MMJ fast-mul trade-off.
        {HackType::ACCURATE_MULTIPLICATION,
         HackEntry{
             .mode = HackAllowMode::DISALLOW,
             // clang-format off
             .affected_title_ids =
                 {
                     // Attack on Titan
                     0x0004000000134500,
                     0x00040000000DF800,
                     0x0004000000152000,
                     0x00040000001AA200,
                     // Super Mario 3D Land
                     0x0004000000054000,
                     0x0004000000053F00,
                     0x0004000000054100,
                     0x0004000000089F00,
                     0x0004000000089E00,
                     // Captain Toad: Treasure Tracker
                     0x00040000001CB000,
                     0x00040000001CB200,
                     0x00040000001CB100,
                     // The Legend of Zelda: A Link Between Worlds
                     0x00040000000EC200,
                     0x00040000000EC300,
                     0x00040000000EC400,
                     // New Super Mario Bros. 2
                     0x000400000007AD00,
                     0x00040000000B8A00,
                     0x000400000007AE00,
                     0x000400000007AF00,
                     // Jett Rocket II
                     0x0004000000079600,
                     // Cut the Rope
                     0x0004000000112600,
                     0x0004000000116700,
                     // Luigi's Mansion: Dark Moon
                     0x00040000000D0000,
                     0x0004000000076400,
                     0x0004000000055F00,
                     0x0004000000076500,
                     // Digimon World Re:Digitize Decode
                     0x00040000000AFC00,
                     // The Legend of Zelda: Majoras Mask 3D
                     0x0004000000125600,
                     0x0004000000125500,
                     0x00040000000D6E00,
                     // Lego City Undercover
                     0x0004000000154700,
                     0x00040000000AD600,
                     0x00040000000AD500,
                     // Luigi's Mansion
                     0x00040000001D1800,
                     0x00040000001D1A00,
                     0x00040000001D1900,
                     // Kid Icarus: Uprising
                     0x0004000000030000,
                     0x0004000000030100,
                     0x0004000000030200,
                     // Ever Oasis
                     0x00040000001A4900,
                     0x00040000001A4800,
                     0x0004000000164A00,
                 },
             // clang-format on
         }},
    }};
}