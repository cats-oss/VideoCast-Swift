//
//  IFilter.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/05.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

public protocol IFilter: class {
    var initialized: Bool { get }
    var name: String { get }
    
    func initialize()
    
    func bind()
    func unbind()
}
