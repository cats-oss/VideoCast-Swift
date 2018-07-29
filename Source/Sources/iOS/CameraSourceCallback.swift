//
//  CameraSourceCallback.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/29/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import Foundation
import AVFoundation

class SbCallback: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var source: CameraSource?

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            Logger.debug("unexpected return")
            return
        }
        source?.bufferCaptured(pixelBuffer: pixelBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
    }

    @objc func orientationChanged(notification: Notification) {
        guard let source = source, !source.orientationLocked else { return }
        DispatchQueue.global().async { [weak self] in
            self?.source?.reorientCamera()
        }
    }
}
