//
//  GenericAudioMixer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import CoreMedia
import AudioUnit

/*!
 *  Basic, cross-platform mixer that uses a very simple nearest neighbour resampling method
 *  and the sum of the samples to mix.  The mixer takes LPCM data from multiple sources, resamples (if needed), and
 *  mixes them to output a single LPCM stream.
 *
 *  Note that this mixer uses an extremely simple sample rate conversion algorithm that will produce undesirable
 *  noise in most cases, but it will be much less CPU intensive than more sophisticated methods.
 *  If you are using an Apple
 *  operating system and can dedicate more CPU resources to sample rate conversion,
 *   look at videocore::Apple::AudioMixer.
 */
open class AudioMixer: IAudioMixer {
    private let kMixWindowCount = 10

    private let kE: Float = 2.7182818284590

    var windows: [MixWindow]
    var currentWindow: MixWindow
    var outgoingWindow: MixWindow?

    private var mixQueue = JobQueue("jp.co.cyberagent.VideoCast.composite", priority: .high)

    var epoch = Date()
    var delay = TimeInterval()
    var nextMixTime = Date()
    var lastMixTime = Date()

    var frameDuration: TimeInterval
    var bufferDuration: TimeInterval

    var _mixThread: Thread?
    var mixThreadCond = NSCondition()

    weak var output: IOutput?

    private var inGain = [Int: Float]()
    private var lastSampleTime = [Int: Date]()

    var outChannelCount: Int
    var outFrequencyInHz: Int
    var outBitsPerChannel = 16
    var bytesPerSample: Int

    var exiting = Atomic(false)

    private var catchingUp = false

    static var s_samplingRateConverterComplexity = kAudioConverterSampleRateConverterComplexity_Normal
    static var s_samplingRateConverterQuality = kAudioConverterQuality_Medium

    var converters = [UInt64: ConverterInst]()

    /*!
     *  Constructor.
     *
     *  \param outChannelCount      number of channels to output.
     *  \param outFrequencyInHz     sampling rate to output.
     *  \param outBitsPerChannel    number of bits per channel to output
     *  \param frameDuration        The duration of a single frame of audio.
     *                              For example, AAC uses 1024 samples per frame
     *                              and therefore the duration is 1024 / sampling rate
     */
    public init(
        outChannelCount: Int,
        outFrequencyInHz: Int,
        outBitsPerChannel: Int,
        frameDuration: Double) {
        self.bufferDuration = frameDuration
        self.frameDuration = frameDuration
        self.outChannelCount = outChannelCount
        self.outFrequencyInHz = outFrequencyInHz

        self.bytesPerSample = outChannelCount * outBitsPerChannel / 8

        windows = [MixWindow]()
        for _ in 0 ..< kMixWindowCount {
            windows.append(MixWindow(size: Int(Double(bytesPerSample) * frameDuration * Double(outFrequencyInHz))))
        }

        for i in 0 ..< kMixWindowCount-1 {
            windows[i].next = windows[i + 1]
            windows[i + 1].prev = windows[i + 1]
        }

        windows[kMixWindowCount - 1].next = windows[0]
        windows[0].prev = windows[kMixWindowCount - 1]

        currentWindow = windows[0]
        currentWindow.start = Date()

    }

    deinit {
        mixQueue.markExiting()
        mixQueue.enqueueSync {}

        for converterInst in converters {
            if let converter = converterInst.value.converter {
                AudioConverterDispose(converter)
            } else {
                Logger.debug("unexpected return")
            }
        }
    }

    /*! IMixer::registerSource */
    open func registerSource(_ source: ISource, inBufferSize: Int) {
        inGain[hash(source)] = 1
    }

    /*! IMixer::unregisterSource */
    open func unregisterSource(_ source: ISource) {
        mixQueue.enqueue {
            if let index = self.inGain.index(forKey: hash(source)) {
                self.inGain.remove(at: index)
            }
        }
    }

    /*! IOutput::pushBuffer */
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    open func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        guard let inMeta = metadata as? AudioBufferMetadata, let metaData = inMeta.data else {
            return Logger.debug("unexpected return")
        }

        let data = data.assumingMemoryBound(to: UInt8.self)
        let inSource = metaData.source
        let cMixTime = Date()
        let currentWindow = self.currentWindow

        guard inSource.value != nil else { return }

        let resampledBuffer = resample(data, size: size, metadata: inMeta)

        if resampledBuffer.buffer.isEmpty {
            resampledBuffer.buffer.append(data, count: size)
        }

        mixQueue.enqueue {
            guard let lSource = inSource.value else { return }

            var mixTime = cMixTime
            let g: Float = 0.70710678118  // 1 / sqrt(2)
            let h = hash(lSource)

            if let time = self.lastSampleTime[h],
                mixTime.timeIntervalSince(time) < self.frameDuration * 0.25 {
                mixTime = time
            }

            var startOffset = 0
            var window: MixWindow? = currentWindow
            let diff = mixTime.timeIntervalSince(currentWindow.start)

            if diff > 0 {
                startOffset = Int(diff * Double(self.outFrequencyInHz) *
                    Double(self.bytesPerSample)) & ~(self.bytesPerSample-1)

                while let size = window?.size, startOffset >= size {
                    startOffset -= size
                    window = window?.next
                }
            } else {
                startOffset = 0
            }

            let sampleDuration = Double(resampledBuffer.buffer.count) / Double(self.bytesPerSample *
                self.outFrequencyInHz)
            let mult = self.inGain[h].map { $0 * g } ?? 0

            resampledBuffer.buffer.withUnsafeBytes {
                guard let p = $0.baseAddress?.assumingMemoryBound(to: Int16.self) else {
                    Logger.error("unaligned pointer \($0)")
                    return
                }
                var mix = p
                var bytesLeft = resampledBuffer.buffer.count
                var so = startOffset

                while bytesLeft > 0 {
                    guard let _window = window else {
                        Logger.debug("unexpected return")
                        break
                    }

                    let toCopy = min(_window.size - so, bytesLeft)
                    let count = toCopy / MemoryLayout<Int16>.size

                    _window.buffer[so...].withUnsafeMutableBufferPointer {
                        let winMix = UnsafeMutableRawBufferPointer($0).bindMemory(to: Int16.self)
                        for i in 0..<count {
                            winMix[i] = AudioMixer.TPMixSamples(winMix[i], Int16(Float((mix + i).pointee)*mult))
                        }

                        mix += count
                        bytesLeft -= toCopy

                        if bytesLeft > 0 {
                            window = window?.next
                            so = 0
                        }
                    }
                }
            }

            self.lastSampleTime[h] = mixTime + sampleDuration
        }
    }

    /*! ITransform::setOutput */
    open func setOutput(_ output: IOutput) {
        self.output = output
    }

    /*! IAudioMixer::setSourceGain */
    open func setSourceGain(_ source: WeakRefISource, gain: Float) {
        if let s = source.value {
            let h = hash(s)

            var gain = max(0, min(1, gain))
            gain = powf(gain, kE)
            inGain[h] = gain
        }
    }

    /*! IAudioMixer::setChannelCount */
    open func setChannelCount(_ channelCount: Int) {
        outChannelCount = channelCount
    }

    /*! IAudioMixer::setFrequencyInHz */
    open func setFrequencyInHz(_ frequencyInHz: Float) {
        outFrequencyInHz = Int(frequencyInHz)
    }

    /*! IAudioMixer::setMinimumBufferDuration */
    open func setMinimumBufferDuration(_ duraiton: Double) {
        bufferDuration = duraiton
    }

    /*! ITransform::setEpoch */
    open func setEpoch(_ epoch: Date) {
        self.epoch = epoch
        nextMixTime = epoch
    }

    open func start() {
        _mixThread = Thread(target: self, selector: #selector(mixThread), object: nil)
        _mixThread?.name = "jp.co.cyberagent.VideoCast.audiomixer"
        exiting.value = false
        _mixThread?.start()
    }

    open func stop() {
        exiting.value = true
        mixThreadCond.broadcast()
        _mixThread?.cancel()
    }

    open func setDelay(delay: TimeInterval) {
        self.delay = delay
    }
}
