//
//  ISource.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/05.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

/*!
 *  ISource interface.  Defines the interface for sources of data into a graph.
 */
public protocol ISource: AnyObject {
    /*!
     *  a component that conforms to the IOutput interface and is compatible with the
     *                data being vended by the source.
     */
    var filter: IFilter? { get set }
    
    func setOutput(_ output: IOutput)
}
