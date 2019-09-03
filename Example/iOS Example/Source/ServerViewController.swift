//
//  ServerViewController.swift
//  iOS Example
//
//  Created by Tomohiro Matsuzawa on 2018/09/08.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import UIKit

class ServerViewController: UITableViewController, UITextFieldDelegate {
    enum Mode {
        case add
        case edit
    }
    struct ItemProp {
        let name: String
        let keyboardType: UIKeyboardType
        let placeholder: String
    }
    let itemProps: [ItemProp] = [
        .init(
            name: "Description",
            keyboardType: .default,
            placeholder: "Required"
        ),
        .init(
            name: "URL",
            keyboardType: .URL,
            placeholder: "rtmp://server/live"
        ),
        .init(
            name: "Stream Name/Key",
            keyboardType: .URL,
            placeholder: "Required"
        )
    ]

    var mode: Mode = .add
    private var server: Server?

    override func viewWillAppear(_ animated: Bool) {
        switch mode {
        case .add:
            let add = UIBarButtonItem(title: "Add", style: .plain, target: self, action: #selector(add(_:)))
            navigationItem.rightBarButtonItems = [add]
            server = Server(desc: "", url: "", streamName: "")
        case .edit:
            let save = UIBarButtonItem(title: "Save", style: .plain, target: self, action: #selector(save(_:)))
            navigationItem.rightBarButtonItems = [save]
            server = ServerModel.shared.servers[ServerModel.shared.selected]
        }

    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return itemProps.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "ServerItemCell", for: indexPath)
            as? TextFieldCell else {
                fatalError()
        }

        cell.label.text = itemProps[indexPath.row].name
        cell.textfield.keyboardType = itemProps[indexPath.row].keyboardType
        cell.textfield.attributedPlaceholder = NSAttributedString(
            string: itemProps[indexPath.row].placeholder,
            attributes: [NSAttributedString.Key.foregroundColor: UIColor.darkGray])
        cell.textfield.tag = indexPath.row
        cell.textfield.delegate = self

        switch indexPath.row {
        case 0:
            cell.textfield.text = server?.desc
        case 1:
            cell.textfield.text = server?.url
        case 2:
            cell.textfield.text = server?.streamName
        default:
            break
        }

        return cell
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        switch textField.tag {
        case 0:
            server?.desc = textField.text ?? ""
        case 1:
            server?.url = textField.text ?? ""
        case 2:
            server?.streamName = textField.text ?? ""
        default:
            break
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc func add(_ button: UIButton) {
        guard let server = server else { return }
        ServerModel.shared.servers.append(server)
        _ = navigationController?.popViewController(animated: true)
    }

    @objc func save(_ button: UIButton) {
        guard let server = server else { return }
        ServerModel.shared.servers[ServerModel.shared.selected] = server
        _ = navigationController?.popViewController(animated: true)
    }
}
