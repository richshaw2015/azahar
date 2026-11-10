// Copyright 2026 Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#pragma once

#include <array>
#include <chrono>
#include <string>
#include <string_view>
#include "common/common_types.h"

#include "video_core/host_shaders/screen_filtering/aa_color_frag.h"
#include "video_core/host_shaders/screen_filtering/film_grain_frag.h"
#include "video_core/host_shaders/screen_filtering/fsr_easu_frag.h"
#include "video_core/host_shaders/screen_filtering/fsr_rcas_frag.h"
#include "video_core/host_shaders/screen_filtering/fxaa_frag.h"
#include "video_core/host_shaders/screen_filtering/hq2x_frag.h"
#include "video_core/host_shaders/screen_filtering/hq4x_frag.h"
#include "video_core/host_shaders/screen_filtering/lcd_frag.h"
#include "video_core/host_shaders/screen_filtering/natural_frag.h"
#include "video_core/host_shaders/screen_filtering/pl_2x_frag.h"
#include "video_core/host_shaders/screen_filtering/pl_hard_frag.h"
#include "video_core/host_shaders/screen_filtering/pl_mask_frag.h"
#include "video_core/host_shaders/screen_filtering/quilez_frag.h"
#include "video_core/host_shaders/screen_filtering/scanlines_frag.h"
#include "video_core/host_shaders/screen_filtering/sharp_bilinear_frag.h"
#include "video_core/host_shaders/screen_filtering/xbr2_frag.h"

namespace VideoCore {

// Built-in screen filters applied in the present pass on the final frame.
// Selected via pp_shader_name values of the form "<Name> (builtin)", matching
// the "None (builtin)" convention used for the default present shader.
// Unlike texture filters they run at any internal resolution scale, once per
// frame at output resolution.
struct ScreenFilterInfo {
    std::string_view name;   // pp_shader_name value
    std::string_view glsl;   // fragment source shared by both backends
    bool linear_sampling;    // required texture sampler mode
};

// clang-format off
inline constexpr std::array<ScreenFilterInfo, 16> SCREEN_FILTERS = {{
    {"2xBR (builtin)",            HostShaders::XBR2_FRAG,           false},
    {"HQ2X (builtin)",            HostShaders::HQ2X_FRAG,           false},
    {"HQ4X (builtin)",            HostShaders::HQ4X_FRAG,           false},
    {"Quilez (builtin)",          HostShaders::QUILEZ_FRAG,         true},
    {"LCD (builtin)",             HostShaders::LCD_FRAG,            false},
    {"Sharp Bilinear (builtin)",  HostShaders::SHARP_BILINEAR_FRAG, false},
    {"AAColor (builtin)",         HostShaders::AA_COLOR_FRAG,       true},
    {"FXAA (builtin)",            HostShaders::FXAA_FRAG,           true},
    {"Natural Colors (builtin)",  HostShaders::NATURAL_FRAG,        true},
    {"Scanlines (builtin)",       HostShaders::SCANLINES_FRAG,      true},
    {"FSR RCAS (builtin)",        HostShaders::FSR_RCAS_FRAG,       false},
    {"FSR EASU (builtin)",        HostShaders::FSR_EASU_FRAG,       false},
    {"PL2x (builtin)",            HostShaders::PL_2X_FRAG,          false},
    {"PL Mask (builtin)",         HostShaders::PL_MASK_FRAG,        false},
    {"PL Hard (builtin)",         HostShaders::PL_HARD_FRAG,        false},
    {"Film Grain (builtin)",      HostShaders::FILM_GRAIN_FRAG,     false},
}};
// clang-format on

// Returns the index into SCREEN_FILTERS for a pp_shader_name value, or -1 when
// it does not name a built-in screen filter.
inline int ScreenFilterIndex(std::string_view pp_shader_name) {
    for (u32 i = 0; i < SCREEN_FILTERS.size(); ++i) {
        if (SCREEN_FILTERS[i].name == pp_shader_name) {
            return static_cast<int>(i);
        }
    }
    return -1;
}

// Time source (seconds) for animated filters.
inline float ScreenFilterTime() {
    using Clock = std::chrono::steady_clock;
    static const auto start = Clock::now();
    return std::chrono::duration<float>(Clock::now() - start).count();
}

// Shared fragment-shader declarations for screen filters. Filter .frag files
// contain only the filter body; these declarations are prepended at compile
// time. The shaders see:
//   in vec2 frag_tex_coord / out vec4 color — present quad interface
//   vec4 SampleTex(vec2 uv) — samples the screen texture for this draw
//   vec4 i_resolution — (w, h, 1/w, 1/h) of the sampled screen texture
//   vec4 o_resolution — (h, w, 1/h, 1/w) of the output quad
//   float time — seconds, for animated filters
inline constexpr std::string_view SCREEN_FILTER_GL_PREAMBLE = R"(
layout(location = 0) in vec2 frag_tex_coord;
layout(location = 0) out vec4 color;

layout(binding = 0) uniform sampler2D color_texture;
uniform vec4 i_resolution;
uniform vec4 o_resolution;
uniform int layer;
uniform float time;

vec4 SampleTex(vec2 uv) {
    return texture(color_texture, uv);
}
)";

inline constexpr std::string_view SCREEN_FILTER_VK_PREAMBLE = R"(
layout(location = 0) in vec2 frag_tex_coord;
layout(location = 0) out vec4 color;

layout(push_constant, std140) uniform DrawInfo {
    mat4 modelview_matrix;
    vec4 i_resolution;
    vec4 o_resolution;
    int screen_id_l;
    int screen_id_r;
    int layer;
    int reverse_interlaced;
    float time;
};

layout(set = 0, binding = 0) uniform sampler2D screen_textures[3];
)";

// Vulkan preamble plus a SampleTex implementation; whether the screen texture
// array can be indexed dynamically is device-dependent.
inline std::string ScreenFilterVulkanPreamble(bool dynamic_index) {
    if (dynamic_index) {
        return std::string{SCREEN_FILTER_VK_PREAMBLE} + R"(
vec4 SampleTex(vec2 uv) {
    return texture(screen_textures[screen_id_l], uv);
}
)";
    }
    return std::string{SCREEN_FILTER_VK_PREAMBLE} + R"(
vec4 SampleTex(vec2 uv) {
    switch (screen_id_l) {
    case 0:
        return texture(screen_textures[0], uv);
    case 1:
        return texture(screen_textures[1], uv);
    default:
        return texture(screen_textures[2], uv);
    }
}
)";
}

} // namespace VideoCore
