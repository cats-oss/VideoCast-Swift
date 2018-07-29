//
//  GLESVideoMixer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/10.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit

/*
 *  Takes CVPixelBufferRef inputs and outputs a single CVPixelBufferRef that
    has been composited from the various sources.
 *  Sources must output VideoBufferMetadata with their buffers. This compositor uses homogeneous coordinates.
 */
open class GLESVideoMixer: IVideoMixer {
    public var filterFactory = FilterFactory()

    let glJobQueue = JobQueue("jp.co.cyberagent.VideoCast.composite")

    let bufferDuration: TimeInterval

    weak var output: IOutput?
    private var sources = [WeakRefISource]()

    private var _mixThread: Thread?
    let mixThreadCond = NSCondition()

    let pixelBufferPool: CVPixelBufferPool?
    var pixelBuffer = [CVPixelBuffer?](repeating: nil, count: 2)
    var textureCache: CVOpenGLESTextureCache?
    var texture = [CVOpenGLESTexture?](repeating: nil, count: 2)

    private let callbackSession: GLESObjCCallback
    var glesCtx: EAGLContext?
    var vbo: GLuint = 0
    private var vao: GLuint = 0
    var fbo = [GLuint](repeating: 0, count: 2)
    private var prog: GLuint = 0
    private var uMat: GLuint = 0

    let frameW: Int
    let frameH: Int

    var zRange = (0, 0)
    var layerMap = [Int: [Int]]()

    var sourceMats = [Int: GLKMatrix4]()
    var sourceFilters = [Int: IVideoFilter]()
    var sourceBuffers = [Int: SourceBuffer]()

    var syncPoint = Date()
    var epoch = Date()
    var nextMixTime = Date()
    var us25 = TimeInterval()

    var exiting = Atomic(false)
    var mixing = Atomic(false)
    var paused = Atomic<Bool>(false)

    var shouldSync = false
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
    public init(
        frame_w: Int,
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

            for layerInnerIndex in stride(from: layerMap_i.count - 1, through: 0, by: -1)
                where layerMap_i[layerInnerIndex] == hashValue {
                layerMap[layerIndex]?.remove(at: layerInnerIndex)
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
        sourceBuffers[hashValue]?.setBuffer(inPixelBuffer, textureCache: textureCache,
                                            jobQueue: glJobQueue, glContext: glesCtx)
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

// Dispatch and execute synchronously
func perfGLSync(glContext: EAGLContext?, jobQueue: JobQueue, execute: @escaping () -> Void) {
    perfGL(isSync: true, glContext: glContext, jobQueue: jobQueue, execute: execute)
}

// Dispatch and execute asynchronously
func perfGLAsync(glContext: EAGLContext?, jobQueue: JobQueue, execute: @escaping () -> Void) {
    perfGL(isSync: false, glContext: glContext, jobQueue: jobQueue, execute: execute)
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
