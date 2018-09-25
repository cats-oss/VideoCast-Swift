//
//  Logger.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/01.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import os.log

class Logger {
    struct LogFlags: OptionSet {
        let rawValue: Int

        static let error    = LogFlags(rawValue: 1 << 0)
        static let warn     = LogFlags(rawValue: 1 << 1)
        static let info     = LogFlags(rawValue: 1 << 2)
        static let debug    = LogFlags(rawValue: 1 << 3)
        static let verbose  = LogFlags(rawValue: 1 << 4)

        static let levelError: LogFlags = [.error]
        static let levelWarn: LogFlags = [.error, .warn]
        static let levelInfo: LogFlags = [.error, .warn, .info]
        static let levelDebug: LogFlags = [.error, .warn, .info, .debug]
        static let levelVerbose: LogFlags = [.error, .warn, .info, .debug, .verbose]
    }

    struct LogLevel: OptionSet {
        let rawValue: Int

    }

    @available(iOS 10.0, *)
    static let general = OSLog(subsystem: "jp.co.cyberagent.videocast", category: "general")

#if DEBUG
    static let levelDef: LogFlags = .levelDebug
#else
    static let levelDef: LogFlags = .levelInfo
#endif

    static let asyncEnabled = true

    static let asyncError   = false && Logger.asyncEnabled
    static let asyncWarn    = true && Logger.asyncEnabled
    static let asyncInfo    = true && Logger.asyncEnabled
    static let asyncDebug   = true && Logger.asyncEnabled
    static let asyncVerbose = true && Logger.asyncEnabled

    static let queue: DispatchQueue = .init(label: "jp.co.cyberagent.VideoCast.logger", qos: .background)

    class func error<T>(_ message: @autoclosure () -> T,
                        file: String = #file,
                        function: String = #function,
                        line: Int = #line ) {
        Logger.log(synchronous: asyncError,
                   level: levelDef,
                   flag: .error,
                   ctx: 0,
                   file: file,
                   function: function,
                   line: line,
                   message: message)
    }

    class func warn<T>(_ message: @autoclosure () -> T,
                       file: String = #file,
                       function: String = #function,
                       line: Int = #line ) {
        Logger.log(synchronous: asyncWarn,
                   level: levelDef,
                   flag: .warn,
                   ctx: 0,
                   file: file,
                   function: function,
                   line: line,
                   message: message)
    }

    class func info<T>(_ message: @autoclosure () -> T,
                       file: String = #file,
                       function: String = #function,
                       line: Int = #line ) {
        Logger.log(synchronous: asyncInfo,
                   level: levelDef,
                   flag: .info,
                   ctx: 0,
                   file: file,
                   function: function,
                   line: line,
                   message: message)
    }

    class func debug<T>(_ message: @autoclosure () -> T,
                        file: String = #file,
                        function: String = #function,
                        line: Int = #line ) {
        Logger.log(synchronous: asyncDebug,
                   level: levelDef,
                   flag: .debug,
                   ctx: 0,
                   file: file,
                   function: function,
                   line: line,
                   message: message)
    }

    class func verbose<T>(_ message: @autoclosure () -> T,
                          file: String = #file,
                          function: String = #function,
                          line: Int = #line ) {
        Logger.log(synchronous: asyncVerbose,
                   level: levelDef,
                   flag: .verbose,
                   ctx: 0,
                   file: file,
                   function: function,
                   line: line,
                   message: message)
    }

    class func log<T>(
        synchronous: Bool,
        level: LogFlags,
        flag: LogFlags,
        ctx: Int,
        file: String,
        function: String,
        line: Int,
        message: @autoclosure () -> T) {
        if level.contains(flag) {
            let message = message()
            let logging = {
                if #available(iOS 10.0, *) {
                    let type: OSLogType
                    switch flag {
                    case .error:
                        type = .error
                    case .warn:
                        type = .info
                    case .info:
                        type = .info
                    case .debug:
                        type = .debug
                    case .verbose:
                        type = .debug
                    default:
                        type = .default
                    }
                    os_log("%{public}@", log: general, type: type, "[\(file)] [\(function)] [\(line)] : \(message)")
                    //NSLog("%@", "[\(file)] [\(function)] [\(line)] : \(message)")
                } else {
                    print("[\(Logger.dateToString(Date()))] [\(file)] [\(function)] [\(line)] : \(message)")
                }
            }
            if synchronous {
                queue.sync {
                    logging()
                }
            } else {
                queue.async {
                    logging()
                }
            }
        }
    }

    class func dateToString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.string(from: date)
    }

    class func dumpBuffer(_ desc: String, buf: UnsafePointer<UInt8>, size: Int, sep: String = " ", breaklen: Int = 16) {
        var hexBuf: String = ""
        hexBuf.reserveCapacity(size * 4 + 1)

        for i in 0..<size {
            hexBuf += String(format: "%02x", buf[i]) + sep
            if i % breaklen == breaklen-1 {
                hexBuf += "\n"
            }
        }
        Logger.debug("\(desc):\n\(hexBuf)")
    }
}
