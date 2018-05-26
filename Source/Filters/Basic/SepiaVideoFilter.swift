//
//  SepiaVideoFilter.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/13.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit

open class SepiaVideoFilter: BasicVideoFilter {
    internal static let isRegistered = registerFilter()
    
    open override var pixelKernel: String? {
        return kernel(language: .GL_ES2_3, target: filterLanguage, kernelstr: """
precision mediump float;
varying vec2      vCoord;
uniform sampler2D uTex0;
const vec3 SEPIA = vec3(1.2, 1.0, 0.8);
void main(void) {
   vec4 color = texture2D(uTex0, vCoord);
   float gray = dot(color.rgb, vec3(0.3, 0.59, 0.11));
   vec3 sepiaColor = vec3(gray) * SEPIA;
   color.rgb = mix(color.rgb, sepiaColor, 0.75);
   gl_FragColor = color;
}
""")
    }
    
    open override var name: String {
        return "jp.co.cyberagent.VideoCast.filters.sepia"
    }
    
    private static func registerFilter() -> Bool {
        FilterFactory.register(name: "jp.co.cyberagent.VideoCast.filters.sepia", instantiation: { return SepiaVideoFilter() })
        return true
    }
}
