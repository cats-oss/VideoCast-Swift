//
//  ServersModel.swift
//  iOS Example
//
//  Created by Tomohiro Matsuzawa on 2018/09/08.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

class Server: NSObject, NSCoding {
    var desc: String
    var url: String
    var streamName: String

    init(desc: String, url: String, streamName: String) {
        self.desc = desc
        self.url = url
        self.streamName = streamName
    }

    required convenience init?(coder aDecoder: NSCoder) {
        guard let desc = aDecoder.decodeObject(forKey: "desc") as? String,
            let url = aDecoder.decodeObject(forKey: "url") as? String,
            let streamName = aDecoder.decodeObject(forKey: "streamName") as? String
            else { fatalError() }
        self.init(desc: desc, url: url, streamName: streamName)
    }

    func encode(with aCoder: NSCoder) {
        aCoder.encode(desc, forKey: "desc")
        aCoder.encode(url, forKey: "url")
        aCoder.encode(streamName, forKey: "streamName")
    }
}

class ServerModel {
    static let shared = ServerModel()

    private let userDefaults = UserDefaults.standard
    private let serversKey = "Server.Servers"
    private let selectedKey = "Server.Selected"

    private var _servers: [Server]
    private var _selected: Int

    var servers: [Server] {
        get {
            return _servers
        }
        set {
            _servers = newValue
            let encodedData: Data = NSKeyedArchiver.archivedData(withRootObject: _servers)
            userDefaults.set(encodedData, forKey: serversKey)
            userDefaults.synchronize()
        }
    }

    var selected: Int {
        get {
            return _selected
        }
        set {
            _selected = newValue
            userDefaults.set(_selected, forKey: selectedKey)
            userDefaults.synchronize()
        }
    }

    var server: Server {
        return _servers[_selected]
    }

    private init() {
        if let decoded = userDefaults.object(forKey: serversKey) as? Data {
            _servers = NSKeyedUnarchiver.unarchiveObject(with: decoded) as? [Server] ?? []
        } else {
            _servers = []
        }

        _selected = userDefaults.integer(forKey: selectedKey)
    }
}
