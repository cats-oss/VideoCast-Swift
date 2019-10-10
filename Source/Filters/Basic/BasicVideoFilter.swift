//
//  BasicVideoFilter.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/13.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit
import Metal

open class BasicVideoFilter: IVideoFilter {
    open var renderPipelineState: MTLRenderPipelineState?

    open class var vertexFunc: String {
        return "basic_vertex"
    }

    open class var fragmentFunc: String {
        return "bgra_fragment"
    }

    open var matrix = GLKMatrix4Identity

    open var dimensions = CGSize.zero

    open var initialized = false

    open var piplineDescripter: String? {
        return .init(describing: type(of: self))
    }

    private var bound = false

    public init() {

    }

    open func initialize() {
        let frameworkBundleLibrary: MTLLibrary?
        let mainBundleLibrary: MTLLibrary?
        guard let frameworkLibraryFile =
            Bundle(for: BasicVideoFilter.self).path(forResource: "default", ofType: "metallib") else {
            fatalError(">> ERROR: Couldnt find a default shader library path")
        }
        do {
            try frameworkBundleLibrary = DeviceManager.device.makeLibrary(filepath: frameworkLibraryFile)
            try mainBundleLibrary =
                Bundle.main.path(forResource: "default", ofType: "metallib").map(DeviceManager.device.makeLibrary)
        } catch {
            fatalError(">> ERROR: Couldnt create a default shader library")
        }
        // read the vertex and fragment shader functions from the library

        let vertexProgram: MTLFunction?
        let vertexFunctionName = type(of: self).vertexFunc
        if mainBundleLibrary?.functionNames.contains(vertexFunctionName) ?? false {
            vertexProgram = mainBundleLibrary?.makeFunction(name: vertexFunctionName)
        } else {
            vertexProgram = frameworkBundleLibrary?.makeFunction(name: vertexFunctionName)
        }

        let fragmentProgram: MTLFunction?
        let fragmentFunctionName = type(of: self).fragmentFunc
        if mainBundleLibrary?.functionNames.contains(fragmentFunctionName) ?? false {
            fragmentProgram = mainBundleLibrary?.makeFunction(name: fragmentFunctionName)
        } else {
            fragmentProgram = frameworkBundleLibrary?.makeFunction(name: fragmentFunctionName)
        }

        //  create a pipeline state descriptor
        let renderPipelineDescriptor = MTLRenderPipelineDescriptor()
        if let piplineDescripter = piplineDescripter {
            renderPipelineDescriptor.label = piplineDescripter
        }

        // set pixel formats that match the framebuffer we are drawing into
        renderPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        // set the vertex and fragment programs
        renderPipelineDescriptor.vertexFunction = vertexProgram
        renderPipelineDescriptor.fragmentFunction = fragmentProgram

        do {
            // generate the pipeline state
            renderPipelineState = try DeviceManager.device.makeRenderPipelineState(descriptor: renderPipelineDescriptor)
        } catch {
            fatalError("failed to generate the pipeline state \(error)")
        }
        initialized = true
    }

    open func bind() {
        if !bound {
            if !initialized {
                initialize()
            }
        }
    }

    open func render(_ renderEncoder: MTLRenderCommandEncoder) {
        guard let renderPipelineState = renderPipelineState else { return }
        // set the pipeline state object which contains its precompiled shaders
        renderEncoder.setRenderPipelineState(renderPipelineState)

        // set the model view project matrix data
        if #available(iOS 8.3, *) {
            renderEncoder.setVertexBytes(&matrix, length: MemoryLayout<GLKMatrix4>.size, index: 1)
        } else {
            let buffer = DeviceManager.device.makeBuffer(bytes: &matrix,
                                                      length: MemoryLayout<GLKMatrix4>.size,
                                                      options: [])
            renderEncoder.setVertexBuffer(buffer, offset: 0, index: 1)
        }
    }

    open func unbind() {
        bound = false
    }
}
