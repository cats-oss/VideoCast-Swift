//
//  ADTSEncode.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/28.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

open class ADTSEncode: ITransform {
    private weak var output: IOutput?
    
    private let ADTS_HEADER_SIZE: Int = 7
    private let ADTS_MAX_FRAME_BYTES: Int = ((1 << 13) - 1)
    
    private var write_adts: Bool = false
    private var objecttype: Int = 0
    private var sample_rate_index: Int = 0
    private var channel_conf: Int = 0
    
    private let streamIndex: Int
    
    public init(_ streamIndex: Int) {
        self.streamIndex = streamIndex
    }
    
    public func setOutput(_ output: IOutput) {
        self.output = output
    }
    
    public func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        let inBuffer = data.assumingMemoryBound(to: UInt8.self)
        
        if size == 2 {
            if !write_adts {
                let gb: GetBits = .init(inBuffer)
                objecttype = Int(gb.get_bits(5)) - 1
                sample_rate_index = Int(gb.get_bits(4))
                channel_conf = Int(gb.get_bits(4))
                write_adts = true
            }
            return
        }

        guard write_adts else { return }
        
        var buf: [UInt8] = .init(repeating: 0x00, count: ADTS_HEADER_SIZE)
        guard write_frame_header(&buf, size: size) else { return }

        buf.reserveCapacity(ADTS_HEADER_SIZE + size)
        buf.append(contentsOf: UnsafeBufferPointer<UInt8>(start: data.assumingMemoryBound(to: UInt8.self), count: size))
        
        var metadata = metadata
        metadata.streamIndex = streamIndex
        output?.pushBuffer(buf, size: ADTS_HEADER_SIZE + size, metadata: metadata)
    }
    
    private func write_frame_header(_ buf: inout [UInt8], size: Int) -> Bool {
        let full_frame_size = ADTS_HEADER_SIZE + size
        guard full_frame_size <= ADTS_MAX_FRAME_BYTES else {
            Logger.error("ADTS frame size too large: \(full_frame_size) (max \(ADTS_MAX_FRAME_BYTES)")
            return false
        }
        
        let pb = PutBits(&buf, buffer_size: ADTS_HEADER_SIZE)
        
        /* adts_fixed_header */
        pb.put_bits(12, value: 0xfff)    /* syncword */
        pb.put_bits(1, value: 0)        /* ID */
        pb.put_bits(2, value: 0)        /* layer */
        pb.put_bits(1, value: 1)        /* protection_absent */
        pb.put_bits(2, value: UInt32(objecttype)) /* profile_objecttype */
        pb.put_bits(4, value: UInt32(sample_rate_index))
        pb.put_bits(1, value: 0)        /* private_bit */
        pb.put_bits(3, value: UInt32(channel_conf)) /* channel_configuration */
        pb.put_bits(1, value: 0)        /* original_copy */
        pb.put_bits(1, value: 0)        /* home */
        
        /* adts_variable_header */
        pb.put_bits(1, value: 0)        /* copyright_identification_bit */
        pb.put_bits(1, value: 0)        /* copyright_identification_start */
        pb.put_bits(13, value: UInt32(full_frame_size)) /* aac_frame_length */
        pb.put_bits(11, value: 0x7ff)   /* adts_buffer_fullness */
        pb.put_bits(2, value: 0)        /* number_of_raw_data_blocks_in_frame */
        
        pb.flush_put_bits()
        
        return true
    }
}
