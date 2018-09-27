//
//  VCSampleHandler.swift
//  VideoCast iOS
//
//  Created by Tomohiro Matsuzawa on 2018/09/21.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import ReplayKit

@available(iOS 10.0, *)
open class VCSampleHandler: RPBroadcastSampleHandler {
    private var session: VCSimpleSession?
    open var errorNoConfigFound: NSError {
        let userInfo = [NSLocalizedFailureReasonErrorKey: "No broadcast config found"]
        return NSError(domain: "RPBroadcastErrorDomain", code: 401, userInfo: userInfo)
    }

    open var errorInvalidURL: NSError {
        let userInfo = [NSLocalizedFailureReasonErrorKey: "Invalid URL"]
        return NSError(domain: "RPBroadcastErrorDomain", code: 402, userInfo: userInfo)
    }

    open var errorConnection: NSError {
        let userInfo = [NSLocalizedFailureReasonErrorKey: "Failed to connect the server"]
        return NSError(domain: "RPBroadcastErrorDomain", code: 403, userInfo: userInfo)
    }

    open var errorDisconnected: NSError {
        let userInfo = [NSLocalizedFailureReasonErrorKey: "Disconnected from the server"]
        return NSError(domain: "RPBroadcastErrorDomain", code: 403, userInfo: userInfo)
    }

    open var screencastConfig: VCScreencastConfig? {
        return nil
    }

    // User has requested to start the broadcast
    override open func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let config = screencastConfig else {
            finishBroadcastWithError(errorNoConfigFound)
            return
        }
        let session = VCSimpleSession(
            videoSize: config.videoSize,
            frameRate: config.fps,
            bitrate: config.bitrate,
            videoCodecType: config.videoCodecType,
            useInterfaceOrientation: true,
            cameraState: .back,
            aspectMode: config.aspectMode,
            screencast: true)
        self.session = session
        session.keyframeInterval = config.keyframeInterval
        session.useAdaptiveBitrate = config.useAdaptiveBitrate
        session.audioSampleRate = 44100

        let url = config.broadcastURL.absoluteString

        if url.starts(with: "rtmp") {
            session.startRtmpSession(
                url: url,
                streamKey: config.streamName
            )
        } else if url.starts(with: "srt") {
            guard var urlComponents = URLComponents(string: url) else { return }
            var items = urlComponents.queryItems ?? []
            items.append(URLQueryItem(name: "streamid", value: config.streamName))
            urlComponents.queryItems = items

            session.startSRTSession(
                url: urlComponents.url!.absoluteString
            )
        } else {
            finishBroadcastWithError(errorInvalidURL)
        }

        let delegate = session.delegate

        delegate.connectionStatusChanged = { [weak self] sessionState in
            guard let strongSelf = self else { return }

            switch sessionState {
            case .error:
                strongSelf.finishBroadcastWithError(strongSelf.errorConnection)
            case .ended:
                strongSelf.finishBroadcastWithError(strongSelf.errorDisconnected)
            default:
                break
            }
        }
    }

    // User has requested to finish the broadcast
    override open func broadcastFinished() {
        session?.endSession()
        session = nil
    }

    // Handle the sample buffer here
    override open func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                           with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            session?.pushVideo(sampleBuffer)
        case .audioApp:
            // Handle audio sample buffer for app audio
            //session?.pushAudioApp(sampleBuffer)
            break
        case .audioMic:
            // Handle audio sample buffer for mic audio
            session?.pushAudioMic(sampleBuffer)
        }
    }

    @available(iOS 11.2, *)
    override open func broadcastAnnotated(withApplicationInfo applicationInfo: [AnyHashable: Any]) {
        let bundleIdentifier = applicationInfo[RPApplicationInfoBundleIdentifierKey]
        if let bundleIdentifier = bundleIdentifier {
            Logger.info("broadcastAnnotated(\(bundleIdentifier))")
        }
    }
}
