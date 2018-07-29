//
//  JobQueue.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/12.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

public enum JobQueuePriority {
    case `default`
    case high
    case low
}

// swiftlint:disable:next type_name
open class Job {
    public var done: Bool = false
    public var isSynchronous: Bool = false

    private var job: () -> Void
    private var dispatchDate: Date = Date()

    public init(_ job: @escaping () -> Void) {
        self.job = job
    }

    open func exec() {
        job()
        done = true
    }
}

open class JobQueue {
    private let queue: DispatchQueue
    private var exiting: Atomic<Bool> = .init(false)

    public init(_ name: String = "", priority: JobQueuePriority = .default) {
        let qos: DispatchQoS
        switch priority {
        case .default:
            qos = .default
        case .high:
            qos = .userInitiated
        case .low:
            qos = .utility
        }
        queue = .init(label: name, qos: qos)
    }

    deinit {
        markExiting()
    }

    open func markExiting() {
        exiting.value = true
    }

    open func enqueue(_ job: @escaping () -> Void) {
        enqueue(Job(job))
    }

    open func enqueue(_ job: Job) {
        queue.async { [weak self] in
            guard let strongSelf = self else { return }
            if !strongSelf.exiting.value {
                job.exec()
            }
        }
    }

    open func enqueueSync(_ job: @escaping () -> Void) {
        enqueueSync(Job(job))
    }

    open func enqueueSync(_ job: Job) {
        if let label = String(validatingUTF8: __dispatch_queue_get_label(nil)), label == queue.label {
            job.exec()
        } else {
            queue.sync(execute: job.exec)
        }
    }
}
