//
//  functions.h
//  iOS Example
//
//  Created by 堀田 有哉 on 2019/04/19.
//  Copyright © 2019 CyberAgent, Inc. All rights reserved.
//

#ifndef functions_h
#define functions_h

#include <simd/simd.h>

float gauss(float x, float sigma);
vector_float3 rgb2hsv(vector_float3 col);
vector_float3 hsv2rgb(vector_float3 col);

constant float step_w = 0.0015625;
constant float step_h = 0.0027778;

#endif /* functions_h */
