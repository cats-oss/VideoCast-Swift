//
//  IAudioMixer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/05.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import CoreAudio

/*!
 *  Specifies the properties of the incoming audio buffer.
 */
public typealias AudioBufferMetadata = MetaData<(
    frequencyInHz: Int,         /*!< Specifies the sampling rate of the buffer */
    bitsPerChannel: Int,        /*!< Specifies the number of bits per channel */
    channelCount: Int,          /*!< Specifies the number of channels */
    flags: AudioFormatFlags,    /*!< Specifies the audio flags */
    bytesPerFrame: Int,         /*!< Specifies the number of bytes per frame */
    numberFrames: Int,          /*!< Number of sample frames in the buffer. */
    usesOSStruct: Bool,         /*!< Indicates that the audio is not raw but instead uses a platform-specific struct */
    loops: Bool,                /*!< Indicates whether or not the buffer should loop. Currently ignored. */
    source: WeakRefISource    /*!< A smart pointer to the source. */
    )>

/*! IAudioMixer protocole.  Defines the required protocol function for Audio mixers. */
public protocol IAudioMixer: IMixer {
    /*!
     *  Set the output gain of the specified source.
     *
     *  \param source  A smart pointer to the source to be modified
     *  \param gain    A value between 0 and 1 representing the desired gain.
     */
    func setSourceGain(_ source: WeakRefISource, gain: Float)

    /*!
     *  Set the channel count.
     *
     *  \param channelCount  The number of audio channels.
     */
    func setChannelCount(_ channelCount: Int)

    /*!
     *  Set the channel count.
     *
     *  \param frequencyInHz  The audio sample frequency in Hz.
     */
    func setFrequencyInHz(_ frequencyInHz: Float)

    /*!
     *  Set the amount of time to buffer before emitting mixed samples.
     *
     *  \param duration The duration, in seconds, to buffer.
     */
    func setMinimumBufferDuration(_ duraiton: Double)
}
