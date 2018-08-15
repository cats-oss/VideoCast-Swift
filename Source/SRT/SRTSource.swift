//
//  SRTSource.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/29/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import Foundation

class SrtSource: SrtCommon {
    static var counter: UInt32 = 1
    var hostport_copy: String = ""

    var isOpen: Bool {
        return isUsable
    }

    var end: Bool {
        return isBroken
    }

    static func create(_ url: String, pollid: Int32?) throws -> SrtSource {
        let ret = try parseSrtUri(url)
        return try .init(ret.host, port: ret.port, par: ret.par, pollid: pollid)
    }

    init(_ host: String, port: Int, par: [String: String], pollid: Int32?) throws {
        try super.init(host, port: port, par: par, dir_output: false, pollid: pollid)
        hostport_copy = "\(host):\(port)"
    }

    override init() {
        // Do nothing - create just to prepare for use
        super.init()
    }

    func read(_ chunk: Int, data: inout [Int8]) throws -> Bool {
        if data.count < chunk {
            data = .init(repeating: 0, count: chunk)
        }

        let ready: Bool = true
        var stat: Int32

        repeat {
            stat = srt_recvmsg(sock, &data, Int32(chunk))
            if stat == SRT_ERROR {
                // EAGAIN for SRT READING
                if srt_getlasterror(nil) == SRT_EASYNCRCV.rawValue {
                    data.removeAll()
                    return false
                }
                try error(udtGetLastError(), src: "recvmsg")
            }

            if stat == 0 {
                throw SRTError.readEOF(message: hostport_copy)
            }
        } while !ready

        let chunk = MemoryLayout.size(ofValue: stat)
        if chunk < data.count {
            data = .init(repeating: 0, count: chunk)
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
            printSrtStats(Int(sock), mon: &perf)
            clear_stats = SrtConf.transmit_total_stats ? 0 : 1
        }

        SrtSource.counter += 1

        return true
    }

    func getSRTSocket() -> SRTSOCKET {
        var socket = self.socket
        if socket == SRT_INVALID_SOCK {
            socket = listener
        }
        return socket
    }
}
