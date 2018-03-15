//
//  StreamSession.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/30.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

class StreamCallback: NSObject, StreamDelegate {
    weak var session: StreamSession?
    
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        session?.nsStreamCallback(aStream, event: eventCode)
    }
}

open class StreamSession: IStreamSession {
    open var status: StreamStatus = .init()
    
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var runLoop:    RunLoop?
    private var streamCallback: StreamCallback?
    
    private var callback: StreamSessionCallback?
    
    public init() {
        streamCallback = StreamCallback()
        streamCallback?.session = self
    }
    
    deinit {
        disconnect()
        streamCallback = nil
        
        Logger.debug("StreamSession::deinit")
    }
    
    open func connect(host: String, port: Int, sscb callback: @escaping StreamSessionCallback) {
        self.callback = callback
        if !status.isEmpty {
            disconnect()
        }
        autoreleasepool {
            var readStream: Unmanaged<CFReadStream>?
            var writeStream: Unmanaged<CFWriteStream>?
            
            CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, host as CFString, UInt32(port), &readStream, &writeStream)
            
            inputStream = readStream?.takeRetainedValue()
            outputStream = writeStream?.takeRetainedValue()
            
            let queue: DispatchQueue = .init(label: "com.videocast.network")
            
            if let _ = inputStream, let _ = outputStream {
                queue.async { [weak self] in
                    self?.startNetwork()
                }
            } else {
                nsStreamCallback(nil, event: .errorOccurred)
            }
        }
        
    }
    
    open func disconnect() {
        outputStream?.close()
        outputStream = nil
        
        inputStream?.close()
        inputStream = nil
        
        if let runLoop = runLoop {
            CFRunLoopStop(runLoop.getCFRunLoop())
            self.runLoop = nil
        }
    }
    
    open func write(_ buffer: UnsafePointer<UInt8>, size: Int) -> Int {
        var ret = 0
        
        guard let outputStream = outputStream else {
            Logger.debug("unexpected return")
            return ret
        }

        if outputStream.hasSpaceAvailable {
            ret = outputStream.write(buffer, maxLength: size)
        }
        if ret >= 0 && ret < size && (status.contains(.writeBufferHasSpace)) {
            // Remove the Has Space Available flag
            status.remove(.writeBufferHasSpace)
        } else if (ret < 0) {
            Logger.error("ERROR! [\(String(describing: outputStream.streamError))] buffer: \(buffer) [ \(String(format:"0x%02X", buffer[0])) ], size: \(size)")
        }
        
        return ret
    }
    
    open func read(_ buffer: UnsafeMutablePointer<UInt8>, size: Int) -> Int {
        var ret = 0
        
        guard let inputStream = inputStream else {
            Logger.debug("unexpected return")
            return ret
        }
        
        ret = inputStream.read(buffer, maxLength: size)
        
        if ret < size && (status.contains(.readBufferHasBytes)) {
            status.remove(.readBufferHasBytes)
        } else if !inputStream.hasBytesAvailable {
            Logger.info("No more data in stream, clear read status")
            status.remove(.readBufferHasBytes)
        }
        return ret
    }
    
    open func nsStreamCallback(_ stream: Stream?, event: Stream.Event) {
        if event.contains(.openCompleted) {
            // Only set connected event when input and output stream both connected
            if let inputStream = inputStream, let outputStream = outputStream,
                inputStream.streamStatus.rawValue >= Stream.Status.open.rawValue && outputStream.streamStatus.rawValue >= Stream.Status.open.rawValue &&
                    inputStream.streamStatus.rawValue < Stream.Status.atEnd.rawValue &&
                    outputStream.streamStatus.rawValue < Stream.Status.atEnd.rawValue {
                setStatus(.connected, clear: true)
            } else {
                return
            }
        }
        if event.contains(.hasBytesAvailable) {
            setStatus(.readBufferHasBytes)
        }
        if event.contains(.hasSpaceAvailable) {
            setStatus(.writeBufferHasSpace)
        }
        if event.contains(.endEncountered) {
            setStatus(.endStream, clear: true)
        }
        if event.contains(.errorOccurred) {
            setStatus(.errorEncountered, clear: true)
            if let streamError = inputStream?.streamError {
                Logger.error("Input stream error:\(streamError)")
            }
            if let streamError = outputStream?.streamError {
                Logger.error("Output stream error:\(streamError)")
            }
        }
    }
    
    private func setStatus(_ status: StreamStatus, clear: Bool = false) {
        if clear {
            self.status = status
        } else {
            self.status.insert(status)
        }
        callback?(self, status)
    }
    
    private func startNetwork() {
        let runLoop = RunLoop.current
        self.runLoop = runLoop
        inputStream?.delegate = streamCallback
        inputStream?.schedule(in: runLoop, forMode: .defaultRunLoopMode)
        outputStream?.delegate = streamCallback
        outputStream?.schedule(in: runLoop, forMode: .defaultRunLoopMode)
        outputStream?.open()
        inputStream?.open()
        
        runLoop.run()
    }
}
