//
//  SRTLogSupport.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/03/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

public enum SRTLogLevel: Int {
    case alert
    case crit
    case debug
    case emerg
    case err
    case info
    case notice
    case warning

    func setLogLevel() {
        let logLevel: Int32
        switch self {
        case .alert:
            logLevel = LOG_ALERT
        case .crit:
            logLevel = LOG_CRIT
        case .debug:
            logLevel = LOG_DEBUG
        case .emerg:
            logLevel = LOG_EMERG
        case .err:
            logLevel = LOG_ERR
        case .info:
            logLevel = LOG_INFO
        case .notice:
            logLevel = LOG_NOTICE
        case .warning:
            logLevel = LOG_WARNING
        }
        srt_setloglevel(logLevel)
    }
}

public struct SRTLogFAs: OptionSet {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let general   = SRTLogFAs([])
    public static let bstats    = SRTLogFAs(rawValue: 1 << 0)
    public static let control   = SRTLogFAs(rawValue: 1 << 1)
    public static let data      = SRTLogFAs(rawValue: 1 << 2)
    public static let tsbpd     = SRTLogFAs(rawValue: 1 << 3)
    public static let rexmit    = SRTLogFAs(rawValue: 1 << 4)
    public static let haicrypt  = SRTLogFAs(rawValue: 1 << 5)
    public static let congest   = SRTLogFAs(rawValue: 1 << 6)

    public static let all: SRTLogFAs = [.bstats, .control, .data, .tsbpd, .rexmit, .haicrypt]

    public func setLogFA() {
        if self.contains(.bstats) {
            srt_addlogfa(SRT_LOGFA_BSTATS)
        }
        if self.contains(.control) {
            srt_addlogfa(SRT_LOGFA_CONTROL)
        }
        if self.contains(.data) {
            srt_addlogfa(SRT_LOGFA_DATA)
        }
        if self.contains(.tsbpd) {
            srt_addlogfa(SRT_LOGFA_TSBPD)
        }
        if self.contains(.rexmit) {
            srt_addlogfa(SRT_LOGFA_REXMIT)
        }
        if self.contains(.haicrypt) {
            srt_addlogfa(SRT_LOGFA_HAICRYPT)
        }
        if self.contains(.congest) {
            srt_addlogfa(SRT_LOGFA_CONGEST)
        }
    }
}
