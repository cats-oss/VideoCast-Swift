//
//  MetalVideoMixer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/08/23.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit
import Metal

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
    var textureCache: CVMetalTextureCache?
    var texture = [CVMetalTexture?](repeating: nil, count: 2)

    var renderPassDescriptor = MTLRenderPassDescriptor()
    var vertexBuffer: MTLBuffer?
    var colorSamplerState: MTLSamplerState?
    var metalTexture = [MTLTexture?](repeating: nil, count: 2)

    let device = DeviceManager.device
    let commandQueue = DeviceManager.commandQueue

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

        metalJobQueue.enqueueSync {
            if zIndex < self.zRange.0 {
                self.zRange.0 = zIndex
            }

            if zIndex > self.zRange.1 {
                self.zRange.1 = zIndex
            }

            let source = metaData.source

            guard let textureCache = self.textureCache, let hashValue = self.hashWeak(source) else {
                return Logger.debug("unexpected return")
            }

            let inPixelBuffer = data.assumingMemoryBound(to: PixelBuffer.self).pointee

            if self.sourceBuffers[hashValue] == nil {
                self.sourceBuffers[hashValue] = .init()
            }
            self.sourceBuffers[hashValue]?.setBuffer(inPixelBuffer,
                                                     textureCache: textureCache, jobQueue: self.metalJobQueue)
            self.sourceBuffers[hashValue]?.blends = metaData.blends

            if self.layerMap[zIndex] == nil {
                self.layerMap[zIndex] = []
            }

            let layerIndex = self.layerMap[zIndex]?.firstIndex(of: hashValue)
            if layerIndex == nil {
                self.layerMap[zIndex]?.append(hashValue)
            }
            self.sourceMats[hashValue] = metaData.matrix
        }
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

            metalJobQueue.enqueue {
                self.createTextures()
            }
        }
    }
}
