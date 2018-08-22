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

open class TSMultiplexer: ITransform {
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

    public typealias TSMetadata = MetaData<()>

    // swiftlint:disable:next type_name
    enum C {
        static let TS_PACKET_SIZE: Int = 188

        /* pids */
        static let PAT_PID: Int = 0x0000
        static let SDT_PID: Int = 0x0011

        /* table ids */
        static let PAT_TID: Int = 0x00
        static let PMT_TID: Int = 0x02
        static let M4OD_TID: Int = 0x05
        static let SDT_TID: Int = 0x42

        static let STREAM_TYPE_PRIVATE_DATA: Int = 0x06
        static let STREAM_TYPE_AUDIO_AAC: Int = 0x0f
        static let STREAM_TYPE_VIDEO_H264: Int = 0x1b
        static let STREAM_TYPE_VIDEO_HEVC: Int = 0x24

        static let PCR_TIME_BASE: Int32 = 27000000

        /* write DVB SI sections */
        static let DVB_PRIVATE_NETWORK_START: Int = 0xff01

        static let DEFAULT_PES_HEADER_FREQ: Int = 16
        static let DEFAULT_PES_PAYLOAD_SIZE: Int = ((DEFAULT_PES_HEADER_FREQ - 1) * 184 + 170)

        /* The section length is 12 bits. The first 2 are set to 0, the remaining
         * 10 bits should not exceed 1021. */
        static let SECTION_LENGTH: Int = 1020

        /* mpegts writer */

        static let DEFAULT_PROVIDER_NAME: String = "VideoCast"
        static let DEFAULT_SERVICE_NAME: String = "Service01"

        /* we retransmit the SI info at this rate */
        static let SDT_RETRANS_TIME: CMTime = .init(value: 500, timescale: 1000)
        static let PAT_RETRANS_TIME: CMTime = .init(value: 100, timescale: 1000)
        static let PCR_RETRANS_TIME: CMTime = .init(value: 20, timescale: 1000)

        static let NO_PTS: CMTime = .init(value: Int64.min, timescale: 90000)
    }

    weak var output: IOutput?

    private let ctsOffset: CMTime

    let ts: MpegTSWrite = .init()
    let streams: [Stream]
    let max_delay: CMTime = .init(value: 0, timescale: VC_TIME_BASE)  // maximum muxing or demuxing delay

    var sentByte: Int64 = 0

    private let jobQueue: JobQueue = .init("jp.co.cyberagent.VideoCast.tsmux")

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public init(_ streams: [Stream], ctsOffset: CMTime = .init(value: 0, timescale: VC_TIME_BASE)) {
        self.ctsOffset = ctsOffset
        self.streams = streams

        var pcr_st: Stream? = nil

        self.ts.pes_payload_size = (ts.pes_payload_size + 14 + 183) / 184 * 184 - 14

        ts.tsid = ts.transport_stream_id
        ts.onid = ts.original_network_id

        /* allocate a single DVB service */
        let service_name = C.DEFAULT_SERVICE_NAME
        let provider_name = C.DEFAULT_PROVIDER_NAME
        let service = ts.add_service(ts.service_id,
                                     provider_name: provider_name, name: service_name)

        service.pmt.parent = self
        service.pmt.cc = 15
        service.pmt.discontinuity = ts.flags.contains(.initial_discontinuity)

        ts.pat.pid = C.PAT_PID
        /* Initialize at 15 so that it wraps and is equal to 0 for the
         * first packet we write. */
        ts.pat.cc = 15
        ts.pat.discontinuity = ts.flags.contains(.initial_discontinuity)
        ts.pat.parent = self

        ts.sdt.pid = C.SDT_PID
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
            } else if st.id < 0x1FFF {
                ts_st.pid = st.id
            } else {
                Logger.error("Invalid stream id \(st.id), must be less than 8191")
                return
            }
            if ts_st.pid == service.pmt.pid {
                Logger.error("Duplicate stream id \(ts_st.pid)")
                return
            }
            for j in 0..<i where pids[j] == ts_st.pid {
                Logger.error("Duplicate stream id \(ts_st.pid)")
                return
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
        if service.pcr_pid == 0x1fff && !streams.isEmpty {
            pcr_st = streams[0]
            ts_st_tmp = pcr_st?.data
        } else {
            ts_st_tmp = pcr_st?.data
        }

        guard let ts_st = ts_st_tmp else { return }

        if ts.mux_rate > 1 {
            service.pcr_packet_period =
                Int(CMTimeMultiplyByRatio(ts.pcr_period, Int32(ts.mux_rate), Int32(C.TS_PACKET_SIZE * 8)).seconds)
            ts.sdt_packet_period =
                Int(CMTimeMultiplyByRatio(C.SDT_RETRANS_TIME, Int32(ts.mux_rate), Int32(C.TS_PACKET_SIZE * 8)).seconds)
            ts.pat_packet_period =
                Int(CMTimeMultiplyByRatio(C.PAT_RETRANS_TIME, Int32(ts.mux_rate), Int32(C.TS_PACKET_SIZE * 8)).seconds)

            if !ts.copyts {
                ts.first_pcr = max_delay.convertScale(C.PCR_TIME_BASE, method: .default)
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
        Logger.verbose("pcr every \(service.pcr_packet_period) pkts, " +
            "sdt every \(ts.sdt_packet_period), pat/pmt every \(ts.pat_packet_period) pkts")
    }

    deinit {
        Logger.debug("TSMultiplexer::deinit")

        jobQueue.markExiting()
        jobQueue.enqueueSync {}
    }

    static func put16(_ q_ptr: inout [UInt8], val: Int) {
        q_ptr.append(UInt8((val >> 8) & 0xff))
        q_ptr.append(UInt8(val & 0xff))
    }
}

extension TSMultiplexer {
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

    public func setOutput(_ output: IOutput) {
        self.output = output
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        var pts = metadata.pts
        var dts = metadata.dts

        var buf = Data(capacity: size)
        buf.append(data.assumingMemoryBound(to: UInt8.self), count: size)

        jobQueue.enqueue {
            buf.withUnsafeBytes { (p: UnsafePointer<UInt8>) in
                let size = buf.count
                let st = self.streams[metadata.streamIndex]
                guard let ts_st = st.data else { return }
                let delay: CMTime = self.max_delay.convertScale(90000, method: .default)
                let stream_id = -1

                // correct for pts < dts which some players (ffmpeg) don't like
                // swiftlint:disable:next shorthand_operator
                pts = pts + self.ctsOffset
                dts = dts.isNumeric ? dts : (st.mediaType == .video ? pts - self.ctsOffset : pts)

                if self.ts.flags.contains(.resend_headers) {
                    self.ts.pat_packet_count = self.ts.pat_packet_period - 1
                    self.ts.sdt_packet_count = self.ts.sdt_packet_period - 1
                    self.ts.flags.remove(.resend_headers)
                }

                if !self.ts.copyts {
                    if pts.isNumeric {
                        // swiftlint:disable:next shorthand_operator
                        pts = pts + delay
                    }
                    if dts.isNumeric {
                        // swiftlint:disable:next shorthand_operator
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
                        if !ts_st2.payload.isEmpty
                            && (ts_st2.payload_dts == nil ||
                                cond(dts, ts_st2.payload_dts, CMTimeMultiplyByRatio(delay, 1, 2))) {
                            self.write_pes(st2, payload: ts_st2.payload, payload_size: ts_st2.payload.count,
                                           pts: ts_st2.payload_pts, dts: ts_st2.payload_dts,
                                           key: ts_st2.key, steram_id: stream_id)
                            ts_st2.payload.removeAll(keepingCapacity: true)
                        }
                    }
                }

                if !ts_st.payload.isEmpty && (ts_st.payload.count + size > self.ts.pes_payload_size ||
                    (dts.isNumeric && ts_st.payload_dts != nil &&
                        cond(dts, ts_st.payload_dts, self.max_delay))) {
                    self.write_pes(st, payload: ts_st.payload, payload_size: ts_st.payload.count,
                                   pts: ts_st.payload_pts, dts: ts_st.payload_dts,
                                   key: ts_st.key, steram_id: stream_id)
                    ts_st.payload.removeAll(keepingCapacity: true)
                }

                if st.mediaType != .audio || size > self.ts.pes_payload_size {
                    assert(ts_st.payload.isEmpty)
                    // for video and subtitle, write a single pes packet
                    self.write_pes(st, payload: p, payload_size: size,
                                   pts: pts, dts: dts, key: metadata.isKey, steram_id: stream_id)
                    return
                }

                if ts_st.payload.isEmpty {
                    ts_st.payload_pts = pts
                    ts_st.payload_dts = dts
                    ts_st.key = metadata.isKey
                }

                ts_st.payload.append(contentsOf: UnsafeBufferPointer<UInt8>(start: p, count: size))
            }
        }
    }
}
