//
//  PutBits.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/28.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

class PutBits {
    var bit_buf: UInt32
    var bit_left: Int
    var buf: UnsafeMutableRawPointer
    var buf_ptr: UnsafeMutableRawPointer
    var buf_end: UnsafeMutableRawPointer
    var size_in_bits: Int

    init(_ buffer: UnsafeMutableRawPointer, buffer_size: Int) {
        size_in_bits = 8 * buffer_size
        buf = buffer
        buf_end = buf + buffer_size
        buf_ptr = buf
        bit_left = 32
        bit_buf = 0
    }

    func put_bits(_ n: Int, value: UInt32) {
        assert(n <= 31 && value < (1 << n))

        var bit_buf = self.bit_buf
        var bit_left = self.bit_left

        if n < bit_left {
            bit_buf = (bit_buf << n) | value
            bit_left -= n
        } else {
            bit_buf <<= bit_left
            bit_buf |= value >> (n - bit_left)
            if 3 < buf_end - buf_ptr {
                buf_ptr.assumingMemoryBound(to: UInt32.self).pointee = CFSwapInt32HostToBig(bit_buf)
                buf_ptr += 4
            } else {
                Logger.error("Internal error, put_bits buffer too small")
                assert(false)
            }
            bit_left += 32 - n
            bit_buf = value
        }

        self.bit_buf = bit_buf
        self.bit_left = bit_left
    }

    func flush_put_bits() {
        if bit_left < 32 {
            bit_buf <<= bit_left
        }
        while bit_left < 32 {
            assert(buf_ptr < buf_end)
            buf_ptr.assumingMemoryBound(to: UInt8.self).pointee = UInt8(bit_buf >> 24)
            buf_ptr += 1
            bit_buf <<= 8
            bit_left += 8
        }
        bit_left = 32
        bit_buf = 0
    }
}
