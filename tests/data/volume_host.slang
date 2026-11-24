import slangkit_volume;

struct Params
{
    float4x4 inverseViewProjection;
    float4x4 worldToTexture;
    float4   dims;
    float4   spacing;
    float4   cellDims;
    float4   viewport;
    float    baseStep;
    float    unitDistance;
    uint     blendMode;
    uint     maxSteps;
    float    valueMin;
    float    valueScale;
    float    cellSize;
    float    emptyThreshold;
};

[vk::binding(0, 0)] ConstantBuffer<Params>   params;
[vk::binding(1, 0)] Texture3D<float4>        volume;
[vk::binding(2, 0)] SamplerState             linearClamp;
[vk::binding(3, 0)] Texture2D<float4>        transfer;
[vk::binding(4, 0)] StructuredBuffer<float2> cells;
[vk::binding(5, 0)] StructuredBuffer<float2> ranges;
[vk::binding(6, 0)] StructuredBuffer<float2> extremeTable;
[vk::binding(7, 0)] RWStructuredBuffer<float2> classified;

struct WholeVolume : IVolumeSampler
{
    typealias Cursor = float3;
    VolumeGrid grid()
    {
        VolumeGrid g = VolumeGrid();
        g.dims       = params.dims.xyz;
        g.spacing    = params.spacing.xyz;
        return g;
    }
    float3 locate(float3 texCoord) { return texCoord; }
    float4 sample(float3 c)
    {
        float3 voxel = grid().voxelOf(c);
        return volume.SampleLevel(linearClamp, (voxel + 0.5f) / params.dims.xyz, 0.f);
    }
};

struct TableTransfer : ITransferFunction
{
    float normalize(uint component, float value)
    {
        return clamp((value - params.valueMin) * params.valueScale, 0.f, 1.f);
    }
    float opacity(uint component, float normalized)
    {
        return transfer.SampleLevel(linearClamp, float2(normalized, 0.5f), 0.f).a;
    }
    float3 color(uint component, float normalized)
    {
        return transfer.SampleLevel(linearClamp, float2(normalized, 0.5f), 0.f).rgb;
    }
};

struct BufferCells : IMacrocells
{
    float cellSize() { return params.cellSize; }
    uint index(float3 voxel)
    {
        float3 cell = clamp(floor(voxel / params.cellSize), float3(0.f), params.cellDims.xyz - 1.f);
        return uint(cell.z * params.cellDims.y * params.cellDims.x + cell.y * params.cellDims.x + cell.x);
    }
    float2 cell(float3 voxel) { return cells[index(voxel)]; }
    float2 range(float3 voxel) { return ranges[index(voxel)]; }
};

struct Headlight : IVolumeHooks
{
    override bool shades() { return true; }
    override float3 shade(float3 color, float3 texCoord, float3 gradient)
    {
        VolumeMaterial m = VolumeMaterial();
        m.ambient        = 0.1f;
        float3 normal    = gradientNormal(params.worldToTexture, gradient, params.dims.xyz - 1.f);
        return shadeHeadlight(m, color, normal, float3(0.f, 0.f, 1.f), VolumeLight(), true);
    }
};

struct TableExtremes : IOpacityExtremes
{
    float2 extremes(uint function, uint level, uint entry) { return extremeTable[level * 1024u + entry]; }
};

VolumeRay rayAt(float4 position)
{
    float2 ndc   = float2((position.x - params.viewport.x) / params.viewport.z * 2.f - 1.f,
                          1.f - (position.y - params.viewport.y) / params.viewport.w * 2.f);
    float3 nearPoint = unproject(params.inverseViewProjection, ndc, 0.f);
    float3 farPoint  = unproject(params.inverseViewProjection, ndc, 1.f);
    return volumeRay(params.worldToTexture, nearPoint, normalize(farPoint - nearPoint),
                     distance(nearPoint, farPoint));
}

VolumeMarch marchAt(float4 position)
{
    VolumeMarch m  = VolumeMarch();
    m.blendMode    = params.blendMode;
    m.baseStep     = params.baseStep;
    m.unitDistance = params.unitDistance;
    m.maxSteps     = params.maxSteps;
    m.jitter       = jitterHash(position.xy) * params.baseStep;
    m.skipEmpty    = true;
    m.emptyThreshold = params.emptyThreshold;
    return m;
}

[shader("fragment")]
float4 fragmentMain(float4 position : SV_Position) : SV_Target
{
    VolumeResult r = marchVolume(WholeVolume(), TableTransfer(), BufferCells(), Headlight(),
                                 rayAt(position), marchAt(position));
    if (!r.covered)
        discard;
    return r.color;
}

[shader("fragment")]
float4 fragmentPlain(float4 position : SV_Position) : SV_Target
{
    VolumeResult r = marchVolume(WholeVolume(), TableTransfer(), NoMacrocells(),
                                 DefaultVolumeHooks(), rayAt(position), marchAt(position));
    return r.color;
}

[shader("compute")]
[numthreads(64, 1, 1)]
void classify(uint3 id : SV_DispatchThreadID)
{
    float2 range = ranges[id.x];
    classified[id.x] = range.x > range.y
        ? float2(1.f)
        : classifyCell(TableExtremes(), 0u, 1024u, range, params.valueMin, params.valueScale);
}
