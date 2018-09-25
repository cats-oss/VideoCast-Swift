//
//  SampleHandler.swift
//  Video Cast
//
//  Created by Tomohiro Matsuzawa on 2018/09/21.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import VideoCast
import ReplayKit

class SampleHandler: VCSampleHandler {
    override var screencastConfig: VCScreencastConfig? {
        let server = ServerModel.shared.server
        let option = OptionsModel.shared
        let broadcastURL = URL(string: server.url)!
        
        return VCScreencastConfig(
            broadcastURL: broadcastURL,
            streamName: server.streamName,
            videoSize: getVideoSize(),
            fps: option.framerate,
            bitrate: option.bitrate,
            keyframeInterval: option.keyframeInterval,
            useAdaptiveBitrate: option.bitrateMode == .automatic)
    }
    
    private func getVideoSize() -> CGSize {
        let (width, height) = OptionsModel.shared.videoSizes[OptionsModel.shared.videoSizeIndex]
        return OptionsModel.shared.orientation == .landscape ?
            CGSize(width: width, height: height) :
            CGSize(width: height, height: width)
    }
}
