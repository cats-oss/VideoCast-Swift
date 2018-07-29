//
//  SRTModel.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/29/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import Foundation

// This class is used when we don't know yet whether the given URI
// designates an effective listener or caller. So we create it, initialize,
// then we know what mode we'll be using.
//
// When caller, then we will do connect() using this object, then clone out
// a new object - of a direction specific class - which will steal the socket
// from this one and then roll the data. After this, this object is ready
// to connect again, and will create its own socket for that occasion, and
// the whole procedure repeats.
//
// When listener, then this object will be doing accept() and with every
// successful acceptation it will clone out a new object - of a direction
// specific class - which will steal just the connection socket from this
// object. This object will still live on and accept new connections and
// so on.
class SrtModel: SrtCommon {
    var isCaller: Bool = false
    var host: String = ""
    var port: Int = 0

    init(_ host: String, port: Int, par: [String: String]) throws {
        super.init()
        try initParameters(host, par: par)
        if mode == "caller" {
            isCaller = true
        } else if mode != "listener" {
            throw SRTError.invalidArgument(message: "Only caller and listener modes supported")
        }

        self.host = host
        self.port = port
    }

    func establish(name: inout String) throws {
        // This does connect or accept.
        // When this returned true, the caller should create
        // a new SrtSource or SrtTaget then call StealFrom(*this) on it.

        // If this is a connector and the peer doesn't have a corresponding
        // medium, it should send back a single byte with value 0. This means
        // that agent should stop connecting.

        if isCaller {
            // Establish a connection

            try prepareClient()

            if !name.isEmpty {
                Logger.verbose("Connect with requesting stream [\(name)]")
                _ = name.withCString { udtSetStreamId(sock, $0) }
            } else {
                Logger.verbose("NO STREAM ID for SRT connection")
            }

            if outgoing_port > 0 {
                Logger.verbose("Setting outgoing port: \(outgoing_port)")
                try setupAdapter("", port: outgoing_port)
            }

            try connectClient(host, port: port)

            if outgoing_port == 0 {
                // Must rely on a randomly selected one. Extract the port
                // so that it will be reused next time.
                var s: sockaddr_in = .init()
                s.sin_family = sa_family_t(AF_INET)
                var namelen = Int32(MemoryLayout.size(ofValue: s))
                let stat = withUnsafeMutablePointer(to: &s) { ptr -> Int32 in
                    let ps = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
                    return srt_getsockname(sock, ps, &namelen)
                }
                if stat == SRT_ERROR {
                    try error(udtGetLastError(), src: "srt_getsockname")
                }

                outgoing_port = Int(CFSwapInt16BigToHost(s.sin_port))
                Logger.verbose("Extracted outgoing port: \(outgoing_port)")
            }
        } else {
            // Listener - get a socket by accepting.
            // Check if the listener is already created first
            if listener == SRT_INVALID_SOCK {
                Logger.verbose("Setting up listener: port=\(port) backlog=5")
                try prepareListener(adapter, port: port, backlog: 5)
            }

            Logger.verbose("Accepting a client...")
            try acceptNewClient()
            // This rewrites m_sock with a new SRT socket ("accepted" socket)
            if let cstr = udtGetStreamId(sock), let str = String(cString: cstr, encoding: String.Encoding.utf8) {
                name = str
            }
            Logger.verbose("... GOT CLIENT for stream [\(name)]")
        }
    }

    override func close() {
        if sock != SRT_INVALID_SOCK {
            unregisterEpoll()
            srt_close(sock)
            sock = SRT_INVALID_SOCK
        }
    }
}
