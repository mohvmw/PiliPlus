// HDR Vision for mpv — BT.2446a inverse tone mapping (SDR -> simulated HDR)
//
// Ported from the HDR Vision userscript (WebGPU/WGSL) to an mpv user shader.
// The userscript renders each video frame through a WebGPU pipeline and draws
// it on an overlay canvas; here the same math runs inside mpv's own GPU
// pipeline (vo_gpu), so it works in any mpv-based player — including
// PiliPlus on iOS (media_kit + libmpv, OpenGL ES render path).
//
// Pipeline (identical order to the userscript's video shader):
//   1. multi-scale deband (4 ring scales, detail-preserving)
//   2. BT.2446a inverse EOTF with mid-tone lift (the default mapping mode)
//   3. saturation adjustment in OKLab
// Sharpening (CAS) is intentionally left out: it is disabled by default
// in the userscript as well.
//
// Defaults below match the userscript's bt2446a preset:
//   exposure 0.0, saturation 1.1, peak 1.7, boost 1.15, midToneLift 0.35,
//   deband threshold 0.012.
// pHDR / logPHDR are precomputed from peak:
//   maxL = max(peak, 1.0) * 100 = 170
//   pHDR = 1 + 32 * pow(maxL / 10000, 1 / 2.4) = 6.859182545952805
//   logPHDR = log(pHDR) = 1.925588272239841
//
// Usage (mpv): add this file to the `glsl-shaders` list, e.g.
//   mpv --glsl-shaders="HDR_Vision_BT2446a.glsl" video.mp4
// In PiliPlus it is toggled from the player menu ("HDR 模拟") and applied
// through the existing `change-list glsl-shaders` machinery.
//
// Note: this is an SDR->HDR *simulation*. It expands highlight range and
// perceived dynamic range, but the output is still written into mpv's
// (8-bit) output framebuffer, exactly like the userscript's SDR path.
// Turn it off for sources that are already true HDR.

//!DESC HDR Vision BT.2446a inverse tone mapping
//!HOOK MAIN
//!BIND HOOKED

#define PEAK 1.7
#define BOOST 1.15
#define MID_LIFT 0.35
#define SATURATION 1.1
#define DEBAND_THRESHOLD 0.012
#define PHDR 6.859182545952805
#define LOG_PHDR 1.925588272239841
#define MAX_OUT 5.0

float luminance(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

vec3 processInOKLab(vec3 color, float saturationFactor) {
    vec3 c = max(color, vec3(0.0));
    float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
    float l_ = pow(max(l, 1e-8), 1.0 / 3.0);
    float m_ = pow(max(m, 1e-8), 1.0 / 3.0);
    float s_ = pow(max(s, 1e-8), 1.0 / 3.0);
    float L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
    float a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
    float b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;
    a *= saturationFactor;
    b *= saturationFactor;
    float l2_ = L + 0.3963377774 * a + 0.2158037573 * b;
    float m2_ = L - 0.1055613458 * a - 0.0638541728 * b;
    float s2_ = L - 0.0894841775 * a - 1.2914855480 * b;
    float l2 = l2_ * l2_ * l2_;
    float m2 = m2_ * m2_ * m2_;
    float s2 = s2_ * s2_ * s2_;
    return vec3(
         4.0767416621 * l2 - 3.3077115913 * m2 + 0.2309699292 * s2,
        -1.2684380046 * l2 + 2.6097574011 * m2 - 0.3413193965 * s2,
        -0.0041960863 * l2 - 0.7034186147 * m2 + 1.7076147010 * s2
    );
}

// BT.2446a inverse EOTF with mid-tone lift (mirrors the userscript).
vec3 bt2446aInverseWithLift(vec3 color) {
    float luma = luminance(color);
    float lumaClamped = clamp(luma, 0.0, 1.0);
    if (lumaClamped < 1e-5) {
        return color;
    }

    float Yp;
    if (lumaClamped <= 0.7969) {
        Yp = lumaClamped / 1.0770;
    } else if (lumaClamped >= 0.99545) {
        Yp = 2.0 * lumaClamped - 1.0;
    } else {
        float a = 1.1510;
        float b = -2.7811;
        float c = 0.6302 + lumaClamped;
        float disc = b * b - 4.0 * a * c;
        float sqrtDisc = sqrt(max(disc, 0.0));
        Yp = (-b - sqrtDisc) / (2.0 * a);
    }

    float Y = (exp(Yp * LOG_PHDR) - 1.0) / (PHDR - 1.0);
    float outputLuma = Y * PEAK * BOOST;
    float gain = outputLuma / lumaClamped;
    vec3 result = color * gain;

    if (outputLuma > MAX_OUT) {
        float excess = outputLuma - MAX_OUT;
        float compressed = MAX_OUT + excess / (1.0 + excess / MAX_OUT);
        result = result * (compressed / outputLuma);
        outputLuma = compressed;
    }

    if (MID_LIFT > 0.001 && outputLuma > 1e-5) {
        float effectivePeak = min(PEAK * BOOST, MAX_OUT);
        float norm = clamp(outputLuma / effectivePeak, 0.0, 1.0);
        float gamma = 1.0 / (1.0 + MID_LIFT * 0.7);
        float liftedNorm = pow(norm, gamma);
        float newLuma = liftedNorm * effectivePeak;
        float lumaScale = max(newLuma / outputLuma, 1.0);
        result = result * lumaScale;
    }

    return result;
}

struct RingResult {
    vec3 avg;
    float variance;
};

// 8-tap ring sample, returns the ring average and its variance.
RingResult sampleRingWithStats(vec2 uv, vec2 pt, float radius) {
    vec2 t = pt * radius;
    vec3 s0 = HOOKED_tex(uv + vec2(t.x, 0.0)).rgb;
    vec3 s1 = HOOKED_tex(uv - vec2(t.x, 0.0)).rgb;
    vec3 s2 = HOOKED_tex(uv + vec2(0.0, t.y)).rgb;
    vec3 s3 = HOOKED_tex(uv - vec2(0.0, t.y)).rgb;
    vec3 s4 = HOOKED_tex(uv + t).rgb;
    vec3 s5 = HOOKED_tex(uv - t).rgb;
    vec3 s6 = HOOKED_tex(uv + vec2(t.x, -t.y)).rgb;
    vec3 s7 = HOOKED_tex(uv + vec2(-t.x, t.y)).rgb;

    vec3 avg = (s0 + s1 + s2 + s3 + s4 + s5 + s6 + s7) * 0.125;

    float d0 = abs(s0.r - avg.r) + abs(s0.g - avg.g) + abs(s0.b - avg.b);
    float d1 = abs(s1.r - avg.r) + abs(s1.g - avg.g) + abs(s1.b - avg.b);
    float d2 = abs(s2.r - avg.r) + abs(s2.g - avg.g) + abs(s2.b - avg.b);
    float d3 = abs(s3.r - avg.r) + abs(s3.g - avg.g) + abs(s3.b - avg.b);
    float d4 = abs(s4.r - avg.r) + abs(s4.g - avg.g) + abs(s4.b - avg.b);
    float d5 = abs(s5.r - avg.r) + abs(s5.g - avg.g) + abs(s5.b - avg.b);
    float d6 = abs(s6.r - avg.r) + abs(s6.g - avg.g) + abs(s6.b - avg.b);
    float d7 = abs(s7.r - avg.r) + abs(s7.g - avg.g) + abs(s7.b - avg.b);
    float variance = (d0 + d1 + d2 + d3 + d4 + d5 + d6 + d7) * 0.125;

    return RingResult(avg, variance);
}

// Multi-scale adaptive deband, ported from the userscript:
// fine/medium/edge scales protect detail, the wide scale finds banding.
vec3 applyDeband(vec2 uv, vec2 pt, vec3 centerColor, float threshold) {
    RingResult r3  = sampleRingWithStats(uv, pt, 3.0);
    RingResult r8  = sampleRingWithStats(uv, pt, 8.0);
    RingResult r12 = sampleRingWithStats(uv, pt, 12.0);
    RingResult r28 = sampleRingWithStats(uv, pt, 28.0);

    float d3  = smoothstep(threshold * 0.5, threshold * 3.0, r3.variance);
    float d8  = smoothstep(threshold * 0.5, threshold * 3.0, r8.variance);
    float d12 = smoothstep(threshold * 0.5, threshold * 3.0, r12.variance);
    float detailMask = max(max(d3, d8), d12);

    float flatLarge = 1.0 - smoothstep(threshold * 0.5, threshold * 2.5, r28.variance);

    float strength = flatLarge * (1.0 - detailMask) * 0.92;

    vec3 smoothValue = r3.avg * 0.2 + r12.avg * 0.5 + r28.avg * 0.3;

    return mix(centerColor, smoothValue, strength);
}

vec4 hook() {
    vec2 uv = HOOKED_pos;
    vec2 pt = vec2(1.0) / HOOKED_size;

    vec3 color = HOOKED_tex(uv).rgb;

    // Same order as the userscript: deband first, then the color pipeline.
    color = applyDeband(uv, pt, color, DEBAND_THRESHOLD);
    color = bt2446aInverseWithLift(color);
    color = processInOKLab(color, SATURATION);

    return vec4(color, 1.0);
}
