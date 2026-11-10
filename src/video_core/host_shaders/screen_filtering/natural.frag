// Screen filter: Natural Colors (color enhancement + softening)
// Ported from melonDS-ohos (video_filter_shaders.cpp), originally
// ppsspp natural.fsh (ShadX, modded by SimoneT)
// Common declarations (sampler/uniforms/SampleTex) are injected at compile
// time — see video_core/screen_filters.h

const mat3 RGBtoYIQ = mat3(0.299, 0.596, 0.212,
                           0.587, -0.275, -0.523,
                           0.114, -0.321, 0.311);
const mat3 YIQtoRGB = mat3(1.0, 1.0, 1.0,
                           0.95568806036115671171, -0.27158179694405859326, -1.1081773266826619523,
                           0.61985809445637075388, -0.64687381613840131330, 1.7050645599191817149);
const vec3 val00 = vec3(1.2, 1.2, 1.2);

void main() {
    vec4 t0 = frag_tex_coord.xyxy + vec4(-0.5, -0.5, -1.5, -1.5) * i_resolution.zwzw;
    vec4 t1 = frag_tex_coord.xyxy + vec4( 0.5, -0.5,  1.5, -1.5) * i_resolution.zwzw;
    vec4 t2 = frag_tex_coord.xyxy + vec4(-0.5,  0.5, -1.5,  1.5) * i_resolution.zwzw;
    vec4 t3 = frag_tex_coord.xyxy + vec4( 0.5,  0.5,  1.5,  1.5) * i_resolution.zwzw;

    vec3 c0 = SampleTex(t0.xy).rgb;
    c0 += SampleTex(t0.zy).rgb * 0.25;
    c0 += SampleTex(t0.xw).rgb * 0.25;
    c0 += SampleTex(t0.zw).rgb * 0.125;
    c0 += SampleTex(t1.xy).rgb;
    c0 += SampleTex(t1.zy).rgb * 0.25;
    c0 += SampleTex(t1.xw).rgb * 0.25;
    c0 += SampleTex(t1.zw).rgb * 0.125;
    c0 += SampleTex(t2.xy).rgb;
    c0 += SampleTex(t2.zy).rgb * 0.25;
    c0 += SampleTex(t2.xw).rgb * 0.25;
    c0 += SampleTex(t2.zw).rgb * 0.125;
    c0 += SampleTex(t3.xy).rgb;
    c0 += SampleTex(t3.zy).rgb * 0.25;
    c0 += SampleTex(t3.xw).rgb * 0.25;
    c0 += SampleTex(t3.zw).rgb * 0.125;
    c0 *= 0.153846153846;

    vec3 c1 = RGBtoYIQ * c0;
    c1 = vec3(pow(c1.x, val00.x), c1.yz * val00.yz);
    color.rgb = YIQtoRGB * c1;
    color.a = 1.0;
}
