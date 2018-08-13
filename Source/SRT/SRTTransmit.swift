//
//  SRTTransmit.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/03/06.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

enum SRTError: Error {
    case invalidArgument(message: String)
    case runtime(message: String)
    case transmission(message: String)
    case readEOF(message: String)
}

class SrtConf {
    static var transmit_total_stats: Bool = false
    static var transmit_bw_report: UInt32 = 0
    static var transmit_stats_report: UInt32 = 0
    static var transmit_chunk_size: Int32 = SRT_LIVE_DEF_PLSIZE
}
