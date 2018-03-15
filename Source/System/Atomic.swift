//
//  Atomic.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/16.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

/// `Lock` exposes `os_unfair_lock` on supported platforms, with pthread mutex as the
// fallback.
internal class Lock {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    @available(iOS 10.0, *)
    @available(macOS 10.12, *)
    @available(tvOS 10.0, *)
    @available(watchOS 3.0, *)
    internal final class UnfairLock: Lock {
        private let _lock: os_unfair_lock_t
        
        override init() {
            _lock = .allocate(capacity: 1)
            _lock.initialize(to: os_unfair_lock())
            super.init()
        }
        
        override func lock() {
            os_unfair_lock_lock(_lock)
        }
        
        override func unlock() {
            os_unfair_lock_unlock(_lock)
        }
        
        override func `try`() -> Bool {
            return os_unfair_lock_trylock(_lock)
        }
        
        deinit {
            _lock.deinitialize()
            _lock.deallocate(capacity: 1)
        }
    }
    #endif
    
    internal final class PthreadLock: Lock {
        private let _lock: UnsafeMutablePointer<pthread_mutex_t>
        
        init(recursive: Bool = false) {
            _lock = .allocate(capacity: 1)
            _lock.initialize(to: pthread_mutex_t())
            
            let attr = UnsafeMutablePointer<pthread_mutexattr_t>.allocate(capacity: 1)
            attr.initialize(to: pthread_mutexattr_t())
            pthread_mutexattr_init(attr)
            
            defer {
                pthread_mutexattr_destroy(attr)
                attr.deinitialize()
                attr.deallocate(capacity: 1)
            }
            
            // Darwin pthread for 32-bit ARM somehow returns `EAGAIN` when
            // using `trylock` on a `PTHREAD_MUTEX_ERRORCHECK` mutex.
            #if DEBUG && !arch(arm)
                pthread_mutexattr_settype(attr, Int32(recursive ? PTHREAD_MUTEX_RECURSIVE : PTHREAD_MUTEX_ERRORCHECK))
            #else
                pthread_mutexattr_settype(attr, Int32(recursive ? PTHREAD_MUTEX_RECURSIVE : PTHREAD_MUTEX_NORMAL))
            #endif
            
            let status = pthread_mutex_init(_lock, attr)
            assert(status == 0, "Unexpected pthread mutex error code: \(status)")
            
            super.init()
        }
        
        override func lock() {
            let status = pthread_mutex_lock(_lock)
            assert(status == 0, "Unexpected pthread mutex error code: \(status)")
        }
        
        override func unlock() {
            let status = pthread_mutex_unlock(_lock)
            assert(status == 0, "Unexpected pthread mutex error code: \(status)")
        }
        
        override func `try`() -> Bool {
            let status = pthread_mutex_trylock(_lock)
            switch status {
            case 0:
                return true
            case EBUSY:
                return false
            default:
                assertionFailure("Unexpected pthread mutex error code: \(status)")
                return false
            }
        }
        
        deinit {
            let status = pthread_mutex_destroy(_lock)
            assert(status == 0, "Unexpected pthread mutex error code: \(status)")
            
            _lock.deinitialize()
            _lock.deallocate(capacity: 1)
        }
    }
    
    static func make() -> Lock {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
            if #available(*, iOS 10.0, macOS 10.12, tvOS 10.0, watchOS 3.0) {
                return UnfairLock()
            }
        #endif
        
        return PthreadLock()
    }
    
    private init() {}
    
    func lock() { fatalError() }
    func unlock() { fatalError() }
    func `try`() -> Bool { fatalError() }
}

/// An atomic variable.
public final class Atomic<Value> {
    private let lock: Lock
    private var _value: Value
    
    /// Atomically get or set the value of the variable.
    public var value: Value {
        get {
            return withValue { $0 }
        }
        
        set(newValue) {
            swap(newValue)
        }
    }
    
    /// Initialize the variable with the given initial value.
    ///
    /// - parameters:
    ///   - value: Initial value for `self`.
    public init(_ value: Value) {
        _value = value
        lock = Lock.make()
    }
    
    /// Atomically modifies the variable.
    ///
    /// - parameters:
    ///   - action: A closure that takes the current value.
    ///
    /// - returns: The result of the action.
    @discardableResult
    public func modify<Result>(_ action: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        
        return try action(&_value)
    }
    
    /// Atomically perform an arbitrary action using the current value of the
    /// variable.
    ///
    /// - parameters:
    ///   - action: A closure that takes the current value.
    ///
    /// - returns: The result of the action.
    @discardableResult
    public func withValue<Result>(_ action: (Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        
        return try action(_value)
    }
    
    /// Atomically replace the contents of the variable.
    ///
    /// - parameters:
    ///   - newValue: A new value for the variable.
    ///
    /// - returns: The old value.
    @discardableResult
    public func swap(_ newValue: Value) -> Value {
        return modify { (value: inout Value) in
            let oldValue = value
            value = newValue
            return oldValue
        }
    }
}
