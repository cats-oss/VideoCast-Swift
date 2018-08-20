//
//  IOutputSession.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/05.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

public typealias BandwidthCallback = (
    _ rateVector: Float,
    _ estimatedAvailableBandwidth: Float,
    _ immediateThroughput: Int) -> Int
public typealias StopSessionCallback = () -> Void

public protocol IOutputSession: IOutput {
    func setSessionParameters(_ parameters: IMetaData)
    func setBandwidthCallback(_ callback: @escaping BandwidthCallback)
    func stop(_ callback: @escaping StopSessionCallback)
}
