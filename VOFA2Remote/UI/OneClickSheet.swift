//
//  OneClickSheet.swift
//  VOFA2Remote
//
//  Mirrors the PC "一键发送数据" dialog: pick which sliders of the current group
//  are sent, adjust the interval, then watch progress or cancel.
//
//  The wire protocol has no message to change `controls[].inc`, so the checkboxes
//  start from what the PC has ticked and stay local to this send.
//

import UIKit

final class OneClickSheetViewController: UIViewController {

    struct Row {
        let id: Int
        let label: String
        let valueText: String
        /// `inc` as reported by the PC.
        let pcIncluded: Bool
    }

    let groupName: String
    private let rows: [Row]
    private var selected: Set<Int>
    private var intervalMs: Int

    var onSend: (([Int], Int) -> Void)?
    var onStop: (() -> Void)?
    var onClose: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let countLabel = UILabel()
    private let intervalField = InsetTextField()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let statusLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let selectAllButton = UIButton(type: .system)
    private let selectNoneButton = UIButton(type: .system)
    private let warningLabel = UILabel()
    private var isSending = false
    /// Whether the PC says it is connected to a board / a TCP peer.
    private var pcConnected: Bool

    init(groupName: String, rows: [Row], intervalMs: Int, pcConnected: Bool) {
        self.groupName = groupName
        self.rows = rows
        self.intervalMs = max(10, min(5000, intervalMs))
        self.pcConnected = pcConnected
        self.selected = Set(rows.filter { $0.pcIncluded }.map { $0.id })
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "oneclick.sheet"
        buildUI()
        updateCount()

        // Starting with nothing ticked on the PC would block sending entirely, so
        // pre-select the whole group the first time that happens.
        if selected.isEmpty {
            selected = Set(rows.map { $0.id })
            updateCount()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isSending {
            // Never leave a send running behind a dismissed sheet.
            onStop?()
            isSending = false
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onClose?()
    }

    // MARK: - UI

    private func buildUI() {
        let titleLabel = UILabel()
        titleLabel.text = "一键发送数据"
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .tertiaryLabel
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityIdentifier = "oneclick.sheet.close"
        closeButton.accessibilityLabel = "关闭"
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), closeButton])
        titleRow.axis = .horizontal
        titleRow.alignment = .center

        let subtitle = UILabel()
        subtitle.text = "当前命令组：\(groupName)。按键和开关不会参与发送。"
        subtitle.font = .preferredFont(forTextStyle: .footnote)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0

        selectAllButton.setTitle("全选", for: .normal)
        selectAllButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        selectAllButton.setTitleColor(Theme.accent, for: .normal)
        selectAllButton.addTarget(self, action: #selector(selectAllTapped), for: .touchUpInside)
        selectAllButton.accessibilityIdentifier = "oneclick.sheet.selectAll"

        selectNoneButton.setTitle("全不选", for: .normal)
        selectNoneButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        selectNoneButton.setTitleColor(Theme.accent, for: .normal)
        selectNoneButton.addTarget(self, action: #selector(selectNoneTapped), for: .touchUpInside)
        selectNoneButton.accessibilityIdentifier = "oneclick.sheet.selectNone"

        countLabel.font = .preferredFont(forTextStyle: .footnote)
        countLabel.textColor = .secondaryLabel
        countLabel.textAlignment = .right
        countLabel.accessibilityIdentifier = "oneclick.sheet.count"

        let toolsRow = UIStackView(arrangedSubviews: [selectAllButton, selectNoneButton, UIView(), countLabel])
        toolsRow.axis = .horizontal
        toolsRow.spacing = 14
        toolsRow.alignment = .center

        tableView.dataSource = self
        tableView.delegate = self
        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.backgroundColor = .secondarySystemBackground
        tableView.layer.cornerRadius = 10
        tableView.clipsToBounds = true
        tableView.tableFooterView = UIView()
        tableView.accessibilityIdentifier = "oneclick.sheet.table"

        let intervalLabel = UILabel()
        intervalLabel.text = "发送间隔"
        intervalLabel.font = .preferredFont(forTextStyle: .subheadline)

        intervalField.text = "\(intervalMs)"
        intervalField.font = Theme.monoFont(ofSize: 15, weight: .medium)
        intervalField.textAlignment = .right
        intervalField.keyboardType = .numberPad
        intervalField.backgroundColor = .secondarySystemFill
        intervalField.layer.cornerRadius = 6
        intervalField.delegate = self
        intervalField.accessibilityIdentifier = "oneclick.sheet.interval"
        intervalField.translatesAutoresizingMaskIntoConstraints = false
        intervalField.widthAnchor.constraint(equalToConstant: 84).isActive = true
        intervalField.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let msLabel = UILabel()
        msLabel.text = "ms"
        msLabel.font = .preferredFont(forTextStyle: .footnote)
        msLabel.textColor = .secondaryLabel

        let intervalRow = UIStackView(arrangedSubviews: [intervalLabel, UIView(), intervalField, msLabel])
        intervalRow.axis = .horizontal
        intervalRow.spacing = 6
        intervalRow.alignment = .center

        let hint = UILabel()
        hint.text = "勾选只对本次发送有效；PC 上勾选了「参与一键发送数据」的滑块默认已选。"
        hint.font = .preferredFont(forTextStyle: .caption2)
        hint.textColor = .tertiaryLabel
        hint.numberOfLines = 0

        warningLabel.text = "PC 还没有连接设备，发送会失败；请先在 PC 上连接串口/TCP。"
        warningLabel.font = .preferredFont(forTextStyle: .caption1)
        warningLabel.textColor = Theme.warning
        warningLabel.numberOfLines = 0
        warningLabel.isHidden = pcConnected
        warningLabel.accessibilityIdentifier = "oneclick.sheet.warning"

        progressView.progressTintColor = Theme.accent
        progressView.trackTintColor = .tertiarySystemFill
        progressView.isHidden = true
        progressView.accessibilityIdentifier = "oneclick.sheet.progress"

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        statusLabel.accessibilityIdentifier = "oneclick.sheet.status"
        statusLabel.text = "按键/开关不会被发送。"

        sendButton.setTitle("发送", for: .normal)
        sendButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        sendButton.setTitleColor(.white, for: .normal)
        sendButton.backgroundColor = Theme.accent
        sendButton.layer.cornerRadius = 10
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.heightAnchor.constraint(equalToConstant: 46).isActive = true
        sendButton.accessibilityIdentifier = "oneclick.sheet.send"

        stopButton.setTitle("停止", for: .normal)
        stopButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        stopButton.setTitleColor(Theme.danger, for: .normal)
        stopButton.layer.borderWidth = 1
        stopButton.layer.borderColor = Theme.danger.withAlphaComponent(0.4).cgColor
        stopButton.layer.cornerRadius = 10
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        stopButton.heightAnchor.constraint(equalToConstant: 46).isActive = true
        stopButton.widthAnchor.constraint(equalToConstant: 88).isActive = true
        stopButton.isEnabled = false
        stopButton.alpha = 0.4
        stopButton.accessibilityIdentifier = "oneclick.sheet.stop"

        let buttonsRow = UIStackView(arrangedSubviews: [sendButton, stopButton])
        buttonsRow.axis = .horizontal
        buttonsRow.spacing = 10

        // Absorbs leftover height so the list keeps a content-sized box.
        let filler = UIView()
        filler.setContentHuggingPriority(.defaultLow, for: .vertical)

        let stack = UIStackView(arrangedSubviews: [
            titleRow, subtitle, toolsRow, tableView, intervalRow, hint, warningLabel,
            filler, progressView, statusLabel, buttonsRow
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let rowHeight: CGFloat = 56
        let tableHeight = min(max(CGFloat(rows.count) * rowHeight + 8, 120), 340)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.horizontalInset),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Theme.horizontalInset),
            stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            tableView.heightAnchor.constraint(equalToConstant: tableHeight)
        ])
    }

    // MARK: - Selection

    private func updateCount() {
        countLabel.text = "已选 \(selected.count) 项"
        sendButton.isEnabled = !selected.isEmpty && !isSending
        sendButton.alpha = sendButton.isEnabled ? 1 : 0.4
        tableView.reloadData()
    }

    @objc private func selectAllTapped() {
        guard !isSending else { return }
        selected = Set(rows.map { $0.id })
        updateCount()
    }

    @objc private func selectNoneTapped() {
        guard !isSending else { return }
        selected.removeAll()
        updateCount()
    }

    // MARK: - Sending

    @objc private func sendTapped() {
        guard !selected.isEmpty else { return }
        intervalMs = parsedInterval()
        intervalField.text = "\(intervalMs)"

        // Keep the PC's order: the plan is built from the visible row order.
        let ids = rows.map { $0.id }.filter { selected.contains($0) }

        isSending = true
        setControlsEnabled(false)
        progressView.isHidden = false
        progressView.progress = 0
        statusLabel.text = "准备发送…"
        sendButton.setTitle("发送中…", for: .normal)

        onSend?(ids, intervalMs)
    }

    @objc private func stopTapped() {
        onStop?()
        statusLabel.text = "已请求取消…"
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    private func parsedInterval() -> Int {
        let text = intervalField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        let value = Int(text) ?? intervalMs
        return max(10, min(5000, value))
    }

    private func setControlsEnabled(_ enabled: Bool) {
        tableView.isUserInteractionEnabled = enabled
        selectAllButton.isEnabled = enabled
        selectNoneButton.isEnabled = enabled
        intervalField.isEnabled = enabled
        selectAllButton.alpha = enabled ? 1 : 0.4
        selectNoneButton.alpha = enabled ? 1 : 0.4
        sendButton.isEnabled = enabled
        sendButton.alpha = enabled ? 1 : 0.5
        stopButton.isEnabled = !enabled
        stopButton.alpha = enabled ? 0.4 : 1
    }

    /// Called when a `conn` update arrives while the sheet is open.
    func setPCConnected(_ connected: Bool) {
        guard pcConnected != connected else { return }
        pcConnected = connected
        warningLabel.isHidden = connected
    }

    /// Called by the tuning screen for both the server-driven and the local plan.
    func updateProgress(sent: Int, total: Int, status: String, sending: Bool) {
        progressView.isHidden = false
        progressView.progress = total > 0 ? Float(min(sent, total)) / Float(total) : 0
        if !status.isEmpty {
            statusLabel.text = status
        }
        if isSending != sending {
            isSending = sending
            setControlsEnabled(!sending)
            sendButton.setTitle(sending ? "发送中…" : "发送", for: .normal)
        }
    }
}

// MARK: - Table

extension OneClickSheetViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "OneClickRow"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        let row = rows[indexPath.row]
        cell.textLabel?.text = row.label
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.detailTextLabel?.text = row.pcIncluded ? "\(row.valueText) · PC 已勾选" : row.valueText
        cell.detailTextLabel?.font = Theme.monoFont(ofSize: 12)
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.accessoryType = selected.contains(row.id) ? .checkmark : .none
        cell.tintColor = Theme.accent
        cell.backgroundColor = .clear
        cell.accessibilityIdentifier = "oneclick.sheet.item.\(row.label)"
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = row.label
        cell.accessibilityValue = selected.contains(row.id) ? "已选" : "未选"
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isSending else { return }
        let row = rows[indexPath.row]
        if selected.contains(row.id) {
            selected.remove(row.id)
        } else {
            selected.insert(row.id)
        }
        updateCount()
    }
}

extension OneClickSheetViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
