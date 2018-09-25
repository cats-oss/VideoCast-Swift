//
//  SelectViewController.swift
//  iOS Example
//
//  Created by Tomohiro Matsuzawa on 2018/09/08.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import UIKit
import VideoCast

class SelectViewController: UITableViewController {
    var mode: OptionsUtil.SelectOption = .bitrate

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch mode {
        case .bitrate:
            return OptionsModel.shared.bitrates.count
        case .videoSize:
            return OptionsModel.shared.videoSizes.count
        case .videoCodec:
            return 2
        case .orientation:
            return 3
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SelectCell", for: indexPath)

        switch mode {
        case .bitrate:
            cell.textLabel?.text = OptionsUtil.getBitrateLabel(indexPath.row)
            cell.isSelected = OptionsModel.shared.bitrateIndex == indexPath.row
        case .videoSize:
            cell.textLabel?.text = OptionsUtil.getVideoSizeLabel(indexPath.row)
            cell.isSelected = OptionsModel.shared.videoSizeIndex == indexPath.row
        case .videoCodec:
            cell.textLabel?.text = OptionsUtil.getVideoCodecLabel(indexPath.row)
            cell.isSelected = OptionsModel.shared.videoCodec.rawValue == indexPath.row
        case .orientation:
            cell.textLabel?.text = OptionsUtil.getOrientationLabel(indexPath.row)
            cell.isSelected = OptionsModel.shared.orientation.rawValue == indexPath.row
        }
        cell.accessoryType = cell.isSelected ? .checkmark : .none

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch mode {
        case .bitrate:
            OptionsModel.shared.bitrateIndex = indexPath.row
        case .videoSize:
            OptionsModel.shared.videoSizeIndex = indexPath.row
        case .videoCodec:
            OptionsModel.shared.videoCodec = VCVideoCodecType(rawValue: indexPath.row)!
        case .orientation:
            OptionsModel.shared.orientation = Orientation(rawValue: indexPath.row)!
        }
        tableView.reloadData()
    }
}
