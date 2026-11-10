// Screen filter: AA-Color pixel-art softening AA
// Ported from melonDS-ohos (video_filter_shaders.cpp), originally
// ppsspp aacolor.fsh (guest(r), GPL)
// Parameters baked: saturation a=1.20, brightness b=1.00, contrast c=1.25,
// channels c_ch=vec3(1)
// Common declarations (sampler/uniforms/SampleTex) are injected at compile
// time — see video_core/screen_filters.h

const vec3 c_ch = vec3(1.0, 1.0, 1.0);  //  rgb color channel intensity
const float a = 1.20;                   //  saturation
const float b = 1.00;                   //  brightness
const float c = 1.25;                   //  contrast

float contrast4(float x)
{ return clamp(0.866 + c * (x - 0.866), 0.05, 1.73); }

void main() {
    vec3 c10 = SampleTex(frag_tex_coord + vec2(0.0, -0.8) * i_resolution.zw).rgb;
    vec3 c01 = SampleTex(frag_tex_coord + vec2(-0.8, 0.0) * i_resolution.zw).rgb;
    vec3 c11 = SampleTex(frag_tex_coord).rgb;
    vec3 c21 = SampleTex(frag_tex_coord + vec2(0.8, 0.0) * i_resolution.zw).rgb;
    vec3 c12 = SampleTex(frag_tex_coord + vec2(0.0, 0.8) * i_resolution.zw).rgb;

    vec3 dt = vec3(1.0, 1.0, 1.0);
    float k1 = dot(abs(c01 - c21), dt);
    float k2 = dot(abs(c10 - c12), dt);

    vec3 color_ = (k1 * (c10 + c12) + k2 * (c01 + c21) + 0.001 * c11) / (2.0 * (k1 + k2) + 0.001);

    float x = sqrt(dot(color_, color_));

    color_.r = pow(color_.r + 0.001, a);
    color_.g = pow(color_.g + 0.001, a);
    color_.b = pow(color_.b + 0.001, a);

    color.rgb = contrast4(x) * normalize(color_ * c_ch) * b;
    color.a = 1.0;
}
