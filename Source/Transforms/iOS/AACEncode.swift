//
//  AACEncode.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/11.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import AudioToolbox

open class AACEncode: IEncoder {
    private let kSamplesPerFrame: UInt32 = 1024

    private var inDesc: AudioStreamBasicDescription
    private var outDesc: AudioStreamBasicDescription

    private let converterQueue: DispatchQueue = .init(label: "jp.co.cyberagent.VideoCast.aacencode")
    private var audioConverter: AudioConverterRef?
    private weak var output: IOutput?
    private var bytesPerSample: UInt32 = 0
    private var outputPacketMaxSize: UInt32 = 0

    private let outputBuffer: Buffer = .init()

    private var _bitrate: Int
    private var asc: [UInt8] = .init(repeating: 0, count: 2)
    private var sentConfig: Bool = false

    struct UserData {
        var data: UnsafeMutableRawPointer?
        var size: UInt32
        var packetSize: UInt32
        var pd: AudioStreamPacketDescription?
    }

    private let ioProc: AudioConverterComplexInputDataProc = { (
        audioConverter,
        ioNumDataPackets,
        ioData,
        ioPacketDesc,
        inUserData ) -> OSStatus in
        guard let ud = inUserData?.assumingMemoryBound(to: UserData.self) else {
            Logger.debug("unexpected return")
            return noErr
        }

        let maxPackets = UInt32(ud.pointee.size / ud.pointee.packetSize)

        ioNumDataPackets.pointee = min(maxPackets, ioNumDataPackets.pointee)

        let dataPtr = UnsafeMutableAudioBufferListPointer(ioData)
        dataPtr[0].mData = ud.pointee.data
        dataPtr[0].mDataByteSize = ud.pointee.size
        dataPtr[0].mNumberChannels = 1

        return noErr
    }

    open var bitrate: Int {
        get {
            return _bitrate
        }
        set {
            if _bitrate != newValue {
                converterQueue.sync {
                    var br = UInt32(newValue)
                    if let audioConverter = audioConverter {
                        AudioConverterDispose(audioConverter)
                    }

                    let subtype = kAudioFormatMPEG4AAC
                    let requestedCodecs: [AudioClassDescription] = [
                        .init(
                            mType: kAudioEncoderComponentType,
                            mSubType: subtype,
                            mManufacturer: kAppleSoftwareAudioCodecManufacturer),
                        .init(
                            mType: kAudioEncoderComponentType,
                            mSubType: subtype,
                            mManufacturer: kAppleHardwareAudioCodecManufacturer)
                    ]
                    AudioConverterNewSpecific(&inDesc, &outDesc, 2, requestedCodecs, &audioConverter)
                    guard let audioConverter = audioConverter else {
                        Logger.debug("unexpected return")
                        return
                    }
                    let result = AudioConverterSetProperty(audioConverter,
                                                           kAudioConverterEncodeBitRate,
                                                           UInt32(MemoryLayout<UInt32>.size), &br)
                    var propSize = UInt32(MemoryLayout<UInt32>.size)

                    guard result == noErr else {
                        Logger.debug("unexpected return: \(result)")
                        return
                    }
                    AudioConverterGetProperty(audioConverter, kAudioConverterEncodeBitRate, &propSize, &br)
                    _bitrate = Int(br)
                }
            }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public init(frequencyInHz: Int, channelCount: Int, averageBitrate bitrate: Int) {
        self._bitrate = bitrate

        var result: OSStatus = 0

        var inDesc: AudioStreamBasicDescription = .init()
        var outDesc: AudioStreamBasicDescription = .init()

        // passing anything except 48000, 44100, and 22050 for mSampleRate results in "!dat"
        // OSStatus when querying for kAudioConverterPropertyMaximumOutputPacketSize property
        // below
        inDesc.mSampleRate = Float64(frequencyInHz)
        // passing anything except 2 for mChannelsPerFrame results in "!dat" OSStatus when
        // querying for kAudioConverterPropertyMaximumOutputPacketSize property below
        inDesc.mChannelsPerFrame = UInt32(channelCount)
        inDesc.mBitsPerChannel = 16
        inDesc.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        inDesc.mFormatID = kAudioFormatLinearPCM
        inDesc.mFramesPerPacket = 1
        inDesc.mBytesPerFrame = inDesc.mBitsPerChannel * inDesc.mChannelsPerFrame / 8
        inDesc.mBytesPerPacket = inDesc.mFramesPerPacket*inDesc.mBytesPerFrame

        self.inDesc = inDesc

        outDesc.mFormatID = kAudioFormatMPEG4AAC
        outDesc.mFormatFlags = 0
        outDesc.mFramesPerPacket = kSamplesPerFrame
        outDesc.mSampleRate = Float64(frequencyInHz)
        outDesc.mChannelsPerFrame = UInt32(channelCount)

        self.outDesc = outDesc

        var outputBitrate = bitrate
        var propSize = UInt32(MemoryLayout<UInt32>.size)
        var outputPacketSize = 0

        let subtype = kAudioFormatMPEG4AAC
        let requestedCodecs: [AudioClassDescription] = [
            .init(
                mType: kAudioEncoderComponentType,
                mSubType: subtype,
                mManufacturer: kAppleSoftwareAudioCodecManufacturer),
            .init(
                mType: kAudioEncoderComponentType,
                mSubType: subtype,
                mManufacturer: kAppleHardwareAudioCodecManufacturer)
        ]

        result = AudioConverterNewSpecific(&inDesc, &outDesc, 2, requestedCodecs, &audioConverter)

        guard let audioConverter = audioConverter else {
            Logger.error("Error setting up audio encoder \(String(format: "%x", result))")
            return
        }

        if result == noErr {

            result = AudioConverterSetProperty(audioConverter, kAudioConverterEncodeBitRate, propSize, &outputBitrate)

        }
        if result == noErr {
            result = AudioConverterGetProperty(audioConverter,
                                               kAudioConverterPropertyMaximumOutputPacketSize,
                                               &propSize,
                                               &outputPacketSize)
        }

        guard result == noErr else {
            Logger.error("Error setting up audio encoder \(String(format: "%x", result))")
            return
        }

        outputPacketMaxSize = UInt32(outputPacketSize)

        bytesPerSample = UInt32(2 * channelCount)

        var sampleRateIndex: UInt8 = 0
        switch frequencyInHz {
        case 96000:
            sampleRateIndex = 0
        case 88200:
            sampleRateIndex = 1
        case 64000:
            sampleRateIndex = 2
        case 48000:
            sampleRateIndex = 3
        case 44100:
            sampleRateIndex = 4
        case 32000:
            sampleRateIndex = 5
        case 24000:
            sampleRateIndex = 6
        case 22050:
            sampleRateIndex = 7
        case 16000:
            sampleRateIndex = 8
        case 12000:
            sampleRateIndex = 9
        case 11025:
            sampleRateIndex = 10
        case 8000:
            sampleRateIndex = 11
        case 7350:
            sampleRateIndex = 12
        default:
            sampleRateIndex = 15
        }
        makeAsc(sampleRateIndex, channelCount: UInt8(channelCount))
    }

    deinit {

        if let audioConverter = audioConverter {
            AudioConverterDispose(audioConverter)
        }
    }

    open func setOutput(_ output: IOutput) {
        self.output = output
    }

    open func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        guard let audioConverter = audioConverter else {
            Logger.debug("unexpected return")
            return
        }

        let sampleCount = size / Int(bytesPerSample)
        let aac_packet_count = sampleCount / Int(kSamplesPerFrame)
        let required_bytes = aac_packet_count * Int(outputPacketMaxSize)

        if outputBuffer.size < required_bytes {
            outputBuffer.resize(required_bytes)
        }
        var p = outputBuffer.getMutable()
        var p_out = data.assumingMemoryBound(to: UInt8.self)

        for i in 0..<aac_packet_count {
            var num_packets: UInt32 = 1

            var buf = AudioBuffer()
            buf.mDataByteSize = outputPacketMaxSize * num_packets
            buf.mData = UnsafeMutableRawPointer(p)
            var l = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: buf)

            var ud = UserData(
                data: UnsafeMutableRawPointer(mutating: p_out),
                size: kSamplesPerFrame * bytesPerSample,
                packetSize: bytesPerSample,
                pd: nil)

            var output_packet_desc: UnsafeMutablePointer<AudioStreamPacketDescription>? =
                .allocate(capacity: Int(num_packets))
            defer {
                output_packet_desc?.deallocate()
            }
            converterQueue.sync {
                _ = AudioConverterFillComplexBuffer(audioConverter, ioProc, &ud, &num_packets, &l, output_packet_desc)
            }

            if let output_packet_desc = output_packet_desc {
                p += Int(output_packet_desc[0].mDataByteSize)
            }
            p_out += Int(kSamplesPerFrame * bytesPerSample)
        }
        let totalBytes = p - outputBuffer.getMutable()

        if let output = output, totalBytes > 0 {
            if !sentConfig {
                output.pushBuffer(asc, size: MemoryLayout<UInt8>.size * asc.count, metadata: metadata)
                sentConfig = true
            }

            output.pushBuffer(outputBuffer.get(), size: totalBytes, metadata: metadata)
        }
    }

    private func makeAsc(_ sampleRateIndex: UInt8, channelCount: UInt8) {
        // http://wiki.multimedia.cx/index.php?title=MPEG-4_Audio#Audio_Specific_Config
        asc[0] = 0x10 | ((sampleRateIndex>>1) & 0x3)
        asc[1] = ((sampleRateIndex & 0x1)<<7) | ((channelCount & 0xF) << 3)
    }
}
