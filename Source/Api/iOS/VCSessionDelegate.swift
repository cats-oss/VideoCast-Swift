//
//  VCSessionDelegate.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/05.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

open class VCSessionDelegate: NSObject {
    open var connectionStatusChanged: ((_ sessionState: VCSessionState) -> Void)?
    open var didAddCameraSource: ((_ session: VCSimpleSession) -> Void)?
    open var detectedThroughput: ((_ throughputInBytesPerSecond: Int, _ rate: Int) -> Void)?
    
    public override init() {
        super.init()
    }
}
