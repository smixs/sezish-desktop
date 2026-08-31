// Liquid-metal rim for the recording overlay — MSL port of the plasma effect
// from metal-fx (https://github.com/Jakubantalik/metal-fx, MIT (c) 2026 Jakub
// Antalik), matching the site's metal.js chromatic-dark preset. The preset is
// baked as constants: all palette alphas are 1, so the original's palette-alpha
// path collapses to 1 and is not ported; blur is 1, so the reference's 5-tap
// cross blur is always active and is ported as-is.

#include <metal_stdlib>
using namespace metal;

// Tuned by eye with the user (2026-07-25): gold from the brand glyph, the
// canonical green back in (it sells the metal), rose kept, dark bookends.
constant float3 kColor1 = float3(0.000, 0.000, 0.000); // #000000
constant float3 kColor2 = float3(0.949, 0.753, 0.471); // #f2c078 soft gold
constant float3 kColor3 = float3(0.773, 0.996, 0.620); // #c5fe9e green (metallic sheen)
constant float3 kColor4 = float3(0.969, 0.533, 0.553); // #f7888d rose
constant float3 kColor5 = float3(0.051, 0.051, 0.051); // #0d0d0d

constant float kDirection = 80.0 * M_PI_F / 180.0;
constant float kIntensity = 2.0;
constant float kScale = 1.6;
constant float kDistortion = 0.3;
// freq = 3.0 + complexity * 8.0 with the reference complexity of 0.68.
constant float kFreq = 8.44;
constant float kBlur = 1.0;
constant float kVignette = 0.26;
constant float kVigOpacity = 0.6;
constant float kShaderOpacity = 0.7;

static float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float2 mod289v2(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float3 permute(float3 x) { return mod289((x * 34.0 + 1.0) * x); }

static float snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439,
                            -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod289v2(i);
    float3 p = permute(permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    float3 x_ = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x_) - 0.5;
    float3 ox = floor(x_ + 0.5);
    float3 a0 = x_ - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

// Reference nfbm: fbm(p, 3.0 + complexity * 4.0) with complexity 0.68 gives
// int(5.72) = 5 octaves.
static float fbm5(float2 p) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 5; i++) {
        val += amp * snoise(p);
        p *= 2.0;
        amp *= 0.5;
    }
    return val;
}

// 5-stop gaussian palette, stops at t = 0 / .25 / .5 / .75 / 1
static float3 palette(float t) {
    t = clamp(t, 0.0, 1.0);
    t = t * t * (3.0 - 2.0 * t);
    const float k = 64.0;
    float w1 = exp(-k * t * t);
    float w2 = exp(-k * (t - 0.25) * (t - 0.25));
    float w3 = exp(-k * (t - 0.50) * (t - 0.50));
    float w4 = exp(-k * (t - 0.75) * (t - 0.75));
    float w5 = exp(-k * (t - 1.00) * (t - 1.00));
    float total = w1 + w2 + w3 + w4 + w5 + 0.0001;
    return (kColor1 * w1 + kColor2 * w2 + kColor3 * w3 + kColor4 * w4 + kColor5 * w5) / total;
}

static float2 warp(float2 p, float t) {
    const float str = kDistortion * 2.0;
    return float2(
        fbm5(p + float2(t * 0.1, 0.0)),
        fbm5(p + float2(0.0, t * 0.12) + 5.0)
    ) * str;
}

// Plasma: four sine bands warped by an FBM field, mapped through the palette.
static float3 computeEffect(float2 uv, float aspect, float t) {
    float2 p = (uv - 0.5) * kScale;
    p.x *= aspect;
    p += float2(cos(kDirection), sin(kDirection)) * t * 0.15;

    float val = 0.0;
    val += sin(p.x * kFreq + t);
    val += sin(p.y * kFreq + t * 1.3);
    val += sin((p.x + p.y) * kFreq * 0.7 + t * 0.7);
    val += sin(length(p) * kFreq * 0.8 - t * 1.5);
    float2 w = warp(p, t);
    val += (w.x + w.y) * kDistortion;
    val = val * 0.2 * kIntensity + 0.5;

    return palette(clamp(val, 0.0, 1.0));
}

// `time` arrives pre-multiplied by the preset speed (0.4), as in metal.js.
// `color` is the stroke-ring mask: its alpha carries the shape (and AA edges).
[[stitchable]] half4 metalRim(float2 position, half4 color, float2 size, float time) {
    if (color.a <= 0.0h) {
        return color;
    }

    float2 uv = position / size;
    uv.y = 1.0 - uv.y; // gl_FragCoord parity with the WebGL original

    float aspect = size.x / size.y;

    // 5-tap cross blur, center plus cardinal offsets, exactly as the reference
    // main(). The preset ships blur = 1, so the radius is 1 * 0.02 in uv space.
    const float r = kBlur * 0.02;
    float3 col  = computeEffect(uv,                        aspect, time) * 0.4;
    col        += computeEffect(uv + float2( r, 0.0),      aspect, time) * 0.15;
    col        += computeEffect(uv + float2(-r, 0.0),      aspect, time) * 0.15;
    col        += computeEffect(uv + float2(0.0,  r),      aspect, time) * 0.15;
    col        += computeEffect(uv + float2(0.0, -r),      aspect, time) * 0.15;

    col = pow(col, float3(1.3));

    // Vignette — the 40 px scale is hard-coded in the canonical engine.
    float edgeDist = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
    float vigPx = 40.0 / min(size.x, size.y);
    float vigRange = vigPx * (1.0 + kVignette * 3.0);
    float vig = smoothstep(0.0, 1.0, edgeDist * edgeDist / (vigRange * vigRange));
    col *= mix(1.0, vig, kVignette * kVigOpacity);

    // Premultiplied output; the ring mask's alpha keeps the shape.
    float alpha = kShaderOpacity * float(color.a);
    return half4(half3(col * alpha), half(alpha));
}
