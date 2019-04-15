//
//  VCTypes.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/29/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import Foundation

public enum VCSessionState {
    case none
    case previewStarted
    case starting
    case started
    case ended
    case error
    case reconnecting
}

public enum VCCameraState {
    case front
    case back
}

public enum VCAspectMode: Int {
    case fit
    case fill
}

public enum VCVideoCodecType: Int {
    case h264
    case hevc
}
