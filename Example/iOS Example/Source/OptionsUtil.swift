//
//  OptionsUtil.swift
//  iOS Example
//
//  Created by Tomohiro Matsuzawa on 2018/09/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import VideoCast

class OptionsUtil {
    enum SelectOption: Int {
        case bitrate
        case videoSize
        case videoCodec
        case orientation
    }

    static func getBitrateLabel(_ index: Int) -> String {
        return "\(OptionsModel.shared.bitrates[index] / 1000) kbits"
    }

    static func getVideoSizeLabel(_ index: Int) -> String {
        let text: String
        let (width, height) = OptionsModel.shared.videoSizes[index]
        switch height {
        case 720:
            text = "HD (720p)"
        case 1080:
            text = "HD (1080p)"
        case 2160:
            text = "UHD (2160p)"
        default:
            text = "\(width)x\(height)"
        }
        return text
    }

    static func getVideoCodecLabel(_ index: Int) -> String {
        guard let videoCodec = VCVideoCodecType(rawValue: index) else { return "" }
        switch videoCodec {
        case .h264:
            return "H264"
        case .hevc:
            return "HEVC"
        }
    }

    static func getOrientationLabel(_ index: Int) -> String {
        guard let orientation = Orientation(rawValue: index) else { return "" }
        switch orientation {
        case .default:
            return "Default"
        case .landscape:
            return "Landscape"
        case .portrait:
            return "Portrait"
        }
    }
}
