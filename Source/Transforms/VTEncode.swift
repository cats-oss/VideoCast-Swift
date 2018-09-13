//
//  VTEncode.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/16.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

import CoreVideo
import VideoToolbox

open class VTEncode: IEncoder {
    private let encodeQueue: DispatchQueue = .init(label: "jp.co.cyberagent.VideoCast.vtencode")
    private weak var output: IOutput?
    private var compressionSession: VTCompressionSession?
    private let frameW: Int
    private let frameH: Int
    private let fps: Int
    private let keyframeInterval: Int
    private var _bitrate: Int
    private let codecType: CMVideoCodecType

    private let ctsOffset: CMTime

    private var baseline: Bool = false
    private var forceKeyframe: Bool = false

    static private var s_forcedKeyframePTS: CMTimeValue = 0

    /*! IEncoder */
    open var bitrate: Int {
        get {
            return _bitrate
        }
        set {
            guard newValue != _bitrate else { return }
            _bitrate = newValue

            guard let compressionSession = compressionSession else {
                Logger.debug("unexpected return")
                return
            }
            encodeQueue.sync {

                let v = _bitrate
                var ret = VTSessionSetProperty(compressionSession,
                                               kVTCompressionPropertyKey_AverageBitRate,
                                               NSNumber(value: _bitrate))

                if ret != noErr {
                    Logger.error("VTEncode::setBitrate Error setting bitrate! \(ret)")
                }
                var ref: NSNumber = 0
                ret = VTSessionCopyProperty(compressionSession,
                                            kVTCompressionPropertyKey_AverageBitRate,
                                            kCFAllocatorDefault, &ref)

                if ret == noErr && ref != 0 {
                    _bitrate = Int(truncating: ref)
                } else {
                    _bitrate = v
                }
                let bytes = _bitrate / 8
                let duration = 1
                let limit: NSArray = .init(array: [bytes, duration])

                VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_DataRateLimits, limit)
            }
        }
    }

    private let vtCallback: VTCompressionOutputCallback = { (
        outputCallbackRefCon,
        sourceFrameRefCon,
        status,
        infoFlags,
        sampleBuffer ) -> Void in
        guard let sampleBuffer = sampleBuffer else {
            Logger.debug("unexpected return")
            return
        }

        let enc = unsafeBitCast(outputCallbackRefCon, to: VTEncode.self)

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            Logger.debug("unexpected return")
            return
        }
        let attachments: NSArray? = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)

        var isKeyframe = false
        if let attachments = attachments {
            if let attachment = attachments[0] as? NSDictionary {
                if let dependsOnOthers = attachment[kCMSampleAttachmentKey_DependsOnOthers] as? Bool {
                    isKeyframe = !dependsOnOthers
                }
            }
        }

        if isKeyframe {

            // Send the SPS and PPS.
            if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
                var vpsSize: Int = 0
                var spsSize: Int = 0
                var ppsSize: Int = 0
                var parmCount: Int = 0
                var vps: UnsafePointer<UInt8>?
                var sps: UnsafePointer<UInt8>?
                var pps: UnsafePointer<UInt8>?

                switch enc.codecType {
                case kCMVideoCodecType_H264:
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &sps, &spsSize, &parmCount, nil)
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 1, &pps, &ppsSize, &parmCount, nil)
                case kCMVideoCodecType_HEVC:
                    if #available(iOS 11.0, *) {
                        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 0, &vps, &vpsSize, &parmCount, nil)
                        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 1, &sps, &spsSize, &parmCount, nil)
                        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 2, &pps, &ppsSize, &parmCount, nil)
                    } else {
                        Logger.error("unsupported codec type: \(enc.codecType)")
                        return
                    }
                default:
                    Logger.error("unsupported codec type: \(enc.codecType)")
                    return
                }

                if let vps = vps {
                    var vps_buf: [UInt8] = .init()
                    vps_buf.reserveCapacity(vpsSize + 4)

                    withUnsafeBytes(of: &vpsSize) {
                        vps_buf.append(contentsOf: $0[..<4])
                    }
                    vps_buf.append(contentsOf: UnsafeBufferPointer<UInt8>(start: vps, count: vpsSize))

                    enc.compressionSessionOutput(&vps_buf, size: vps_buf.count, pts: pts, dts: dts, isKey: isKeyframe)
                }

                if let sps = sps, let pps = pps {
                    var sps_buf: [UInt8] = .init()
                    sps_buf.reserveCapacity(spsSize + 4)
                    var pps_buf: [UInt8] = .init()
                    pps_buf.reserveCapacity(ppsSize + 4)

                    withUnsafeBytes(of: &spsSize) {
                        sps_buf.append(contentsOf: $0[..<4])
                    }
                    sps_buf.append(contentsOf: UnsafeBufferPointer<UInt8>(start: sps, count: spsSize))

                    withUnsafeBytes(of: &ppsSize) {
                        pps_buf.append(contentsOf: $0[..<4])
                    }
                    pps_buf.append(contentsOf: UnsafeBufferPointer<UInt8>(start: pps, count: ppsSize))

                    enc.compressionSessionOutput(&sps_buf, size: sps_buf.count, pts: pts, dts: dts, isKey: isKeyframe)
                    enc.compressionSessionOutput(&pps_buf, size: pps_buf.count, pts: pts, dts: dts, isKey: isKeyframe)
                }
            }
        }

        var bufferData: UnsafeMutablePointer<Int8>?
        var size: Int = 0
        CMBlockBufferGetDataPointer(block, 0, nil, &size, &bufferData)

        guard let ptr = bufferData else {
            Logger.debug("unexpected return")
            return
        }
        enc.compressionSessionOutput(ptr, size: size, pts: pts, dts: dts, isKey: isKeyframe)
    }

    init(frame_w: Int,
         frame_h: Int,
         fps: Int,
         bitrate: Int,
         keyframeInterval: Int,
         codecType: CMVideoCodecType,
         useBaseline: Bool = true,
         ctsOffset: CMTime = .init(value: 0, timescale: VC_TIME_BASE)) {
        self.frameW = frame_w
        self.frameH = frame_h
        self.fps = fps
        self.keyframeInterval = keyframeInterval
        self._bitrate = bitrate
        self.codecType = codecType
        self.ctsOffset = ctsOffset

        setupCompressionSession(useBaseline)
    }

    deinit {
        teardownCompressionSession()
    }

    open func pixelBufferPool() -> CVPixelBufferPool? {
        guard let compressionSession = compressionSession else {
            Logger.debug("unexpected return")
            return nil
        }
        return VTCompressionSessionGetPixelBufferPool(compressionSession)
    }

    /*! ITransform */
    open func setOutput(_ output: IOutput) {
        self.output = output
    }

    // Input is expecting a CVPixelBufferRef
    open func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        guard let compressionSession = compressionSession else {
            Logger.debug("unexpected return")
            return
        }

        encodeQueue.sync {
            let session = compressionSession

            let pts = metadata.pts + ctsOffset
            let dur: CMTime = .init(value: 1, timescale: Int32(fps))
            var flags: VTEncodeInfoFlags = .init()

            var frameProps: [String: Any]?

            if forceKeyframe {
                VTEncode.s_forcedKeyframePTS = pts.value

                frameProps = [
                    kVTEncodeFrameOptionKey_ForceKeyFrame as String: true
                ]
            }

            let ref = data.assumingMemoryBound(to: CVPixelBuffer.self).pointee
            VTCompressionSessionEncodeFrame(session, ref, pts, dur, frameProps as NSDictionary?, nil, &flags)

            if forceKeyframe {
                frameProps = nil
                forceKeyframe = false
            }

        }
    }

    open func requestKeyframe() {
        forceKeyframe = true
    }

    open func compressionSessionOutput(_ data: UnsafeMutableRawPointer,
                                       size: Int,
                                       pts: CMTime,
                                       dts: CMTime,
                                       isKey: Bool) {
        if let l = output, size > 0 {
            let md: VideoBufferMetadata = .init(pts: pts, dts: dts)
            md.isKey = isKey
            l.pushBuffer(data, size: size, metadata: md)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func setupCompressionSession(_ useBaseline: Bool) {
        self.baseline = useBaseline

        // swiftlint:disable:next line_length
        // Parts of this code pulled from https://github.com/galad87/HandBrake-QuickSync-Mac/blob/2c1332958f7095c640cbcbcb45ffc955739d5945/libhb/platform/macosx/encvt_h264.c
        // More info from WWDC 2014 Session 513

        encodeQueue.sync {
            var err: OSStatus = noErr
            var encoderSpecifications: [String: Any]?

            #if !os(iOS)
                /** iOS is always hardware-accelerated **/
                switch codecType {
                case kCMVideoCodecType_H264:
                    encoderSpecifications = [
                        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
                        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
                        kVTVideoEncoderSpecification_EncoderID as String: "com.apple.videotoolbox.videoencoder.h264.gva"
                    ]
                case kCMVideoCodecType_HEVC:
                    encoderSpecifications = [
                        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
                        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
                        kVTVideoEncoderSpecification_EncoderID as String: "com.apple.videotoolbox.videoencoder.hevc.gva"
                    ]
                default:
                    Logger.error("unsupported codec type: \(enc.codecType)")
                    return
                }
            #endif
            var sessionOut: VTCompressionSession?
            autoreleasepool {
                let pixelBufferOptions: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: frameW,
                    kCVPixelBufferHeightKey as String: frameH,
                    kCVPixelBufferOpenGLESCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]

                err = VTCompressionSessionCreate(
                    kCFAllocatorDefault,
                    Int32(frameW),
                    Int32(frameH),
                    codecType,
                    encoderSpecifications as NSDictionary?,
                    pixelBufferOptions as NSDictionary?,
                    nil,
                    vtCallback,
                    UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                    &sessionOut)

            }

            guard let session = sessionOut else {
                Logger.debug("unexpected return")
                return
            }
            if err == noErr {
                compressionSession = session

                err = VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                           NSNumber(value: keyframeInterval))
            }

            if err == noErr {
                err = VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
            }

            if err == noErr {
                let allowFrameReodering = useBaseline ? kCFBooleanFalse : kCFBooleanTrue
                err = VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, allowFrameReodering)
            }

            if err == noErr {
                err = VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: _bitrate))
            }

            if err == noErr {
                err = VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
            }

            if err == noErr {
                let profileLevel: NSString

                switch codecType {
                case kCMVideoCodecType_H264:
                    profileLevel = useBaseline ? kVTProfileLevel_H264_Baseline_AutoLevel :
                    kVTProfileLevel_H264_Main_AutoLevel
                case kCMVideoCodecType_HEVC:
                    if #available(iOS 11.0, *) {
                        profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel
                    } else {
                        Logger.error("unsupported codec type: \(codecType)")
                        return
                    }
                default:
                    Logger.error("unsupported codec type: \(codecType)")
                    return
                }

                err = VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, profileLevel)
            }
            if codecType == kCMVideoCodecType_H264 {
                if !useBaseline {
                    VTSessionSetProperty(session, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
                }
            }
            if err == noErr {
                VTCompressionSessionPrepareToEncodeFrames(session)
            }
        }
    }

    private func teardownCompressionSession() {
        guard let compressionSession = compressionSession else {
            Logger.debug("unexpected return")
            return
        }
        VTCompressionSessionInvalidate(compressionSession)
        self.compressionSession = nil
    }
}
