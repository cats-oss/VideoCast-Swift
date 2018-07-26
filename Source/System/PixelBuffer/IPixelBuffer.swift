//
//  IPixelBuffer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/12.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

public typealias PixelBufferFormatType = OSType

public enum PixelBufferState {
    case available
    case dequeued
    case enqueued
    case acquired
}

public protocol IPixelBuffer {
    var width: Int { get }
    var height: Int { get }

    var pixelFormat: PixelBufferFormatType { get }

    var baseAddress: UnsafeMutableRawPointer? { get }

    var state: PixelBufferState { get set }
    var isTemporary: Bool { get set }

    func lock(_ readOnly: Bool)
    func unlock(_ readOnly: Bool)
    func lock()
    func unlock()
}

extension IPixelBuffer {
    public func lock() {
        lock(false)
    }

    public func unlock() {
        unlock(false)
    }
}
