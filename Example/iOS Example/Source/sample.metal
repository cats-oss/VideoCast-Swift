#include <metal_stdlib>
using namespace metal;

#include "functions.h"

struct VertexOut {
    float4 position [[ position ]];
    float2 texcoords;
};

fragment float4 invertColors(
                             VertexOut vertexIn [[ stage_in ]],
                             texture2d<float, access::sample> colorTexture [[ texture(0) ]],
                             sampler colorSampler [[ sampler(0) ]]
                             ) {
    float4 color = colorTexture.sample(colorSampler, vertexIn.texcoords);
    return float4(1.0 - color.r, 1.0 - color.g, 1.0 - color.b, color.a);
}

struct BeautySkinParameters {
    int kernel_size; // Odd number is predered for centering target pixel
    float sigma;
    float luminance_sigma;
    float alpha_factor;
    float beta_factor;
};

float kernel_function(float center_luminance,
                      float surrounding_luminance,
                      float sigma,
                      float luminance_sigma,
                      int2 normalized_position) {
    float luminance_gauss = gauss(center_luminance - surrounding_luminance, luminance_sigma);
    float space_gauss = gauss(normalized_position.x, sigma) * gauss(normalized_position.y, sigma);
    
    return space_gauss * luminance_gauss;
}

/// Based on this reference: https://www.csie.ntu.edu.tw/~fuh/personal/FaceBeautificationandColorEnhancement.A2-1-0040.pdf
fragment float4 beauty_skin(
                            VertexOut vertexIn [[ stage_in ]],
                            texture2d<float, access::sample> colorTexture [[ texture(0) ]],
                            constant BeautySkinParameters & params [[ buffer(0) ]],
                            sampler colorSampler [[ sampler(0) ]]
                            ) {
    const int radius = params.kernel_size / 2;
    
    const float3 central_rgb = colorTexture.sample(colorSampler, vertexIn.texcoords).rgb;
    const float3 central_hsv = rgb2hsv(central_rgb);
    
    // Bilateral
    float kernel_weight = 0;
    const float central_luminance = central_hsv.z;
    for (int j = 0; j <= params.kernel_size - 1; j++) {
        for (int i = 0; i <= params.kernel_size - 1; i++) {
            const float2 texture_index(vertexIn.texcoords.x + step_w * (i - radius), vertexIn.texcoords.y + step_h * (j - radius));
            const float surrounding_luminance = rgb2hsv(colorTexture.sample(colorSampler, texture_index).rgb).z;
            const int2 normalized_position(i - radius, j - radius);
            
            kernel_weight += kernel_function(central_luminance,
                                             surrounding_luminance,
                                             params.sigma,
                                             params.luminance_sigma,
                                             normalized_position);
        }
    }
    
    float bilateral_luminance = 0.0f;
    for (int j = 0; j <= params.kernel_size - 1; j++) {
        for (int i = 0; i <= params.kernel_size - 1; i++) {
            const float2 texture_index(vertexIn.texcoords.x + step_w * (i - radius), vertexIn.texcoords.y + step_h * (j - radius));
            const float4 texture = colorTexture.sample(colorSampler, texture_index);
            const float surrounding_luminance = rgb2hsv(texture.rgb).z;
            const int2 normalized_position(i - radius, j - radius);
            
            const float factor = kernel_function(central_luminance,
                                                 surrounding_luminance,
                                                 params.sigma,
                                                 params.luminance_sigma,
                                                 normalized_position) / kernel_weight;
            bilateral_luminance += factor * surrounding_luminance;
        }
    }
    
    // Sobel
    const float3x3 sobel_horizontal_kernel = float3x3(float3(-1, -2, -1),
                                                      float3(0,  0,  0),
                                                      float3(1, 2, 1));
    const float3x3 sobel_vertical_kernel = float3x3(float3(1, 0, -1),
                                                    float3(2, 0, -2),
                                                    float3(1, 0, -1));
    
    float3 result_horizontal(0, 0, 0);
    float3 result_vertical(0, 0, 0);
    for (int j = 0; j <= 2; j++) {
        for (int i = 0; i <= 2; i++) {
            float2 texture_index(vertexIn.texcoords.x + step_w * (i - 1), vertexIn.texcoords.y + step_h * (j - 1));
            float3 texture = colorTexture.sample(colorSampler, texture_index).rgb;
            result_horizontal += sobel_horizontal_kernel[i][j] * texture;
            result_vertical += sobel_vertical_kernel[i][j] * texture;
        }
    }
    
    const float gray_horizontal = rgb2hsv(result_horizontal.rgb).z;
    const float gray_vertical = rgb2hsv(result_vertical.rgb).z;
    
    float magnitude = abs(1 - length(float2(gray_horizontal, gray_vertical)));
    if (magnitude > 0.8) {
        magnitude = 1;
    } else {
        magnitude = 0;
    }
    
    // Combining smooting and edge
    float smooth = bilateral_luminance;
    if (magnitude < 0.5) {
        float smooth_luminance = bilateral_luminance + (central_luminance - bilateral_luminance) * params.alpha_factor;
        smooth = smooth_luminance;
    }
    
    float3 final_color = hsv2rgb(float3(central_hsv.x, central_hsv.y, smooth));
    
    // Wever-Fechner Law
    final_color = log(1.0 + (params.beta_factor - 1) * final_color) / log(params.beta_factor);
    
    return float4(final_color, 1);
}
