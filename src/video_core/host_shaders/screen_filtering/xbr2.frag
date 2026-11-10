// Screen filter: 2xBR edge-detection smoothing
// Ported from melonDS-ohos (video_filter_shaders.cpp), originally
// Copyright (C) 2011 Hyllian/Jararaca - sergiogdb@gmail.com
// License: GPL-2.0+
// Common declarations (sampler/uniforms/SampleTex) are injected at compile
// time — see video_core/screen_filters.h

void main() {
    vec2 ps = i_resolution.zw;
    vec2 fp = fract(frag_tex_coord * i_resolution.xy);
    vec2 d1 = vec2(0.0, -ps.y);
    vec2 d2 = vec2(-ps.x, 0.0);

    vec2 g1 = d1 * (step(0.5, fp.x) + step(0.5, fp.y) - 1.0) +
              d2 * (step(0.5, fp.x) - step(0.5, fp.y));
    vec2 g2 = d1 * (step(0.5, fp.y) - step(0.5, fp.x)) +
              d2 * (step(0.5, fp.x) + step(0.5, fp.y) - 1.0);

    vec3 B = SampleTex(frag_tex_coord + g1).rgb;
    vec3 C = SampleTex(frag_tex_coord + g1 - g2).rgb;
    vec3 D = SampleTex(frag_tex_coord + g2).rgb;
    vec3 E = SampleTex(frag_tex_coord).rgb;
    vec3 F = SampleTex(frag_tex_coord - g2).rgb;
    vec3 G = SampleTex(frag_tex_coord - g1 + g2).rgb;
    vec3 H = SampleTex(frag_tex_coord - g1).rgb;
    vec3 I = SampleTex(frag_tex_coord - g1 - g2).rgb;

    const vec3 dtt = vec3(65536.0, 255.0, 1.0);
    float b = dot(B, dtt);
    float c = dot(C, dtt);
    float d = dot(D, dtt);
    float e = dot(E, dtt);
    float f = dot(F, dtt);
    float g = dot(G, dtt);
    float h = dot(H, dtt);
    float i = dot(I, dtt);

    color = vec4(E, 1.0);
    if (h == f && h != e &&
        (e == g && (h == i || e == d) || e == c && (h == i || e == b))) {
        color.rgb = mix(E, F, 0.5);
    }
}
