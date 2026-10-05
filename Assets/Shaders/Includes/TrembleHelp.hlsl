// Hash without Sine (David Hoskins, MIT): 1 in, 3 out, each in [0, 1).
float3 TrembleHash31(float p)
{
    float3 p3 = frac(p * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.xxy + p3.yzz) * p3.zyx);
}

// Hash without Sine: 3 in, 1 out.
float TrembleHash13(float3 p3)
{
    p3 = frac(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return frac((p3.x + p3.y) * p3.z);
}

// Smooth 3D value noise in [0, 1].
float TrembleValueNoise(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);
    f = f * f * (3 - 2 * f);

    float n000 = TrembleHash13(i);
    float n100 = TrembleHash13(i + float3(1, 0, 0));
    float n010 = TrembleHash13(i + float3(0, 1, 0));
    float n110 = TrembleHash13(i + float3(1, 1, 0));
    float n001 = TrembleHash13(i + float3(0, 0, 1));
    float n101 = TrembleHash13(i + float3(1, 0, 1));
    float n011 = TrembleHash13(i + float3(0, 1, 1));
    float n111 = TrembleHash13(i + float3(1, 1, 1));

    return lerp(lerp(lerp(n000, n100, f.x), lerp(n010, n110, f.x), f.y),
                lerp(lerp(n001, n101, f.x), lerp(n011, n111, f.x), f.y), f.z);
}

// Hero-object "nervous tremble", after the shake marks around Grace in the concept art.
// Step is floor(Time * Tremble Rate), so the offsets only change a few times a second and the motion reads as
// hand-drawn animation rather than smooth movement.
//  - Shake: every step the whole object hops to a new random offset, mostly sideways.
//  - Boil: every step each vertex is pushed along its normal by freshly seeded noise, so the silhouette wobbles like
//    line art being redrawn. The seed is hashed from Step to keep the noise input small as time grows.
// All values are in object space.
void Tremble_float(float3 Position, float3 Normal, float Step, float ShakeAmount, float BoilAmount, float BoilScale,
                   out float3 OUT)
{
    float3 shake = (TrembleHash31(Step) * 2 - 1) * float3(1, 0.4, 1) * ShakeAmount;

    float3 seed = TrembleHash31(Step + 17.0) * 100.0;
    float boil = TrembleValueNoise(Position * BoilScale + seed) * 2 - 1;

    OUT = Position + shake + Normal * (boil * BoilAmount);
}
