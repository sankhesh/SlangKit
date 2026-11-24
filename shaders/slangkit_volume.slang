// Copyright 2026 Sankhesh Jhaveri
// SPDX-License-Identifier: BSD-3-Clause

module slangkit_volume;

public static const int kVolumeInterfaceVersion = 1;

public static const uint kBlendComposite        = 0u;
public static const uint kBlendMaximumIntensity = 1u;
public static const uint kBlendMinimumIntensity = 2u;
public static const uint kBlendAverageIntensity = 3u;
public static const uint kBlendAdditive         = 4u;
public static const uint kBlendIsosurface       = 5u;

public static const float kFarAway           = 3.4e38f;
public static const float kVisibleOpacity    = 3.f / 255.f;
public static const uint  kMaxBoundCells     = 1024u;
public static const float kDetailSensitivity = 4.f;

public struct VolumeGrid
{
    public float3 dims     = float3(1.f);
    public float3 spacing  = float3(1.f);
    public bool   cellData = false;

    public float3 extent() { return cellData ? dims : max(dims - 1.f, float3(1.f)); }

    public float3 shift() { return cellData ? float3(0.5f) : float3(0.f); }

    public float3 sampleStep() { return 1.f / extent(); }

    public float3 voxelOf(float3 texCoord)
    {
        float3 clamped = clamp(texCoord, float3(0.f), float3(1.f));
        if (cellData)
            return clamp(clamped * dims - 0.5f, float3(0.f), max(dims - 1.f, float3(0.f)));
        return clamped * max(dims - 1.f, float3(1.f));
    }
};

public struct VolumeRay
{
    public float3 origin    = float3(0.f);
    public float3 direction = float3(0.f, 0.f, 1.f);
    public float  tNear     = 0.f;
    public float  tFar      = 0.f;
};

public struct VolumeMarch
{
    public uint  blendMode         = kBlendComposite;
    public uint  component         = 0u;
    public float baseStep          = 1.f;
    public float unitDistance      = 1.f;
    public float maxOpacity        = 1.f;
    public uint  maxSteps          = 1024u;
    public float jitter            = 0.f;
    public bool  adaptive          = false;
    public float minStepFactor     = 1.f;
    public float maxStepFactor     = 1.f;
    public bool  skipEmpty         = false;
    public float emptyThreshold    = 0.f;
    public bool  normalFromOpacity = false;
    public float averageMinimum    = -kFarAway;
    public float averageMaximum    = kFarAway;
    public float opaqueAlpha       = 0.99f;
};

public struct VolumeResult
{
    public float4 color           = float4(0.f);
    public bool   covered         = false;
    public bool   hit             = false;
    public float  tHit            = 0.f;
    public float3 texCoordHit     = float3(0.f);
    public bool   visible         = false;
    public float  tVisible        = 0.f;
    public float3 texCoordVisible = float3(0.f);
};

public interface IVolumeSampler
{
    associatedtype Cursor;

    VolumeGrid grid();

    float blockSize() { return 0.f; }

    Cursor locate(float3 texCoord);

    bool present(Cursor c) { return true; }

    float4 sample(Cursor c);

    float4 sampleNear(Cursor c, float3 texCoord) { return sample(locate(texCoord)); }

    float3 gradient(Cursor c, float3 texCoord, uint component)
    {
        return centralDifferences(this, c, texCoord, component);
    }
};

public interface ITransferFunction
{
    float normalize(uint component, float value);

    float opacity(uint component, float normalized);

    float3 color(uint component, float normalized);

    bool hasGradientOpacity() { return false; }

    float gradientOpacity(uint component, float magnitude) { return 1.f; }
};

public interface IMacrocells
{
    float cellSize();

    float2 cell(float3 voxel);

    float2 range(float3 voxel);
};

public struct NoMacrocells : IMacrocells
{
    public float cellSize() { return 0.f; }
    public float2 cell(float3 voxel) { return float2(1.f); }
    public float2 range(float3 voxel) { return float2(1.f, 0.f); }
};

public interface IVolumeHooks
{
    bool hides() { return false; }

    bool hidden(float3 texCoord) { return false; }

    bool shades() { return false; }

    float3 shade(float3 color, float3 texCoord, float3 gradient) { return color; }

    uint isoValueCount() { return 0u; }

    float isoValue(uint i) { return 0.f; }
};

public struct DefaultVolumeHooks : IVolumeHooks
{
};

public interface IOpacityExtremes
{
    float2 extremes(uint function, uint level, uint entry);
};

public float3 unproject(float4x4 inverseViewProjection, float2 ndc, float depth)
{
    float4 p = mul(inverseViewProjection, float4(ndc, depth, 1.f));
    return p.xyz / p.w;
}

public float2 intersectUnitBox(float3 origin, float3 direction)
{
    float3 inverse = 1.f / direction;
    float3 t0      = (float3(0.f) - origin) * inverse;
    float3 t1      = (float3(1.f) - origin) * inverse;
    float3 tMin    = min(t0, t1);
    float3 tMax    = max(t0, t1);
    return float2(max(max(tMin.x, tMin.y), tMin.z), min(min(tMax.x, tMax.y), tMax.z));
}

public float2 clipToPlane(float4 plane, float3 origin, float3 direction, float2 range)
{
    float denominator = dot(plane.xyz, direction);
    float numerator   = dot(plane.xyz, origin) + plane.w;
    if (abs(denominator) < 1.0e-9f)
        return numerator < 0.f ? float2(1.f, 0.f) : range;
    float hit = -numerator / denominator;
    if (denominator > 0.f)
        range.x = max(range.x, hit);
    else
        range.y = min(range.y, hit);
    return range;
}

public VolumeRay volumeRay(float4x4 worldToTexture, float3 origin, float3 direction, float tLimit)
{
    VolumeRay r = VolumeRay();
    r.origin    = mul(worldToTexture, float4(origin, 1.f)).xyz;
    r.direction = mul(worldToTexture, float4(direction, 0.f)).xyz;
    float2 span = intersectUnitBox(r.origin, r.direction);
    r.tNear     = max(span.x, 0.f);
    r.tFar      = min(span.y, tLimit);
    return r;
}

public float jitterHash(float2 p)
{
    float3 p3 = frac(float3(p.x, p.y, p.x) * 0.1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return frac((p3.x + p3.y) * p3.z);
}

public float correctOpacity(float opacity, float step, float unitDistance, float maxOpacity)
{
    float o = min(opacity, maxOpacity);
    return o >= 1.f ? 1.f : 1.f - pow(1.f - o, step / unitDistance);
}

public float gradientMagnitude(float3 gradient, float3 spacing)
{
    float average = (spacing.x + spacing.y + spacing.z) / 3.f;
    return length(gradient / (spacing * 2.f / average));
}

public float3 gradientNormal(float4x4 worldToTexture, float3 gradient, float3 extent)
{
    return normalize(mul(transpose(worldToTexture), float4(gradient * extent, 0.f)).xyz);
}

public void compositeFrontToBack(inout float3 color, inout float alpha, float3 sampleColor,
                                 float opacity)
{
    float remaining = 1.f - alpha;
    color += remaining * opacity * sampleColor;
    alpha += remaining * opacity;
}

public float blockExit(VolumeGrid g, float3 origin, float3 direction, float t, float size)
{
    float3 extent = g.extent();
    float3 shift  = g.shift();
    float3 voxel  = (origin + t * direction) * extent - shift;
    float3 block  = floor(voxel / size);
    float3 lower  = (block * size + shift) / extent;
    float3 upper  = ((block + 1.f) * size + shift) / extent;
    float3 inverse = 1.f / direction;
    float3 tMax   = max((lower - origin) * inverse, (upper - origin) * inverse);
    return max(min(min(tMax.x, tMax.y), tMax.z) - t, 0.f);
}

public float advancePast(float t, float skipTo, float pace, float coarsest)
{
    if (pace < kFarAway) {
        pace = max(pace, coarsest);
        return t + pace * max(1.f, ceil((skipTo - t) / pace));
    }
    return max(skipTo, t + max(1.0e-6f, abs(t) * 1.0e-5f));
}

public float adaptiveStep(float baseStep, float detail, float minStepFactor, float maxStepFactor)
{
    return baseStep * lerp(maxStepFactor, minStepFactor, detail);
}

public struct VolumeMaterial
{
    public float ambient       = 0.f;
    public float diffuse       = 1.f;
    public float specular      = 0.f;
    public float specularPower = 1.f;
};

public struct VolumeLight
{
    public float3 ambient     = float3(0.f);
    public float  coneAngle   = 180.f;
    public float3 diffuse     = float3(1.f);
    public float  exponent    = 1.f;
    public float3 specular    = float3(1.f);
    public bool   positional  = false;
    public float3 direction   = float3(0.f, 0.f, -1.f);
    public float3 position    = float3(0.f);
    public float3 attenuation = float3(1.f, 0.f, 0.f);
};

public struct LightSums
{
    public float3 ambient  = float3(0.f);
    public float3 diffuse  = float3(0.f);
    public float3 specular = float3(0.f);
};

public float3 shadeHeadlight(VolumeMaterial m, float3 color, float3 normal, float3 view,
                             VolumeLight light, bool twoSided)
{
    float3 toLight   = -light.direction;
    float  nDotL     = dot(normal, toLight);
    float3 reflected = normalize(2.f * nDotL * normal - toLight);
    float  vDotR     = dot(reflected, view);
    if (nDotL < 0.f && twoSided)
        nDotL = -nDotL;
    float3 diffuse  = float3(0.f);
    float3 specular = float3(0.f);
    if (nDotL > 0.f) {
        diffuse  = nDotL * m.diffuse * light.diffuse * color;
        specular = pow(max(vDotR, 0.f), m.specularPower) * m.specular * light.specular;
    }
    return m.ambient * color + diffuse + specular;
}

public void accumulateLight(inout LightSums sums, VolumeLight light, float3 normal, float3 view,
                            float3 world, float specularPower, bool twoSided)
{
    float  attenuation = 1.f;
    float3 away        = light.direction;
    if (light.positional) {
        float3 offset   = world - light.position;
        float  distance = length(offset);
        away = distance > 1.0e-9f ? offset / distance : light.direction;
        attenuation = 1.f / max(light.attenuation.x + light.attenuation.y * distance +
                                    light.attenuation.z * distance * distance,
                                1.0e-9f);
        if (light.coneAngle <= 90.f) {
            float coneDot = dot(away, light.direction);
            attenuation = coneDot >= cos(radians(light.coneAngle))
                ? attenuation * pow(coneDot, light.exponent)
                : 0.f;
        }
    }

    float nDotL = dot(normal, away);
    if (nDotL < 0.f && twoSided)
        nDotL = -nDotL;
    if (nDotL > 0.f) {
        sums.diffuse += max(0.f, attenuation * nDotL) * light.diffuse;
        float3 reflected = normalize(2.f * nDotL * normal - away);
        float  rDotV     = dot(-view, reflected);
        if (rDotV < 0.f && twoSided)
            rDotV = -rDotV;
        if (rDotV > 0.f)
            sums.specular += attenuation * pow(rDotV, specularPower) * light.specular;
    }
    sums.ambient += light.ambient;
}

public float3 shadeLights(VolumeMaterial m, float3 color, LightSums sums)
{
    return m.ambient * sums.ambient + m.diffuse * sums.diffuse * color + m.specular * sums.specular;
}

public float3 centralDifferences<S : IVolumeSampler>(S sampler, S.Cursor c, float3 texCoord,
                                                     uint component)
{
    float3 step = sampler.grid().sampleStep();
    float3 dx   = float3(step.x, 0.f, 0.f);
    float3 dy   = float3(0.f, step.y, 0.f);
    float3 dz   = float3(0.f, 0.f, step.z);
    return float3(
        sampler.sampleNear(c, texCoord + dx)[component] - sampler.sampleNear(c, texCoord - dx)[component],
        sampler.sampleNear(c, texCoord + dy)[component] - sampler.sampleNear(c, texCoord - dy)[component],
        sampler.sampleNear(c, texCoord + dz)[component] - sampler.sampleNear(c, texCoord - dz)[component]);
}

float opacityNear<S : IVolumeSampler, T : ITransferFunction>(S sampler, T tf, S.Cursor c,
                                                              float3 texCoord, uint component)
{
    float value = sampler.sampleNear(c, texCoord)[component];
    return tf.opacity(component, tf.normalize(component, value));
}

public float3 opacityGradient<S : IVolumeSampler, T : ITransferFunction>(
    S sampler, T tf, S.Cursor c, float3 texCoord, uint component)
{
    float3 step = sampler.grid().sampleStep();
    float3 dx   = float3(step.x, 0.f, 0.f);
    float3 dy   = float3(0.f, step.y, 0.f);
    float3 dz   = float3(0.f, 0.f, step.z);
    return float3(
        opacityNear(sampler, tf, c, texCoord + dx, component) - opacityNear(sampler, tf, c, texCoord - dx, component),
        opacityNear(sampler, tf, c, texCoord + dy, component) - opacityNear(sampler, tf, c, texCoord - dy, component),
        opacityNear(sampler, tf, c, texCoord + dz, component) - opacityNear(sampler, tf, c, texCoord - dz, component));
}

public float4 classifyAt<S : IVolumeSampler, T : ITransferFunction, H : IVolumeHooks>(
    S sampler, T tf, H hooks, S.Cursor c, float3 texCoord, uint component, float normalized,
    bool normalFromOpacity)
{
    float  value   = clamp(normalized, 0.f, 1.f);
    float  opacity = tf.opacity(component, value);
    float3 color   = tf.color(component, value);
    if (hooks.shades() && opacity > 0.f) {
        float3 gradient = normalFromOpacity ? opacityGradient(sampler, tf, c, texCoord, component)
                                            : sampler.gradient(c, texCoord, component);
        color = hooks.shade(color, texCoord, gradient);
    }
    return float4(color, opacity);
}

public bool cellCanMove<T : ITransferFunction>(T tf, uint component, float2 range, bool maximum,
                                               float value, float bound)
{
    if (range.x > range.y)
        return true;
    if (maximum) {
        float greatest = tf.normalize(component, range.y);
        return greatest > value && greatest >= bound;
    }
    float least = tf.normalize(component, range.x);
    return least < value && least <= bound;
}

public float projectionBound<S : IVolumeSampler, T : ITransferFunction, M : IMacrocells,
                             H : IVolumeHooks>(S sampler, T tf, M cells, H hooks, VolumeRay ray,
                                               uint component, bool maximum, float tFrom,
                                               float tTo, float reach, float start)
{
    float      bound = start;
    VolumeGrid g     = sampler.grid();
    float      size  = cells.cellSize();
    if (size <= 0.f || hooks.hides() || g.cellData)
        return bound;
    float block = sampler.blockSize();
    if (block > 0.f && fmod(block, size) != 0.f)
        return bound;

    float t = tFrom;
    for (uint visited = 0u; visited < kMaxBoundCells && t < tTo; visited++) {
        float exit = min(t + blockExit(g, ray.origin, ray.direction, t, size), tTo);
        if (exit - t >= reach) {
            float3 texCoord = ray.origin + 0.5f * (t + exit) * ray.direction;
            float2 range    = cells.range(g.voxelOf(texCoord));
            float  reached  = tf.normalize(component, maximum ? range.x : range.y);
            if (range.x <= range.y && ((maximum && reached > bound) || (!maximum && reached < bound)) &&
                sampler.present(sampler.locate(texCoord)))
                bound = reached;
        }
        t = exit + max(1.0e-6f, abs(exit) * 1.0e-5f);
    }
    return bound;
}

float isoBoundary<H : IVolumeHooks>(H hooks, int index)
{
    if (index <= 0)
        return -kFarAway;
    if (index > int(hooks.isoValueCount()))
        return kFarAway;
    return hooks.isoValue(uint(index - 1));
}

int isoIntervalOf<H : IVolumeHooks>(H hooks, float value)
{
    int index = 0;
    for (uint i = 0u; i < hooks.isoValueCount(); i++) {
        if (value >= hooks.isoValue(i))
            index = int(i) + 1;
    }
    return index;
}

public VolumeResult marchVolume<S : IVolumeSampler, T : ITransferFunction, M : IMacrocells,
                                H : IVolumeHooks>(S sampler, T tf, M cells, H hooks, VolumeRay ray,
                                                  VolumeMarch m)
{
    VolumeResult r = VolumeResult();
    if (ray.tNear >= ray.tFar)
        return r;

    VolumeGrid g           = sampler.grid();
    uint       component   = m.component;
    bool       compositing = m.blendMode == kBlendComposite;
    bool       isosurface  = m.blendMode == kBlendIsosurface;
    bool       maximum     = m.blendMode == kBlendMaximumIntensity;
    bool       minimum     = m.blendMode == kBlendMinimumIntensity;
    float      cellSize    = cells.cellSize();
    bool       useCells    = cellSize > 0.f;
    bool       adaptive    = m.adaptive && useCells;
    bool       skipEmpty   = compositing && m.skipEmpty && useCells;
    bool       skipSettled = !adaptive && m.skipEmpty && useCells && (maximum || minimum);
    bool       shades      = hooks.shades();
    bool       gradientOpacity = tf.hasGradientOpacity();
    float      coarsest    = (ray.tFar - ray.tNear) / float(max(m.maxSteps, 2u) - 1u);

    float3 color       = float3(0.f);
    float  alpha       = 0.f;
    float  value       = minimum ? kFarAway : -kFarAway;
    float  count       = 0.f;
    int    isoInterval = 0;
    bool   isoSeen     = false;

    float bound = value;
    if (skipSettled)
        bound = projectionBound(sampler, tf, cells, hooks, ray, component, maximum, ray.tNear,
                                ray.tFar, 2.f * max(coarsest, m.baseStep), bound);

    float t     = ray.tNear + m.jitter;
    uint  steps = 0u;
    while (t < ray.tFar && steps < m.maxSteps) {
        steps++;
        float3   texCoord = ray.origin + t * ray.direction;
        float3   voxel    = g.voxelOf(texCoord);
        S.Cursor c        = sampler.locate(texCoord);

        float step   = m.baseStep;
        float skipTo = kFarAway;
        float pace   = kFarAway;
        if (!sampler.present(c)) {
            skipTo = t + blockExit(g, ray.origin, ray.direction, t, sampler.blockSize());
            if (!adaptive)
                pace = m.baseStep;
        } else if (adaptive || skipEmpty) {
            float2 cell = cells.cell(voxel);
            if (skipEmpty && cell.x <= m.emptyThreshold) {
                skipTo = t + blockExit(g, ray.origin, ray.direction, t, cellSize);
                if (!adaptive)
                    pace = m.baseStep;
            } else if (adaptive) {
                step = adaptiveStep(m.baseStep, cell.y, m.minStepFactor, m.maxStepFactor);
            }
        } else if (skipSettled && !cellCanMove(tf, component, cells.range(voxel), maximum, value, bound)) {
            skipTo = t + blockExit(g, ray.origin, ray.direction, t, cellSize);
            pace   = m.baseStep;
        }

        if (skipTo < kFarAway) {
            t = advancePast(t, skipTo, pace, coarsest);
            continue;
        }
        step = max(step, coarsest);

        if (hooks.hidden(texCoord)) {
            t += step;
            continue;
        }

        float4 values     = sampler.sample(c);
        float  scalar     = values[component];
        float  normalized = tf.normalize(component, scalar);

        if (isosurface) {
            if (!isoSeen) {
                isoInterval = isoIntervalOf(hooks, scalar);
                isoSeen     = true;
            } else {
                float crossing = 0.f;
                bool  crossed  = false;
                int   interval = clamp(isoInterval, 0, int(hooks.isoValueCount()));
                if (scalar < isoBoundary(hooks, interval)) {
                    crossing = isoBoundary(hooks, interval);
                    interval -= 1;
                    crossed = true;
                }
                if (scalar > isoBoundary(hooks, interval + 1)) {
                    crossing = isoBoundary(hooks, interval + 1);
                    interval += 1;
                    crossed = true;
                }
                isoInterval = interval;
                if (crossed) {
                    float4 s = classifyAt(sampler, tf, hooks, c, texCoord, component,
                                          tf.normalize(component, crossing), m.normalFromOpacity);
                    compositeFrontToBack(color, alpha, s.rgb, s.a);
                }
            }
            t += step;
            continue;
        }

        if (!compositing) {
            if (maximum) {
                value = max(value, normalized);
            } else if (minimum) {
                value = min(value, normalized);
            } else if (m.blendMode != kBlendAverageIntensity ||
                       (scalar >= m.averageMinimum && scalar <= m.averageMaximum)) {
                if (count == 0.f)
                    value = 0.f;
                value += tf.opacity(component, normalized) * normalized;
                count += 1.f;
            }
            t += step;
            continue;
        }

        float  opacity  = tf.opacity(component, normalized);
        float3 gradient = float3(0.f);
        if (opacity > 0.f) {
            if (shades || gradientOpacity)
                gradient = sampler.gradient(c, texCoord, component);
            opacity = correctOpacity(opacity, step, m.unitDistance, m.maxOpacity);
            if (gradientOpacity)
                opacity *= tf.gradientOpacity(component, gradientMagnitude(gradient, g.spacing));
            opacity = clamp(opacity, 0.f, 1.f);
        }
        if (opacity > 0.f) {
            float3 sampleColor = tf.color(component, normalized);
            if (shades) {
                float3 normal = m.normalFromOpacity
                    ? opacityGradient(sampler, tf, c, texCoord, component)
                    : gradient;
                sampleColor = hooks.shade(sampleColor, texCoord, normal);
            }
            if (!r.hit) {
                r.hit         = true;
                r.tHit        = t;
                r.texCoordHit = texCoord;
            }
            compositeFrontToBack(color, alpha, sampleColor, opacity);
            if (!r.visible && alpha > kVisibleOpacity) {
                r.visible         = true;
                r.tVisible        = t;
                r.texCoordVisible = texCoord;
            }
            if (alpha >= m.opaqueAlpha)
                break;
        }
        t += step;
    }

    if (maximum || minimum) {
        if (value <= -kFarAway || value >= kFarAway)
            return r;
        float v   = clamp(value, 0.f, 1.f);
        float a   = tf.opacity(component, v);
        r.color   = float4(tf.color(component, v) * a, a);
        r.covered = true;
        return r;
    }
    if (!compositing && !isosurface) {
        if (count == 0.f)
            return r;
        if (m.blendMode == kBlendAverageIntensity)
            value /= count;
        r.color   = float4(float3(clamp(value, 0.f, 1.f)), 1.f);
        r.covered = true;
        return r;
    }
    r.color   = float4(min(color, float3(1.f)), min(alpha, 1.f));
    r.covered = alpha > 0.f || r.hit;
    return r;
}

public float2 classifyCell<E : IOpacityExtremes>(E table, uint function, uint tableSize,
                                                 float2 range, float rangeMin, float rangeScale)
{
    float low       = clamp((range.x - rangeMin) * rangeScale, 0.f, 1.f);
    float high      = clamp((range.y - rangeMin) * rangeScale, 0.f, 1.f);
    uint  lastEntry = tableSize - 1u;
    uint  first     = min(uint(floor(max(low * float(tableSize) - 0.5f, 0.f))), lastEntry);
    uint  last      = clamp(uint(ceil(max(high * float(tableSize) - 0.5f, 0.f))), first, lastEntry);
    uint  level     = firstbithigh(last - first + 1u);
    float2 head     = table.extremes(function, level, first);
    float2 tail     = table.extremes(function, level, last + 1u - (1u << level));
    float  opacityLow  = min(head.x, tail.x);
    float  opacityHigh = max(head.y, tail.y);
    float  detail = clamp(kDetailSensitivity * max(high - low, opacityHigh - opacityLow), 0.f, 1.f);
    return float2(opacityHigh, detail);
}
