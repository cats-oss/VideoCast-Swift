//
//  H264Packetizer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/11.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import CoreMedia

open class H264Packetizer: ITransform {
    private var epoch: Date = .init()
    private weak var output: IOutput?
    private var sps: [UInt8] = .init()
    private var pps: [UInt8] = .init()
    private var outBuffer: [UInt8] = .init()
    
    private let videoTs: Double = 0
    
    private var configurationFromSpsAndPps: [UInt8] {
        var conf: [UInt8] = .init()
        
        put_byte(&conf, val: 1) // version
        put_byte(&conf, val: sps[1])    // profile
        put_byte(&conf, val: sps[2])    // compat
        put_byte(&conf, val: sps[3])    // level
        put_byte(&conf, val: 0xff)  // 6 bits reserved + 2 bits nal size length - 1 (11)
        put_byte(&conf, val: 0xe1)  // 3 bits reserved + 5 bits number of sps (00001)
        put_be16(&conf, val: Int16(sps.count))
        put_buff(&conf, src: sps)
        put_byte(&conf, val: 1)
        put_be16(&conf, val: Int16(pps.count))
        put_buff(&conf, src: pps)
        
        return conf
    }
    
    private let ctsOffset: CMTime
    private var sentConfig: Bool = false
    
    public init(ctsOffset: CMTime = .init(value: 0, timescale: VC_TIME_BASE)) {
        self.ctsOffset = ctsOffset
    }
    
    deinit {
        Logger.debug("H264Packetizer::deinit")
    }

    open func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        let inBuffer = data.assumingMemoryBound(to: UInt8.self)
        var inSize = size
        outBuffer.removeAll()
        
        let nal_type = inBuffer[4] & 0x1F
        var flags: FlvFlags = .init()
        let flags_size = 5
        let pts = metadata.pts + ctsOffset  // correct for pts < dts which some players (ffmpeg) don't like
        let dts = metadata.dts.isNumeric ? metadata.dts : pts - ctsOffset
        
        let is_config = (nal_type == 7 || nal_type == 8)
        
        flags = .codecIdH264
        
        switch nal_type {
        case 7:
            if sps.count == 0 {
                sps.removeAll()
                let buf = UnsafeBufferPointer<UInt8>(start: inBuffer.advanced(by: 4), count: inSize-4)
                sps.append(contentsOf: buf)
            }
        case 8:
            if pps.count == 0 {
                pps.removeAll()
                let buf = UnsafeBufferPointer<UInt8>(start: inBuffer.advanced(by: 4), count: inSize-4)
                pps.append(contentsOf: buf)
            }
            flags.insert(.frameKey)
        case 5:
            flags.insert(.frameKey)
            
        default:
            flags.insert(.frameInter)
        }
        
        guard let output = output else {
            Logger.debug("unexpected return")
            return
        }
        
        let outMeta: RTMPMetadata = .init(ts: dts)
        var conf: [UInt8] = .init()
        
        if is_config && sps.count > 0 && pps.count > 0 {
            conf = configurationFromSpsAndPps
            inSize = conf.count
        }
        outBuffer.reserveCapacity(inSize + flags_size)
        
        put_byte(&outBuffer, val: flags.rawValue)
        put_byte(&outBuffer, val: is_config ? 0 : 1)
        put_be24(&outBuffer, val: Int32((pts - dts).seconds * 1000))    // Decoder delay
        
        if is_config {
            // create modified SPS/PPS buffer
            if sps.count > 0 && pps.count > 0 && !sentConfig {
                put_buff(&outBuffer, src: conf)
                sentConfig = true
            } else {
                return
            }
        } else {
            put_buff(&outBuffer, src: inBuffer, srcsize: inSize)
        }
        
        outMeta.data = (.video, Int(dts.seconds * 1000), outBuffer.count, .video, .data, nal_type == 5)
        
        output.pushBuffer(outBuffer, size: outBuffer.count, metadata: outMeta)
    }

    open func setOutput(_ output: IOutput) {
        self.output = output
    }
    
    open func setEpoch(_ epoch: Date) {
        self.epoch = epoch
    }

}
