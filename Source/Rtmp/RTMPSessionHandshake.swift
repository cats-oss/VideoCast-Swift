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
            c1.removeAll()
            s1.removeAll()
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

        c1.removeAll()
        c1.reserveCapacity(kRTMPSignatureSize)

        uptime = CFSwapInt32HostToBig(UInt32(ProcessInfo().systemUptime * 1000))
        withUnsafeBytes(of: &uptime, {
            c1.append($0.bindMemory(to: UInt8.self))
        })

        var zero: UInt32 = 0
        withUnsafeBytes(of: &zero, {
            c1.append($0.bindMemory(to: UInt8.self))
        })

        for _ in 8 ..< kRTMPSignatureSize {
            c1.append(UInt8(arc4random_uniform(256)))
        }

        c1.withUnsafeBytes {
            guard let p = $0.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                Logger.error("unaligned pointer \($0)")
                return
            }
            write(p, size: c1.count)
        }
    }

    private func handshake2() {
        setClientState(.handshake2)
        s1.withUnsafeMutableBytes {
            guard let p = $0.baseAddress?.assumingMemoryBound(to: UInt32.self) else {
                Logger.error("unaligned pointer \($0)")
                return
            }
            (p + 1).pointee = uptime
        }

        s1.withUnsafeBytes {
            guard let p = $0.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                Logger.error("unaligned pointer \($0)")
                return
            }
            write(p, size: s1.count)
        }
    }
}
