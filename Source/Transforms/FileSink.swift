//
//  FileSink.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/03/02.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

public typealias FileSinkSessionParameters = MetaData<(filename: String, dummy: Int?)>

open class FileSink: IOutputSession {
    private let writingQueue: DispatchQueue = .init(label: "filesink")

    private var filename: String = ""

    private var startedSession: Bool = false
    private var started: Bool = false
    private var exiting: Atomic<Bool> = .init(false)
    private var thread: Thread?
    private let cond: NSCondition = .init()

    private var buffers: [Data] = .init()

    private var stopCallback: StopSessionCallback?

    public init() {

    }

    deinit {
        if startedSession {
            stop {}
        }
    }

    open func stop(_ callback: @escaping StopSessionCallback) {
        startedSession = false
        exiting.value = true
        cond.broadcast()

        stopCallback = callback
    }

    public func setSessionParameters(_ parameters: IMetaData) {
        guard let params = parameters as? FileSinkSessionParameters, let data = params.data else {
            Logger.debug("unexpected return")
            return
        }

        filename = data.filename

        if !started {
            started = true
            thread = Thread(block: writingThread)
            thread?.start()
        }
    }

    public func setBandwidthCallback(_ callback: @escaping BandwidthCallback) {

    }

    public func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        let data: Data = .init(bytes: data, count: size)
        writingQueue.async { [weak self] in
            guard let strongSelf = self, !strongSelf.exiting.value else { return }

            strongSelf.buffers.insert(data, at: 0)
            strongSelf.cond.signal()
        }

    }

    private func writingThread() {
        let fh: FileHandle
        let fileUrl = URL(fileURLWithPath: filename)
        let fileManager = FileManager()
        let filePath = fileUrl.path

        do {
            fileManager.createFile(atPath: filePath, contents: nil,
                               attributes: nil)

            fh = try FileHandle(forWritingTo: fileUrl)

            fh.truncateFile(atOffset: 0)
        } catch {
            Logger.error("Could not create FileHandle: \(error)")
            return
        }

        while !exiting.value {
            cond.lock()
            defer {
                cond.unlock()
            }

            writingQueue.sync {
                if !buffers.isEmpty {
                    if let buffer = buffers.popLast() {
                        fh.write(buffer)
                    }
                }
            }

            if buffers.count < 2 && !exiting.value {
                cond.wait()
            }
        }

        while !buffers.isEmpty {
            writingQueue.sync {
                if let buffer = buffers.popLast() {
                    fh.write(buffer)
                }
            }
        }

        fh.closeFile()
        Logger.debug("Stopped writing file")
        stopCallback?()
    }
}
