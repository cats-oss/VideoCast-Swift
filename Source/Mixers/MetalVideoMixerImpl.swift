//
//  MetalVideoMixerImpl.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/08/23.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import Foundation
import Metal
import GLKit

// swiftlint:disable file_length
extension MetalVideoMixer {
    final class MetalObjCCallback: NSObject {
        weak var mixer: MetalVideoMixer?

        override init() {
            super.init()
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(applicationDidEnterBackground),
                                                   name: .UIApplicationDidEnterBackground, object: nil)
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(applicationWillEnterForeground),
                                                   name: .UIApplicationWillEnterForeground, object: nil)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func applicationDidEnterBackground() {
            mixer?.mixPaused(true)
        }

        @objc func applicationWillEnterForeground() {
            mixer?.mixPaused(false)
        }
    }

    final class SourceBuffer {
        private class BufferContainer {
            var buffer: PixelBuffer
            #if targetEnvironment(simulator)
            var texture: CVOpenGLESTexture?
            #else
            var texture: CVMetalTexture?
            #endif
            var time = Date()

            init(_ buf: PixelBuffer) {
                buffer = buf
            }

            deinit {
                texture = nil
            }
        }

        #if targetEnvironment(simulator)
        var currentTexture: CVOpenGLESTexture?
        #else
        var currentTexture: CVMetalTexture?
        #endif
        var currentBuffer: PixelBuffer?
        var blends = false

        private var pixelBuffers = [CVPixelBuffer: BufferContainer]()

        #if targetEnvironment(simulator)
        // swiftlint:disable:next function_body_length
        func setBuffer(_ pixelBuffer: PixelBuffer, textureCache: CVOpenGLESTextureCache,
                       jobQueue: JobQueue, glContext: EAGLContext) {
            var flush = false
            let now = Date()

            currentBuffer?.state = .available
            pixelBuffer.state = .acquired

            if let bufferContainer = pixelBuffers[pixelBuffer.cvBuffer] {
                currentBuffer = pixelBuffer
                currentTexture = bufferContainer.texture
                bufferContainer.time = now
            } else {
                perfGLAsync(glContext: glContext, jobQueue: jobQueue) { [weak self] in
                    guard let strongSelf = self else { return }

                    pixelBuffer.lock(true)

                    let format = pixelBuffer.pixelFormat
                    let is32bit = format != kCVPixelFormatType_16LE565

                    var texture: CVOpenGLESTexture?
                    let ret = CVOpenGLESTextureCacheCreateTextureFromImage(
                        kCFAllocatorDefault,
                        textureCache,
                        pixelBuffer.cvBuffer,
                        nil,
                        GLenum(GL_TEXTURE_2D),
                        is32bit ? GL_RGBA : GL_RGB,
                        GLsizei(pixelBuffer.width),
                        GLsizei(pixelBuffer.height),
                        GLenum(is32bit ? GL_BGRA : GL_RGB),
                        GLenum(is32bit ? GL_UNSIGNED_BYTE : GL_UNSIGNED_SHORT_5_6_5),
                        0,
                        &texture
                    )

                    pixelBuffer.unlock(true)

                    if ret == noErr, let texture = texture {
                        glBindTexture(GLenum(GL_TEXTURE_2D), CVOpenGLESTextureGetName(texture))
                        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
                        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
                        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
                        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)

                        let bufferContainer = BufferContainer(pixelBuffer)
                        strongSelf.pixelBuffers[pixelBuffer.cvBuffer] = bufferContainer
                        bufferContainer.texture = texture

                        strongSelf.currentBuffer = pixelBuffer
                        strongSelf.currentTexture = texture
                        bufferContainer.time = now
                    } else {
                        Logger.error("Error creating texture! \(ret)")
                    }
                }

                flush = true
            }

            perfGLAsync(glContext: glContext, jobQueue: jobQueue) {
                for (pixelBuffer, bufferContainer) in self.pixelBuffers
                    where bufferContainer.buffer.isTemporary &&
                        bufferContainer.buffer.cvBuffer != self.currentBuffer?.cvBuffer {
                            // Buffer is temporary, release it.
                            self.pixelBuffers[pixelBuffer] = nil
                }

                if flush {
                    CVOpenGLESTextureCacheFlush(textureCache, 0)
                }
            }
        }
        #else
        // swiftlint:disable:next function_body_length
        func setBuffer(_ pixelBuffer: PixelBuffer, textureCache: CVMetalTextureCache, jobQueue: JobQueue) {
            var flush = false
            let now = Date()

            currentBuffer?.state = .available
            pixelBuffer.state = .acquired

            if let bufferContainer = pixelBuffers[pixelBuffer.cvBuffer] {
                currentBuffer = pixelBuffer
                currentTexture = bufferContainer.texture
                bufferContainer.time = now
            } else {
                jobQueue.enqueue {
                    pixelBuffer.lock(true)

                    let pixelFormat = PixcelFormatToMetal(pixelBuffer.pixelFormat)

                    var texture: CVMetalTexture?
                    let ret = CVMetalTextureCacheCreateTextureFromImage(
                        kCFAllocatorDefault,
                        textureCache,
                        pixelBuffer.cvBuffer,
                        nil,
                        pixelFormat,
                        pixelBuffer.width,
                        pixelBuffer.height,
                        0,
                        &texture
                    )

                    pixelBuffer.unlock(true)

                    if ret == noErr, let texture = texture {
                        let bufferContainer = BufferContainer(pixelBuffer)
                        self.pixelBuffers[pixelBuffer.cvBuffer] = bufferContainer
                        bufferContainer.texture = texture

                        self.currentBuffer = pixelBuffer
                        self.currentTexture = texture
                        bufferContainer.time = now
                    } else {
                        Logger.error("Error creating texture! \(ret)")
                    }
                }

                flush = true
            }

            jobQueue.enqueue {
                for (pixelBuffer, bufferContainer) in self.pixelBuffers
                    where bufferContainer.buffer.isTemporary &&
                        bufferContainer.buffer.cvBuffer != self.currentBuffer?.cvBuffer {
                            // Buffer is temporary, release it.
                            self.pixelBuffers[pixelBuffer] = nil
                }

                if flush {
                    CVMetalTextureCacheFlush(textureCache, 0)
                }
            }
        }
        #endif
    }

    /*!
     *  Release a currently-retained buffer from a source.
     *
     *  \param source  The source that created the buffer to be released.
     */
    func releaseBuffer(_ source: WeakRefISource) {
        Logger.debug("GLESVideoMixer::releaseBuffer")

        guard let hashValue = hashWeak(source), let index = sourceBuffers.index(forKey: hashValue) else {
            return Logger.debug("unexpected return")
        }
        sourceBuffers.remove(at: index)
    }

    func hashWeak(_ obj: WeakRefISource) -> Int? {
        guard let obj = obj.value else {
            Logger.debug("unexpected return")
            return 0
        }
        return ObjectIdentifier(obj).hashValue
    }

    /*! Start the compositor thread */
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    @objc func mixThread() {
        let us = TimeInterval(bufferDuration)
        let us_25 = TimeInterval(bufferDuration * 0.25)
        us25 = us_25

        Thread.current.name = "jp.co.cyberagent.VideoCast.compositeloop"

        var currentFb = 0

        var locked: [Bool] = .init(repeating: false, count: 2)

        nextMixTime = epoch

        while !exiting.value {
            mixThreadCond.lock()
            defer { mixThreadCond.unlock() }

            let now = Date()

            if now >= nextMixTime {

                let currentTime = nextMixTime
                if !shouldSync {
                    nextMixTime += us
                } else {
                    nextMixTime = syncPoint > nextMixTime ? syncPoint + us : nextMixTime + us
                }

                if mixing.value || paused.value {
                    continue
                }

                locked[currentFb] = true

                mixing.value = true
                defer {
                    mixing.value = false
                }

                #if targetEnvironment(simulator)
                perfGLAsync(glContext: glesCtx, jobQueue: metalJobQueue) {
                    glPushGroupMarkerEXT(0, "Videocast.Mix")
                    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), self.fbo[currentFb])

                    var currentFilter: IVideoFilter?
                    glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
                    var layerKey = self.zRange.0

                    while layerKey <= self.zRange.1 {
                        guard let layerMap = self.layerMap[layerKey] else {
                            Logger.debug("unexpected return")
                            continue
                        }

                        for key in layerMap {
                            var texture: CVOpenGLESTexture?
                            let filter = self.sourceFilters.index(forKey: key)

                            if filter == nil {
                                let newFilter =
                                    self.filterFactory.filter(name: "jp.co.cyberagent.VideoCast.filters.bgra")
                                self.sourceFilters[key] = newFilter as? IVideoFilter
                            }

                            if currentFilter !== self.sourceFilters[key] {
                                if let currentFilter = currentFilter {
                                    currentFilter.unbind()
                                }
                                currentFilter = self.sourceFilters[key]

                                if let currentFilter = currentFilter, !currentFilter.initialized {
                                    currentFilter.initialize()
                                }
                            }

                            guard let iTex = self.sourceBuffers[key] else {
                                Logger.debug("unexpected return")
                                continue
                            }

                            texture = iTex.currentTexture

                            // TODO: Add blending.
                            if iTex.blends {
                                glEnable(GLenum(GL_BLEND))
                                glBlendFunc(GLenum(GL_SRC_ALPHA), GLenum(GL_ONE_MINUS_SRC_ALPHA))
                            }
                            if let texture = texture, let currentFilter = currentFilter {
                                currentFilter.matrix = self.sourceMats[key] ?? GLKMatrix4Identity
                                currentFilter.bind()
                                glBindTexture(GLenum(GL_TEXTURE_2D), CVOpenGLESTextureGetName(texture))
                                glDrawArrays(GLenum(GL_TRIANGLES), 0, 6)
                            } else {
                                Logger.error("Null texture!")
                            }
                            if iTex.blends {
                                glDisable(GLenum(GL_BLEND))
                            }
                        }
                        layerKey += 1
                    }
                    glFlush()
                    glPopGroupMarkerEXT()

                    if let lout = self.output {
                        let md = VideoBufferMetadata(ts: .init(seconds: currentTime.timeIntervalSince(self.epoch),
                                                               preferredTimescale: VC_TIME_BASE))
                        let nextFb = (currentFb + 1) % 2
                        if self.pixelBuffer[nextFb] != nil {
                            lout.pushBuffer(&self.pixelBuffer[nextFb]!,
                                            size: MemoryLayout<CVPixelBuffer>.size, metadata: md)
                        }
                    }

                    self.mixing.value = false
                }
                #else
                metalJobQueue.enqueue {
                    var currentFilter: IVideoFilter?

                    guard self.zRange.1 >= self.zRange.0 else { return }

                    // create a new command buffer for each renderpass to the current drawable
                    guard let commandBuffer = self.commandQueue.makeCommandBuffer() else { return }

                    guard let destinationTexture = self.metalTexture[currentFb] else { return }
                    self.setupRenderPassDescriptorForTexture(destinationTexture)

                    // create a render command encoder so we can render into something
                    guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(
                        descriptor: self.renderPassDescriptor) else { return }

                    for layerKey in (self.zRange.0...self.zRange.1) {
                        guard let layerMap = self.layerMap[layerKey] else {
                            continue
                        }

                        for key in layerMap {
                            var texture: CVMetalTexture?
                            let filter = self.sourceFilters.index(forKey: key)

                            if filter == nil {
                                let newFilter =
                                    self.filterFactory.filter(name: "jp.co.cyberagent.VideoCast.filters.bgra")
                                self.sourceFilters[key] = newFilter as? IVideoFilter
                            }

                            if currentFilter !== self.sourceFilters[key] {
                                if let currentFilter = currentFilter {
                                    currentFilter.unbind()
                                }
                                currentFilter = self.sourceFilters[key]

                                if let currentFilter = currentFilter, !currentFilter.initialized {
                                    currentFilter.initialize()
                                }
                            }

                            guard let iTex = self.sourceBuffers[key] else {
                                Logger.debug("unexpected return")
                                continue
                            }

                            texture = iTex.currentTexture

                            if let texture = texture,
                                let sourceTexture = CVMetalTextureGetTexture(texture),
                                let vertexBuffer = self.vertexBuffer,
                                let currentFilter = currentFilter {

                                // setup for GPU debugger
                                renderEncoder.pushDebugGroup("VideoCast.Mix \(layerKey):\(key)")

                                let mat = self.sourceMats[key] ?? GLKMatrix4Identity

                                // flip y
                                let flip = GLKVector3Make(1, -1, 1)
                                currentFilter.matrix = GLKMatrix4ScaleWithVector3(mat, flip)

                                currentFilter.bind()
                                currentFilter.render(renderEncoder)

                                // set the static vertex buffers
                                renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

                                // fragment texture for environment
                                renderEncoder.setFragmentTexture(sourceTexture, index: 0)

                                renderEncoder.setFragmentSamplerState(self.colorSamplerState, index: 0)

                                // tell the render context we want to draw our primitives
                                renderEncoder.drawPrimitives(type: .triangle,
                                                             vertexStart: 0,
                                                             vertexCount: s_vertexData.count)

                                renderEncoder.popDebugGroup()
                            } else {
                                Logger.error("Null texture!")
                            }
                        }
                    }

                    renderEncoder.endEncoding()

                    // finalize rendering here. this will push the command buffer to the GPU
                    commandBuffer.commit()

                    if let lout = self.output {
                        let md = VideoBufferMetadata(ts: .init(seconds: currentTime.timeIntervalSince(self.epoch),
                                                               preferredTimescale: VC_TIME_BASE))
                        let nextFb = (currentFb + 1) % 2
                        if self.pixelBuffer[nextFb] != nil {
                            lout.pushBuffer(&self.pixelBuffer[nextFb]!,
                                            size: MemoryLayout<CVPixelBuffer>.size, metadata: md)
                        }
                    }
                }
                #endif

                currentFb = (currentFb + 1) % 2
            }

            mixThreadCond.wait(until: nextMixTime)
        }
    }

    #if targetEnvironment(simulator)
    /*!
     * Setup the OpenGL ES context, shaders, and state.
     *
     */
    func setupGLES(excludeContext: (() -> Void)?) {
        glesCtx = EAGLContext(api: .openGLES3)
        if glesCtx == nil {
            glesCtx = EAGLContext(api: .openGLES2)
        }

        guard let glesCtx = glesCtx else {
            return Logger.error("Error! Unable to create an OpenGL ES 2.0 or 3.0 Context!")
        }
        EAGLContext.setCurrent(nil)
        EAGLContext.setCurrent(glesCtx)
        excludeContext?()

        CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, glesCtx, nil, &textureCache)
        guard let textureCache = textureCache else {
            fatalError("textureCache creation failed")
        }

        glGenFramebuffers(2, &fbo)

        glFramebufferStatus()

        glGenBuffers(1, &vbo)
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), vbo)
        glBufferData(GLenum(GL_ARRAY_BUFFER), s_vbo.count * MemoryLayout<GLfloat>.size * s_vbo.count, s_vbo,
                     GLenum(GL_STATIC_DRAW))

        glDisable(GLenum(GL_BLEND))
        glDisable(GLenum(GL_DEPTH_TEST))
        glDisable(GLenum(GL_SCISSOR_TEST))
        glViewport(0, 0, GLsizei(frameW), GLsizei(frameH))
        glClearColor(0.05, 0.05, 0.07, 1)
        CVOpenGLESTextureCacheFlush(textureCache, 0)
    }
    #else
    /*!
     * Setup the Metal, shaders, and state.
     *
     */
    func setupMetal() {
        CVMetalTextureCacheCreate(kCFAllocatorDefault,
                                  nil,
                                  device,
                                  nil,
                                  &textureCache)
        guard let textureCache = textureCache else {
            fatalError("textureCache creation failed")
        }

        createTextures()

        // setup the vertex, texCoord buffers
        vertexBuffer = device.makeBuffer(bytes: s_vertexData,
                                         length: MemoryLayout<Vertex>.size * s_vertexData.count,
                                         options: [])
        vertexBuffer?.label = "VideoMixerVertexBuffer"

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        colorSamplerState = device.makeSamplerState(descriptor: samplerDescriptor)

        CVMetalTextureCacheFlush(textureCache, 0)
    }
    #endif

    // swiftlint:disable:next function_body_length
    func createTextures() {
        //
        // Shared-memory FBOs
        //
        // What we are doing here is creating a couple of shared-memory textures to double-buffer the mixer and give us
        // direct access to the framebuffer data.
        //
        // There are several steps in this process:
        // 1. Create CVPixelBuffers that are created as IOSurfaces.  This is mandatory and only
        //    requires specifying the kCVPixelBufferIOSurfacePropertiesKey.
        // 2. Create a CVOpenGLESTextureCache
        // 3. Create a CVOpenGLESTextureRef for each CVPixelBuffer.
        // 4. Create an OpenGL ES Framebuffer for each CVOpenGLESTextureRef and
        //    set that texture as the color attachment.
        //
        // We may now attach these FBOs as the render target and avoid using the costly glGetPixels.
        autoreleasepool {
            if let pixelBufferPool = pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer[0])
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer[1])
            } else {
                let pixelBufferOptions: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: frameW,
                    kCVPixelBufferHeightKey as String: frameW,
                    kCVPixelBufferOpenGLESCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]

                CVPixelBufferCreate(kCFAllocatorDefault, frameW, frameH, kCVPixelFormatType_32BGRA,
                                    pixelBufferOptions as NSDictionary?, &pixelBuffer[0])
                CVPixelBufferCreate(kCFAllocatorDefault, frameW, frameH, kCVPixelFormatType_32BGRA,
                                    pixelBufferOptions as NSDictionary?, &pixelBuffer[1])
            }
        }

        guard let textureCache = textureCache else {
            fatalError("textureCache creation failed")
        }

        for i in (0 ... 1) {
            guard let pixelBuffer = pixelBuffer[i] else {
                Logger.debug("unexpected return")
                break
            }

            #if targetEnvironment(simulator)
            CVOpenGLESTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache, pixelBuffer,
                nil,
                GLenum(GL_TEXTURE_2D),
                GL_RGBA,
                GLsizei(frameW),
                GLsizei(frameH),
                GLenum(GL_BGRA),
                GLenum(GL_UNSIGNED_BYTE),
                0,
                &texture[i]
            )
            #else
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                      textureCache,
                                                      pixelBuffer,
                                                      nil,
                                                      MTLPixelFormat.bgra8Unorm,
                                                      frameW,
                                                      frameH,
                                                      0,
                                                      &texture[i])
            #endif

            guard let texture = texture[i] else {
                Logger.debug("unexpected return")
                break
            }

            #if targetEnvironment(simulator)
            glBindTexture(GLenum(GL_TEXTURE_2D), CVOpenGLESTextureGetName(texture))
            glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GLfloat(GL_LINEAR))
            glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GLfloat(GL_LINEAR))
            glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE))
            glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE))
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo[i])
            glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                                   GLenum(GL_TEXTURE_2D), CVOpenGLESTextureGetName(texture), 0)
            #else
            metalTexture[i] = CVMetalTextureGetTexture(texture)
            #endif
        }
    }

    #if !targetEnvironment(simulator)
    private func setupRenderPassDescriptorForTexture(_ texture: MTLTexture) {
        // create a color attachment every frame since we have to recreate the texture every frame
        renderPassDescriptor.colorAttachments[0].texture = texture

        // make sure to clear every frame for best performance
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.07, 1.0)

        // store only attachments that will be presented to the screen
        renderPassDescriptor.colorAttachments[0].storeAction = .store
    }
    #endif
}
