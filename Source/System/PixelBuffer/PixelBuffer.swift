//
//  PixelBuffer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/12.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import CoreVideo

open class PixelBuffer: IPixelBuffer {
    open var width: Int {
        return CVPixelBufferGetWidth(cvBuffer)
    }

    open var height: Int {
        return CVPixelBufferGetHeight(cvBuffer)
    }

    open var pixelFormat: PixelBufferFormatType

    open var baseAddress: UnsafeMutableRawPointer? {
        return CVPixelBufferGetBaseAddress(cvBuffer)
    }

    open var state: PixelBufferState = .available

    open var isTemporary: Bool

    open var cvBuffer: CVPixelBuffer
    private var locked = false

    public init(_ pb: CVPixelBuffer, temporary: Bool = false) {
        cvBuffer = pb
        isTemporary = temporary
        pixelFormat = CVPixelBufferGetPixelFormatType(pb)
    }

    open func lock(_ readonly: Bool) {
        locked = true
    }

    open func unlock(_ readonly: Bool) {
        locked = false
    }
}
