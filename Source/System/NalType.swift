//
//  NalType.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/28/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import Foundation

enum NalType {
    case unknown
    case vps
    case sps
    case pps
}

func getNalTypeH264(_ data: UnsafePointer<UInt8>) -> (nalType: NalType, isVLC: Bool) {
    let nalType: NalType
    let isVLC: Bool
    let nalTypeByte = data[4] & 0x1F
    isVLC = nalTypeByte <= 5
    switch nalTypeByte {
    case 7:
        nalType = .sps
    case 8:
        nalType = .pps
    default:
        nalType = .unknown
    }
    return (nalType, isVLC)
}

func getNalTypeHEVC(_ data: UnsafePointer<UInt8>) -> (nalType: NalType, isVLC: Bool) {
    let nalType: NalType
    let isVLC: Bool
    let nalTypeByte = (data[4] & 0x7E) >> 1
    isVLC = nalTypeByte <= 31
    switch nalTypeByte {
    case 32:
        nalType = .vps
    case 33:
        nalType = .sps
    case 34:
        nalType = .pps
    default:
        nalType = .unknown
    }
    return (nalType, isVLC)
}
