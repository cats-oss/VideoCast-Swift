//
//  Util.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/24.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit

public let VC_TIME_BASE: Int32 = 1000000

extension GLKMatrix4 {
    var array: [Float] {
        return (0..<16).map { i in
            self[i]
        }
    }
}

func hash(_ obj: AnyObject) -> Int {
    return ObjectIdentifier(obj).hashValue
}

public class WeakRefISource {
    private(set) weak var value: ISource?

    init(value: ISource?) {
        self.value = value
    }
}

public class WeakRefIOutput {
    private(set) weak var value: IOutput?

    init(value: IOutput?) {
        self.value = value
    }
}

func syncSafe<T>(_ work: () -> T) -> T {
    if Thread.isMainThread {
        return work()
    } else {
        return DispatchQueue.main.sync {
            return work()
        }
    }
}
