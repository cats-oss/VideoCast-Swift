//
//  RTMPSession.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

public typealias RTMPSessionParameters =
    MetaData<(width: Int, height: Int, frameDuration: Double, videoBitrate: Int,
    audioFrequency: Double, stereo: Bool)>
public typealias RTMPMetadata =
    MetaData<(chunkStreamId: ChunkStreamId, timestamp: Int, msgLength: Int,
    msgTypeId: RtmpPt, msgStreamId: ChannelStreamId, isKeyframe: Bool)>

public typealias RTMPSessionStateCallback = (_ session: RTMPSession, _ state: RTMPClientState) -> Void

open class RTMPSession: IOutputSession {
    private let kMaxSendbufferSize = 10 * 1024 * 1024   // 10 MB
    let networkQueue: JobQueue = .init("jp.co.cyberagent.VideoCast.rtmp.network")
    let jobQueue: JobQueue = .init("jp.co.cyberagent.VideoCast.rtmp")
    private var sentKeyframe: Date = .init()

    private let networkWaitSemaphore: DispatchSemaphore = .init(value: 0)

    var s1: Data = .init()
    var c1: Data = .init()
    var uptime: UInt32 = 0

    let throughputSession: TCPThroughputAdaptation = .init()

    private let previousTs: UInt64 = 0
    var previousChunkMap: [UInt8: RTMPChunk0] = .init()

    private var previousChunkData: [ChunkStreamId: UInt64] = .init()

    let streamInBuffer: PreallocBuffer = .init(4096)
    private let streamSession: IStreamSession = StreamSession()
    let uri: URL

    private let callback: RTMPSessionStateCallback

    let playPath: String
    let app: String
    var trackedCommands: [Int32: String] = .init()

    var outChunkSize: Int = 128
    var inChunkSize: Int = 128
    private var bufferSize: Int64 = 0

    var streamId: Int32 = 0
    var numberOfInvokes: Int32 = 0
    var frameWidth: Int32 = 0
    var frameHeight: Int32 = 0
    var bitrate: Int32 = 0
    var frameDuration: Double = 0
    var audioSampleRate: Double = 0
    var audioStereo: Bool = false

    var state: RTMPClientState = .none

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

    func write(_ data: UnsafePointer<UInt8>, size: Int, packetTime: Date = .init(), isKeyframe: Bool = false) {
        if size > 0 {
            var buf = Data(capacity: size)
            buf.append(data, count: size)

            throughputSession.addBufferSizeSample(Int(bufferSize))

            increaseBuffer(Int64(size))
            if isKeyframe {
                sentKeyframe = packetTime
            }
            if bufferSize > kMaxSendbufferSize && isKeyframe {
                clearing = true
            }
            networkQueue.enqueue {
                buf.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
                    var p = ptr
                    var tosend = buf.count

                    while tosend > 0 && !self.ending && (!self.clearing || self.sentKeyframe == packetTime) {
                        self.clearing = false
                        let sent = self.streamSession.write(p, size: tosend)
                        p += sent
                        tosend -= sent
                        self.throughputSession.addSentBytesSample(sent)
                        if sent == 0 {
                            _ = self.networkWaitSemaphore.wait(timeout: DispatchTime.now() +
                                DispatchTimeInterval.seconds(1))
                        }
                    }
                }

                self.increaseBuffer(-Int64(size))
            }
        }

    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
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
                        s1 = Data(capacity: kRTMPSignatureSize)
                        s1.append(streamInBuffer.readBuffer, count: kRTMPSignatureSize)
                        streamInBuffer.didRead(kRTMPSignatureSize)
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

    func setClientState(_ state: RTMPClientState) {
        self.state = state
        callback(self, state)
    }

    private func increaseBuffer(_ size: Int64) {
        bufferSize = max(bufferSize + size, 0)
    }

    private func reassembleBuffer(_ p: UnsafePointer<UInt8>, msgSize: Int, packageSize: Int) {

    }

    func trackCommand(_ cmd: String) -> Int32 {
        numberOfInvokes += 1
        trackedCommands[numberOfInvokes] = cmd
        Logger.debug("Tracking command(\(numberOfInvokes), \(cmd)")
        return numberOfInvokes
    }

    open func reset() {
        sentKeyframe = .init()

        state = .none

        s1.removeAll()
        c1.removeAll()
        uptime = 0

        previousChunkMap = .init()
        previousChunkData = .init()
        trackedCommands = .init()

        streamSession.disconnect()
        streamInBuffer.reset()

        outChunkSize = 128
        inChunkSize = 128
        bufferSize = 0

        streamId = 0
        numberOfInvokes = 0
    }
}

extension RTMPSession {
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
        reset()
        let port = uri.port ?? 1935
        Logger.info("Connecting:\(host):\(port), stream name:\(playPath)")
        streamSession.negotiateSSL = (uri.scheme?.lowercased() == "rtmps")
        streamSession.connect(host: host, port: port, sscb: { [weak self] (_, status) in
            self?.streamStatusChanged(status)
        })
    }

    // swiftlint:disable:next function_body_length
    open func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        guard !ending,
            let inMetadata = metadata as? RTMPMetadata,
            let metaData = inMetadata.data,
            state.rawValue >= RTMPClientState.handshakeComplete.rawValue,
            state.rawValue <= RTMPClientState.sessionStarted.rawValue
            else { return }

        // make the lamdba capture the data
        var buf = Data(capacity: size)
        buf.append(data.assumingMemoryBound(to: UInt8.self), count: size)

        jobQueue.enqueue {
            if !self.ending {
                let packetTime = Date()

                var chunk: [UInt8] = .init()
                chunk.reserveCapacity(size+64)
                var len = buf.count
                var tosend = min(len, self.outChunkSize)
                buf.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
                    var p = ptr
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
                        // msg stream id is little-endian
                        put_buff(&chunk, src: &streamId, srcsize: MemoryLayout<Int32>.size)
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
        throughputSession.setThroughputCallback(callback)
    }
}
