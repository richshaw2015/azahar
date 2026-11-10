// Screen filter: PhosphorLine v2 shadow mask (Roc-Y)
// Ported from melonDS-ohos (video_filter_shaders.cpp), originally
// ppsspp pl_mask.fsh — 3-color staggered aperture mask on output pixels
// Parameters baked: MaskIntensity=0.7, MaskType=1 (staggered), MaskSize=1.0,
// Gamma=2.2
// Common declarations (sampler/uniforms/SampleTex) are injected at compile
// time — see video_core/screen_filters.h

const float MASK_INT = 0.7;
const float MASK_SIZE = 1.0;
const float GAMMA_EMU = 2.2;

void main() {
    vec3 b = SampleTex(frag_tex_coord).rgb;
    // mask cell size = ceil(output pixels per source texel row * MaskSize)
    float c = max(ceil((1.0 / (fwidth(frag_tex_coord.y) * i_resolution.y)) * MASK_SIZE), 2.0);
    vec2 d = gl_FragCoord.xy;
    float e = floor(c * 0.5 + 0.1);
    d.x += floor(d.y / e) * e;   // MASK_TYPE=1 (staggered)
    vec3 f = mod(vec3(d.x, d.x + floor(c / 2.0 + 0.5), d.x), c);
    f = abs((f - c * 0.5) * 2.0 - 0.5);
    vec3 j = pow(b, vec3(GAMMA_EMU));
    vec3 k = (j * MASK_INT + (1.0 - MASK_INT)) * c;
    vec3 l = clamp(k - f + 0.5, 0.0, 1.0);
    l *= j / (j * MASK_INT + 1.0 - MASK_INT);
    color = vec4(pow(l, vec3(1.0 / 2.2)), 1.0);
}
