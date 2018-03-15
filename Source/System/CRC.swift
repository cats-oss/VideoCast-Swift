//
//  CRC.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/23.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

enum CRC_ID: Int {
    case crc8Atm = 0
    case crc16ANSI
    case crc16CCITT
    case crc32IEEE
    case crc32IEEE_LE
    case crc16ANSI_LE
    case crc24IEEE
    case crcMax
}

class CRC {
    static let shared = CRC()
    
    var table: [[UInt32]] = .init()
    
    private init() {
        for _ in 0..<CRC_ID.crcMax.rawValue {
            table.append([UInt32](repeating: 0, count: 1024))
        }
        crcInit(&table[CRC_ID.crc8Atm.rawValue], le: false, bits: 8, poly: 0x07, ctxSize: 1024)
        crcInit(&table[CRC_ID.crc16ANSI.rawValue], le: false, bits: 16, poly: 0x8005, ctxSize: 1024)
        crcInit(&table[CRC_ID.crc16CCITT.rawValue], le: false, bits: 16, poly: 0x1021, ctxSize: 1024)
        crcInit(&table[CRC_ID.crc24IEEE.rawValue], le: false, bits: 24, poly: 0x864CFB, ctxSize: 1024)
        crcInit(&table[CRC_ID.crc32IEEE.rawValue], le: false, bits: 32, poly: 0x04C11DB7, ctxSize: 1024)
        crcInit(&table[CRC_ID.crc32IEEE_LE.rawValue], le: false, bits: 32, poly: 0xEDB88320, ctxSize: 1024)
        crcInit(&table[CRC_ID.crc16ANSI_LE.rawValue], le: false, bits: 16, poly: 0xA001, ctxSize: 1024)
    }
    
    @discardableResult
    private func crcInit(_ ctx: inout [UInt32], le: Bool, bits: Int, poly: UInt32, ctxSize: Int) -> Bool {
        if bits < 8 || bits > 32 || poly >= (1 << bits) {
            return false
        }
        var c: Int32 = 0
        
        for i in 0 ..< 256 {
            if le {
                c = Int32(i)
                for _ in 0 ..< 8 {
                    c = (c >> 1) ^ (Int32(poly) & (-(c & 1)))
                }
                ctx[Int(i)] = UInt32(c)
            } else {
                c = Int32(truncatingIfNeeded: i << 24)
                for _ in 0 ..< 8 {
                    c = (c << 1) ^ (Int32(truncatingIfNeeded: poly << (32 - bits)) & (Int32(c) >> 31))
                }
                ctx[i] = CFSwapInt32(UInt32(truncatingIfNeeded: c));
            }
        }
        ctx[256] = 1;
        if ctxSize >= MemoryLayout<UInt32>.size * 1024 {
            for i in 0 ..< 256 {
                for j: Int in 0 ..< 3 {
                    let x = ctx[256 * j + i] >> 8
                    let y = ctx[Int(ctx[256 * j + i] & 0xFF)]
                    ctx[256 * (j + 1) + i] = x ^ y
                }
            }
        }
        return true
    }
    
    func calculate(_ crcId: CRC_ID, crc: UInt32,
                   buffer: [UInt8], length: Int) -> UInt32 {
        
        let ctx = table[crcId.rawValue]
        var crc = crc
        var buffer = buffer.withUnsafeBufferPointer { $0.baseAddress! }
        let end = buffer + length
        
        if ctx[256] == 0 {
            while ((Int(bitPattern: buffer) & 3) != 0 && buffer < end) {
                crc = ctx[Int(UInt8(crc) ^ buffer.pointee)] ^ (crc >> 8)
                buffer += 1
            }
            
            while (buffer < end - 3) {
                crc ^= CFSwapInt32LittleToHost(UnsafeRawPointer(buffer).load(as: UInt32.self))
                buffer += 4
                let c1 = ctx[Int(3 * 256 + ( crc        & 0xFF))]
                let c2 = ctx[Int(2 * 256 + ((crc >> 8 ) & 0xFF))]
                let c3 = ctx[Int(1 * 256 + ((crc >> 16) & 0xFF))]
                let c4 = ctx[Int(0 * 256 + ((crc >> 24)       ))]
                crc = c1 ^ c2 ^ c3 ^ c4
            }
        }
        
        while (buffer < end) {
            crc = ctx[Int(UInt8(crc & 0xff) ^ buffer.pointee)] ^ (crc >> 8)
            buffer += 1
        }
        
        return crc;
    }
}
