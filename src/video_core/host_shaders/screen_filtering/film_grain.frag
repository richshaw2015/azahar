// Screen filter: Strider Film Grain
// Ported from melonDS-ohos (video_filter_shaders.cpp), originally
// ppsspp strider_filmgrain.fsh (StriderTibe, MIT)
// https://github.com/Tibbee/PPSSPP_Shaders
// Parameters baked: Strength=1.0, Size=1.0, FrameRate=30.0, MidtoneBias=1.0
// Common declarations (sampler/uniforms/SampleTex) are injected at compile
// time — see video_core/screen_filters.h

const float STRENGTH = 1.0;
const float GRAIN_SIZE = 1.0;
const float FRAME_RATE = 30.0;
const float MIDTONE_BIAS = 1.0;

// Integer-free hash (D. Hoskins, hash without sine)
float pcg_rand(vec3 seed) {
    vec3 p = mod(seed, 289.0);
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z) - 0.5;
}

vec2 rotate(vec2 v, float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return vec2(v.x * c - v.y * s, v.x * s + v.y * c);
}

void main() {
    vec3 col = SampleTex(frag_tex_coord).rgb;

    // grain is measured in output pixels, decoupled from internal resolution
    // (o_resolution is packed (h, w, 1/h, 1/w))
    vec2 pixelPos = frag_tex_coord * o_resolution.yx;
    float baseSize = GRAIN_SIZE;

    float frame = floor(time * FRAME_RATE);
    float subFrame = fract(time * FRAME_RATE);

    // Three non-symmetric rotation angles for good artifact cancellation
    const vec3 angles = vec3(0.0, 0.41015237422, 0.81814668289);

    float noiseTotal = 0.0;

    for (int i = 0; i < 3; i++) {
        float angle = angles[i];

        vec2 rotPosCoarse = rotate(pixelPos, angle);
        vec2 blockCoarse = floor(rotPosCoarse / (baseSize * 3.0));
        vec2 seedCoarse = blockCoarse * (baseSize * 3.0) + (baseSize * 3.0) * 0.5;

        vec2 rotPosFine = rotate(pixelPos, angle);
        vec2 blockFine = floor(rotPosFine / baseSize);
        vec2 seedFine = blockFine * baseSize + baseSize * 0.5;

        vec3 coordA_coarse = vec3(seedCoarse, frame);
        vec3 coordB_coarse = coordA_coarse + vec3(2.7, 1.3, 1.0);
        vec3 coordA_fine   = vec3(seedFine,   frame);
        vec3 coordB_fine   = coordA_fine   + vec3(1.9, 3.1, 1.0);

        float nCoarse = mix(pcg_rand(coordA_coarse), pcg_rand(coordB_coarse), subFrame);
        float nFine   = mix(pcg_rand(coordA_fine),   pcg_rand(coordB_fine),   subFrame);

        float layerNoise = nCoarse * 0.65 + nFine * 0.35;

        noiseTotal += layerNoise;
    }

    float noise = noiseTotal / 3.0;

    float luma = dot(col, vec3(0.299, 0.587, 0.114));
    float baseCurve = 1.0 - abs(luma - 0.5) * 2.0;
    baseCurve = max(0.001, baseCurve);
    float exponent = 1.0 + MIDTONE_BIAS * 2.0;
    float midtoneCurve = pow(baseCurve, exponent);

    noise *= STRENGTH * midtoneCurve;

    col += noise * (col * (1.0 - col) * 4.0);

    color = vec4(col, 1.0);
}
