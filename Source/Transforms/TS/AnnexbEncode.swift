//
//  AnnexbEncode.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/28.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import CoreMedia

open class AnnexbEncode: ITransform {
    private weak var output: IOutput?
    
    private var vps: [UInt8] = .init()
    private var sps: [UInt8] = .init()
    private var pps: [UInt8] = .init()
    
    private var conf: [UInt8] = .init()

    private let nalu_header_size: Int = 4
    private let kAnnexBHeaderBytes: [UInt8] = [0, 0, 0, 1]
    
    private let streamIndex: Int
    private let codecType: CMVideoCodecType

    public init(_ streamIndex: Int, codecType: CMVideoCodecType) {
        self.streamIndex = streamIndex
        self.codecType = codecType
    }
    
    public func setOutput(_ output: IOutput) {
        self.output = output
    }
    
    public func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        let inBuffer = data.assumingMemoryBound(to: UInt8.self)
        var nalType: NalType = .unknown
        let keyFrame: Bool = metadata.isKey
        
        let nal_type: UInt8
        switch codecType {
        case kCMVideoCodecType_H264:
            nal_type = inBuffer[nalu_header_size] & 0x1F
            switch nal_type {
            case 7:
                nalType = .sps
            case 8:
                nalType = .pps
            default:
                break
            }
        case kCMVideoCodecType_HEVC:
            nal_type = (inBuffer[nalu_header_size] & 0x7E) >> 1
            switch nal_type {
            case 32:
                nalType = .vps
            case 33:
                nalType = .sps
            case 34:
                nalType = .pps
            default:
                break
            }
        default:
            Logger.error("unsupported codec type: \(codecType)")
            return
        }
        
        let is_config = (nalType != .unknown)
        
        switch nalType {
        case .vps:
            if vps.count == 0 {
                let buf = UnsafeBufferPointer<UInt8>(start: inBuffer.advanced(by: nalu_header_size), count: size-nalu_header_size)
                vps.append(contentsOf: buf)
            }
        case .sps:
            if sps.count == 0 {
                let buf = UnsafeBufferPointer<UInt8>(start: inBuffer.advanced(by: nalu_header_size), count: size-nalu_header_size)
                sps.append(contentsOf: buf)
            }
        case .pps:
            if pps.count == 0 {
                let buf = UnsafeBufferPointer<UInt8>(start: inBuffer.advanced(by: nalu_header_size), count: size-nalu_header_size)
                pps.append(contentsOf: buf)
            }
            
        default:
            break
        }
        
        if is_config {
            if conf.count == 0 && sps.count > 0 && pps.count > 0 && (codecType != kCMVideoCodecType_HEVC || vps.count > 0){
                conf = configurationFromSpsAndPps
            }
        } else {
            var annexb_buffer: [UInt8] = .init()
            
            annexb_buffer.append(contentsOf: kAnnexBHeaderBytes)
            
            if codecType == kCMVideoCodecType_HEVC {
                annexb_buffer.append(2*35)
                annexb_buffer.append(1)
                annexb_buffer.append(0x50) // any slice type (0x4) + rbsp stop one bit
            } else {
                annexb_buffer.append(0x09)  // AUD
                annexb_buffer.append(0xf0)  // any slice type (0xe) + rbsp stop one bit
            }
            
            if keyFrame {
                annexb_buffer.append(contentsOf: conf)
            }
            
            var data_ptr = inBuffer
            
            var bytes_remaining = size
            
            while bytes_remaining > 0 {
                // The size type here must match |nalu_header_size|, we expect 4 bytes.
                // Read the length of the next packet of data. Must convert from big endian
                // to host endian.
                let packet_size = data_ptr.withMemoryRebound(to: UInt32.self, capacity: 1) {
                    Int(CFSwapInt32BigToHost($0.pointee))
                }
                if !isAUD(data_ptr[4]) {  // AUD NAL
                    // Update buffer.
                    annexb_buffer.append(contentsOf: kAnnexBHeaderBytes)
                    let buf = UnsafeBufferPointer<UInt8>(start: data_ptr.advanced(by: nalu_header_size), count: packet_size)
                    annexb_buffer.append(contentsOf: buf)
                }
                
                let bytes_written = packet_size + kAnnexBHeaderBytes.count
                bytes_remaining -= bytes_written
                data_ptr += bytes_written
            }
            
            var metadata = metadata
            metadata.streamIndex = streamIndex
            output?.pushBuffer(annexb_buffer, size: annexb_buffer.count, metadata: metadata)
        }
    }
    
    private func isAUD(_ state: UInt8) -> Bool {
        if codecType == kCMVideoCodecType_HEVC {
            return (state & 0x7e) == 2*35
        } else {
            return (state & 0x1F) == 9
        }
    }
    
    private var configurationFromSpsAndPps: [UInt8] {
        var conf: [UInt8] = .init()
        
        if codecType == kCMVideoCodecType_HEVC{
            conf.append(contentsOf: kAnnexBHeaderBytes)
            conf.append(contentsOf: vps)
        }
        
        conf.append(contentsOf: kAnnexBHeaderBytes)
        conf.append(contentsOf: sps)
        
        conf.append(contentsOf: kAnnexBHeaderBytes)
        conf.append(contentsOf: pps)
        
        return conf
    }
}
