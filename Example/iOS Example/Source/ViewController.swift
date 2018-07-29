//
//  ViewController.swift
//  iOS Example
//
//  Created by Tomohiro Matsuzawa on 2018/01/05.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import VideoCast
import UIKit

class ViewController: UIViewController {

    @IBOutlet weak var previewView: UIView!
    @IBOutlet weak var btnConnect: UIButton!

    var session = VCSimpleSession(
        videoSize: CGSize(width: 720, height: 408),
        frameRate: 30,
        bitrate: 1000000,
        videoCodecType: .h264,
        useInterfaceOrientation: false
    )

    /*var session = VCSimpleSession(
        videoSize: CGSize(width: 1280, height: 720),
        frameRate: 30,
        bitrate: 1500000,
        videoCodecType: .hevc,
        useInterfaceOrientation: false
    )*/

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.

        previewView.addSubview(session.previewView)
        session.previewView.frame = previewView.bounds

        let delegate = session.delegate

        delegate.connectionStatusChanged = { [weak self] sessionState in
            guard let strongSelf = self else { return }

            switch strongSelf.session.sessionState {
            case .starting:
                strongSelf.btnConnect.setTitle("Connecting", for: .normal)

            case .started:
                strongSelf.btnConnect.setTitle("Disconnect", for: .normal)

            default:
                strongSelf.btnConnect.setTitle("Connect", for: .normal)
            }
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    deinit {
        btnConnect = nil
        previewView = nil
    }

    @IBAction func btnConnectTouch(_ sender: AnyObject) {
        switch session.sessionState {
        case .none, .previewStarted, .ended, .error:
            session.startRtmpSession(
                url: "rtmp://localhost/live",
                streamKey: "myStream"
            )
            /*session.startSRTSession(
                url: "srt://localhost:5000?streamid=myStream"
            )*/

        default:
            session.endSession()
        }
    }

    @IBAction func btnFilterTouch(_ sender: AnyObject) {
        switch self.session.filter {

        case .normal:
            self.session.filter = .gray

        case .gray:
            self.session.filter = .invertColors

        case .invertColors:
            self.session.filter = .sepia

        case .sepia:
            self.session.filter = .fisheye

        case .fisheye:
            self.session.filter = .glow

        case .glow:
            self.session.filter = .normal
        }
    }
}
