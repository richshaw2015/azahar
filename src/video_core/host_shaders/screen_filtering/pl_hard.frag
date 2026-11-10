// Screen filter: PL-Hard integer-pitch hard scanlines + shadow mask
// (PhosphorLine v2, Roc-Y)
// Ported from melonDS-ohos (video_filter_shaders.cpp), originally
// ppsspp pl_hard.fsh
// Parameters baked: Pitch=1.0, Thickness=0.95, Opacity=0.95, MaskIntensity=0.5
// Common declarations (sampler/uniforms/SampleTex) are injected at compile
// time — see video_core/screen_filters.h

const float GAMMA = 2.2;
const float SCAN_PITCH = 1.0;
const float THICKNESS = 0.95;
const float OPACITY = 0.95;
const float MASK_INT = 0.5;

float lum3(vec3 col) {
    return col.r * 0.3 + col.g * 0.6 + col.b * 0.1;
}

vec3 bilin(vec2 tc, vec2 e) {
    vec2 f = tc / i_resolution.zw - 0.5;
    vec2 g = fract(f);
    g = clamp((g - 0.5) / max(e, vec2(0.0001)) + 0.5, 0.0, 1.0);
    vec2 p00 = floor(f) + 0.5;
    vec3 c00 = SampleTex(p00 * i_resolution.zw).rgb;
    vec3 c10 = SampleTex((p00 + vec2(1.0, 0.0)) * i_resolution.zw).rgb;
    vec3 c01 = SampleTex((p00 + vec2(0.0, 1.0)) * i_resolution.zw).rgb;
    vec3 c11 = SampleTex((p00 + 1.0) * i_resolution.zw).rgb;
    c00 *= c00; c10 *= c10; c01 *= c01; c11 *= c11;
    return sqrt(mix(mix(c00, c10, g.x), mix(c01, c11, g.x), g.y));
}

void main() {
    // output pixels per source texel row, measured on this quad
    float pxPerRow = 1.0 / (fwidth(frag_tex_coord.y) * i_resolution.y);
    float v2x = max(floor(pxPerRow * 1.05), 1.0);
    vec2 v1xy = vec2(pxPerRow / v2x);        // integer scale: x == y
    vec2 v1zw = (1.0 - 1.0 / v1xy) * 0.5;    // resample grid centering offset
    float v2z = max(floor(v2x * SCAN_PITCH + 0.5), 3.0);
    float v2y = max(floor(pxPerRow * 0.6 + 0.5), 2.0);

    vec2 r = frag_tex_coord - v1zw;
    float s = floor(gl_FragCoord.y) + 0.5;
    r *= v1xy;

    vec2 t = vec2(0.8, 1.0);
    vec2 u = vec2(0.0);
    if (pxPerRow > 1.5) {
        vec3 v = SampleTex(r - vec2((1.0 / i_resolution.x) * 0.45, 0.0)).rgb;
        vec3 w = SampleTex(r + vec2((1.0 / i_resolution.x) * 0.45, 0.0)).rgb;
        u.x = (lum3(v) - lum3(w)) * 0.25 * (1.0 / i_resolution.x) * 0.8;
        t.x = 1.0;
    }

    vec3 y = bilin(r - u, t);
    y = pow(y, vec3(GAMMA));
    vec3 z = y;
    vec3 outRgb;

    if (v2x * SCAN_PITCH > 1.9) {
        float PITCH = v2z;
        vec3 aa = (z * 0.7 + 0.3) * PITCH * THICKNESS;
        float bb = mod(s, PITCH) - PITCH * 0.5;
        vec3 cc;
        cc.rb = vec2(abs(bb * 2.0 - 0.5));
        cc.g = abs(-bb * 2.0 - 0.5);
        vec3 dd = clamp(aa - cc + 0.5, 0.0, 1.0);
        dd *= z / (z * 0.7 + 0.3);
        outRgb = mix(y, dd, OPACITY);
    } else {
        outRgb = y;
    }

    // shadow mask
    {
        float c = v2y;
        vec2 dv;
        dv.x = floor(gl_FragCoord.x) + 0.5;
        dv.y = s;
        float e = floor(c * 0.5 + 0.1);
        dv.x += floor(dv.y / e) * e;              // MASK_TYPE=1
        vec3 f = mod(vec3(dv.x, dv.x + floor(c / 2.0 + 0.5), dv.x), c);
        f = abs((f - c * 0.5) * 2.0 - 0.5);
        vec3 zc = outRgb;
        vec3 k = (zc * MASK_INT + (1.0 - MASK_INT)) * c;
        vec3 l = clamp(k - f + 0.5, 0.0, 1.0);
        l *= zc / (zc * MASK_INT + 1.0 - MASK_INT);
        outRgb = l;
    }
    color = vec4(pow(outRgb, vec3(1.0 / GAMMA)), 1.0);
}
