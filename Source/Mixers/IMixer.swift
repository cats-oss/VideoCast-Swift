//
//  IMixer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/05.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

/*!
 *  IMixer interface.  Defines the interface for registering and unregistering sources with mixers.
 */
public protocol IMixer: ITransform {
    /*!
     *  Register a source with the mixer.  There may be intermediate transforms between the source and
     *  the mixer.
     *
     *  \param source A smart pointer to the source being registered.
     *  \param inBufferSize an optional parameter to specify the expected buffer size from the source. Only useful if
     *         the buffer size is always the same.
     */
    func registerSource(_ source: ISource, inBufferSize: Int)
    func registerSource(_ source: ISource)

    /*!
     *  Unregister a source with the mixer.
     *
     *  \param source  A smart pointer to the source being unregistered.
     */
    func unregisterSource(_ source: ISource)

    func start()
    func stop()
}

extension IMixer {
    public func registerSource(_ source: ISource) {
        registerSource(source, inBufferSize: 0)
    }
}
