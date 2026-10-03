#include <metal_stdlib>
using namespace metal;

struct DustSourceUniforms {
    float4 viewportAndImageOrigin;
    float4 imageAndTextureSize;
};

struct DustParticleUniforms {
    float4 viewportAndImageOrigin;
    float4 imageAndTextureSize;
    float4 progressCellScaleEndScale;
    float4 directionDistanceSpread;
    float4 rotationStaggerGravityFlutter;
    float4 fadeMorphShape;
    float4 frequencyWaveDistanceMin;
    float4 distanceMaxAndPadding;
    uint4 gridAndSeed;
};

struct DustParticleMetadata {
    uint gridIndex;
    float edgeFactor;
};

struct DustSourceVertexOutput {
    float4 position [[position]];
    float2 textureCoordinate;
};

struct DustParticleVertexOutput {
    float4 position [[position]];
    float2 textureCoordinate;
    float2 localUV;
    float localProgress;
    float opacity;
    float shapeRandom;
};

static float dustHash(uint value) {
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    value ^= value >> 16;
    return float(value) / float(0xffffffffu);
}

static float2 dustQuadCorner(uint vertexID) {
    constexpr float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };
    return corners[vertexID];
}

vertex DustSourceVertexOutput dustSourceVertex(
    uint vertexID [[vertex_id]],
    constant DustSourceUniforms &u [[buffer(0)]]
) {
    const float2 viewport = u.viewportAndImageOrigin.xy;
    const float2 imageOrigin = u.viewportAndImageOrigin.zw;
    const float2 imageSize = u.imageAndTextureSize.xy;
    const float2 corner = dustQuadCorner(vertexID);
    const float2 pixel = imageOrigin + corner * imageSize;
    const float2 clip = float2(
        pixel.x / viewport.x * 2.0 - 1.0,
        1.0 - pixel.y / viewport.y * 2.0
    );

    DustSourceVertexOutput output;
    output.position = float4(clip, 0, 1);
    output.textureCoordinate = corner;
    return output;
}

fragment half4 dustSourceFragment(
    DustSourceVertexOutput input [[stage_in]],
    texture2d<half> sourceTexture [[texture(0)]]
) {
    constexpr sampler textureSampler(
        address::clamp_to_edge,
        min_filter::linear,
        mag_filter::linear
    );
    return sourceTexture.sample(textureSampler, input.textureCoordinate);
}

vertex DustParticleVertexOutput dustParticleVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant DustParticleUniforms &u [[buffer(0)]],
    device const DustParticleMetadata *particles [[buffer(1)]]
) {
    const DustParticleMetadata metadata = particles[instanceID];
    const uint gridIndex = metadata.gridIndex;
    const float edgeFactor = clamp(metadata.edgeFactor, 0.0, 1.0);

    const float2 viewport = u.viewportAndImageOrigin.xy;
    const float2 imageOrigin = u.viewportAndImageOrigin.zw;
    const float2 imageSize = u.imageAndTextureSize.xy;
    const float2 textureSize = u.imageAndTextureSize.zw;
    const float progress = u.progressCellScaleEndScale.x;
    const float cellSize = u.progressCellScaleEndScale.y;
    const float textureToDisplay = u.progressCellScaleEndScale.z;
    const float endScale = u.progressCellScaleEndScale.w;

    const uint columns = u.gridAndSeed.x;
    const uint row = gridIndex / columns;
    const uint column = gridIndex % columns;
    const float2 textureStart = float2(column, row) * cellSize;
    const float2 textureEnd = min(textureStart + cellSize, textureSize);
    const float2 textureParticleSize = max(textureEnd - textureStart, float2(0));
    const float2 displayParticleSize = textureParticleSize * textureToDisplay;
    const float2 uvStart = textureStart / textureSize;
    const float2 uvSize = textureParticleSize / textureSize;
    const float2 uvCenter = uvStart + uvSize * 0.5;
    const bool isAssembling = u.distanceMaxAndPadding.w > 0.5;

    const uint seed = u.gridAndSeed.z;
    const float directionRandom = dustHash(gridIndex ^ seed ^ 0x9e3779b9u);
    const float distanceRandom = dustHash(gridIndex ^ seed ^ 0x85ebca6bu);
    const float rotationRandom = dustHash(gridIndex ^ seed ^ 0xc2b2ae35u);
    const float phaseRandom = dustHash(gridIndex ^ seed ^ 0x165667b1u);
    const float microRandom = dustHash(gridIndex ^ seed ^ 0xd3a2646cu);
    const float shapeRandom = dustHash(gridIndex ^ seed ^ 0xfd7046c5u);

    const float2 baseDirection = normalize(u.directionDistanceSpread.xy);
    const float baseAngle = atan2(baseDirection.y, baseDirection.x);
    const float directionAngle = baseAngle
        + (directionRandom - 0.5) * u.directionDistanceSpread.w;
    const float2 direction = float2(cos(directionAngle), sin(directionAngle));
    const float2 perpendicular = float2(-direction.y, direction.x);
    const float distanceMultiplier = mix(
        u.frequencyWaveDistanceMin.w,
        u.distanceMaxAndPadding.x,
        distanceRandom
    );
    const float distance = u.directionDistanceSpread.z * distanceMultiplier;

    const float waveAngle = u.frequencyWaveDistanceMin.z;
    const float2 waveDirection = float2(cos(waveAngle), sin(waveAngle));
    const float waveProjection = clamp(
        dot(uvCenter - 0.5, waveDirection) / 1.41421356 + 0.5,
        0.0,
        1.0
    );
    // waveProjection is the canonical source-axis order: 0 is the trailing
    // edge and 1 is the leading edge. Assembly reverses motion progress, not
    // this source order, so there is no second transition-specific timing axis.
    const float delay = u.rotationStaggerGravityFlutter.y * waveProjection;
    const float localProgress = clamp(
        (progress - delay) / max(1.0 - delay, 0.0001),
        0.0,
        1.0
    );
    const float eased = localProgress * localProgress * (3.0 - 2.0 * localProgress);
    const float windEnvelope = smoothstep(0.05, 0.42, localProgress);

    float2 travel = direction * distance * eased;
    const float driftPhase = phaseRandom * M_PI_F * 2.0 + uvCenter.y * 5.0;
    const float microPhase = microRandom * M_PI_F * 2.0 + uvCenter.x * 7.0;
    const float drift = sin(eased * u.frequencyWaveDistanceMin.x + driftPhase);
    const float micro = sin(eased * u.frequencyWaveDistanceMin.y + microPhase) * 0.24;
    travel += perpendicular
        * (drift * 0.76 + micro)
        * u.rotationStaggerGravityFlutter.w
        * windEnvelope;
    travel.y += u.rotationStaggerGravityFlutter.z * eased * eased;

    const float targetRotation = (rotationRandom * 2.0 - 1.0)
        * u.rotationStaggerGravityFlutter.x;
    const float rotation = targetRotation * eased;
    const float sine = sin(rotation);
    const float cosine = cos(rotation);
    const float2x2 rotationMatrix = float2x2(
        float2(cosine, sine),
        float2(-sine, cosine)
    );

    const float particleScale = mix(1.0, endScale, eased);
    const float2 corner = dustQuadCorner(vertexID);
    const float2 localPosition = rotationMatrix
        * ((corner - 0.5) * displayParticleSize * particleScale);
    const float2 center = imageOrigin + uvCenter * imageSize + travel;
    const float2 pixelPosition = center + localPosition;
    const float2 clip = float2(
        pixelPosition.x / viewport.x * 2.0 - 1.0,
        1.0 - pixelPosition.y / viewport.y * 2.0
    );

    const float fadeStart = min(u.fadeMorphShape.x + edgeFactor * 0.10, 0.92);
    const float fadeT = smoothstep(fadeStart, 1.0, localProgress);

    DustParticleVertexOutput output;
    output.position = float4(clip, 0, 1);
    output.textureCoordinate = uvStart + corner * uvSize;
    output.localUV = corner;
    output.localProgress = localProgress;
    // Assembly keeps the dispersed particles visible while the same
    // deterministic trajectory runs backward into the source.
    output.opacity = isAssembling ? 1.0 : 1.0 - fadeT;
    output.shapeRandom = shapeRandom;
    return output;
}

fragment half4 dustParticleFragment(
    DustParticleVertexOutput input [[stage_in]],
    constant DustParticleUniforms &u [[buffer(0)]],
    texture2d<half> sourceTexture [[texture(0)]]
) {
    constexpr sampler textureSampler(
        address::clamp_to_edge,
        min_filter::linear,
        mag_filter::linear
    );
    half4 color = sourceTexture.sample(textureSampler, input.textureCoordinate);

    const float morph = smoothstep(
        u.fadeMorphShape.y,
        u.fadeMorphShape.z,
        input.localProgress
    );
    const float2 p = input.localUV * 2.0 - 1.0;
    const float angle = atan2(p.y, p.x);
    const float roundness = clamp(u.fadeMorphShape.w, 0.0, 1.0);
    const float wobble = 1.0
        + sin(angle * 5.0 + input.shapeRandom * M_PI_F * 2.0)
        * mix(0.20, 0.055, roundness);
    const float radius = length(p) / wobble;
    const float speck = 1.0 - smoothstep(
        mix(0.48, 0.60, roundness),
        mix(0.92, 1.02, roundness),
        radius
    );
    const float mask = mix(1.0, speck, morph);
    color *= half(input.opacity * mask);

    if (color.a <= half(0.0015)) {
        discard_fragment();
    }
    return color;
}
