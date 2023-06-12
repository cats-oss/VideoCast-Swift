//
//  MP4Multiplexer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

// swiftlint:disable file_length
import Foundation
import AVFoundation

public typealias MP4SessionParameters =
    MetaData<(filename: String, fps: Int, width: Int, height: Int, videoCodecType: CMVideoCodecType)>

open class MP4Multiplexer: IOutputSession {
    private let writingQueue: DispatchQueue = .init(label: "jp.co.cyberagent.VideoCast.mp4multiplexer")

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    private var videoFormat: CMVideoFormatDescription?
    private var audioFormat: CMAudioFormatDescription?

    private var vps: [UInt8] = .init()
    private var sps: [UInt8] = .init()
    private var pps: [UInt8] = .init()

    private let epoch: Date = .init()

    private var filename: String = ""
    private var fps: Int = 30
    private var width: Int = 0
    private var height: Int = 0
    private var videoCodecType: CMVideoCodecType = kCMVideoCodecType_H264
    private let framecount: Int = 0

    private var startedSession: Bool = false
    private var firstVideoBuffer: Bool = true
    private var firstAudioBuffer: Bool = true
    private var firstVideoFrameTime: CMTime?
    private var lastVideoFrameTime: CMTime?

    private var started: Bool = false
    private var exiting: Atomic<Bool> = .init(false)
    private var thread: Thread?
    private let cond: NSCondition = .init()

    struct SampleInput {
        var buffer: CMBlockBuffer
        var timingInfo: CMSampleTimingInfo
        var size: Int
    }

    private var videoSamples: [SampleInput] = .init()
    private var audioSamples: [SampleInput] = .init()

    private var stopCallback: StopSessionCallback?

    public init() {

    }

    deinit {
        if startedSession {
            stop {}
        }

        audioFormat = nil
        videoFormat = nil
        assetWriter = nil
    }

    open func stop(_ callback: @escaping StopSessionCallback) {
        startedSession = false
        exiting.value = true
        cond.broadcast()

        stopCallback = callback
    }

    open func setSessionParameters(_ parameters: IMetaData) {
        guard let params = parameters as? MP4SessionParameters, let data = params.data else {
            Logger.debug("unexpected return")
            return
        }

        filename = data.filename
        fps = data.fps
        width = data.width
        height = data.height
        videoCodecType = data.videoCodecType
        Logger.info("(\(fps), \(width), \(height), \(videoCodecType)")

        if !started {
            started = true
            thread = Thread(target: self, selector: #selector(writingThread), object: nil)
            thread?.start()
        }
    }

    open func setBandwidthCallback(_ callback: @escaping BandwidthCallback) {

    }

    open func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        if let videMetadata = metadata as? VideoBufferMetadata {
            self.pushVideoBuffer(data, size: size, metadata: videMetadata)
        } else if let sounMetadata = metadata as? AudioBufferMetadata {
            self.pushAudioBuffer(data, size: size, metadata: sounMetadata)
        }
    }
}

extension MP4Multiplexer {
    private func saveParameterSet(_ nalType: NalType, data: UnsafePointer<UInt8>, size: Int) {
        switch nalType {
        case .vps:
            if vps.isEmpty {
                let buf = UnsafeBufferPointer<UInt8>(start: data.advanced(by: 4), count: size-4)
                vps.append(contentsOf: buf)
            }
        case .sps:
            if sps.isEmpty {
                let buf = UnsafeBufferPointer<UInt8>(start: data.advanced(by: 4), count: size-4)
                sps.append(contentsOf: buf)
            }
        case .pps:
            if pps.isEmpty {
                let buf = UnsafeBufferPointer<UInt8>(start: data.advanced(by: 4), count: size-4)
                pps.append(contentsOf: buf)
            }
        default:
            break
        }
    }

    private func addVideo(_ data: UnsafePointer<UInt8>, size: Int, metadata: VideoBufferMetadata) {
        var bufferOut: CMBlockBuffer?
        let memoryBlock = UnsafeMutableRawPointer.allocate(byteCount: size,
                                                           alignment: MemoryLayout<UInt8>.alignment)
        memoryBlock.initializeMemory(as: UInt8.self, from: data, count: size)
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: memoryBlock,
            blockLength: size,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: size,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &bufferOut)
        guard let buffer = bufferOut else {
            Logger.debug("unexpected return")
            return
        }

        var timingInfo: CMSampleTimingInfo = .init()
        timingInfo.presentationTimeStamp = metadata.pts
        timingInfo.decodeTimeStamp = metadata.dts.isNumeric ? metadata.dts : metadata.pts

        guard let assetWriter = assetWriter else { return }
        if assetWriter.status == .unknown {
            if assetWriter.startWriting() {
                assetWriter.startSession(atSourceTime: timingInfo.decodeTimeStamp)
                Logger.debug("startSession: \(timingInfo.decodeTimeStamp)")
                startedSession = true
            } else {
                Logger.error("could not start writing video: \(String(describing: assetWriter.error))")
            }
        }

        if nil == firstVideoFrameTime {
            firstVideoFrameTime = timingInfo.decodeTimeStamp
        }
        lastVideoFrameTime = timingInfo.presentationTimeStamp

        writingQueue.async { [weak self] in
            guard let strongSelf = self, !strongSelf.exiting.value else { return }

            strongSelf.videoSamples.insert(.init(buffer: buffer, timingInfo: timingInfo, size: size), at: 0)
            strongSelf.cond.signal()
        }
    }

    private func pushVideoBuffer(_ data: UnsafeRawPointer, size: Int, metadata: VideoBufferMetadata) {
        let data = data.assumingMemoryBound(to: UInt8.self)
        let isVLC: Bool
        let nalType: NalType

        switch videoCodecType {
        case kCMVideoCodecType_H264:
            (nalType, isVLC) = getNalTypeH264(data)
        case kCMVideoCodecType_HEVC:
            (nalType, isVLC) = getNalTypeHEVC(data)
        default:
            Logger.error("unsupported codec type: \(videoCodecType)")
            return
        }

        firstVideoBuffer = false

        if !isVLC {
            saveParameterSet(nalType, data: data, size: size)
            if videoInput == nil {
                createAVCC()
            }
        } else {
            addVideo(data, size: size, metadata: metadata)
        }
    }

    // swiftlint:disable:next function_body_length
    private func pushAudioBuffer(_ data: UnsafeRawPointer, size: Int, metadata: AudioBufferMetadata) {
        guard let assetWriter = assetWriter else { return }

        let data = data.assumingMemoryBound(to: UInt8.self)

        if audioFormat != nil {
            guard let firstVideoFrameTime = firstVideoFrameTime,
                firstVideoFrameTime < metadata.pts else {
                return
            }
            var bufferOut: CMBlockBuffer?
            let memoryBlock = UnsafeMutableRawPointer.allocate(byteCount: size,
                                                               alignment: MemoryLayout<UInt8>.alignment)
            memoryBlock.initializeMemory(as: UInt8.self, from: data, count: size)
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: memoryBlock,
                blockLength: size,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: size,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &bufferOut)
            guard let buffer = bufferOut else {
                Logger.debug("unexpected return")
                return
            }

            var timingInfo: CMSampleTimingInfo = .init()
            timingInfo.presentationTimeStamp = metadata.pts
            timingInfo.decodeTimeStamp = metadata.dts.isNumeric ? metadata.dts : metadata.pts

            writingQueue.async { [weak self] in
                guard let strongSelf = self, !strongSelf.exiting.value else { return }

                strongSelf.audioSamples.insert(.init(buffer: buffer, timingInfo: timingInfo, size: size), at: 0)
                strongSelf.cond.signal()
            }
        } else {
            let md = metadata
            guard let metaData = md.data else {
                Logger.debug("unexpected return")
                return
            }

            var asbd: AudioStreamBasicDescription = .init()
            asbd.mFormatID = kAudioFormatMPEG4AAC
            asbd.mFormatFlags = 0
            asbd.mFramesPerPacket = 1024
            asbd.mSampleRate = Float64(metaData.frequencyInHz)
            asbd.mChannelsPerFrame = UInt32(metaData.channelCount)

            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: size,
                magicCookie: data,
                extensions: nil,
                formatDescriptionOut: &audioFormat)

            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)

            audio.expectsMediaDataInRealTime = true

            if assetWriter.canAdd(audio) {
                assetWriter.add(audio)
                audioInput = audio
            } else {
                Logger.error("cannot add audio input")
            }
        }
    }

    @objc private func writingThread() {
        let fileUrl = URL(fileURLWithPath: filename)
        do {
            let writer = try AVAssetWriter(url: fileUrl, fileType: .mp4)

            let fileManager = FileManager()
            let filePath = fileUrl.path
            if fileManager.fileExists(atPath: filePath) {
                try fileManager.removeItem(at: fileUrl)
            }

            assetWriter = writer
            assetWriter?.shouldOptimizeForNetworkUse = false

        } catch {
            Logger.error("Could not create AVAssetWriter: \(error)")
            return
        }

        while !exiting.value {
            cond.lock()
            defer {
                cond.unlock()
            }

            writingQueue.sync {
                writeSample(.video)
                writeSample(.audio)
            }

            if videoSamples.count < 2 && audioSamples.count < 2 && !exiting.value {
                cond.wait()
            }
        }

        while !videoSamples.isEmpty || !audioSamples.isEmpty {
            writingQueue.sync {
                writeSample(.video)
                writeSample(.audio)
            }
        }

        /*videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        assetWriter?.endSession(atSourceTime: lastVideoFrameTime)*/
        assetWriter?.finishWriting(completionHandler: { [weak self] in
            guard let strongSelf = self else { return }
            Logger.debug("Stopped writing video file")
            if strongSelf.assetWriter?.status == .failed {
                Logger.error("creating video file failed: \(String(describing: strongSelf.assetWriter?.error))")
            }
            strongSelf.stopCallback?()
        })

    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func writeSample(_ mediaType: AVMediaType) {
        let samples = (mediaType == .video) ? videoSamples : audioSamples
        if samples.count > 1 || (exiting.value && !samples.isEmpty) {
            guard let format = (mediaType == .video) ? videoFormat : audioFormat else { return }
            guard var sampleInput = (mediaType == .video) ? videoSamples.popLast() : audioSamples.popLast() else {
                Logger.debug("unexpected return")
                return
            }
            let nextSampleInput = samples.last ?? sampleInput
            guard let assetWriter = assetWriter else {
                Logger.debug("unexpected return")
                return
            }

            var sampleOut: CMSampleBuffer?
            var size: Int = sampleInput.size

            sampleInput.timingInfo.duration =
                nextSampleInput.timingInfo.decodeTimeStamp - sampleInput.timingInfo.decodeTimeStamp
            if CMTimeCompare(CMTime.zero, sampleInput.timingInfo.duration) == 0 {
                // last sample
                sampleInput.timingInfo.duration = .init(value: 1, timescale: 100000)
            }

            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: sampleInput.buffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: format,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &sampleInput.timingInfo,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &size,
                sampleBufferOut: &sampleOut)

            guard let sample = sampleOut else {
                Logger.debug("unexpected return")
                return
            }
            CMSampleBufferMakeDataReady(sample)

            guard let input = (mediaType == .video) ? videoInput : audioInput else {
                Logger.debug("unexpected return")
                return
            }

            if mediaType == .audio {
                if firstAudioBuffer {
                    firstAudioBuffer = false
                    primeAudio(audioSample: sample)
                }
            }

            guard assetWriter.status == .writing else {
                Logger.debug("unexpected return")
                return
            }
            let mediaType = mediaType.rawValue
            Logger.verbose("Appending \(mediaType)")
            if input.isReadyForMoreMediaData {
                if !input.append(sample) {
                    Logger.error("could not append \(mediaType): \(String(describing: assetWriter.error))")
                }
            } else {
                Logger.warn("\(mediaType) input not ready for more media data, dropping buffer")
            }
            Logger.verbose("Done \(mediaType)")
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func createAVCC() {
        guard let assetWriter = assetWriter else { return }
        switch videoCodecType {
        case kCMVideoCodecType_H264:
            guard !sps.isEmpty && !pps.isEmpty else { return }
        case kCMVideoCodecType_HEVC:
            guard !vps.isEmpty && !sps.isEmpty && !pps.isEmpty else { return }
        default:
            Logger.error("unsupported codec type: \(videoCodecType)")
            return
        }

        let spsCount = sps.count
        let ppsCount = pps.count
        let vpsCount = vps.count
        withUnsafePointer(to: &sps[0]) { pointerSPS in
            withUnsafePointer(to: &pps[0]) { pointerPPS in
                var dataParamArray = [pointerSPS, pointerPPS]
                var sizeParamArray = [spsCount, ppsCount]
                if videoCodecType == kCMVideoCodecType_HEVC {
                    withUnsafePointer(to: &vps[0]) { pointerVPS in
                        dataParamArray.insert(pointerVPS, at: 0)
                        sizeParamArray.insert(vpsCount, at: 0)
                    }
                }

                switch videoCodecType {
                case kCMVideoCodecType_H264:
                    let ret = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: dataParamArray.count,
                        parameterSetPointers: &dataParamArray,
                        parameterSetSizes: &sizeParamArray,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &videoFormat)
                    guard ret == noErr else {
                        Logger.error("could not create video format for h264")
                        return
                    }
                case kCMVideoCodecType_HEVC:
                    if #available(iOS 11.0, *) {
                        let ret = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: dataParamArray.count,
                            parameterSetPointers: &dataParamArray,
                            parameterSetSizes: &sizeParamArray,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &videoFormat)
                        guard ret == noErr else {
                            Logger.error("could not create video format for hevc")
                            return
                        }
                    } else {
                        Logger.error("unsupported codec type: \(videoCodecType)")
                        return
                    }
                default:
                    return
                }
            }
        }

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        video.expectsMediaDataInRealTime = true

        if assetWriter.canAdd(video) {
            assetWriter.add(video)
            videoInput = video
        } else {
            Logger.error("cannot add video input")
        }
    }

    private func primeAudio(audioSample: CMSampleBuffer) {
        var attachmentMode: CMAttachmentMode = .init()
        let trimDuration = CMGetAttachment(audioSample,
                                           key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                                           attachmentModeOut: &attachmentMode)

        if trimDuration == nil {
            Logger.debug("Prime audio")
            let trimTime: CMTime = .init(seconds: 0.1, preferredTimescale: 1000000000)
            let timeDict = CMTimeCopyAsDictionary(trimTime, allocator: kCFAllocatorDefault)
            CMSetAttachment(audioSample,
                            key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                            value: timeDict,
                            attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
    }
}
