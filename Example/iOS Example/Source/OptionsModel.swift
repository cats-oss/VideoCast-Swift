//
//  OptionsModel.swift
//  iOS Example
//
//  Created by Tomohiro Matsuzawa on 2018/09/06.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import VideoCast

enum BitrateMode: Int {
    case automatic
    case fixed
}

class OptionsModel {
    static let shared = OptionsModel()

    private let userDefaults = UserDefaults.standard

    private let bitrateModeKey = "Options.BitrateMode"
    private let maxBitrateIndexKey = "Options.MaxBitrateIndex"
    private let fixedBitrateIndexKey = "Options.FixedBitrateIndex"
    private let framerateKey = "Options.Framerate"
    private let keyframeIntervalKey = "Options.KeyframeInterval"
    private let videoSizeIndexKey = "Options.VideoSizeIndex"
    private let videoCodecKey = "Options.VideoCodec"

    private var _bitrateMode: BitrateMode
    private var _maxBitrateIndex: Int
    private var _fixedBitrateIndex: Int
    private var _framerate: Int
    private var _keyframeInterval: Int
    private var _videoSizeIndex: Int
    private var _videoCodec: VCVideoCodecType

    let bitrates = [200000, 400000, 800000, 1200000, 2400000, 4000000, 8000000, 12000000]
    let videoSizes: [(width: Int, height: Int)] = [
        (192, 144),
        (320, 240),
        (352, 240),
        (352, 288),
        (480, 360),
        (640, 360),
        (640, 480),
        (960, 540),
        (1280, 720),
        (1920, 1080),
        (3840, 2160)
    ]

    var bitrateMode: BitrateMode {
        get { return _bitrateMode }
        set {
            _bitrateMode = newValue
            userDefaults.set(_bitrateMode.rawValue, forKey: bitrateModeKey)
        }
    }

    var maxBitrateIndex: Int {
        get { return _maxBitrateIndex }
        set {
            _maxBitrateIndex = newValue
            userDefaults.set(_maxBitrateIndex, forKey: maxBitrateIndexKey)
        }
    }

    var fixedBitrateIndex: Int {
        get { return _fixedBitrateIndex }
        set {
            _fixedBitrateIndex = newValue
            userDefaults.set(_fixedBitrateIndex, forKey: fixedBitrateIndexKey)
        }
    }

    var bitrateIndex: Int {
        get {
            switch _bitrateMode {
            case .automatic:
                return _maxBitrateIndex
            case .fixed:
                return _fixedBitrateIndex
            }
        }
        set {
            switch _bitrateMode {
            case .automatic:
                maxBitrateIndex = newValue
            case .fixed:
                fixedBitrateIndex = newValue
            }
        }
    }

    var bitrate: Int {
        return bitrates[bitrateIndex]
    }

    var framerate: Int {
        get { return _framerate }
        set {
            _framerate = newValue
            userDefaults.set(_framerate, forKey: framerateKey)
        }
    }
    var keyframeInterval: Int {
        get { return _keyframeInterval }
        set {
            _keyframeInterval = newValue
            userDefaults.set(_keyframeInterval, forKey: keyframeIntervalKey)
        }
    }
    var videoSizeIndex: Int {
        get { return _videoSizeIndex }
        set {
            _videoSizeIndex = newValue
            userDefaults.set(_videoSizeIndex, forKey: videoSizeIndexKey)
        }
    }

    var videoCodec: VCVideoCodecType {
        get { return _videoCodec }
        set {
            _videoCodec = newValue
            userDefaults.set(_videoCodec.rawValue, forKey: videoCodecKey)
        }
    }

    private init() {
        userDefaults.register(defaults: [
            bitrateModeKey: 0,
            maxBitrateIndexKey: 4,
            fixedBitrateIndexKey: 3,
            framerateKey: 30,
            keyframeIntervalKey: 60,
            videoSizeIndexKey: 5,
            videoCodecKey: VCVideoCodecType.h264.rawValue
            ])

        _bitrateMode = BitrateMode(rawValue: userDefaults.integer(forKey: bitrateModeKey))!
        _maxBitrateIndex = userDefaults.integer(forKey: maxBitrateIndexKey)
        _fixedBitrateIndex = userDefaults.integer(forKey: fixedBitrateIndexKey)
        _framerate = userDefaults.integer(forKey: framerateKey)
        _keyframeInterval = userDefaults.integer(forKey: keyframeIntervalKey)
        _videoSizeIndex = userDefaults.integer(forKey: videoSizeIndexKey)
        _videoCodec = VCVideoCodecType(rawValue: userDefaults.integer(forKey: videoCodecKey))!
    }
}
