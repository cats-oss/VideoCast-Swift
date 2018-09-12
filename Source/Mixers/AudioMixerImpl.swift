//
//  AudioMixerImpl.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/29/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import CoreMedia
import AudioUnit

extension AudioMixer {
    class MixWindow {
        var start = Date()
        let size: Int
        var next: MixWindow?
        var prev: MixWindow?
        var buffer: [UInt8]

        init(size: Int) {
            buffer = [UInt8](repeating: 0, count: size)
            self.size = size
        }

        func clear() {
            _ = (0 ..< size).map {buffer[$0] = 0}
        }
    }

    struct UserData {
        var data: UnsafeMutableRawPointer
        var p: Int
        var size: Int
        var packetSize: Int
        var numberPackets: UInt32
        var numChannels: Int
        var pd: UnsafePointer<AudioStreamPacketDescription>?
        var isInterleaved: Bool
        var usesOSStruct: Bool
    }

    struct ConverterInst {
        var asbdIn: AudioStreamBasicDescription
        var asbdOut: AudioStreamBasicDescription
        var converter: AudioConverterRef?
    }

    /*!
     *  Called to resample a buffer of audio samples.
     *
     * \param buffer    The input samples
     * \param size      The buffer size in bytes
     * \param metadata  The associated AudioBufferMetadata that specifies the properties of this buffer.
     *
     * \return An audio buffer that has been resampled to match the output properties of the mixer.
     */
    // swiftlint:disable:next function_body_length
    func resample(_ buffer: UnsafeRawPointer, size: Int, metadata: AudioBufferMetadata) -> Buffer {
        guard let metaData = metadata.data else {
            Logger.debug("unexpected return")
            return Buffer()
        }

        let inFrequncyInHz = metaData.frequencyInHz
        let inBitsPerChannel = metaData.bitsPerChannel
        let inChannelCount = metaData.channelCount
        let inFlags = metaData.flags
        let inBytesPerFrame = metaData.bytesPerFrame
        let inNumberFrames = metaData.numberFrames
        let inUsesOSStruct = metaData.usesOSStruct

        guard outFrequencyInHz != inFrequncyInHz ||
            outBitsPerChannel != inBitsPerChannel ||
            outChannelCount != inChannelCount ||
            (inFlags & kAudioFormatFlagIsNonInterleaved) != 0 ||
            (inFlags & kAudioFormatFlagIsFloat) != 0 else {
                // No resampling necessary
                return Buffer()
        }

        let b1 = UInt64(inBytesPerFrame&0xFF) << 56
        let b2 = UInt64(inFlags&0xFF) << 48
        let b3 = UInt64(inChannelCount) << 40
        let b4 = UInt64(inBitsPerChannel&0xFF) << 32
        let b5 = UInt64(inFrequncyInHz)
        let hash = b1 | b2 | b3 | b4 | b5

        let converterInst: ConverterInst

        if let _converterInst = converters[hash] {
            converterInst = _converterInst
        } else {
            var asbdIn = AudioStreamBasicDescription()
            var asbdOut = AudioStreamBasicDescription()

            asbdIn.mFormatID = kAudioFormatLinearPCM
            asbdIn.mFormatFlags = inFlags
            asbdIn.mChannelsPerFrame = UInt32(inChannelCount)
            asbdIn.mSampleRate = Float64(inFrequncyInHz)
            asbdIn.mBitsPerChannel = UInt32(inBitsPerChannel)
            asbdIn.mBytesPerFrame = UInt32(inBytesPerFrame)
            asbdIn.mFramesPerPacket = 1
            asbdIn.mBytesPerPacket = asbdIn.mBytesPerFrame * asbdIn.mFramesPerPacket

            asbdOut.mFormatID = kAudioFormatLinearPCM
            asbdOut.mFormatFlags =
                kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
            asbdOut.mChannelsPerFrame = UInt32(outChannelCount)
            asbdOut.mSampleRate = Float64(outFrequencyInHz)
            asbdOut.mBitsPerChannel = UInt32(outBitsPerChannel)
            asbdOut.mBytesPerFrame = (asbdOut.mBitsPerChannel * asbdOut.mChannelsPerFrame) / 8
            asbdOut.mFramesPerPacket = 1
            asbdOut.mBytesPerPacket = asbdOut.mBytesPerFrame * asbdOut.mFramesPerPacket

            var _converterInst = ConverterInst(asbdIn: asbdIn, asbdOut: asbdOut, converter: nil)
            let status = AudioConverterNew(&asbdIn, &asbdOut, &_converterInst.converter)
            converterInst = _converterInst

            if let converter = converterInst.converter {
                AudioConverterSetProperty(converter,
                                          kAudioConverterSampleRateConverterComplexity,
                                          UInt32(MemoryLayout<UInt32>.size),
                                          &AudioMixer.s_samplingRateConverterComplexity)

                AudioConverterSetProperty(converter,
                                          kAudioConverterSampleRateConverterQuality,
                                          UInt32(MemoryLayout<UInt32>.size),
                                          &AudioMixer.s_samplingRateConverterQuality)

                var prime = kConverterPrimeMethod_None

                AudioConverterSetProperty(converter,
                                          kAudioConverterPrimeMethod,
                                          UInt32(MemoryLayout<UInt32>.size),
                                          &prime)
            }

            converters[hash] = converterInst

            if status != noErr {
                Logger.error("converterInst = \(converterInst) (\(String(format: "%x", status))")
            }
        }

        guard let inConverter = converterInst.converter else {
            Logger.debug("unexpected return")
            return Buffer()
        }

        let asbdIn = converterInst.asbdIn
        let asbdOut = converterInst.asbdOut

        let inSampleCount = inNumberFrames
        let ratio = Double(inFrequncyInHz) / Double(outFrequencyInHz)

        let outBufferSampleCount: Double = round(Double(inSampleCount) / ratio)

        let outBufferSize = Int(Double(asbdOut.mBytesPerPacket) * outBufferSampleCount)
        let outBuffer = Buffer(outBufferSize)

        var userData = UserData(
            data: UnsafeMutableRawPointer(mutating: buffer),
            p: 0,
            size: size,
            packetSize: Int(asbdIn.mBytesPerPacket),
            numberPackets: UInt32(inSampleCount),
            numChannels: inChannelCount,
            pd: nil,
            isInterleaved: (inFlags & kAudioFormatFlagIsNonInterleaved) == 0,
            usesOSStruct: inUsesOSStruct
        )

        let size: Int = outBuffer.buffer.withUnsafeMutableBytes { (mData: UnsafeMutablePointer<UInt8>) in
             var outBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(outChannelCount),
                    mDataByteSize: UInt32(outBufferSize),
                    mData: mData
            ))

            var sampleCount = UInt32(outBufferSampleCount)
            let status = AudioConverterFillComplexBuffer(inConverter,  /* AudioConverterRef inAudioConverter */
                AudioMixer.ioProc,    /* AudioConverterComplexInputDataProc inInputDataProc */
                &userData, /* void *inInputDataProcUserData */
                &sampleCount, /* UInt32 *ioOutputDataPacketSize */
                &outBufferList,   /* AudioBufferList *outOutputData */
                nil   /* AudioStreamPacketDescription *outPacketDescription */
            )
            if status != noErr {
                Logger.error("status = \(status) (\(String(format: "%x", status))")
            }
            return Int(outBufferList.mBuffers.mDataByteSize)
        }
        outBuffer.buffer.count = size

        return outBuffer
    }

    private static let ioProc: AudioConverterComplexInputDataProc = {
        audioConverter, ioNumDataPackets, ioData, ioPacketDesc, inUserData in
        var err: OSStatus = noErr
        let userData = inUserData!.assumingMemoryBound(to: UserData.self)
        let numPackets = min(ioNumDataPackets.pointee, userData.pointee.numberPackets)

        ioNumDataPackets.pointee = numPackets
        let ioDataPtr = UnsafeMutableAudioBufferListPointer(ioData)
        if !userData.pointee.usesOSStruct {
            ioDataPtr[0].mData = userData.pointee.data
            ioDataPtr[0].mDataByteSize = numPackets * UInt32(userData.pointee.packetSize)
            ioDataPtr[0].mNumberChannels = UInt32(userData.pointee.numChannels)
        } else {
            let ab = userData.pointee.data.assumingMemoryBound(to: AudioBufferList.self)
            ioData[0].mNumberBuffers = ab.pointee.mNumberBuffers
            let p = userData.pointee.p

            for i in 0..<Int(ab.pointee.mNumberBuffers) {
                let abPtr = UnsafeMutableAudioBufferListPointer(ab)
                guard let data = abPtr[i].mData else {
                    Logger.debug("unexpected return")
                    continue
                }
                ioDataPtr[i].mData = data + p
                ioDataPtr[i].mDataByteSize = numPackets * UInt32(userData.pointee.packetSize)
                ioDataPtr[i].mNumberChannels = abPtr[i].mNumberChannels
            }

            userData.pointee.p += Int(numPackets) * userData.pointee.packetSize
        }

        return err
    }

    /*!
     *  Start the mixer thread.
     */
    @objc func mixThread() {
        let duration = frameDuration
        let start = epoch

        nextMixTime = start
        currentWindow.start = start
        currentWindow.next?.start = start + duration

        while !exiting.value {
            mixThreadCond.lock()
            defer { mixThreadCond.unlock() }

            let now = Date()

            if let nextWindow = currentWindow.next, now >= nextWindow.start {
                let currentTime = nextMixTime

                let currentWindow = self.currentWindow

                nextWindow.start = currentWindow.start + duration
                nextWindow.next?.start = nextWindow.start + duration

                nextMixTime = currentWindow.start

                let md = AudioBufferMetadata(ts: .init(seconds: currentTime.timeIntervalSince(epoch),
                                                       preferredTimescale: VC_TIME_BASE))

                md.data = (outFrequencyInHz, outBitsPerChannel, outChannelCount, AudioFormatFlags(0), 0,
                           currentWindow.size, false, false, WeakRefISource(value: nil))
                if let out = output, let outgoingWindow = outgoingWindow {
                    out.pushBuffer(outgoingWindow.buffer, size: outgoingWindow.size, metadata: md)
                    outgoingWindow.clear()
                }
                outgoingWindow = currentWindow

                self.currentWindow = nextWindow
            }

            if !exiting.value, let start = self.currentWindow.next?.start {
                mixThreadCond.wait(until: start)
            }
        }

        Logger.debug("Exiting audio mixer...")
    }

    static func TPMixSamples(_ a: Int16, _ b: Int16) -> Int16 {
        let sum = (Int(a) + Int(b))
        let mul = (Int(a) * Int(b))

        if a < 0 && b < 0 {
            // If both samples are negative, mixed signal must have an amplitude
            // between the lesser of A and B, and the minimum permissible negative amplitude
            return Int16(sum - (mul/Int(Int16.min)))
        } else if a > 0 && b > 0 {
            // If both samples are positive, mixed signal must have an amplitude
            // between the greater of A and B, and the maximum permissible positive amplitude
            return Int16(sum - (mul/Int(Int16.max)))
        } else {
            // If samples are on opposite sides of the 0-crossing, mixed signal should reflect
            // that samples cancel each other out somewhat
            return a + b
        }
    }
}
