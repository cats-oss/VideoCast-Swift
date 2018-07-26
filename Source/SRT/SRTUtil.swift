//
//  SRTUtil.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/03/07.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

func createAddrInet(_ name: String, port: UInt16) throws -> sockaddr_in {
    var sa: sockaddr_in = .init()
    sa.sin_family = sa_family_t(AF_INET)
    sa.sin_port = CFSwapInt16HostToBig(port)

    if ( !name.isEmpty ) {
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
