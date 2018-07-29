//
//  MpegTSWrite.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/28/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import Foundation
import CoreMedia

extension TSMultiplexer {
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
        var first_pcr: CMTime = .init(value: 0, timescale: C.PCR_TIME_BASE)
        var mux_rate: Int = 1   ///< set to 1 when VBR
        var pes_payload_size: Int = C.DEFAULT_PES_PAYLOAD_SIZE   // Minimum PES packet payload in bytes

        var transport_stream_id: Int = 0x0001
        var original_network_id: Int = C.DVB_PRIVATE_NETWORK_START
        var service_id: Int = 0x0001
        var service_type: MpegTSServiceType = .digital_tv

        var pmt_start_pid: Int  = 0x1000    // the first pid of the PMT
        var start_pid: Int = 0x0100 // the first pid
        var m2ts_mode: Bool = false // Enable m2ts mode

        var pcr_period: CMTime = C.PCR_RETRANS_TIME  // PCR retransmission time in milliseconds
        var flags: MpegTSFlags = []
        var copyts: Bool = false    // don't offset dts/pts
        var tables_version: Int = 0 //  PAT, PMT and SDT version
        // PAT/PMT retransmission time limit in seconds
        var pat_period: CMTime = .init(value: CMTimeValue(Int32.max), timescale: 1)
        // SDT retransmission time limit in seconds
        var sdt_period: CMTime = .init(value: CMTimeValue(Int32.max), timescale: 1)
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
            return curTime.convertScale(C.PCR_TIME_BASE, method: .default) + first_pcr
        }
    }
}
