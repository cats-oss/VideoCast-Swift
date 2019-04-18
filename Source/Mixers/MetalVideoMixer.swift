//
//  MetalVideoMixer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/08/23.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit
#if !targetEnvironment(simulator) && !arch(arm)
import Metal
#endif

/*
 *  Takes CVPixelBufferRef inputs and outputs a single CVPixelBufferRef that
 has been composited from the various sources.
 *  Sources must output VideoBufferMetadata with their buffers. This compositor uses homogeneous coordinates.
 */
open class MetalVideoMixer: IVideoMixer {
    let metalJobQueue = JobQueue("jp.co.cyberagent.VideoCast.composite")

    let bufferDuration: TimeInterval

    weak var output: IOutput?
    private var sources = [WeakRefISource]()

    private var _mixThread: Thread?
    let mixThreadCond = NSCondition()

    let pixelBufferPool: CVPixelBufferPool?
    var pixelBuffer = [CVPixelBuffer?](repeating: nil, count: 2)
    #if targetEnvironment(simulator) || arch(arm)
    var textureCache: CVOpenGLESTextureCache?
    var texture = [CVOpenGLESTexture?](repeating: nil, count: 2)

    var glesCtx: EAGLContext?
    var vbo: GLuint = 0
    private var vao: GLuint = 0
    var fbo = [GLuint](repeating: 0, count: 2)
    private var prog: GLuint = 0
    private var uMat: GLuint = 0
    #else
    var textureCache: CVMetalTextureCache?
    var texture = [CVMetalTexture?](repeating: nil, count: 2)

    var renderPassDescriptor = MTLRenderPassDescriptor()
    var vertexBuffer: MTLBuffer?
    var colorSamplerState: MTLSamplerState?
    var metalTexture = [MTLTexture?](repeating: nil, count: 2)

    let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    let commandQueue = DeviceManager.commandQueue
    #endif
    private let callbackSession: MetalObjCCallback

    var frameW: Int
    var frameH: Int

    var zRange = (0, 0)
    var layerMap = [Int: [Int]]()

    var sourceMats = [Int: GLKMatrix4]()
    var sourceFilters = [Int: IVideoFilter]()
    var sourceBuffers = [Int: SourceBuffer]()

    var syncPoint = Date()
    var epoch = Date()
    var delay = TimeInterval()
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
     */

    #if targetEnvironment(simulator) || arch(arm)
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

        callbackSession = MetalObjCCallback()
        callbackSession.mixer = self

        perfGLSync(glContext: glesCtx, jobQueue: metalJobQueue) {
            self.setupGLES(excludeContext: excludeContext)
        }
    }
    #else
    public init(
        frame_w: Int,
        frame_h: Int,
        frameDuration: TimeInterval,
        pixelBufferPool: CVPixelBufferPool? = nil) {
        bufferDuration = frameDuration
        frameW = frame_w
        frameH = frame_h
        self.pixelBufferPool = pixelBufferPool

        zRange.0 = .max
        zRange.1 = .min

        callbackSession = MetalObjCCallback()
        callbackSession.mixer = self

        metalJobQueue.enqueueSync {
            self.setupMetal()
        }
    }
    #endif

    deinit {
        Logger.debug("MetalVideoMixer::deinit")

        #if targetEnvironment(simulator) || arch(arm)
        perfGLSync(glContext: glesCtx, jobQueue: metalJobQueue) {
            glDeleteBuffers(1, &self.vbo)
            self.deleteTextures()

            self.sourceBuffers.removeAll()

            if let textureCache = self.textureCache {
                CVOpenGLESTextureCacheFlush(textureCache, 0)
            }

            self.glesCtx = nil
        }
        #else
        metalJobQueue.enqueueSync {
            self.sourceBuffers.removeAll()
        }
        #endif

        _mixThread?.cancel()

        metalJobQueue.markExiting()
        metalJobQueue.enqueueSync {}
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
        Logger.debug("MetalVideoMixer::unregisterSource")
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

        #if targetEnvironment(simulator) || arch(arm)
        guard let textureCache = textureCache, let glesCtx = glesCtx, let hashValue = hashWeak(source) else {
            return Logger.debug("unexpected return")
        }
        #else
        guard let textureCache = textureCache, let hashValue = hashWeak(source) else {
            return Logger.debug("unexpected return")
        }
        #endif

        let inPixelBuffer = data.assumingMemoryBound(to: PixelBuffer.self).pointee

        if sourceBuffers[hashValue] == nil {
            sourceBuffers[hashValue] = .init()
        }
        #if targetEnvironment(simulator) || arch(arm)
        sourceBuffers[hashValue]?.setBuffer(inPixelBuffer, textureCache: textureCache,
                                            jobQueue: metalJobQueue, glContext: glesCtx)
        #else
        sourceBuffers[hashValue]?.setBuffer(inPixelBuffer, textureCache: textureCache, jobQueue: metalJobQueue)
        #endif
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
        exiting.value = false
        _mixThread = Thread(target: self, selector: #selector(mixThread), object: nil)
        _mixThread?.start()
    }

    open func stop() {
        output = nil
        exiting.value = true
        mixThreadCond.broadcast()
    }

    open func setDelay(delay: TimeInterval) {
        self.delay = delay
    }

    open func mixPaused(_ paused: Bool) {
        self.paused.value = paused
    }

    open func setFrameSize(width: Int, height: Int) {
        if frameW != width || frameH != height {
            frameW = width
            frameH = height

            #if targetEnvironment(simulator) || arch(arm)
            perfGLAsync(glContext: glesCtx, jobQueue: metalJobQueue) { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.createTextures()
            }
            #else
            metalJobQueue.enqueue {
                self.createTextures()
            }
            #endif
        }
    }
}

#if targetEnvironment(simulator) || arch(arm)
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
#endif
