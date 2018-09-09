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
}

public enum VCCameraState {
    case front
    case back
}

public enum VCAspectMode {
    case fit
    case fill
}

public enum VCFilter {
    case normal
    case gray
    case invertColors
    case sepia
    case fisheye
    case glow
}

public enum VCVideoCodecType: Int {
    case h264
    case hevc
}
