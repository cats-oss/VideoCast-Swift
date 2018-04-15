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

// Convenience function to dispatch an OpenGL ES job to the created JobQueue
func perfGL(_ x: @escaping ()->Void, isSync: Bool, glContext: EAGLContext?, jobQueue: JobQueue) {
    let cl = {
        let cur = EAGLContext.current()
        if let glContext = glContext {
            EAGLContext.setCurrent(glContext)
        }
        x()
        EAGLContext.setCurrent(cur)
    }
    if isSync {
        jobQueue.enqueueSync(cl)
    } else {
        jobQueue.enqueue(cl)
    }
}

// Dispatch and execute synchronously
func perfGLSync(_ x: @escaping ()->Void, glContext: EAGLContext?, jobQueue: JobQueue) {
    perfGL(x, isSync: true, glContext: glContext, jobQueue: jobQueue)
}

// Dispatch and execute asynchronously
func perfGLAsync(_ x: @escaping ()->Void, glContext: EAGLContext?, jobQueue: JobQueue) {
    perfGL(x, isSync: false, glContext: glContext, jobQueue: jobQueue)
}

class GLESObjCCallback: NSObject {
    weak var mixer: GLESVideoMixer?
    
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(type(of: self).notification(notification:)), name: .UIApplicationDidEnterBackground, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(type(of: self).notification(notification:)), name: .UIApplicationWillEnterForeground, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc func notification(notification: Notification) {
        switch notification.name {
        case .UIApplicationDidEnterBackground:
            mixer?.mixPaused(true)
        case .UIApplicationWillEnterForeground:
            mixer?.mixPaused(false)
        default:
            break
        }
    }
}

fileprivate class SourceBuffer {
    private class Buffer_ {
        var buffer: PixelBuffer
        var texture: CVOpenGLESTexture?
        var time: Date = .init()
        
        init(_ buf: PixelBuffer) {
            buffer = buf
            
        }
        
        deinit {
            texture = nil
        }
    }
    
    fileprivate var currentTexture: CVOpenGLESTexture?
    fileprivate var currentBuffer: PixelBuffer?
    fileprivate var blends: Bool = false
    
    private var pixelBuffers: [CVPixelBuffer: Buffer_] = .init()
    
    fileprivate func setBuffer(_ pb: PixelBuffer, textureCache: CVOpenGLESTextureCache, jobQueue: JobQueue, glContext: EAGLContext) {
        var flush = false
        let now = Date()
        
        currentBuffer?.state = .available
        pb.state = .acquired
        
        if let it = pixelBuffers[pb.cvBuffer] {
            
            currentBuffer = pb
            currentTexture = it.texture
            it.time = now
            
        } else {
            perfGLAsync({ [weak self] in
                guard let strongSelf = self else { return }
                
                pb.lock(true)
                let format = pb.pixelFormat
                var is32bit = true
                
                is32bit = (format != kCVPixelFormatType_16LE565)

                var texture: CVOpenGLESTexture?
                let ret = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                       textureCache,
                                                                       pb.cvBuffer,
                                                                       nil,
                                                                       GLenum(GL_TEXTURE_2D),
                                                                       is32bit ? GL_RGBA : GL_RGB,
                                                                       GLsizei(pb.width),
                                                                       GLsizei(pb.height),
                                                                       GLenum(is32bit ? GL_BGRA : GL_RGB),
                                                                       GLenum(is32bit ? GL_UNSIGNED_BYTE : GL_UNSIGNED_SHORT_5_6_5),
                                                                       0,
                                                                       &texture)
                
                pb.unlock(true)
                if ret == noErr, let texture = texture {
                    glBindTexture(GLenum(GL_TEXTURE_2D), CVOpenGLESTextureGetName(texture))
                    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
                    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
                    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE);
                    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
                    
                    let iit = Buffer_(pb)
                    strongSelf.pixelBuffers[pb.cvBuffer] = iit
                    iit.texture = texture
                    
                    strongSelf.currentBuffer = pb
                    strongSelf.currentTexture = texture
                    iit.time = now
                    
                } else {
                    Logger.error("Error creating texture! \(ret)")
                }
                
            }, glContext: glContext, jobQueue: jobQueue)
            flush = true
        }
        
        perfGLAsync({
            for (key, it) in self.pixelBuffers {
                
                if it.buffer.isTemporary && it.buffer.cvBuffer != self.currentBuffer?.cvBuffer {
                    // Buffer is temporary, release it.
                    self.pixelBuffers[key] = nil
                }
            }
            if flush {
                CVOpenGLESTextureCacheFlush(textureCache, 0)
            }
            }, glContext: glContext, jobQueue: jobQueue)
        
    }
}

/*
 *  Takes CVPixelBufferRef inputs and outputs a single CVPixelBufferRef that has been composited from the various sources.
 *  Sources must output VideoBufferMetadata with their buffers. This compositor uses homogeneous coordinates.
 */
open class GLESVideoMixer: IVideoMixer {
    public var filterFactory: FilterFactory = .init()
    
    private let glJobQueue: JobQueue = .init("com.videocast.composite")
    
    private let bufferDuration: TimeInterval
    
    private weak var output: IOutput?
    private var sources: [WeakRefISource] = .init()
    
    private var _mixThread: Thread?
    private let mixThreadCond: NSCondition = .init()
    
    private let pixelBufferPool: CVPixelBufferPool?
    private var pixelBuffer: [CVPixelBuffer?] = .init(repeating: nil, count: 2)
    private var textureCache: CVOpenGLESTextureCache?
    private var texture: [CVOpenGLESTexture?] = .init(repeating: nil, count: 2)
    
    private let callbackSession: GLESObjCCallback
    private var glesCtx: EAGLContext?
    private var vbo: GLuint = 0, vao: GLuint = 0, fbo: [GLuint] = .init(repeating: 0, count: 2), prog: GLuint = 0, uMat: GLuint = 0
    
    private let frameW: Int
    private let frameH: Int
    
    private var zRange: (Int, Int) = (0, 0)
    private var layerMap: [Int: [Int]] = .init()
    
    private var sourceMats: [Int: GLKMatrix4] = .init()
    private var sourceFilters: [Int: IVideoFilter] = .init()
    private var sourceBuffers: [Int: SourceBuffer] = .init()
    
    private var syncPoint: Date = .init()
    private var epoch: Date = .init()
    private var nextMixTime: Date = .init()
    private var us25: TimeInterval = .init()
    
    private var exiting: Atomic<Bool> = .init(false)
    private var mixing: Atomic<Bool> = .init(false)
    private var paused: Atomic<Bool> = .init(false)
    
    private var shouldSync: Bool = false
    private let catchingUp: Bool = false
    
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

        zRange.0 = Int.max
        zRange.1 = Int.min
        
        callbackSession = .init()
        callbackSession.mixer = self

        perfGLSync({
            
            self.setupGLES(excludeContext: excludeContext)
            
            }, glContext: glesCtx, jobQueue: glJobQueue)
        
    }
    
    deinit {
        Logger.debug("GLESVideoMixer::deinit")
        perfGLSync({
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
        }, glContext: glesCtx, jobQueue: glJobQueue)
        
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
        
        let h = hash(source)
        for i in stride(from: sources.count - 1, through: 0, by: -1) {
            
            let shash = hashWeak(sources[i])
            
            if h == shash {
                sources.remove(at: i)
            }
        }
        
        if let iit = sourceBuffers.index(forKey: h) {
            sourceBuffers.remove(at: iit)
        }
        for i in (zRange.0...zRange.1) {
            guard let layerMap_i = layerMap[i] else {
                Logger.debug("unexpected return")
                continue
            }
            for iit in stride(from: layerMap_i.count - 1, through: 0, by: -1) {
                if layerMap_i[iit] == h {
                    layerMap[i]?.remove(at: iit)
                }
            }
        }
    }
    
    /*! IVideoMixer::setSourceFilter */
    open func setSourceFilter(_ source: WeakRefISource, filter: IVideoFilter) {
        let h = hashWeak(source)
        sourceFilters[h] = filter
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
        if paused.value {
            return
        }
        
        guard let md = metadata as? VideoBufferMetadata,
            let zIndex = md.data?.zIndex,
            let metaData = md.data else {
                Logger.debug("unexpected return")
                return
        }
        
        if zIndex < zRange.0 {
            zRange.0 = zIndex
        }
        if zIndex > zRange.1 {
            zRange.1 = zIndex
        }
        
        let source = metaData.source
        
        let h = hashWeak(source)
        
        guard let textureCache = textureCache,
            let glesCtx = glesCtx
            else {
                Logger.debug("unexpected return")
                return
        }
        let inPixelBuffer = data.assumingMemoryBound(to: PixelBuffer.self).pointee
        
        if sourceBuffers[h] == nil {
            sourceBuffers[h] = .init()
        }
        sourceBuffers[h]?.setBuffer(inPixelBuffer, textureCache: textureCache, jobQueue: glJobQueue, glContext: glesCtx)
        sourceBuffers[h]?.blends = metaData.blends
        
        if layerMap[zIndex] == nil {
            layerMap[zIndex] = .init()
        }
        let it = layerMap[zIndex]?.index(of: h)
        if it == nil {
            layerMap[zIndex]?.append(h)
        }
        sourceMats[h] = metaData.matrix
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
        
    /*!
     *  Release a currently-retained buffer from a source.
     *
     *  \param source  The source that created the buffer to be released.
     */
    private func releaseBuffer(_ source: WeakRefISource) {
        Logger.debug("GLESVideoMixer::releaseBuffer")
        let h = hashWeak(source)
        guard let it = sourceBuffers.index(forKey: h) else {
            Logger.debug("unexpected return")
            return
        }
        sourceBuffers.remove(at: it)
    }
    
    private func hashWeak(_ obj: WeakRefISource) -> Int {
        guard let obj = obj.value else {
            Logger.debug("unexpected return")
            return 0
        }
        return ObjectIdentifier(obj).hashValue
    }
    
    /*! Start the compositor thread */
    private func mixThread() {
        let us = TimeInterval(bufferDuration)
        let us_25 = TimeInterval(bufferDuration * 0.25)
        us25 = us_25
        
        Thread.current.name = "com.videocast.compositeloop"
        
        var currentFb = 0
        
        var locked: [Bool] = .init(repeating: false, count: 2)
        
        nextMixTime = epoch
        
        while !exiting.value {
            mixThreadCond.lock()
            defer {
                mixThreadCond.unlock()
            }
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
                perfGLAsync({
                    glPushGroupMarkerEXT(0, "Videocast.Mix")
                    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), self.fbo[currentFb])
                    
                    var currentFilter: IVideoFilter?
                    glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
                    var i = self.zRange.0
                    while i <= self.zRange.1 {
                        
                        guard let layerMap = self.layerMap[i] else {
                            Logger.debug("unexpected return")
                            continue
                        }
                        for it in layerMap {
                            var texture: CVOpenGLESTexture?
                            let filterit = self.sourceFilters.index(forKey: it)
                            if filterit == nil {
                                let filter = self.filterFactory.filter(name: "com.videocast.filters.bgra")
                                self.sourceFilters[it] = filter as? IVideoFilter
                            }
                            if currentFilter !== self.sourceFilters[it] {
                                if let currentFilter = currentFilter {
                                    currentFilter.unbind()
                                }
                                currentFilter = self.sourceFilters[it]
                                
                                if let currentFilter = currentFilter, !currentFilter.initialized {
                                    currentFilter.initialize()
                                }
                            }
                            
                            guard let iTex = self.sourceBuffers[it] else {
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
                                currentFilter.matrix = self.sourceMats[it] ?? GLKMatrix4Identity
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
                        i += 1
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
                    
                }, glContext: glesCtx, jobQueue: glJobQueue)
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
    private func setupGLES(excludeContext: (()->Void)?) {
        glesCtx = EAGLContext(api: .openGLES3)
        if glesCtx == nil {
            glesCtx = EAGLContext(api: .openGLES2)
        }
        guard let glesCtx = glesCtx else {
            Logger.error("Error! Unable to create an OpenGL ES 2.0 or 3.0 Context!")
            return
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
            Logger.debug("unexpected return")
            return
        }
        glGenFramebuffers(2, &fbo)
        for i in (0 ... 1) {
            guard let pixelBuffer = pixelBuffer[i] else {
                Logger.debug("unexpected return")
                break
            }
            CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, GLenum(GL_TEXTURE_2D), GL_RGBA, GLsizei(frameW), GLsizei(frameH), GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), 0, &texture[i])
            
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
        glClearColor(0.05, 0.05, 0.07, 1.0)
        CVOpenGLESTextureCacheFlush(textureCache, 0)
    }
    

}
