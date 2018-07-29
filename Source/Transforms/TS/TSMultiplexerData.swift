//
//  TSMultiplexerData.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/28/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import Foundation
import CoreMedia
import AVFoundation

extension TSMultiplexer {
    class MpegTSService {
        var pmt: MpegTSSection = .init()  /* MPEG-2 PMT table context */
        var sid: Int = 0
        var name: String = ""
        var provider_name: String = ""
        var pcr_pid: Int = 0x1fff
        var pcr_packet_count: Int = 0
        var pcr_packet_period: Int = 0
    }

    struct MpegTSFlags: OptionSet {
        let rawValue: UInt8

        init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        // Reemit PAT/PMT before writing the next packet
        static let resend_headers           = MpegTSFlags(rawValue: 0x01)
        // Use LATM packetization for AAC
        static let latm                     = MpegTSFlags(rawValue: 0x02)
        // Reemit PAT and PMT at each video frame
        static let pat_pmt_at_frames        = MpegTSFlags(rawValue: 0x04)
        // Conform to System B (DVB) instead of System A (ATSC)
        static let system_b                 = MpegTSFlags(rawValue: 0x08)
        // Mark initial packets as discontinuous
        static let initial_discontinuity    = MpegTSFlags(rawValue: 0x10)
    }

    class MpegTSWriteStream {
        var service: MpegTSService?
        var pid: Int = 0    /* stream associated pid */
        var cc: Int = 15
        var discontinuity: Bool = false
        var first_pts_check: Bool = true   ///< first pts check needed
        var prev_payload_key: Bool = false
        var payload_pts: CMTime?
        var payload_dts: CMTime?
        var key: Bool = false
        var payload: [UInt8] = .init()
        var user_tb: CMTime = .init()
    }
}
