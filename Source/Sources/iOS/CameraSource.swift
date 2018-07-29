//
//  CameraSource.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import AVFoundation
import GLKit

open class CameraSource: ISource {
    open var hashValue: Int {
        return ObjectIdentifier(self).hashValue
    }

    open static func == (lhs: CameraSource, rhs: CameraSource) -> Bool {
        return lhs.hashValue == rhs.hashValue
    }

    open var filter: IFilter?
    /*!
     * If the orientation is locked, we ignore device / interface
     * orientation changes.
     *
     * \return `true` is returned if the orientation is locked
     */
    open var orientationLocked: Bool = false

    private var matrix: GLKMatrix4 = GLKMatrix4Identity

    private weak var output: IOutput?

    private var captureSession: AVCaptureSession?
    private var captureDevice: AVCaptureDevice?
    private var callbackSession: SbCallback?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    private var fps: Int = 0
    private var torchOn: Bool = false
    private var useInterfaceOrientation: Bool = false

    public init() {

    }

    deinit {
        captureSession?.stopRunning()
        captureSession = nil
        if let callbackSession = callbackSession {
            NotificationCenter.default.removeObserver(callbackSession)
            self.callbackSession = nil
        }
        previewLayer = nil
    }

    /*!
     *  Get the AVCaptureVideoPreviewLayer associated with the camera output.
     *
     *  \param outAVCaputreVideoPreviewLayer a pointer to an AVCaptureVideoPreviewLayer pointer.
     */
    open func getPreviewLayer(_ outAVCaptureVideoPreviewLayer: inout AVCaptureVideoPreviewLayer) {
        if previewLayer == nil {
            autoreleasepool {
                guard let session = captureSession else {
                    Logger.debug("unexpected return")
                    return
                }
                let previewLayer = AVCaptureVideoPreviewLayer(session: session)
                previewLayer.videoGravity = .resizeAspectFill
                self.previewLayer = previewLayer
            }
        }
        guard let previewLayer = previewLayer else {
            Logger.debug("unexpected return")
            return
        }
        outAVCaptureVideoPreviewLayer = previewLayer
    }

    /*! ISource::setOutput */
    open func setOutput(_ output: IOutput) {
        self.output = output
    }

    /*!
     *  Setup camera properties
     *
     *  \param fps      Optional parameter to set the output frames per second.
     *  \param useFront Start with the front-facing camera
     *  \param useInterfaceOrientation whether to use interface or device orientation
     *          as reference for video capture orientation
     *  \param sessionPreset name of the preset to use for the capture session
     *  \param callbackBlock block to be called after everything is set
     */
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    open func setupCamera(fps: Int = 15, useFront: Bool = true,
                          useInterfaceOrientation: Bool = false,
                          sessionPreset: AVCaptureSession.Preset? = nil,
                          callback: (() -> Void)? = nil) {
        self.fps = fps
        self.useInterfaceOrientation = useInterfaceOrientation

        let permissions = { [weak self] (granted: Bool) in
            guard let strongSelf = self else { return }

            autoreleasepool {
                if granted {

                    let position: AVCaptureDevice.Position = useFront ? .front : .back

                    if let d = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                       for: AVMediaType.video, position: position) {
                        strongSelf.captureDevice = d
                        do {
                            try d.lockForConfiguration()
                            d.activeVideoMinFrameDuration = .init(value: 1, timescale: Int32(fps))
                            d.activeVideoMaxFrameDuration = .init(value: 1, timescale: Int32(fps))
                            d.unlockForConfiguration()
                        } catch {
                            Logger.error("Could not lock device for configuration: \(error)")
                        }

                        let session = AVCaptureSession()
                        if let sessionPreset = sessionPreset {
                            session.sessionPreset = sessionPreset
                        }
                        strongSelf.captureSession = session
                        session.beginConfiguration()

                        do {
                            let input = try AVCaptureDeviceInput(device: d)

                            let output = AVCaptureVideoDataOutput()

                            output.videoSettings =
                                [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

                            let callbackSession: SbCallback
                            if let cs = strongSelf.callbackSession {
                                callbackSession = cs
                            } else {
                                callbackSession = SbCallback()
                                callbackSession.source = self
                                strongSelf.callbackSession = callbackSession
                            }
                            let camQueue: DispatchQueue = .init(label: "jp.co.cyberagent.VideoCast.camera")

                            output.setSampleBufferDelegate(strongSelf.callbackSession, queue: camQueue)

                            if session.canAddInput(input) {
                                session.addInput(input)
                            }
                            if session.canAddOutput(output) {
                                session.addOutput(output)
                            }

                            strongSelf.reorientCamera()
                            session.commitConfiguration()
                            session.startRunning()

                            if strongSelf.orientationLocked {
                                if strongSelf.useInterfaceOrientation {
                                    NotificationCenter.default.addObserver(
                                        callbackSession,
                                        selector:
                                        #selector(type(of: callbackSession).orientationChanged(notification:)),
                                        name: .UIApplicationDidChangeStatusBarOrientation,
                                        object: nil)
                                } else {
                                    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                                    NotificationCenter.default.addObserver(
                                        callbackSession,
                                        selector:
                                        #selector(type(of: callbackSession).orientationChanged(notification:)),
                                        name: .UIDeviceOrientationDidChange, object: nil)
                                }
                            }
                        } catch {
                            Logger.error("Could not create video device input: \(error)")
                            session.commitConfiguration()
                        }
                    }
                    callback?()
                }
            }
        }
        autoreleasepool {
            let auth = AVCaptureDevice.authorizationStatus(for: .video)

            if auth == .authorized {
                permissions(true)
            } else if auth == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video, completionHandler: permissions)
            }
        }
    }

    /*!
     *  Toggle the camera between front and back-facing cameras.
     */
    open func toggleCamera() {

        guard let session = captureSession else {
            Logger.debug("unexpected return")
            return
        }

        session.beginConfiguration()
        do {
            try captureDevice?.lockForConfiguration()

            if !session.inputs.isEmpty {
                guard let currentCameraInput = session.inputs[0] as? AVCaptureDeviceInput else {
                    Logger.debug("unexpected return")
                    return
                }

                session.removeInput(currentCameraInput)
                captureDevice?.unlockForConfiguration()

                guard let newCamera = cameraWithPosition(
                    currentCameraInput.device.position == .back ? .front : .back) else {
                    Logger.debug("unexpected return")
                    return
                }

                let newVideoInput = try AVCaptureDeviceInput(device: newCamera)
                try newCamera.lockForConfiguration()
                session.addInput(newVideoInput)

                captureDevice = newCamera
                newCamera.unlockForConfiguration()
                session.commitConfiguration()
            }

            reorientCamera()
        } catch {
            Logger.error("Error while locking device for toggle camera: \(error)")
        }
    }

    /*!
     *  Attempt to turn the torch mode on or off.
     *
     *  \param torchOn  Bool indicating whether the torch should be on or off.
     *
     *  \return the actual state of the torch.
     */
    @discardableResult
    open func setTorch(_ torchOn: Bool) -> Bool {
        var ret = false
        guard let session = captureSession else {
            Logger.debug("unexpected return")
            return ret
        }

        session.beginConfiguration()

        if !session.inputs.isEmpty {
            guard let currentCameraInput = session.inputs[0] as? AVCaptureDeviceInput else {
                Logger.debug("unexpected return")
                return ret
            }

            if currentCameraInput.device.isTorchAvailable {
                do {
                    try currentCameraInput.device.lockForConfiguration()
                    currentCameraInput.device.torchMode = torchOn ? .on : .off
                    currentCameraInput.device.unlockForConfiguration()
                    ret = currentCameraInput.device.torchMode == .on
                } catch {
                    Logger.error("Error while locking device for torch: \(error)")
                    ret = false
                }
            } else {
                Logger.error("Torch not available in current camera input")
            }

        }

        session.commitConfiguration()
        self.torchOn = ret
        return ret
    }

    /*!
     *  Attempt to set the POI for focus.
     *  (0,0) represents top left, (1,1) represents bottom right.
     *
     *  \return Success. `false` is returned if the device doesn't support a POI.
     */
    @discardableResult
    open func setFocusPointOfInterest(x: Float, y: Float) -> Bool {
        guard let device = captureDevice else {
            Logger.debug("unexpected return")
            return false
        }

        var ret = device.isFocusPointOfInterestSupported

        if ret {
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = CGPoint(x: CGFloat(x), y: CGFloat(y))
                if device.focusMode == .locked {
                    device.focusMode = .autoFocus
                }
                device.unlockForConfiguration()
            } catch {
                Logger.error("Error while locking device for focus POI: \(error)")
                ret = false
            }
        } else {
            Logger.info("Focus POI not supported")
        }

        return ret
    }

    @discardableResult
    open func setContinuousAutofocus(_ wantsContinuous: Bool) -> Bool {
        guard let device = captureDevice else {
            Logger.debug("unexpected return")
            return false
        }
        let newMode: AVCaptureDevice.FocusMode = wantsContinuous ? .continuousAutoFocus : .autoFocus
        var ret = device.isFocusModeSupported(newMode)

        if ret {
            do {
                try device.lockForConfiguration()
                device.focusMode = newMode
                device.unlockForConfiguration()
            } catch {
                Logger.debug("Error while locking device for autofocus: \(error)")
                ret = false
            }
        } else {
            let mode = wantsContinuous ? AVCaptureDevice.FocusMode.continuousAutoFocus :
                AVCaptureDevice.FocusMode.autoFocus
            Logger.info("Focus mode not supported: \(mode)")
        }

        return ret
    }

    @discardableResult
    open func setExposurePointOfInterest(x: Float, y: Float) -> Bool {
        guard let device = captureDevice else {
            Logger.debug("unexpected return")
            return false
        }

        var ret = device.isExposurePointOfInterestSupported

        if ret {
            do {
                try device.lockForConfiguration()
                device.exposurePointOfInterest = CGPoint(x: CGFloat(x), y: CGFloat(y))
                device.unlockForConfiguration()
            } catch {
                Logger.error("Error while locking device for exposure POI: \(error)")
                ret = false
            }
        } else {
            Logger.info("Exposure POI not supported")
        }

        return ret
    }

    @discardableResult
    open func setContinuousExposure(_ wantsContinuous: Bool) -> Bool {
        guard let device = captureDevice else {
            Logger.debug("unexpected return")
            return false
        }
        let newMode: AVCaptureDevice.ExposureMode = wantsContinuous ? .continuousAutoExposure : .autoExpose
        var ret = device.isExposureModeSupported(newMode)

        if ret {
            do {
                try device.lockForConfiguration()
                device.exposureMode = newMode
                device.unlockForConfiguration()
            } catch {
                Logger.error("Error while locking device for exposure: \(error)")
                ret = false
            }
        } else {
            let mode = wantsContinuous ? AVCaptureDevice.ExposureMode.continuousAutoExposure :
                AVCaptureDevice.ExposureMode.autoExpose
            Logger.info("Exposure mode not supported: \(mode)")
        }

        return ret
    }

    /*! Used by Objective-C Capture Session */
    open func bufferCaptured(pixelBuffer: CVPixelBuffer) {
        guard let output = output else { return }

        let md = VideoBufferMetadata(ts: .init(value: 1, timescale: Int32(fps)))

        md.data = (1, matrix, false, WeakRefISource(value: self))

        var pb: IPixelBuffer = PixelBuffer(pixelBuffer, temporary: true)

        pb.state = .enqueued
        output.pushBuffer(&pb, size: MemoryLayout<PixelBuffer>.size, metadata: md)

    }

    /*! Used by Objective-C Device/Interface Orientation Notifications */
    // swiftlint:disable:next cyclomatic_complexity
    open func reorientCamera() {
        guard let session = captureSession else {
            Logger.debug("unexpected return")
            return
        }

        let orientation: UIInterfaceOrientation
        if useInterfaceOrientation {
            orientation = UIApplication.shared.statusBarOrientation
        } else {
            switch UIDevice.current.orientation {
            case .portrait:
                orientation = .portrait
            case .portraitUpsideDown:
                orientation = .portraitUpsideDown
            case .landscapeLeft:
                orientation = .landscapeLeft
            case .landscapeRight:
                orientation = .landscapeRight
            default:
                orientation = UIApplication.shared.statusBarOrientation
            }
        }

        for output in session.outputs {
            for av in output.connections {

                switch orientation {
                case .portraitUpsideDown:
                    if av.videoOrientation != .portraitUpsideDown {
                        av.videoOrientation = .portraitUpsideDown
                    }
                case .landscapeRight:
                    if av.videoOrientation != .landscapeRight {
                        av.videoOrientation = .landscapeRight
                    }
                case .landscapeLeft:
                    if av.videoOrientation != .landscapeLeft {
                        av.videoOrientation = .landscapeLeft
                    }
                case .portrait:
                    if av.videoOrientation != .portrait {
                        av.videoOrientation = .portrait
                    }
                default:
                    break
                }
            }
        }

        if torchOn {
            setTorch(torchOn)
        }
    }

    /*!
     * Get a camera with a specified position
     *
     * \param position The position to search for.
     *
     * \return the camera device, if found.
     */
    private func cameraWithPosition(_ position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: AVMediaType.video, position: position)
    }
}
