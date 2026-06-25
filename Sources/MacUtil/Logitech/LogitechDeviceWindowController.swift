import AppKit

final class LogitechDeviceWindowController: NSWindowController {
    private let manager: LogitechManager
    private var deviceID: String
    private var device: LogitechDeviceSnapshot

    private let titleLabel = NSTextField(labelWithString: "")
    private let batteryLabel = NSTextField(labelWithString: "")
    private let dpiSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let dpiValueLabel = NSTextField(labelWithString: "")
    private let dpiApplyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let dpiStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let gesturePopup = NSPopUpButton()
    private let gestureStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let backSideButtonPopup = NSPopUpButton()
    private let forwardSideButtonPopup = NSPopUpButton()
    private let sideButtonStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)

    init(device: LogitechDeviceSnapshot, manager: LogitechManager) {
        self.device = device
        self.deviceID = device.id
        self.manager = manager

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = device.name
        window.minSize = NSSize(width: 480, height: 400)
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.contentView = makeContentView()
        configureActions()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showDevice() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func update(device: LogitechDeviceSnapshot) {
        guard device.id == deviceID else { return }
        self.device = device
        window?.title = device.name
        render()
    }

    private func configureActions() {
        dpiSlider.target = self
        dpiSlider.action = #selector(dpiSliderChanged)
        dpiSlider.isContinuous = true

        dpiApplyButton.target = self
        dpiApplyButton.action = #selector(applyDPI)

        gesturePopup.target = self
        gesturePopup.action = #selector(gestureActionChanged)

        configureSideButtonPopup(backSideButtonPopup, button: .back)
        configureSideButtonPopup(forwardSideButtonPopup, button: .forward)

        refreshButton.target = self
        refreshButton.action = #selector(refreshDevice)

        for action in LogitechGestureAction.allCases {
            gesturePopup.addItem(withTitle: action.title)
            gesturePopup.lastItem?.representedObject = action.rawValue
        }
    }

    private func makeContentView() -> NSView {
        let root = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .labelColor

        batteryLabel.font = .systemFont(ofSize: 13, weight: .medium)
        batteryLabel.textColor = .secondaryLabelColor

        let headerColumn = NSStackView(views: [titleLabel, batteryLabel])
        headerColumn.orientation = .vertical
        headerColumn.alignment = .leading
        headerColumn.spacing = 3

        refreshButton.bezelStyle = .rounded

        let header = NSStackView(views: [headerColumn, NSView(), refreshButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false
        headerColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(section(title: "Pointer Speed", body: dpiView()))
        stack.addArrangedSubview(section(title: "Gesture Button", body: gestureView()))
        stack.addArrangedSubview(section(title: "Side Buttons", body: sideButtonsView()))

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        return root
    }

    private func dpiView() -> NSView {
        dpiValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        dpiValueLabel.alignment = .right
        dpiValueLabel.translatesAutoresizingMaskIntoConstraints = false

        dpiApplyButton.bezelStyle = .rounded
        dpiApplyButton.keyEquivalent = "\r"

        let row = NSStackView(views: [dpiSlider, dpiValueLabel, dpiApplyButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        dpiStatusLabel.font = .systemFont(ofSize: 12)
        dpiStatusLabel.textColor = .secondaryLabelColor
        dpiStatusLabel.preferredMaxLayoutWidth = 420

        let stack = NSStackView(views: [row, dpiStatusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            dpiSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            dpiValueLabel.widthAnchor.constraint(equalToConstant: 72),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        return stack
    }

    private func sideButtonsView() -> NSView {
        let rows = NSStackView(views: [
            sideButtonRow(button: .back, popup: backSideButtonPopup),
            sideButtonRow(button: .forward, popup: forwardSideButtonPopup),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8

        sideButtonStatusLabel.font = .systemFont(ofSize: 12)
        sideButtonStatusLabel.textColor = .secondaryLabelColor
        sideButtonStatusLabel.preferredMaxLayoutWidth = 420

        let stack = NSStackView(views: [rows, sideButtonStatusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func sideButtonRow(button: LogitechSideButton, popup: NSPopUpButton) -> NSView {
        let label = NSTextField(labelWithString: button.title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        popup.bezelStyle = .rounded

        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 150),
            popup.widthAnchor.constraint(equalToConstant: 150),
        ])

        return row
    }

    private func gestureView() -> NSView {
        gesturePopup.bezelStyle = .rounded

        let row = NSStackView(views: [gesturePopup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        gestureStatusLabel.font = .systemFont(ofSize: 12)
        gestureStatusLabel.textColor = .secondaryLabelColor
        gestureStatusLabel.preferredMaxLayoutWidth = 420

        let stack = NSStackView(views: [row, gestureStatusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func section(title: String, body: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor

        let stack = NSStackView(views: [label, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        return stack
    }

    private func render() {
        titleLabel.stringValue = device.name
        batteryLabel.stringValue = "Battery: \(device.batteryTitle)"

        renderDPI()
        renderGesture()
        renderSideButtons()
    }

    private func renderDPI() {
        guard let dpi = device.dpi,
              let minDPI = dpi.min,
              let maxDPI = dpi.max else {
            dpiSlider.isEnabled = false
            dpiApplyButton.isEnabled = false
            dpiValueLabel.stringValue = "--"
            dpiStatusLabel.stringValue = device.lastError ?? "DPI is not available for this device."
            return
        }

        dpiSlider.isEnabled = true
        dpiApplyButton.isEnabled = true
        dpiSlider.minValue = Double(minDPI)
        dpiSlider.maxValue = Double(maxDPI)
        dpiSlider.doubleValue = Double(dpi.current)
        dpiSlider.numberOfTickMarks = min(dpi.values.count, 12)
        dpiValueLabel.stringValue = "\(dpi.current) DPI"
        dpiStatusLabel.stringValue = "Supported range: \(minDPI)-\(maxDPI) DPI"
    }

    private func renderGesture() {
        gesturePopup.isEnabled = device.supportsGestureButton
        let action = manager.gestureAction(for: deviceID)
        if let item = gesturePopup.itemArray.first(where: { ($0.representedObject as? String) == action.rawValue }) {
            gesturePopup.select(item)
        }
        gestureStatusLabel.stringValue = device.supportsGestureButton
            ? "Current action: \(action.title)"
            : "Gesture button is not available for this device."
    }

    private func renderSideButtons() {
        selectSideButtonPopup(backSideButtonPopup, action: manager.sideButtonAction(for: deviceID, button: .back))
        selectSideButtonPopup(forwardSideButtonPopup, action: manager.sideButtonAction(for: deviceID, button: .forward))

        let backAction = manager.sideButtonAction(for: deviceID, button: .back)
        let forwardAction = manager.sideButtonAction(for: deviceID, button: .forward)
        sideButtonStatusLabel.stringValue = "Current mapping: \(backAction.title), \(forwardAction.title)"
    }

    @objc private func dpiSliderChanged() {
        guard let dpi = device.dpi,
              let nearest = dpi.nearest(to: Int(dpiSlider.doubleValue.rounded())) else {
            return
        }
        dpiValueLabel.stringValue = "\(nearest) DPI"
    }

    @objc private func applyDPI() {
        let requested = Int(dpiSlider.doubleValue.rounded())
        dpiApplyButton.isEnabled = false
        dpiStatusLabel.stringValue = "Applying..."

        manager.setDPI(requested, for: deviceID) { [weak self] result in
            guard let self else { return }
            self.dpiApplyButton.isEnabled = true
            switch result {
            case .success(let applied):
                self.dpiValueLabel.stringValue = "\(applied) DPI"
                self.dpiSlider.doubleValue = Double(applied)
                self.dpiStatusLabel.stringValue = "Applied \(applied) DPI"
            case .failure(let error):
                self.dpiStatusLabel.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func gestureActionChanged() {
        guard let raw = gesturePopup.selectedItem?.representedObject as? String,
              let action = LogitechGestureAction(rawValue: raw) else {
            return
        }
        manager.setGestureAction(action, for: deviceID)
        gestureStatusLabel.stringValue = "Current action: \(action.title)"
    }

    @objc private func sideButtonActionChanged(_ sender: NSPopUpButton) {
        guard let rawButton = sender.identifier?.rawValue,
              let button = LogitechSideButton(rawValue: rawButton),
              let rawAction = sender.selectedItem?.representedObject as? String,
              let action = LogitechSideButtonAction(rawValue: rawAction) else {
            return
        }

        manager.setSideButtonAction(action, for: deviceID, button: button)
        renderSideButtons()
    }

    @objc private func refreshDevice() {
        manager.refreshDevices()
    }

    private func configureSideButtonPopup(_ popup: NSPopUpButton, button: LogitechSideButton) {
        popup.identifier = NSUserInterfaceItemIdentifier(button.rawValue)
        popup.target = self
        popup.action = #selector(sideButtonActionChanged(_:))

        for action in LogitechSideButtonAction.allCases {
            popup.addItem(withTitle: action.title)
            popup.lastItem?.representedObject = action.rawValue
        }
    }

    private func selectSideButtonPopup(_ popup: NSPopUpButton, action: LogitechSideButtonAction) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == action.rawValue }) {
            popup.select(item)
        }
    }
}
