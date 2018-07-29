//
//  SRTUtil.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/03/07.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

func printSrtStats(_ sid: Int, mon: CBytePerfMon) {
    Logger.info("======= SRT STATS: sid=\(sid)")
    Logger.info(String(format: "PACKETS     SENT: %11d  RECEIVED:   %11d", mon.pktSent, mon.pktRecv))
    Logger.info(String(format: "LOST PKT    SENT: %11d  RECEIVED:   %11d", mon.pktSndLoss, mon.pktRcvLoss))
    Logger.info(String(format: "REXMIT      SENT: %11d  RECEIVED:   %11d", mon.pktRetrans, mon.pktRcvRetrans))
    Logger.info(String(format: "DROP PKT    SENT: %11d  RECEIVED:   %11d", mon.pktSndDrop, mon.pktRcvDrop))
    Logger.info(String(format: "RATE     SENDING: %11d  RECEIVING:  %11d", mon.mbpsSendRate, mon.mbpsRecvRate))
    Logger.info(String(format: "BELATED RECEIVED: %11d  AVG TIME:   %11d", mon.pktRcvBelated, mon.pktRcvAvgBelatedTime))
    Logger.info(String(format: "REORDER DISTANCE: %11d", mon.pktReorderDistance))
    Logger.info(String(format: "WINDOW      FLOW: %11d  CONGESTION: %11d  FLIGHT: %11d",
                       mon.pktFlowWindow, mon.pktCongestionWindow, mon.pktFlightSize))
    Logger.info(String(format: "LINK         RTT: %9dms  BANDWIDTH:  %7dMb/s ", mon.msRTT, mon.mbpsBandwidth))
    Logger.info(String(format: "BUFFERLEFT:  SND: %11d  RCV:        %11d", mon.byteAvailSndBuf, mon.byteAvailRcvBuf))
}

func parseSrtUri(_ uri: String) throws -> (host: String, port: Int, par: [String: String]) {
    guard let u = URLComponents(string: uri),
        let scheme = u.scheme, scheme == "srt",
        let host = u.host else {
            throw SRTError.invalidArgument(message: "Invalid uri")
    }
    guard let port = u.port, port > 1024 else {
        Logger.error("Port value invalid: \(String(describing: u.port)) - must be >1024")
        throw SRTError.invalidArgument(message: "Invalid port number")
    }
    var params = [String: String]()

    if let queryItems = u.queryItems {
        for queryItem in queryItems {
            params[queryItem.name] = queryItem.value
        }
    }

    return (host, port, params)
}

func createAddrInet(_ name: String, port: UInt16) throws -> sockaddr_in {
    var sa: sockaddr_in = .init()
    sa.sin_family = sa_family_t(AF_INET)
    sa.sin_port = CFSwapInt16HostToBig(port)

    if !name.isEmpty {
        if inet_pton(AF_INET, name, &sa.sin_addr) == 1 {
            return sa
        }

        // XXX RACY!!! Use getaddrinfo() instead. Check portability.
        // Windows/Linux declare it.
        // See:
        //  http://www.winsocketdotnetworkprogramming.com/winsock2programming/winsock2advancedInternet3b.html
        guard let he = gethostbyname(name), he.pointee.h_addrtype == AF_INET else {
            throw SRTError.invalidArgument(message: "SrtSource: host not found: \(name)")
        }

        sa.sin_addr = UnsafeRawPointer(he.pointee.h_addr_list[0]!).assumingMemoryBound(to: in_addr.self).pointee
    }

    return sa
}
