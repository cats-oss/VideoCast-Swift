//
//  SRTTarget.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/29/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import Foundation

class SrtTarget: SrtCommon {
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
            return false
        }

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
