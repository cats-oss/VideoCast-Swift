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
    open override class var fragmentFunc: String {
        return "glow_fragment"
    }

}
