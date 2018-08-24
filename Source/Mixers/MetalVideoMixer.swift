//
//  MetalVideoMixer.swift
//  VideoCast
//
//  Created by 松澤 友弘 on 2018/08/23.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import MetalKit
import GLKit

/*
 *  Takes CVPixelBufferRef inputs and outputs a single CVPixelBufferRef that
 has been composited from the various sources.
 *  Sources must output VideoBufferMetadata with their buffers. This compositor uses homogeneous coordinates.
 */
open class MetalVideoMixer: IVideoMixer {
    public var filterFactory = FilterFactory()

    let metalJobQueue = JobQueue("jp.co.cyberagent.VideoCast.composite")

    let bufferDuration: TimeInterval

    weak var output: IOutput?
    private var sources = [WeakRefISource]()

    private var _mixThread: Thread?
    let mixThreadCond = NSCondition()

    let pixelBufferPool: CVPixelBufferPool?
    var pixelBuffer = [CVPixelBuffer?](repeating: nil, count: 2)
    var textureCache: CVMetalTextureCache?
    var texture = [CVMetalTexture?](repeating: nil, count: 2)

    var metalTexture = [MTLTexture?](repeating: nil, count: 2)

    private let callbackSession: MetalObjCCallback

    let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    var commandQueue: MTLCommandQueue!

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
     */
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

    deinit {
        Logger.debug("MetalVideoMixer::deinit")

        metalJobQueue.enqueueSync {
            self.sourceBuffers.removeAll()
        }

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

        guard let textureCache = textureCache, let hashValue = hashWeak(source) else {
            return Logger.debug("unexpected return")
        }

        let inPixelBuffer = data.assumingMemoryBound(to: PixelBuffer.self).pointee

        if sourceBuffers[hashValue] == nil {
            sourceBuffers[hashValue] = .init()
        }
        sourceBuffers[hashValue]?.setBuffer(inPixelBuffer, textureCache: textureCache, jobQueue: metalJobQueue)
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
            var texture: CVMetalTexture?
            var time = Date()

            init(_ buf: PixelBuffer) {
                buffer = buf
            }

            deinit {
                texture = nil
            }
        }

        var currentTexture: CVMetalTexture?
        var currentBuffer: PixelBuffer?
        var blends = false

        private var pixelBuffers = [CVPixelBuffer: BufferContainer]()

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
                jobQueue.enqueue { [weak self] in
                    guard let strongSelf = self else { return }

                    pixelBuffer.lock(true)

                    let format = pixelBuffer.pixelFormat
                    let is32bit = format != kCVPixelFormatType_16LE565

                    var texture: CVMetalTexture?
                    let ret = CVMetalTextureCacheCreateTextureFromImage(
                        kCFAllocatorDefault,
                        textureCache,
                        pixelBuffer.cvBuffer,
                        nil,
                        is32bit ? MTLPixelFormat.bgra8Unorm : MTLPixelFormat.b5g6r5Unorm,
                        pixelBuffer.width,
                        pixelBuffer.height,
                        0,
                        &texture
                    )

                    pixelBuffer.unlock(true)

                    if ret == noErr, let texture = texture {
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

            jobQueue.enqueue { [weak self] in
                guard let strongSelf = self else { return }
                for (pixelBuffer, bufferContainer) in strongSelf.pixelBuffers
                    where bufferContainer.buffer.isTemporary &&
                        bufferContainer.buffer.cvBuffer != strongSelf.currentBuffer?.cvBuffer {
                            // Buffer is temporary, release it.
                            strongSelf.pixelBuffers[pixelBuffer] = nil
                }

                if flush {
                    CVMetalTextureCacheFlush(textureCache, 0)
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
    // swiftlint:disable:next cyclomatic_complexity function_body_length
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
                metalJobQueue.enqueue { [weak self] in
                    guard let strongSelf = self else { return }
                    var currentFilter: IVideoFilter?
                    var layerKey = strongSelf.zRange.0

                    while layerKey <= strongSelf.zRange.1 {
                        guard let layerMap = strongSelf.layerMap[layerKey] else {
                            Logger.debug("unexpected return")
                            continue
                        }

                        for key in layerMap {
                            var texture: CVMetalTexture?
                            let filter = strongSelf.sourceFilters.index(forKey: key)

                            if filter == nil {
                                let newFilter =
                                    strongSelf.filterFactory.filter(name: "jp.co.cyberagent.VideoCast.filters.bgra")
                                strongSelf.sourceFilters[key] = newFilter as? IVideoFilter
                            }

                            if currentFilter !== strongSelf.sourceFilters[key] {
                                if let currentFilter = currentFilter {
                                    currentFilter.unbind()
                                }
                                currentFilter = strongSelf.sourceFilters[key]

                                if let currentFilter = currentFilter, !currentFilter.initialized {
                                    currentFilter.initialize()
                                }
                            }

                            guard let iTex = strongSelf.sourceBuffers[key] else {
                                Logger.debug("unexpected return")
                                continue
                            }

                            texture = iTex.currentTexture

                            // TODO: Add blending.
                            if iTex.blends {
                            }
                            if let texture = texture,
                                let sourceTexture = CVMetalTextureGetTexture(texture),
                                let currentFilter = currentFilter {
                                //currentFilter.matrix = self.sourceMats[key] ?? GLKMatrix4Identity
                                //currentFilter.bind()

                                guard let commandBuffer = strongSelf.commandQueue.makeCommandBuffer() else { return }
                                guard let destinationTexture = strongSelf.metalTexture[currentFb] else { return }

                                guard let blitCommandEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
                                blitCommandEncoder.copy(from: sourceTexture,
                                                        sourceSlice: 0,
                                                        sourceLevel: 0,
                                                        sourceOrigin: MTLOriginMake(0, 0, 0),
                                                        sourceSize: MTLSizeMake(sourceTexture.width, sourceTexture.height, 1),
                                                        to: destinationTexture,
                                                        destinationSlice: 0,
                                                        destinationLevel: 0,
                                                        destinationOrigin: MTLOriginMake(0, 0, 0))
                                blitCommandEncoder.endEncoding()
                            } else {
                                Logger.error("Null texture!")
                            }
                            if iTex.blends {
                            }
                        }
                        layerKey += 1
                    }

                    if let lout = strongSelf.output {
                        let md = VideoBufferMetadata(ts: .init(seconds: currentTime.timeIntervalSince(strongSelf.epoch),
                                                               preferredTimescale: VC_TIME_BASE))
                        let nextFb = (currentFb + 1) % 2
                        if strongSelf.pixelBuffer[nextFb] != nil {
                            lout.pushBuffer(&strongSelf.pixelBuffer[nextFb]!,
                                            size: MemoryLayout<CVPixelBuffer>.size, metadata: md)
                        }
                    }

                    strongSelf.mixing.value = false
                }

                currentFb = (currentFb + 1) % 2
            }

            mixThreadCond.wait(until: nextMixTime)
        }
    }

    /*!
     * Setup the OpenGL ES context, shaders, and state.
     *
     */
    // swiftlint:disable:next function_body_length
    func setupMetal() {
        commandQueue = device.makeCommandQueue()

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
        CVMetalTextureCacheCreate(kCFAllocatorDefault,
                                  nil,
                                  device,
                                  nil,
                                  &textureCache)

        guard let textureCache = textureCache else {
            fatalError("textureCache creation failed")
        }

        for i in (0 ... 1) {
            guard let pixelBuffer = pixelBuffer[i] else {
                Logger.debug("unexpected return")
                break
            }

            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                      textureCache,
                                                      pixelBuffer,
                                                      nil,
                                                      MTLPixelFormat.bgra8Unorm,
                                                      frameW,
                                                      frameH,
                                                      0,
                                                      &texture[i])

            guard let texture = texture[i] else {
                Logger.debug("unexpected return")
                break
            }

            metalTexture[i] = CVMetalTextureGetTexture(texture)
        }
    }
}
