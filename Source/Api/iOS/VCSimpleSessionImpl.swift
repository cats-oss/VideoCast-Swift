//
//  VCSimpleSessionImpl.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/29/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import UIKit
import CoreMedia

// swiftlint:disable file_length
extension VCSimpleSession {
    final class PixelBufferOutput: IOutput {
        typealias PixelBufferCallback = (_ data: UnsafeRawPointer, _ size: Int) -> Void

        var callback: PixelBufferCallback

        init(callback: @escaping PixelBufferCallback) {
            self.callback = callback
        }

        func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
            callback(data, size)
        }
    }

    var applicationDocumentsDirectory: String? {
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        let basePath = (!paths.isEmpty) ? paths[0] : nil
        return basePath
    }

    // swiftlint:disable:next function_body_length
    func setupGraph() {
        let frameDuration = 1 / Double(fps)

        // Add audio mixer
        let aacPacketTime = 1024 / Double(audioSampleRate)

        let audioMixer = AudioMixer(outChannelCount: audioChannelCount,
                                    outFrequencyInHz: Int(audioSampleRate), outBitsPerChannel: 16,
                                    frameDuration: aacPacketTime)
        self.audioMixer = audioMixer

        // The H.264 Encoder introduces about 2 frames of latency,
        // so we will set the minimum audio buffer duration to 2 frames.
        audioMixer.setMinimumBufferDuration(frameDuration * 2)

        // Add video mixer
        videoMixer = MetalVideoMixer(frame_w: Int(videoSize.width), frame_h: Int(videoSize.height),
                                     frameDuration: frameDuration)

        let videoSplit = Split()

        self.videoSplit = videoSplit

        if !screencast {
            let pbOutput = PixelBufferOutput(callback: { [weak self, previewView] (data: UnsafeRawPointer, _: Int)  in
                guard let strongSelf = self else { return }

                let pixelBuffer = data.assumingMemoryBound(to: CVPixelBuffer.self).pointee
                previewView.drawFrame(pixelBuffer)

                if strongSelf.sessionState == .none {
                    strongSelf.sessionState = .previewStarted
                }
            })
            self.pbOutput = pbOutput

            videoSplit.setOutput(pbOutput)
        }

        videoMixer?.setOutput(videoSplit)

        // Create sources
        if screencast {
            let videoSampleSource = VideoSampleSource()
            self.videoSampleSource = videoSampleSource
            let aspectTransform = AspectTransform(boundingWidth: Int(videoSize.width),
                                                  boundingHeight: Int(videoSize.height), aspectMode: atAspectMode)

            let positionTransform = PositionTransform(
                x: Int(videoSize.width / 2), y: Int(videoSize.height / 2),
                width: Int(Float(videoSize.width) * videoZoomFactor),
                height: Int(Float(videoSize.height) * videoZoomFactor),
                contextWidth: Int(videoSize.width), contextHeight: Int(videoSize.height)
            )

            self.videoSampleSource?.setOutput(aspectTransform)

            guard let videoMixer = self.videoMixer,
                let filter = videoMixer.filterFactory.filter(
                    name: "jp.co.cyberagent.VideoCast.filters.bgra") as? IVideoFilter else {
                        return Logger.debug("unexpected return")
            }

            let delay = TimeInterval(0.5)

            videoMixer.setSourceFilter(WeakRefISource(value: videoSampleSource), filter: filter)
            self.filter = .normal
            aspectTransform.setOutput(positionTransform)
            positionTransform.setOutput(videoMixer)
            self.aspectTransform = aspectTransform
            self.positionTransform = positionTransform

            // Add audio source
            let audioAppSampleSource = AudioSampleSource()
            self.audioAppSampleSource = audioAppSampleSource
            let audioAppSampleSmoother = Smoother(delay: delay)
            self.audioAppSampleSmoother = audioAppSampleSmoother

            let audioMicSampleSource = AudioSampleSource()
            self.audioMicSampleSource = audioMicSampleSource
            let audioMicSampleSmoother = Smoother(delay: delay)
            self.audioMicSampleSmoother = audioMicSampleSmoother

            audioAppSampleSource.setOutput(audioAppSampleSmoother)
            audioAppSampleSmoother.setOutput(audioMixer)
            audioMixer.registerSource(audioAppSampleSource)

            audioMicSampleSource.setOutput(audioMicSampleSmoother)
            audioMicSampleSmoother.setOutput(audioMixer)
            audioMixer.registerSource(audioMicSampleSource)

            audioAppSampleSmoother.start()
            audioMicSampleSmoother.start()

            videoMixer.setDelay(delay: delay)
        } else {
            // Add camera source
            let cameraSource = CameraSource()
            self.cameraSource = cameraSource
            cameraSource.orientationLocked = orientationLocked
            let aspectTransform = AspectTransform(boundingWidth: Int(videoSize.width),
                                                  boundingHeight: Int(videoSize.height), aspectMode: atAspectMode)

            let positionTransform = PositionTransform(
                x: Int(videoSize.width / 2), y: Int(videoSize.height / 2),
                width: Int(Float(videoSize.width) * videoZoomFactor),
                height: Int(Float(videoSize.height) * videoZoomFactor),
                contextWidth: Int(videoSize.width), contextHeight: Int(videoSize.height)
            )

            cameraSource.setupCamera(fps: fps, useFront: cameraState == .front,
                                     useInterfaceOrientation: useInterfaceOrientation, sessionPreset: nil) {
                                        self.cameraSource?.setContinuousAutofocus(true)
                                        self.cameraSource?.setContinuousExposure(true)

                                        self.cameraSource?.setOutput(aspectTransform)

                                        guard let videoMixer = self.videoMixer,
                                            let filter = videoMixer.filterFactory.filter(
                                                name: "jp.co.cyberagent.VideoCast.filters.bgra") as? IVideoFilter else {
                                                    return Logger.debug("unexpected return")
                                        }

                                        videoMixer.setSourceFilter(WeakRefISource(value: cameraSource), filter: filter)
                                        self.filter = .normal
                                        aspectTransform.setOutput(positionTransform)
                                        positionTransform.setOutput(videoMixer)
                                        self.aspectTransform = aspectTransform
                                        self.positionTransform = positionTransform

                                        // Inform delegate that camera source has been added
                                        self.delegate.didAddCameraSource?(self)
            }

            // Add mic source
            micSource = MicSource(sampleRate: Double(audioSampleRate), preferedChannelCount: audioChannelCount)
            micSource?.setOutput(audioMixer)
        }

        let epoch = Date()

        audioMixer.setEpoch(epoch)
        videoMixer?.setEpoch(epoch)

        audioMixer.start()
        videoMixer?.start()
    }

    // swiftlint:disable:next function_body_length
    func addEncodersAndPacketizers() {
        guard let outputSession = outputSession else {
            return Logger.debug("unexpected return")
        }

        let ctsOffset = CMTime(value: 2, timescale: Int32(fps))  // 2 * frame duration

        // Add encoders

        let aacEncoder =
            AACEncode(frequencyInHz: Int(audioSampleRate), channelCount: audioChannelCount,
                      averageBitrate: audioChannelCount > 1 ? 105000 : 88000)
        self.aacEncoder = aacEncoder

        let vtEncoder = VTEncode(
            frame_w: Int(videoSize.width),
            frame_h: Int(videoSize.height),
            fps: fps,
            bitrate: bitrate,
            keyframeInterval: keyframeInterval,
            codecType: videoCodecType == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
            useBaseline: false,
            ctsOffset: ctsOffset
        )
        self.vtEncoder = vtEncoder

        audioMixer?.setOutput(aacEncoder)
        videoSplit?.setOutput(vtEncoder)

        self.delegate.bitrateChanged?(vtEncoder.bitrate, aacEncoder.bitrate)

        let aacSplit = Split()
        self.aacSplit = aacSplit
        let vtSplit = Split()
        self.vtSplit = vtSplit
        aacEncoder.setOutput(aacSplit)
        vtEncoder.setOutput(vtSplit)

        if outputSession is RTMPSession {
            let h264Packetizer = H264Packetizer(ctsOffset: ctsOffset)
            self.h264Packetizer = h264Packetizer
            let aacPacketizer =
                AACPacketizer(sampleRate: Int(audioSampleRate),
                              channelCount: audioChannelCount, ctsOffset: ctsOffset)
            self.aacPacketizer = aacPacketizer

            vtSplit.setOutput(h264Packetizer)
            aacSplit.setOutput(aacPacketizer)

            h264Packetizer.setOutput(outputSession)
            aacPacketizer.setOutput(outputSession)
        }

        /*
         muxer = .init()
         if let applicationDocumentsDirectory = applicationDocumentsDirectory, let muxer = muxer  {
         let params: MP4SessionParameters = .init()
         let file = applicationDocumentsDirectory + "/output.mp4"
         params.data = (file, fps, Int(videoSize.width),
         Int(videoSize.height),
         videoCodecType == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC)
         muxer.setSessionParameters(params)
         aacSplit.setOutput(muxer)
         vtSplit.setOutput(muxer)
         }
         */

        if outputSession is SRTSession {
            var streamIndex = 0
            let videoStream = TSMultiplexer.Stream(
                id: 0,
                mediaType: .video,
                videoCodecType: videoCodecType == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
                timeBase: CMTime(value: 1, timescale: CMTimeScale(fps))
            )
            let codecType = videoCodecType == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
            annexbEncoder = AnnexbEncode(streamIndex,
                                         codecType: codecType)
            streamIndex += 1
            let audioStream = TSMultiplexer.Stream(
                id: 1, mediaType: .audio, videoCodecType: nil,
                timeBase: CMTime(value: 1, timescale: CMTimeScale(audioSampleRate)))
            adtsEncoder = ADTSEncode(streamIndex)

            let streams = [videoStream, audioStream]
            tsMuxer = TSMultiplexer(streams, ctsOffset: ctsOffset)

            if let tsMuxer = tsMuxer, let adtsEncoder = adtsEncoder, let annexbEncoder = annexbEncoder {
                tsMuxer.setOutput(outputSession)

                adtsEncoder.setOutput(tsMuxer)
                annexbEncoder.setOutput(tsMuxer)

                aacSplit.setOutput(adtsEncoder)
                vtSplit.setOutput(annexbEncoder)

                /*
                 fileSink = .init()
                 if let applicationDocumentsDirectory = applicationDocumentsDirectory, let fileSink = fileSink {
                 let params: FileSinkSessionParameters = .init()
                 let file = applicationDocumentsDirectory + "/output.ts"
                 params.data = (file, nil)
                 fileSink.setSessionParameters(params)
                 
                 tsMuxer.setOutput(fileSink)
                 }*/

            }
        }
    }

    func startSRTSessionInternal(url: String) {
        let outputSession = SRTSession(uri: url) { [weak self] _, state  in
            guard let strongSelf = self else { return }

            Logger.info("ClientState: \(state)")

            switch state {
            case .connecting:
                if strongSelf.sessionState != .reconnecting {
                    strongSelf.sessionState = .starting
                }
            case .connected:
                if strongSelf.sessionState != .reconnecting {
                    strongSelf.graphManagementQueue.async { [weak strongSelf] in
                        strongSelf?.addEncodersAndPacketizers()
                    }
                }
                strongSelf.sessionState = .started
                strongSelf.sessionStarted = true
            case .error:
                strongSelf.sessionState = .error
                strongSelf.endSession()
            case .notConnected:
                strongSelf.sessionState = .ended
                strongSelf.endSession()
            case .reconnecting:
                strongSelf.sessionState = .reconnecting
            case .none:
                break
            }
        }

        startOutputSessionCommon(outputSession)

        let sessionParameters = SRTSessionParameters()

        sessionParameters.data = (
            chunk: SRT_LIVE_DEF_PLSIZE,
            loglevel: .err,
            logfa: .general,
            logfile: "",
            internal_log: true,
            autoreconnect: autoreconnect,
            reconnectPeriod: reconnectPeriod,
            quiet: false
        )

        outputSession.setSessionParameters(sessionParameters)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func startRtmpSessionInternal(url: String, streamKey: String) {
        let uri = url + "/" + streamKey

        let startReconnecting = { () -> Bool in
            if self.sessionStarted && self.autoreconnect {
                if let outputSession = self.outputSession as? RTMPSession {
                    outputSession.reset()
                    DispatchQueue.global().asyncAfter(deadline: .now() + self.reconnectPeriod, execute: { [weak self] in
                        if let outputSession = self?.outputSession as? RTMPSession {
                            outputSession.connectServer()
                        }
                    })
                    self.sessionState = .reconnecting
                    return true
                }
            }
            return false
        }

        let outputSession = RTMPSession(uri: uri) { [weak self] (_, state)  in
            guard let strongSelf = self else { return }

            Logger.info("ClientState: \(state)")

            switch state {
            case .connected:
                if strongSelf.sessionState != .reconnecting {
                    strongSelf.sessionState = .starting
                }
            case .sessionStarted:
                strongSelf.graphManagementQueue.async { [weak strongSelf] in
                    strongSelf?.addEncodersAndPacketizers()
                }
                strongSelf.sessionState = .started
                strongSelf.sessionStarted = true
            case .error:
                if !startReconnecting() {
                    strongSelf.sessionState = .error
                    strongSelf.endSession()
                }
            case .notConnected:
                if !startReconnecting() {
                    strongSelf.sessionState = .ended
                    strongSelf.endSession()
                }
            default:
                break
            }
        }

        startOutputSessionCommon(outputSession)

        let sessionParameters = RTMPSessionParameters()

        sessionParameters.data = (
            width: Int(videoSize.width),
            height: Int(videoSize.height),
            frameDuration: 1 / Double(fps),
            videoBitrate: bitrate,
            audioFrequency: Double(audioSampleRate),
            stereo: audioChannelCount == 2
        )

        outputSession.setSessionParameters(sessionParameters)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func startOutputSessionCommon(_ outputSession: IOutputSession) {
        self.outputSession = outputSession

        bpsCeiling = bitrate

        if useAdaptiveBitrate {
            bitrate = min(500000, bpsCeiling)
        }

        outputSession.setBandwidthCallback {[weak self] vector, predicted, byterate in
            guard let strongSelf = self else { return 0 }

            strongSelf.estimatedThroughput = Int(predicted)

            guard let video = strongSelf.vtEncoder else { return 0 }

            strongSelf.delegate.detectedThroughput?(Int(predicted), video.bitrate, byterate * 8 )

            guard let audio = strongSelf.aacEncoder,
                strongSelf.useAdaptiveBitrate else { return 0 }

            let bytesPerSec = { (video.bitrate + audio.bitrate) / 8 }

            guard vector != 0 else { return bytesPerSec() }

            let vector = vector < 0 ? -1 : 1

            let videoBR = video.bitrate
            let audioBR = audio.bitrate

            let setAudioBitrate = { (videoBr: Int) in
                switch videoBr {
                case 500001...:
                    audio.bitrate = strongSelf.audioChannelCount > 1 ? 128000 : 108000
                case 250001...500000:
                    audio.bitrate = strongSelf.audioChannelCount > 1 ? 108000 : 80000
                default:
                    audio.bitrate = strongSelf.audioChannelCount > 1 ? 78000 : 52000
                }
            }

            if outputSession is SRTSession && predicted < Float(bytesPerSec()) {
                let bwe = predicted * 8
                let bitrate = Int(Double(bwe) / kBitrateRatio)

                setAudioBitrate(bitrate)

                let availableVideoBitrate = bitrate - audio.bitrate
                video.bitrate = max(Int(Float(availableVideoBitrate)), strongSelf.minVideoBitrate)
            } else {
                let videoBr = video.bitrate

                setAudioBitrate(videoBr)

                switch videoBr {
                case 1152001...:
                    video.bitrate = min(Int(videoBr / 384000 + vector) * 384000, strongSelf.bpsCeiling)
                case 512001...:
                    video.bitrate = min(Int(videoBr / 128000 + vector) * 128000, strongSelf.bpsCeiling)
                case 128001...:
                    video.bitrate = min(Int(videoBr / 64000 + vector) * 64000, strongSelf.bpsCeiling)
                default:
                    video.bitrate = max(min(Int(videoBr / 32000 + vector) * 32000,
                                            strongSelf.bpsCeiling), strongSelf.minVideoBitrate)
                }
            }

            if videoBR != video.bitrate || audioBR != audio.bitrate {
                strongSelf.delegate.bitrateChanged?(video.bitrate, audio.bitrate)
            }
            Logger.info("\n(\(vector)) AudioBR: \(audio.bitrate) VideoBR: \(video.bitrate) (\(predicted))")

            return bytesPerSec()
        }
    }

    func updatePreview() {
        previewView.flipX = _mirrorPreview ? _cameraState == .front : false
    }

    // swiftlint:disable:next function_body_length
    func addPixelBufferSourceInternal(image: UIImage, rect: CGRect, aspectMode: VCAspectMode = .fit) {
        guard let cgImage = image.cgImage, let videoMixer = videoMixer else {
            return Logger.debug("unexpected return")
        }

        resetPixelBufferSourceInternal()

        let pixelBufferSource = PixelBufferSource(
            width: cgImage.width,
            height: cgImage.height,
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        self.pixelBufferSource = pixelBufferSource

        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let options: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        var pixelBuffer: CVPixelBuffer?

        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, options as CFDictionary?, &pixelBuffer)

        CVPixelBufferLockBaseAddress(pixelBuffer!, [])

        let pixelData = CVPixelBufferGetBaseAddress(pixelBuffer!)

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        let context = CGContext(
            data: pixelData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )

        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let aspectMode: AspectTransform.AspectMode = aspectMode == .fit ? .fit : .fill
        let pbAspect = AspectTransform(boundingWidth: Int(rect.size.width),
                                       boundingHeight: Int(rect.size.height), aspectMode: aspectMode)
        self.pbAspect = pbAspect

        let pbPosition = PositionTransform(
            x: Int(rect.origin.x),
            y: Int(rect.origin.y),
            width: Int(rect.size.width),
            height: Int(rect.size.height),
            contextWidth: Int(videoSize.width),
            contextHeight: Int(videoSize.height)
        )
        self.pbPosition = pbPosition

        pixelBufferSource.setOutput(pbAspect)
        pbAspect.setOutput(pbPosition)
        pbPosition.setOutput(videoMixer)
        videoMixer.registerSource(pixelBufferSource)
        pixelBufferSource.pushPixelBuffer(data: pixelData!, size: width * height * 4)

        CVPixelBufferUnlockBaseAddress(pixelBuffer!, [])
    }

    func resetPixelBufferSourceInternal() {
        if let pixelBufferSource = self.pixelBufferSource {
            videoMixer?.unregisterSource(pixelBufferSource)
        }

        pbPosition = nil
        pbAspect = nil
        self.pixelBufferSource = nil
    }
}
