//
//  RTMPSessionSendPacket.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/28/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import Foundation

extension RTMPSession {
    private func sendPacket(_ data: UnsafePointer<UInt8>, size: Int, streamId: ChunkStreamId, metadata: RTMPChunk0) {
        let md = RTMPMetadata()

        md.data = (streamId, Int(metadata.timestamp), Int(metadata.msg_length),
                   metadata.msg_type_id, metadata.msg_stream_id, false)

        pushBuffer(data, size: size, metadata: md)
    }

    func sendConnectPacket() {
        var metadata: RTMPChunk0 = .init()
        metadata.msg_stream_id = .control
        metadata.msg_type_id = RtmpPt.invoke
        var buff: [UInt8] = .init()
        var url = URLComponents()
        url.scheme = uri.scheme
        url.host = uri.host
        url.port = uri.port
        url.path = "/" + app

        put_string(&buff, string: "connect")
        put_double(&buff, val: Double(trackCommand("connect")))
        put_byte(&buff, val: AMFDataType.object.rawValue)
        put_named_string(&buff, name: "app", val: app)
        put_named_string(&buff, name: "type", val: "nonprivate")
        put_named_string(&buff, name: "tcUrl", val: url.string ?? "")
        put_named_bool(&buff, name: "fpad", val: false)
        put_named_double(&buff, name: "capabilities", val: 15)
        put_named_double(&buff, name: "audioCodecs", val: 10)
        put_named_double(&buff, name: "videoCodecs", val: 7)
        put_named_double(&buff, name: "videoFunction", val: 1)
        put_be16(&buff, val: 0)
        put_byte(&buff, val: AMFDataType.objectEnd.rawValue)

        metadata.msg_length = Int32(buff.count)
        sendPacket(buff, size: buff.count, streamId: .connect, metadata: metadata)
    }

    func sendReleaseStream() {
        var metadata: RTMPChunk0 = .init()
        metadata.msg_stream_id = .control
        metadata.msg_type_id = RtmpPt.invoke
        var buff: [UInt8] = .init()
        put_string(&buff, string: "releaseStream")
        put_double(&buff, val: Double(trackCommand("releaseStream")))
        put_byte(&buff, val: AMFDataType.null.rawValue)
        put_string(&buff, string: playPath)
        metadata.msg_length = Int32(buff.count)

        sendPacket(buff, size: buff.count, streamId: .create, metadata: metadata)
    }

    func sendFCPublish() {
        var metadata: RTMPChunk0 = .init()
        metadata.msg_stream_id = .control
        metadata.msg_type_id = RtmpPt.invoke
        var buff: [UInt8] = .init()
        put_string(&buff, string: "FCPublish")
        put_double(&buff, val: Double(trackCommand("FCPublish")))
        put_byte(&buff, val: AMFDataType.null.rawValue)
        put_string(&buff, string: playPath)
        metadata.msg_length = Int32(buff.count)

        sendPacket(buff, size: buff.count, streamId: .create, metadata: metadata)
    }

    func sendCreateStream() {
        var metadata: RTMPChunk0 = .init()
        metadata.msg_stream_id = .control
        metadata.msg_type_id = RtmpPt.invoke
        var buff: [UInt8] = .init()
        put_string(&buff, string: "createStream")
        put_double(&buff, val: Double(trackCommand("createStream")))
        put_byte(&buff, val: AMFDataType.null.rawValue)
        metadata.msg_length = Int32(buff.count)

        sendPacket(buff, size: buff.count, streamId: .create, metadata: metadata)
    }

    func sendPublish() {
        var metadata: RTMPChunk0 = .init()
        metadata.msg_stream_id = .data
        metadata.msg_type_id = RtmpPt.invoke
        var buff: [UInt8] = .init()
        put_string(&buff, string: "publish")
        put_double(&buff, val: 0)
        put_byte(&buff, val: AMFDataType.null.rawValue)
        put_string(&buff, string: playPath)
        put_string(&buff, string: "LIVE")
        metadata.msg_length = Int32(buff.count)

        sendPacket(buff, size: buff.count, streamId: .publish, metadata: metadata)
    }

    // swiftlint:disable:next function_body_length
    func sendHeaderPacket() {
        Logger.debug("send header packet")

        var enc: [UInt8] = .init()
        var metadata: RTMPChunk0 = .init()

        put_string(&enc, string: "@setDataFrame")
        put_string(&enc, string: "onMetaData")
        put_byte(&enc, val: AMFDataType.object.rawValue)

        put_named_double(&enc, name: "width", val: Double(frameWidth))
        put_named_double(&enc, name: "height", val: Double(frameHeight))
        put_named_double(&enc, name: "displaywidth", val: Double(frameWidth))
        put_named_double(&enc, name: "displayheight", val: Double(frameHeight))
        put_named_double(&enc, name: "framewidth", val: Double(frameWidth))
        put_named_double(&enc, name: "frameheight", val: Double(frameHeight))
        put_named_double(&enc, name: "videodatarate", val: Double(bitrate) / 1024)
        put_named_double(&enc, name: "videoframerate", val: 1 / frameDuration)

        put_named_string(&enc, name: "videocodecid", val: "avc1")

        put_name(&enc, name: "trackinfo")
        put_byte(&enc, val: AMFDataType.strictArray.rawValue)
        put_be32(&enc, val: 2)

        //
        // Audio stream metadata
        put_byte(&enc, val: AMFDataType.object.rawValue)
        put_named_string(&enc, name: "type", val: "audio")

        let ss: String = "{AACFrame: codec:AAC, channels: \(audioStereo ? 2 : 1), " +
        "frequency:\(audioSampleRate), samplesPerFrame:1024, objectType:LC}"
        put_named_string(&enc, name: "description", val: ss)

        put_named_double(&enc, name: "timescale", val: 1000)

        put_name(&enc, name: "sampledescription")
        put_byte(&enc, val: AMFDataType.strictArray.rawValue)
        put_be32(&enc, val: 1)
        put_byte(&enc, val: AMFDataType.object.rawValue)
        put_named_string(&enc, name: "sampletype", val: "mpeg4-generic")
        put_byte(&enc, val: 0)
        put_byte(&enc, val: 0)
        put_byte(&enc, val: AMFDataType.objectEnd.rawValue)

        put_named_string(&enc, name: "language", val: "eng")

        put_byte(&enc, val: 0)
        put_byte(&enc, val: 0)
        put_byte(&enc, val: AMFDataType.objectEnd.rawValue)

        //
        // Video stream metadata

        put_byte(&enc, val: AMFDataType.object.rawValue)
        put_named_string(&enc, name: "type", val: "video")
        put_named_double(&enc, name: "timescale", val: 1000)
        put_named_string(&enc, name: "language", val: "eng")
        put_name(&enc, name: "sampledescription")
        put_byte(&enc, val: AMFDataType.strictArray.rawValue)
        put_be32(&enc, val: 1)
        put_byte(&enc, val: AMFDataType.object.rawValue)
        put_named_string(&enc, name: "sampletype", val: "H264")
        put_byte(&enc, val: 0)
        put_byte(&enc, val: 0)
        put_byte(&enc, val: AMFDataType.objectEnd.rawValue)
        put_byte(&enc, val: 0)
        put_byte(&enc, val: 0)
        put_byte(&enc, val: AMFDataType.objectEnd.rawValue)

        put_be16(&enc, val: 0)
        put_byte(&enc, val: AMFDataType.objectEnd.rawValue)
        put_named_double(&enc, name: "audiodatarate", val: Double(131152) / Double(1024))
        put_named_double(&enc, name: "audiosamplerate", val: audioSampleRate)
        put_named_double(&enc, name: "audiosamplesize", val: 16)
        put_named_double(&enc, name: "audiochannels", val: audioStereo ? 2 : 1)
        put_named_string(&enc, name: "audiocodecid", val: "mp4a")

        put_be16(&enc, val: 0)
        put_byte(&enc, val: AMFDataType.objectEnd.rawValue)
        let len = enc.count

        metadata.msg_type_id = RtmpPt(rawValue: FlvTagType.meta.rawValue)!
        metadata.msg_stream_id = .data
        metadata.msg_length = Int32(len)
        metadata.timestamp = 0

        sendPacket(enc, size: len, streamId: .meta, metadata: metadata)
    }

    func sendSetChunkSize(_ chunkSize: Int32) {
        jobQueue.enqueue {
            Logger.debug("send set chunk size:\(chunkSize)")
            var streamId: Int = 0

            var buff: [UInt8] = .init()

            put_byte(&buff, val: 2) // chunk stream ID 2
            put_be24(&buff, val: 0) // ts
            put_be24(&buff, val: 4) // size (4 bytes)
            put_byte(&buff, val: RtmpPt.chunkSize.rawValue) // chunk type

            put_buff(&buff, src: &streamId, srcsize: MemoryLayout<Int32>.size)

            put_be32(&buff, val: chunkSize)

            self.write(buff, size: buff.count)

            self.outChunkSize = Int(chunkSize)
        }
    }

    func sendPong() {
        jobQueue.enqueue {
            Logger.debug("send pong")

            var streamId: Int = 0

            var buff: [UInt8] = .init()

            put_byte(&buff, val: 2) // chunk stream ID 2
            put_be24(&buff, val: 0) // ts
            put_be24(&buff, val: 6) // size (6 bytes)
            put_byte(&buff, val: RtmpPt.userControl.rawValue) // chunk type

            put_buff(&buff, src: &streamId, srcsize: MemoryLayout<Int32>.size)
            put_be16(&buff, val: 7) // PingResponse
            put_be16(&buff, val: 0)
            put_be16(&buff, val: 0)

            self.write(buff, size: buff.count)
        }
    }

    func sendDeleteStream() {
        Logger.debug("send delete stream")

        var metadata: RTMPChunk0 = .init()
        metadata.msg_stream_id = .control
        metadata.msg_type_id = RtmpPt.invoke
        var buff: [UInt8] = .init()
        put_string(&buff, string: "deleteStream")
        numberOfInvokes += 1
        put_double(&buff, val: Double(numberOfInvokes))
        trackedCommands[numberOfInvokes] = "deleteStream"
        put_byte(&buff, val: AMFDataType.null.rawValue)
        put_double(&buff, val: Double(streamId))

        metadata.msg_length = Int32(buff.count)

        sendPacket(buff, size: buff.count, streamId: .create, metadata: metadata)
    }

    func sendSetBufferTime(_ milliseconds: Int) {
        jobQueue.enqueue {
            Logger.debug("send set buffer length")

            var streamId: Int = 0

            var buff: [UInt8] = .init()

            put_byte(&buff, val: 2)
            put_be24(&buff, val: 0)
            put_be24(&buff, val: 10)
            put_byte(&buff, val: RtmpPt.userControl.rawValue) // chunk type
            put_buff(&buff, src: &streamId, srcsize: MemoryLayout<Int32>.size)

            put_be16(&buff, val: 3) // SetBufferTime
            put_be32(&buff, val: self.streamId)
            put_be32(&buff, val: Int32(milliseconds))

            self.write(buff, size: buff.count)
        }
    }
}
