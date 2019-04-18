#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[ position ]];
    float2 texcoords;
};

struct Uniforms {
    float4x4 modelViewProjectionMatrix;
};

fragment float4 invertColors(
                             VertexOut vertexIn [[ stage_in ]],
                             constant Uniforms & uniforms [[ buffer(0) ]],
                             texture2d<float, access::sample> colorTexture [[ texture(0) ]],
                             sampler colorSampler [[ sampler(0) ]]
                             ) {
    float4 color = colorTexture.sample(colorSampler, vertexIn.texcoords);
    return float4(1.0 - color.r, 1.0 - color.g, 1.0 - color.b, color.a);
}
