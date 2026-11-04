//
//  ServerListViewController.swift
//  VOFA2Remote
//
//  Screen 1: LAN discovery list plus manual endpoint entry.
//

import UIKit

final class ServerListViewController: UIViewController {

    private let discovery = DiscoveryService()
    private var offers: [ServerOffer] = []

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let headerLabel = UILabel()
    private let emptyStack = UIStackView()
    private let manualButton = UIButton(type: .system)
    private let hintLabel = UILabel()

    private var refreshItem: UIBarButtonItem?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "VOFA2 远程调参"
        view.backgroundColor = .systemGroupedBackground
        buildUI()
        wireDiscovery()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        discovery.start()
        discovery.refresh()
        updateHeader()
        autoConnectIfRequested()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        discovery.stop()
    }

    // MARK: - UI

    private func buildUI() {
        refreshItem = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"),
                                      style: .plain,
                                      target: self,
                                      action: #selector(refreshTapped))
        navigationItem.rightBarButtonItem = refreshItem

        headerLabel.font = .preferredFont(forTextStyle: .footnote)
        headerLabel.textColor = .secondaryLabel
        headerLabel.numberOfLines = 0
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ServerCell.self, forCellReuseIdentifier: ServerCell.reuseIdentifier)
        tableView.backgroundColor = .clear
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "antenna.radiowaves.left.and.right"))
        icon.tintColor = .tertiaryLabel
        icon.contentMode = .scaleAspectFit
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let emptyTitle = UILabel()
        emptyTitle.text = "未发现服务端"
        emptyTitle.font = .preferredFont(forTextStyle: .headline)
        emptyTitle.textAlignment = .center

        let emptyDetail = UILabel()
        emptyDetail.text = "确认手机与 PC 在同一 Wi-Fi，\n并在 PC 上勾选「启用远程调参服务」。\n也可以直接手动输入 IP 连接。"
        emptyDetail.font = .preferredFont(forTextStyle: .footnote)
        emptyDetail.textColor = .secondaryLabel
        emptyDetail.numberOfLines = 0
        emptyDetail.textAlignment = .center

        emptyStack.axis = .vertical
        emptyStack.spacing = 10
        emptyStack.alignment = .center
        emptyStack.addArrangedSubview(icon)
        emptyStack.addArrangedSubview(emptyTitle)
        emptyStack.addArrangedSubview(emptyDetail)
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        emptyStack.isHidden = true

        manualButton.setTitle("手动输入 IP 连接", for: .normal)
        manualButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        manualButton.setTitleColor(Theme.accent, for: .normal)
        manualButton.addTarget(self, action: #selector(manualTapped), for: .touchUpInside)
        manualButton.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .preferredFont(forTextStyle: .caption2)
        hintLabel.textColor = .tertiaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2
        hintLabel.text = "发现端口 UDP 47901 · 控制通道 WebSocket"
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerLabel)
        view.addSubview(tableView)
        view.addSubview(emptyStack)
        view.addSubview(manualButton)
        view.addSubview(hintLabel)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.horizontalInset),
            headerLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Theme.horizontalInset),

            tableView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: manualButton.topAnchor, constant: -4),

            emptyStack.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: tableView.centerYAnchor, constant: -40),
            emptyStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 32),
            emptyStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -32),

            manualButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.horizontalInset),
            manualButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Theme.horizontalInset),
            manualButton.heightAnchor.constraint(equalToConstant: 44),
            manualButton.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -2),

            hintLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.horizontalInset),
            hintLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Theme.horizontalInset),
            hintLabel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8)
        ])
    }

    private func wireDiscovery() {
        discovery.onServersChanged = { [weak self] servers in
            guard let self = self else { return }
            self.offers = servers
            self.tableView.reloadData()
            self.updateHeader()
        }
        discovery.onHint = { [weak self] hint in
            self?.hintLabel.text = hint
            self?.hintLabel.textColor = Theme.warning
        }
    }

    private func updateHeader() {
        if offers.isEmpty {
            headerLabel.text = "正在搜索局域网服务端…"
            emptyStack.isHidden = false
        } else {
            headerLabel.text = "发现 \(offers.count) 台服务端，点击即可连接"
            emptyStack.isHidden = true
        }
    }

    // MARK: - Actions

    @objc private func refreshTapped() {
        offers = []
        tableView.reloadData()
        updateHeader()
        discovery.refresh()
    }

    @objc private func manualTapped() {
        let alert = UIAlertController(title: "手动连接",
                                      message: "输入 PC 端的地址，例如 192.168.1.23:47900",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "192.168.1.23:47900"
            field.keyboardType = .numbersAndPunctuation
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "连接", style: .default) { [weak self, weak alert] _ in
            guard let self = self, let text = alert?.textFields?.first?.text else { return }
            guard let endpoint = EndpointParser.parse(text) else {
                self.presentSimpleAlert(title: "地址无效",
                                        message: "请按 192.168.1.23:47900 或 ws://192.168.1.23:47900 的格式输入。")
                return
            }
            self.openTuning(host: endpoint.host, port: endpoint.port, pin: nil,
                            name: "手动连接", requiresPin: false)
        })
        present(alert, animated: true)
    }

    private func connect(to offer: ServerOffer) {
        guard offer.requiresPin else {
            openTuning(host: offer.host, port: offer.port, pin: nil,
                       name: offer.name, requiresPin: false)
            return
        }
        promptPin(serverName: offer.name) { [weak self] pin in
            guard let pin = pin else { return }
            self?.openTuning(host: offer.host, port: offer.port, pin: pin,
                             name: offer.name, requiresPin: true)
        }
    }

    private func promptPin(serverName: String, completion: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: "输入访问码",
                                      message: "「\(serverName)」开启了访问码校验",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "访问码"
            field.keyboardType = .numberPad
            field.isSecureTextEntry = true
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(nil) })
        alert.addAction(UIAlertAction(title: "连接", style: .default) { [weak alert] _ in
            let text = alert?.textFields?.first?.text ?? ""
            completion(text.isEmpty ? nil : text)
        })
        present(alert, animated: true)
    }

    private func openTuning(host: String, port: Int, pin: String?, name: String, requiresPin: Bool) {
        let controller = TuningViewController(host: host, port: port, pin: pin,
                                              serverName: name, requiresPin: requiresPin)
        navigationController?.pushViewController(controller, animated: true)
    }

    /// UI tests and screenshots can launch with `-RemoteEndpoint 192.168.1.23:47900`.
    private func autoConnectIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-RemoteEndpoint"),
              flagIndex + 1 < arguments.count,
              let endpoint = EndpointParser.parse(arguments[flagIndex + 1]),
              presentedViewController == nil,
              (navigationController?.topViewController === self) else { return }

        var pin: String?
        if let pinIndex = arguments.firstIndex(of: "-RemotePin"), pinIndex + 1 < arguments.count {
            pin = arguments[pinIndex + 1]
        }
        openTuning(host: endpoint.host, port: endpoint.port, pin: pin,
                   name: "手动连接", requiresPin: pin != nil)
    }

    private func presentSimpleAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Table

extension ServerListViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        offers.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ServerCell.reuseIdentifier, for: indexPath)
        (cell as? ServerCell)?.configure(with: offers[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        connect(to: offers[indexPath.row])
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        offers.isEmpty ? nil : "局域网服务端"
    }
}

// MARK: - Cell

private final class ServerCell: UITableViewCell {

    static let reuseIdentifier = "ServerCell"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        selectionStyle = .default
        textLabel?.font = .preferredFont(forTextStyle: .body)
        detailTextLabel?.font = .preferredFont(forTextStyle: .footnote)
        detailTextLabel?.textColor = .secondaryLabel
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with offer: ServerOffer) {
        textLabel?.text = offer.name
        var detail = offer.endpointText
        if offer.requiresPin {
            detail += "  ·  🔒 需要访问码"
        } else {
            detail += "  ·  开放"
        }
        detailTextLabel?.text = detail
    }
}

// MARK: - Endpoint parsing

struct Endpoint {
    let host: String
    let port: Int
}

enum EndpointParser {
    /// Accepts `192.168.1.23:47900`, `ws://192.168.1.23:47900/`, `192.168.1.23`.
    static func parse(_ raw: String) -> Endpoint? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("ws://") { text.removeFirst(5) }
        if text.hasPrefix("wss://") { text.removeFirst(6) }
        while text.hasSuffix("/") { text.removeLast() }

        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(parts[0])
        guard !host.isEmpty else { return nil }

        var port = 47900
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), parsed > 0, parsed <= 65535 else { return nil }
            port = parsed
        }
        return Endpoint(host: host, port: port)
    }
}
