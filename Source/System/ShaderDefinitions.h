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

#endif /* ShaderDefinitions_h */
