//
//  GetBits.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/28.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

class GetBits {
    var buffer: UnsafeRawPointer
    var index: UInt32 = 0
    
    init(_ buffer: UnsafeRawPointer) {
        self.buffer = buffer
    }
    
    func get_bits(_ n: Int) -> UInt32 {
        assert(n>0 && n<=25)
        
        let ptr = buffer + Int(index >> 3)
        let val = CFSwapInt32HostToBig(ptr.assumingMemoryBound(to: UInt32.self).pointee)
        let re_cache = val << (index & 7)
        
        let tmp = re_cache >> (32-n)
        index += UInt32(n)
        
        return tmp
    }
}
