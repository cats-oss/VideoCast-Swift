//
//  VCPreviewView.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/05.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import UIKit
import GLKit
#if !targetEnvironment(simulator) && !arch(arm)
import Metal
#endif

// swiftlint:disable file_length
open class VCPreviewView: UIView {
    private var currentBuffer = 1
    private var paused = Atomic(false)

    private var current = [CVPixelBuffer?](repeating: nil, count: 2)
    #if targetEnvironment(simulator) || arch(arm)
    private var renderBuffer: GLuint = 0
    private var shaderProgram: GLuint = 0
    private var vbo: GLuint = 0
    private var fbo: GLuint = 0
    private var vao: GLuint = 0
    private var matrixPos: GLuint = 0

    private var texture = [CVOpenGLESTexture?](repeating: nil, count: 2)
    private var cache: CVOpenGLESTextureCache?

    private var context: EAGLContext?
    private var glLayer: CAEAGLLayer!
    #else
    private var vertexBuffer: MTLBuffer?
    private var renderPipelineState: MTLRenderPipelineState?
    private var colorSamplerState: MTLSamplerState?

    private var texture = [CVMetalTexture?](repeating: nil, count: 2)
    private var cache: CVMetalTextureCache?

    private let device = DeviceManager.device
    private let commandQueue = DeviceManager.commandQueue
    private weak var metalLayer: CAMetalLayer!
    private var _currentDrawable: CAMetalDrawable?
    private var _renderPassDescriptor: MTLRenderPassDescriptor?
    #endif

    private var layerSizeDidUpdate = false

    public var flipX = false

    final public override class var layerClass: AnyClass {
        #if targetEnvironment(simulator) || arch(arm)
        return CAEAGLLayer.self
        #else
        return CAMetalLayer.self
        #endif
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        configure()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        #if targetEnvironment(simulator) || arch(arm)
        if shaderProgram != 0 {
            glDeleteProgram(shaderProgram)
        }
        if vbo != 0 {
            glDeleteBuffers(1, &vbo)
        }
        if fbo != 0 {
            glDeleteFramebuffers(1, &fbo)
        }
        if renderBuffer != 0 {
            glDeleteRenderbuffers(1, &renderBuffer)
        }
        #endif

        if let cache = cache {
            #if targetEnvironment(simulator) || arch(arm)
            CVOpenGLESTextureCacheFlush(cache, 0)
            #else
            CVMetalTextureCacheFlush(cache, 0)
            #endif
        }
    }

    open override var contentScaleFactor: CGFloat {
        get {
            return super.contentScaleFactor
        }
        set {
            super.contentScaleFactor = newValue

            layerSizeDidUpdate = true
        }
    }

    open override func layoutSubviews() {
        super.layoutSubviews()

        backgroundColor = .black
        layerSizeDidUpdate = true
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    open func drawFrame(_ pixelBuffer: CVPixelBuffer) {
        guard !paused.value else { return }

        autoreleasepool {
            var updateTexture = false

            if pixelBuffer != current[currentBuffer] {
                // not found, swap buffers.
                currentBuffer = (currentBuffer + 1) % 2
            }

            if pixelBuffer != current[currentBuffer] {
                // Still not found, update the texture for this buffer.
                current[currentBuffer] = pixelBuffer
                updateTexture = true
            }

            DispatchQueue.main.async { [weak self, currentBuffer] in
                guard let strongSelf = self else { return }

                #if !targetEnvironment(simulator) && !arch(arm)
                guard let vertexBuffer = strongSelf.vertexBuffer,
                    let renderPipelineState = strongSelf.renderPipelineState,
                    let colorSamplerState = strongSelf.colorSamplerState else { return }
                #endif

                guard let buffer = strongSelf.current[currentBuffer], let cache = strongSelf.cache else {
                    fatalError("unexpected return")
                }

                if strongSelf.layerSizeDidUpdate {
                    // set the metal layer to the drawable size in case orientation or size changes
                    var drawableSize = strongSelf.bounds.size
                    drawableSize.width *= strongSelf.contentScaleFactor
                    drawableSize.height *= strongSelf.contentScaleFactor
                    #if targetEnvironment(simulator) || arch(arm)
                    strongSelf.generateGLESBuffers(drawableSize)
                    #else
                    strongSelf.metalLayer.drawableSize = drawableSize
                    #endif

                    strongSelf.layerSizeDidUpdate = false
                }

                #if targetEnvironment(simulator) || arch(arm)
                let current = EAGLContext.current()
                EAGLContext.setCurrent(strongSelf.context)
                #endif

                if updateTexture {
                    // create a new texture
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    #if targetEnvironment(simulator) || arch(arm)
                    CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                 cache,
                                                                 buffer,
                                                                 nil,
                                                                 GLenum(GL_TEXTURE_2D),
                                                                 GL_RGBA,
                                                                 GLsizei(CVPixelBufferGetWidth(buffer)),
                                                                 GLsizei(CVPixelBufferGetHeight(buffer)),
                                                                 GLenum(GL_BGRA),
                                                                 GLenum(GL_UNSIGNED_BYTE),
                                                                 0,
                                                                 &strongSelf.texture[currentBuffer]
                    )
                    #else
                    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                              cache,
                                                              buffer,
                                                              nil,
                                                              MTLPixelFormat.bgra8Unorm,
                                                              CVPixelBufferGetWidth(buffer),
                                                              CVPixelBufferGetHeight(buffer),
                                                              0,
                                                              &strongSelf.texture[currentBuffer]
                    )
                    #endif

                    if let texture = strongSelf.texture[currentBuffer] {
                        #if targetEnvironment(simulator) || arch(arm)
                        glBindTexture(GLenum(GL_TEXTURE_2D),
                                      CVOpenGLESTextureGetName(texture))
                        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GLfloat(GL_LINEAR))
                        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GLfloat(GL_LINEAR))
                        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE))
                        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE))
                        #endif

                        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                    } else {
                        fatalError("could not create texture")
                    }
                }

                defer {
                    #if targetEnvironment(simulator) || arch(arm)
                    CVOpenGLESTextureCacheFlush(cache, 0)
                    #else
                    CVMetalTextureCacheFlush(cache, 0)
                    #endif
                }

                guard let texture = strongSelf.texture[currentBuffer] else {
                    fatalError("texture doesn't exist in currentBuffer")
                }

                // draw
                #if targetEnvironment(simulator) || arch(arm)
                glBindFramebuffer(GLenum(GL_FRAMEBUFFER), strongSelf.fbo)
                glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
                glBindTexture(GLenum(GL_TEXTURE_2D), CVOpenGLESTextureGetName(texture))
                #else
                guard let metalTexture = CVMetalTextureGetTexture(texture) else { return }
                #endif

                let width = Float(CVPixelBufferGetWidth(buffer))
                let height = Float(CVPixelBufferGetHeight(buffer))

                var wfac = Float(strongSelf.bounds.size.width) / width
                var hfac = Float(strongSelf.bounds.size.height) / height

                let aspectFit = true

                let mult = (aspectFit ? (wfac < hfac) : (wfac > hfac)) ? wfac : hfac

                wfac = width * mult / Float(strongSelf.bounds.width)
                hfac = height * mult / Float(strongSelf.bounds.height)

                var matrix = GLKMatrix4MakeScale((strongSelf.flipX ? -1 : 1) * wfac, -1 * hfac, 1)

                #if targetEnvironment(simulator) || arch(arm)
                glUniformMatrix4fv(GLint(strongSelf.matrixPos), 1, GLboolean(GL_FALSE), matrix.array)
                glDrawArrays(GLenum(GL_TRIANGLES), 0, 6)
                glErrors()
                glBindRenderbuffer(GLenum(GL_RENDERBUFFER), strongSelf.renderBuffer)

                if !strongSelf.paused.value {
                    strongSelf.context?.presentRenderbuffer(Int(GL_RENDERBUFFER))
                }

                EAGLContext.setCurrent(current)
                #else
                // create a new command buffer for each renderpass to the current drawable
                guard let commandBuffer = strongSelf.commandQueue.makeCommandBuffer() else { return }

                if let renderPassDescriptor = strongSelf.renderPassDescriptor {
                    // create a render command encoder so we can render into something
                    guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(
                        descriptor: renderPassDescriptor) else { return }

                    // setup for GPU debugger
                    renderEncoder.pushDebugGroup("preview")

                    // set the pipeline state object which contains its precompiled shaders
                    renderEncoder.setRenderPipelineState(renderPipelineState)

                    // set the static vertex buffers
                    renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

                    // set the model view project matrix data
                    if #available(iOS 8.3, *) {
                        renderEncoder.setVertexBytes(&matrix, length: MemoryLayout<GLKMatrix4>.size, index: 1)
                    } else {
                        let buffer = strongSelf.device.makeBuffer(bytes: &matrix,
                                                       length: MemoryLayout<GLKMatrix4>.size,
                                                       options: [])
                        renderEncoder.setVertexBuffer(buffer, offset: 0, index: 1)
                    }

                    // fragment texture for environment
                    renderEncoder.setFragmentTexture(metalTexture, index: 0)

                    renderEncoder.setFragmentSamplerState(colorSamplerState, index: 0)

                    // tell the render context we want to draw our primitives
                    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: s_vertexData.count)

                    renderEncoder.popDebugGroup()

                    renderEncoder.endEncoding()

                    if !strongSelf.paused.value {
                        if let currentDrawable = strongSelf.currentDrawable {
                            // schedule a present once the framebuffer is complete
                            commandBuffer.present(currentDrawable)
                            strongSelf._currentDrawable = nil
                        }
                    }
                }

                // finalize rendering here. this will push the command buffer to the GPU
                commandBuffer.commit()
                #endif
            }
        }

    }
}

private extension VCPreviewView {
    func configure() {
        #if targetEnvironment(simulator) || arch(arm)
        guard let glLayer = layer as? CAEAGLLayer else {
            fatalError("layer is not CAGLESLayer")
        }
        self.glLayer = glLayer

        Logger.debug("Creating context")
        context = EAGLContext(api: .openGLES2)
        #else
        guard let metalLayer = layer as? CAMetalLayer else {
            fatalError("layer is not CAMetalLayer")
        }
        self.metalLayer = metalLayer
        #endif

        contentScaleFactor = UIScreen.main.scale

        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        DispatchQueue.main.async { [weak self] in
            #if targetEnvironment(simulator) || arch(arm)
            self?.setupGLES()
            #else
            self?.setupMetal()
            #endif
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc func applicationDidEnterBackground() {
        paused.value = true
    }

    @objc func applicationWillEnterForeground() {
        paused.value = false
    }

    #if targetEnvironment(simulator) || arch(arm)
    func setupGLES() {
        guard let context = context else {
            return assert(false, "unexpected return")
        }

        let current = EAGLContext.current()
        EAGLContext.setCurrent(context)
        CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, context, nil, &cache)

        glGenVertexArraysOES(1, &vao)
        glBindVertexArrayOES(vao)

        glGenBuffers(1, &vbo)
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), vbo)
        glBufferData(GLenum(GL_ARRAY_BUFFER), MemoryLayout<GLfloat>.size*s_vbo.count, s_vbo, GLenum(GL_STATIC_DRAW))

        shaderProgram = buildProgram(vertex: s_vs_mat, fragment: s_fs)
        glUseProgram(shaderProgram)

        let attrpos = glGetAttribLocation(shaderProgram, "aPos")
        let attrtex = glGetAttribLocation(shaderProgram, "aCoord")
        let unitex = glGetUniformLocation(shaderProgram, "uTex0")

        matrixPos = GLuint(glGetUniformLocation(shaderProgram, "uMat"))

        glUniform1i(unitex, 0)

        glEnableVertexAttribArray(GLuint(attrpos))
        glEnableVertexAttribArray(GLuint(attrtex))
        glVertexAttribPointer(GLuint(attrpos), 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE),
                              GLsizei(MemoryLayout<Float>.size * 4), BUFFER_OFFSET(0))
        glVertexAttribPointer(GLuint(attrtex), 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE),
                              GLsizei(MemoryLayout<Float>.size * 4), BUFFER_OFFSET(8))

        EAGLContext.setCurrent(current)
    }

    func generateGLESBuffers(_ size: CGSize) {
        let current = EAGLContext.current()
        EAGLContext.setCurrent(context)

        if renderBuffer != 0 {
            glDeleteRenderbuffers(1, &renderBuffer)
        }

        if fbo != 0 {
            glDeleteFramebuffers(1, &fbo)
        }

        glGenRenderbuffers(1, &renderBuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), renderBuffer)

        context?.renderbufferStorage(Int(GL_RENDERBUFFER), from: glLayer)

        glErrors()

        glGenFramebuffers(1, &fbo)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)

        var width: GLint = 0
        var height: GLint = 0

        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &width)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &height)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                                  GLenum(GL_RENDERBUFFER), renderBuffer)

        glErrors()

        glClearColor(0, 0, 0, 1)

        glViewport(0, 0, GLsizei(size.width), GLsizei(size.height))

        EAGLContext.setCurrent(current)
    }
    #else
    func setupMetal() {
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm

        metalLayer.framebufferOnly = true

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)

        let defaultLibrary: MTLLibrary!
        guard let libraryFile = Bundle(for: type(of: self)).path(forResource: "default", ofType: "metallib") else {
                fatalError(">> ERROR: Couldnt find a default shader library path")
        }
        do {
            try defaultLibrary = device.makeLibrary(filepath: libraryFile)
        } catch {
            fatalError(">> ERROR: Couldnt create a default shader library")
        }

        // read the vertex and fragment shader functions from the library
        let vertexProgram = defaultLibrary.makeFunction(name: "basic_vertex")
        let fragmentprogram = defaultLibrary.makeFunction(name: "preview_fragment")

        //  create a pipeline state descriptor
        let renderPipelineDescriptor = MTLRenderPipelineDescriptor()
        renderPipelineDescriptor.label = "PreviewPiplineState"

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

        // setup the vertex, texCoord buffers
        vertexBuffer = device.makeBuffer(bytes: s_vertexData,
                                         length: MemoryLayout<Vertex>.size * s_vertexData.count,
                                         options: [])
        vertexBuffer?.label = "PreviewVertexBuffer"

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        colorSamplerState = device.makeSamplerState(descriptor: samplerDescriptor)
    }

    func setupRenderPassDescriptorForTexture(_ texture: MTLTexture) {
        // create lazily
        if _renderPassDescriptor == nil {
            _renderPassDescriptor = MTLRenderPassDescriptor()
        }

        guard let renderPassDescriptor = _renderPassDescriptor else { return }
        // create a color attachment every frame since we have to recreate the texture every frame
        renderPassDescriptor.colorAttachments[0].texture = texture

        // make sure to clear every frame for best performance
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        // store only attachments that will be presented to the screen
        renderPassDescriptor.colorAttachments[0].storeAction = .store
    }

    var renderPassDescriptor: MTLRenderPassDescriptor? {
        if let drawable = currentDrawable {
            setupRenderPassDescriptorForTexture(drawable.texture)
        } else {
            // this can happen when the app is backgrounded, in this case just return nil and let the renderer handle it
            _renderPassDescriptor = nil
        }

        return _renderPassDescriptor
    }

    var currentDrawable: CAMetalDrawable? {
        if _currentDrawable == nil {
            _currentDrawable = metalLayer.nextDrawable()
        }
        return _currentDrawable
    }
    #endif
}
