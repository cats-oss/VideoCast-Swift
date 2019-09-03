//
//  AudioSampleSource.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/09/21.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import CoreMedia
import AVFoundation

open class AudioSampleSource: ISource {
    open var filter: IFilter?

    private weak var output: IOutput?

    public init() {
    }

    deinit {
    }

    open func setOutput(_ output: IOutput) {
        self.output = output
        if let mixer = output as? IAudioMixer {
            mixer.registerSource(self)
        }
    }

    // swiftlint:disable:next function_body_length
    open func pushSample(_ sampleBuffer: CMSampleBuffer) {
        guard let outp = output else {
            Logger.debug("unexpected return")
            return
        }

        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            Logger.debug("data is not ready yet")
            return
        }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
            else {
                Logger.debug("unexpected return")
                return
        }
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil))
        var blockBuffer: CMBlockBuffer?

        let ret = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        assert(ret == noErr)
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) as CMTime
        let md = AudioBufferMetadata(ts: pts)

        md.data = (Int(asbd.mSampleRate),
                   Int(asbd.mBitsPerChannel),
                   Int(asbd.mChannelsPerFrame),
                   asbd.mFormatFlags,
                   Int(asbd.mBytesPerFrame),
                   numSamples,
                   false,
                   false,
                   WeakRefISource(value: self)
        )
        for i in 0..<Int(audioBufferList.mNumberBuffers) {
            let abPtr = UnsafeMutableAudioBufferListPointer(&audioBufferList)
            guard let data = abPtr[i].mData else {
                Logger.debug("unexpected return")
                continue
            }
            outp.pushBuffer(data,
                            size: Int(abPtr[i].mDataByteSize), metadata: md)
        }
    }
}
