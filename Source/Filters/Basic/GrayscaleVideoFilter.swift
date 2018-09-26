//
//  GrayscaleVideoFilter.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/13.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit

open class GrayscaleVideoFilter: BasicVideoFilter {
    internal static let isRegistered = registerFilter()

    #if targetEnvironment(simulator) || arch(arm)
    open override var pixelKernel: String? {
        return kernel(language: .GL_ES2_3, target: filterLanguage, kernelstr: """
precision mediump float;
varying vec2      vCoord;
uniform sampler2D uTex0;
void main(void) {
   vec4 color = texture2D(uTex0, vCoord);
   float gray = dot(color.rgb, vec3(0.3, 0.59, 0.11));
   gl_FragColor = vec4(gray, gray, gray, color.a);
}
""")
    }
    #else
    open override var fragmentFunc: String {
        return "grayscale_fragment"
    }
    #endif

    open override var name: String {
        return "jp.co.cyberagent.VideoCast.filters.grayscale"
    }

    #if !targetEnvironment(simulator) && !arch(arm)
    open override var piplineDescripter: String? {
        return "grayscalePiplineState"
    }
    #endif

    private static func registerFilter() -> Bool {
        FilterFactory.register(
            name: "jp.co.cyberagent.VideoCast.filters.grayscale",
            instantiation: { return GrayscaleVideoFilter() }
        )
        return true
    }
}
