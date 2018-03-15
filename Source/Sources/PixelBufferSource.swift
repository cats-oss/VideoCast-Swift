//
//  PixelBufferSource.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import CoreVideo
import GLKit

open class PixelBufferSource: ISource {
    open var filter: IFilter?
    
    private weak var output: IOutput?
    private var pixelBuffer: CVPixelBuffer?
    private let width: Int
    private let height: Int
    private let pixelFormat: OSType
    
    public init(width: Int, height: Int, pixelFormat: OSType) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        
        var pb: CVPixelBuffer? = nil
        var ret: CVReturn = kCVReturnSuccess
        autoreleasepool {
            let pixelBufferOptions: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferOpenGLESCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            
            ret = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, pixelBufferOptions as NSDictionary, &pb)
        }
        if ret != 0 {
            pixelBuffer = pb
        } else {
            fatalError("PixelBuffer creation failed")
        }
    }
    
    deinit {
        pixelBuffer = nil
    }
    
    open func setOutput(_ output: IOutput) {
        self.output = output
    }
    
    open func pushPixelBuffer(data: UnsafeMutableRawPointer, size: Int) {
        guard let outp = output, let pixelBuffer = pixelBuffer else {
            Logger.debug("unexpected return")
            return
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let loc = CVPixelBufferGetBaseAddress(pixelBuffer)
        memcpy(loc, data, size)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        
        let mat = GLKMatrix4Identity
        let md = VideoBufferMetadata()
        md.data = (4, mat, true, WeakRefISource(value: self))
        var pb = PixelBuffer(pixelBuffer, temporary: false)
        outp.pushBuffer(&pb, size: MemoryLayout<PixelBuffer>.size, metadata: md)
    }
}
