//
//  MetalUtil.swift
//  VideoCast
//
//  Created by 松澤 友弘 on 2018/08/24.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import Metal
import GLKit

struct Uniforms {
    var modelViewProjectionMatrix: GLKMatrix4
}

let s_vertexData = [
    Vertex(position: [-1, -1, 0, 1], texcoords: [0, 0]),   // 0
    Vertex(position: [ 1, -1, 0, 1], texcoords: [1, 0]),   // 1
    Vertex(position: [-1, 1, 0, 1], texcoords: [0, 1]),   // 2

    Vertex(position: [ 1, -1, 0, 1], texcoords: [1, 0]),   // 1
    Vertex(position: [ 1, 1, 0, 1], texcoords: [1, 1]),   // 3
    Vertex(position: [-1, 1, 0, 1], texcoords: [0, 1])    // 2
]
