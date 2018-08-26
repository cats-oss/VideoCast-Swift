//
//  MpegTSSection.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/28/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import Foundation

extension TSMultiplexer {
    /*********************************************/
    /* mpegts section writer */
    class MpegTSSection {
        var pid: Int = 0
        var cc: Int = 0
        var discontinuity: Bool = false
        weak var parent: TSMultiplexer?

        init() {
        }

        func write_section(_ buf: inout [UInt8]) {
            var packet: [UInt8] = .init()
            packet.reserveCapacity(C.TS_PACKET_SIZE)
            let crc = CFSwapInt32(CRC.shared.calculate(.crc32IEEE, crc: UInt32.max, buffer: buf, length: buf.count))
            var first: Bool
            var b: UInt8
            var len1: Int

            buf.append(UInt8((crc >> 24) & 0xff))
            buf.append(UInt8((crc >> 16) & 0xff))
            buf.append(UInt8((crc >>  8) & 0xff))
            buf.append(UInt8(crc & 0xff))

            var len = buf.count

            /* send each packet */
            var bi = 0
            while len > 0 {
                packet.removeAll(keepingCapacity: true)
                first = (bi == 0)
                packet.append(0x47)
                b = UInt8((pid >> 8) & 0xff)
                if first {
                    b |= 0x40
                }
                packet.append(b)
                packet.append(UInt8(pid & 0xff))
                cc = (cc + 1) & 0xf
                packet.append(0x10 | UInt8(cc))
                if discontinuity {
                    packet[packet.count - 2] |= 0x20
                    packet.append(1)
                    packet.append(0x80)
                    discontinuity = false
                }
                if first {
                    packet.append(0)   /* 0 offset */
                }
                len1 = C.TS_PACKET_SIZE - packet.count
                if len1 > len {
                    len1 = len
                }
                packet.append(contentsOf: buf[bi..<bi + len1])
                /* add known padding data */
                let left = C.TS_PACKET_SIZE - packet.count
                if left > 0 {
                    packet.append(contentsOf: [UInt8](repeating: 0xFF, count: left))
                }

                write_packet(packet)

                bi += len1
                len -= len1
            }
        }

        @discardableResult
        func write_section1(_ tid: Int, id: Int,
                            version: Int, sec_num: Int, last_sec_num: Int,
                            buf: [UInt8], len: Int) -> Bool {
            var section: [UInt8] = .init()
            section.reserveCapacity(1024)
            /* reserved_future_use field must be set to 1 for SDT */
            let flags: Int = (tid == C.SDT_TID) ? 0xf000 : 0xb000

            let tot_len = 3 + 5 + len + 4
            /* check if not too big */
            guard tot_len <= 1024 else {
                Logger.error("invalid data")
                return false
            }

            section.append(UInt8(tid))
            put16(&section, val: flags | len + 5 + 4)    /* 5 byte header + 4 byte CRC */
            put16(&section, val: id)
            section.append(UInt8(0xc1 | (version << 1)))    /* current_next_indicator = 1 */
            section.append(UInt8(sec_num))
            section.append(UInt8(last_sec_num))
            section.append(contentsOf: buf[..<len])

            write_section(&section)
            return true
        }

        func write_packet(_ packet: [UInt8]) {
            parent?.prefix_m2ts_header()
            parent?.write(packet, size: C.TS_PACKET_SIZE)
        }
    }
}
