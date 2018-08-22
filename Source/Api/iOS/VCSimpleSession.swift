//
//  VCSimpleSession.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/05.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import AVFoundation
import UIKit

open class VCSimpleSession {
    var pbOutput: PixelBufferOutput?
    var micSource: MicSource?
    var cameraSource: CameraSource?
    var pixelBufferSource: PixelBufferSource?
    var pbAspect: AspectTransform?
    var pbPosition: PositionTransform?

    var videoSplit: Split?
    var aspectTransform: AspectTransform?
    var atAspectMode: AspectTransform.AspectMode = .fill
    var positionTransform: PositionTransform?
    var audioMixer: AudioMixer?
    var videoMixer: IVideoMixer?
    var vtEncoder: IEncoder?
    var aacEncoder: IEncoder?
    var h264Packetizer: ITransform?
    var aacPacketizer: ITransform?

    var aacSplit: Split?
    var vtSplit: Split?
    var muxer: MP4Multiplexer?

    var outputSession: IOutputSession?

    var adtsEncoder: ITransform?
    var annexbEncoder: ITransform?
    var tsMuxer: TSMultiplexer?
    var fileSink: FileSink?

    let graphManagementQueue = DispatchQueue(label: "jp.co.cyberagent.VideoCast.session.graph")
    let minVideoBitrate = 32000

    var bpsCeiling = 0

    private var _torch = false
    private var _audioChannelCount = 1
    private var _audioSampleRate: Float = 48000
    private var _micGain: Float = 1
    private var _cameraState: VCCameraState

    open var sessionState = VCSessionState.none {
        didSet {
            if Thread.isMainThread {
                delegate.connectionStatusChanged?(sessionState)
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let strongSelf = self else { return }
                    strongSelf.delegate.connectionStatusChanged?(strongSelf.sessionState)
                }
            }
        }
    }

    open var previewView: VCPreviewView

    open var videoSize: CGSize {
        didSet {
            aspectTransform?.setBoundingSize(boundingWidth: Int(videoSize.width), boundingHeight: Int(videoSize.height))
            positionTransform?.setSize(
                width: Int(Float(videoSize.width) * videoZoomFactor),
                height: Int(Float(videoSize.height) * videoZoomFactor)
            )
        }
    }
    open var bitrate: Int        // Change will not take place until the next Session
    open var fps: Int            // Change will not take place until the next Session
    open var videoCodecType: VCVideoCodecType   // Change will not take place until the next Session
    open let useInterfaceOrientation: Bool
    open var cameraState: VCCameraState {
        get { return _cameraState }
        set {
            if _cameraState != newValue {
                _cameraState = cameraState
                cameraSource?.toggleCamera()
            }
        }
    }
    open var orientationLocked: Bool = false {
        didSet { cameraSource?.orientationLocked = orientationLocked }
    }
    open var torch: Bool {
        get { return _torch }
        set { _torch = cameraSource?.setTorch(newValue) ?? newValue }
    }
    open var videoZoomFactor: Float = 1 {
        didSet {
            positionTransform?.setSize(
                width: Int(Float(videoSize.width) * videoZoomFactor),
                height: Int(Float(videoSize.height) * videoZoomFactor)
            )
        }
    }
    open var audioChannelCount: Int {
        get { return _audioChannelCount }
        set {
            _audioChannelCount = max(1, min(newValue, 2))
            audioMixer?.setChannelCount(_audioChannelCount)
        }
    }
    open var audioSampleRate: Float {
        get { return _audioSampleRate }
        set {
            _audioSampleRate = newValue
            audioMixer?.setFrequencyInHz(newValue)
        }
    }
    open var micGain: Float {      // [0..1]
        get { return _micGain }
        set {
            if let audioMixer = audioMixer, let micSource = micSource {
                audioMixer.setSourceGain(WeakRefISource(value: micSource), gain: micGain)
            }
            _micGain = newValue
        }
    }
    open var focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) {   // (0,0) is top-left, (1,1) is bottom-right
        didSet {
            cameraSource?.setFocusPointOfInterest(x: Float(focusPointOfInterest.x), y: Float(focusPointOfInterest.y))
        }
    }
    open var exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) {
        didSet {
            cameraSource?.setExposurePointOfInterest(x: Float(exposurePointOfInterest.x),
                                                     y: Float(exposurePointOfInterest.y))
        }
    }
    open var continuousAutofocus = false {
        didSet {
            cameraSource?.setContinuousAutofocus(continuousAutofocus)
        }
    }
    open var continuousExposure = true {
        didSet {
            cameraSource?.setContinuousExposure(continuousExposure)
        }
    }
    open var useAdaptiveBitrate = false { /* Default is off */
        didSet {
            bpsCeiling = bitrate
        }
    }
    open internal(set) var estimatedThroughput = 0    /* Bytes Per Second. */
    open var aspectMode: VCAspectMode {
        didSet {
            switch aspectMode {
            case .fill:
                atAspectMode = .fill
            case .fit:
                atAspectMode = .fit
            }
        }
    }
    open var filter: VCFilter = .normal {    /* Default is normal */
        didSet {
            guard let videoMixer = videoMixer, let cameraSource = cameraSource else {
                return Logger.debug("unexpected return")
            }

            let filterName: String
            switch filter {
            case .normal:
                filterName = "jp.co.cyberagent.VideoCast.filters.bgra"
            case .gray:
                filterName = "jp.co.cyberagent.VideoCast.filters.grayscale"
            case .invertColors:
                filterName = "jp.co.cyberagent.VideoCast.filters.invertColors"
            case .sepia:
                filterName = "jp.co.cyberagent.VideoCast.filters.sepia"
            case .fisheye:
                filterName = "jp.co.cyberagent.VideoCast.filters.fisheye"
            case .glow:
                filterName = "jp.co.cyberagent.VideoCast.filters.glow"
            }

            Logger.info("FILTER IS : \(filter)")

            if let videoFilter = videoMixer.filterFactory.filter(name: filterName) as? IVideoFilter {
                videoMixer.setSourceFilter(WeakRefISource(value: cameraSource), filter: videoFilter)
            }
        }
    }

    // swiftlint:disable:next weak_delegate
    open let delegate: VCSessionDelegate

    public init(
        videoSize: CGSize,
        frameRate fps: Int,
        bitrate bps: Int,
        videoCodecType: VCVideoCodecType = .h264,
        useInterfaceOrientation: Bool = false,
        cameraState: VCCameraState = .back,
        aspectMode: VCAspectMode = .fit,
        delegate: VCSessionDelegate = .init()) {
        self.delegate = delegate

        self.bitrate = bps
        self.videoSize = videoSize
        self.fps = fps
        self.videoCodecType = videoCodecType
        self.useInterfaceOrientation = useInterfaceOrientation
        self.aspectMode = aspectMode

        self.previewView = .init()

        self._cameraState = cameraState

        graphManagementQueue.async { [weak self] in
            self?.setupGraph()
        }
    }

    deinit {
        endSession()
        audioMixer?.stop()
        audioMixer = nil
        videoMixer?.stop()
        videoMixer = nil
        videoSplit = nil
        aspectTransform = nil
        positionTransform = nil
        micSource = nil
        cameraSource = nil
        pbOutput = nil
    }

    open func startRtmpSession(url: String, streamKey: String) {
        graphManagementQueue.async { [weak self] in
            self?.startRtmpSessionInternal(url: url, streamKey: streamKey)
        }
    }

    open func startSRTSession(url: String) {
        graphManagementQueue.async { [weak self] in
            self?.startSRTSessionInternal(url: url)
        }
    }

    open func endSession() {
        h264Packetizer = nil
        aacPacketizer = nil

        if let vtEncoder = vtEncoder {
            videoSplit?.removeOutput(vtEncoder)
        }

        vtEncoder = nil
        aacEncoder = nil

        muxer?.stop {
            self.muxer = nil
        }

        outputSession?.stop {
            self.outputSession = nil
        }

        annexbEncoder = nil
        adtsEncoder = nil
        tsMuxer = nil
        fileSink = nil

        bitrate = bpsCeiling

        sessionState = .ended
    }

    open func getCameraPreviewLayer(_ previewLayer: inout AVCaptureVideoPreviewLayer) {
        if let cameraSource = cameraSource {
            cameraSource.getPreviewLayer(&previewLayer)
        }
    }

    // swiftlint:disable:next function_body_length
    open func addPixelBufferSource(image: UIImage, rect: CGRect) {
        guard let cgImage = image.cgImage, let videoMixer = videoMixer else {
            return Logger.debug("unexpected return")
        }

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

        var pixelBuffer: CVPixelBuffer? = nil

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

        let pbAspect = AspectTransform(boundingWidth: Int(rect.size.width),
                                       boundingHeight: Int(rect.size.height), aspectMode: .fit)
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
}
