//
//  SRTTarget.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/29/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import Foundation

class SrtTarget: SrtCommon {
    static var counter: UInt32 = 1

    var isOpen: Bool {
        return isUsable
    }

    var broken: Bool {
        return isBroken
    }

    static func create(_ url: String, pollid: Int32? = nil) throws -> SrtTarget {
        let ret = try parseSrtUri(url)
        return try .init(ret.host, port: ret.port, par: ret.par, pollid: pollid)
    }

    init(_ host: String, port: Int, par: [String: String], pollid: Int32?) throws {
        try super.init(host, port: port, par: par, dir_output: true, pollid: pollid)
    }

    override init() {
        super.init()
    }

    override func configurePre(_ sock: SRTSOCKET) -> Int32 {
        var result = super.configurePre(sock)
        if result == -1 {
            return result
        }

        var yes: Int32 = 1
        // This is for the HSv4 compatibility; if both parties are HSv5
        // (min. version 1.2.1), then this setting simply does nothing.
        // In HSv4 this setting is obligatory; otherwise the SRT handshake
        // extension will not be done at all.
        result = srt_setsockopt(sock, 0, SRTO_SENDER, &yes, Int32(MemoryLayout.size(ofValue: yes)))
        if result == -1 {
            return result
        }

        return 0
    }

    func write(_ data: UnsafePointer<Int8>, size: Int) throws -> Bool {
        let stat = srt_sendmsg2(sock, data, Int32(size), nil)
        if stat == SRT_ERROR {
            if blocking_mode {
                try error(udtGetLastError(), src: "srt_sendmsg")
            }
            return false
        }

        var perf: CBytePerfMon = .init()
        srt_bstats(sock, &perf, clear_stats)
        clear_stats = 0

        if SrtConf.transmit_bw_report > 0 &&
            (SrtSource.counter % SrtConf.transmit_bw_report) == SrtConf.transmit_bw_report - 1 {
            Logger.info("+++/+++SRT BANDWIDTH: \(perf.mbpsBandwidth)")
        }
        if SrtConf.transmit_stats_report > 0 &&
            (SrtSource.counter % SrtConf.transmit_stats_report) == SrtConf.transmit_stats_report - 1 {
            printSrtStats(Int(sock), mon: perf)
            clear_stats = SrtConf.transmit_total_stats ? 0 : 1
        }

        SrtSource.counter += 1

        return true
    }

    func still() -> Int {
        var bytes: Int = 0
        let st = srt_getsndbuffer(sock, nil, &bytes)
        if st == -1 {
            return 0
        }
        return bytes
    }

    func getSRTSocket() -> SRTSOCKET {
        var socket = self.socket
        if socket == SRT_INVALID_SOCK {
            socket = listener
        }
        return socket
    }
}
