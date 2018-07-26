//
//  GLESVideoMixer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/10.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit
import CoreVideo
import CoreMedia

/*
 *  Takes CVPixelBufferRef inputs and outputs a single CVPixelBufferRef that has been composited from the various sources.
 *  Sources must output VideoBufferMetadata with their buffers. This compositor uses homogeneous coordinates.
 */
open class GLESVideoMixer: IVideoMixer {
    public var filterFactory = FilterFactory()

    private let glJobQueue = JobQueue("jp.co.cyberagent.VideoCast.composite")

    private let bufferDuration: TimeInterval

    private weak var output: IOutput?
    private var sources = [WeakRefISource]()

    private var _mixThread: Thread?
    private let mixThreadCond = NSCondition()

    private let pixelBufferPool: CVPixelBufferPool?
    private var pixelBuffer = [CVPixelBuffer?](repeating: nil, count: 2)
    private var textureCache: CVOpenGLESTextureCache?
    private var texture = [CVOpenGLESTexture?](repeating: nil, count: 2)

    private let callbackSession: GLESObjCCallback
    private var glesCtx: EAGLContext?
    private var vbo: GLuint = 0
    private var vao: GLuint = 0
    private var fbo = [GLuint](repeating: 0, count: 2)
    private var prog: GLuint = 0
    private var uMat: GLuint = 0

    private let frameW: Int
    private let frameH: Int

    private var zRange = (0, 0)
    private var layerMap = [Int: [Int]]()

    private var sourceMats = [Int: GLKMatrix4]()
    private var sourceFilters = [Int: IVideoFilter]()
    private var sourceBuffers = [Int: SourceBuffer]()

    private var syncPoint = Date()
    private var epoch = Date()
    private var nextMixTime = Date()
    private var us25 = TimeInterval()

    private var exiting = Atomic(false)
    private var mixing = Atomic(false)
    private var paused = Atomic<Bool>(false)

    private var shouldSync = false
    private let catchingUp = false

    /*! Constructor.
     *
     *  \param frame_w          The width of the output frame
     *  \param frame_h          The height of the output frame
     *  \param frameDuration    The duration of time a frame is presented, in seconds. 30 FPS would be (1/30)
     *  \param excludeContext   An optional lambda method that is called when the mixer generates its GL ES context.
     *                          The parameter of this method will be a pointer to its EAGLContext.  This is useful for
     *                          applications that may be capturing GLES data and do not wish to capture the mixer.
     */
    public init(frame_w: Int,
         frame_h: Int,
         frameDuration: TimeInterval,
         pixelBufferPool: CVPixelBufferPool? = nil,
         excludeContext: (() -> Void)? = nil) {
        bufferDuration = frameDuration
        frameW = frame_w
        frameH = frame_h
        self.pixelBufferPool = pixelBufferPool

        zRange.0 = .max
        zRange.1 = .min

        callbackSession = GLESObjCCallback()
        callbackSession.mixer = self

        perfGLSync(glContext: glesCtx, jobQueue: glJobQueue) {
            self.setupGLES(excludeContext: excludeContext)
        }
    }

    deinit {
        Logger.debug("GLESVideoMixer::deinit")

        perfGLSync(glContext: glesCtx, jobQueue: glJobQueue) {
            glDeleteFramebuffers(2, self.fbo)
            glDeleteBuffers(1, &self.vbo)
            if let texture0 = self.texture[0], let texture1 = self.texture[1] {
                let textures: [GLuint] = [
                    CVOpenGLESTextureGetName(texture0),
                    CVOpenGLESTextureGetName(texture1)
                ]
                glDeleteTextures(2, textures)
            }

            self.sourceBuffers.removeAll()

            if let textureCache = self.textureCache {
                CVOpenGLESTextureCacheFlush(textureCache, 0)
            }

            self.glesCtx = nil
        }

        _mixThread?.cancel()

        glJobQueue.markExiting()
        glJobQueue.enqueueSync {}
    }

    /*! IMixer::registerSource */
    open func registerSource(_ source: ISource, inBufferSize: Int) {
        let shash = hash(source)
        var registered = false

        for it in sources {
            if shash == hash(it) {
                registered = true
            }
        }

        if !registered {
            sources.append(WeakRefISource(value: source))
        }
    }

    /*! IMixer::unregisterSource */
    open func unregisterSource(_ source: ISource) {
        Logger.debug("GLESVideoMixer::unregisterSource")
        releaseBuffer(WeakRefISource(value: source))

        let hashValue = hash(source)
        for index in stride(from: sources.count - 1, through: 0, by: -1) {
            let shash = hashWeak(sources[index])

            if hashValue == shash {
                sources.remove(at: index)
            }
        }

        if let index = sourceBuffers.index(forKey: hashValue) {
            sourceBuffers.remove(at: index)
        }

        for layerIndex in zRange.0...zRange.1 {
            guard let layerMap_i = layerMap[layerIndex] else {
                Logger.debug("unexpected return")
                continue
            }

            for layerInnerIndex in stride(from: layerMap_i.count - 1, through: 0, by: -1) {
                if layerMap_i[layerInnerIndex] == hashValue {
                    layerMap[layerIndex]?.remove(at: layerInnerIndex)
                }
            }
        }
    }

    /*! IVideoMixer::setSourceFilter */
    open func setSourceFilter(_ source: WeakRefISource, filter: IVideoFilter) {
        guard let hashValue = hashWeak(source) else {
            return Logger.debug("unexpected return")
        }
        sourceFilters[hashValue] = filter
    }

    open func sync() {
        syncPoint = Date()
        shouldSync = true
    }

    /*! ITransform::setOutput */
    open func setOutput(_ output: IOutput) {
        self.output = output
    }

    /*! IOutput::pushBuffer */
    open func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        guard !paused.value else {
            return
        }

        guard let md = metadata as? VideoBufferMetadata, let zIndex = md.data?.zIndex, let metaData = md.data else {
            return Logger.debug("unexpected return")
        }

        if zIndex < zRange.0 {
            zRange.0 = zIndex
        }

        if zIndex > zRange.1 {
            zRange.1 = zIndex
        }

        let source = metaData.source

        guard let textureCache = textureCache, let glesCtx = glesCtx, let hashValue = hashWeak(source) else {
            return Logger.debug("unexpected return")
        }

        let inPixelBuffer = data.assumingMemoryBound(to: PixelBuffer.self).pointee

        if sourceBuffers[hashValue] == nil {
            sourceBuffers[hashValue] = .init()
        }
        sourceBuffers[hashValue]?.setBuffer(inPixelBuffer, textureCache: textureCache, jobQueue: glJobQueue, glContext: glesCtx)
        sourceBuffers[hashValue]?.blends = metaData.blends

        if layerMap[zIndex] == nil {
            layerMap[zIndex] = []
        }

        let layerIndex = layerMap[zIndex]?.index(of: hashValue)
        if layerIndex == nil {
            layerMap[zIndex]?.append(hashValue)
        }
        sourceMats[hashValue] = metaData.matrix
    }

    /*! ITransform::setEpoch */
    open func setEpoch(_ epoch: Date) {
        self.epoch = epoch
        nextMixTime = epoch
    }

    open func start() {
        _mixThread = Thread(block: mixThread)
        _mixThread?.start()
    }

    open func stop() {
        output = nil
        exiting.value = true
        mixThreadCond.broadcast()
    }

    open func mixPaused(_ paused: Bool) {
        self.paused.value = paused
    }
}

private extension GLESVideoMixer {
    final class GLESObjCCallback: NSObject {
        weak var mixer: GLESVideoMixer?

        override init() {
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(applicationDidEnterBackground), name: .UIApplicationDidEnterBackground, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(applicationWillEnterForeground), name: .UIApplicationWillEnterForeground, object: nil)
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
            var texture: CVOpenGLESTexture?
            var time = Date()

            init(_ buf: PixelBuffer) {
                buffer = buf
            }

            deinit {
                texture = nil
            }
        }

        var currentTexture: CVOpenGLESTexture?
        var currentBuffer: PixelBuffer?
        var blends = false

        private var pixelBuffers = [CVPixelBuffer: BufferContainer]()

        func setBuffer(_ pixelBuffer: PixelBuffer, textureCache: CVOpenGLESTextureCache, jobQueue: JobQueue, glContext: EAGLContext) {
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
                    where bufferContainer.buffer.isTemporary && bufferContainer.buffer.cvBuffer != self.currentBuffer?.cvBuffer {
                        // Buffer is temporary, release it.
                        self.pixelBuffers[pixelBuffer] = nil
                }

                if flush {
                    CVOpenGLESTextureCacheFlush(textureCache, 0)
                }
            }
        }
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
    func mixThread() {
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
                perfGLAsync(glContext: glesCtx, jobQueue: glJobQueue) {
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
                                let newFilter = self.filterFactory.filter(name: "jp.co.cyberagent.VideoCast.filters.bgra")
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
                        let md = VideoBufferMetadata(ts: .init(seconds: currentTime.timeIntervalSince(self.epoch), preferredTimescale: VC_TIME_BASE))
                        let nextFb = (currentFb + 1) % 2
                        if let _ = self.pixelBuffer[nextFb] {
                            lout.pushBuffer(&self.pixelBuffer[nextFb]!, size: MemoryLayout<CVPixelBuffer>.size, metadata: md)
                        }
                    }

                    self.mixing.value = false
                }

                currentFb = (currentFb + 1) % 2
            }

            mixThreadCond.wait(until: nextMixTime)
        }
    }

    /*!
     * Setup the OpenGL ES context, shaders, and state.
     *
     * \param excludeContext An optional lambda method that is called when the mixer generates its GL ES context.
     *                       The parameter of this method will be a pointer to its EAGLContext.  This is useful for
     *                       applications that may be capturing GLES data and do not wish to capture the mixer.
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
        // 4. Create an OpenGL ES Framebuffer for each CVOpenGLESTextureRef and set that texture as the color attachment.
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

                CVPixelBufferCreate(kCFAllocatorDefault, frameW, frameH, kCVPixelFormatType_32BGRA, pixelBufferOptions as NSDictionary?, &pixelBuffer[0])
                CVPixelBufferCreate(kCFAllocatorDefault, frameW, frameH, kCVPixelFormatType_32BGRA, pixelBufferOptions as NSDictionary?, &pixelBuffer[1])
            }
        }
        CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, glesCtx, nil, &textureCache)

        guard let textureCache = textureCache else {
            return Logger.debug("unexpected return")
        }

        glGenFramebuffers(2, &fbo)

        for i in (0 ... 1) {
            guard let pixelBuffer = pixelBuffer[i] else {
                Logger.debug("unexpected return")
                break
            }

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

            guard let texture = texture[i] else {
                Logger.debug("unexpected return")
                break
            }

            glBindTexture(GLenum(GL_TEXTURE_2D), CVOpenGLESTextureGetName(texture))
            glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GLfloat(GL_LINEAR))
            glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GLfloat(GL_LINEAR))
            glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE))
            glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE))
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo[i])
            glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), CVOpenGLESTextureGetName(texture), 0)
        }

        glFramebufferStatus()

        glGenBuffers(1, &vbo)
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), vbo)
        glBufferData(GLenum(GL_ARRAY_BUFFER), s_vbo.count * MemoryLayout<GLfloat>.size * s_vbo.count, s_vbo, GLenum(GL_STATIC_DRAW))

        glDisable(GLenum(GL_BLEND))
        glDisable(GLenum(GL_DEPTH_TEST))
        glDisable(GLenum(GL_SCISSOR_TEST))
        glViewport(0, 0, GLsizei(frameW), GLsizei(frameH))
        glClearColor(0.05, 0.05, 0.07, 1)
        CVOpenGLESTextureCacheFlush(textureCache, 0)
    }
}

// Convenience function to dispatch an OpenGL ES job to the created JobQueue
private func perfGL(isSync: Bool, glContext: EAGLContext?, jobQueue: JobQueue, execute: @escaping () -> Void) {
    let cl = {
        let context = EAGLContext.current()
        if let glContext = glContext {
            EAGLContext.setCurrent(glContext)
        }
        execute()
        EAGLContext.setCurrent(context)
    }
    if isSync {
        jobQueue.enqueueSync(cl)
    } else {
        jobQueue.enqueue(cl)
    }
}

// Dispatch and execute synchronously
private func perfGLSync(glContext: EAGLContext?, jobQueue: JobQueue, execute: @escaping () -> Void) {
    perfGL(isSync: true, glContext: glContext, jobQueue: jobQueue, execute: execute)
}

// Dispatch and execute asynchronously
private func perfGLAsync(glContext: EAGLContext?, jobQueue: JobQueue, execute: @escaping () -> Void) {
    perfGL(isSync: false, glContext: glContext, jobQueue: jobQueue, execute: execute)
}
