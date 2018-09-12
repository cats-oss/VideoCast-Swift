//
//  SRTStatsManager.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/08/16.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

class SrtStatsManager {
    // seconds - represents the time between measurements when increasing or decreasing bitrate
    private let kMeasurementDelay: TimeInterval = 0.1
    // seconds - represents time to wait after a bitrate decrease before attempting to increase again
    private let kSettlementDelay: TimeInterval = 30
    // seconds - number of seconds to wait between increase vectors (after initial ramp up)
    private let kIncreaseDelta: TimeInterval = 10
    // seconds - number of seconds to wait between increase vectors (before initial ramp up)
    private let kRampUpIncreaseDelta: TimeInterval = 2
    // seconds - number of seconds to wait between decrease vectors
    private let kDecreaseDelta: TimeInterval = 1

    private var previousTurndown: Date = .init()
    private var previousIncrease: Date = .init()

    private var thread: Thread?
    private let cond: NSCondition = .init()
    private let buffQueue: DispatchQueue = .init(label: "jp.co.cyberagent.VideoCast.tcp.adaptation.buff")
    private let durQueue: DispatchQueue = .init(label: "jp.co.cyberagent.VideoCast.tcp.adaptation.dur")

    private var callback: ThroughputCallback?

    private var started: Bool = false
    private var exiting: Atomic<Bool> = .init(false)
    private var hasFirstTurndown: Bool = false

    private var sock: SRTSOCKET = SRT_INVALID_SOCK
    private var samples: [SrtStats] = .init()
    private let sampleCount: Int = 30
    private var currentRate: Double = 0

    public init() {

    }

    deinit {
        stop()
    }

    open func reset() {
    }

    open func start(_ sock: SRTSOCKET) {
        if !started {
            started = true
            self.sock = sock
            thread = Thread(target: self, selector: #selector(sampleThread), object: nil)
            thread?.start()
        }
    }

    open func stop() {
        exiting.value = true
        cond.broadcast()
        callback = nil
        if started {
            thread?.cancel()
            started = false
        }
    }

    open func setThroughputCallback(_ callback: @escaping ThroughputCallback) {
        self.callback = callback
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    @objc private func sampleThread() {
        let clear_stats: Int32 = 1
        var perf: CBytePerfMon = .init()

        Thread.current.name = "jp.co.cyberagent.VideoCast.srt.adaptation"
        while !exiting.value {
            cond.lock()
            defer {
                cond.unlock()
            }

            if !exiting.value {
                cond.wait(until: Date.init(timeIntervalSinceNow: kMeasurementDelay))
            }
            guard !exiting.value else {
                break
            }

            srt_bstats(sock, &perf, clear_stats)
            let stats = SrtStats(sock, mon: &perf)
            samples.insert(stats, at: 0)
            if samples.count > sampleCount {
                samples.removeLast()
            }

            guard let current = samples.first else {
                continue
            }
            let now = Date()
            let previousTurndownDiff = now.timeIntervalSince(previousTurndown)
            let previousIncreaseDiff = now.timeIntervalSince(previousIncrease)

            var vec: Float = 1

            let turnDown = { () -> Bool in
                if previousTurndownDiff > self.kDecreaseDelta {
                    if current.link.bandwidth < self.currentRate {
                        Logger.info("detected bwe: \(current.link.bandwidth) < send rate: \(self.currentRate)")
                        return true
                    } else if current.send.packetsDropped > 0 {
                        Logger.info("detected packets dropped: \(current.send.packetsDropped)")
                        return true
                    }
                }
                return false
            }

            let turnUp = { () -> Bool in
                if current.link.bandwidth > self.currentRate * kBitrateRatio {
                    if !self.hasFirstTurndown && previousIncreaseDiff > self.kRampUpIncreaseDelta {
                        return true
                    } else if self.hasFirstTurndown && (previousTurndownDiff > self.kSettlementDelay &&
                        previousIncreaseDiff > self.kIncreaseDelta) {
                        return true
                    }
                }
                return false
            }

            if turnDown() {
                vec = -1
                hasFirstTurndown = true
                previousTurndown = now
            } else if turnUp() {
                vec = 1
            } else {
                vec = 0
            }

            if let callback = callback {
                if vec > 0 {
                    previousIncrease = now
                }
                if vec != 0 {
                    let currentByteRate =
                        callback(
                            vec, Float(current.link.bandwidth * 1000000 / 8),
                            Int(current.send.mbitRate * 1000000 / 8))
                    currentRate = Double(currentByteRate) * 8 / 1000000
                }
            }

        }
    }
}
