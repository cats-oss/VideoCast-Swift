//
//  RTMPSession.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

public typealias RTMPSessionParameters = MetaData<(width: Int, height: Int, frameDuration: Double, videoBitrate: Int, audioFrequency: Double, stereo: Bool)>
public typealias RTMPMetadata = MetaData<(chunkStreamId: ChunkStreamId, timestamp: Int, msgLength: Int, msgTypeId: RtmpPt, msgStreamId: ChannelStreamId, isKeyframe: Bool)>

public typealias RTMPSessionStateCallback = (_ session: RTMPSession, _ state: RTMPClientState) -> Void

open class RTMPSession: IOutputSession {
    private let kMaxSendbufferSize = 10 * 1024 * 1024   // 10 MB
    private let networkQueue: JobQueue = .init("com.videocast.rtmp.network")
    private let jobQueue: JobQueue = .init("com.videocast.rtmp")
    private var sentKeyframe: Date = .init()
    
    private let networkWaitSemaphore: DispatchSemaphore = .init(value: 0)
    
    private let s1: Buffer = .init()
    private let c1: Buffer = .init()
    
    private let throughputSession: TCPThroughputAdaptation = .init()
    
    private let previousTs: UInt64 = 0
    private var previousChunk: RTMPChunk_0 = .init()
    
    private var previousChunkData: [ChunkStreamId: UInt64] = .init()
    
    private let streamInBuffer: PreallocBuffer = .init(4096)
    private let streamSession: IStreamSession = StreamSession()
    private let outBuffer: [UInt8] = .init()
    private let uri: URL
    
    private let callback: RTMPSessionStateCallback
    private var bandwidthCallback: BandwidthCallback? = nil
    
    private let playPath: String
    private let app: String
    private var trackedCommands: [Int32: String] = .init()
    
    private var outChunkSize: Int = 128
    private var inChunkSize: Int = 128
    private var bufferSize: Int64 = 0
    
    private var streamId: Int32 = 0
    private var numberOfInvokes: Int32 = 0
    private var frameWidth: Int32 = 0
    private var frameHeight: Int32 = 0
    private var bitrate: Int32 = 0
    private var frameDuration: Double = 0
    private var audioSampleRate: Double = 0
    private var audioStereo: Bool = false
    
    private var state: RTMPClientState = .none
    
    private var clearing: Bool = false
    private var ending: Bool = false
    
    public init(uri: String, callback: @escaping RTMPSessionStateCallback) {
        self.callback = callback
        
        self.uri = URL(string: uri)!
        
        let uri_tokens = uri.components(separatedBy: "/")
        
        var tokenCount = 0
        var pp = ""
        var app: String = ""
        for it in uri_tokens {
            tokenCount += 1
            guard tokenCount >= 4 else { continue }   // skip protocol and host/port
            
            if tokenCount == 4 {
                app = it
            } else {
                pp += (it + "/")
            }
        }
        pp.removeLast()
        self.playPath = pp
        self.app = app
        
        connectServer()
    }
    
    deinit {
        Logger.debug("RTMPSession::deinit")
        
        if !ending {
            stop {}
        }
    }
    
    open func stop(_ callback: @escaping StopSessionCallback) {
        ending = true

        if state == .connected {
            sendDeleteStream()
        }
        
        streamSession.disconnect()
        throughputSession.stop()
        
        jobQueue.markExiting()
        jobQueue.enqueueSync {}
        networkQueue.markExiting()
        networkQueue.enqueueSync {}
        
        callback()
    }
    
    open func connectServer() {
        guard let host = uri.host else {
            Logger.debug("unexpected return")
            return
        }
        // reset the stream buffer.
        streamInBuffer.reset()
        let port = uri.port ?? 1935
        Logger.info("Connecting:\(host):\(port), stream name:\(playPath)")
        streamSession.connect(host: host, port: port, sscb: { [weak self] (session, status) in
            self?.streamStatusChanged(status)
        })
    }

    open func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        guard !ending, let inMetadata = metadata as? RTMPMetadata, let metaData = inMetadata.data else { return }
        
        // make the lamdba capture the data
        let buf = Buffer(size)
        buf.put(data, size: size)
        
        jobQueue.enqueue {
            if !self.ending {
                let packetTime = Date()
                
                var chunk: [UInt8] = .init()
                chunk.reserveCapacity(size+64)
                var len = buf.size
                var tosend = min(len, self.outChunkSize)
                var ptr: UnsafePointer<UInt8>?
                buf.read(&ptr, size: buf.size)
                guard var p = ptr else {
                    Logger.debug("unexpected return")
                    return
                }
                let ts = UInt64(metaData.timestamp)
                let chunkStreamId = metaData.chunkStreamId
                var streamId = metaData.msgStreamId.rawValue
                
                if let it = self.previousChunkData[chunkStreamId] {
                    // Type 1.
                    put_byte(&chunk, val: RTMP_CHUNK_TYPE_1 | (chunkStreamId.rawValue & 0x1F))
                    put_be24(&chunk, val: Int32(ts - it))   // timestamp delta
                    put_be24(&chunk, val: Int32(metaData.msgLength))
                    put_byte(&chunk, val: metaData.msgTypeId.rawValue)
                } else {
                    // Type 0.
                    put_byte(&chunk, val: chunkStreamId.rawValue & 0x1F)
                    put_be24(&chunk, val: Int32(ts))
                    put_be24(&chunk, val: Int32(metaData.msgLength))
                    put_byte(&chunk, val: metaData.msgTypeId.rawValue)
                    put_buff(&chunk, src: &streamId, srcsize: MemoryLayout<Int32>.size) // msg stream id is little-endian
                }
                
                self.previousChunkData[chunkStreamId] = ts
                put_buff(&chunk, src: p, srcsize: tosend)
                
                len -= tosend
                p += tosend
                
                while len > 0 {
                    tosend = min(len, self.outChunkSize)
                    put_byte(&chunk, val: RTMP_CHUNK_TYPE_3 | (chunkStreamId.rawValue & 0x1F))
                    put_buff(&chunk, src: p, srcsize: tosend)
                    p+=tosend
                    len-=tosend
                }
                self.write(chunk, size: chunk.count, packetTime: packetTime, isKeyframe: metaData.isKeyframe)
            }
        }
    }

    open func setSessionParameters(_ parameters: IMetaData) {
        guard let params = parameters as? RTMPSessionParameters, let data = params.data else {
            Logger.debug("unexpected return")
            return
        }
        bitrate = Int32(data.videoBitrate)
        frameDuration = data.frameDuration
        frameHeight = Int32(data.height)
        frameWidth = Int32(data.width)
        audioSampleRate = data.audioFrequency
        audioStereo = data.stereo
    }
    
    open func setBandwidthCallback(_ callback: @escaping BandwidthCallback) {
        bandwidthCallback = callback
        throughputSession.setThroughputCallback(callback)
    }
    
    private func sendPacket(_ data: UnsafePointer<UInt8>, size: Int, streamId: ChunkStreamId, metadata: RTMPChunk_0) {
        let md = RTMPMetadata()
        
        md.data = (streamId, Int(metadata.timestamp), Int(metadata.msg_length), metadata.msg_type_id, metadata.msg_stream_id, false)
        
        pushBuffer(data, size: size, metadata: md)
    }
    
    private func streamStatusChanged(_ status: StreamStatus) {
        if status.contains(.connected) && state.rawValue < RTMPClientState.connected.rawValue {
            setClientState(.connected)
        }
        if status.contains(.readBufferHasBytes) {
            dataReceived()
        }
        if status.contains(.writeBufferHasSpace) {
            if state.rawValue < RTMPClientState.handshakeComplete.rawValue {
                handshake()
            }
        } else {
            networkWaitSemaphore.signal()
        }
        if status.contains(.endStream) {
            setClientState(.notConnected)
        }
        if status.contains(.errorEncountered) {
            setClientState(.error)
        }
    }
    
    private func write(_ data: UnsafePointer<UInt8>, size: Int, packetTime: Date = .init(), isKeyframe: Bool = false) {
        if size > 0 {
            let buf = Buffer(size)
            buf.put(data, size: size)
            
            throughputSession.addBufferSizeSample(Int(bufferSize))
            
            increaseBuffer(Int64(size))
            if isKeyframe {
                sentKeyframe = packetTime
            }
            if bufferSize > kMaxSendbufferSize && isKeyframe {
                clearing = true
            }
            networkQueue.enqueue {
                var tosend = size
                
                var ptr: UnsafePointer<UInt8>?
                buf.read(&ptr, size: size)
                guard var p = ptr else {
                    Logger.debug("unexpected return")
                    return
                }
                
                while tosend > 0 && !self.ending && (!self.clearing || self.sentKeyframe == packetTime) {
                    self.clearing = false
                    let sent = self.streamSession.write(p, size: tosend)
                    p += sent
                    tosend -= sent
                    self.throughputSession.addSentBytesSample(sent)
                    if sent == 0 {
                        _ = self.networkWaitSemaphore.wait(timeout: DispatchTime.now() + DispatchTimeInterval.seconds(1))
                    }
                }
                self.increaseBuffer(-Int64(size))
            }
        }
        
    }
    
    private func dataReceived() {
        var stop1 = false
        var stop2 = false
        while streamSession.status.contains(.readBufferHasBytes) && !stop2 {
            let maxlen = streamInBuffer.availableSpace
            if maxlen > 0 {
                let len = streamSession.read(streamInBuffer.writeBuffer, size: maxlen)
                Logger.verbose("Want read:\(maxlen), read:\(len)")
                
                guard len > 0 else {
                    Logger.error("Read from stream error:\(len)")
                    stop2 = true
                    break
                }
                streamInBuffer.didWrite(len)
            } else {
                Logger.debug("Stream in buffer full")
            }
            
            while streamInBuffer.availableBytes > 0 && !stop1 {
                switch state {
                case .handshake1s0:
                    let s0 = streamInBuffer.readBuffer.pointee
                    if s0 == 0x03 {
                        setClientState(.handshake1s1)
                        streamInBuffer.didRead(1)
                    } else {
                        Logger.error("Want s0, but not:0x\(String(format: "%X", s0))")
                        // do remove data from buffer??
                        stop1 = true
                    }
                case .handshake1s1:
                    if streamInBuffer.availableBytes >= kRTMPSignatureSize {
                        let data = Data(bytes: streamInBuffer.readBuffer, count: kRTMPSignatureSize)
                        streamInBuffer.didRead(kRTMPSignatureSize)
                        s1.resize(kRTMPSignatureSize)
                        s1.put(data, size: kRTMPSignatureSize)
                        handshake()
                    } else {
                        Logger.debug("Not enough s1 size")
                        stop1 = true
                    }
                case .handshake2:
                    if streamInBuffer.availableBytes >= kRTMPSignatureSize {
                        // we don't care about s2 data, so did read directly
                        streamInBuffer.didRead(kRTMPSignatureSize)
                        setClientState(.handshakeComplete)
                        handshake()
                        sendConnectPacket()
                    } else {
                        Logger.debug("Not enough s2 size")
                        stop1 = true
                    }
                default:
                    if !parseCurrentData() {
                        streamInBuffer.dumpInfo()
                        stop1 = true
                    }
                }
            }
        }
    }
    
    private func setClientState(_ state: RTMPClientState) {
        self.state = state
        callback(self, state)
    }
    
    // RTMP
    
    private func handshake() {
        switch state {
        case .connected:
            handshake0()
        case .handshake0:
            handshake1()
        case .handshake1s1:
            handshake2()
        default:
            c1.resize(0)
            s1.resize(0)
        }
    }
    
    private func handshake0() {
        var c0: UInt8 = 0x03
        
        setClientState(.handshake0)
        
        write(&c0, size: 1)
        
        handshake()
    }
    
    private func handshake1() {
        setClientState(.handshake1s0)
        
        c1.resize(kRTMPSignatureSize)
        var ptr: UnsafePointer<UInt8>?
        c1.read(&ptr, size: kRTMPSignatureSize)
        guard let p = ptr else {
            Logger.debug("unexpected return")
            return
        }
        var zero: UInt64 = 0
        c1.put(&zero, size: MemoryLayout<UInt64>.size)
        
        write(p, size: kRTMPSignatureSize)
    }
    
    private func handshake2() {
        setClientState(.handshake2)
        var ptr: UnsafePointer<UInt8>?
        s1.read(&ptr, size: kRTMPSignatureSize)
        guard var p = ptr else {
            Logger.debug("unexpected return")
            return
        }
        p += 4
        var zero: UInt32 = 0
        memcpy(UnsafeMutablePointer<UInt8>(mutating: p), &zero, MemoryLayout<UInt32>.size)
        
        write(s1.get(), size: s1.size)
    }
    
    private func sendConnectPacket() {
        var metadata: RTMPChunk_0 = .init()
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
    
    private func sendReleaseStream() {
        var metadata: RTMPChunk_0 = .init()
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
    
    private func sendFCPublish() {
        var metadata: RTMPChunk_0 = .init()
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
    
    private func sendCreateStream() {
        var metadata: RTMPChunk_0 = .init()
        metadata.msg_stream_id = .control
        metadata.msg_type_id = RtmpPt.invoke
        var buff: [UInt8] = .init()
        put_string(&buff, string: "createStream")
        put_double(&buff, val: Double(trackCommand("createStream")))
        put_byte(&buff, val: AMFDataType.null.rawValue)
        metadata.msg_length = Int32(buff.count)
        
        sendPacket(buff, size: buff.count, streamId: .create, metadata: metadata)
    }
    
    private func sendPublish() {
        var metadata: RTMPChunk_0 = .init()
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
    
    private func sendHeaderPacket() {
        Logger.debug("send header packet")
        
        var enc: [UInt8] = .init()
        var metadata: RTMPChunk_0 = .init()
        
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
        
        let ss: String = "{AACFrame: codec:AAC, channels: \(audioStereo ? 2 : 1), frequency:\(audioSampleRate), samplesPerFrame:1024, objectType:LC}"
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
    
    private func sendSetChunkSize(_ chunkSize: Int32) {
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
    
    private func sendPong() {
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
    
    private func sendDeleteStream() {
        Logger.debug("send delete stream")
        
        var metadata: RTMPChunk_0 = .init()
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
    
    private func sendSetBufferTime(_ milliseconds: Int) {
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
    
    private func increaseBuffer(_ size: Int64) {
        bufferSize = max(bufferSize + size, 0)
    }
    
    private func reassembleBuffer(_ p: UnsafePointer<UInt8>, msgSize: Int, packageSize: Int) {
        
    }
    
    private func tryReadOneMessage(_ msg: inout [UInt8], from_offset: Int) -> Int {
        let msgsize = msg.count
        var full_msg_length = msgsize
        if msgsize > inChunkSize {
            // multiple chunk
            var remain = msgsize
            while remain > inChunkSize {
                remain -= inChunkSize
                full_msg_length += 1    // addn the chunk seperator 0xC?(0xC3 specially) count.
            }
        }
        
        // because we do not confirm the header length, so check with header length.
        guard streamInBuffer.availableBytes >= from_offset + full_msg_length else { return -1 }
        
        var msg_offset = 0  // where to write
        var buf_offset = from_offset    // where read for write
        var remain = msgsize
        while remain > inChunkSize {
            msg.replaceSubrange(msg_offset..., with: UnsafeBufferPointer<UInt8>(start: streamInBuffer.readBuffer+buf_offset, count: inChunkSize))
            msg_offset += inChunkSize
            buf_offset += inChunkSize+1
            remain -= inChunkSize
        }
        if remain > 0 {
            msg.replaceSubrange(msg_offset..., with: UnsafeBufferPointer<UInt8>(start: streamInBuffer.readBuffer+buf_offset, count: remain))
        }
        
        return full_msg_length
    }
    
    // Parse only one message every time, loop in the caller
    // If data not enough for one message, return false, else return true;
    private func parseCurrentData() -> Bool {
        Logger.verbose("Steam in buffer size:\(streamInBuffer.availableBytes)")
        guard streamInBuffer.availableBytes > 0 else {
            Logger.debug("No data in buffer")
            return false
        }
        
        var first_byte: UInt8
        // at least one byte in current buffer.
        first_byte = streamInBuffer.readBuffer.pointee
        let header_type = (first_byte & 0xC0) >> 6
        Logger.verbose("First byte:0x\(String(format: "%X", first_byte)), header type:\(header_type)")
        
        guard let type = RtmpHeaderType(rawValue: header_type) else {
            Logger.error("Invalid header type:\(header_type)")
            // FIXME: Maybe we shoult close the connection and reopen it
            networkQueue.enqueue {
                self.connectServer()
            }
            return false
        }
        
        switch type {
        case .full:
            var chunk: RTMPChunk_0 = .init()
            // at least a full header bytes in current buffer
            guard streamInBuffer.availableBytes >= 1+chunk.body.count else {
                Logger.debug("Not enough a header")
                // DEBUG only
                Logger.dumpBuffer("RTMPChunk_0", buf: streamInBuffer.readBuffer, size: streamInBuffer.availableBytes)
                return false
            }
            
            chunk.body.replaceSubrange(0..., with: UnsafeRawBufferPointer(start: streamInBuffer.readBuffer+1, count: chunk.body.count))
            guard chunk.msg_length >= 0 else {
                Logger.debug("ERROR: Invalid header length")
                Logger.dumpBuffer("RTMPChunk_0 ERROR", buf: streamInBuffer.readBuffer, size: streamInBuffer.availableBytes)
                // FIXME: Clear the stream in buffer ?
                return false
            }
            if chunk.msg_length > 65535 {
                Logger.debug("Length too large ???:\(chunk.msg_length)")
            }
            var msg: [UInt8] = .init(repeating: 0, count: Int(chunk.msg_length))
            let full_msgsize = tryReadOneMessage(&msg, from_offset: 1+chunk.body.count)
            guard full_msgsize > 0 else {
                Logger.debug("Not enough one message in buffer")
                return false
            }
            streamInBuffer.didRead(1+chunk.body.count + full_msgsize)
            
            handleMessage(msg, msgTypeId: chunk.msg_type_id)
            previousChunk = chunk
            return true
            
        case .noMsgStreamId:
            var chunk: RTMPChunk_1 = .init()
            guard streamInBuffer.availableBytes >= 1+chunk.body.count else {
                Logger.debug("Not enough a header")
                // DEBUG only
                Logger.dumpBuffer("RTMPChunk_1 ERROR", buf: streamInBuffer.readBuffer, size: streamInBuffer.availableBytes)
                return false
            }
            chunk.body.replaceSubrange(0..., with: UnsafeRawBufferPointer(start: streamInBuffer.readBuffer+1, count: chunk.body.count))
            
            guard chunk.msg_length >= 0 else {
                Logger.debug("ERROR: Invalid header length")
                Logger.dumpBuffer("RTMPChunk_1 ERROR", buf: streamInBuffer.readBuffer, size: streamInBuffer.availableBytes)
                // FIXME: Clear the stream in buffer ?
                return false
            }
            
            if chunk.msg_length > 65535 {
                Logger.debug("Length too large ???:\(chunk.msg_length)")
            }
            
            var msg: [UInt8] = .init(repeating: 0, count: Int(chunk.msg_length))
            let full_msgsize = tryReadOneMessage(&msg, from_offset: 1+chunk.body.count)
            guard full_msgsize > 0 else {
                Logger.debug("Not enough one message in buffer")
                return false
            }
            streamInBuffer.didRead(1+chunk.body.count + full_msgsize)
            
            handleMessage(msg, msgTypeId: chunk.msg_type_id)
            
            previousChunk.msg_type_id = chunk.msg_type_id
            previousChunk.msg_length = chunk.msg_length
            return true
            
        case .timestamp:
            // the message length is the same as previous message.
            Logger.debug("Previous chunk length:\(previousChunk.msg_length), msgid:\(previousChunk.msg_type_id), streamid:\(String(describing: previousChunk.msg_stream_id))")
            var chunk: RTMPChunk_2 = .init()
            guard streamInBuffer.availableBytes >= 1+chunk.body.count else {
                Logger.debug("Not enough a header")
                // DEBUG only
                Logger.dumpBuffer("RTMPChunk_2 ERROR", buf: streamInBuffer.readBuffer, size: streamInBuffer.availableBytes)
                return false
            }
            chunk.body.replaceSubrange(0..., with: UnsafeRawBufferPointer(start: streamInBuffer.readBuffer+1, count: chunk.body.count))
            var msg: [UInt8] = .init(repeating: 0, count: Int(previousChunk.msg_length))
            let full_msgsize = tryReadOneMessage(&msg, from_offset: 1+chunk.body.count)
            guard full_msgsize > 0 else {
                Logger.debug("Not enough one message in buffer")
                return false
            }
            streamInBuffer.didRead(1+chunk.body.count + full_msgsize)
            handleMessage(msg, msgTypeId: previousChunk.msg_type_id)
            return true
            
        case .only:
            streamInBuffer.didRead(1)
            return true
        }
    }
    
    private func handleInvoke(_ p: [UInt8]) {
        var buflen = 0
        guard let command = get_string(p, bufsize: &buflen) else {
            Logger.debug("unexpected return")
            return
        }
        
        Logger.debug("Received invoke \(command)")
        
        switch command {
        case "_result":
            let pktId = Int32(get_double(p.dropFirst(11)))
            
            guard let trackedCommand = self.trackedCommands[pktId] else {
                Logger.debug("unexpected return")
                return
            }
            
            Logger.debug("Find command: \(trackedCommand) for ID:\(pktId)")
            switch trackedCommand {
            case "connect":
                sendReleaseStream()
                sendFCPublish()
                sendCreateStream()
                setClientState(.fCPublish)
            case "createStream":
                if p[10] != 0 || p[19] != 0x05 || p[20] != 0 {
                    Logger.info("RTMP: Unexpected reply on connect()")
                } else {
                    streamId = Int32(get_double(p.dropFirst(21)))
                }
                sendPublish()
                setClientState(.ready)
            default:
                break
            }
            
        case "onStatus":
            let code = parseStatusCode(p.dropFirst(3 + command.count))
            Logger.debug("code : \(String(describing: code))")
            if code == "NetStream.Publish.Start" {
                
                sendHeaderPacket()
                
                sendSetChunkSize(getpagesize())
                
                setClientState(.sessionStarted)
                
                throughputSession.start()
            }
        default:
            break
        }
    }
    
    private func handleUserControl(_ p: [UInt8]) {
        let eventType = get_be16(p)
        
        Logger.debug("Received userControl \(eventType)")
        
        switch eventType {
        case 6:
            sendPong()

        default:
            break
        }
    }
    
    @discardableResult
    private func handleMessage(_ p: [UInt8], msgTypeId: RtmpPt) -> Bool {
        var ret = true
        Logger.debug("Handle message:\(msgTypeId)")
        switch msgTypeId {
        case .bytesRead:
            break
        case .chunkSize:
            let newChunkSize = get_be32(p)
            Logger.debug("Request to change incoming chunk size from \(inChunkSize) -> \(newChunkSize)")
            inChunkSize = newChunkSize
        case .userControl:
            Logger.debug("Received ping, sending pong.")
            handleUserControl(p)
        case .serverWindow:
            Logger.debug("Received server window size: \(get_be32(p))")
        case .peerBw:
            Logger.debug("Received peer bandwidth limit: \(get_be32(p)) type: \(p[4])")
        case .invoke:
            Logger.debug("Received invoke")
            handleInvoke(p)
        case .video:
            Logger.debug("Received video")
        case .audio:
            Logger.debug("Received audio")
        case .metadata:
            Logger.debug("Received metadata")
        case .notify:
            Logger.debug("Received notify")
        default:
            Logger.warn("Received unknown packet type: \(msgTypeId)")
            ret = false
        }
        return ret
    }
    
    private func parseStatusCode(_ p: ArraySlice<UInt8>) -> String? {
        var props: [String:String] = .init()
        
        // skip over the packet id
        _ = get_double(p.dropFirst(1))  // num
        var p = p.dropFirst(MemoryLayout<Double>.size + 1)
        
        // keep reading until we find an AMF Object
        var foundObject = false
        while !foundObject {
            if p[p.startIndex] == AMFDataType.object.rawValue {
                p = p.dropFirst(1)
                foundObject = true
                continue
            } else {
                p = p.dropFirst(Int(amfPrimitiveObjectSize(p)))
            }
        }
        
        // read the properties of the object
        var nameLen: UInt16 = 0
        var valLen: UInt16 = 0
        var propName: String = ""
        var propVal: String = ""
        propName.reserveCapacity(128)
        propVal.reserveCapacity(128)
        repeat {
            nameLen = UInt16(get_be16(p))
            p = p.dropFirst(MemoryLayout<UInt16>.size)
            propName = String(data: .init(p.prefix(Int(nameLen))), encoding: .utf8) ?? ""
            p = p.dropFirst(Int(nameLen))
            if p[p.startIndex] == AMFDataType.string.rawValue {
                valLen = UInt16(get_be16(p.dropFirst(1)))
                p = p.dropFirst(MemoryLayout<UInt16>.size + 1)
                propVal = String(data: .init(p.prefix(Int(valLen))), encoding: .utf8) ?? ""
                p = p.dropFirst(Int(valLen))
                props[propName] = propVal
            } else {
                // treat non-string property values as empty
                p = p.dropFirst(Int(amfPrimitiveObjectSize(p)))
                props[propName] = ""
            }
            // Fix large AMF object may break to multiple packets
            // that crash us.
            if propName == "code" {
                break
            }
        } while get_be24(p) != AMFDataType.objectEnd.rawValue
        
        return props["code"]
    }
    
    private func amfPrimitiveObjectSize(_ p: ArraySlice<UInt8>) -> Int32 {
        guard let dataType = AmfDataType(rawValue: p[p.startIndex]) else {
            Logger.debug("unexpected return")
            return -1
        }
        switch dataType {
        case .number:
            return 9
        case .bool:
            return 2
        case .null:
            return 1
        case .string:
            return 3 + Int32(get_be16(p))
        case .longString:
            return 5 + Int32(get_be32(p))
        default:
            break
        }
        return -1; // not a primitive, likely an object
    }
    
    private func trackCommand(_ cmd: String) -> Int32 {
        numberOfInvokes += 1
        trackedCommands[numberOfInvokes] = cmd
        Logger.debug("Tracking command(\(numberOfInvokes), \(cmd)")
        return numberOfInvokes
    }
}
