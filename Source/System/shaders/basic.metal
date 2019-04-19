//
//  shaders.metal
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/08/24.
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

vertex VertexOut basic_vertex(
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

fragment float4 bgra_fragment(
                                 VertexOut vertexIn [[ stage_in ]],
                                 constant Uniforms & uniforms [[ buffer(0) ]],
                                 texture2d<float, access::sample> colorTexture [[ texture(0) ]],
                                 sampler colorSampler [[ sampler(0) ]]
                                 ) {
    return colorTexture.sample(colorSampler, vertexIn.texcoords);
}

constant float4x4 RGBtoYUV(float4(0.257,  0.439, -0.148, 0.0),
                           float4(0.504, -0.368, -0.291, 0.0),
                           float4(0.098, -0.071,  0.439, 0.0),
                           float4(0.0625, 0.500,  0.500, 1.0)
                           );

fragment float4 bgra2yuva_fragment(
                               VertexOut vertexIn [[ stage_in ]],
                               constant Uniforms & uniforms [[ buffer(0) ]],
                               texture2d<float, access::sample> colorTexture [[ texture(0) ]],
                               sampler colorSampler [[ sampler(0) ]]
                               ) {
    float3 color = (colorTexture.sample(colorSampler, vertexIn.texcoords) * RGBtoYUV).rgb;
    return float4(color, 1);
}

fragment float4 fisheye_fragment(
                               VertexOut vertexIn [[ stage_in ]],
                               constant Uniforms & uniforms [[ buffer(0) ]],
                               texture2d<float, access::sample> colorTexture [[ texture(0) ]],
                               sampler colorSampler [[ sampler(0) ]]
                               ) {
    float2 uv = vertexIn.texcoords - 0.5;
    float z = sqrt(1.0 - uv.x * uv.x - uv.y * uv.y);
    float a = 1.0 / (z * tan(-5.2)); // FOV
    return colorTexture.sample(colorSampler, (uv * a) + 0.5);
}

constant float step_w = 0.0015625;
constant float step_h = 0.0027778;

fragment float4 glow_fragment(
                               VertexOut vertexIn [[ stage_in ]],
                               constant Uniforms & uniforms [[ buffer(0) ]],
                               texture2d<float, access::sample> colorTexture [[ texture(0) ]],
                               sampler colorSampler [[ sampler(0) ]]
                               ) {
    float3 t1 = colorTexture.sample(colorSampler, float2(vertexIn.texcoords.x - step_w, vertexIn.texcoords.y - step_h)).bgr;
    float3 t2 = colorTexture.sample(colorSampler, float2(vertexIn.texcoords.x, vertexIn.texcoords.y - step_h)).bgr;
    float3 t3 = colorTexture.sample(colorSampler, float2(vertexIn.texcoords.x + step_w, vertexIn.texcoords.y - step_h)).bgr;
    float3 t4 = colorTexture.sample(colorSampler, float2(vertexIn.texcoords.x - step_w, vertexIn.texcoords.y)).bgr;
    float3 t5 = colorTexture.sample(colorSampler, vertexIn.texcoords).bgr;
    float3 t6 = colorTexture.sample(colorSampler, float2(vertexIn.texcoords.x + step_w, vertexIn.texcoords.y)).bgr;
    float3 t7 = colorTexture.sample(colorSampler, float2(vertexIn.texcoords.x - step_w, vertexIn.texcoords.y + step_h)).bgr;
    float3 t8 = colorTexture.sample(colorSampler, float2(vertexIn.texcoords.x, vertexIn.texcoords.y + step_h)).bgr;
    float3 t9 = colorTexture.sample(colorSampler, float2(vertexIn.texcoords.x + step_w, vertexIn.texcoords.y + step_h)).bgr;
    
    float3 xx = t1 + 2.0*t2 + t3 - t7 - 2.0*t8 - t9;
    float3 yy = t1 - t3 + 2.0*t4 - 2.0*t6 + t7 - t9;
    
    float3 rr = sqrt(xx * xx + yy * yy);
    
    return float4(rr * 2.0 * t5, 1);
}

fragment float4 grayscale_fragment(
                               VertexOut vertexIn [[ stage_in ]],
                               constant Uniforms & uniforms [[ buffer(0) ]],
                               texture2d<float, access::sample> colorTexture [[ texture(0) ]],
                               sampler colorSampler [[ sampler(0) ]]
                               ) {
    float4 color = colorTexture.sample(colorSampler, vertexIn.texcoords);
    float gray = dot(color.rgb, float3(0.3, 0.59, 0.11));
    return float4(gray, gray, gray, color.a);
}

fragment float4 invertColors_fragment(
                               VertexOut vertexIn [[ stage_in ]],
                               constant Uniforms & uniforms [[ buffer(0) ]],
                               texture2d<float, access::sample> colorTexture [[ texture(0) ]],
                               sampler colorSampler [[ sampler(0) ]]
                               ) {
    float4 color = colorTexture.sample(colorSampler, vertexIn.texcoords);
    return float4(1.0 - color.r, 1.0 - color.g, 1.0 - color.b, color.a);
}

constant float3 SEPIA = float3(1.2, 1.0, 0.8);

fragment float4 sepia_fragment(
                               VertexOut vertexIn [[ stage_in ]],
                               constant Uniforms & uniforms [[ buffer(0) ]],
                               texture2d<float, access::sample> colorTexture [[ texture(0) ]],
                               sampler colorSampler [[ sampler(0) ]]
                               ) {
    float4 color = colorTexture.sample(colorSampler, vertexIn.texcoords);
    float gray = dot(color.rgb, float3(0.3, 0.59, 0.11));
    float3 sepiaColor = float3(gray) * SEPIA;
    color.rgb = mix(color.rgb, sepiaColor, 0.75);
    return color;
}
