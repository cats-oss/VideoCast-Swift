//
//  RTMPSessionHandshake.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/28/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import Foundation

extension RTMPSession {
    func handshake() {
        switch state {
        case .connected:
            handshake0()
        case .handshake0:
            handshake1()
        case .handshake1s1:
            handshake2()
        default:
            c1.resize(0)
            s1.resize(0)
        }
    }

    private func handshake0() {
        var c0: UInt8 = 0x03

        setClientState(.handshake0)

        write(&c0, size: 1)

        handshake()
    }

    private func handshake1() {
        setClientState(.handshake1s0)

        c1.resize(kRTMPSignatureSize)
        var ptr: UnsafePointer<UInt8>?
        c1.read(&ptr, size: kRTMPSignatureSize)
        guard let p = ptr else {
            Logger.debug("unexpected return")
            return
        }

        uptime = CFSwapInt32HostToBig(UInt32(ProcessInfo().systemUptime * 1000))
        c1.put(&uptime, size: MemoryLayout<UInt32>.size)

        var zero: UInt32 = 0
        c1.append(&zero, size: MemoryLayout<UInt32>.size)

        let sig = c1.getMutable()
        for i in 8 ..< kRTMPSignatureSize {
            sig[i] = UInt8(arc4random_uniform(256))
        }

        write(p, size: kRTMPSignatureSize)
    }

    private func handshake2() {
        setClientState(.handshake2)
        var ptr: UnsafePointer<UInt8>?
        s1.read(&ptr, size: kRTMPSignatureSize)
        guard var p = ptr else {
            Logger.debug("unexpected return")
            return
        }
        p += 4
        memcpy(UnsafeMutablePointer<UInt8>(mutating: p), &uptime, MemoryLayout<UInt32>.size)

        write(s1.get(), size: s1.size)
    }
}
