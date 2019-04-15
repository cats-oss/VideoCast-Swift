//
//  IVideoMixer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/05.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import GLKit

/*!
 *  Specifies the properties of the incoming image buffer.
 */
public typealias VideoBufferMetadata = MetaData<(
    zIndex: Int,                /*!< Specifies the z-Index the buffer (lower is farther back) */
    /*!< Specifies the transformation matrix to use. Pass an Identity matrix if no transformation is to be applied.
     Note that the compositor operates using homogeneous coordinates (-1 to 1) unless otherwise specified. */
    matrix: GLKMatrix4,

    blends: Bool,
    source: WeakRefISource    /*!< Specifies a smart pointer to the source */
    )>

/*! IVideoMixer interface.  Defines the required interface methods for Video mixers (compositors). */
public protocol IVideoMixer: IMixer {
    func setSourceFilter(_ source: WeakRefISource, filter: IVideoFilter)
    func sync()

    func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData)

    func setFrameSize(width: Int, height: Int)
}
