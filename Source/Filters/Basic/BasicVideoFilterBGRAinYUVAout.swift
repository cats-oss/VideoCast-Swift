//
//  BasicVideoFilterBGRAinYUVAout.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/13.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit

open class BasicVideoFilterBGRAinYUVAout: BasicVideoFilter {
    internal static let isRegistered = registerFilter()

    open override var fragmentFunc: String {
        return "bgra2yuva_fragment"
    }

    open override var name: String {
        return "jp.co.cyberagent.VideoCast.filters.bgra2yuva"
    }

    open override var piplineDescripter: String? {
        return "bgra2yuvaPiplineState"
    }

    private static func registerFilter() -> Bool {
        FilterFactory.register(
            name: "jp.co.cyberagent.VideoCast.filters.bgra2yuva",
            instantiation: { return BasicVideoFilterBGRAinYUVAout() }
        )
        return true
    }
}
