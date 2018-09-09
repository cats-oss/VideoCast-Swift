//
//  BroadcastsViewController.swift
//  iOS Example
//
//  Created by Tomohiro Matsuzawa on 2018/09/06.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import UIKit

class BroadcastsViewController: UITableViewController {
    override func viewDidLoad() {
        navigationItem.title = "Broadcasts"
    }

    override func viewWillAppear(_ animated: Bool) {
        refreshNavigation()
        tableView.reloadData()
        super.viewWillAppear(animated)
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        guard let nvc = segue.destination as? ServerViewController else {
            fatalError()
        }
        nvc.mode = segue.identifier == "editServerSegue" ? .edit : .add
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return ServerModel.shared.servers.count + 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return "SERVERS"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.row < ServerModel.shared.servers.count {
            let cell = tableView.dequeueReusableCell(withIdentifier: "ServerCell", for: indexPath)
            cell.textLabel?.text = ServerModel.shared.servers[indexPath.row].desc
            cell.isSelected = indexPath.row == ServerModel.shared.selected
            cell.accessoryType = cell.isSelected ? .checkmark : .none
            return cell
        } else {
            let cell = tableView.dequeueReusableCell(withIdentifier: "NewServerCell", for: indexPath)
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if indexPath.row < ServerModel.shared.servers.count {
            return indexPath
        } else {
            performSegue(withIdentifier: "addServerSegue", sender: nil)
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        ServerModel.shared.selected = indexPath.row
        tableView.reloadData()
    }

    private func refreshNavigation() {
        if !ServerModel.shared.servers.isEmpty {
            let edit = UIBarButtonItem(title: "Edit", style: .plain, target: self, action: #selector(editServer(_:)))
            let delete = UIBarButtonItem(title: "Delete", style: .plain,
                                         target: self, action: #selector(deleteServer(_:)))
            navigationItem.rightBarButtonItems = [edit, delete]
        } else {
            navigationItem.rightBarButtonItems = []
        }
    }

    @objc func editServer(_ button: UIButton) {
        performSegue(withIdentifier: "editServerSegue", sender: nil)
    }

    @objc func deleteServer(_ button: UIButton) {
        ServerModel.shared.servers.remove(at: ServerModel.shared.selected)
        ServerModel.shared.selected = 0
        refreshNavigation()
        tableView.reloadData()
    }
}
