//
//  SRTUtil.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/03/07.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

func printSrtStats(_ sid: Int32, mon: inout CBytePerfMon) {
    let stats = SrtStats(sid, mon: &mon)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    // swiftlint:disable:next force_try
    let data = try! encoder.encode(stats)
    if let json = String(data: data, encoding: .utf8) {
        Logger.info(json)
    }
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
