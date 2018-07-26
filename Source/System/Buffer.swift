//
//  Buffer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/26.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

enum AMFDataType: UInt8 {
    case number = 0,
    boolean,
    string,
    object,
    movieClip,        /* reserved, not used */
    null,
    undefined,
    reference,
    eMCAArray,
    objectEnd,
    strictArray,
    date,
    longString,
    unsupported,
    recordSet,        /* reserved, not used */
    xmlDoc,
    typedObject,
    avmPlus        /* switch to AMF3 */
    case invalid = 0xff
}

/************************************************
 * Buffer writing funcs
 ************************************************/
func put_buff<T: Sequence>(_ data: inout [UInt8], src: T) where T.Iterator.Element == UInt8 {
    data.append(contentsOf: src)
}

func put_buff(_ data: inout [UInt8], src: UnsafeRawPointer, srcsize: Int) {
    data.append(contentsOf: UnsafeRawBufferPointer(start: src, count: srcsize))
}

func put_byte(_ data: inout [UInt8], val: UInt8) {
    data.append(val)
}

func put_be16(_ data: inout [UInt8], val: Int16) {
    var buf: [UInt8] = .init(repeating: 0, count: 2)
    buf[1] = UInt8(val & 0xff)
    buf[0] = UInt8((val >> 8) & 0xff)

    put_buff(&data, src: buf)
}

func get_be16(_ val: [UInt8]) -> Int {
    return (Int(val[0]) << 8) | (Int(val[1]))
}

func get_be16(_ val: ArraySlice<UInt8>) -> Int {
    return (Int(val[val.startIndex]) << 8) | (Int(val[val.startIndex + 1]))
}

func put_be24(_ data: inout [UInt8], val: Int32) {
    var buf: [UInt8] = .init(repeating: 0, count: 3)

    buf[2] = UInt8(val & 0xff)
    buf[1] = UInt8((val >> 8) & 0xff)
    buf[0] = UInt8((val >> 16) & 0xff)

    put_buff(&data, src: buf)
}

func get_be24(_ val: ArraySlice<UInt8>) -> Int {
    let ret = (Int(val[val.startIndex + 2])) | (Int(val[val.startIndex + 1]) << 8) | (Int(val[val.startIndex]<<16))
    return ret
}

func put_be32(_ data: inout [UInt8], val: Int32) {
    var buf: [UInt8] = .init(repeating: 0, count: 4)

    buf[3] = UInt8(val & 0xff)
    buf[2] = UInt8((val >> 8) & 0xff)
    buf[1] = UInt8((val >> 16) & 0xff)
    buf[0] = UInt8((val >> 24) & 0xff)

    put_buff(&data, src: buf)
}

func get_be32(_ val: ArraySlice<UInt8>) -> Int {
    let b1 = Int(val[val.startIndex]) << 24
    let b2 = Int(val[val.startIndex + 1]) << 16
    let b3 = Int(val[val.startIndex + 2]) << 8
    let b4 = Int(val[val.startIndex + 3])
    return  b1 | b2 | b3 | b4
}

func get_be32(_ val: [UInt8]) -> Int {
    let b1 = Int(val[0]) << 24
    let b2 = Int(val[1]) << 16
    let b3 = Int(val[2]) << 8
    let b4 = Int(val[3])
    return  b1 | b2 | b3 | b4
}

func put_tag(_ data: inout [UInt8], tag: [UInt8]) {
    var i = 0
    while tag[i] != 0 {
        put_byte(&data, val: tag[i])
        i += 1
    }
}

func put_string(_ data: inout [UInt8], string: String) {
    if string.count < 0xFFFF {
        put_byte(&data, val: AMFDataType.string.rawValue)
        put_be16(&data, val: Int16(string.count))
    } else {
        put_byte(&data, val: AMFDataType.longString.rawValue)
        put_be32(&data, val: Int32(string.count))
    }
    put_buff(&data, src: [UInt8](string.utf8))
}

func get_string(_ buf: [UInt8], bufsize: inout Int) -> String? {
    var len = 0
    var buf = ArraySlice(buf)
    if buf[0] == AMFDataType.string.rawValue {
        buf = buf.dropFirst(1)
        len = get_be16(buf)
        buf = buf.dropFirst(2)
        bufsize = 2 + len
    } else {
        buf = buf.dropFirst(1)
        len = get_be32(buf)
        buf = buf.dropFirst(4)
        bufsize = 4 + len
    }

    let val = String(data: .init(buf.prefix(len)), encoding: .utf8)
    return val
}

func get_string(_ buf: [UInt8]) -> String? {
    var buflen = 0
    return get_string(buf, bufsize: &buflen)
}

func put_double(_ data: inout [UInt8], val: Double) {
    put_byte(&data, val: AMFDataType.number.rawValue)

    var buf = CFConvertFloat64HostToSwapped(val)
    let src = [UInt8](Data(bytes: &buf, count: MemoryLayout<CFSwappedFloat64>.size))

    put_buff(&data, src: src)
}

func get_double(_ buf: [UInt8]) -> Double {
    var arg: CFSwappedFloat64 = .init()
    memcpy(&arg, buf, MemoryLayout<CFSwappedFloat64>.size)
    return CFConvertDoubleSwappedToHost(arg)
}

func get_double(_ buf: ArraySlice<UInt8>) -> Double {
    var arg: CFSwappedFloat64 = .init()
    memcpy(&arg, buf.withUnsafeBytes { $0.baseAddress }, MemoryLayout<CFSwappedFloat64>.size)
    return CFConvertDoubleSwappedToHost(arg)
}

func put_bool(_ data: inout [UInt8], val: Bool) {
    put_byte(&data, val: AMFDataType.boolean.rawValue)
    put_byte(&data, val: val ? 1 : 0)
}

func put_name(_ data: inout [UInt8], name: String) {
    put_be16(&data, val: Int16(name.count))
    put_buff(&data, src: [UInt8](name.utf8))
}

func put_named_double(_ data: inout [UInt8], name: String, val: Double) {
    put_name(&data, name: name)
    put_double(&data, val: val)
}

func put_named_string(_ data: inout [UInt8], name: String, val: String) {
    put_name(&data, name: name)
    put_string(&data, string: val)
}

func put_named_bool(_ data: inout [UInt8], name: String, val: Bool) {
    put_name(&data, name: name)
    put_bool(&data, val: val)
}

class Buffer {
    private var buffer: [UInt8]
    var size: Int
    var total: Int

    init(_ size: Int = 0) {
        total = size
        self.size = 0
        buffer = [UInt8]()
        resize(size)
    }

    @discardableResult
    func resize(_ size: Int) -> Int {
        if size > 0 {
            buffer = [UInt8](repeating: 0, count: size)
        } else {
            buffer = [UInt8]()
        }
        total = size
        self.size = 0

        return size
    }

    func get() -> UnsafePointer<UInt8> {
        return buffer.withUnsafeBufferPointer { $0.baseAddress! }
    }

    func getMutable() -> UnsafeMutablePointer<UInt8> {
        return buffer.withUnsafeMutableBufferPointer { $0.baseAddress! }
    }

    @discardableResult
    func put(_ buf: UnsafeRawPointer, size: Int) -> Int {
        let size = size > self.total ? self.total : size

        let p = buf.assumingMemoryBound(to: UInt8.self)
        let arr = Array(UnsafeBufferPointer(start: p, count: size))
        buffer[..<size] = arr.prefix(size)
        self.size = size
        return size
    }

    @discardableResult
    func append(_ buf: UnsafeRawPointer, size: Int) -> Int {
        let size = size + self.size > self.total ? self.total - self.size : size

        let p = buf.assumingMemoryBound(to: UInt8.self)
        let arr = Array(UnsafeBufferPointer(start: p, count: size))
        buffer[self.size..<size + self.size] = arr.prefix(size)
        self.size += size
        return size
    }

    @discardableResult
    func read(_ buf: inout UnsafePointer<UInt8>?, size: Int) -> Int {
        let size = size > self.size ? self.size : size

        buf = buffer.withUnsafeBufferPointer { $0.baseAddress }

        return size
    }
}
