//
//  AACPacketizer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/11.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import CoreMedia

open class AACPacketizer: ITransform {
    private var epoch: Date = .init()
    private weak var output: IOutput?
    private var outBuffer: [UInt8] = .init()
    private let audioTs: Double = 0
    private var asc: [UInt8] = .init(repeating: 0, count: 2)
    private var sentAudioConfig: Bool = false
    private let sampleRate: Float
    private let ctsOffset: CMTime
    private let channelCount: Int
    
    public init(sampleRate: Int = 44100, channelCount: Int = 2, ctsOffset: CMTime = .init(value: 0, timescale: VC_TIME_BASE)) {
        self.sampleRate = Float(sampleRate)
        self.channelCount = channelCount
        self.ctsOffset = ctsOffset
    }
    
    deinit {
        Logger.debug("AACPacketizer::deinit")
    }
    
    open func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        guard let output = output else { return }

        let inBuffer = data.assumingMemoryBound(to: UInt8.self)
        let inSize = size
        
        outBuffer.removeAll()
        
        let flvStereoOrMono: FlvFlags = channelCount == 2 ? .stereo : .mono
        var flvSampleRate = FlvFlags.samplerate44100hz  // default
        if sampleRate == 22050 {
            flvSampleRate = FlvFlags.samplerate22050hz
        }
        
        var flags: FlvFlags = []
        let flags_size = 2
        
        let ts = metadata.pts + ctsOffset
        
        let outMeta = RTMPMetadata(ts: ts)
        
        if inSize == 2 && asc[0] == 0 && asc[1] == 0 {
            asc[0] = inBuffer[0]
            asc[1] = inBuffer[1]
        }
        
        flags = [.codecIdAac, flvSampleRate, .samplesize16bit, flvStereoOrMono]
        
        outBuffer.reserveCapacity(inSize + flags_size)
        
        put_byte(&outBuffer, val: flags.rawValue)
        put_byte(&outBuffer, val: sentAudioConfig ? 1 : 0)
        
        if !sentAudioConfig {
            sentAudioConfig = true
            put_buff(&outBuffer, src: asc)
            
        } else {
            put_buff(&outBuffer, src: inBuffer, srcsize: inSize)
        }
        
        outMeta.data = (.audio, Int(ts.seconds * 1000), outBuffer.count, .audio, .data, false)
        
        output.pushBuffer(outBuffer, size: outBuffer.count, metadata: outMeta)
    }
    
    open func setOutput(_ output: IOutput) {
        self.output = output
    }

    open func setEpoch(_ epoch: Date) {
        self.epoch = epoch
    }
}
