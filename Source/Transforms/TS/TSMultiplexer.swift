//
//  TSMultiplexer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/19.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import CoreMedia
import AVFoundation

public typealias TSMetadata = MetaData<()>

private let TS_PACKET_SIZE: Int = 188

/* pids */
private let PAT_PID: Int = 0x0000
private let SDT_PID: Int = 0x0011

/* table ids */
private let PAT_TID: Int = 0x00
private let PMT_TID: Int = 0x02
private let M4OD_TID: Int = 0x05
private let SDT_TID: Int = 0x42

private let STREAM_TYPE_PRIVATE_DATA: Int = 0x06
private let STREAM_TYPE_AUDIO_AAC: Int = 0x0f
private let STREAM_TYPE_VIDEO_H264: Int = 0x1b
private let STREAM_TYPE_VIDEO_HEVC: Int = 0x24

private let PCR_TIME_BASE: Int32 = 27000000

/* write DVB SI sections */
private let DVB_PRIVATE_NETWORK_START: Int = 0xff01

private let DEFAULT_PES_HEADER_FREQ: Int = 16
private let DEFAULT_PES_PAYLOAD_SIZE: Int = ((DEFAULT_PES_HEADER_FREQ - 1) * 184 + 170)

/* The section length is 12 bits. The first 2 are set to 0, the remaining
 * 10 bits should not exceed 1021. */
private let SECTION_LENGTH: Int = 1020

/* mpegts writer */

private let DEFAULT_PROVIDER_NAME: String = "VideoCast"
private let DEFAULT_SERVICE_NAME: String = "Service01"

/* we retransmit the SI info at this rate */
private let SDT_RETRANS_TIME: CMTime = .init(value: 500, timescale: 1000)
private let PAT_RETRANS_TIME: CMTime = .init(value: 100, timescale: 1000)
private let PCR_RETRANS_TIME: CMTime = .init(value: 20, timescale: 1000)

private let NO_PTS: CMTime = .init(value: Int64.min, timescale: 90000)

private func put16(_ q_ptr: inout [UInt8], val: Int) {
    q_ptr.append(UInt8((val >> 8) & 0xff))
    q_ptr.append(UInt8(val & 0xff))
}

open class TSMultiplexer: ITransform {

    /*********************************************/
    /* mpegts section writer */
    class MpegTSSection {
        var pid: Int = 0
        var cc: Int = 0
        var discontinuity: Bool = false
        var parent: TSMultiplexer?

        init() {
        }

        func write_section(_ buf: inout [UInt8]) {
            var packet: [UInt8] = .init()
            packet.reserveCapacity(TS_PACKET_SIZE)
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
                len1 = TS_PACKET_SIZE - packet.count
                if len1 > len {
                    len1 = len
                }
                packet.append(contentsOf: buf[bi..<bi + len1])
                /* add known padding data */
                let left = TS_PACKET_SIZE - packet.count
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
            let flags: Int = (tid == SDT_TID) ? 0xf000 : 0xb000

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
            parent?.write(packet, size: TS_PACKET_SIZE)
        }
    }

    class MpegTSService {
        var pmt: MpegTSSection = .init()  /* MPEG-2 PMT table context */
        var sid: Int = 0
        var name: String = ""
        var provider_name: String = ""
        var pcr_pid: Int = 0x1fff
        var pcr_packet_count: Int = 0
        var pcr_packet_period: Int = 0

        init() {
        }
    }

    // service_type values as defined in ETSI 300 468
    enum MpegTSServiceType: Int {
        case digital_tv                     = 0x01  // Digital Television
        case digital_radio                  = 0x02  // Digital Radio
        case teletext                       = 0x03  // Teletext
        case advanced_codec_digital_radio   = 0x0A  // Advanced Codec Digital Radio
        case mpeg2_digital_hdtv             = 0x11  // MPEG2 Digital HDTV
        case advanced_codec_digital_sdtv    = 0x16  // Advanced Codec Digital SDTV
        case advanced_codec_digital_hdtv    = 0x19  // Advanced Codec Digital HDTV
        case hevc_digital_hdtv              = 0x1f  // HEVC Digital Television Service
    }

    struct MpegTSFlags: OptionSet {
        let rawValue: UInt8

        init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        static let resend_headers           = MpegTSFlags(rawValue: 0x01)   // Reemit PAT/PMT before writing the next packet
        static let latm                     = MpegTSFlags(rawValue: 0x02)   // Use LATM packetization for AAC
        static let pat_pmt_at_frames        = MpegTSFlags(rawValue: 0x04)   // Reemit PAT and PMT at each video frame
        static let system_b                 = MpegTSFlags(rawValue: 0x08)   // Conform to System B (DVB) instead of System A (ATSC)
        static let initial_discontinuity    = MpegTSFlags(rawValue: 0x10)   // Mark initial packets as discontinuous
    }

    class MpegTSWrite {
        var pat: MpegTSSection = .init()  /* MPEG-2 PAT table */
        var sdt: MpegTSSection = .init()  /* MPEG-2 SDT table context */
        var services: [MpegTSService] = .init()
        var sdt_packet_count: Int = 0
        var sdt_packet_period: Int = 0
        var pat_packet_count: Int = 0
        var pat_packet_period: Int = 0
        var onid: Int = 0
        var tsid: Int = 0
        var first_pcr: CMTime = .init(value: 0, timescale: PCR_TIME_BASE)
        var mux_rate: Int = 1   ///< set to 1 when VBR
        var pes_payload_size: Int = DEFAULT_PES_PAYLOAD_SIZE   // Minimum PES packet payload in bytes

        var transport_stream_id: Int = 0x0001
        var original_network_id: Int = DVB_PRIVATE_NETWORK_START
        var service_id: Int = 0x0001
        var service_type: MpegTSServiceType = .digital_tv

        var pmt_start_pid: Int  = 0x1000    // the first pid of the PMT
        var start_pid: Int = 0x0100 // the first pid
        var m2ts_mode: Bool = false // Enable m2ts mode

        var pcr_period: CMTime = PCR_RETRANS_TIME  // PCR retransmission time in milliseconds
        var flags: MpegTSFlags = []
        var copyts: Bool = false    // don't offset dts/pts
        var tables_version: Int = 0 //  PAT, PMT and SDT version
        var pat_period: CMTime = .init(value: CMTimeValue(Int32.max), timescale: 1)    // PAT/PMT retransmission time limit in seconds
        var sdt_period: CMTime = .init(value: CMTimeValue(Int32.max), timescale: 1)    // SDT retransmission time limit in seconds
        var last_pat_ts: CMTime?
        var last_sdt_ts: CMTime?

        var omit_video_pes_length: Bool = true  // Omit the PES packet length for video packets

        init() {

        }

        func add_service(_ sid: Int, provider_name: String, name: String) -> MpegTSService {
            let service = MpegTSService()

            service.pmt.pid = pmt_start_pid + services.count
            service.sid = sid
            service.pcr_pid = 0x1fff
            service.provider_name = provider_name
            service.name = name

            services.append(service)

            return service
        }

        func get_pcr(_ sentByte: Int64) -> CMTime {
            let curTime: CMTime = .init(value: sentByte * 8, timescale: Int32(mux_rate))
            return curTime.convertScale(PCR_TIME_BASE, method: .default) + first_pcr
        }
    }

    class MpegTSWriteStream {
        var service: MpegTSService?
        var pid: Int = 0    /* stream associated pid */
        var cc: Int = 15
        var discontinuity: Bool = false
        var first_pts_check: Bool = true   ///< first pts check needed
        var prev_payload_key: Bool = false
        var payload_pts: CMTime?
        var payload_dts: CMTime?
        var key: Bool = false
        var payload: [UInt8] = .init()
        var user_tb: CMTime = .init()

        init() {
        }
    }

    public class Stream {
        let id: Int
        let mediaType: AVMediaType
        let videoCodecType: CMVideoCodecType?
        let timeBase: CMTime
        var data: MpegTSWriteStream?

        init(id: Int, mediaType: AVMediaType, videoCodecType: CMVideoCodecType?, timeBase: CMTime) {
            self.id = id
            self.mediaType = mediaType
            self.videoCodecType = videoCodecType
            self.timeBase = timeBase
        }
    }

    private weak var output: IOutput?

    private let ctsOffset: CMTime

    private let ts: MpegTSWrite = .init()
    private let streams: [Stream]
    private let max_delay: CMTime = .init(value: 0, timescale: VC_TIME_BASE)  // maximum muxing or demuxing delay

    private var sentByte: Int64 = 0

    private let jobQueue: JobQueue = .init("jp.co.cyberagent.VideoCast.tsmux")

    public init(_ streams: [Stream], ctsOffset: CMTime = .init(value: 0, timescale: VC_TIME_BASE)) {
        self.ctsOffset = ctsOffset
        self.streams = streams

        var pcr_st: Stream? = nil

        self.ts.pes_payload_size = (ts.pes_payload_size + 14 + 183) / 184 * 184 - 14

        ts.tsid = ts.transport_stream_id
        ts.onid = ts.original_network_id

        /* allocate a single DVB service */
        let service_name = DEFAULT_SERVICE_NAME
        let provider_name = DEFAULT_PROVIDER_NAME
        let service = ts.add_service(ts.service_id,
                                     provider_name: provider_name, name: service_name)

        service.pmt.parent = self
        service.pmt.cc = 15
        service.pmt.discontinuity = ts.flags.contains(.initial_discontinuity)

        ts.pat.pid = PAT_PID
        /* Initialize at 15 so that it wraps and is equal to 0 for the
         * first packet we write. */
        ts.pat.cc = 15
        ts.pat.discontinuity = ts.flags.contains(.initial_discontinuity)
        ts.pat.parent = self

        ts.sdt.pid = SDT_PID
        ts.sdt.cc = 15
        ts.sdt.discontinuity = ts.flags.contains(.initial_discontinuity)
        ts.sdt.parent = self

        var pids = [Int](repeating: 0, count: streams.count)

        /* assign pids to each stream */
        for i in 0..<streams.count {
            let st = streams[i]
            let ts_st = MpegTSWriteStream()
            st.data = ts_st

            ts_st.user_tb = st.timeBase

            ts_st.payload = [UInt8](repeating: 0x00, count: ts.pes_payload_size)

            ts_st.service = service
            /* MPEG pid values < 16 are reserved. Applications which set st->id in
             * this range are assigned a calculated pid. */
            if st.id < 16 {
                ts_st.pid = ts.start_pid + i
            } else if (st.id < 0x1FFF) {
                ts_st.pid = st.id
            } else {
                Logger.error("Invalid stream id \(st.id), must be less than 8191")
                return
            }
            if (ts_st.pid == service.pmt.pid) {
                Logger.error("Duplicate stream id \(ts_st.pid)")
                return
            }
            for j in 0..<i {
                if (pids[j] == ts_st.pid) {
                    Logger.error("Duplicate stream id \(ts_st.pid)")
                    return
                }
            }
            pids[i] = ts_st.pid
            ts_st.payload_pts = nil
            ts_st.payload_dts = nil
            ts_st.first_pts_check = true
            ts_st.cc = 15
            ts_st.discontinuity = ts.flags.contains(.initial_discontinuity)
            /* update PCR pid by using the first video stream */
            if st.mediaType == .video &&
                service.pcr_pid == 0x1fff {
                service.pcr_pid = ts_st.pid
                pcr_st = st
            }
        }

        let ts_st_tmp: MpegTSWriteStream?

        /* if no video stream, use the first stream as PCR */
        if service.pcr_pid == 0x1fff && streams.count > 0 {
            pcr_st = streams[0]
            ts_st_tmp = pcr_st?.data
        } else {
            ts_st_tmp = pcr_st?.data
        }

        guard let ts_st = ts_st_tmp else { return }

        if ts.mux_rate > 1 {
            service.pcr_packet_period = Int(CMTimeMultiplyByRatio(ts.pcr_period, Int32(ts.mux_rate), Int32(TS_PACKET_SIZE * 8)).seconds)
            ts.sdt_packet_period = Int(CMTimeMultiplyByRatio(SDT_RETRANS_TIME, Int32(ts.mux_rate), Int32(TS_PACKET_SIZE * 8)).seconds)
            ts.pat_packet_period = Int(CMTimeMultiplyByRatio(PAT_RETRANS_TIME, Int32(ts.mux_rate), Int32(TS_PACKET_SIZE * 8)).seconds)

            if !ts.copyts {
                ts.first_pcr = max_delay.convertScale(PCR_TIME_BASE, method: .default)
            }
        } else {
            guard let pcr_st = pcr_st else { return }

            /* Arbitrary values, PAT/PMT will also be written on video key frames */
            ts.sdt_packet_period = 200
            ts.pat_packet_period = 40
            if pcr_st.mediaType == .audio {
                service.pcr_packet_period = Int(pcr_st.timeBase.timescale) / (10 * 512)
            } else {
                // max delta PCR 0.1s
                // TODO: should be avg_frame_rate
                service.pcr_packet_period = Int(ts_st.user_tb.timescale) / Int(10 * ts_st.user_tb.value)
            }
            if service.pcr_packet_period == 0 {
                service.pcr_packet_period = 1
            }
        }

        ts.last_pat_ts = nil
        ts.last_sdt_ts = nil
        // The user specified a period, use only it
        if ts.pat_period.seconds < Double(Int32.max/2) {
            ts.pat_packet_period = Int.max
        }
        if ts.sdt_period.seconds < Double(Int32.max/2) {
            ts.sdt_packet_period = Int.max
        }

        // output a PCR as soon as possible
        service.pcr_packet_count = service.pcr_packet_period
        ts.pat_packet_count = ts.pat_packet_period - 1
        ts.sdt_packet_count = ts.sdt_packet_period - 1

        if ts.mux_rate == 1 {
            Logger.verbose("muxrate VBR, ")
        } else {
            Logger.verbose("muxrate \(ts.mux_rate), ")
        }
        Logger.verbose("pcr every \(service.pcr_packet_period) pkts, sdt every \(ts.sdt_packet_period), pat/pmt every \(ts.pat_packet_period) pkts")
    }

    deinit {
        Logger.debug("TSMultiplexer::deinit")

        jobQueue.markExiting()
        jobQueue.enqueueSync {}
    }

    private func write_pat() {
        var data: [UInt8] = .init()
        data.reserveCapacity(SECTION_LENGTH)

        for service in ts.services {
            put16(&data, val: service.sid)
            put16(&data, val: 0xe000 | service.pmt.pid)
        }
        ts.pat.write_section1(PAT_TID, id: ts.tsid, version: ts.tables_version, sec_num: 0, last_sec_num: 0,
                              buf: data, len: data.count)
    }

    private func putstr8(_ q_ptr: inout [UInt8], str: String, write_len: Int) {
        let len = str.count
        if (write_len > 0) {
            q_ptr.append(UInt8(len))
        }
        q_ptr.append(contentsOf: str.utf8)
    }

    private func write_pmt(_ service: MpegTSService) {
        var data: [UInt8] = .init()
        data.reserveCapacity(SECTION_LENGTH)
        var val: Int, stream_type: Int, err: Bool = false
        var i: Int = 0

        put16(&data, val: 0xe000 | service.pcr_pid)

        val = 0xf000
        data.append(UInt8((val >> 8) & 0xff))
        data.append(UInt8(val & 0xff))

        for st in streams {
            guard let ts_st = st.data else { continue }

            if data.count > SECTION_LENGTH - 32 {
                err = true
                break
            }
            switch (st.mediaType) {
            case .video:
                if st.videoCodecType == kCMVideoCodecType_H264 {
                    stream_type = STREAM_TYPE_VIDEO_H264
                } else if st.videoCodecType == kCMVideoCodecType_HEVC {
                    stream_type = STREAM_TYPE_VIDEO_HEVC
                } else {
                    stream_type = STREAM_TYPE_PRIVATE_DATA
                }
            case .audio:
                stream_type = STREAM_TYPE_AUDIO_AAC
            default:
                stream_type = STREAM_TYPE_PRIVATE_DATA
            }

            data.append(UInt8(stream_type))
            put16(&data, val: 0xe000 | ts_st.pid)

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

        service.pmt.write_section1(PMT_TID, id: service.sid, version: ts.tables_version, sec_num: 0, last_sec_num: 0,
                                   buf: data, len: data.count)
    }

    private func write_sdt() {
        var data: [UInt8] = .init()
        data.reserveCapacity(SECTION_LENGTH)
        var desc_list_len_index: Int
        var desc_len_index: Int
        var running_status: Int, free_ca_mode: Int, val: Int

        put16(&data, val: ts.onid)
        data.append(0xff)
        for service in ts.services {
            put16(&data, val: service.sid)
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
        ts.sdt.write_section1(SDT_TID, id: ts.tsid, version: ts.tables_version, sec_num: 0, last_sec_num: 0,
                              buf: data, len: data.count)
    }

    private func prefix_m2ts_header() {
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
        assert(pcr.timescale == PCR_TIME_BASE)
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
        buf.reserveCapacity(TS_PACKET_SIZE)

        buf.append(0x47)
        buf.append(0x00 | 0x1f)
        buf.append(0xff)
        buf.append(0x10)
        buf.append(contentsOf: [UInt8](repeating: 0xFF, count: TS_PACKET_SIZE - buf.count))
        prefix_m2ts_header()
        write(buf, size: TS_PACKET_SIZE)
    }

    /* Write a single transport stream packet with a PCR and no payload */
    private func insert_pcr_only(_ st: Stream) {
        guard let ts_st = st.data else { return }
        var buf: [UInt8] = .init()
        buf.reserveCapacity(TS_PACKET_SIZE)

        buf.append(0x47)
        buf.append(UInt8((ts_st.pid >> 8) & 0xff))
        buf.append(UInt8(ts_st.pid & 0xff))
        buf.append(UInt8(0x20 | ts_st.cc))   /* Adaptation only */
        /* Continuity Count field does not increment (see 13818-1 section 2.4.3.3) */
        buf.append(UInt8(TS_PACKET_SIZE - 5)) /* Adaptation Field Length */
        buf.append(0x10)               /* Adaptation flags: PCR present */
        if (ts_st.discontinuity) {
            buf[buf.count - 2] |= 0x80
            ts_st.discontinuity = false
        }

        /* PCR coded into 6 bytes */
        write_pcr_bits(&buf, pcr: ts.get_pcr(sentByte))

        /* stuffing bytes */
        buf.append(contentsOf: [UInt8](repeating: 0xFF, count: TS_PACKET_SIZE - buf.count))
        prefix_m2ts_header()
        write(buf, size: TS_PACKET_SIZE)
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
    private func write_pes(_ st: Stream, payload: UnsafePointer<UInt8>, payload_size: Int,
                           pts: CMTime?, dts: CMTime?, key: Bool, steram_id: Int) {
        guard let ts_st = st.data, let service = ts_st.service else { return }
        var payload = payload
        var payload_size = payload_size
        var buf: [UInt8] = .init()
        buf.reserveCapacity(TS_PACKET_SIZE)

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
                if (write_pcr) {
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
            if (is_start) {
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
            if (write_pcr) {
                set_af_flag(&buf, flag: 0x10)
                get_ts_payload_start(&buf)
                // add 11, pcr references the last byte of program clock reference base
                if ts.mux_rate > 1 {
                    pcr = ts.get_pcr(sentByte)
                } else {
                    if let dts = dts {
                        pcr = (dts - delay).convertScale(PCR_TIME_BASE, method: .default)
                    } else {
                        pcr = .init(value: Int64.min, timescale: PCR_TIME_BASE)
                    }
                }
                if let dts = dts, dts < pcr {
                    Logger.warn("dts < pcr, TS is invalid")
                }
                extend_af(&buf, size: UInt8(write_pcr_bits(&buf, pcr: pcr)))
            }

            get_ts_payload_start(&buf)
            if (is_start) {
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
            len = TS_PACKET_SIZE - header_len
            if len > payload_size {
                len = payload_size
            }
            stuffing_len = TS_PACKET_SIZE - header_len - len
            if (stuffing_len > 0) {
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
                    if (stuffing_len >= 2) {
                        buf[5] = 0x00
                    }
                }
            }

            let expectedBufCount = TS_PACKET_SIZE - len
            if buf.count > expectedBufCount {
                buf.removeLast(buf.count - expectedBufCount)
            } else if buf.count < expectedBufCount {
                buf.append(contentsOf: [UInt8](repeating: 0x00, count: expectedBufCount - buf.count))
            }

            buf.append(contentsOf: UnsafeBufferPointer<UInt8>(start: payload, count: len))

            payload += len
            payload_size -= len
            prefix_m2ts_header()
            write(buf, size: TS_PACKET_SIZE)
        }
        ts_st.prev_payload_key = key
        write(buf, size: 0)
    }

    private func write_flush() {
        /* flush current packets */
        for st in streams {
            guard let ts_st = st.data else { continue }
            if ts_st.payload.count > 0 {
                write_pes(st, payload: ts_st.payload, payload_size: ts_st.payload.count,
                          pts: ts_st.payload_pts, dts: ts_st.payload_dts,
                          key: ts_st.key, steram_id: -1)
                ts_st.payload.removeAll(keepingCapacity: true)
            }
        }
    }

    private func write(_ buf: UnsafeRawPointer, size: Int) {
        let outMeta: TSMetadata = .init()
        output?.pushBuffer(buf, size: size, metadata: outMeta)
        sentByte += Int64(size)
    }

    public func setOutput(_ output: IOutput) {
        self.output = output
    }

    public func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        var pts = metadata.pts
        var dts = metadata.dts

        let buf = Buffer(size)
        buf.put(data, size: size)

        jobQueue.enqueue {
            var ptr: UnsafePointer<UInt8>?
            buf.read(&ptr, size: buf.size)
            guard let p = ptr else {
                Logger.debug("unexpected return")
                return
            }

            let st = self.streams[metadata.streamIndex]
            guard let ts_st = st.data else { return }
            let delay: CMTime = self.max_delay.convertScale(90000, method: .default)
            let stream_id = -1

            // correct for pts < dts which some players (ffmpeg) don't like
            pts = pts + self.ctsOffset
            dts = dts.isNumeric ? dts : (st.mediaType == .video ? pts - self.ctsOffset : pts)

            if self.ts.flags.contains(.resend_headers) {
                self.ts.pat_packet_count = self.ts.pat_packet_period - 1
                self.ts.sdt_packet_count = self.ts.sdt_packet_period - 1
                self.ts.flags.remove(.resend_headers)
            }

            if !self.ts.copyts {
                if pts.isNumeric {
                    pts = pts + delay
                }
                if dts.isNumeric {
                    dts = dts + delay
                }
            }

            guard !ts_st.first_pts_check || pts.isNumeric else {
                Logger.error("first pts value must be set")
                return
            }
            ts_st.first_pts_check = false

            let cond = { (dts: CMTime?, payload_dts: CMTime?, delay: CMTime) -> Bool in
                guard let dts = dts, let payload_dts = payload_dts else { return false }
                return dts - payload_dts > delay
            }

            if dts.isNumeric {
                for st2 in self.streams {
                    guard let ts_st2 = st2.data else { continue }
                    if ts_st2.payload.count > 0
                        && (ts_st2.payload_dts == nil || cond(dts, ts_st2.payload_dts, CMTimeMultiplyByRatio(delay, 1, 2))) {
                        self.write_pes(st2, payload: ts_st2.payload, payload_size: ts_st2.payload.count, pts: ts_st2.payload_pts, dts: ts_st2.payload_dts, key: ts_st2.key, steram_id: stream_id)
                        ts_st2.payload.removeAll(keepingCapacity: true)
                    }
                }
            }

            if ts_st.payload.count > 0 && (ts_st.payload.count + size > self.ts.pes_payload_size ||
                (dts.isNumeric && ts_st.payload_dts != nil &&
                    cond(dts, ts_st.payload_dts, self.max_delay))) {
                self.write_pes(st, payload: ts_st.payload, payload_size: ts_st.payload.count, pts: ts_st.payload_pts, dts: ts_st.payload_dts, key: ts_st.key, steram_id: stream_id)
                ts_st.payload.removeAll(keepingCapacity: true)
            }

            if st.mediaType != .audio || size > self.ts.pes_payload_size {
                assert(ts_st.payload.count == 0)
                // for video and subtitle, write a single pes packet
                self.write_pes(st, payload: p, payload_size: size, pts: pts, dts: dts, key: metadata.isKey, steram_id: stream_id)
                return
            }

            if ts_st.payload.count == 0 {
                ts_st.payload_pts = pts
                ts_st.payload_dts = dts
                ts_st.key = metadata.isKey
            }

            ts_st.payload.append(contentsOf: UnsafeBufferPointer<UInt8>(start: p, count: size))
        }
    }
}
