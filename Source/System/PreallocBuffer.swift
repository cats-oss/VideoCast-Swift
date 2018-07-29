//
//  PreallocBuffer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/31.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

open class PreallocBuffer {
    open var availableBytes: Int { // for read
        return writePointer - readPointer
    }
    open var readBuffer: UnsafeMutablePointer<UInt8> {
        return readPointer
    }

    open var availableSpace: Int { // for write
        return preBufferSize - (writePointer - preBuffer)
    }
    open var writeBuffer: UnsafeMutablePointer<UInt8> {
        return writePointer
    }

    private var preBuffer: UnsafeMutablePointer<UInt8>
    private var preBufferSize: Int

    private var readPointer: UnsafeMutablePointer<UInt8>
    private var writePointer: UnsafeMutablePointer<UInt8>

    init(_ capBytes: Int) {
        preBufferSize = capBytes
        preBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capBytes)

        readPointer = preBuffer
        writePointer = preBuffer
    }

    deinit {
        preBuffer.deallocate()
    }

    open func ensureCapacityForWrite(_ capBytes: Int) {
        let availableSpace = self.availableSpace
        if capBytes > availableSpace {
            let additionalBytes = capBytes - availableSpace
            let newPreBufferSize = preBufferSize + additionalBytes
            let newPreBuffer = realloc(preBuffer, newPreBufferSize).assumingMemoryBound(to: UInt8.self)

            let readPointerOffset = readPointer - preBuffer
            let writePointerOffset = writePointer - preBuffer

            preBuffer = newPreBuffer
            preBufferSize = newPreBufferSize
            readPointer = preBuffer + readPointerOffset
            writePointer = preBuffer + writePointerOffset
        }
    }

    open func didRead(_ bytesRead: Int) {
        readPointer += bytesRead

        assert(readPointer <= writePointer)

        if readPointer == writePointer {
            reset()
        }
    }

    open func didWrite(_ bytesWritten: Int) {
        writePointer += bytesWritten
        assert(writePointer <= (preBuffer + preBufferSize))
    }

    open func reset() {
        readPointer = preBuffer
        writePointer = preBuffer
    }

    open func dumpInfo() {
        Logger.debug("PreallocBuffer begin:\(preBufferSize), " +
            "writer:\(writePointer)(\(availableSpace), reader:\(readPointer)(\(availableBytes)")
    }
}
