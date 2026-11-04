//
//  ControlCells.swift
//  VOFA2Remote
//
//  Table cells for switches, command buttons and parameter sliders.
//

import UIKit

/// Text field with a little horizontal breathing room.
final class InsetTextField: UITextField {
    var inset: UIEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        bounds.inset(by: inset)
    }
    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        bounds.inset(by: inset)
    }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
        bounds.inset(by: inset)
    }
}

// MARK: - Switch

final class SwitchCell: UITableViewCell {

    static let reuseIdentifier = "SwitchCell"

    private let nameLabel = UILabel()
    private let toggle = UISwitch()
    private var onToggle: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.numberOfLines = 0

        toggle.onTintColor = Theme.accent
        toggle.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        contentView.addSubview(nameLabel)
        contentView.addSubview(toggle)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.horizontalInset),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            toggle.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            toggle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.horizontalInset),
            toggle.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(label: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        nameLabel.text = label
        toggle.isOn = isOn
        onToggle = onChange
        toggle.accessibilityIdentifier = "action.switch.\(label)"
        toggle.accessibilityLabel = label
    }

    func setOn(_ isOn: Bool) {
        toggle.setOn(isOn, animated: true)
    }

    @objc private func toggleChanged() {
        onToggle?(toggle.isOn)
    }
}

// MARK: - Command button

final class CommandButtonCell: UITableViewCell {

    static let reuseIdentifier = "CommandButtonCell"

    private let button = UIButton(type: .system)
    private var onTap: (() -> Void)?
    private var lastTap = Date.distantPast

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = .secondarySystemFill
        button.layer.cornerRadius = 10
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)

        button.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.horizontalInset),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.horizontalInset),
            button.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            button.heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(label: String, onTap: @escaping () -> Void) {
        button.setTitle(label, for: .normal)
        button.accessibilityIdentifier = "action.button.\(label)"
        self.onTap = onTap
    }

    /// Highlights the button for a moment, used both for taps and `flash` echoes.
    func flash() {
        UIView.animate(withDuration: 0.08, animations: {
            self.button.backgroundColor = Theme.accentSoft
        }, completion: { _ in
            UIView.animate(withDuration: 0.24) {
                self.button.backgroundColor = .secondarySystemFill
            }
        })
    }

    @objc private func tapped() {
        // 300 ms debounce so a double tap does not send two commands.
        let now = Date()
        guard now.timeIntervalSince(lastTap) > 0.3 else { return }
        lastTap = now
        flash()
        onTap?()
    }
}

// MARK: - Slider

final class ControlCell: UITableViewCell {

    static let reuseIdentifier = "ControlCell"

    private let nameLabel = UILabel()
    private let valueField = InsetTextField()
    private let slider = UISlider()
    private let minLabel = UILabel()
    private let maxLabel = UILabel()

    private var item: ControlItem?
    private var isDragging = false

    var onDrag: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?
    var onExactCommit: ((Double) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.numberOfLines = 1
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        valueField.font = Theme.monoFont(ofSize: 15, weight: .medium)
        valueField.textAlignment = .right
        valueField.backgroundColor = .secondarySystemFill
        valueField.layer.cornerRadius = 6
        valueField.keyboardType = .numbersAndPunctuation
        valueField.returnKeyType = .done
        valueField.textColor = .label
        valueField.delegate = self
        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.widthAnchor.constraint(equalToConstant: 92).isActive = true
        valueField.heightAnchor.constraint(equalToConstant: 30).isActive = true
        valueField.addTarget(self, action: #selector(fieldEditingEnded), for: .editingDidEndOnExit)
        valueField.addTarget(self, action: #selector(fieldEditingEnded), for: .editingDidEnd)

        let fieldToolbar = UIToolbar()
        fieldToolbar.sizeToFit()
        fieldToolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(dismissKeyboard))
        ]
        valueField.inputAccessoryView = fieldToolbar

        slider.minimumTrackTintColor = Theme.accent
        slider.maximumTrackTintColor = .tertiarySystemFill
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderFinished), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        minLabel.font = Theme.monoFont(ofSize: 10)
        minLabel.textColor = .tertiaryLabel
        maxLabel.font = Theme.monoFont(ofSize: 10)
        maxLabel.textColor = .tertiaryLabel
        maxLabel.textAlignment = .right

        let rangeRow = UIStackView(arrangedSubviews: [minLabel, maxLabel])
        rangeRow.axis = .horizontal
        rangeRow.distribution = .fillEqually

        let topRow = UIStackView(arrangedSubviews: [nameLabel, valueField])
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 8

        let stack = UIStackView(arrangedSubviews: [topRow, slider, rangeRow])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.horizontalInset),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.horizontalInset),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Configuration

    func configure(with item: ControlItem, onDrag: @escaping (Double) -> Void,
                   onCommit: @escaping (Double) -> Void, onExactCommit: @escaping (Double) -> Void) {
        self.item = item
        self.onDrag = onDrag
        self.onCommit = onCommit
        self.onExactCommit = onExactCommit

        nameLabel.text = item.label
        slider.accessibilityIdentifier = "control.slider.\(item.label)"
        slider.accessibilityLabel = item.label
        valueField.accessibilityIdentifier = "control.field.\(item.label)"
        valueField.accessibilityLabel = "\(item.label) 数值"
        nameLabel.accessibilityIdentifier = "control.name.\(item.label)"

        // UISlider refuses minimum == maximum, so keep a hair of range.
        let lower = Float(min(item.minimum, item.maximum))
        let upper = Float(max(item.minimum, item.maximum))
        slider.minimumValue = lower
        slider.maximumValue = upper > lower ? upper : lower + 0.0001
        slider.value = Float(item.value)

        minLabel.text = item.formatted(item.minimum)
        maxLabel.text = item.formatted(item.maximum)
        valueField.text = item.formatted(item.value)
        isDragging = false
    }

    /// Applies a server echo without stealing an in-progress drag.
    func applyEcho(_ value: Double) {
        guard let item = item else { return }
        valueField.text = item.formatted(value)
        guard !isDragging else { return }
        slider.setValue(Float(value), animated: false)
    }

    func setEditingEnabled(_ enabled: Bool) {
        slider.isEnabled = enabled
        valueField.isEnabled = enabled
        alpha = enabled ? 1 : 0.5
    }

    // MARK: Actions

    @objc private func sliderChanged() {
        guard let item = item else { return }
        isDragging = true
        let value = Double(slider.value)
        valueField.text = item.formatted(value)
        onDrag?(value)
    }

    @objc private func sliderFinished() {
        guard let item = item else { return }
        isDragging = false
        // Snap the final value to the configured step so the PC spin box agrees.
        let value = quantized(Double(slider.value), item: item)
        slider.setValue(Float(value), animated: false)
        valueField.text = item.formatted(value)
        onCommit?(value)
    }

    private func quantized(_ value: Double, item: ControlItem) -> Double {
        guard item.step > 0, item.step.isFinite else { return value }
        let steps = ((value - item.minimum) / item.step).rounded()
        let snapped = item.minimum + steps * item.step
        return item.clamped(snapped)
    }

    @objc private func fieldEditingEnded() {
        guard let text = valueField.text, let item = item else { return }
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard let typed = Double(normalized), typed.isFinite else {
            valueField.text = item.formatted(item.value)
            valueField.resignFirstResponder()
            return
        }
        // Typed values are allowed outside the slider range (exact commit).
        valueField.text = item.formatted(typed)
        if Double(slider.minimumValue)...Double(slider.maximumValue) ~= typed {
            slider.setValue(Float(typed), animated: false)
        }
        onExactCommit?(typed)
        valueField.resignFirstResponder()
    }

    @objc private func dismissKeyboard() {
        valueField.resignFirstResponder()
    }
}

extension ControlCell: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        isDragging = false
        textField.selectAll(nil)
    }
}
