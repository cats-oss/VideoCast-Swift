//
//  VideoSampleSource.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/09/21.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import CoreMedia
import CoreGraphics
import CoreImage
import GLKit
import ReplayKit

open class VideoSampleSource: ISource {
    open var filter: IFilter?

    private weak var output: IOutput?
    private var pool: CVPixelBufferPool?
    private var poolBufferDimensions: CGSize = CGSize()
    private let imageContext = CIContext(options: nil)

    public init() {
    }

    deinit {
    }

    open func setOutput(_ output: IOutput) {
        self.output = output
    }

    @available(iOS 9.0, *)
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    open func pushSample(_ inputBuffer: CMSampleBuffer) {
        guard let outp = output else {
            Logger.debug("unexpected return")
            return
        }

        guard CMSampleBufferDataIsReady(inputBuffer) else {
            Logger.debug("data is not ready yet")
            return
        }

        // Input data
        let inputPixels = CMSampleBufferGetImageBuffer(inputBuffer)!
        var inputImage = CIImage(cvPixelBuffer: inputPixels)

        var rotate = false
        if #available(iOS 11.0, *) {
            if let orientationAttachment =
                CMGetAttachment(
                    inputBuffer,
                    key: RPVideoSampleOrientationKey as CFString,
                    attachmentModeOut: nil) as? NSNumber {
                if let orientation = CGImagePropertyOrientation(rawValue: orientationAttachment.uint32Value) {
                    switch orientation {
                    case .up:
                        break
                    case .down, .upMirrored, .downMirrored:
                        inputImage = inputImage.oriented(orientation)
                    case .right:
                        inputImage = inputImage.oriented(.left)
                        rotate = true
                    case .left:
                        inputImage = inputImage.oriented(.right)
                        rotate = true
                    case .rightMirrored:
                        inputImage = inputImage.oriented(.leftMirrored)
                        rotate = true
                    case .leftMirrored:
                        inputImage = inputImage.oriented(.rightMirrored)
                        rotate = true
                    @unknown default:
                        Logger.error("unknown orientation \(orientation)")
                    }
                }
            }
        }

        // Create a new pool if the old pool doesn't have the right format.
        let bufferDimensions: CGSize
        if rotate {
            bufferDimensions = CGSize(width: CVPixelBufferGetHeight(inputPixels),
                                      height: CVPixelBufferGetWidth(inputPixels))
        } else {
            bufferDimensions = CGSize(width: CVPixelBufferGetWidth(inputPixels),
                                      height: CVPixelBufferGetHeight(inputPixels))
        }
        if pool == nil || !__CGSizeEqualToSize(bufferDimensions, poolBufferDimensions) {
            pool = nil
            let ok0 = CVPixelBufferPoolCreate(nil,
                                              nil, // pool attrs
                [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(bufferDimensions.width),
                    kCVPixelBufferHeightKey as String: Int(bufferDimensions.height),
                    kCVPixelFormatOpenGLESCompatibility as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                    ] as NSDictionary,  // buffer attrs
                &pool
            )
            poolBufferDimensions = bufferDimensions
            assert(ok0 == noErr)
        }

        guard let pool = pool else { return }

        // Create pixel buffer
        var outputPixelsOut: CVPixelBuffer?
        var ok1: CVReturn = kCVReturnSuccess
        autoreleasepool {
            ok1 = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil,
                                                                          pool,
                                                                          [
                                                                            kCVPixelBufferPoolAllocationThresholdKey: 3
                                                                            ] as NSDictionary, // aux attributes
                &outputPixelsOut
            )
        }
        if ok1 == kCVReturnWouldExceedAllocationThreshold {
            // Dropping frame because consumer is too slow
            return
        }
        assert(ok1 == noErr)
        guard let outputPixels = outputPixelsOut else { return }

        let ok2 = CVPixelBufferLockBaseAddress(outputPixels, [])
        assert(ok2 == noErr)

        imageContext.render(inputImage, to: outputPixels)

        CVPixelBufferUnlockBaseAddress(outputPixels, [])

        let pts = CMSampleBufferGetPresentationTimeStamp(inputBuffer)

        let md = VideoBufferMetadata(ts: pts)
        let mat = GLKMatrix4Identity
        md.data = (1, mat, true, WeakRefISource(value: self))

        var pb: IPixelBuffer = PixelBuffer(outputPixels, temporary: true)
        outp.pushBuffer(&pb, size: MemoryLayout<PixelBuffer>.size, metadata: md)
    }
}
