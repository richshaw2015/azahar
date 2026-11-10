// Screen filter: Scanlines (CRT scanline + green tint + vignette)
// Ported from melonDS-ohos (video_filter_shaders.cpp), originally
// ppsspp scanlines.fsh ("Advanced Scanlines (CRT)")
// Parameters baked: Amount=1.0, Intensity=0.5
// Scanline period: one cosine cycle per 2 source texels.
// Common declarations (sampler/uniforms/SampleTex) are injected at compile
// time — see video_core/screen_filters.h

void main() {
    float pos0 = frag_tex_coord.y * i_resolution.y * 0.5;
    float pos1 = cos((fract(pos0) - 0.5) * 3.1415926 * 0.5) * 1.5;
    vec4 rgb = vec4(SampleTex(frag_tex_coord).rgb, 1.0);

    // slight contrast curve
    vec4 col = rgb * 0.5 + 0.5 * rgb * rgb * 1.2;

    // color tint
    col *= vec4(0.9, 1.0, 0.7, 1.0);

    // vignette
    col *= 1.1 - 0.6 * (dot(frag_tex_coord - 0.5, frag_tex_coord - 0.5) * 2.0);

    color = mix(vec4(0.0, 0.0, 0.0, 1.0), col, pos1);
}
