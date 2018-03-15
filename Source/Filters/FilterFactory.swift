//
//  FilterFactory.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

public typealias InstantiateFilter = () -> IFilter

open class FilterFactory {
    private var filters: [String: IFilter] = [:]
    
    private static var registration: [String: InstantiateFilter] = [:]
    
    
    public init() {
        _ = BasicVideoFilterBGRA.registered
        _ = BasicVideoFilterBGRAinYUVAout.registered
        _ = FisheyeVideoFilter.registered
        _ = GlowVideoFilter.registered
        _ = GrayscaleVideoFilter.registered
        _ = InvertColorsVideoFilter.registered
        _ = SepiaVideoFilter.registered
    }
    
    open func filter(name: String) -> IFilter? {
        if let it = filters[name] {
            return it
        } else if let iit = FilterFactory.registration[name] {
            filters[name] = iit()
            return filters[name]
        }
        return nil
    }
    
    open static func register(name: String, instantiation: @escaping InstantiateFilter) {
        registration[name] = instantiation
    }
}
