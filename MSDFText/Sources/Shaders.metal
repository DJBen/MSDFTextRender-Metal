#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// Indices must match Swift side
enum BufferIndex {
    BufferIndexMeshPositions = 0,
    BufferIndexMeshGenerics  = 1,
    BufferIndexUniforms      = 2
};

enum VertexAttribute {
    VertexAttributePosition  = 0,
    VertexAttributeTexcoord  = 1,
};

enum TextureIndex {
    TextureIndexColor = 0,
};

typedef struct {
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 modelViewMatrix;
    float4 textColor;
    float2 unitRange;
    float4 strokeColor;
    uint2 renderOptions;   // x: mode (0=fill,1=hollow)
    float2 strokeParams;   // x: width px, y: feather px
} Uniforms;

typedef struct {
    float3 position [[attribute(VertexAttributePosition)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
} Vertex;

typedef struct {
    float4 position [[position]];
    float2 texCoord;
} Varyings;

vertex Varyings msdfVertexShader(Vertex in                 [[stage_in]],
                             constant Uniforms & uni   [[buffer(BufferIndexUniforms)]])
{
    Varyings out;
    float4 pos = float4(in.position, 1.0);
    out.position = uni.projectionMatrix * uni.modelViewMatrix * pos;
    out.texCoord = in.texCoord;
    return out;
}

fragment float4 msdfFragmentShader(Varyings in               [[stage_in]],
                               constant Uniforms & uni   [[buffer(BufferIndexUniforms)]],
                               texture2d<float> atlas     [[texture(TextureIndexColor)]])
{
    constexpr sampler colorSampler(address::clamp_to_edge, filter::bicubic);

    float3 sample = atlas.sample(colorSampler, in.texCoord).rgb;
    float msdf = max(min(sample.r, sample.g), min(max(sample.r, sample.g), sample.b));
    float2 screenTexSize = 1.0f / fwidth(in.texCoord);
    float screenPxRange = max(0.5f * dot(uni.unitRange, screenTexSize), 1.0f);
    float screenPxDistance = screenPxRange * (msdf - 0.5f);

    uint mode = uni.renderOptions.x;
    if (mode == 0) {
        float alphaFill = clamp(screenPxDistance + 0.5f, 0.0f, 1.0f);
        float4 color = uni.textColor;
        color.a *= alphaFill;
        return color;
    } else {
        // Outline mode
        float strokeWidth = max(uni.strokeParams.x, 0.0f);
        float feather = max(uni.strokeParams.y, 0.0f);
        float halfW = 0.5f * strokeWidth;
        float ad = fabs(screenPxDistance);
        float alphaStroke;
        if (feather > 0.0f) {
            alphaStroke = clamp((halfW + feather - ad) / feather, 0.0f, 1.0f);
        } else {
            alphaStroke = ad <= halfW ? 1.0f : 0.0f;
        }
        float4 color = uni.strokeColor;
        color.a *= alphaStroke;
        return color;
    }
}
