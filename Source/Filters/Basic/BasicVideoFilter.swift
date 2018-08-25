//
//  BasicVideoFilter.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/13.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit

open class BasicVideoFilter: IVideoFilter {
    open var vertexFunc: String {
        return "basic_vertex"
    }

    open var fragmentFunc: String {
        return "bgra_fragment"
    }

    open var renderPipelineState: MTLRenderPipelineState?

    open var renderEncoder: MTLRenderCommandEncoder?

    open var matrix = GLKMatrix4Identity

    open var dimensions = CGSize.zero

    open var initialized = false

    open var name: String {
        return ""
    }

    open var piplineDescripter: String? {
        return nil
    }

    private var device = DeviceManager.device
    private var uMatrix: Int32 = 0
    private var bound = false

    public init() {

    }

    deinit {
    }

    open func initialize() {
        let defaultLibrary: MTLLibrary!
        let bundle = Bundle(for: type(of: self))
        do {
            try defaultLibrary = device.makeDefaultLibrary(bundle: bundle)
        } catch {
            fatalError(">> ERROR: Couldnt create a default shader library")
        }

        // read the vertex and fragment shader functions from the library
        let vertexProgram = defaultLibrary.makeFunction(name: vertexFunc)
        let fragmentprogram = defaultLibrary.makeFunction(name: fragmentFunc)

        //  create a pipeline state descriptor
        let renderPipelineDescriptor = MTLRenderPipelineDescriptor()
        if let piplineDescripter = piplineDescripter {
            renderPipelineDescriptor.label = piplineDescripter
        }

        // set pixel formats that match the framebuffer we are drawing into
        renderPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        // set the vertex and fragment programs
        renderPipelineDescriptor.vertexFunction = vertexProgram
        renderPipelineDescriptor.fragmentFunction = fragmentprogram

        do {
            // generate the pipeline state
            try renderPipelineState = device.makeRenderPipelineState(descriptor: renderPipelineDescriptor)
        } catch {
            fatalError("failed to generate the pipeline state \(error)")
        }
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

        var uniforms = Uniforms(modelViewProjectionMatrix: matrix)

        guard let uniformsBuffer = device.makeBuffer(
            bytes: &uniforms,
            length: MemoryLayout<Uniforms>.size,
            options: []) else { return }

        // set the model view project matrix data
        renderEncoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 1)
    }

    open func unbind() {
        bound = false
    }
}
