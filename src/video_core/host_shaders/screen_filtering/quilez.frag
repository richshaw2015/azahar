// Screen filter: Quilez improved texture interpolation
// Ported from melonDS-ohos (video_filter_shaders.cpp)
// Original: http://www.iquilezles.org/www/articles/texture/texture.htm
// Common declarations (sampler/uniforms/SampleTex) are injected at compile
// time — see video_core/screen_filters.h

vec4 getTexel(vec2 p) {
    vec2 textureSize = i_resolution.xy;
    p = p * textureSize + vec2(0.5);

    vec2 i = floor(p);
    vec2 f = p - i;
    f = f * f * f * (f * (f * 6.0 - vec2(15.0)) + vec2(10.0));
    p = i + f;

    p = (p - vec2(0.5)) / textureSize;
    return SampleTex(p);
}

void main() {
    color = vec4(getTexel(frag_tex_coord).rgb, 1.0);
}
