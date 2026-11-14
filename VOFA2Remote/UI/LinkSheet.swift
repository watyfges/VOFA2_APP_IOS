//
//  LinkSheet.swift
//  VOFA2Remote
//
//  「连接」面板：手机直接开关 PC 的串口 / TCP / UDP / 演示连接。
//  结果一律以服务端推回的 link 状态为准，不本地猜测。
//

import UIKit

/// 一次打开请求的参数，按 kind 取用。
struct LinkRequest {
    var kind: Int
    var port: String = ""
    var baud: Int = 115200
    var host: String = ""
    var tcpPort: Int = 0
    var remotePort: Int = 0
    var localPort: Int = 0
}

final class LinkSheetViewController: UIViewController {

    var onOpen: ((LinkRequest) -> Void)?
    var onClose: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onRefreshPorts: (() -> Void)?

    private var state: PCLinkState
    private var userPickedKind = false

    private let statusLabel = UILabel()
    private let kindScroll = UIScrollView()
    private let kindStack = UIStackView()
    private var kindButtons: [UIButton] = []
    private var selectedKind = 0
    private let portButton = UIButton(type: .system)
    private let baudField = InsetTextField()
    private let hostField = InsetTextField()
    private let tcpPortField = InsetTextField()
    private let listenPortField = InsetTextField()
    private let remoteHostField = InsetTextField()
    private let remotePortField = InsetTextField()
    private let localPortField = InsetTextField()
    private let refreshButton = UIButton(type: .system)
    private let actionButton = UIButton(type: .system)
    private let hintLabel = UILabel()

    private var serialBox: UIStackView!
    private var clientBox: UIStackView!
    private var serverBox: UIStackView!
    private var udpBox: UIStackView!
    private var demoBox: UIStackView!

    init(state: PCLinkState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "link.sheet"
        buildUI()
        applyState(state, forceKind: true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onClose?()
    }

    // MARK: - UI

    private func buildUI() {
        let titleLabel = UILabel()
        titleLabel.text = "PC 连接"
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .tertiaryLabel
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityIdentifier = "link.sheet.close"
        closeButton.accessibilityLabel = "关闭"
        closeButton.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), closeButton])
        titleRow.axis = .horizontal
        titleRow.alignment = .center

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        statusLabel.accessibilityIdentifier = "link.sheet.status"

        selectedKind = max(0, min(4, state.kind))
        buildKindChips()

        // 串口
        portButton.contentHorizontalAlignment = .left
        portButton.setTitle("选择端口", for: .normal)
        portButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        portButton.accessibilityIdentifier = "link.sheet.port"
        portButton.showsMenuAsPrimaryAction = true

        baudField.text = "\(state.baud)"
        baudField.keyboardType = .numberPad
        baudField.font = Theme.monoFont(ofSize: 15, weight: .medium)
        baudField.backgroundColor = .secondarySystemFill
        baudField.layer.cornerRadius = 6
        baudField.accessibilityIdentifier = "link.sheet.baud"
        baudField.heightAnchor.constraint(equalToConstant: 34).isActive = true

        serialBox = formBox(rows: [
            labeled("端口", portButton),
            labeled("波特率", baudField)
        ])

        // TCP 客户端
        hostField.text = state.tcpHost
        hostField.keyboardType = .URL
        hostField.autocapitalizationType = .none
        hostField.autocorrectionType = .no
        hostField.backgroundColor = .secondarySystemFill
        hostField.layer.cornerRadius = 6
        hostField.accessibilityIdentifier = "link.sheet.host"
        hostField.heightAnchor.constraint(equalToConstant: 34).isActive = true

        tcpPortField.text = "\(state.tcpClientPort)"
        tcpPortField.keyboardType = .numberPad
        tcpPortField.backgroundColor = .secondarySystemFill
        tcpPortField.layer.cornerRadius = 6
        tcpPortField.accessibilityIdentifier = "link.sheet.port.tcp"
        tcpPortField.heightAnchor.constraint(equalToConstant: 34).isActive = true

        clientBox = formBox(rows: [
            labeled("主机", hostField),
            labeled("端口", tcpPortField)
        ])

        // TCP 服务端
        listenPortField.text = "\(state.tcpServerPort)"
        listenPortField.keyboardType = .numberPad
        listenPortField.backgroundColor = .secondarySystemFill
        listenPortField.layer.cornerRadius = 6
        listenPortField.accessibilityIdentifier = "link.sheet.listen"
        listenPortField.heightAnchor.constraint(equalToConstant: 34).isActive = true
        serverBox = formBox(rows: [labeled("监听端口", listenPortField)])

        // UDP
        remoteHostField.text = state.udpHost
        remoteHostField.backgroundColor = .secondarySystemFill
        remoteHostField.layer.cornerRadius = 6
        remoteHostField.autocapitalizationType = .none
        remoteHostField.accessibilityIdentifier = "link.sheet.udp.host"
        remoteHostField.heightAnchor.constraint(equalToConstant: 34).isActive = true

        remotePortField.text = "\(state.udpRemotePort)"
        remotePortField.keyboardType = .numberPad
        remotePortField.backgroundColor = .secondarySystemFill
        remotePortField.layer.cornerRadius = 6
        remotePortField.accessibilityIdentifier = "link.sheet.udp.remote"
        remotePortField.heightAnchor.constraint(equalToConstant: 34).isActive = true

        localPortField.text = "\(state.udpLocalPort)"
        localPortField.keyboardType = .numberPad
        localPortField.backgroundColor = .secondarySystemFill
        localPortField.layer.cornerRadius = 6
        localPortField.accessibilityIdentifier = "link.sheet.udp.local"
        localPortField.heightAnchor.constraint(equalToConstant: 34).isActive = true

        udpBox = formBox(rows: [
            labeled("远端主机", remoteHostField),
            labeled("远端端口", remotePortField),
            labeled("本地端口", localPortField)
        ])

        // 演示
        let demoLabel = UILabel()
        demoLabel.text = "演示模式不需要硬件，用来试界面和调参。"
        demoLabel.font = .preferredFont(forTextStyle: .footnote)
        demoLabel.textColor = .secondaryLabel
        demoLabel.numberOfLines = 0
        demoBox = formBox(rows: [demoLabel])

        hintLabel.text = "串口列表来自 PC；端口或波特率不对时连接会失败，错误会显示在这里。"
        hintLabel.font = .preferredFont(forTextStyle: .caption2)
        hintLabel.textColor = .tertiaryLabel
        hintLabel.numberOfLines = 0

        refreshButton.setTitle("刷新端口", for: .normal)
        refreshButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        refreshButton.setTitleColor(Theme.accent, for: .normal)
        refreshButton.addTarget(self, action: #selector(refreshTapped), for: .touchUpInside)
        refreshButton.accessibilityIdentifier = "link.sheet.refresh"

        actionButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        actionButton.setTitleColor(.white, for: .normal)
        actionButton.backgroundColor = Theme.accent
        actionButton.layer.cornerRadius = 10
        actionButton.heightAnchor.constraint(equalToConstant: 46).isActive = true
        actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        actionButton.accessibilityIdentifier = "link.sheet.action"

        let buttonsRow = UIStackView(arrangedSubviews: [actionButton, refreshButton])
        buttonsRow.axis = .horizontal
        buttonsRow.spacing = 10
        buttonsRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [
            titleRow, statusLabel, kindScroll,
            serialBox, clientBox, serverBox, udpBox, demoBox,
            hintLabel, buttonsRow
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor,
                                           constant: Theme.horizontalInset),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor,
                                            constant: -Theme.horizontalInset)
        ])
    }

    private func labeled(_ title: String, _ field: UIView) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let row = UIStackView(arrangedSubviews: [label, field])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        return row
    }

    private func formBox(rows: [UIView]) -> UIStackView {
        let box = UIStackView(arrangedSubviews: rows)
        box.axis = .vertical
        box.spacing = 8
        return box
    }

    // MARK: - State

    /// 服务端推回的状态，永远以它为准。
    func applyState(_ newState: PCLinkState, forceKind: Bool = false) {
        state = newState
        statusLabel.text = newState.statusText
        statusLabel.textColor = newState.isConnected ? Theme.accent : .secondaryLabel

        if forceKind || !userPickedKind {
            selectedKind = max(0, min(4, newState.kind))
            updateKindChips()
        }

        if !newState.ports.isEmpty {
            portButton.menu = makePortMenu(newState.ports)
        }
        if !userPickedKind {
            let title = newState.serialPort.isEmpty ? "选择端口" : newState.serialPort
            portButton.setTitle(title, for: .normal)
        }

        actionButton.setTitle(newState.isConnected ? "断开" : "连接", for: .normal)
        actionButton.backgroundColor = newState.isConnected ? Theme.danger : Theme.accent
        refreshButton.isHidden = selectedKind != 0
        updateVisibleBox()
    }

    /// 服务端拒绝时把原因显示在面板里，不弹窗打断。
    func showError(_ text: String) {
        hintLabel.text = text
        hintLabel.textColor = Theme.danger
    }

    private func makePortMenu(_ ports: [String]) -> UIMenu {
        let actions = ports.map { port in
            UIAction(title: port) { [weak self] _ in
                guard let self = self else { return }
                self.portButton.setTitle(port, for: .normal)
            }
        }
        return UIMenu(title: "串口", children: actions)
    }

    private func updateVisibleBox() {
        let kind = selectedKind
        serialBox.isHidden = kind != 0
        clientBox.isHidden = kind != 1
        serverBox.isHidden = kind != 2
        udpBox.isHidden = kind != 3
        demoBox.isHidden = kind != 4
    }

    // MARK: - Actions

    @objc private func kindChipTapped(_ sender: UIButton) {
        selectedKind = sender.tag
        userPickedKind = true
        updateKindChips()
        updateVisibleBox()
        refreshButton.isHidden = selectedKind != 0
    }

    /// 五段横向胶囊：分段控件在 iPhone 上会把「TCP 客户端」截断。
    private func buildKindChips() {
        kindScroll.showsHorizontalScrollIndicator = false
        kindScroll.translatesAutoresizingMaskIntoConstraints = false
        kindScroll.accessibilityIdentifier = "link.sheet.kind"
        kindScroll.heightAnchor.constraint(equalToConstant: 36).isActive = true

        kindStack.axis = .horizontal
        kindStack.spacing = 6
        kindStack.translatesAutoresizingMaskIntoConstraints = false
        kindScroll.addSubview(kindStack)

        NSLayoutConstraint.activate([
            kindStack.leadingAnchor.constraint(equalTo: kindScroll.contentLayoutGuide.leadingAnchor),
            kindStack.trailingAnchor.constraint(equalTo: kindScroll.contentLayoutGuide.trailingAnchor),
            kindStack.topAnchor.constraint(equalTo: kindScroll.contentLayoutGuide.topAnchor),
            kindStack.bottomAnchor.constraint(equalTo: kindScroll.contentLayoutGuide.bottomAnchor),
            kindStack.heightAnchor.constraint(equalTo: kindScroll.frameLayoutGuide.heightAnchor)
        ])

        for (index, title) in PCLinkState.kindTitles.enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
            button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
            button.layer.cornerRadius = 18
            button.tag = index
            button.accessibilityIdentifier = "link.sheet.kind.\(index)"
            button.addTarget(self, action: #selector(kindChipTapped(_:)), for: .touchUpInside)
            kindStack.addArrangedSubview(button)
            kindButtons.append(button)
        }
        updateKindChips()
    }

    private func updateKindChips() {
        for (index, button) in kindButtons.enumerated() {
            let isSelected = index == selectedKind
            button.backgroundColor = isSelected ? Theme.accent : .secondarySystemFill
            button.setTitleColor(isSelected ? .white : .label, for: .normal)
        }
        // 小屏放不下五项：把当前选中项滚进视野，别让人以为没选中。
        kindScroll.layoutIfNeeded()
        if kindButtons.indices.contains(selectedKind) {
            let target = kindButtons[selectedKind].frame.insetBy(dx: -8, dy: 0)
            kindScroll.scrollRectToVisible(target, animated: false)
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func refreshTapped() {
        onRefreshPorts?()
    }

    @objc private func actionTapped() {
        if state.isConnected {
            onDisconnect?()
            hintLabel.text = "正在请求 PC 断开…"
            return
        }

        var request = LinkRequest(kind: max(0, selectedKind))
        switch request.kind {
        case 0:
            request.port = portButton.title(for: .normal) == "选择端口"
                ? state.serialPort
                : (portButton.title(for: .normal) ?? state.serialPort)
            request.baud = Int(baudField.text?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        case 1:
            request.host = hostField.text?.trimmingCharacters(in: .whitespaces) ?? ""
            request.tcpPort = Int(tcpPortField.text?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        case 2:
            request.tcpPort =
                Int(listenPortField.text?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        case 3:
            request.host = remoteHostField.text?.trimmingCharacters(in: .whitespaces) ?? ""
            request.remotePort =
                Int(remotePortField.text?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            request.localPort =
                Int(localPortField.text?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        default:
            break
        }

        hintLabel.text = "正在请求 PC 打开连接…"
        hintLabel.textColor = .tertiaryLabel
        onOpen?(request)
    }
}
