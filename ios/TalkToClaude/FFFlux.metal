#include <metal_stdlib>
using namespace metal;

// Procedural reproduction of the ffflux SVG: a vertical purple gradient whose
// LUMINANCE is replaced by fractal noise (the feBlend mode="color" step), then the
// saturation is tripled (feColorMatrix saturate=3). All per-pixel — no bitmap.

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Smooth value noise (one "octave" of fractalNoise).
static float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float3 rgb2hsl(float3 c) {
    float mx = max(max(c.r, c.g), c.b);
    float mn = min(min(c.r, c.g), c.b);
    float l = (mx + mn) * 0.5;
    float h = 0.0, s = 0.0;
    float d = mx - mn;
    if (d > 1e-5) {
        s = l > 0.5 ? d / (2.0 - mx - mn) : d / (mx + mn);
        if (mx == c.r)      h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0);
        else if (mx == c.g) h = (c.b - c.r) / d + 2.0;
        else                h = (c.r - c.g) / d + 4.0;
        h /= 6.0;
    }
    return float3(h, s, l);
}

static float hue2rgb(float p, float q, float t) {
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

static float3 hsl2rgb(float3 hsl) {
    float h = hsl.x, s = hsl.y, l = hsl.z;
    if (s < 1e-5) return float3(l);
    float q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
    float p = 2.0 * l - q;
    return float3(hue2rgb(p, q, h + 1.0 / 3.0),
                  hue2rgb(p, q, h),
                  hue2rgb(p, q, h - 1.0 / 3.0));
}

[[ stitchable ]] half4 ffflux(float2 pos, float2 size) {
    float2 uv = pos / max(size, float2(1.0));

    // Vertical gradient: #550b45 -> hsl(308,97%,13%).
    float3 top = float3(0.333, 0.043, 0.271);
    float3 bot = float3(0.256, 0.004, 0.222);
    float3 grad = mix(top, bot, uv.y);
    float3 hsl = rgb2hsl(grad);

    // baseFrequency 0.007 0.003 over a 700-box -> ~5 x ~2 large, vertically-stretched
    // cells. Two weighted octaves keep it smooth (like numOctaves=1) but not blocky.
    float n = vnoise(uv * float2(5.0, 2.2)) * 0.7
            + vnoise(uv * float2(11.0, 5.0) + 7.0) * 0.3;
    n = clamp(n, 0.0, 1.0);

    hsl.z = mix(0.05, 0.34, n);              // luminance comes from the noise
    hsl.y = clamp(hsl.y * 3.0, 0.0, 1.0);    // saturate x3

    return half4(half3(hsl2rgb(hsl)), 1.0h);
}
