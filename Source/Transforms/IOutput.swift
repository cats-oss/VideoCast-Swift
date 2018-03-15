//
//  IOutput.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/05.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

public protocol IOutput: class {
    func setEpoch(_ epoch: Date)
    func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData)
}

extension IOutput {
    public func setEpoch(_ epoch: Date) {
    }
}
