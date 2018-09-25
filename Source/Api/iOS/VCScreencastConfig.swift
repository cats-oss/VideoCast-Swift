//
//  VCScreencastSetupInfo.swift
//  VideoCast iOS
//
//  Created by Tomohiro Matsuzawa on 2018/09/21.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import CoreMedia

open class VCScreencastConfig: NSObject, NSCoding {
    private let broadcastURLKey = "broadcastURL"
    private let streamNameKey = "streamName"
    private let videoSizeKey = "videoSize"
    private let fpsKey = "fps"
    private let bitrateKey = "bitrate"
    private let videoCodecTypeKey = "videoCodecType"
    private let aspectModeKey = "aspectMode"
    private let keyframeIntervalKey = "keyframeInterval"
    private let useAdaptiveBitrateKey = "useAdaptiveBitrate"

    public let broadcastURL: URL
    public let streamName: String
    public let videoSize: CGSize
    public let fps: Int
    public let bitrate: Int
    public let videoCodecType: VCVideoCodecType
    public let aspectMode: VCAspectMode
    public let keyframeInterval: Int
    public let useAdaptiveBitrate: Bool

    public init(
        broadcastURL: URL,
        streamName: String,
        videoSize: CGSize,
        fps: Int,
        bitrate: Int,
        videoCodecType: VCVideoCodecType = .h264,
        aspectMode: VCAspectMode = .fit,
        keyframeInterval: Int,
        useAdaptiveBitrate: Bool
        ) {
        self.broadcastURL = broadcastURL
        self.streamName = streamName
        self.videoSize = videoSize
        self.fps = fps
        self.bitrate = bitrate
        self.videoCodecType = videoCodecType
        self.aspectMode = aspectMode
        self.keyframeInterval = keyframeInterval
        self.useAdaptiveBitrate = useAdaptiveBitrate
    }

    public required init?(coder aDecoder: NSCoder) {
        guard let str = aDecoder.decodeObject(forKey: broadcastURLKey) as? String,
            let url = URL(string: str) else { return nil }
        broadcastURL = url

        guard let name = aDecoder.decodeObject(forKey: streamNameKey) as? String else { return nil }
        streamName = name

        videoSize = aDecoder.decodeCGSize(forKey: videoSizeKey)
        fps = aDecoder.decodeInteger(forKey: fpsKey)
        bitrate = aDecoder.decodeInteger(forKey: bitrateKey)

        guard let type = VCVideoCodecType(rawValue:
            aDecoder.decodeInteger(forKey: videoCodecTypeKey)) else { return nil }
        videoCodecType = type

        guard let mode = VCAspectMode(rawValue:
            aDecoder.decodeInteger(forKey: aspectModeKey)) else { return nil }
        aspectMode = mode

        keyframeInterval = aDecoder.decodeInteger(forKey: keyframeIntervalKey)
        useAdaptiveBitrate = aDecoder.decodeBool(forKey: useAdaptiveBitrateKey)
    }

    public func encode(with encoder: NSCoder) {
        encoder.encode(broadcastURL.absoluteString, forKey: broadcastURLKey)
        encoder.encode(streamName, forKey: streamNameKey)
        encoder.encode(videoSize, forKey: videoSizeKey)
        encoder.encode(fps, forKey: fpsKey)
        encoder.encode(bitrate, forKey: bitrateKey)
        encoder.encode(videoCodecType.rawValue, forKey: videoCodecTypeKey)
        encoder.encode(aspectMode.rawValue, forKey: aspectModeKey)
        encoder.encode(keyframeInterval, forKey: keyframeIntervalKey)
        encoder.encode(useAdaptiveBitrate, forKey: useAdaptiveBitrateKey)
    }
}
