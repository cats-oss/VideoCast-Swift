//
//  ShaderDefinitions.h
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/08/24.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

#ifndef ShaderDefinitions_h
#define ShaderDefinitions_h

#include <simd/simd.h>

struct Vertex {
    vector_float4 position;
    vector_float2 texcoords;
};

float gauss(float x, float sigma);
vector_float3 rgb2hsv(vector_float3 col);
vector_float3 hsv2rgb(vector_float3 col);

#endif /* ShaderDefinitions_h */
