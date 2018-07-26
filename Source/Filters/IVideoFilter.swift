//
//  IVideoFilter.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit

func kernel(language: FilterLanguage, target: FilterLanguage, kernelstr: String) -> String? {
    return language == target ? kernelstr : nil
}

public enum FilterLanguage {
    case GL_ES2_3
    case GL_2
    case GL_3
}

public protocol IVideoFilter: IFilter {
    var vertexKernel: String? { get }
    var pixelKernel: String? { get }

    var filterLanguage: FilterLanguage { get set }
    var program: GLuint { get set }

    var matrix: GLKMatrix4 { get set }
    var dimensions: CGSize { get set }
}
