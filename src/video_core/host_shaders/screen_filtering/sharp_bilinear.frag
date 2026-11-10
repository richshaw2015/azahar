// Screen filter: Sharp Bilinear (pixel-preserving non-integer upscale)
// Ported from melonDS-ohos (video_filter_shaders.cpp), originally
// ppsspp upscale_sharp_bilinear.fsh (Marc)
// Common declarations (sampler/uniforms/SampleTex) are injected at compile
// time — see video_core/screen_filters.h

// Returns pixel sharpened to nearest pixel boundary.
vec2 sharpSample(vec4 texSize, vec2 coord) {
    vec2 boxSize = clamp(fwidth(coord) * texSize.zw, 1e-5, 1.0);
    coord = coord * texSize.zw - 0.5 * boxSize;
    vec2 txOffset = smoothstep(vec2(1.0) - boxSize, vec2(1.0), fract(coord));
    return (floor(coord) + 0.5 + txOffset) * texSize.xy;
}

void main() {
    vec2 sharpPos = sharpSample(vec4(i_resolution.zw, i_resolution.xy), frag_tex_coord);
    color = vec4(SampleTex(sharpPos).rgb, 1.0);
}
