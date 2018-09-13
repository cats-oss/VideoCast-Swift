//
//  InvertColorsVideoFilter.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/13.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit

open class InvertColorsVideoFilter: BasicVideoFilter {
    internal static let isRegistered = registerFilter()

    #if targetEnvironment(simulator)
    open override var pixelKernel: String? {
        return kernel(language: .GL_ES2_3, target: filterLanguage, kernelstr: """
               precision mediump float;
               varying vec2      vCoord;
               uniform sampler2D uTex0;
               void main(void) {
                   vec4 color = texture2D(uTex0, vCoord);
                   gl_FragColor = vec4(1.0 - color.r, 1.0 - color.g, 1.0 - color.b, color.a);
               }
""")
    }
    #else
    open override var fragmentFunc: String {
        return "invertColors_fragment"
    }
    #endif

    open override var name: String {
        return "jp.co.cyberagent.VideoCast.filters.invertColors"
    }

    #if !targetEnvironment(simulator)
    open override var piplineDescripter: String? {
        return "invertColorsPiplineState"
    }
    #endif

    private static func registerFilter() -> Bool {
        FilterFactory.register(
            name: "jp.co.cyberagent.VideoCast.filters.invertColors",
            instantiation: { return InvertColorsVideoFilter() }
        )
        return true
    }
}
