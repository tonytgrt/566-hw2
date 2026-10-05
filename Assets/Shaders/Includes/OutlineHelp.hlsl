SAMPLER(sampler_point_clamp);

void GetDepth_float(float2 uv, out float Depth)
{
    Depth = SHADERGRAPH_SAMPLE_SCENE_DEPTH(uv);
}


void GetNormal_float(float2 uv, out float3 Normal)
{
    Normal = SAMPLE_TEXTURE2D(_NormalsBuffer, sampler_point_clamp, uv).rgb;
}

// ---------------------------------------------------------------------------------------------------------------------
// Sketchy post-process outlines from the depth and normal buffers.
// ---------------------------------------------------------------------------------------------------------------------

// 3x3 neighbourhood, row by row from the top: 0 1 2 / 3 4 5 / 6 7 8 (4 is the centre).
static const float2 kOutlineTaps[9] =
{
    float2(-1, 1), float2(0, 1), float2(1, 1),
    float2(-1, 0), float2(0, 0), float2(1, 0),
    float2(-1, -1), float2(0, -1), float2(1, -1)
};

// Hash without Sine (David Hoskins, MIT).
float OutlineHash12(float2 p)
{
    float3 p3 = frac(p.xyx * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float2 OutlineHash21(float p)
{
    float3 p3 = frac(p * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.xx + p3.yz) * p3.zy);
}

// Smooth 2D value noise in [0, 1].
float OutlineValueNoise(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    f = f * f * (3 - 2 * f);
    return lerp(lerp(OutlineHash12(i), OutlineHash12(i + float2(1, 0)), f.x),
                lerp(OutlineHash12(i + float2(0, 1)), OutlineHash12(i + float2(1, 1)), f.x), f.y);
}

// Filter 0 = Roberts Cross (diagonal corners), 1 = Sobel, 2 = Laplacian. Each is normalised so a step of height h
// reads as roughly h.
float OutlineFilter(float v[9], int filter)
{
    if (filter == 0)
        return sqrt((v[2] - v[6]) * (v[2] - v[6]) + (v[0] - v[8]) * (v[0] - v[8]));

    if (filter == 1)
    {
        float gx = (v[2] + 2 * v[5] + v[8]) - (v[0] + 2 * v[3] + v[6]);
        float gy = (v[0] + 2 * v[1] + v[2]) - (v[6] + 2 * v[7] + v[8]);
        return sqrt(gx * gx + gy * gy) * 0.25;
    }

    return abs(v[3] + v[5] - 2 * v[4]) + abs(v[1] + v[7] - 2 * v[4]);
}

float OutlineFilter3(float3 v[9], int filter)
{
    if (filter == 0)
        return sqrt(dot(v[2] - v[6], v[2] - v[6]) + dot(v[0] - v[8], v[0] - v[8]));

    if (filter == 1)
    {
        float3 gx = (v[2] + 2 * v[5] + v[8]) - (v[0] + 2 * v[3] + v[6]);
        float3 gy = (v[0] + 2 * v[1] + v[2]) - (v[6] + 2 * v[7] + v[8]);
        return sqrt(dot(gx, gx) + dot(gy, gy)) * 0.25;
    }

    return length(v[3] + v[5] - 2 * v[4]) + length(v[1] + v[7] - 2 * v[4]);
}

// Depth discontinuity relative to distance, so one threshold works near and far. Roberts and Sobel run on eye depth
// divided by the nearest tap. The Laplacian runs on 1/depth, which is linear across any plane in screen space, so
// floors seen at grazing angles produce no false edges. Also returns the uv of the nearest tap, so the line can take
// the colour of whatever is in front.
float OutlineDepthEdge(float2 uv, float2 offset, int filter, out float2 nearestUV, out float nearest)
{
    float eye[9];
    float inv[9];
    nearest = 1e20;
    nearestUV = uv;
    for (int i = 0; i < 9; i++)
    {
        float2 tapUV = uv + kOutlineTaps[i] * offset;
        float raw;
        GetDepth_float(tapUV, raw);
        eye[i] = LinearEyeDepth(raw, _ZBufferParams);
        inv[i] = 1.0 / eye[i];
        if (eye[i] < nearest)
        {
            nearest = eye[i];
            nearestUV = tapUV;
        }
    }

    if (filter == 2)
        return OutlineFilter(inv, 2) * nearest;
    return OutlineFilter(eye, filter) / nearest;
}

// Crease strength from the view-space normals buffer. Pixels that never got a normal (background, and anything on
// the "No Normal" layer such as the ground) are cleared to black; silhouettes there are left to the depth lines.
float OutlineNormalEdge(float2 uv, float2 offset, int filter)
{
    float3 n[9];
    float allWritten = 1;
    for (int i = 0; i < 9; i++)
    {
        float3 encoded;
        GetNormal_float(uv + kOutlineTaps[i] * offset, encoded);
        allWritten *= step(0.01, dot(encoded, 1));
        n[i] = encoded * 2 - 1;
    }
    return OutlineFilter3(n, filter) * allWritten;
}

// Step is floor(Time * Boil Rate). Silhouette (depth) lines wobble, change thickness and re-roll their grain every
// step, like a drawing redrawn on twos; crease (normal) lines stay put so the drawing keeps its structure.
// Line colour is the colour of the object in front times Line Tint (darker and redder, like the concept art's coloured
// line art), mixed toward the flat Line Color by Ink Mix. Lines fade out between Fade Start and Fade End (metres), so
// a ground plane cut off by the far clip plane doesn't draw a horizon line.
// Debug View: 0 final, 1 lines only, 2 normals buffer, 3 depth buffer.
void SketchOutline_float(float2 UV, float CenterRawDepth, UnityTexture2D MainTex, float Step,
                         float Width, float EdgeFilter, float DepthThreshold, float NormalThreshold,
                         float NormalLineStrength, float3 LineColor, float3 LineTint, float InkMix,
                         float WobbleAmount, float WobbleScale, float ThicknessJitter, float Grain,
                         float FadeStart, float FadeEnd, float DebugView,
                         out float3 OUT)
{
    float2 texel = 1.0 / _ScreenParams.xy;
    float px = _ScreenParams.y / 1080.0;   // widths and wobble are authored in 1080p pixels
    int filter = (int)round(EdgeFilter);

    float2 seed = OutlineHash21(Step) * 100.0;
    float2 p = UV * float2(_ScreenParams.x / _ScreenParams.y, 1) * WobbleScale + seed;
    float2 wobble = float2(OutlineValueNoise(p), OutlineValueNoise(p + 17.31)) * 2 - 1;
    float thickness = lerp(1.0, 0.35 + 1.3 * OutlineValueNoise(p * 0.6 + 41.7), ThicknessJitter);

    float2 nearestUV;
    float nearestDepth;
    float2 depthUV = UV + wobble * (WobbleAmount * px) * texel;
    float depthEdge = OutlineDepthEdge(depthUV, texel * max(Width * px * thickness, 0.5), filter, nearestUV,
                                       nearestDepth);
    depthEdge = smoothstep(DepthThreshold, DepthThreshold * 1.5 + 1e-4, depthEdge);

    float normalEdge = OutlineNormalEdge(UV, texel * max(Width * px, 0.5), filter);
    normalEdge = smoothstep(NormalThreshold, NormalThreshold * 1.5 + 1e-4, normalEdge) * NormalLineStrength;

    float grain = lerp(1.0, 0.45 + 0.55 * OutlineValueNoise(UV * _ScreenParams.xy / (2.5 * px) + seed * 3.1), Grain);
    float fade = 1 - smoothstep(FadeStart, max(FadeEnd, FadeStart + 1e-3), nearestDepth);
    float edge = saturate(max(depthEdge, normalEdge)) * grain * fade;

    float3 scene = SAMPLE_TEXTURE2D(MainTex.tex, MainTex.samplerstate, UV).rgb;
    float3 front = SAMPLE_TEXTURE2D(MainTex.tex, MainTex.samplerstate, depthEdge > normalEdge ? nearestUV : UV).rgb;
    float3 ink = lerp(front * LineTint, LineColor, InkMix);

    OUT = lerp(scene, ink, edge);

    if (DebugView > 2.5)
        OUT = 1 - saturate(LinearEyeDepth(CenterRawDepth, _ZBufferParams) / 20.0);
    else if (DebugView > 1.5)
        GetNormal_float(UV, OUT);
    else if (DebugView > 0.5)
        OUT = lerp(float3(1, 1, 1), ink, edge);
}
