//
//  TSMultiplexerWriter.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/28/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import Foundation
import CoreMedia

extension TSMultiplexer {
    private func write_pat() {
        var data: [UInt8] = .init()
        data.reserveCapacity(C.SECTION_LENGTH)

        for service in ts.services {
            TSMultiplexer.put16(&data, val: service.sid)
            TSMultiplexer.put16(&data, val: 0xe000 | service.pmt.pid)
        }
        ts.pat.write_section1(C.PAT_TID, id: ts.tsid, version: ts.tables_version, sec_num: 0, last_sec_num: 0,
                              buf: data, len: data.count)
    }

    private func putstr8(_ q_ptr: inout [UInt8], str: String, write_len: Int) {
        let len = str.count
        if write_len > 0 {
            q_ptr.append(UInt8(len))
        }
        q_ptr.append(contentsOf: str.utf8)
    }

    private func write_pmt(_ service: MpegTSService) {
        var data: [UInt8] = .init()
        data.reserveCapacity(C.SECTION_LENGTH)
        var val: Int, stream_type: Int, err: Bool = false
        var i: Int = 0

        TSMultiplexer.put16(&data, val: 0xe000 | service.pcr_pid)

        val = 0xf000
        data.append(UInt8((val >> 8) & 0xff))
        data.append(UInt8(val & 0xff))

        for st in streams {
            guard let ts_st = st.data else { continue }

            if data.count > C.SECTION_LENGTH - 32 {
                err = true
                break
            }
            switch st.mediaType {
            case .video:
                if st.videoCodecType == kCMVideoCodecType_H264 {
                    stream_type = C.STREAM_TYPE_VIDEO_H264
                } else if st.videoCodecType == kCMVideoCodecType_HEVC {
                    stream_type = C.STREAM_TYPE_VIDEO_HEVC
                } else {
                    stream_type = C.STREAM_TYPE_PRIVATE_DATA
                }
            case .audio:
                stream_type = C.STREAM_TYPE_AUDIO_AAC
            default:
                stream_type = C.STREAM_TYPE_PRIVATE_DATA
            }

            data.append(UInt8(stream_type))
            TSMultiplexer.put16(&data, val: 0xe000 | ts_st.pid)

            val = 0xf000
            data.append(UInt8((val >> 8) & 0xff))
            data.append(UInt8(val & 0xff))

            i += 1
        }

        if err {
            Logger.error("""
                The PMT section cannot fit stream \(i) and all following streams.
                Try reducing the number of languages in the audio streams or the total number of streams.
                """)
        }

        service.pmt.write_section1(C.PMT_TID, id: service.sid, version: ts.tables_version, sec_num: 0, last_sec_num: 0,
                                   buf: data, len: data.count)
    }

    private func write_sdt() {
        var data: [UInt8] = .init()
        data.reserveCapacity(C.SECTION_LENGTH)
        var desc_list_len_index: Int
        var desc_len_index: Int
        var running_status: Int, free_ca_mode: Int, val: Int

        TSMultiplexer.put16(&data, val: ts.onid)
        data.append(0xff)
        for service in ts.services {
            TSMultiplexer.put16(&data, val: service.sid)
            data.append(0xfc | 0x00) /* currently no EIT info */
            desc_list_len_index = data.count
            data.append(contentsOf: [UInt8](repeating: 0x00, count: 2))
            running_status    = 4; /* running */
            free_ca_mode      = 0

            /* write only one descriptor for the service name and provider */
            data.append(0x48)
            desc_len_index = data.count
            data.append(0x00)
            data.append(UInt8(ts.service_type.rawValue))
            putstr8(&data, str: service.provider_name, write_len: 1)
            putstr8(&data, str: service.name, write_len: 1)
            data[desc_len_index] = UInt8(data.count - desc_len_index - 1)

            /* fill descriptor length */
            val = (running_status << 13) | (free_ca_mode << 12) |
                (data.count - desc_list_len_index - 2)
            data[desc_list_len_index] = UInt8((val >> 8) & 0xff)
            data[desc_list_len_index + 1] = UInt8(val & 0xff)
        }
        ts.sdt.write_section1(C.SDT_TID, id: ts.tsid, version: ts.tables_version, sec_num: 0, last_sec_num: 0,
                              buf: data, len: data.count)
    }

    func prefix_m2ts_header() {
        if ts.m2ts_mode {
            let pcr = ts.get_pcr(sentByte)
            var tp_extra_header = UInt32(pcr.value % 0x3fffffff)
            tp_extra_header = CFSwapInt32(tp_extra_header)
            write(&tp_extra_header, size: MemoryLayout<UInt32>.size)
        }
    }

    /* send SDT, PAT and PMT tables regularly */
    private func retransmit_si_info(_ force_pat: Bool, dts: CMTime?) {
        ts.sdt_packet_count += 1
        if (ts.sdt_packet_count == ts.sdt_packet_period) ||
            (dts != nil && ts.last_sdt_ts == nil) ||
            isTimeSinceLastOverPeriod(dts, last_ts: ts.last_sdt_ts, period: ts.sdt_period) {
            ts.sdt_packet_count = 0
            if let dts = dts {
                if let last_ts = ts.last_sdt_ts {
                    ts.last_sdt_ts = max(dts, last_ts)
                } else {
                    ts.last_sdt_ts = dts
                }
            }
            write_sdt()
        }
        ts.pat_packet_count += 1
        if (ts.pat_packet_count == ts.pat_packet_period) ||
            (dts != nil && ts.last_pat_ts == nil) ||
            isTimeSinceLastOverPeriod(dts, last_ts: ts.last_pat_ts, period: ts.pat_period) ||
            force_pat {
            ts.pat_packet_count = 0
            if let dts = dts {
                if let last_ts = ts.last_pat_ts {
                    ts.last_pat_ts = max(dts, last_ts)
                } else {
                    ts.last_pat_ts = dts
                }
            }
            write_pat()
            for i in 0..<ts.services.count {
                write_pmt(ts.services[i])
            }
        }
    }

    private func isTimeSinceLastOverPeriod(_ dts: CMTime?, last_ts: CMTime?, period: CMTime) -> Bool {
        guard let dts = dts, let last_ts = last_ts else { return false }
        return dts - last_ts > period
    }

    @discardableResult
    private func write_pcr_bits(_ buf: inout [UInt8], pcr: CMTime) -> Int {
        assert(pcr.timescale == C.PCR_TIME_BASE)
        let pcr_low: Int64 = pcr.value % 300
        let pcr_high: Int64 = pcr.value / 300

        buf.append(UInt8((pcr_high >> 25) & 0xff))
        buf.append(UInt8((pcr_high >> 17) & 0xff))
        buf.append(UInt8((pcr_high >>  9) & 0xff))
        buf.append(UInt8((pcr_high >>  1) & 0xff))
        buf.append(UInt8((pcr_high <<  7 | pcr_low >> 8 | 0x7e) & 0xff))
        buf.append(UInt8(pcr_low & 0xff))

        return 6
    }

    /* Write a single null transport stream packet */
    private func insert_null_packet() {
        var buf: [UInt8] = .init()
        buf.reserveCapacity(C.TS_PACKET_SIZE)

        buf.append(0x47)
        buf.append(0x00 | 0x1f)
        buf.append(0xff)
        buf.append(0x10)
        buf.append(contentsOf: [UInt8](repeating: 0xFF, count: C.TS_PACKET_SIZE - buf.count))
        prefix_m2ts_header()
        write(buf, size: C.TS_PACKET_SIZE)
    }

    /* Write a single transport stream packet with a PCR and no payload */
    private func insert_pcr_only(_ st: Stream) {
        guard let ts_st = st.data else { return }
        var buf: [UInt8] = .init()
        buf.reserveCapacity(C.TS_PACKET_SIZE)

        buf.append(0x47)
        buf.append(UInt8((ts_st.pid >> 8) & 0xff))
        buf.append(UInt8(ts_st.pid & 0xff))
        buf.append(UInt8(0x20 | ts_st.cc))   /* Adaptation only */
        /* Continuity Count field does not increment (see 13818-1 section 2.4.3.3) */
        buf.append(UInt8(C.TS_PACKET_SIZE - 5)) /* Adaptation Field Length */
        buf.append(0x10)               /* Adaptation flags: PCR present */
        if ts_st.discontinuity {
            buf[buf.count - 2] |= 0x80
            ts_st.discontinuity = false
        }

        /* PCR coded into 6 bytes */
        write_pcr_bits(&buf, pcr: ts.get_pcr(sentByte))

        /* stuffing bytes */
        buf.append(contentsOf: [UInt8](repeating: 0xFF, count: C.TS_PACKET_SIZE - buf.count))
        prefix_m2ts_header()
        write(buf, size: C.TS_PACKET_SIZE)
    }

    private func write_pts(_ q: inout [UInt8], fourbits: Int, pts: CMTime) {
        let pts = pts.convertScale(90000, method: .default)

        var val  = fourbits << 4 | Int(((pts.value >> 30) & 0x07) << 1) | 1
        q.append(UInt8(val))
        val  = Int(((pts.value >> 15) & 0x7fff) << 1) | 1
        q.append(UInt8((val >> 8) & 0xff))
        q.append(UInt8(val & 0xff))
        val  = Int(((pts.value) & 0x7fff) << 1) | 1
        q.append(UInt8((val >> 8) & 0xff))
        q.append(UInt8(val & 0xff))
    }

    /* Set an adaptation field flag in an MPEG-TS packet*/
    private func set_af_flag(_ pkt: inout [UInt8], flag: UInt8) {
        // expect at least one flag to set
        assert(flag != 0)

        if (pkt[3] & 0x20) == 0 {
            // no AF yet, set adaptation field flag
            pkt[3] |= 0x20
            // 1 byte length, no flags
            pkt[4] = 1
            pkt[5] = 0
        }
        pkt[5] |= flag
    }

    /* Extend the adaptation field by size bytes */
    private func extend_af(_ pkt: inout [UInt8], size: UInt8) {
        // expect already existing adaptation field
        assert((pkt[3] & 0x20) != 0)
        pkt[4] += size
    }

    /* Get a pointer to MPEG-TS payload (right after TS packet header) */
    private func get_ts_payload_start(_ pkt: inout [UInt8]) {
        let startAt: Int
        if (pkt[3] & 0x20) != 0 {
            startAt =  5 + Int(pkt[4])
        } else {
            startAt = 4
        }
        if pkt.count > startAt {
            pkt.removeLast(pkt.count - startAt)
        } else if pkt.count < startAt {
            pkt.append(contentsOf: [UInt8](repeating: 0x00, count: startAt - pkt.count))
        }
    }

    /* Add a PES header to the front of the payload, and segment into an integer
     * number of TS packets. The final TS packet is padded using an oversized
     * adaptation header to exactly fill the last TS packet.
     * NOTE: 'payload' contains a complete PES payload. */
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func write_pes(
        _ st: Stream,
        payload: UnsafePointer<UInt8>,
        payload_size: Int,
        pts: CMTime?,
        dts: CMTime?,
        key: Bool,
        steram_id: Int) {
        guard let ts_st = st.data, let service = ts_st.service else { return }
        var payload = payload
        var payload_size = payload_size
        var buf: [UInt8] = .init()
        buf.reserveCapacity(C.TS_PACKET_SIZE)

        var val: Int, is_start: Bool, len: Int, header_len: Int, write_pcr: Bool, flags: Int
        var afc_len: Int, stuffing_len: Int
        var pcr: CMTime /* avoid warning */
        let delay: CMTime = max_delay.convertScale(90000, method: .default)
        var force_pat: Bool = st.mediaType == .video && key && !ts_st.prev_payload_key

        //assert(ts_st.payload != buf || st.mediaType != .video)
        if ts.flags.contains(.pat_pmt_at_frames) && st.mediaType == .video {
            force_pat = true
        }

        is_start = true
        while payload_size > 0 {
            retransmit_si_info(force_pat, dts: dts)
            force_pat = false

            write_pcr = false
            if ts_st.pid == service.pcr_pid {
                if ts.mux_rate > 1 || is_start { // VBR pcr period is based on frames
                    service.pcr_packet_count += 1
                }
                if service.pcr_packet_count >=
                    service.pcr_packet_period {
                    service.pcr_packet_count = 0
                    write_pcr = true
                }
            }

            if ts.mux_rate > 1, let dts = dts,
                dts - ts.get_pcr(sentByte) > delay {
                /* pcr insert gets priority over null packet insert */
                if write_pcr {
                    insert_pcr_only(st)
                } else {
                    insert_null_packet()
                }
                /* recalculate write_pcr and possibly retransmit si_info */
                continue
            }

            /* prepare packet header */
            buf.removeAll(keepingCapacity: true)
            buf.append(0x47)
            val  = ts_st.pid >> 8
            if is_start {
                val |= 0x40
            }
            buf.append(UInt8(val))
            buf.append(UInt8(ts_st.pid & 0xff))
            ts_st.cc = (ts_st.cc + 1) & 0xf
            buf.append(UInt8(0x10 | ts_st.cc)) // payload indicator + CC

            // For writing af flag
            buf.append(contentsOf: [UInt8](repeating: 0x00, count: 3))

            if ts_st.discontinuity {
                set_af_flag(&buf, flag: 0x80)
                ts_st.discontinuity = false
            }
            if key && is_start && pts != nil {
                // set Random Access for key frames
                if ts_st.pid == service.pcr_pid {
                    write_pcr = true
                }
                set_af_flag(&buf, flag: 0x40)
            }
            if write_pcr {
                set_af_flag(&buf, flag: 0x10)
                get_ts_payload_start(&buf)
                // add 11, pcr references the last byte of program clock reference base
                if ts.mux_rate > 1 {
                    pcr = ts.get_pcr(sentByte)
                } else {
                    if let dts = dts {
                        pcr = (dts - delay).convertScale(C.PCR_TIME_BASE, method: .default)
                    } else {
                        pcr = .init(value: Int64.min, timescale: C.PCR_TIME_BASE)
                    }
                }
                if let dts = dts, dts < pcr {
                    Logger.warn("dts < pcr, TS is invalid")
                }
                extend_af(&buf, size: UInt8(write_pcr_bits(&buf, pcr: pcr)))
            }

            get_ts_payload_start(&buf)
            if is_start {
                /* write PES header */
                buf.append(0x00)
                buf.append(0x00)
                buf.append(0x01)
                if st.mediaType == .video {
                    buf.append(0xe0)
                } else if st.mediaType == .audio {
                    buf.append(0xc0)
                } else {
                    Logger.error("unsupported mediaType = \(st.mediaType)")
                }
                header_len = 0
                flags      = 0
                if pts != nil {
                    header_len += 5
                    flags      |= 0x80
                }
                if dts != nil && pts != nil && dts != pts {
                    header_len += 5
                    flags      |= 0x40
                }
                len = payload_size + header_len + 3
                if len > 0xffff {
                    len = 0
                }
                if ts.omit_video_pes_length && st.mediaType == .video {
                    len = 0
                }
                buf.append(UInt8((len >> 8) & 0xff))
                buf.append(UInt8(len & 0xff))
                val  = 0x80
                buf.append(UInt8(val))
                buf.append(UInt8(flags))
                buf.append(UInt8(header_len))
                if let pts = pts {
                    write_pts(&buf, fourbits: flags >> 6, pts: pts)
                }
                if let dts = dts, let pts = pts, dts != pts {
                    write_pts(&buf, fourbits: 1, pts: dts)
                }

                is_start = false
            }
            /* header size */
            header_len = buf.count
            /* data len */
            len = C.TS_PACKET_SIZE - header_len
            if len > payload_size {
                len = payload_size
            }
            stuffing_len = C.TS_PACKET_SIZE - header_len - len
            if stuffing_len > 0 {
                /* add stuffing with AFC */
                if (buf[3] & 0x20) != 0 {
                    /* stuffing already present: increase its size */
                    afc_len = Int(buf[4] + 1)
                    buf.insert(contentsOf: [UInt8](repeating: 0xff, count: stuffing_len), at: 4 + afc_len)
                    buf[4] += UInt8(stuffing_len)
                } else {
                    /* add stuffing */
                    buf.insert(contentsOf: [UInt8](repeating: 0xff, count: stuffing_len), at: 4)
                    buf[3] |= 0x20
                    buf[4]  = UInt8(stuffing_len - 1)
                    if stuffing_len >= 2 {
                        buf[5] = 0x00
                    }
                }
            }

            let expectedBufCount = C.TS_PACKET_SIZE - len
            if buf.count > expectedBufCount {
                buf.removeLast(buf.count - expectedBufCount)
            } else if buf.count < expectedBufCount {
                buf.append(contentsOf: [UInt8](repeating: 0x00, count: expectedBufCount - buf.count))
            }

            buf.append(contentsOf: UnsafeBufferPointer<UInt8>(start: payload, count: len))

            payload += len
            payload_size -= len
            prefix_m2ts_header()
            write(buf, size: C.TS_PACKET_SIZE)
        }
        ts_st.prev_payload_key = key
        write(buf, size: 0)
    }

    private func write_flush() {
        /* flush current packets */
        for st in streams {
            guard let ts_st = st.data else { continue }
            if !ts_st.payload.isEmpty {
                write_pes(st, payload: ts_st.payload, payload_size: ts_st.payload.count,
                          pts: ts_st.payload_pts, dts: ts_st.payload_dts,
                          key: ts_st.key, steram_id: -1)
                ts_st.payload.removeAll(keepingCapacity: true)
            }
        }
    }

    func write(_ buf: UnsafeRawPointer, size: Int) {
        let outMeta: TSMetadata = .init()
        output?.pushBuffer(buf, size: size, metadata: outMeta)
        sentByte += Int64(size)
    }
}
