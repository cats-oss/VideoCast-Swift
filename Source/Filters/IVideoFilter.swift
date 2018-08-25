//
//  IVideoFilter.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import Metal
import GLKit

public protocol IVideoFilter: IFilter {
    var vertexFunc: String { get }
    var fragmentFunc: String { get }
    var piplineDescripter: String? { get }

    var renderPipelineState: MTLRenderPipelineState? { get set }

    var matrix: GLKMatrix4 { get set }
    var dimensions: CGSize { get set }

    func render(_ renderEncoder: MTLRenderCommandEncoder)
}
