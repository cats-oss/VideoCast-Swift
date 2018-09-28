//
//  Smoother.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/09/27.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import CoreMedia

open class Smoother: ITransform {
    class Sample {
        var buf: Buffer
        var metadata: IMetaData

        init(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
            buf = Buffer()
            buf.buffer.append(data.assumingMemoryBound(to: UInt8.self), count: size)
            self.metadata = metadata
        }
    }
    private weak var output: IOutput?

    private var thread: Thread?
    private let cond: NSCondition = .init()
    private let buffQueue: DispatchQueue = .init(label: "jp.co.cyberagent.VideoCast.tcp.adaptation.buff")
    private var queue: [Sample] = .init()
    private var delay: TimeInterval
    private var started: Bool = false
    private var exiting: Atomic<Bool> = .init(false)

    public init(delay: TimeInterval) {
        self.delay = delay
    }

    public func setOutput(_ output: IOutput) {
        self.output = output
    }

    public func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        guard output != nil else {
            Logger.debug("unexpected return")
            return
        }

        let sample = Sample(data, size: size, metadata: metadata)
        buffQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.queue.append(sample)
        }
    }

    open func start() {
        if !started {
            started = true
            exiting.value = false
            thread = Thread(target: self, selector: #selector(sampleThread), object: nil)
            thread?.start()
        }
    }

    open func stop() {
        exiting.value = true
        cond.broadcast()
        if started {
            thread?.cancel()
            started = false
        }
    }

    @objc private func sampleThread() {
        var firstTime: Date?
        var firstCMTime = kCMTimeZero
        Thread.current.name = "jp.co.cyberagent.VideoCast.smoother"
        while !exiting.value {
            cond.lock()
            defer {
                cond.unlock()
            }

            guard let sample = getSample() else { continue }
            let now = Date()

            let cmtime = sample.metadata.dts

            let waitTime: TimeInterval
            if let firstTime = firstTime {
                if cmtime == kCMTimeZero {
                    waitTime = delay
                } else {
                    waitTime = max((cmtime - firstCMTime).seconds - (now.timeIntervalSince(firstTime)) + delay, 0)
                }
            } else {
                waitTime = delay
                firstTime = now
                firstCMTime = cmtime
            }

            if !exiting.value {
                cond.wait(until: Date.init(timeIntervalSinceNow: waitTime))
            }
            guard !exiting.value else {
                break
            }

            sample.buf.buffer.withUnsafeBytes { (data: UnsafePointer<UInt8>) in
                output?.pushBuffer(data, size: sample.buf.buffer.count, metadata: sample.metadata)
            }
        }
    }

    private func getSample() -> Sample? {
        var result: Sample?
        buffQueue.sync {
            if !queue.isEmpty {
                result = queue.removeFirst()
            }
        }
        return result
    }
}
