//
//  BeautySkinFilter.swift
//  VideoCast iOS
//
//  Created by 堀田 有哉 on 2019/04/18.
//  Copyright © 2019 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit

open class BeautySkinFilter: BasicVideoFilter {
    open override class var fragmentFunc: String {
        return "beauty_skin"
    }
    
    #if targetEnvironment(simulator) || arch(arm)
    // Does not support simulator or arch(arm)
    open override var pixelKernel: String? {
        return nil
    }
    #endif
}
