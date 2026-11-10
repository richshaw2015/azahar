// Screen filter: PL2x phosphor scanlines (PhosphorLine v2, Roc-Y)
// Ported from melonDS-ohos (video_filter_shaders.cpp), originally
// ppsspp pl_2x.fsh — nearest snap + per-output-row dark line
// Parameters baked: ScanlineIntensity=0.7, GammaEmulated=2.2
// Common declarations (sampler/uniforms/SampleTex) are injected at compile
// time — see video_core/screen_filters.h

const float SCAN_INTENSITY = 0.7;
const float GAMMA_EMU = 2.2;

void main() {
    float c = mod(floor(gl_FragCoord.y), 2.0);   // alternate dark line per output row
    vec2 tc = (floor(frag_tex_coord / i_resolution.zw) + 0.5) * i_resolution.zw;
    vec3 d = pow(SampleTex(tc).rgb, vec3(GAMMA_EMU));
    vec3 e = (d * SCAN_INTENSITY + (1.0 - SCAN_INTENSITY)) * 2.0;
    vec3 f = clamp(e - c + 0.5, 0.0, 1.0);
    f *= d / (d * SCAN_INTENSITY + 1.0 - SCAN_INTENSITY);
    color = vec4(pow(f, vec3(0.454545)), 1.0);
}
