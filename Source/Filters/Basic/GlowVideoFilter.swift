//
//  GlowVideoFilter.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/13.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit

open class GlowVideoFilter: BasicVideoFilter {
    internal static let isRegistered = registerFilter()

    #if targetEnvironment(simulator) || arch(arm)
    open override var pixelKernel: String? {
        return kernel(language: .GL_ES2_3, target: filterLanguage, kernelstr: """
precision mediump float;
varying vec2      vCoord;
uniform sampler2D uTex0;
const float step_w = 0.0015625;
const float step_h = 0.0027778;
void main(void) {
    vec3 t1 = texture2D(uTex0, vec2(vCoord.x - step_w, vCoord.y - step_h)).bgr;
    vec3 t2 = texture2D(uTex0, vec2(vCoord.x, vCoord.y - step_h)).bgr;
    vec3 t3 = texture2D(uTex0, vec2(vCoord.x + step_w, vCoord.y - step_h)).bgr;
    vec3 t4 = texture2D(uTex0, vec2(vCoord.x - step_w, vCoord.y)).bgr;
    vec3 t5 = texture2D(uTex0, vCoord).bgr;
    vec3 t6 = texture2D(uTex0, vec2(vCoord.x + step_w, vCoord.y)).bgr;
    vec3 t7 = texture2D(uTex0, vec2(vCoord.x - step_w, vCoord.y + step_h)).bgr;
    vec3 t8 = texture2D(uTex0, vec2(vCoord.x, vCoord.y + step_h)).bgr;
    vec3 t9 = texture2D(uTex0, vec2(vCoord.x + step_w, vCoord.y + step_h)).bgr;
    vec3 xx= t1 + 2.0*t2 + t3 - t7 - 2.0*t8 - t9;
    vec3 yy = t1 - t3 + 2.0*t4 - 2.0*t6 + t7 - t9;
    vec3 rr = sqrt(xx * xx + yy * yy);
    gl_FragColor.a = 1.0;
    gl_FragColor.rgb = rr * 2.0 * t5;
}
""")
    }
    #else
    open override var fragmentFunc: String {
        return "glow_fragment"
    }
    #endif

    open override var name: String {
        return "jp.co.cyberagent.VideoCast.filters.glow"
    }

    #if !targetEnvironment(simulator) && !arch(arm)
    open override var piplineDescripter: String? {
        return "glowPiplineState"
    }
    #endif

    private static func registerFilter() -> Bool {
        FilterFactory.register(
            name: "jp.co.cyberagent.VideoCast.filters.glow",
            instantiation: { return GlowVideoFilter() }
        )
        return true
    }
}
