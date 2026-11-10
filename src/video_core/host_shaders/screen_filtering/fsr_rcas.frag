// Screen filter: AMD FidelityFX RCAS (Robust Contrast-Adaptive Sharpening)
// Ported from melonDS-ohos (video_filter_shaders.cpp), originally
// ppsspp fsr_rcas.fsh (MIT)
// Parameter baked: Sharpness=0.5
// Common declarations (sampler/uniforms/SampleTex) are injected at compile
// time — see video_core/screen_filters.h

const vec3  lumCoef  = vec3(0.2126, 0.7152, 0.0722);   // Rec.709
const float rcasPeak = 8.0 - 3.0;                      // = 5.0
const float rcasInvP = 1.0 / rcasPeak;
const float FSR_EPS  = 0.0001;
const float SHARPNESS = 0.5;

const vec2 offN = vec2( 0.0, -1.0);
const vec2 offW = vec2(-1.0,  0.0);
const vec2 offE = vec2( 1.0,  0.0);
const vec2 offS = vec2( 0.0,  1.0);

vec4 FsrRcasVanilla(vec2 uv) {
    vec3 C = SampleTex(uv).rgb;
    float CL = dot(C, lumCoef);

    vec3 N = SampleTex(uv + offN * i_resolution.zw).rgb;
    vec3 W = SampleTex(uv + offW * i_resolution.zw).rgb;
    vec3 E = SampleTex(uv + offE * i_resolution.zw).rgb;
    vec3 S = SampleTex(uv + offS * i_resolution.zw).rgb;

    float NL = dot(N, lumCoef);
    float WL = dot(W, lumCoef);
    float EL = dot(E, lumCoef);
    float SL = dot(S, lumCoef);

    // Adaptive range
    vec3 minRGB = min(min(min(N, W), min(E, S)), C);
    vec3 maxRGB = max(max(max(N, W), max(E, S)), C);
    vec3 invMax = 1.0 / (maxRGB + FSR_EPS);
    vec3 amp    = clamp(min(minRGB, 2.0 - maxRGB) * invMax, 0.0, 1.0);
    amp         = inversesqrt(amp + FSR_EPS);

    float w = -rcasInvP / dot(amp, lumCoef);

    float sumL   = NL + WL + EL + SL;
    float invDen = 1.0 / (4.0 * w + 1.0);
    float sharpL = clamp((sumL * w + CL) * invDen, 0.0, 1.0);

    vec3  chroma     = C - vec3(CL);
    vec3  sharpColor = chroma + vec3(sharpL);

    vec3  outColor   = mix(C, sharpColor, SHARPNESS);
    return vec4(outColor, 1.0);
}

void main() {
    color = vec4(FsrRcasVanilla(frag_tex_coord).rgb, 1.0);
}
