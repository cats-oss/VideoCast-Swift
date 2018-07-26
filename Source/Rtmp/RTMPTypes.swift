//
//  RTMPTypes.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

public let kRTMPMaxChunkSize = 128
public let kRTMPDefaultChunkSize = 128
public let kRTMPSignatureSize = 1536

public enum RTMPClientState: Int {
    case none = 0
    case connected = 1
    case handshake0 = 2
    case handshake1s0 = 3
    case handshake1s1 = 4
    case handshake2 = 5
    case handshakeComplete = 6
    case fCPublish = 7
    case ready = 8
    case sessionStarted = 9
    case error = 10
    case notConnected = 11
}

public struct RTMPChunk_0 {
    public var body: [UInt8] = .init(repeating: 0, count: 11)
    public var timestamp: Int32 {
        get {
            return Int32(get_be24(body[...]))
        }
        set {
            var buf: [UInt8] = .init()
            put_be24(&buf, val: newValue)
            body[0..<3] = buf[0..<3]
        }
    }
    public var msg_length: Int32 {
        get {
            return Int32(get_be24(body[3...]))
        }
        set {
            var buf: [UInt8] = .init()
            put_be24(&buf, val: newValue)
            body[3..<6] = buf[0..<3]
        }
    }
    public var msg_type_id: RtmpPt {
        get {
            guard let typeId = RtmpPt(rawValue: body[6]) else {
                Logger.warn("Received unknown packet type: 0x\(String(format: "%02X", body[6]))")
                return .unknown
            }
            return typeId
        }
        set {
            body[6] = newValue.rawValue
        }
    }
    public var msg_stream_id: ChannelStreamId {
        get {
            let rawValue = get_be32(body[7...])
            guard let streamId = ChannelStreamId(rawValue: rawValue) else {
                Logger.warn("Received unknown stream Id: 0x\(String(format: "%02X", rawValue))")
                return .unknown
            }
            return streamId
        }
        set {
            var buf: [UInt8] = .init()
            put_be32(&buf, val: Int32(newValue.rawValue))
            body[7..<11] = buf[0..<4]
        }
    }
}

public let RTMP_CHUNK_TYPE_0 = 0x0

public struct RTMPChunk_1 {
    public var body: [UInt8] = .init(repeating: 0, count: 7)
    public var delta: Int32 {
        get {
            return Int32(get_be24(body[...]))
        }
        set {
            var buf: [UInt8] = .init()
            put_be24(&buf, val: newValue)
            body[0..<3] = buf[0..<3]
        }
    }
    public var msg_length: Int32 {
        get {
            return Int32(get_be24(body[3...]))
        }
        set {
            var buf: [UInt8] = .init()
            put_be24(&buf, val: newValue)
            body[3..<6] = buf[0..<3]
        }
    }
    public var msg_type_id: RtmpPt {
        get {
            guard let typeId = RtmpPt(rawValue: body[6]) else {
                Logger.warn("Received unknown packet type: 0x\(String(format: "%02X", body[6]))")
                return .unknown
            }
            return typeId
        }
        set {
            body[6] = newValue.rawValue
        }
    }
}
public let RTMP_CHUNK_TYPE_1: UInt8 = 0x40

public struct RTMPChunk_2 {
    public var body: [UInt8] = .init(repeating: 0, count: 3)
    public var delta: Int32 {
        get {
            return Int32(get_be24(body[...]))
        }
        set {
            var buf: [UInt8] = .init()
            put_be24(&buf, val: newValue)
            body[0..<3] = buf[0..<3]
        }
    }

}
public let RTMP_CHUNK_TYPE_2: UInt8 = 0x80

public let RTMP_CHUNK_TYPE_3: UInt8 = 0xC0

/* offsets for packed values */
public let FLV_AUDIO_SAMPLESSIZE_OFFSET     = 1
public let FLV_AUDIO_SAMPLERATE_OFFSET      = 2
public let FLV_AUDIO_CODECID_OFFSET         = 4

public let FLV_VIDEO_FRAMETYPE_OFFSET       = 4

/* bitmasks to isolate specific values */
public let FLV_AUDIO_CHANNEL_MASK           = 0x01
public let FLV_AUDIO_SAMPLESIZE_MASK        = 0x02
public let FLV_AUDIO_SAMPLERATE_MASK        = 0x0c
public let FLV_AUDIO_CODECID_MASK           = 0xf0

public let FLV_VIDEO_CODECID_MASK           = 0x0f
public let FLV_VIDEO_FRAMETYPE_MASK         = 0xf0

public let AMF_END_OF_OBJECT                = 0x09

public enum FlvTagType: UInt8 {
    case audio  = 0x08
    case video  = 0x09
    case meta   = 0x12
    case invoke = 0x14
}

// RTMP header type is 1 byte
public enum RtmpHeaderType: UInt8 {
    case full           = 0x0   // RTMPChunk_0
    case noMsgStreamId  = 0x1   // RTMPChunk_1
    case timestamp      = 0x2   // RTMPChunk_2
    case only           = 0x3   // no chunk header
}

public enum RtmpPt: UInt8 {
    case unknown        = 0x0
    case chunkSize      = 0x1
    case bytesRead      = 0x3
    case userControl    = 0x4
    case serverWindow   = 0x5
    case peerBw         = 0x6
    case audio          = 0x8
    case video          = 0x9
    case flexStream     = 0xF
    case flexObject     = 0x10
    case flexMessage    = 0x11
    case notify         = 0x12
    case sharedObj      = 0x13
    case invoke         = 0x14
    case metadata       = 0x16
}

public enum AmfDataType: UInt8 {
    case number         = 0x00
    case bool           = 0x01
    case string         = 0x02
    case object         = 0x03
    case null           = 0x05
    case undefined      = 0x06
    case reference      = 0x07
    case mixedarray     = 0x08
    case objectEnd      = 0x09
    case array          = 0x0a
    case date           = 0x0b
    case longString     = 0x0c
    case unsupported    = 0x0d
}

public enum FlvSoundType: UInt8 {
    case mono   = 0
    case stereo = 1
}

public struct FlvFlags: OptionSet {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let mono   = FlvFlags(rawValue: 0)
    public static let stereo = FlvFlags(rawValue: 1)

    public static let samplesize8bit    = FlvFlags(rawValue: 0)
    public static let samplesize16bit   = FlvFlags(rawValue: 1 << FLV_AUDIO_SAMPLESSIZE_OFFSET)

    public static let samplerateSpecial  = FlvFlags(rawValue: 0)  /**< signifies 5512Hz and 8000Hz in the case of NELLYMOSER */
    public static let samplerate11025hz = FlvFlags(rawValue: 1 << FLV_AUDIO_SAMPLERATE_OFFSET)
    public static let samplerate22050hz = FlvFlags(rawValue: 2 << FLV_AUDIO_SAMPLERATE_OFFSET)
    public static let samplerate44100hz = FlvFlags(rawValue: 3 << FLV_AUDIO_SAMPLERATE_OFFSET)

    public static let codecIdPcm                  = FlvFlags(rawValue: 0)
    public static let codecIdAdpcm                = FlvFlags(rawValue: 1 << FLV_AUDIO_CODECID_OFFSET)
    public static let codecIdMp3                  = FlvFlags(rawValue: 2 << FLV_AUDIO_CODECID_OFFSET)
    public static let codecIdPcmLe                = FlvFlags(rawValue: 3 << FLV_AUDIO_CODECID_OFFSET)
    public static let codecIdNellymoser8khzMono   = FlvFlags(rawValue: 5 << FLV_AUDIO_CODECID_OFFSET)
    public static let codecIdNellymoser           = FlvFlags(rawValue: 6 << FLV_AUDIO_CODECID_OFFSET)
    public static let codecIdAac                  = FlvFlags(rawValue: 10 << FLV_AUDIO_CODECID_OFFSET)
    public static let codecIdSpeex                = FlvFlags(rawValue: 11 << FLV_AUDIO_CODECID_OFFSET)

    public static let codecIdH263                 = FlvFlags(rawValue: 2)
    public static let codecIdScreen               = FlvFlags(rawValue: 3)
    public static let codecIdVp6                  = FlvFlags(rawValue: 4)
    public static let codecIdVp6a                 = FlvFlags(rawValue: 5)
    public static let codecIdScreen2              = FlvFlags(rawValue: 6)
    public static let codecIdH264                 = FlvFlags(rawValue: 7)

    public static let frameKey          = FlvFlags(rawValue: 1 << FLV_VIDEO_FRAMETYPE_OFFSET)
    public static let frameInter        = FlvFlags(rawValue: 2 << FLV_VIDEO_FRAMETYPE_OFFSET)
    public static let frameDispInter    = FlvFlags(rawValue: 3 << FLV_VIDEO_FRAMETYPE_OFFSET)
}

public enum ChunkStreamId: UInt8 {
    case unknown    = 0x00
    case control    = 0x02
    case connect    = 0x03
    case create     = 0x04
    case publish    = 0x05
    case meta       = 0x06
    case video      = 0x07
    case audio      = 0x08
}

public enum ChannelStreamId: Int {
    case unknown    = -1
    case control    = 0x00
    case data       = 0x01
}
