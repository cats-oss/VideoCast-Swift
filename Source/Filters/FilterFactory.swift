//
//  FilterFactory.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

open class FilterFactory {
    public typealias InstantiateFilter = () -> IFilter
    
    private var filters: [String: IFilter] = [:]
    
    private static var registration: [String: InstantiateFilter] = [:]
    
    public init() {
        _ = BasicVideoFilterBGRA.isRegistered
        _ = BasicVideoFilterBGRAinYUVAout.isRegistered
        _ = FisheyeVideoFilter.isRegistered
        _ = GlowVideoFilter.isRegistered
        _ = GrayscaleVideoFilter.isRegistered
        _ = InvertColorsVideoFilter.isRegistered
        _ = SepiaVideoFilter.isRegistered
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
