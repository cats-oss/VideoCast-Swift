//
//  shaders.metal
//  VideoCast
//
//  Created by 松澤 友弘 on 2018/08/24.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

#include <metal_stdlib>
using namespace metal;

#include "../ShaderDefinitions.h"

struct VertexOut {
    float4 position [[ position ]];
    float2 texcoords;
};

struct Uniforms {
    float4x4 modelViewProjectionMatrix;
};

vertex VertexOut preview_vertex(
                              const device Vertex* vertices [[ buffer(0) ]],
                              constant Uniforms& uniforms [[ buffer(1) ]],
                              uint vid [[ vertex_id ]]
                              ) {
    VertexOut outVertex;
    Vertex inVertex = vertices[vid];
    outVertex.position = uniforms.modelViewProjectionMatrix * float4(inVertex.position);
    outVertex.texcoords = inVertex.texcoords;
    return outVertex;
}

fragment float4 preview_fragment(
                               VertexOut vertexIn [[ stage_in ]],
                               constant Uniforms & uniforms [[ buffer(0) ]],
                               texture2d<float, access::sample> colorTexture [[ texture(0) ]],
                               sampler colorSampler [[ sampler(0) ]]
                               ) {
    float3 color = colorTexture.sample(colorSampler, vertexIn.texcoords).rgb;
    return float4(color, 1);
}
