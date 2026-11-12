//
//  TuningViewController.swift
//  VOFA2Remote
//
//  Screen 2: live tuning panel mirrored from the PC command list.
//

import UIKit

final class TuningViewController: UIViewController {

    // MARK: - Connection configuration

    private let host: String
    private let port: Int
    private var pin: String?
    private let initialServerName: String
    private let requiresPin: Bool
    private let client: RemoteClient

    // MARK: - Model

    private var snapshot: RemoteSnapshot?
    private var currentGroup: String = ""
    private var linkState: LinkState = .idle
    private var onlineClients = 0
    private var dragControlID: Int?
    private var isSendingOneClick = false
    private var hintResetWork: DispatchWorkItem?
    private weak var linkSheet: LinkSheetViewController?

    /// The "一键发送数据" panel, kept so progress can be pushed into it.
    private weak var oneClickSheet: OneClickSheetViewController?
    /// Flipped to false when the PC answers `bad_request` for `{"t":"inc"}`.
    private var inclusionWritesSupported = true
    /// Local fallback send used when the selection differs from the PC plan.
    private var localTimer: DispatchSourceTimer?
    private var localPlan: [ControlItem] = []
    private var localTotal = 0
    private var localSent = 0

    private enum Section {
        case actions
        case controls
    }
    private var sections: [Section] = []

    // MARK: - Views

    private let statusCard = UIView()
    private let statusDot = UIView()
    private let linkLabel = UILabel()
    private let clientsLabel = UILabel()
    private let serverLabel = UILabel()
    private let connLabel = UILabel()
    private let peerLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let retryRow = UIStackView()

    private let groupScroll = UIScrollView()
    private let groupStack = UIStackView()
    private var chips: [UIButton] = []

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyLabel = UILabel()

    private let oneClickButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let progressLabel = UILabel()

    // MARK: - Init

    init(host: String, port: Int, pin: String?, serverName: String, requiresPin: Bool) {
        self.host = host
        self.port = port
        self.pin = pin
        self.initialServerName = serverName
        self.requiresPin = requiresPin
        self.client = RemoteClient(host: host,
                                   port: port,
                                   pin: pin,
                                   displayName: UIDevice.current.name,
                                   clientId: TuningViewController.stableClientId())
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Stable per-install identifier used by the server for de-duplication.
    private static func stableClientId() -> String {
        let key = "vofa.remote.clientId"
        if let stored = UserDefaults.standard.string(forKey: key) { return stored }
        let generated = "ios-" + UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = initialServerName
        view.backgroundColor = .systemGroupedBackground
        buildUI()
        bindClient()
        registerNotifications()
        updateStatusUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        if case .idle = linkState {
            client.connect()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            stopLocalTimer()
            UIApplication.shared.isIdleTimerDisabled = false
            client.disconnect()
        }
    }

    // MARK: - UI

    private func buildUI() {
        let linkItem = UIBarButtonItem(image: UIImage(systemName: "link"), style: .plain,
                                       target: self, action: #selector(linkTapped))
        linkItem.accessibilityLabel = "连接"
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "xmark.circle"), style: .plain,
                            target: self, action: #selector(closeTapped)),
            UIBarButtonItem(image: UIImage(systemName: "arrow.triangle.2.circlepath"), style: .plain,
                            target: self, action: #selector(syncTapped)),
            linkItem
        ]

        // --- status card -------------------------------------------------
        statusCard.backgroundColor = .secondarySystemGroupedBackground
        statusCard.layer.cornerRadius = Theme.cardCorner
        statusCard.translatesAutoresizingMaskIntoConstraints = false

        statusDot.layer.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        linkLabel.font = .preferredFont(forTextStyle: .subheadline)
        linkLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        clientsLabel.font = .preferredFont(forTextStyle: .caption1)
        clientsLabel.textColor = .secondaryLabel
        clientsLabel.textAlignment = .right

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let topRow = UIStackView(arrangedSubviews: [statusDot, linkLabel, spacer, clientsLabel])
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 6

        serverLabel.font = .preferredFont(forTextStyle: .caption1)
        serverLabel.textColor = .secondaryLabel
        serverLabel.numberOfLines = 1

        connLabel.font = .preferredFont(forTextStyle: .caption1)
        connLabel.textColor = Theme.warning
        connLabel.numberOfLines = 0
        connLabel.isHidden = true

        peerLabel.font = .preferredFont(forTextStyle: .caption1)
        peerLabel.textColor = .tertiaryLabel
        peerLabel.numberOfLines = 0
        peerLabel.isHidden = true

        retryButton.setTitle("重新连接", for: .normal)
        retryButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        retryButton.setTitleColor(.white, for: .normal)
        retryButton.backgroundColor = Theme.accent
        retryButton.layer.cornerRadius = 8
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        retryButton.setContentHuggingPriority(.required, for: .horizontal)

        retryRow.axis = .horizontal
        retryRow.addArrangedSubview(retryButton)
        retryRow.addArrangedSubview(UIView())
        retryRow.isHidden = true

        let cardStack = UIStackView(arrangedSubviews: [topRow, serverLabel, connLabel, peerLabel, retryRow])
        cardStack.axis = .vertical
        cardStack.spacing = 4
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        statusCard.addSubview(cardStack)

        // --- group chips -------------------------------------------------
        groupScroll.showsHorizontalScrollIndicator = false
        groupScroll.translatesAutoresizingMaskIntoConstraints = false
        groupScroll.contentInset = UIEdgeInsets(top: 0, left: Theme.horizontalInset,
                                                bottom: 0, right: Theme.horizontalInset)

        groupStack.axis = .horizontal
        groupStack.spacing = 8
        groupStack.alignment = .center
        groupStack.translatesAutoresizingMaskIntoConstraints = false
        groupScroll.addSubview(groupStack)

        // --- table -------------------------------------------------------
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.keyboardDismissMode = .interactive
        tableView.estimatedRowHeight = 84
        tableView.rowHeight = UITableView.automaticDimension
        tableView.tableFooterView = UIView()
        tableView.register(SwitchCell.self, forCellReuseIdentifier: SwitchCell.reuseIdentifier)
        tableView.register(CommandButtonCell.self, forCellReuseIdentifier: CommandButtonCell.reuseIdentifier)
        tableView.register(ControlCell.self, forCellReuseIdentifier: ControlCell.reuseIdentifier)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.text = "该命令组暂无控件"
        emptyLabel.font = .preferredFont(forTextStyle: .footnote)
        emptyLabel.textColor = .tertiaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        // --- bottom bar --------------------------------------------------
        oneClickButton.setTitle("一键发送数据", for: .normal)
        oneClickButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        oneClickButton.setTitleColor(.white, for: .normal)
        oneClickButton.backgroundColor = Theme.accent
        oneClickButton.layer.cornerRadius = 10
        oneClickButton.addTarget(self, action: #selector(oneClickTapped), for: .touchUpInside)
        oneClickButton.heightAnchor.constraint(equalToConstant: 46).isActive = true

        cancelButton.setTitle("取消", for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cancelButton.setTitleColor(Theme.danger, for: .normal)
        cancelButton.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        cancelButton.addTarget(self, action: #selector(cancelOneClickTapped), for: .touchUpInside)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.isHidden = true

        progressView.progressTintColor = Theme.accent
        progressView.trackTintColor = .tertiarySystemFill
        progressView.isHidden = true

        progressLabel.font = .preferredFont(forTextStyle: .caption1)
        progressLabel.textColor = .secondaryLabel
        progressLabel.numberOfLines = 1
        progressLabel.isHidden = true

        let progressRow = UIStackView(arrangedSubviews: [progressView, progressLabel, cancelButton])
        progressRow.axis = .horizontal
        progressRow.alignment = .center
        progressRow.spacing = 8
        progressView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bottomStack = UIStackView(arrangedSubviews: [progressRow, oneClickButton])
        bottomStack.axis = .vertical
        bottomStack.spacing = 8
        bottomStack.translatesAutoresizingMaskIntoConstraints = false

        // Accessibility identifiers double as UI test hooks.
        linkLabel.accessibilityIdentifier = "status.link"
        clientsLabel.accessibilityIdentifier = "status.clients"
        connLabel.accessibilityIdentifier = "status.conn"
        peerLabel.accessibilityIdentifier = "status.hint"
        retryButton.accessibilityIdentifier = "status.retry"
        groupScroll.accessibilityIdentifier = "group.scroll"
        tableView.accessibilityIdentifier = "tuning.table"
        oneClickButton.accessibilityIdentifier = "oneclick.button"
        cancelButton.accessibilityIdentifier = "oneclick.cancel"
        progressLabel.accessibilityIdentifier = "oneclick.status"
        progressView.accessibilityIdentifier = "oneclick.progress"
        emptyLabel.accessibilityIdentifier = "tuning.empty"

        view.addSubview(statusCard)
        view.addSubview(groupScroll)
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        view.addSubview(bottomStack)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            statusCard.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            statusCard.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.horizontalInset),
            statusCard.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Theme.horizontalInset),

            cardStack.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 10),
            cardStack.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 12),
            cardStack.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -12),
            cardStack.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -10),

            groupScroll.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 8),
            groupScroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            groupScroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            groupScroll.heightAnchor.constraint(equalToConstant: 34),

            groupStack.leadingAnchor.constraint(equalTo: groupScroll.contentLayoutGuide.leadingAnchor),
            groupStack.trailingAnchor.constraint(equalTo: groupScroll.contentLayoutGuide.trailingAnchor),
            groupStack.topAnchor.constraint(equalTo: groupScroll.contentLayoutGuide.topAnchor),
            groupStack.bottomAnchor.constraint(equalTo: groupScroll.contentLayoutGuide.bottomAnchor),
            groupStack.heightAnchor.constraint(equalTo: groupScroll.frameLayoutGuide.heightAnchor),

            tableView.topAnchor.constraint(equalTo: groupScroll.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -32),

            bottomStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.horizontalInset),
            bottomStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Theme.horizontalInset),
            bottomStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8)
        ])
    }

    // MARK: - Client wiring

    private func bindClient() {
        client.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: RemoteEvent) {
        switch event {
        case .stateChanged(let state):
            linkState = state
            if state.isConnected { retryRow.isHidden = true }
            if case .closed(let reason, let canRetry) = state {
                retryRow.isHidden = !canRetry
                showPeerHint(reason, persistent: true)
            }
            updateStatusUI()

        case .welcome(let info):
            if !info.serverName.isEmpty {
                title = info.serverName
            }
            updateStatusUI()

        case .snapshot(let snapshot):
            applySnapshot(snapshot)

        case .value(let id, let value, let from):
            applyValue(id: id, value: value, from: from)

        case .action(let id, let kind, let on, let from, let flash):
            applyAction(id: id, kind: kind, on: on, from: from, flash: flash)

        case .oneClick(let update):
            applyOneClick(update)

        case .conn(let conn):
            applyConn(conn)

        case .pcLink(let link):
            applyPCLink(link)

        case .clients(let count):
            onlineClients = count
            clientsLabel.text = count > 0 ? "在线 \(count) 台" : ""

        case .serverError(let code, let message):
            handleServerError(code: code, message: message)

        case .terminated(let code, let reason):
            handleTermination(code: code, reason: reason)
        }
    }

    private func applySnapshot(_ snapshot: RemoteSnapshot) {
        self.snapshot = snapshot

        if !snapshot.serverName.isEmpty {
            title = snapshot.serverName
        }
        serverLabel.text = "\(title ?? initialServerName) · \(host):\(port)"

        if !snapshot.groups.contains(currentGroup) {
            if snapshot.groups.contains(snapshot.pcGroup) {
                currentGroup = snapshot.pcGroup
            } else {
                currentGroup = snapshot.groups.first ?? ""
            }
        }

        rebuildGroupChips()
        reloadSections()
        updateStatusUI()
        updateOneClickUI(snapshot.oneClick)
        oneClickSheet?.setPCConnected(snapshot.conn.isConnected)
        linkSheet?.applyState(snapshot.link)
        if let sheet = oneClickSheet, let group = currentGroupIfAvailable {
            let map = Dictionary(uniqueKeysWithValues: snapshot
                .controls(inGroup: group)
                .map { ($0.id, $0.includedInOneClick) })
            sheet.applyPCState(map)
        }
    }

    private func applyValue(id: Int, value: Double, from: String?) {
        guard var snapshot = snapshot else { return }
        guard let index = snapshot.controls.firstIndex(where: { $0.id == id }) else { return }
        snapshot.controls[index].value = value
        self.snapshot = snapshot

        if let path = indexPath(forControl: id), let cell = tableView.cellForRow(at: path) as? ControlCell {
            cell.applyEcho(value)
        }
        if let from = from, from != "pc" {
            if let control = snapshot.control(id: id) {
                showPeerHint("另一台手机正在调整 \(control.label)")
            }
        } else {
            if let control = snapshot.control(id: id) {
                showPeerHint("PC 正在调整 \(control.label)")
            }
        }
    }

    private func applyAction(id: Int, kind: ActionItem.Kind, on: Bool, from: String?, flash: Bool) {
        guard var snapshot = snapshot else { return }
        if let index = snapshot.actions.firstIndex(where: { $0.id == id }) {
            snapshot.actions[index].isOn = on
            self.snapshot = snapshot
            if kind == .toggle, let path = indexPath(forAction: id),
               let cell = tableView.cellForRow(at: path) as? SwitchCell {
                cell.setOn(on)
            }
            if flash, let path = indexPath(forAction: id),
               let cell = tableView.cellForRow(at: path) as? CommandButtonCell {
                cell.flash()
            }
        }
    }

    private func applyOneClick(_ update: OneClickUpdate) {
        if let snapshot = snapshot {
            var copy = snapshot
            copy.oneClick.sent = update.sent
            copy.oneClick.total = update.total
            copy.oneClick.status = update.status
            copy.oneClick.isSending = !update.phase.isTerminal
            self.snapshot = copy
        }

        switch update.phase {
        case .start, .step:
            setSending(true)
            progressView.progress = update.total > 0 ? Float(update.sent) / Float(update.total) : 0
            progressLabel.text = update.status.isEmpty
                ? "\(update.sent)/\(update.total)"
                : update.status
        case .done:
            setSending(false)
            progressView.progress = 1
            progressLabel.text = update.status.isEmpty ? "发送完成" : update.status
            scheduleProgressHide()
        case .cancel:
            setSending(false)
            progressLabel.text = update.status.isEmpty ? "已取消" : update.status
            scheduleProgressHide()
        case .idle:
            setSending(false)
            progressLabel.text = update.status.isEmpty ? "没有可发送的滑块" : update.status
            scheduleProgressHide()
        }

        oneClickSheet?.updateProgress(sent: update.sent,
                                      total: update.total,
                                      status: update.status,
                                      sending: !update.phase.isTerminal)
    }

    /// PC 连接面板状态：更新模型并同步给已打开的面板。
    private func applyPCLink(_ link: PCLinkState) {
        if var snapshot = snapshot {
            snapshot.link = link
            self.snapshot = snapshot
        }
        linkSheet?.applyState(link)
    }

    private func applyConn(_ conn: ConnState) {
        if var snapshot = snapshot {
            snapshot.conn = conn
            self.snapshot = snapshot
        }
        connLabel.isHidden = conn.isConnected
        connLabel.text = conn.isConnected
            ? nil
            : "PC 未连接板子（\(conn.text.isEmpty ? "离线" : conn.text)）· 操作会被记录但发不出去"

        oneClickSheet?.setPCConnected(conn.isConnected)
        if !conn.isConnected, localTimer != nil {
            failOneClick(message: "已中断：连接已断开")
        }
    }

    private func handleServerError(code: String, message: String) {
        switch code {
        case "bad_pin":
            // The close frame (4003) drives the PIN prompt; ignore the duplicate error.
            break
        case "busy":
            setSending(false)
            progressLabel.text = "另一台设备正在发送"
            showPeerHint("另一台设备正在一键发送")
            scheduleProgressHide()
        case "empty_plan":
            setSending(false)
            progressLabel.text = "该组没有勾选「一键发送」的滑块"
            showPeerHint("该命令组没有可发送的滑块")
            scheduleProgressHide()
        case "not_connected":
            // PC 端没有串口/TCP 对端：一键发送一步都不会走，服务端已同时广播
            // phase=idle 解锁按钮，这里把原因显示出来。
            failOneClick(message: message.isEmpty ? "PC 未连接设备，先连接再发送" : message)
        case "link_busy":
            linkSheet?.showError("PC 已经连接，先断开再切换")
            showPeerHint("PC 已连接，先断开")
        case "no_port":
            linkSheet?.showError("PC 上没有可用串口，先刷新端口列表")
            showPeerHint("没有可用串口")
        case "bad_link":
            linkSheet?.showError("连接参数不合法，检查端口/主机")
            showPeerHint("连接参数不合法")
        case "bad_value":
            showPeerHint("数值不合法，已回退")
        case "bad_request":
            if message.contains("inc") || message.contains("未知消息类型") {
                // 旧版服务端不认识 {"t":"inc"}：退化成「只对本次发送生效」。
                inclusionWritesSupported = false
                oneClickSheet?.setInclusionSupported(false)
                showPeerHint("这台 PC 不支持写回勾选，选择只在本次生效")
            } else if !message.isEmpty {
                showPeerHint(message)
            }
        case "unknown_control", "unknown_group":
            showPeerHint("控件已被 PC 修改，正在刷新")
        case "unsupported":
            break
        default:
            if !message.isEmpty { showPeerHint(message) }
        }
    }

    private func handleTermination(code: Int, reason: String) {
        if code == 4001 {
            let alert = UIAlertController(title: "连接已断开", message: reason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "返回", style: .default) { [weak self] _ in
                self?.navigationController?.popViewController(animated: true)
            })
            present(alert, animated: true)
        } else if code == 4003 {
            promptForPin(reason: reason)
        }
    }

    // MARK: - Groups

    private func rebuildGroupChips() {
        groupStack.arrangedSubviews.forEach {
            groupStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        chips.removeAll()

        for (index, group) in (snapshot?.groups ?? []).enumerated() {
            let chip = UIButton(type: .system)
            chip.setTitle(group, for: .normal)
            chip.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
            chip.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
            chip.layer.cornerRadius = 15
            chip.clipsToBounds = true
            chip.tag = index
            chip.accessibilityIdentifier = "group.chip.\(group)"
            chip.accessibilityLabel = group
            chip.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
            groupStack.addArrangedSubview(chip)
            chips.append(chip)
        }
        updateChipSelection(scroll: true)
    }

    private func updateChipSelection(scroll: Bool) {
        let groups = snapshot?.groups ?? []
        for (index, chip) in chips.enumerated() {
            let selected = index < groups.count && groups[index] == currentGroup
            chip.backgroundColor = selected ? Theme.accent : .secondarySystemGroupedBackground
            chip.setTitleColor(selected ? .white : .label, for: .normal)
        }
        guard scroll, let index = groups.firstIndex(of: currentGroup), index < chips.count else { return }
        let chip = chips[index]
        let target = chip.convert(chip.bounds, to: groupScroll)
        groupScroll.scrollRectToVisible(target.insetBy(dx: -24, dy: 0), animated: true)
    }

    @objc private func chipTapped(_ sender: UIButton) {
        let groups = snapshot?.groups ?? []
        guard sender.tag < groups.count else { return }
        currentGroup = groups[sender.tag]
        updateChipSelection(scroll: true)
        reloadSections()
    }

    private func reloadSections() {
        guard let snapshot = snapshot else {
            sections = []
            tableView.reloadData()
            emptyLabel.isHidden = true
            return
        }
        let actions = snapshot.actions(inGroup: currentGroup)
        let controls = snapshot.controls(inGroup: currentGroup)

        var newSections: [Section] = []
        if !actions.isEmpty { newSections.append(.actions) }
        if !controls.isEmpty { newSections.append(.controls) }
        sections = newSections

        tableView.reloadData()
        emptyLabel.isHidden = !sections.isEmpty
    }

    private func indexPath(forControl id: Int) -> IndexPath? {
        guard let snapshot = snapshot, let section = sections.firstIndex(of: .controls) else { return nil }
        let list = snapshot.controls(inGroup: currentGroup)
        guard let row = list.firstIndex(where: { $0.id == id }) else { return nil }
        return IndexPath(row: row, section: section)
    }

    private func indexPath(forAction id: Int) -> IndexPath? {
        guard let snapshot = snapshot, let section = sections.firstIndex(of: .actions) else { return nil }
        let list = snapshot.actions(inGroup: currentGroup)
        guard let row = list.firstIndex(where: { $0.id == id }) else { return nil }
        return IndexPath(row: row, section: section)
    }

    // MARK: - Status

    private func updateStatusUI() {
        switch linkState {
        case .idle:
            statusDot.backgroundColor = .tertiaryLabel
            linkLabel.text = "未连接"
            linkLabel.textColor = .secondaryLabel
        case .connecting:
            statusDot.backgroundColor = Theme.warning
            linkLabel.text = "连接中…"
            linkLabel.textColor = .label
        case .connected:
            statusDot.backgroundColor = Theme.success
            linkLabel.text = "已连接"
            linkLabel.textColor = .label
        case .reconnecting(let attempt, let delay):
            statusDot.backgroundColor = Theme.warning
            linkLabel.text = "重连中 第 \(attempt) 次 · \(Int(delay))s"
            linkLabel.textColor = .label
        case .closed(let reason, _):
            statusDot.backgroundColor = Theme.danger
            linkLabel.text = reason
            linkLabel.textColor = Theme.danger
        }

        serverLabel.text = "\(title ?? initialServerName) · \(host):\(port)"
        clientsLabel.text = linkState.isConnected && onlineClients > 0 ? "在线 \(onlineClients) 台" : ""

        if let conn = snapshot?.conn {
            connLabel.isHidden = conn.isConnected
            if !conn.isConnected {
                connLabel.text = "PC 未连接板子（\(conn.text.isEmpty ? "离线" : conn.text)）· 操作会被记录但发不出去"
            }
        }

        let editable = linkState.isConnected
        tableView.visibleCells.forEach { cell in
            (cell as? ControlCell)?.setEditingEnabled(editable)
        }
        oneClickButton.isEnabled = linkState.isConnected && !isSendingOneClick
        oneClickButton.alpha = oneClickButton.isEnabled ? 1 : 0.4
        updateOneClickButtonTitle()
    }

    private func showPeerHint(_ text: String, persistent: Bool = false) {
        peerLabel.text = text
        peerLabel.isHidden = false
        hintResetWork?.cancel()
        guard !persistent else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.peerLabel.isHidden = true
        }
        hintResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: - One-click

    private func setSending(_ sending: Bool) {
        isSendingOneClick = sending
        if sending {
            progressView.isHidden = false
            progressLabel.isHidden = false
            cancelButton.isHidden = false
            progressView.progress = 0
            progressLabel.text = "准备发送…"
        } else {
            // Keep the final status text on screen; `scheduleProgressHide` clears it.
            progressView.isHidden = true
            cancelButton.isHidden = true
        }
        oneClickButton.isEnabled = !sending && linkState.isConnected
        oneClickButton.alpha = oneClickButton.isEnabled ? 1 : 0.4
        updateOneClickButtonTitle()
    }

    private func updateOneClickButtonTitle() {
        if isSendingOneClick {
            oneClickButton.setTitle("正在一键发送…", for: .normal)
        } else if case .closed = linkState {
            oneClickButton.setTitle("连接已断开", for: .normal)
        } else {
            oneClickButton.setTitle("一键发送数据", for: .normal)
        }
    }

    private func hideProgress() {
        progressView.isHidden = true
        progressLabel.isHidden = true
        cancelButton.isHidden = true
    }

    private func updateOneClickUI(_ state: OneClickState) {
        guard !isSendingOneClick else { return }
        if state.isSending {
            setSending(true)
            progressView.progress = Float(state.fraction)
            progressLabel.text = state.status
        }
    }

    private func scheduleProgressHide() {
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isSendingOneClick else { return }
            self.hideProgress()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Opens the PC-style "一键发送数据" panel: pick the sliders, then send.
    @objc private func oneClickTapped() {
        guard let group = currentGroupIfAvailable, let snapshot = snapshot else {
            showPeerHint("请先选择一个命令组")
            return
        }
        let controls = snapshot.controls(inGroup: group)
        guard !controls.isEmpty else {
            showPeerHint("该命令组没有可发送的滑块")
            return
        }

        let rows = controls.map { control in
            OneClickSheetViewController.Row(id: control.id,
                                            label: control.label,
                                            valueText: control.formatted(control.value),
                                            pcIncluded: control.includedInOneClick)
        }
        let sheet = OneClickSheetViewController(groupName: group,
                                                rows: rows,
                                                intervalMs: snapshot.oneClick.intervalMs,
                                                pcConnected: snapshot.conn.isConnected)
        sheet.onSend = { [weak self] ids, intervalMs in
            self?.startOneClick(ids: ids, intervalMs: intervalMs)
        }
        sheet.onStop = { [weak self] in
            self?.stopOneClick()
        }
        sheet.onToggleInclusion = { [weak self] id, included in
            self?.client.setIncluded(id: id, included: included)
        }
        sheet.setInclusionSupported(inclusionWritesSupported)
        sheet.onClose = { [weak self] in
            self?.oneClickSheet = nil
        }
        oneClickSheet = sheet
        present(sheet, animated: true)
    }

    /// Uses the server's one-click when the selection matches the PC plan, and a
    /// local sequenced send otherwise: the protocol has no way to change `inc`.
    private func startOneClick(ids: [Int], intervalMs: Int) {
        guard let group = currentGroupIfAvailable, let snapshot = snapshot else { return }
        let controls = snapshot.controls(inGroup: group)
        let pcPlan = controls.filter { $0.includedInOneClick }.map { $0.id }
        let chosen = controls.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return }

        if chosen.map({ $0.id }) == pcPlan {
            // The server refuses on its own (and broadcasts phase=idle + the
            // `not_connected` error) when it has no board or TCP peer.
            setSending(true)
            client.startOneClick(group: group, intervalMs: intervalMs)
        } else {
            // A local plan never reaches the server's one-click guard, so check
            // the link ourselves: commits would be dropped on the PC side.
            guard snapshot.conn.isConnected else {
                failOneClick(message: "PC 未连接设备，先连接再发送")
                return
            }
            runLocalOneClick(chosen, intervalMs: intervalMs)
        }
    }

    /// Stops whatever is running and reports why, unlocking both UIs.
    private func failOneClick(message: String) {
        stopLocalTimer()
        setSending(false)
        progressView.progress = 0
        progressLabel.isHidden = false
        progressLabel.text = message
        oneClickSheet?.updateProgress(sent: 0, total: 0, status: message, sending: false)
        showPeerHint(message)
        scheduleProgressHide()
    }

    private func runLocalOneClick(_ items: [ControlItem], intervalMs: Int) {
        stopLocalTimer()
        localPlan = items
        localTotal = items.count
        localSent = 0

        setSending(true)
        let status = "开始发送（自定义选择 \(localTotal) 项）"
        progressLabel.text = status
        progressView.progress = 0
        oneClickSheet?.updateProgress(sent: 0, total: localTotal, status: status, sending: true)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(max(10, min(5000, intervalMs))))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard !self.localPlan.isEmpty else {
                self.finishLocalOneClick()
                return
            }
            let control = self.localPlan.removeFirst()
            // A commit is exactly what releasing the slider sends; the PC clamps it
            // and forwards the same bytes it would for its own one-click send.
            self.client.commit(id: control.id, value: control.value, exact: false)
            self.localSent += 1
            let text = "已发送 \(self.localSent)/\(self.localTotal): \(control.label)"
            self.progressLabel.text = text
            if self.localTotal > 0 {
                self.progressView.progress = Float(self.localSent) / Float(self.localTotal)
            }
            self.oneClickSheet?.updateProgress(sent: self.localSent,
                                               total: self.localTotal,
                                               status: text,
                                               sending: true)
        }
        localTimer = timer
        timer.resume()
    }

    private func finishLocalOneClick() {
        let total = localTotal
        let sent = localSent
        stopLocalTimer()
        setSending(false)
        let status = sent >= total ? "完成 \(total) 项" : "已发送 \(sent)/\(total)"
        progressLabel.text = status
        progressView.progress = 1
        oneClickSheet?.updateProgress(sent: sent, total: total, status: status, sending: false)
        scheduleProgressHide()
    }

    private func stopOneClick() {
        if localTimer != nil {
            let sent = localSent
            let total = localTotal
            stopLocalTimer()
            setSending(false)
            let status = "已取消（已发送 \(sent)/\(total)）"
            progressLabel.text = status
            oneClickSheet?.updateProgress(sent: sent, total: total, status: status, sending: false)
            scheduleProgressHide()
        } else {
            client.stopOneClick()
        }
    }

    private func stopLocalTimer() {
        localTimer?.cancel()
        localTimer = nil
    }

    @objc private func cancelOneClickTapped() {
        stopOneClick()
        progressLabel.text = localTimer == nil ? "已请求取消…" : progressLabel.text
    }

    private var currentGroupIfAvailable: String? {
        guard let groups = snapshot?.groups, groups.contains(currentGroup) else { return nil }
        return currentGroup
    }

    // MARK: - Actions

    @objc private func syncTapped() {
        client.requestSync()
        showPeerHint("已请求同步")
    }

    /// 打开「PC 连接」面板：手机直接开关 PC 的串口 / TCP / UDP / 演示。
    @objc private func linkTapped() {
        let sheet = LinkSheetViewController(state: snapshot?.link ?? .unknown)
        sheet.onOpen = { [weak self] request in
            self?.client.openLink(kind: request.kind,
                                  port: request.port,
                                  baud: request.baud,
                                  host: request.host,
                                  tcpPort: request.tcpPort,
                                  remotePort: request.remotePort,
                                  localPort: request.localPort)
        }
        sheet.onDisconnect = { [weak self] in
            self?.client.closeLink()
        }
        sheet.onRefreshPorts = { [weak self] in
            self?.client.refreshPorts()
        }
        sheet.onClose = { [weak self] in
            self?.linkSheet = nil
        }
        linkSheet = sheet
        present(sheet, animated: true)
    }

    @objc private func closeTapped() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func retryTapped() {
        retryRow.isHidden = true
        client.retry()
    }

    private func promptForPin(reason: String) {
        let alert = UIAlertController(title: "需要访问码", message: reason, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "访问码"
            field.keyboardType = .numberPad
            field.isSecureTextEntry = true
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        alert.addAction(UIAlertAction(title: "重连", style: .default) { [weak self, weak alert] _ in
            guard let self = self else { return }
            let text = alert?.textFields?.first?.text ?? ""
            guard !text.isEmpty else { return }
            self.pin = text
            self.client.connect(withPin: text)
        })
        present(alert, animated: true)
    }

    // MARK: - Notifications

    private func registerNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)
    }

    @objc private func didBecomeActive() {
        switch linkState {
        case .closed(_, let canRetry):
            if canRetry { client.retry() }
        case .connected:
            // Coming back from the background the socket may be stale; pull a fresh
            // snapshot while the watchdog checks whether the link is still alive.
            client.requestSync()
        default:
            break
        }
    }

    @objc private func keyboardChanged(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let converted = view.convert(frame, from: nil)
        let overlap = max(0, view.bounds.maxY - converted.minY)
        tableView.contentInset.bottom = overlap > 0 ? overlap + 8 : 0
        tableView.verticalScrollIndicatorInsets.bottom = tableView.contentInset.bottom
    }
}

// MARK: - Table

extension TuningViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let snapshot = snapshot else { return 0 }
        switch sections[section] {
        case .actions: return snapshot.actions(inGroup: currentGroup).count
        case .controls: return snapshot.controls(inGroup: currentGroup).count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let snapshot = snapshot else { return nil }
        switch sections[section] {
        case .actions:
            return "命令 · \(snapshot.actions(inGroup: currentGroup).count)"
        case .controls:
            return "参数 · \(snapshot.controls(inGroup: currentGroup).count)"
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let snapshot = snapshot else { return UITableViewCell() }

        switch sections[indexPath.section] {
        case .actions:
            let action = snapshot.actions(inGroup: currentGroup)[indexPath.row]
            if action.kind == .toggle {
                let cell = tableView.dequeueReusableCell(withIdentifier: SwitchCell.reuseIdentifier,
                                                         for: indexPath) as! SwitchCell
                cell.configure(label: action.label, isOn: action.isOn) { [weak self] isOn in
                    self?.switchChanged(id: action.id, isOn: isOn)
                }
                return cell
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: CommandButtonCell.reuseIdentifier,
                                                     for: indexPath) as! CommandButtonCell
            cell.configure(label: action.label) { [weak self] in
                self?.client.triggerButton(id: action.id)
            }
            return cell

        case .controls:
            let control = snapshot.controls(inGroup: currentGroup)[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: ControlCell.reuseIdentifier,
                                                     for: indexPath) as! ControlCell
            cell.configure(with: control,
                           onDrag: { [weak self] value in
                               guard let self = self else { return }
                               self.dragControlID = control.id
                               self.client.sendValue(id: control.id, value: value)
                               self.updateLocalValue(id: control.id, value: value)
                           },
                           onCommit: { [weak self] value in
                               guard let self = self else { return }
                               self.dragControlID = nil
                               self.client.commit(id: control.id, value: value, exact: false)
                               self.updateLocalValue(id: control.id, value: value)
                           },
                           onExactCommit: { [weak self] value in
                               guard let self = self else { return }
                               self.dragControlID = nil
                               self.client.commit(id: control.id, value: value, exact: true)
                               self.updateLocalValue(id: control.id, value: value)
                           })
            cell.setEditingEnabled(linkState.isConnected)
            return cell
        }
    }

    private func switchChanged(id: Int, isOn: Bool) {
        // Optimistic local update; the broadcast echo stays authoritative.
        if var snapshot = snapshot, let index = snapshot.actions.firstIndex(where: { $0.id == id }) {
            snapshot.actions[index].isOn = isOn
            self.snapshot = snapshot
        }
        client.setSwitch(id: id, on: isOn)
    }

    private func updateLocalValue(id: Int, value: Double) {
        guard var snapshot = snapshot,
              let index = snapshot.controls.firstIndex(where: { $0.id == id }) else { return }
        snapshot.controls[index].value = value
        self.snapshot = snapshot
    }
}
