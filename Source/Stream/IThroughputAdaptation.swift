//
//  IThroughputAdaptation.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/31.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

// ratio - stream bitrate / available bandwidth
public let kBitrateRatio: Double = 1.5

public typealias ThroughputCallback = (
    _ bitrateRecommendedVector: Float,
    _ predictedBytesPerSecond: Float,
    _ immediateBytesPerSecond: Int) -> Int

public protocol IThroughputAdaptation {
    func setThroughputCallback(_ callback: @escaping ThroughputCallback)
    func addSentBytesSample(_ bytesSent: Int)
    func addBufferSizeSample(_ bufferSize: Int)
    func addBufferDurationSample(_ bufferDuration: Int64)
    func reset()
    func start()
    func stop()
}
