//
//  functions.metal
//  VideoCast iOS
//
//  Created by 堀田 有哉 on 2019/04/18.
//  Copyright © 2019 CyberAgent, Inc. All rights reserved.
//

#include <metal_stdlib>
using namespace metal;

float gauss(float x, float sigma) {
    return 1 / sqrt(2 * M_PI_H * sigma * sigma) * exp(-x * x / (2 * sigma * sigma));
};

float3 rgb2hsv(float3 col) {
    float r = col.r;
    float g = col.g;
    float b = col.b;
    
    float max_value = r > g ? r : g;
    max_value = max_value > b ? max_value : b;
    float min_value = r < g ? r : g;
    min_value = min_value < b ? min_value : b;
    
    float h = max_value - min_value;
    float s = max_value - min_value;
    float v = max_value;
    
    if (h > 0.0h) {
        if (max_value == r) {
            h = (g - b) / h;
            if (h < 0.0h) {
                h += 6.0;
            }
        } else if (max_value == g) {
            h = 2.0 * (b - r) / h;
        } else {
            h = 4.0f + (r - g) / h;
        }
    }
    
    h /= 6.0h;
    if (max_value != 0.0h)
        s /= max_value;
    
    return float3(h, s, v);
}

float3 hsv2rgb(float3 col) {
    float h = col.x;
    float s = col.y;
    float v = col.z;
    
    float r = v;
    float g = v;
    float b = v;
    if (s == 0) { return float3(r, g, b); }
    
    h *= 6.0h;
    int i = int(h);
    float f = h - float(i);
    
    switch (i) {
        case 0:
            g *= 1 - s * (1 - f);
            b *= 1 - s;
            break;
        case 1:
            r *= 1 - s * f;
            b *= 1 - s;
            break;
        case 2:
            r *= 1 - s;
            b *= 1 - s * (1 - f);
            break;
        case 3:
            r *= 1 - s;
            g *= 1 - s * f;
            break;
        case 4:
            r *= 1 - s * (1 - f);
            g *= 1 - s;
            break;
        case 5:
            g *= 1 - s;
            b *= 1 - s * f;
            break;
    }
    
    return float3(r, g, b);
}
