void GetMainLight_float(float3 WorldPos, out float3 Color, out float3 Direction, out float DistanceAtten, out float ShadowAtten)
{
#ifdef SHADERGRAPH_PREVIEW
    Direction = normalize(float3(0.5, 0.5, 0));
    Color = 1;
    DistanceAtten = 1;
    ShadowAtten = 1;
#else
#if SHADOWS_SCREEN
        float4 clipPos = TransformWorldToClip(WorldPos);
        float4 shadowCoord = ComputeScreenPos(clipPos);
#else
    float4 shadowCoord = TransformWorldToShadowCoord(WorldPos);
#endif

    Light mainLight = GetMainLight(shadowCoord);
    Direction = mainLight.direction;
    Color = mainLight.color;
    DistanceAtten = mainLight.distanceAttenuation;
    ShadowAtten = mainLight.shadowAttenuation;
#endif
}

void ComputeAdditionalLighting_float(float3 WorldPosition, float3 WorldNormal,
    float2 Thresholds, float3 RampedDiffuseValues,
    out float3 Color, out float Diffuse)
{
    Color = float3(0, 0, 0);
    Diffuse = 0;

#ifndef SHADERGRAPH_PREVIEW

    uint pixelLightCount = GetAdditionalLightsCount();

    for (uint i = 0; i < pixelLightCount; ++i)
    {
        Light light = GetAdditionalLight(i, WorldPosition);
        float4 tmp = unity_LightIndices[i / 4];
        uint light_i = tmp[i % 4];

        half shadowAtten = light.shadowAttenuation * AdditionalLightRealtimeShadow(light_i, WorldPosition, light.direction);

        half NdotL = saturate(dot(WorldNormal, light.direction));
        half distanceAtten = light.distanceAttenuation;

        half thisDiffuse = distanceAtten * shadowAtten * NdotL;

        half rampedDiffuse = 0;

        if (thisDiffuse < Thresholds.x)
        {
            rampedDiffuse = RampedDiffuseValues.x;
        }
        else if (thisDiffuse < Thresholds.y)
        {
            rampedDiffuse = RampedDiffuseValues.y;
        }
        else
        {
            rampedDiffuse = RampedDiffuseValues.z;
        }


        if (light.distanceAttenuation <= 0)
        {
            rampedDiffuse = 0.0;
        }

        Color += max(rampedDiffuse, 0) * light.color.rgb;
        Diffuse += rampedDiffuse;
    }

    if (Diffuse <= 0.3)
    {
        Color = float3(0, 0, 0);
        Diffuse = 0;
    }

#endif
}

// ---------------------------------------------------------------------------------------------------------------------
// Watercolour shadows
// ---------------------------------------------------------------------------------------------------------------------

// Hash without Sine (David Hoskins, MIT): 3 in, 1 out.
float WashHash13(float3 p3)
{
    p3 = frac(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return frac((p3.x + p3.y) * p3.z);
}

// Smooth 3D value noise in [0, 1].
float WashNoise3(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);
    f = f * f * (3 - 2 * f);
    return lerp(lerp(lerp(WashHash13(i), WashHash13(i + float3(1, 0, 0)), f.x),
                     lerp(WashHash13(i + float3(0, 1, 0)), WashHash13(i + float3(1, 1, 0)), f.x), f.y),
                lerp(lerp(WashHash13(i + float3(0, 0, 1)), WashHash13(i + float3(1, 0, 1)), f.x),
                     lerp(WashHash13(i + float3(0, 1, 1)), WashHash13(i + float3(1, 1, 1)), f.x), f.y), f.z);
}

// Three octaves around 0.5: lumpy, splashed shapes rather than smooth blobs.
float WashFbm3(float3 p)
{
    return 0.57 * WashNoise3(p) + 0.29 * WashNoise3(p * 2.07 + 17.1) + 0.14 * WashNoise3(p * 4.13 + 5.3);
}

#ifndef SHADERGRAPH_PREVIEW
// Distance in metres along the main light from positionWS to the caster in front of it in the shadow map (<= 0 when
// nothing is in front). Reads the raw shadow-map depth; the directional light's projection is orthographic, so a
// depth difference converts to metres by the length of the cascade's world-to-shadow z row.
float ShadowCasterDistance(float3 positionWS)
{
#if defined(_MAIN_LIGHT_SHADOWS_CASCADE)
    half cascadeIndex = ComputeCascadeIndex(positionWS);
#else
    half cascadeIndex = 0;
#endif
    float4x4 worldToShadow = _MainLightWorldToShadow[cascadeIndex];
    float depthPerMetre = length(worldToShadow[2].xyz);
    if (depthPerMetre < 1e-6) return 0;                         // beyond the last cascade
    float3 coord = mul(worldToShadow, float4(positionWS, 1.0)).xyz;
    float caster = SAMPLE_TEXTURE2D_LOD(_MainLightShadowmapTexture, sampler_PointClamp, coord.xy, 0).r;
#if UNITY_REVERSED_Z
    return (caster - coord.z) / depthPerMetre;
#else
    return (coord.z - caster) / depthPerMetre;
#endif
}
#endif

// Watercolour cast shadows, after the concept art: a translucent wash that is darkest where it touches the caster,
// spreads and softens as it runs away from it, and fades out with no hard outline.
// 1. Caster search: 12 taps over a disc find how far, along the light, this point is from the casters shadowing it.
// 2. Penumbra: the main light's shadow is averaged over a disc of Soft Radius + distance x Penumbra Growth (metres),
//    so the shadow is crisp at the feet and feathers out toward its far end (like contact-hardening soft shadows).
// 3. Fade: the shadow thins out with the same distance and is gone at Fade Distance.
// Both discs lie in the surface's tangent plane, so samples never dip below a receiver that also casts shadows (which
// would make it shadow itself). Their centre is pushed around by world-space noise (Edge Jitter, metres), so the
// outline comes out irregular.
void WatercolorShadow_float(float3 WorldPos, float3 WorldNormal, float SoftRadius, float EdgeJitter,
                            float PenumbraGrowth, float FadeDistance, out float ShadowAtten)
{
#ifdef SHADERGRAPH_PREVIEW
    ShadowAtten = 1;
#else
    float3 n = normalize(WorldNormal);
    float3 t1 = normalize(cross(n, abs(n.y) < 0.99 ? float3(0, 1, 0) : float3(1, 0, 0)));
    float3 t2 = cross(n, t1);
    float3 p = WorldPos * 6.0;
    float2 jitter = float2(WashFbm3(p), WashFbm3(p + 31.7)) * 2 - 1;
    float3 centre = WorldPos + n * (0.25 * SoftRadius + 0.002) + (t1 * jitter.x + t2 * jitter.y) * EdgeJitter;
    FadeDistance = max(FadeDistance, 1e-3);

    const int searchTaps = 12;
    float searchRadius = SoftRadius + FadeDistance * PenumbraGrowth;
    float distanceSum = 0;
    float casters = 0;
    for (int i = 0; i < searchTaps; i++)
    {
        float r = searchRadius * sqrt((i + 0.5) / searchTaps);
        float a = i * 2.39996323;
        float d = ShadowCasterDistance(centre + (t1 * cos(a) + t2 * sin(a)) * r);
        if (d > 0.01)
        {
            distanceSum += d;
            casters += 1;
        }
    }
    if (casters == 0)
    {
        ShadowAtten = 1;
        return;
    }
    float distance = distanceSum / casters;

    const int taps = 16;
    float radius = SoftRadius + distance * PenumbraGrowth;
    float lit = 0;
    for (int j = 0; j < taps; j++)
    {
        float r = radius * sqrt((j + 0.5) / taps);
        float a = j * 2.39996323 + 1.3;
        lit += MainLightRealtimeShadow(TransformWorldToShadowCoord(centre + (t1 * cos(a) + t2 * sin(a)) * r));
    }
    lit /= taps;

    float core = smoothstep(0, 0.6, 1 - lit);                   // the middle of the shadow reaches full strength
    float opacity = 1 - smoothstep(0, FadeDistance, distance);
    ShadowAtten = 1 - core * opacity;
#endif
}

// Three-tone toon ramp from the lab, where the shadow band is a watercolour wash.
// - Edge: the terminator is pushed around by world-space noise (Edge Breakup, Breakup Scale per metre), so washes get
//   irregular, splashed outlines that don't depend on mesh UVs (generated meshes have fragmented UVs). Softness is
//   the width of the wash edge; 0 gives the lab's hard bands.
// - Wash: a translucent glaze of Shadow over the lit colour. Its pigment comes from the custom Watercolor Wash
//   texture, sampled with mesh UV x Shadow Scale (darker = more pigment) at Wash Strength: thin spots let the lit
//   colour show through, dense spots go darker.
// - Edge Darkening: pigment pools into a slightly darker rim just inside the wash edge, the way a wash dries.
// - Cast shadows (CastShadow, from WatercolorShadow) skip the bands: they are laid on as the same glaze with
//   continuous opacity, so they keep their gradual fade and get no hard edge or darkened rim.
// Base Map (white by default) multiplies all three tones, so for textured models the tones act as tints. BaseTint is
// the textured midtone (to tint the additional lights); Alpha is the Base Map's alpha (for the graph's alpha clip).
void ChooseColor_float(float3 Highlight, float3 Midtone, float3 Shadow, float Diffuse, float CastShadow,
                       float ShadowThreshold, float HighlightThreshold, float Softness,
                       float2 ShadowUV, UnityTexture2D ShadowTexture, float WashStrength,
                       float3 WorldPos, float EdgeBreakup, float BreakupScale, float EdgeDarkening,
                       float2 BaseUV, UnityTexture2D BaseMap,
                       out float3 OUT, out float3 BaseTint, out float Alpha)
{
    float4 baseSample = SAMPLE_TEXTURE2D(BaseMap.tex, BaseMap.samplerstate, BaseUV);
    float3 albedo = baseSample.rgb;
    Alpha = baseSample.a;
    Highlight *= albedo;
    Midtone *= albedo;
    Shadow *= albedo;
    BaseTint = Midtone;

    float s = max(Softness, 1e-3);
    float breakup = (WashFbm3(WorldPos * BreakupScale) - 0.5) * EdgeBreakup;
    float depth = ShadowThreshold - (Diffuse + breakup);           // > 0 inside the wash
    float wash = smoothstep(-s, s, depth);
    float rim = wash * (1 - smoothstep(s, s + 0.15, depth));
    float glaze = 1 - (1 - wash) * saturate(CastShadow);

    float pigment = (0.5 - SAMPLE_TEXTURE2D(ShadowTexture.tex, ShadowTexture.samplerstate, ShadowUV).r) * 2;
    float coverage = saturate(glaze * (1 + min(pigment, 0) * WashStrength));
    float3 washColor = Shadow * (1 - EdgeDarkening * rim) * (1 - max(pigment, 0) * WashStrength * 0.35);

    float aboveMidtone = smoothstep(HighlightThreshold - s, HighlightThreshold + s, Diffuse + breakup * 0.5);
    OUT = lerp(lerp(Midtone, Highlight, aboveMidtone), washColor, coverage);
}

// Toon rim light: a crisp band along the silhouette (Fresnel), kept to the side the main light hits by weighting it
// with the shadowed diffuse, so the rim also disappears inside cast shadows. Lower LightBias lets it reach further
// toward the terminator. The band is blended toward RimColor rather than added, so it stays visible on pale
// materials where an additive rim would just clip to white.
void RimLight_float(float3 BaseColor, float3 WorldNormal, float3 ViewDir, float Diffuse, float3 RimColor,
                    float RimSize, float RimSoftness, float LightBias, out float3 OUT)
{
    float fresnel = 1 - saturate(dot(normalize(WorldNormal), normalize(ViewDir)));
    float rim = fresnel * pow(saturate(Diffuse), max(LightBias, 0.01));

    float edge = 1 - RimSize;
    float s = max(RimSoftness, 1e-4);
    OUT = lerp(BaseColor, RimColor, smoothstep(edge - s, edge + s, rim));
}
