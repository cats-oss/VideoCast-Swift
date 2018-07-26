//
//  BasicVideoFilterBGRA.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/24.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit

open class BasicVideoFilterBGRA: BasicVideoFilter {
    internal static let isRegistered = registerFilter()

    open override var name: String {
        return "jp.co.cyberagent.VideoCast.filters.bgra"
    }

    private static func registerFilter() -> Bool {
        FilterFactory.register(name: "jp.co.cyberagent.VideoCast.filters.bgra", instantiation: { return BasicVideoFilterBGRA() })
        return true
    }
}
