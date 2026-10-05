// Hash without Sine (David Hoskins, MIT).
float PostHash11(float p)
{
    p = frac(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return frac(p);
}

float PostHash12(float2 p)
{
    float3 p3 = frac(p.xyx * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

// Survival-horror finish, matched to the concept art.
// - Vignette: the art's backdrop darkens toward the top-right, so the frame is closed in by an off-centre slate
//   vignette (Vignette Center is in UV, radius in screen heights). Its edge bleeds in like a watercolour wash (the
//   Wash Texture drifting slowly in screen space, Bleed Amount / Bleed Scale), and it breathes and now and then
//   flickers like a failing torch (Flicker). Inside the vignette the image keeps some of its own value, so detail
//   survives in the dark.
// - Grade: slightly desaturated, cool slate lifted into the darks (Shadow Tint), warm gain toward the highlights
//   (Highlight Tint).
// - Grain: fine monochrome film grain, strongest in the darks, re-rolled 24 times a second.
void HorrorPost_float(float2 UV, UnityTexture2D MainTex, UnityTexture2D WashTex, float Time,
                      float3 VignetteColor, float VignetteCenterX, float VignetteCenterY, float VignetteRadius,
                      float VignetteSoftness, float VignetteStrength, float BleedAmount, float BleedScale,
                      float Flicker, float3 ShadowTint, float3 HighlightTint, float Desaturate, float Grain,
                      out float3 OUT)
{
    float3 c = SAMPLE_TEXTURE2D(MainTex.tex, MainTex.samplerstate, UV).rgb;
    float aspect = _ScreenParams.x / _ScreenParams.y;

    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = lerp(c, lum.xxx, Desaturate);
    c += ShadowTint * (1 - lum) * (1 - lum) * 0.25;
    c *= lerp(float3(1, 1, 1), HighlightTint, saturate(lum));

    float2 d = (UV - float2(VignetteCenterX, VignetteCenterY)) * float2(aspect, 1);
    float2 washUV = UV * float2(aspect, 1) * BleedScale + Time * float2(0.004, 0.0025);
    float bleed = (SAMPLE_TEXTURE2D(WashTex.tex, WashTex.samplerstate, washUV).r - 0.5) * BleedAmount;
    float breathe = 0.5 + 0.5 * sin(Time * 0.9 + sin(Time * 0.37) * 2.0);
    float flick = step(0.9, PostHash11(floor(Time * 10.0)));
    float radius = VignetteRadius * (1 - Flicker * (0.06 * breathe + 0.12 * flick));
    float s = max(VignetteSoftness, 1e-3);
    float mask = smoothstep(radius - s, radius + s, length(d) + bleed) * VignetteStrength;
    c = lerp(c, VignetteColor * (0.55 + 0.45 * lum), mask);

    float seed = PostHash11(floor(Time * 24.0)) * 1000.0;
    float grain = PostHash12(UV * _ScreenParams.xy + seed) - 0.5;
    c += grain * Grain * (1.2 - lum);

    OUT = saturate(c);
}
