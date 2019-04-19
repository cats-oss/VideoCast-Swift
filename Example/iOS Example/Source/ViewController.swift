//
//  ViewController.swift
//  iOS Example
//
//  Created by Tomohiro Matsuzawa on 2018/01/05.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import UIKit
import VideoCast
import ReplayKit.RPBroadcast

final class SampleFilter: BasicVideoFilter {
    override class var fragmentFunc: String {
        return "beauty_skin"
    }
}

class ViewController: UIViewController {

    @IBOutlet weak var previewView: UIView!
    @IBOutlet weak var btnFlash: UIButton!
    @IBOutlet weak var btnConnect: UIButton!
    @IBOutlet weak var lblBitrate: UILabel!
    @IBOutlet weak var pickerView: UIView!

    let imgFlashOn = UIImage(named: "icons8-flash-on-50")
    let imgFlashOff = UIImage(named: "icons8-flash-off-50")
    let imgRecordStart = UIImage(named: "icon-record-start")
    let imgRecordStop = UIImage(named: "icon-record-stop")

    var session: VCSimpleSession!
    var videoBitrate: Int = 0
    var audioBitrate: Int = 0

    var _connecting = false
    var connecting: Bool {
        get {
            return _connecting
        }
        set {
            if !_connecting && newValue {
                btnConnect.alpha = 1.0
                UIView.animate(withDuration: 0.1, delay: 0.0,
                               options: [.curveEaseInOut, .repeat, .autoreverse, .allowUserInteraction],
                               animations: {() -> Void in
                    self.btnConnect.alpha = 0.1
                }, completion: {(_: Bool) -> Void in
                })
            } else if connecting && !newValue {
                UIView.animate(withDuration: 0.1, delay: 0.0,
                               options: [.curveEaseInOut, .beginFromCurrentState],
                               animations: {() -> Void in
                    self.btnConnect.alpha = 1.0
                }, completion: {(_: Bool) -> Void in
                })
            }
            _connecting = newValue
        }
    }
    
    var isFiltered = false

    // swiftlint:disable function_body_length
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        initSession()
        lblBitrate.text = ""

        if #available(iOS 12.0, *) {
            #if !targetEnvironment(simulator)
            let broadcastPicker = RPSystemBroadcastPickerView(
                frame: CGRect(origin: CGPoint(), size: pickerView.frame.size))
            broadcastPicker.preferredExtension = Constants.screencastId
            pickerView.addSubview(broadcastPicker)
            #endif
        }

        let delegate = session.delegate

        delegate.connectionStatusChanged = { [weak self] sessionState in
            guard let strongSelf = self else { return }

            switch strongSelf.session.sessionState {
            case .starting, .reconnecting:
                strongSelf.connecting = true
                strongSelf.btnConnect.setImage(strongSelf.imgRecordStop, for: .normal)

            case .started:
                strongSelf.connecting = false
                strongSelf.btnConnect.setImage(strongSelf.imgRecordStop, for: .normal)

            case .previewStarted:
                break

            default:
                strongSelf.connecting = false
                strongSelf.btnConnect.setImage(strongSelf.imgRecordStart, for: .normal)
                strongSelf.session.videoSize = strongSelf.getVideoSize()
                strongSelf.lblBitrate.text = ""
            }
        }

        delegate.detectedThroughput = { [weak self] throughputInBytesPerSecond, videorate, oBitrate in
            guard let strongSelf = self else { return }
            let bitrateText = """
            bitrate: \(oBitrate / 1000) kbps
            video:   \(strongSelf.videoBitrate / 1000) kbps
            audio:   \(strongSelf.audioBitrate / 1000) kbps
            """
            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self else { return }

                strongSelf.lblBitrate.text = bitrateText
            }
        }

        delegate.bitrateChanged = { [weak self] videoBitrate, audioBitrate in
            self?.videoBitrate = videoBitrate
            self?.audioBitrate = audioBitrate
        }

        btnFlash.setImage(imgFlashOff, for: .normal)
        btnFlash.setImage(imgFlashOn, for: [.normal, .selected])
        updateFlashBtn()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    deinit {
        btnConnect = nil
        previewView = nil
    }

    override func viewWillAppear(_ animated: Bool) {
        navigationController?.setNavigationBarHidden(true, animated: false)
        refreshVideoSize()
    }

    override func viewWillDisappear(_ animated: Bool) {
        navigationController?.setNavigationBarHidden(false, animated: false)
    }

    override func viewDidLayoutSubviews() {
        session.previewView.frame = previewView.bounds
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        refreshVideoSize()
    }

    @IBAction func btnFlashTouch(_ sender: UIButton) {
        session.torch = !sender.isSelected
        updateFlashBtn()
    }

    @IBAction func btnSwitchCameraTouch(_ sender: UIButton) {
        let newState: VCCameraState
        switch session.cameraState {
        case .back:
            newState = .front
        case .front:
            newState = .back
        }
        session.cameraState = newState

        // try to set current torch state
        session.torch = session.torch
        updateFlashBtn()
    }

    @IBAction func btnConnectTouch(_ sender: AnyObject) {
        switch session.sessionState {
        case .none, .previewStarted, .ended, .error:
            session.bitrate = OptionsModel.shared.bitrate
            session.fps = OptionsModel.shared.framerate
            session.keyframeInterval = OptionsModel.shared.keyframeInterval
            session.useAdaptiveBitrate = OptionsModel.shared.bitrateMode == .automatic
            session.videoCodecType = OptionsModel.shared.videoCodec

            videoBitrate = 0
            audioBitrate = 0

            let server = ServerModel.shared.server

            if server.url.starts(with: "rtmp") {
                session.startRtmpSession(
                    url: server.url,
                    streamKey: server.streamName
                )
            }
            if server.url.starts(with: "srt") {
                guard var urlComponents = URLComponents(string: server.url) else { return }
                var items = urlComponents.queryItems ?? []
                items.append(URLQueryItem(name: "streamid", value: server.streamName))
                urlComponents.queryItems = items

                session.startSRTSession(
                    url: urlComponents.url!.absoluteString
                )
            }
        default:
            session.endSession()
        }
    }

    @IBAction func btnFilterTouch(_ sender: AnyObject) {
        isFiltered.toggle()
        self.session.filter = isFiltered ? SampleFilter() : BasicVideoFilterBGRA()
    }

    private func initSession() {
        session = VCSimpleSession(
            videoSize: getVideoSize(),
            frameRate: OptionsModel.shared.framerate,
            bitrate: OptionsModel.shared.bitrate,
            videoCodecType: OptionsModel.shared.videoCodec,
            useInterfaceOrientation: true,
            aspectMode: .fill
        )
        previewView.addSubview(session.previewView)
        session.previewView.frame = previewView.bounds
    }

    private func updateFlashBtn() {
        btnFlash.isSelected = session.torch
    }

    private func getVideoSize() -> CGSize {
        let (width, height) = OptionsModel.shared.videoSizes[OptionsModel.shared.videoSizeIndex]
        let isLandscape: Bool
        if OptionsModel.shared.orientation == .default {
            isLandscape = UIDevice.current.orientation.isLandscape
        } else {
            isLandscape = OptionsModel.shared.orientation == .landscape
        }
        return isLandscape ?
            CGSize(width: width, height: height) :
            CGSize(width: height, height: width)
    }

    private func refreshVideoSize() {
        switch session.sessionState {
        case .starting, .started, .reconnecting:
            break
        default:
            session.videoSize = getVideoSize()
        }
    }
}
