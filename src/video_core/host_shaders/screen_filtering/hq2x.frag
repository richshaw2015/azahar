// Screen filter: HQ2X interpolation
// Ported from melonDS-ohos (video_filter_shaders.cpp)
// Common declarations (sampler/uniforms/SampleTex) are injected at compile
// time — see video_core/screen_filters.h

const float mx = 0.325;
const float k = -0.250;
const float max_w = 0.25;
const float min_w = -0.05;
const float lum_add = 0.25;

void main() {
    vec2 dg1 = 0.5 * i_resolution.zw;
    vec2 dg2 = vec2(-dg1.x, dg1.y);
    vec2 dx = vec2(dg1.x, 0.0);
    vec2 dy = vec2(0.0, dg1.y);

    vec3 c00 = SampleTex(frag_tex_coord - dg1).rgb;
    vec3 c10 = SampleTex(frag_tex_coord - dy).rgb;
    vec3 c20 = SampleTex(frag_tex_coord - dg2).rgb;
    vec3 c01 = SampleTex(frag_tex_coord - dx).rgb;
    vec3 c11 = SampleTex(frag_tex_coord).rgb;
    vec3 c21 = SampleTex(frag_tex_coord + dx).rgb;
    vec3 c02 = SampleTex(frag_tex_coord + dg2).rgb;
    vec3 c12 = SampleTex(frag_tex_coord + dy).rgb;
    vec3 c22 = SampleTex(frag_tex_coord + dg1).rgb;
    vec3 dt = vec3(1.0, 1.0, 1.0);

    float md1 = dot(abs(c00 - c22), dt);
    float md2 = dot(abs(c02 - c20), dt);

    float w1 = dot(abs(c22 - c11), dt) * md2;
    float w2 = dot(abs(c02 - c11), dt) * md1;
    float w3 = dot(abs(c00 - c11), dt) * md2;
    float w4 = dot(abs(c20 - c11), dt) * md1;

    float t1 = w1 + w3;
    float t2 = w2 + w4;
    float ww = max(t1, t2) + 0.001;

    c11 = (w1 * c00 + w2 * c20 + w3 * c22 + w4 * c02 + ww * c11) / (t1 + t2 + ww);

    float lc1 = k / (0.12 * dot(c10 + c12 + c11, dt) + lum_add);
    float lc2 = k / (0.12 * dot(c01 + c21 + c11, dt) + lum_add);

    w1 = clamp(lc1 * dot(abs(c11 - c10), dt) + mx, min_w, max_w);
    w2 = clamp(lc2 * dot(abs(c11 - c21), dt) + mx, min_w, max_w);
    w3 = clamp(lc1 * dot(abs(c11 - c12), dt) + mx, min_w, max_w);
    w4 = clamp(lc2 * dot(abs(c11 - c01), dt) + mx, min_w, max_w);

    color.rgb = w1 * c10 + w2 * c21 + w3 * c12 + w4 * c01 + (1.0 - w1 - w2 - w3 - w4) * c11;
    color.a = 1.0;
}
