//
//  OptionsViewController.swift
//  iOS Example
//
//  Created by Tomohiro Matsuzawa on 2018/09/06.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import UIKit

class OptionsViewController: UITableViewController, UITextFieldDelegate {
    enum Section: Int {
        case bitrate
        case video
    }

    enum EditOption: Int {
        case framerate
        case keyframeInterval
    }

    let bitrateModeLabels = ["Automatic", "Fixed"]

    override func viewWillAppear(_ animated: Bool) {
        tableView.reloadData()
        super.viewWillAppear(animated)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .bitrate:
            return 4
        case .video:
            return 5
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .bitrate:
            return "VIDEO BITRATE"
        case .video:
            return "VIDEO SETTINGS"
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: UITableViewCell
        switch indexPath.section {
        case Section.bitrate.rawValue:
            if let cell = bitrateCellForRowAt(indexPath) {
                return cell
            }
        case Section.video.rawValue:
            if let cell = videoCellForRowAt(indexPath) {
                return cell
            }
        default:
            break
        }
        cell = tableView.dequeueReusableCell(withIdentifier: "OptionBasicCell", for: indexPath)
        cell.textLabel?.text = nil
        cell.isSelected = false
        cell.accessoryType = .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch indexPath.section {
        case Section.bitrate.rawValue:
            if indexPath.row < 2 {
                OptionsModel.shared.bitrateMode = BitrateMode(rawValue: indexPath.row)!
                tableView.reloadSections(IndexSet(integer: indexPath.section), with: .none)
            }
        default:
            break
        }
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if isCheckCell(indexPath) {
            if let selectedIndexPaths = tableView.indexPathsForSelectedRows {
                for selectedIndexPath in selectedIndexPaths where selectedIndexPath.section == indexPath.section {
                    tableView.deselectRow(at: selectedIndexPath, animated: false)
                }
            }
        }
        return indexPath
    }

    override func tableView(_ tableView: UITableView, willDeselectRowAt indexPath: IndexPath) -> IndexPath? {
        return isCheckCell(indexPath) ? nil : indexPath
    }

    private func bitrateCellForRowAt(_ indexPath: IndexPath) -> UITableViewCell? {
        switch indexPath.row {
        case 0, 1:
            let cell = tableView.dequeueReusableCell(withIdentifier: "OptionBasicCell", for: indexPath)
            cell.textLabel?.text = bitrateModeLabels[indexPath.row]
            cell.isSelected = indexPath.row == OptionsModel.shared.bitrateMode.rawValue
            cell.accessoryType = cell.isSelected ? .checkmark : .none
            return cell
        case 3:
            let label: String
            switch OptionsModel.shared.bitrateMode {
            case .automatic:
                label = "Maximum Bitrate"
            case .fixed:
                label = "Fixed Bitrate"
            }
            return getSelectCell(indexPath,
                                 label: label,
                                 text: OptionsUtil.getBitrateLabel(OptionsModel.shared.bitrateIndex),
                                 tag: OptionsUtil.SelectOption.bitrate.rawValue)
        default:
            return nil
        }
    }

    private func videoCellForRowAt(_ indexPath: IndexPath) -> UITableViewCell? {
        switch indexPath.row {
        case 0:
            return getEditCell(indexPath,
                               label: "Framerate",
                               text: "\(OptionsModel.shared.framerate)", kind: .framerate)
        case 1:
            return getEditCell(indexPath,
                               label: "Keyframe Interval",
                               text: "\(OptionsModel.shared.keyframeInterval)", kind: .keyframeInterval)
        case 2:
            return getSelectCell(indexPath,
                                 label: "Video Size",
                                 text: OptionsUtil.getVideoSizeLabel(OptionsModel.shared.videoSizeIndex),
                                 tag: OptionsUtil.SelectOption.videoSize.rawValue)
        case 3:
            return getSelectCell(indexPath,
                                 label: "Video Codec",
                                 text: OptionsUtil.getVideoCodecLabel(OptionsModel.shared.videoCodec.rawValue),
                                 tag: OptionsUtil.SelectOption.videoCodec.rawValue)
        case 4:
            return getSelectCell(indexPath,
                                 label: "Orientation",
                                 text: OptionsUtil.getOrientationLabel(OptionsModel.shared.orientation.rawValue),
                                 tag: OptionsUtil.SelectOption.orientation.rawValue)
        default:
            return nil
        }
    }

    private func isCheckCell(_ indexPath: IndexPath) -> Bool {
        switch indexPath.section {
        case Section.bitrate.rawValue:
            if indexPath.row < 2 {
                return true
            }
        default:
            break
        }
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if let editOption = EditOption(rawValue: textField.tag) {
            switch editOption {
            case .framerate:
                if let text = textField.text, let val = Int(text) {
                    OptionsModel.shared.framerate = val
                }
            case .keyframeInterval:
                if let text = textField.text, let val = Int(text) {
                    OptionsModel.shared.keyframeInterval = val
                }
            }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if let sender = sender as? UITableViewCell {
            if let mode = OptionsUtil.SelectOption(rawValue: sender.tag) {
                guard let nvc = segue.destination as? SelectViewController else {
                    fatalError()
                }
                nvc.mode = mode
            }
        }
    }

    private func getEditCell(_ indexPath: IndexPath, label: String, text: String, kind: EditOption) -> TextFieldCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "OptionEditCell", for: indexPath)
            as? TextFieldCell else {
            fatalError()
        }
        cell.label.text = label
        cell.textfield.keyboardType = .numbersAndPunctuation
        cell.textfield.attributedPlaceholder = NSAttributedString(
            string: "",
            attributes: [NSAttributedString.Key.foregroundColor: UIColor.darkGray])
        cell.textfield.tag = kind.rawValue
        cell.textfield.delegate = self
        cell.textfield.text = text
        return cell
    }

    private func getSelectCell(_ indexPath: IndexPath, label: String, text: String, tag: Int) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "OptionRightDetailCell", for: indexPath)
        cell.textLabel?.text = label
        cell.detailTextLabel?.text = text
        cell.tag = tag
        return cell
    }
}
