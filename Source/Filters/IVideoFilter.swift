//
//  IVideoFilter.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit
import Metal

public protocol IVideoFilter: IFilter {
    var matrix: GLKMatrix4 { get set }
    var dimensions: CGSize { get set }
    static var vertexFunc: String { get }
    static var fragmentFunc: String { get }

    var renderPipelineState: MTLRenderPipelineState? { get }
    func render(_ renderEncoder: MTLRenderCommandEncoder)
}
