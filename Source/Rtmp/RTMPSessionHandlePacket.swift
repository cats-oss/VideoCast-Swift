//
//  RTMPSessionHandlePacket.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/28/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import Foundation

extension RTMPSession {
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
            msg.replaceSubrange(
                msg_offset...,
                with: UnsafeBufferPointer<UInt8>(start: streamInBuffer.readBuffer+buf_offset, count: inChunkSize))
            msg_offset += inChunkSize
            buf_offset += inChunkSize+1
            remain -= inChunkSize
        }
        if remain > 0 {
            msg.replaceSubrange(
                msg_offset...,
                with: UnsafeBufferPointer<UInt8>(start: streamInBuffer.readBuffer+buf_offset, count: remain))
        }

        return full_msg_length
    }

    // Parse only one message every time, loop in the caller
    // If data not enough for one message, return false, else return true;
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func parseCurrentData() -> Bool {
        Logger.verbose("Steam in buffer size:\(streamInBuffer.availableBytes)")
        guard streamInBuffer.availableBytes > 0 else {
            Logger.debug("No data in buffer")
            return false
        }

        var first_byte: UInt8
        // at least one byte in current buffer.
        first_byte = streamInBuffer.readBuffer.pointee
        let header_type = (first_byte & 0xC0) >> 6
        let chunk_stream_id = first_byte & 0x3F
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
            var chunk: RTMPChunk0 = .init()
            // at least a full header bytes in current buffer
            guard streamInBuffer.availableBytes >= 1+chunk.body.count else {
                Logger.debug("Not enough a header")
                // DEBUG only
                Logger.dumpBuffer("RTMPChunk0", buf: streamInBuffer.readBuffer, size: streamInBuffer.availableBytes)
                return false
            }

            chunk.body.replaceSubrange(
                0...,
                with: UnsafeRawBufferPointer(start: streamInBuffer.readBuffer+1, count: chunk.body.count))
            guard chunk.msg_length >= 0 else {
                Logger.debug("ERROR: Invalid header length")
                Logger.dumpBuffer("RTMPChunk0 ERROR",
                                  buf: streamInBuffer.readBuffer, size: streamInBuffer.availableBytes)
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
            previousChunkMap[chunk_stream_id] = chunk
            return true

        case .noMsgStreamId:
            guard var previousChunk = previousChunkMap[chunk_stream_id] else {
                Logger.error("could not find previous chunk with stream id \(chunk_stream_id)")
                return false
            }
            var chunk: RTMPChunk1 = .init()
            guard streamInBuffer.availableBytes >= 1+chunk.body.count else {
                Logger.debug("Not enough a header")
                // DEBUG only
                Logger.dumpBuffer("RTMPChunk1 ERROR",
                                  buf: streamInBuffer.readBuffer, size: streamInBuffer.availableBytes)
                return false
            }
            chunk.body.replaceSubrange(
                0...,
                with: UnsafeRawBufferPointer(start: streamInBuffer.readBuffer+1, count: chunk.body.count))

            guard chunk.msg_length >= 0 else {
                Logger.debug("ERROR: Invalid header length")
                Logger.dumpBuffer("RTMPChunk1 ERROR",
                                  buf: streamInBuffer.readBuffer, size: streamInBuffer.availableBytes)
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
            previousChunkMap[chunk_stream_id] = previousChunk
            return true

        case .timestamp:
            guard let previousChunk = previousChunkMap[chunk_stream_id] else {
                Logger.error("could not find previous chunk with stream id \(chunk_stream_id)")
                return false
            }
            // the message length is the same as previous message.
            Logger.debug("Previous chunk length:\(previousChunk.msg_length), " +
                "msgid:\(previousChunk.msg_type_id), streamid:\(String(describing: previousChunk.msg_stream_id))")
            var chunk: RTMPChunk2 = .init()
            guard streamInBuffer.availableBytes >= 1+chunk.body.count else {
                Logger.debug("Not enough a header")
                // DEBUG only
                Logger.dumpBuffer("RTMPChunk2 ERROR",
                                  buf: streamInBuffer.readBuffer, size: streamInBuffer.availableBytes)
                return false
            }
            chunk.body.replaceSubrange(
                0...,
                with: UnsafeRawBufferPointer(start: streamInBuffer.readBuffer+1, count: chunk.body.count))
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
            guard let previousChunk = previousChunkMap[chunk_stream_id] else {
                Logger.error("could not find previous chunk with stream id \(chunk_stream_id)")
                return false
            }
            // the message length is the same as previous message.
            Logger.debug("Previous chunk length:\(previousChunk.msg_length), " +
                "msgid:\(previousChunk.msg_type_id), streamid:\(String(describing: previousChunk.msg_stream_id))")
            guard streamInBuffer.availableBytes >= 1 else {
                Logger.debug("Not enough a header")
                // DEBUG only
                Logger.dumpBuffer("RTMPChunk3 ERROR",
                                  buf: streamInBuffer.readBuffer, size: streamInBuffer.availableBytes)
                return false
            }
            var msg: [UInt8] = .init(repeating: 0, count: Int(previousChunk.msg_length))
            let full_msgsize = tryReadOneMessage(&msg, from_offset: 1)
            guard full_msgsize > 0 else {
                Logger.debug("Not enough one message in buffer")
                return false
            }
            streamInBuffer.didRead(1 + full_msgsize)
            handleMessage(msg, msgTypeId: previousChunk.msg_type_id)
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
    // swiftlint:disable:next cyclomatic_complexity
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
        var props: [String: String] = .init()

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
                let size = Int(amfPrimitiveObjectSize(p))
                if size > 0 {
                    p = p.dropFirst(size)
                } else {
                    break
                }
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
}
