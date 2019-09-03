//
//  Split.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

open class Split: ITransform {
    var outputs: [WeakRefIOutput] = .init()

    public init() {

    }

    deinit {
        outputs.removeAll()
    }

    open func setOutput(_ output: IOutput) {
        if !outputs.contains(where: {$0 === output}) {
            outputs.append(WeakRefIOutput(value: output))
        }
    }

    open func removeOutput(_ output: IOutput) {
        if let it = outputs.firstIndex(where: {$0 === output}) {
            outputs.remove(at: it)
        }
    }

    open func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        for it in outputs {
            it.value?.pushBuffer(data, size: size, metadata: metadata)
        }
    }

}
