//
//  SRTStats.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/08/15.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

class SrtStats: Codable {
    let sid: Int32
    let time: Int64
    let window: SrtStatsWindow
    let link: SrtStatsLink
    let send: SrtStatsSend
    let recv: SrtStatsRecv

    init(_ sid: Int32, mon: inout CBytePerfMon) {
        self.sid = sid
        self.time = mon.msTimeStamp
        self.window = SrtStatsWindow(&mon)
        self.link = SrtStatsLink(&mon)
        self.send = SrtStatsSend(&mon)
        self.recv = SrtStatsRecv(&mon)
    }
}

struct SrtStatsWindow: Codable {
    let flow: Int32
    let congestion: Int32
    let flight: Int32

    init(_ mon: inout CBytePerfMon) {
        flow = mon.pktFlowWindow
        congestion = mon.pktCongestionWindow
        flight = mon.pktFlightSize
    }
}

struct SrtStatsLink: Codable {
    let rtt: Double
    let bandwidth: Double
    let maxBandwidth: Double

    init(_ mon: inout CBytePerfMon) {
        rtt = mon.msRTT
        bandwidth = mon.mbpsBandwidth
        maxBandwidth = mon.mbpsMaxBW
    }
}

struct SrtStatsSend: Codable {
    let packets: Int64
    let packetsLost: Int32
    let packetsDropped: Int32
    let packetsRetransmitted: Int32
    let bytes: UInt64
    let bytesDropped: UInt64
    let mbitRate: Double

    init(_ mon: inout CBytePerfMon) {
        packets = mon.pktSent
        packetsLost = mon.pktSndLoss
        packetsDropped = mon.pktSndDrop
        packetsRetransmitted = mon.pktRetrans
        bytes = mon.byteSent
        bytesDropped = mon.byteSndDrop
        mbitRate = mon.mbpsSendRate
    }
}

struct SrtStatsRecv: Codable {
    let packets: Int64
    let packetsLost: Int32
    let packetsDropped: Int32
    let packetsRetransmitted: Int32
    let packetsBelated: Int64
    let bytes: UInt64
    let bytesLost: UInt64
    let bytesDropped: UInt64
    let mbitRate: Double

    init(_ mon: inout CBytePerfMon) {
        packets = mon.pktRecv
        packetsLost = mon.pktRcvLoss
        packetsDropped = mon.pktRcvDrop
        packetsRetransmitted = mon.pktRcvRetrans
        packetsBelated = mon.pktRcvBelated
        bytes = mon.byteRecv
        bytesLost = mon.byteRcvLoss
        bytesDropped = mon.byteRcvDrop
        mbitRate = mon.mbpsRecvRate
    }
}
