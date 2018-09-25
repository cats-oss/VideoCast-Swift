//
//  PixelFormatConverter.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/09/21.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import CoreMedia
import Metal

func PixcelFormatToMetal(_ format: PixelBufferFormatType) -> MTLPixelFormat {
    switch format {
    case kCVPixelFormatType_16LE5551:
        return .bgr5A1Unorm
    case kCVPixelFormatType_16LE565:
        return .b5g6r5Unorm
    case kCVPixelFormatType_32BGRA:
        return .bgra8Unorm
    case kCVPixelFormatType_32RGBA:
        return .rgba8Unorm
    case kCVPixelFormatType_422YpCbCr8:
        return .gbgr422
    default:
        return .bgra8Unorm
    }
}
