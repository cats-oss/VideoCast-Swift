//
//  SRTCommon.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 7/29/18.
//  Copyright © 2018 CyberAgent, Inc. All rights reserved.
//

import Foundation

class SrtCommon {
    var clear_stats: Int32 = 0

    //< Defines which of SND or RCV option variant should be used, also to set SRT_SENDER for output
    var output_direction: Bool = false
    var timeout: Int = 0 //< enforces using SRTO_SNDTIMEO or SRTO_RCVTIMEO, depending on @a m_output_direction
    var tsbpdmode: Bool = true
    var outgoing_port: Int = 0
    var mode: String = "default"
    var adapter: String = ""
    var options: [String: String] = .init()
    var sock: SRTSOCKET = SRT_INVALID_SOCK
    var srt_epoll: Int32?

    var payloadsize: Int32?

    var bindsock: SRTSOCKET = SRT_INVALID_SOCK
    var isUsable: Bool {
        let st = srt_getsockstate(sock)
        return st.rawValue > SRTS_INIT.rawValue && st.rawValue < SRTS_BROKEN.rawValue
    }

    var isBroken: Bool {
        return srt_getsockstate(sock).rawValue > SRTS_CONNECTED.rawValue
    }

    var socket: SRTSOCKET {
        return sock
    }

    var listener: SRTSOCKET {
        return bindsock
    }

    init() {

    }

    init(_ host: String, port: Int, par: [String: String], dir_output: Bool, pollid: Int32?) throws {
        output_direction = dir_output
        srt_epoll = pollid
        try initParameters(host, par: par)

        Logger.verbose("Opening SRT \(dir_output ? "target" : "source") \(mode)" +
            " on \(host):\(port)")

        switch mode {
        case "caller":
            try openClient(host, port: port)
        case "listener":
            try openServer(adapter, port: port)
        case "rendezvous":
            try openRendezvous(adapter, host: host, port: port)
        default:
            throw SRTError.invalidArgument(message: "Invalid 'mode'. Use 'client' or 'server'")
        }
    }

    deinit {
        close()
    }

    // swiftlint:disable:next cyclomatic_complexity
    func initParameters(_ host: String, par: [String: String]) throws {
        var par = par

        // Application-specific options: mode, blocking, timeout, adapter
        Logger.verbose("Parameters:\(par)")

        mode = "default"
        if let mode = par["mode"] {
            self.mode = mode
        }

        if mode == "default" {
            // Use the following convention:
            // 1. Server for source, Client for target
            // 2. If host is empty, then always server.
            if host == "" {
                mode = "listener"
            } else {
                mode = "caller"
            }
        }

        if mode == "client" {
            mode = "caller"
        } else if mode == "server" {
            mode = "listener"
        }

        par["mode"] = nil

        if let val = par["timeout"] {
            guard let timeout = Int(val) else {
                throw SRTError.invalidArgument(message: "timeout=\(val)")
            }
            self.timeout = timeout
            par["timeout"] = nil
        }

        if let adapter = par["adapter"] {
            self.adapter = adapter
            par["adapter"] = nil
        } else if mode == "listener" {
            // For listener mode, adapter is taken from host,
            // if 'adapter' parameter is not given
            adapter = host
        }

        if let tsbpd = par["tsbpd"], SRTSocketOption.false_names.contains(tsbpd) {
            tsbpdmode = false
        }

        if let val = par["port"] {
            guard let port = Int(val) else {
                throw SRTError.invalidArgument(message: "port=\(val)")
            }
            outgoing_port = port
            par["port"] = nil
        }

        // That's kinda clumsy, but it must rely on the defaults.
        // Default mode is live, so check if the file mode was enforced
        if let transtype = par["transtype"], transtype == "file" {
        } else {
            // If the Live chunk size was nondefault, enforce the size.
            if SrtConf.transmit_chunk_size != SRT_LIVE_DEF_PLSIZE {
                if SrtConf.transmit_chunk_size > SRT_LIVE_MAX_PLSIZE {
                    throw SRTError.runtime(message: "Chunk size in live mode exceeds 1456 bytes; this is not supported")
                }
                par["payloadsize"] = String(SrtConf.transmit_chunk_size)
            }
        }

        // Assign the others here.
        options = par
    }

    func prepareListener(_ host: String, port: Int, backlog: Int32) throws {
        bindsock = srt_socket(AF_INET, SOCK_DGRAM, 0)
        if bindsock == SRT_ERROR {
            try error(udtGetLastError(), src: "srt_socket")
        }

        var stat = configurePre(bindsock)
        if stat == SRT_ERROR {
            try error(udtGetLastError(), src: "ConfigurePre")
        }

        let sa = try createAddrInet(host, port: UInt16(port))
        var sa_copy = sa
        stat = withUnsafePointer(to: &sa_copy) { ptr -> Int32 in
            let psa = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
            Logger.verbose("Binding a server on \(host):\(port) ...")
            return srt_bind(bindsock, psa, Int32(MemoryLayout.size(ofValue: sa)))
        }
        if stat == SRT_ERROR {
            srt_close(bindsock)
            try error(udtGetLastError(), src: "srt_bind")
        }

        Logger.verbose(" listen...")
        stat = srt_listen(bindsock, backlog)
        if stat == SRT_ERROR {
            srt_close(bindsock)
            try error(udtGetLastError(), src: "srt_listen")
        }
    }

    func stealFrom(_ src: SrtCommon) {
        // This is used when SrtCommon class designates a listener
        // object that is doing Accept in appropriate direction class.
        // The new object should get the accepted socket.
        output_direction = src.output_direction
        timeout = src.timeout
        tsbpdmode = src.tsbpdmode
        bindsock = SRT_INVALID_SOCK // no listener
        sock = src.sock
        src.sock = SRT_INVALID_SOCK; // STEALING
    }

    @discardableResult
    func acceptNewClient() throws -> Bool {
        var scl: sockaddr_in = .init()
        var sclen: Int32 = Int32(MemoryLayout.size(ofValue: scl))

        Logger.verbose(" accept...")

        withUnsafeMutablePointer(to: &scl) {
            let pscl = UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self)

            sock = srt_accept(bindsock, pscl, &sclen)
        }

        if sock == SRT_INVALID_SOCK {
            srt_close(bindsock)
            bindsock = SRT_INVALID_SOCK
            try error(udtGetLastError(), src: "srt_accept")
        }
        registerEpoll()

        // we do one client connection at a time,
        // so close the listener.
        srt_close(bindsock)
        bindsock = SRT_INVALID_SOCK

        Logger.verbose(" connected.")

        // ConfigurePre is done on bindsock, so any possible Pre flags
        // are DERIVED by sock. ConfigurePost is done exclusively on sock.
        let stat = configurePost(sock)
        if stat == SRT_ERROR {
            try error(udtGetLastError(), src: "ConfigurePost")
        }

        return true
    }

    func close() {
        Logger.verbose("SrtCommon: DESTROYING CONNECTION, closing sockets (rt%\(sock) ls%\(bindsock)...")

        if sock != SRT_INVALID_SOCK {
            unregisterEpoll()
            srt_close(sock)
            sock = SRT_INVALID_SOCK
        }

        if bindsock != SRT_INVALID_SOCK {
            srt_close(bindsock)
            bindsock = SRT_INVALID_SOCK
        }
        Logger.verbose("SrtCommon: ... done.")
    }

    func error(_ udtError: UdtErrorInfo, src: String) throws {
        let str = String(cString: udtError.message)
        Logger.verbose("ERROR #\(udtError.code): \(str)")

        throw SRTError.transmission(message: "error: \(src): \(str)")
    }

    func configurePost(_ sock: SRTSOCKET) -> Int32 {
        var no: Int32 = 0
        var result: Int32 = 0
        if output_direction {
            result = srt_setsockopt(sock, 0, SRTO_SNDSYN, &no, Int32(MemoryLayout.size(ofValue: no)))
            if result == -1 {
                return result
            }

            if timeout > 0 {
                return srt_setsockopt(sock, 0, SRTO_SNDTIMEO, &timeout, Int32(MemoryLayout.size(ofValue: timeout)))
            }
        } else {
            result = srt_setsockopt(sock, 0, SRTO_RCVSYN, &no, Int32(MemoryLayout.size(ofValue: no)))
            if result == -1 {
                return result
            }

            if timeout > 0 {
                return srt_setsockopt(sock, 0, SRTO_RCVTIMEO, &timeout, Int32(MemoryLayout.size(ofValue: timeout)))
            }
        }

        var failures: [String] = .init()
        srtConfigurePost(sock, options: options, failures: &failures)
        for failure in failures {
            Logger.verbose("failed to set '\(failure)'" +
                "(post, \(output_direction ? "target" : "source")) to \(String(describing: options[failure]))")
        }

        return 0
    }

    func configurePre(_ sock: SRTSOCKET) -> Int32 {
        var result: Int32 = 0

        var no: Int32 = 0
        if !tsbpdmode {
            result = srt_setsockopt(sock, 0, SRTO_TSBPDMODE, &no, Int32(MemoryLayout.size(ofValue: no)))
            if result == -1 {
                return result
            }
        }

        result = srt_setsockopt(sock, 0, SRTO_RCVSYN, &no, Int32(MemoryLayout.size(ofValue: no)))
        if result == -1 {
            return result
        }

        // host is only checked for emptiness and depending on that the connection mode is selected.
        // Here we are not exactly interested with that information.
        var failures: [String] = .init()

        // NOTE: here host = "", so the 'connmode' will be returned as LISTENER always,
        // but it doesn't matter here. We don't use 'connmode' for anything else than
        // checking for failures.
        let conmode = srtConfigurePre(sock, host: "", options: &options, failures: &failures)

        if conmode == .failure {
            Logger.verbose("WARNING: failed to set options: \(failures.description)")

            return SRT_ERROR
        }

        return 0
    }

    func openClient(_ host: String, port: Int) throws {
        try prepareClient()

        if outgoing_port > 0 {
            try setupAdapter("", port: outgoing_port)
        }

        try connectClient(host, port: port)
    }

    func prepareClient() throws {
        sock = srt_socket(AF_INET, SOCK_DGRAM, 0)
        if sock == SRT_ERROR {
            try error(udtGetLastError(), src: "srt_socket")
        }
        registerEpoll()

        let stat = configurePre(sock)
        if stat == SRT_ERROR {
            try error(udtGetLastError(), src: "ConfigurePre")
        }
    }

    func setupAdapter(_ host: String, port: Int) throws {
        let localsa = try createAddrInet(host, port: UInt16(port))
        var sa = localsa
        let stat = withUnsafePointer(to: &sa) { ptr -> Int32 in
            let psa = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
            return srt_bind(sock, psa, Int32(MemoryLayout.size(ofValue: localsa)))
        }
        if stat == SRT_ERROR {
            try error(udtGetLastError(), src: "srt_bind")
        }
    }

    func connectClient(_ host: String, port: Int) throws {
        let sa = try createAddrInet(host, port: UInt16(port))
        var sa_copy = sa
        var stat = withUnsafePointer(to: &sa_copy) { ptr -> Int32 in
            let psa = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
            Logger.verbose("Connecting to \(host):\(port) ...")
            return srt_connect(sock, psa, Int32(MemoryLayout.size(ofValue: sa)))
        }
        if stat == SRT_ERROR {
            //srt_close(sock)
            try error(udtGetLastError(), src: "UDT::connect")
        }

        stat = configurePost(sock)
        if stat == SRT_ERROR {
            try error(udtGetLastError(), src: "ConfigurePost")
        }
    }

    func openServer(_ host: String, port: Int) throws {
        try prepareListener(host, port: port, backlog: 1)
    }

    func openRendezvous(_ adapter: String, host: String, port: Int) throws {
        sock = srt_socket(AF_INET, SOCK_DGRAM, 0)
        if sock == SRT_ERROR {
            try error(udtGetLastError(), src: "srt_socket")
        }
        registerEpoll()

        var yes: Int32 = 1
        srt_setsockopt(sock, 0, SRTO_RENDEZVOUS, &yes, Int32(MemoryLayout.size(ofValue: yes)))

        var stat = configurePre(sock)
        if stat == SRT_ERROR {
            try error(udtGetLastError(), src: "ConfigurePre")
        }

        let localsa = try createAddrInet(host, port: UInt16(port))
        var sa_copy = localsa
        stat = withUnsafePointer(to: &sa_copy) { ptr -> Int32 in
            let plsa = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
            Logger.verbose("Binding a server on \(adapter):\(port) ...")
            return srt_bind(sock, plsa, Int32(MemoryLayout.size(ofValue: localsa)))
        }
        if stat == SRT_ERROR {
            unregisterEpoll()
            srt_close(sock)
            try error(udtGetLastError(), src: "srt_bind")
        }

        let sa = try createAddrInet(host, port: UInt16(port))
        sa_copy = sa
        stat = withUnsafePointer(to: &sa_copy) { ptr -> Int32 in
            let psa = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
            Logger.verbose("Connecting to \(host):\(port) ...")
            return srt_connect(sock, psa, Int32(MemoryLayout.size(ofValue: sa)))
        }
        if stat == SRT_ERROR {
            srt_close(sock)
            try error(udtGetLastError(), src: "srt_connect")
        }

        stat = configurePost(sock)
        if stat == SRT_ERROR {
            try error(udtGetLastError(), src: "ConfigurePost")
        }
    }

    func registerEpoll() {
        if let eid = srt_epoll {
            var events: Int32 = Int32(SRT_EPOLL_IN.rawValue | SRT_EPOLL_OUT.rawValue | SRT_EPOLL_ERR.rawValue)
            let stat = srt_epoll_add_usock(eid, sock, &events)
            if stat != 0 {
                Logger.error("Failed to add SRT to poll, \(sock)")
            }
        }
    }

    func unregisterEpoll() {
        if let eid = srt_epoll {
            let stat = srt_epoll_remove_usock(eid, sock)
            if stat != 0 {
                Logger.error("Failed to remove SRT from poll, \(sock)")
            }
        }
    }
}
