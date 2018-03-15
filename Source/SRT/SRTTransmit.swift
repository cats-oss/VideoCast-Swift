//
//  SRTTransmit.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/03/06.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import SRT

enum SRTError: Error {
    case invalidArgument(message: String)
    case runtime(message: String)
    case transmission(message: String)
    case readEOF(message: String)
}

func printSrtStats(_ sid: Int, mon: CBytePerfMon) {
    Logger.info("======= SRT STATS: sid=\(sid)")
    Logger.info(String(format: "PACKETS     SENT: %11d  RECEIVED:   %11d", mon.pktSent, mon.pktRecv))
    Logger.info(String(format: "LOST PKT    SENT: %11d  RECEIVED:   %11d", mon.pktSndLoss, mon.pktRcvLoss))
    Logger.info(String(format: "REXMIT      SENT: %11d  RECEIVED:   %11d", mon.pktRetrans, mon.pktRcvRetrans))
    Logger.info(String(format: "DROP PKT    SENT: %11d  RECEIVED:   %11d", mon.pktSndDrop, mon.pktRcvDrop))
    Logger.info(String(format: "RATE     SENDING: %11d  RECEIVING:  %11d", mon.mbpsSendRate, mon.mbpsRecvRate))
    Logger.info(String(format: "BELATED RECEIVED: %11d  AVG TIME:   %11d", mon.pktRcvBelated, mon.pktRcvAvgBelatedTime))
    Logger.info(String(format: "REORDER DISTANCE: %11d", mon.pktReorderDistance))
    Logger.info(String(format: "WINDOW      FLOW: %11d  CONGESTION: %11d  FLIGHT: %11d", mon.pktFlowWindow, mon.pktCongestionWindow, mon.pktFlightSize))
    Logger.info(String(format: "LINK         RTT: %9dms  BANDWIDTH:  %7dMb/s ", mon.msRTT, mon.mbpsBandwidth))
    Logger.info(String(format: "BUFFERLEFT:  SND: %11d  RCV:        %11d", mon.byteAvailSndBuf, mon.byteAvailRcvBuf))
}

class SrtConf {
    static let transmit_verbose: Bool = false
    static var transmit_total_stats: Bool = false
    static var transmit_bw_report: UInt32 = 0
    static var transmit_stats_report: UInt32 = 0
    static var transmit_chunk_size: Int32 = SRT_LIVE_DEF_PLSIZE
}

func parseSrtUri(_ uri: String) throws -> (host: String, port: Int, par: [String:String]) {
    guard let u = URLComponents(string: uri),
        let scheme = u.scheme, scheme == "srt",
        let host = u.host else {
            throw SRTError.invalidArgument(message: "Invalid uri")
    }
    guard let port = u.port, port > 1024 else {
        Logger.error("Port value invalid: \(String(describing: u.port)) - must be >1024")
        throw SRTError.invalidArgument(message: "Invalid port number")
    }
    var params = [String : String]()
    
    if let queryItems = u.queryItems {
        for queryItem in queryItems {
            params[queryItem.name] = queryItem.value
        }
    }
    
    return (host, port, params)
}

class SrtCommon {
    fileprivate var clear_stats: Int32 = 0
    
    fileprivate var output_direction: Bool = false //< Defines which of SND or RCV option variant should be used, also to set SRT_SENDER for output
    fileprivate var blocking_mode: Bool = false //< enforces using SRTO_SNDSYN or SRTO_RCVSYN, depending on @a m_output_direction
    fileprivate var timeout: Int = 0 //< enforces using SRTO_SNDTIMEO or SRTO_RCVTIMEO, depending on @a m_output_direction
    fileprivate var tsbpdmode: Bool = true
    fileprivate var outgoing_port: Int = 0
    fileprivate var mode: String = "default"
    fileprivate var adapter: String = ""
    fileprivate var options: [String:String] = .init()
    fileprivate var sock: SRTSOCKET = SRT_INVALID_SOCK
    fileprivate var srt_epoll: Int32?
    
    fileprivate var payloadsize: Int32?
    
    fileprivate var bindsock: SRTSOCKET = SRT_INVALID_SOCK;
    fileprivate var isUsable: Bool {
        let st = srt_getsockstate(sock)
        return st.rawValue > SRTS_INIT.rawValue && st.rawValue < SRTS_BROKEN.rawValue
    }
    
    fileprivate var isBroken: Bool {
        return srt_getsockstate(sock).rawValue > SRTS_CONNECTED.rawValue
    }
    
    var socket: SRTSOCKET {
        return sock
    }
    
    var listener: SRTSOCKET {
        return bindsock
    }
    
    fileprivate init() {
        
    }
    
    fileprivate init(_ host: String, port: Int, par: [String:String], dir_output: Bool, pollid: Int32?) throws {
        output_direction = dir_output
        srt_epoll = pollid
        try initParameters(host, par: par)
        
        if SrtConf.transmit_verbose {
            Logger.debug("Opening SRT \(dir_output ? "target" : "source") \(mode)(\(blocking_mode ? "" : "non-")blocking) on \(host):\(port)")
        }
        
        switch mode {
        case "caller":
            try openClient(host, port: port)
        case "listener":
            try openServer(adapter, port: port)
        case "rendezvous":
            try openRendezvous(adapter, host: host, port: port);
        default:
            throw SRTError.invalidArgument(message: "Invalid 'mode'. Use 'client' or 'server'")
        }
    }
    
    deinit {
        close()
    }
    
    func initParameters(_ host: String, par: [String:String]) throws {
        var par = par
        
        // Application-specific options: mode, blocking, timeout, adapter
        if ( SrtConf.transmit_verbose )
        {
            Logger.debug("Parameters:\(par)")
        }
        
        mode = "default";
        if let mode = par["mode"] {
            self.mode = mode
        }
        
        if ( mode == "default" )
        {
            // Use the following convention:
            // 1. Server for source, Client for target
            // 2. If host is empty, then always server.
            if ( host == "" ) {
                mode = "listener"
            } else {
                mode = "caller"
            }
        }
        
        if mode == "client" {
            mode = "caller";
        } else if mode == "server" {
            mode = "listener"
        }
        
        par["mode"] = nil
        
        // no blocking mode support at the moment
        /*if let blocking = par[.blocking] as? Bool {
         blocking_mode = blocking
         par[.blocking] = nil
         }*/
        
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
            if SrtConf.transmit_chunk_size != SRT_LIVE_DEF_PLSIZE
            {
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
        bindsock = srt_socket(AF_INET, SOCK_DGRAM, 0);
        if bindsock == SRT_ERROR {
            try error(udtGetLastError(), src: "srt_socket")
        }
        
        var stat = configurePre(bindsock)
        if ( stat == SRT_ERROR ) {
            try error(udtGetLastError(), src: "ConfigurePre")
        }
        
        var sa = try createAddrInet(host, port: UInt16(port))
        stat = withUnsafePointer(to: &sa) { ptr -> Int32 in
            let psa = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
            if ( SrtConf.transmit_verbose )
            {
                Logger.debug("Binding a server on \(host):\(port) ...")
            }
            return srt_bind(bindsock, psa, Int32(MemoryLayout.size(ofValue: sa)))
        }
        if ( stat == SRT_ERROR )
        {
            srt_close(bindsock);
            try error(udtGetLastError(), src: "srt_bind")
        }
        
        if ( SrtConf.transmit_verbose )
        {
            Logger.debug(" listen...")
        }
        stat = srt_listen(bindsock, backlog)
        if ( stat == SRT_ERROR )
        {
            srt_close(bindsock);
            try error(udtGetLastError(), src: "srt_listen")
        }
    }
    
    func stealFrom(_ src: SrtCommon) {
        // This is used when SrtCommon class designates a listener
        // object that is doing Accept in appropriate direction class.
        // The new object should get the accepted socket.
        output_direction = src.output_direction;
        blocking_mode = src.blocking_mode;
        timeout = src.timeout;
        tsbpdmode = src.tsbpdmode;
        bindsock = SRT_INVALID_SOCK // no listener
        sock = src.sock;
        src.sock = SRT_INVALID_SOCK; // STEALING
    }
    
    @discardableResult
    func acceptNewClient() throws -> Bool {
        var scl: sockaddr_in = .init()
        var sclen: Int32 = Int32(MemoryLayout.size(ofValue: scl))
        
        if ( SrtConf.transmit_verbose )
        {
            Logger.debug(" accept...")
        }
        
        withUnsafeMutablePointer(to: &scl) {
            let pscl = UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self)
            
            sock = srt_accept(bindsock, pscl, &sclen)
        }
        
        if ( sock == SRT_INVALID_SOCK )
        {
            srt_close(bindsock);
            bindsock = SRT_INVALID_SOCK;
            try error(udtGetLastError(), src: "srt_accept");
        }
        registerEpoll()
        
        if true
        {
            // we do one client connection at a time,
            // so close the listener.
            srt_close(bindsock);
            bindsock = SRT_INVALID_SOCK;
        }
        
        if SrtConf.transmit_verbose {
            Logger.debug(" connected.")
        }
        
        // ConfigurePre is done on bindsock, so any possible Pre flags
        // are DERIVED by sock. ConfigurePost is done exclusively on sock.
        let stat = configurePost(sock)
        if ( stat == SRT_ERROR ) {
            try error(udtGetLastError(), src: "ConfigurePost")
        }
        
        return true
    }
    
    func close() {
        if SrtConf.transmit_verbose {
            Logger.debug("SrtCommon: DESTROYING CONNECTION, closing sockets (rt%\(sock) ls%\(bindsock)...")
        }
        
        var yes: Int32 = 1
        if sock != SRT_INVALID_SOCK {
            unregisterEpoll()
            srt_setsockflag(sock, SRTO_SNDSYN, &yes, Int32(MemoryLayout.size(ofValue: yes)))
            srt_close(sock)
        }
        
        if bindsock != SRT_INVALID_SOCK {
            // Set sndsynchro to the socket to synch-close it.
            srt_setsockflag(bindsock, SRTO_SNDSYN, &yes, Int32(MemoryLayout.size(ofValue: yes)))
            srt_close(bindsock)
        }
        if SrtConf.transmit_verbose {
            Logger.debug("SrtCommon: ... done.")
        }
    }
    
    fileprivate func error(_ udtError: UdtErrorInfo, src: String) throws {
        let str = String(cString: udtError.message)
        if SrtConf.transmit_verbose {
            Logger.error("FAILURE \(src):[\(udtError.code)] \(str)")
        } else {
            Logger.error("ERROR #\(udtError.code): \(str)")
        }
        
        throw SRTError.transmission(message: "error: \(src): \(str)")
    }
    
    fileprivate func configurePost(_ sock: SRTSOCKET) -> Int32 {
        var yes: Int32 = blocking_mode ? 1 : 0
        var result: Int32 = 0
        if output_direction {
            result = srt_setsockopt(sock, 0, SRTO_SNDSYN, &yes, Int32(MemoryLayout.size(ofValue: yes)))
            if result == -1 {
                return result;
            }
            
            if timeout > 0 {
                return srt_setsockopt(sock, 0, SRTO_SNDTIMEO, &timeout, Int32(MemoryLayout.size(ofValue: timeout)))
            }
        }
        else
        {
            result = srt_setsockopt(sock, 0, SRTO_RCVSYN, &yes, Int32(MemoryLayout.size(ofValue: yes)))
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
            if SrtConf.transmit_verbose {
                Logger.warn("failed to set '\(failure)' (post, \(output_direction ? "target" : "source")) to \(String(describing: options[failure]))")
            }
        }
        
        return 0;
    }
    
    fileprivate func configurePre(_ sock: SRTSOCKET) -> Int32 {
        var result: Int32 = 0
        
        var no: Int32 = 0
        if !tsbpdmode {
            result = srt_setsockopt(sock, 0, SRTO_TSBPDMODE, &no, Int32(MemoryLayout.size(ofValue: no)))
            if result == -1 {
                return result
            }
        }
        
        // Let's pretend async mode is set this way.
        // This is for asynchronous connect.
        var maybe = blocking_mode
        result = srt_setsockopt(sock, 0, SRTO_RCVSYN, &maybe, Int32(MemoryLayout.size(ofValue: maybe)))
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
            if SrtConf.transmit_verbose {
                Logger.warn("WARNING: failed to set options: \(failures.description)")
            }
            
            return SRT_ERROR
        }
        
        return 0;
    }
    
    fileprivate func openClient(_ host: String, port: Int) throws {
        try prepareClient()
        
        if outgoing_port > 0 {
            try setupAdapter("", port: outgoing_port)
        }
        
        try connectClient(host, port: port)
    }
    
    fileprivate func prepareClient() throws {
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
    
    fileprivate func setupAdapter(_ host: String, port: Int) throws {
        var localsa = try createAddrInet(host, port: UInt16(port))
        let stat = withUnsafePointer(to: &localsa) { ptr -> Int32 in
            let psa = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
            return srt_bind(sock, psa, Int32(MemoryLayout.size(ofValue: localsa)))
        }
        if stat == SRT_ERROR {
            try error(udtGetLastError(), src: "srt_bind")
        }
    }
    
    fileprivate func connectClient(_ host: String, port: Int) throws {
        var sa = try createAddrInet(host, port: UInt16(port))
        var stat = withUnsafePointer(to: &sa) { ptr -> Int32 in
            let psa = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
            if SrtConf.transmit_verbose {
                Logger.debug("Connecting to \(host):\(port) ...")
            }
            return srt_connect(sock, psa, Int32(MemoryLayout.size(ofValue: sa)))
        }
        if stat == SRT_ERROR {
            //srt_close(sock)
            try error(udtGetLastError(), src: "UDT::connect")
        }
        
        if SrtConf.transmit_verbose {
            if blocking_mode {
                Logger.debug(" connected.")
            }
        }
        
        stat = configurePost(sock)
        if stat == SRT_ERROR {
            try error(udtGetLastError(), src: "ConfigurePost")
        }
    }
    
    fileprivate func openServer(_ host: String, port: Int) throws {
        try prepareListener(host, port: port, backlog: 1);
        if (blocking_mode) {
            try acceptNewClient()
        }
    }
    
    fileprivate func openRendezvous(_ adapter: String, host: String, port: Int) throws {
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
        
        var localsa = try createAddrInet(host, port: UInt16(port))
        stat = withUnsafePointer(to: &localsa) { ptr -> Int32 in
            let plsa = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
            if SrtConf.transmit_verbose {
                Logger.debug("Binding a server on \(adapter):\(port) ...")
            }
            return srt_bind(sock, plsa, Int32(MemoryLayout.size(ofValue: localsa)))
        }
        if stat == SRT_ERROR {
            unregisterEpoll()
            srt_close(sock)
            try error(udtGetLastError(), src: "srt_bind")
        }
        
        var sa = try createAddrInet(host, port: UInt16(port))
        stat = withUnsafePointer(to: &sa) { ptr -> Int32 in
            let psa = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
            if SrtConf.transmit_verbose {
                Logger.debug("Connecting to \(host):\(port) ...")
            }
            return srt_connect(sock, psa, Int32(MemoryLayout.size(ofValue: sa)))
        }
        if stat == SRT_ERROR {
            srt_close(sock)
            try error(udtGetLastError(), src: "srt_connect")
        }
        
        if SrtConf.transmit_verbose {
            if blocking_mode && SrtConf.transmit_verbose {
                Logger.debug(" connected.")
            }
        }
        
        stat = configurePost(sock)
        if stat == SRT_ERROR {
            try error(udtGetLastError(), src: "ConfigurePost")
        }
    }
    
    fileprivate func registerEpoll() {
        if let eid = srt_epoll {
            var events: Int32 = Int32(SRT_EPOLL_IN.rawValue | SRT_EPOLL_OUT.rawValue | SRT_EPOLL_ERR.rawValue)
            let stat = srt_epoll_add_usock(eid, sock, &events)
            if stat != 0 {
                Logger.error("Failed to add SRT to poll, \(sock)")
            }
        }
    }
    
    fileprivate func unregisterEpoll() {
        if let eid = srt_epoll {
            let stat = srt_epoll_remove_usock(eid, sock)
            if stat != 0 {
                Logger.error("Failed to remove SRT from poll, \(sock)")
            }
        }
    }
}

class SrtSource: SrtCommon {
    static var counter: UInt32 = 1
    var hostport_copy: String = ""
    
    var isOpen: Bool {
        return isUsable
    }
    
    var end: Bool {
        return isBroken
    }
    
    static func create(_ url: String, pollid: Int32?) throws -> SrtSource {
        let ret = try parseSrtUri(url)
        return try .init(ret.host, port: ret.port, par: ret.par, pollid: pollid)
    }
    
    init(_ host: String, port: Int, par: [String:String], pollid: Int32?) throws {
        try super.init(host, port: port, par: par, dir_output: false, pollid: pollid)
        hostport_copy = "\(host):\(port)"
    }
    
    override init() {
        // Do nothing - create just to prepare for use
        super.init()
    }
    
    func read(_ chunk: Int, data: inout [Int8]) throws -> Bool {
        if data.count < chunk {
            data = .init(repeating: 0, count: chunk)
        }
        
        let ready: Bool = true
        var stat: Int32
        
        repeat {
            stat = srt_recvmsg(sock, &data, Int32(chunk))
            if stat == SRT_ERROR {
                if !blocking_mode {
                    // EAGAIN for SRT READING
                    if srt_getlasterror(nil) == SRT_EASYNCRCV.rawValue {
                        data.removeAll()
                        return false
                    }
                }
                try error(udtGetLastError(), src: "recvmsg")
            }
            
            if stat == 0 {
                throw SRTError.readEOF(message: hostport_copy)
            }
        } while !ready
        
        let chunk = MemoryLayout.size(ofValue: stat)
        if chunk < data.count {
            data = .init(repeating: 0, count: chunk)
        }
        
        var perf: CBytePerfMon = .init()
        srt_bstats(sock, &perf, clear_stats)
        clear_stats = 0
        if SrtConf.transmit_bw_report > 0 && (SrtSource.counter % SrtConf.transmit_bw_report) == SrtConf.transmit_bw_report - 1 {
            Logger.info("+++/+++SRT BANDWIDTH: \(perf.mbpsBandwidth)")
        }
        if SrtConf.transmit_stats_report > 0 && (SrtSource.counter % SrtConf.transmit_stats_report) == SrtConf.transmit_stats_report - 1 {
            printSrtStats(Int(sock), mon: perf)
            clear_stats = SrtConf.transmit_total_stats ? 0 : 1
        }
        
        SrtSource.counter += 1
        
        return true
    }
    
    func getSRTSocket() -> SRTSOCKET {
        var socket = self.socket
        if socket == SRT_INVALID_SOCK {
            socket = listener
        }
        return socket
    }
}

class SrtTarget: SrtCommon {
    static var counter: UInt32 = 1
    
    var isOpen: Bool {
        return isUsable
    }
    
    var broken: Bool {
        return isBroken
    }
    
    static func create(_ url: String, pollid: Int32? = nil) throws -> SrtTarget {
        let ret = try parseSrtUri(url)
        return try .init(ret.host, port: ret.port, par: ret.par, pollid: pollid)
    }
    
    init(_ host: String, port: Int, par: [String:String], pollid: Int32?) throws {
        try super.init(host, port: port, par: par, dir_output: true, pollid: pollid)
    }
    
    override init() {
        super.init()
    }
    
    override func configurePre(_ sock: SRTSOCKET) -> Int32 {
        var result = super.configurePre(sock)
        if result == -1 {
            return result
        }
        
        var yes: Int32 = 1
        // This is for the HSv4 compatibility; if both parties are HSv5
        // (min. version 1.2.1), then this setting simply does nothing.
        // In HSv4 this setting is obligatory; otherwise the SRT handshake
        // extension will not be done at all.
        result = srt_setsockopt(sock, 0, SRTO_SENDER, &yes, Int32(MemoryLayout.size(ofValue: yes)))
        if result == -1 {
            return result
        }
        
        return 0
    }
    
    func write(_ data: UnsafePointer<Int8>, size: Int) throws -> Bool {
        let stat = srt_sendmsg2(sock, data, Int32(size), nil)
        if stat == SRT_ERROR {
            if blocking_mode {
                try error(udtGetLastError(), src: "srt_sendmsg")
            }
            return false
        }
        
        var perf: CBytePerfMon = .init()
        srt_bstats(sock, &perf, clear_stats)
        clear_stats = 0
        
        if SrtConf.transmit_bw_report > 0 && (SrtSource.counter % SrtConf.transmit_bw_report) == SrtConf.transmit_bw_report - 1 {
            Logger.info("+++/+++SRT BANDWIDTH: \(perf.mbpsBandwidth)")
        }
        if SrtConf.transmit_stats_report > 0 && (SrtSource.counter % SrtConf.transmit_stats_report) == SrtConf.transmit_stats_report - 1 {
            printSrtStats(Int(sock), mon: perf)
            clear_stats = SrtConf.transmit_total_stats ? 0 : 1
        }
        
        SrtSource.counter += 1
        
        return true
    }
    
    func still() -> Int {
        var bytes: Int = 0
        let st = srt_getsndbuffer(sock, nil, &bytes)
        if st == -1 {
            return 0
        }
        return bytes
    }
    
    func getSRTSocket() -> SRTSOCKET {
        var socket = self.socket
        if socket == SRT_INVALID_SOCK {
            socket = listener
        }
        return socket
    }
}

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
    
    init(_ host: String, port: Int, par: [String:String]) throws {
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
            try acceptNewClient();
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

