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

// Three-tone toon ramp from the lab, with a hatched shadow band.
// Softness widens each band edge into a smoothstep; 0 gives the lab's hard bands.
// ShadowUV is the mesh UV times Shadow Scale, so the hatching sticks to the surface instead of the screen (the lab's
// Puzzle 3 sampled by screen position). The texture is white paper with dark pen strokes: inside the shadow band the
// strokes are drawn in Shadow * HatchColor. HatchSpread treats stroke pixels as a little darker than they are, so near
// the terminator strokes poke out of the shadow into the midtone and fray the edge like hand-drawn hatching.
void ChooseColor_float(float3 Highlight, float3 Midtone, float3 Shadow, float Diffuse,
                       float ShadowThreshold, float HighlightThreshold, float Softness,
                       float2 ShadowUV, UnityTexture2D ShadowTexture, float3 HatchColor, float HatchSpread,
                       out float3 OUT)
{
    float ink = 1 - SAMPLE_TEXTURE2D(ShadowTexture.tex, ShadowTexture.samplerstate, ShadowUV).r;
    float3 hatchedShadow = lerp(Shadow, Shadow * HatchColor, ink);

    float s = max(Softness, 1e-4);
    float aboveShadow = smoothstep(ShadowThreshold - s, ShadowThreshold + s, Diffuse - ink * HatchSpread);
    float aboveMidtone = smoothstep(HighlightThreshold - s, HighlightThreshold + s, Diffuse);

    OUT = lerp(lerp(hatchedShadow, Midtone, aboveShadow), Highlight, aboveMidtone);
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
