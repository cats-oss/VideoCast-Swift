//
//  TCPThroughputAdaptation.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/31.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

open class TCPThroughputAdaptation: IThroughputAdaptation {
    private let kWeight: Float = 0.75
    private let kPivotSamples: Int = 5
    // seconds - represents the time between measurements when increasing or decreasing bitrate
    private let kMeasurementDelay: TimeInterval = 2
    // seconds - represents time to wait after a bitrate decrease before attempting to increase again
    private let kSettlementDelay: TimeInterval = 30
    // seconds - number of seconds to wait between increase vectors (after initial ramp up)
    private let kIncreaseDelta: TimeInterval = 10

    private var previousTurndown: Date = .init()
    private var previousIncrease: Date = .init()

    private var thread: Thread?
    private let cond: NSCondition = .init()
    private let buffQueue: DispatchQueue = .init(label: "jp.co.cyberagent.VideoCast.tcp.adaptation.buff")
    private let durQueue: DispatchQueue = .init(label: "jp.co.cyberagent.VideoCast.tcp.adaptation.dur")

    private var sentSamples: [Int] = .init()
    private var bufferSizeSamples: [Int] = .init()
    private var bufferDurationSamples: [Int64] = .init()

    private var bwSamples: [Float] = .init()
    private var buffGrowth: [Int] = .init()
    private var turnSamples: [Float] = .init()
    private var bwWeights: [Float] = .init()

    private var callback: ThroughputCallback?

    private let bwSampleCount: Int = 30
    private let negSampleCount: Int = 0

    private var previousVector: Float = 0

    private var started: Bool = false
    private var exiting: Atomic<Bool> = .init(false)
    private var hasFirstTurndown: Bool = false

    public init() {
        let v = (1 - powf(kWeight, Float(bwSampleCount))) / (1 - kWeight)
        for i in 0..<bwSampleCount {
            bwWeights.append(powf(kWeight, Float(i)) / v)
        }
    }

    deinit {
        stop()
    }

    private static func mode<T: Equatable>(array: [T]) -> T {
        var number: T = array[0]
        var mode: T = number
        var count = 1
        var countMode = 1

        for i in 1..<array.count {
            if array[i] == number {
                // count occurrences of the current number
                countMode += 1
            } else {
                // now this is a different number
                if count > countMode {
                    countMode = count   // mode is the biggest ocurrences
                    mode = number
                }
                count = 1   // reset count for the new number
                number = array[i]
            }
        }
        return mode
    }

    open func setThroughputCallback(_ callback: @escaping ThroughputCallback) {
        self.callback = callback
    }

    open func addSentBytesSample(_ bytesSent: Int) {
        buffQueue.async { [weak self] in
            self?.sentSamples.append(bytesSent)
        }
    }

    open func addBufferSizeSample(_ bufferSize: Int) {
        buffQueue.async { [weak self] in
            self?.bufferSizeSamples.append(bufferSize)
        }
    }

    open func addBufferDurationSample(_ bufferDuration: Int64) {
        durQueue.async { [weak self] in
            self?.bufferDurationSamples.append(bufferDuration)
        }
    }

    open func reset() {
        bufferSizeSamples.removeAll()
    }

    open func start() {
        if !started {
            started = true
            thread = Thread(block: sampleThread)
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

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func sampleThread() {
        var prev: Date = .init()

        Thread.current.name = "jp.co.cyberagent.VideoCast.tcp.adaptation"
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

            let now = Date()
            let diff = now.timeIntervalSince(prev)
            let previousTurndownDiff = now.timeIntervalSince(previousTurndown)
            let previousIncreaseDiff = now.timeIntervalSince(previousIncrease)
            prev = now

            var vec: Float = 0
            var detectedBytesPerSec: Float = 0
            var turnAvg: Float = 0

            buffQueue.sync {
                var totalSent = 0

                for samp in sentSamples {
                    totalSent += Int(samp)
                }

                let timeDelta = diff
                detectedBytesPerSec = Float(Double(totalSent) / timeDelta)

                bwSamples.insert(detectedBytesPerSec, at: 0)
                if bwSamples.count > bwSampleCount {
                    bwSamples.removeLast()
                }

                if let bufferSizeSample = bufferSizeSamples.last {
                    buffGrowth.insert(Int(bufferSizeSample), at: 0)
                    if buffGrowth.count > 3 {
                        buffGrowth.removeLast()
                    }

                    var buffGrowthAvg = 0
                    var prevValue = 0
                    for it in buffGrowth {
                        buffGrowthAvg += (it > prevValue) ? -1 : (it < prevValue ? 1 : 0)
                        prevValue = it
                    }

                    if buffGrowthAvg <= 0 &&
                        (!hasFirstTurndown || (previousTurndownDiff > kSettlementDelay &&
                            previousIncreaseDiff > kIncreaseDelta)) {
                        vec = 1
                    } else if buffGrowthAvg > 0 {
                        vec = -1
                        hasFirstTurndown = true
                        previousTurndown = now
                    } else {
                        vec = 0
                    }
                    if previousVector < 0 && vec >= 0 {
                        if let bwSample = bwSamples.first {
                            turnSamples.insert(bwSample, at: 0)
                            if turnSamples.count > kPivotSamples {
                                turnSamples.removeLast()
                            }
                        }
                    }

                    if !turnSamples.isEmpty {

                        for turnSample in turnSamples {
                            turnAvg += turnSample
                        }
                        turnAvg /= Float(turnSamples.count)

                    }

                    if detectedBytesPerSec > turnAvg {
                        turnSamples.insert(detectedBytesPerSec, at: 0)
                        if turnSamples.count > kPivotSamples {
                            turnSamples.removeLast()
                        }
                    }

                    previousVector = vec

                }
                sentSamples.removeAll()
                bufferSizeSamples.removeAll()
                bufferDurationSamples.removeAll()
            }

            if let callback = callback {
                if vec > 0 {
                    previousIncrease = now
                }
                _ = callback(vec, turnAvg, Int(detectedBytesPerSec))
            }

        }
    }
}
