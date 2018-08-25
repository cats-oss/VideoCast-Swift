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

    open override var fragmentFunc: String {
        return "invertColors_fragment"
    }

    open override var name: String {
        return "jp.co.cyberagent.VideoCast.filters.invertColors"
    }

    open override var piplineDescripter: String? {
        return "invertColorsPiplineState"
    }

    private static func registerFilter() -> Bool {
        FilterFactory.register(
            name: "jp.co.cyberagent.VideoCast.filters.invertColors",
            instantiation: { return InvertColorsVideoFilter() }
        )
        return true
    }
}
