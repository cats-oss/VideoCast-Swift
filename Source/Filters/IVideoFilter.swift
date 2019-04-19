//
//  IVideoFilter.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit
#if !targetEnvironment(simulator) && !arch(arm)
import Metal
#endif

#if targetEnvironment(simulator) || arch(arm)
func kernel(language: FilterLanguage, target: FilterLanguage, kernelstr: String) -> String? {
    return language == target ? kernelstr : nil
}

public enum FilterLanguage {
    case GL_ES2_3
    case GL_2
    case GL_3
}
#endif

public protocol IVideoFilter: IFilter {
    var matrix: GLKMatrix4 { get set }
    var dimensions: CGSize { get set }
    static var vertexFunc: String { get }
    static var fragmentFunc: String { get }
    
    #if targetEnvironment(simulator) || arch(arm)
    var vertexKernel: String? { get }
    var pixelKernel: String? { get }

    var filterLanguage: FilterLanguage { get set }
    var program: GLuint { get set }
    #else
    var renderPipelineState: MTLRenderPipelineState? { get }
    func render(_ renderEncoder: MTLRenderCommandEncoder)
    func encode(device: MTLDevice, encoder: MTLRenderCommandEncoder)
    #endif
}
