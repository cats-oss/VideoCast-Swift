//
//  IStreamSession.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/30.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

public struct StreamStatus: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let connected            = StreamStatus(rawValue: 1)
    public static let writeBufferHasSpace  = StreamStatus(rawValue: 1 << 1)
    public static let readBufferHasBytes   = StreamStatus(rawValue: 1 << 2)
    public static let errorEncountered     = StreamStatus(rawValue: 1 << 3)
    public static let endStream            = StreamStatus(rawValue: 1 << 4)
}

public typealias StreamSessionCallback = (IStreamSession, StreamStatus) -> Void

public protocol IStreamSession {
    var status: StreamStatus { get }

    func connect(host: String, port: Int, sscb callback: @escaping StreamSessionCallback)
    func disconnect()
    func write(_ buffer: UnsafePointer<UInt8>, size: Int) -> Int
    func read(_ buffer: UnsafeMutablePointer<UInt8>, size: Int) -> Int
}
