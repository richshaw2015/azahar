// Screen filter: LCD pixel grid (sub-pixel stripes + scanlines)
// Ported from melonDS-ohos (video_filter_shaders.cpp)
// Author: Gigaherz
// License: Public domain
// Common declarations (sampler/uniforms/SampleTex) are injected at compile
// time — see video_core/screen_filters.h

/* configuration (higher values mean brighter image but reduced effect depth) */
const float brighten_scanlines = 16.0;
const float brighten_lcd = 4.0;

const vec3 offsets = 3.141592654 * vec3(1.0/2.0, 1.0/2.0 - 2.0/3.0, 1.0/2.0 - 4.0/3.0);

void main() {
    vec2 omega = 3.141592654 * 2.0 * i_resolution.xy;
    vec2 angle = frag_tex_coord * omega;

    float yfactor = (brighten_scanlines + sin(angle.y)) / (brighten_scanlines + 1.0);
    vec3 xfactors = (brighten_lcd + sin(angle.x + offsets)) / (brighten_lcd + 1.0);

    color.rgb = yfactor * xfactors * SampleTex(frag_tex_coord).rgb;
    color.a = 1.0;
}
