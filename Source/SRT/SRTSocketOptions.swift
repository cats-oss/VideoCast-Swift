//
//  SRTSocketOptions.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/03/08.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

struct SRTOptionValue {
    var size: Int { return data.count }
    let data: Data

    init(_ data: Data) {
        self.data = data
    }
}

enum SRTOptionType: Int {
    case string = 0
    case int
    case int64
    case bool
    case enumeration
}

enum SRTOptionBinding: Int {
    case pre = 0
    case post
}

enum SRTOptionMode: Int {
    case failure = -1
    case listener = 0
    case caller = 1
    case rendezvous = 2
}

let enummap_transtype: [String: Any] = [
    "live": SRTT_LIVE,
    "file": SRTT_FILE
]

struct SRTSocketOption {
    var name: String
    var symbol: SRT_SOCKOPT
    var binding: SRTOptionBinding
    var type: SRTOptionType
    var valmap: [String: Any]?

    static let true_names: Set = ["1", "yes", "on", "true"]
    static let false_names: Set = ["0", "no", "off", "false"]

    func apply(_ socket: SRTSOCKET, value: String) -> Bool {
        var oo: SRTOptionValue?
        extract(type, value: value, o: &oo)
        guard let o = oo else { return false }
        let result = o.data.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
            return setso(socket, data: ptr, size: Int32(o.size))
        }
        return result != -1
    }

    private func setso(_ socket: SRTSOCKET, data: UnsafeRawPointer, size: Int32) -> Int32 {
        return srt_setsockopt(socket, 0, symbol, data, size)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func extract(_ type: SRTOptionType, value: String, o: inout SRTOptionValue?) {
        switch type {
        case .string:
            o = .init(value.data(using: String.Encoding.utf8)!)
        case .int:
            if var v = Int32(value) {
                o = .init(Data(bytes: &v, count: MemoryLayout.size(ofValue: v)))
            }
        case .int64:
            if var v = Int64(value) {
                o = .init(Data(bytes: &v, count: MemoryLayout.size(ofValue: v)))
            }
        case .bool:
            var v: Int32
            if SRTSocketOption.false_names.contains(value) {
                v = 0
            } else if SRTSocketOption.true_names.contains(value) {
                v = 1
            } else {
                break
            }
            o = .init(Data(bytes: &v, count: MemoryLayout.size(ofValue: v)))
        case .enumeration:
            if let valmap = valmap {
                // Search value in the map. If found, set to o.
                if var v = valmap[value] {
                    o = .init(Data(bytes: &v, count: MemoryLayout.size(ofValue: v)))
                    break
                }
            }

            // Fallback: try interpreting it as integer.
            if var v = Int32(value) {
                o = .init(Data(bytes: &v, count: MemoryLayout.size(ofValue: v)))
            }
        }
    }
}

let srtOptions: [SRTSocketOption] = [
    .init(name: "transtype", symbol: SRTO_TRANSTYPE, binding: .pre, type: .enumeration, valmap: enummap_transtype),
    .init(name: "maxbw", symbol: SRTO_MAXBW, binding: .pre, type: .int64, valmap: nil),
    .init(name: "pbkeylen", symbol: SRTO_PBKEYLEN, binding: .pre, type: .int, valmap: nil),
    .init(name: "passphrase", symbol: SRTO_PASSPHRASE, binding: .pre, type: .string, valmap: nil),

    .init(name: "mss", symbol: SRTO_MSS, binding: .pre, type: .int, valmap: nil),
    .init(name: "fc", symbol: SRTO_FC, binding: .pre, type: .int, valmap: nil),
    .init(name: "sndbuf", symbol: SRTO_SNDBUF, binding: .pre, type: .int, valmap: nil),
    .init(name: "rcvbuf", symbol: SRTO_RCVBUF, binding: .pre, type: .int, valmap: nil),
    .init(name: "ipttl", symbol: SRTO_IPTTL, binding: .pre, type: .int, valmap: nil),
    .init(name: "iptos", symbol: SRTO_IPTOS, binding: .pre, type: .int, valmap: nil),
    .init(name: "inputbw", symbol: SRTO_INPUTBW, binding: .post, type: .int64, valmap: nil),
    .init(name: "oheadbw", symbol: SRTO_OHEADBW, binding: .post, type: .int, valmap: nil),
    .init(name: "latency", symbol: SRTO_LATENCY, binding: .pre, type: .int, valmap: nil),
    .init(name: "tsbpdmode", symbol: SRTO_TSBPDMODE, binding: .pre, type: .bool, valmap: nil),
    .init(name: "tlpktdrop", symbol: SRTO_TLPKTDROP, binding: .pre, type: .bool, valmap: nil),
    .init(name: "snddropdelay", symbol: SRTO_SNDDROPDELAY, binding: .post, type: .int, valmap: nil),
    .init(name: "nakreport", symbol: SRTO_NAKREPORT, binding: .pre, type: .bool, valmap: nil),
    .init(name: "conntimeo", symbol: SRTO_CONNTIMEO, binding: .pre, type: .int, valmap: nil),
    .init(name: "lossmaxttl", symbol: SRTO_LOSSMAXTTL, binding: .pre, type: .int, valmap: nil),
    .init(name: "rcvlatency", symbol: SRTO_RCVLATENCY, binding: .pre, type: .int, valmap: nil),
    .init(name: "peerlatency", symbol: SRTO_PEERLATENCY, binding: .pre, type: .int, valmap: nil),
    .init(name: "minversion", symbol: SRTO_MINVERSION, binding: .pre, type: .int, valmap: nil),
    .init(name: "streamid", symbol: SRTO_STREAMID, binding: .pre, type: .string, valmap: nil),
    .init(name: "congestion", symbol: SRTO_CONGESTION, binding: .pre, type: .string, valmap: nil),
    .init(name: "messageapi", symbol: SRTO_MESSAGEAPI, binding: .pre, type: .bool, valmap: nil),
    .init(name: "payloadsize", symbol: SRTO_PAYLOADSIZE, binding: .pre, type: .int, valmap: nil),
    .init(name: "kmrefreshrate", symbol: SRTO_KMREFRESHRATE, binding: .pre, type: .int, valmap: nil),
    .init(name: "kmpreannounce", symbol: SRTO_KMPREANNOUNCE, binding: .pre, type: .int, valmap: nil),
    .init(name: "strictenc", symbol: SRTO_STRICTENC, binding: .pre, type: .bool, valmap: nil)
]

// swiftlint:disable:next cyclomatic_complexity
func srtConfigurePre(_ socket: SRTSOCKET,
                     host: String,
                     options: inout [String: String],
                     failures: inout [String]) -> SRTOptionMode {
    let mode: SRTOptionMode
    var modestr: String = "default"

    if let m = options["mode"] {
        modestr = m
    }

    if modestr == "client" || modestr == "caller" {
        mode = .caller
    } else if modestr == "server" || modestr == "listener" {
        mode = .listener
    } else if modestr == "default" {
        // Use the following convention:
        // 1. Server for source, Client for target
        // 2. If host is empty, then always server.
        if host == "" {
            mode = .listener
        } else {
            // Host is given, so check also "adapter"
            if options["adapter"] != nil {
                mode = .rendezvous
            } else {
                mode = .caller
            }
        }
    } else {
        mode = .failure
        failures.append("mode")
    }

    if let l = options["linger"] {
        let l_linger = Int32(l) ?? 0
        let l_onoff: Int32 = l_linger > 0 ? 1 : 0
        var lin = linger(l_onoff: l_onoff, l_linger: l_linger)
        srt_setsockopt(socket, Int32(SRTOptionBinding.pre.rawValue),
                       SRTO_LINGER, &lin, Int32(MemoryLayout.size(ofValue: lin)))
    }

    var all_clear: Bool = true
    for o in srtOptions {
        guard o.binding == .pre else { continue }
        if let value = options[o.name] {
            let ok = o.apply(socket, value: value)
            if !ok {
                failures.append(o.name)
                all_clear = false
            }
        }
    }

    return all_clear ? mode : .failure
}

func srtConfigurePost(_ socket: SRTSOCKET, options: [String: String], failures: inout [String]) {
    for o in srtOptions {
        guard o.binding == .post else { continue }
        if let value = options[o.name] {
            let ok = o.apply(socket, value: value)
            if !ok {
                failures.append(o.name)
            }
        }
    }
}
