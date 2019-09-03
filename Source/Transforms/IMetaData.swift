//
//  IMetaData.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/05.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import CoreMedia

public protocol IMetaData {
    var pts: CMTime { get }
    var dts: CMTime { get }
    var streamIndex: Int { get set }
    var isKey: Bool { get set }

    init()
    init(ts: CMTime)
    init(pts: CMTime, dts: CMTime)
}

open class MetaData<Types>: IMetaData {
    open var pts: CMTime
    open var dts: CMTime
    open var streamIndex: Int = 0
    open var isKey: Bool = false

    open var data: Types!

    convenience public required init() {
        self.init(pts: CMTime.zero, dts: CMTime.zero)
    }

    convenience public required init(ts: CMTime) {
        self.init(pts: ts, dts: ts)
    }

    public required init(pts: CMTime, dts: CMTime) {
        self.pts = pts
        self.dts = dts
    }
}
