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
            nil,
            &audioBufferList,
            MemoryLayout<AudioBufferList>.size,
            nil,
            nil,
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            &blockBuffer
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
                   true,
                   false,
                   WeakRefISource(value: self)
        )
        outp.pushBuffer(&audioBufferList,
                        size: MemoryLayout<AudioBufferList>.size, metadata: md)
    }
}
