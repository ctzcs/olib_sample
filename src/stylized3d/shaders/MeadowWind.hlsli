// One shared deformation for color and sun-depth passes. Static instance data
// never changes: a travelling gust is evaluated from world position and time.
// Tangent.w is a mesh tag: -1 grass, -2 crowns, -3 flowers, +1 rigid geometry.
float3 meadow_wind(float3 local, float3 position, float3 root, float tag, float time)
{
    if (tag >= 0) return position;
    float2 direction = normalize(float2(0.88, 0.48));
    float travelling_time = time - dot(root.xz, direction) / 4.5;
    float cycle = floor(travelling_time / 14.0);
    float start = 3.0 + frac(sin(cycle * 17.17 + 3.1) * 437.23) * 2.5;
    float age = travelling_time - cycle * 14.0 - start;
    float gust = smoothstep(0, 0.8, age) * (1 - smoothstep(2.0, 3.8, age));
    float strength = 0.75 + 0.25 * sin(cycle * 9.2 + 0.8);
    gust *= strength;
    float rebound = sin(max(age - 2.5, 0) * 5) * exp(-max(age - 2.5, 0) * 2.5) * smoothstep(2.5, 2.8, age);
    float phase = dot(root.xz, float2(1.3, 0.7));
    float breeze = sin(time * 1.5 + phase) * 0.025;
    float flutter = sin(time * 5.2 + phase * 2.0) * gust * 0.025;
    float weight = saturate(local.y);
    float amplitude = 0.24;
    if (tag < -2.5) { amplitude = 0.17; weight = saturate(local.y / 0.8); }
    else if (tag < -1.5) { amplitude = 0.14; weight = saturate((local.y + 1) * 0.5); }
    weight *= weight;
    position.xz += direction * (breeze + amplitude * (gust - rebound * 0.2) + flutter) * weight;
    position.y -= gust * amplitude * weight * 0.18;
    return position;
}
