import AppKit

final class UserGuideWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacUtil User Guide"
        window.minSize = NSSize(width: 460, height: 420)
        window.isReleasedWhenClosed = false
        window.contentView = UserGuideWindowController.makeContentView()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showGuide() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: Content

    private static func makeContentView() -> NSView {
        let root = NSView()

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading   // everything left-aligned; grids size to content
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        scroll.documentView = content
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
        ])

        stack.addArrangedSubview(header())

        stack.addArrangedSubview(section("Window Snapping", rows: [
            GuideRow("Left / Right half", .keys([["⌥", "⌘", "←"], ["⌥", "⌘", "→"]])),
            GuideRow("Top / Bottom half", .keys([["⌥", "⌘", "↑"], ["⌥", "⌘", "↓"]])),
            GuideRow("Top-left / Top-right", .keys([["⌥", "⌘", "U"], ["⌥", "⌘", "I"]])),
            GuideRow("Bottom-left / Bottom-right", .keys([["⌥", "⌘", "J"], ["⌥", "⌘", "K"]])),
            GuideRow("Maximize", .keys([["⌥", "⌘", "↩"]])),
            GuideRow("Center", .keys([["⌥", "⌘", "C"]])),
            GuideRow("Restore original size", .keys([["⌥", "⌘", "⌫"]])),
            GuideRow("First / Center / Last third", .keys([["⌥", "⌘", "D"], ["⌥", "⌘", "F"], ["⌥", "⌘", "G"]])),
            GuideRow("First / Last two-thirds", .keys([["⌥", "⌘", "E"], ["⌥", "⌘", "T"]])),
            GuideRow("Previous / Next display", .keys([["⌃", "⌥", "⌘", "←"], ["⌃", "⌥", "⌘", "→"]])),
        ]))

        stack.addArrangedSubview(section("Drag Snapping", rows: [
            GuideRow("Drag to left or right screen edge", .note("Snap to half")),
            GuideRow("Drag to top screen edge", .note("Maximize")),
            GuideRow("Drag to screen corner", .note("Snap to quarter")),
        ]))

        stack.addArrangedSubview(section("Window Switcher", rows: [
            GuideRow("Open / cycle forward", .keys([["⌘", "Tab"]])),
            GuideRow("Cycle backward", .keys([["⌘", "⇧", "Tab"]])),
            GuideRow("Select a window", .note("Move pointer over preview")),
            GuideRow("Focus a window", .note("Click preview")),
            GuideRow("Close selected window", .keys([["⌘", "W"]])),
            GuideRow("Quit selected app", .keys([["⌘", "Q"]])),
            GuideRow("Cancel", .keys([["Esc"]])),
        ]))

        stack.addArrangedSubview(section("Voice-to-Text", rows: [
            GuideRow("Raw dictation", .keys([["⌥", "Space"]])),
            GuideRow("AI email reply", .keys([["⌥", "⇧", "Space"]])),
            GuideRow("Stop recording", .note("Press the same shortcut again")),
            GuideRow("Email context", .note("Select email text, copy it, then focus the reply field")),
            GuideRow("AI setup", .note("Set OpenRouter key and model in the Voice-to-Text menu")),
        ]))

        stack.addArrangedSubview(section("App Cleanup", rows: [
            GuideRow("Quits unused apps", .keys([["⌘", "⇧", "Q"]])),
        ]))

        return root
    }

    // MARK: Header

    private static func header() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
        ])

        let title = NSTextField(labelWithString: "MacUtil")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = .labelColor

        let subtitle = NSTextField(wrappingLabelWithString:
            "Keyboard-driven window placement, app switching, voice input, and cleanup from the menu bar.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 420

        let titleColumn = NSStackView(views: [title, subtitle])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 2

        let row = NSStackView(views: [icon, titleColumn])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        return row
    }

    // MARK: Section (two-column shortcut table)

    private static func section(_ title: String, rows: [GuideRow]) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = .labelColor

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 9
        grid.columnSpacing = 18
        grid.rowAlignment = .none

        for row in rows {
            let gridRow = grid.addRow(with: [nameLabel(row.label), valueView(row.value)])
            gridRow.yPlacement = .center
        }
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading

        let column = NSStackView(views: [header, grid])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        return column
    }

    private static func nameLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static func valueView(_ value: GuideRow.Value) -> NSView {
        switch value {
        case .keys(let groups):
            return keycapGroups(groups)
        case .note(let text):
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            return label
        }
    }

    /// One or more keycap groups (alternatives), kept tight and separated by "/".
    private static func keycapGroups(_ groups: [[String]]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6

        for (index, group) in groups.enumerated() {
            if index > 0 {
                let slash = NSTextField(labelWithString: "/")
                slash.font = .systemFont(ofSize: 12)
                slash.textColor = .tertiaryLabelColor
                row.addArrangedSubview(slash)
            }
            let keys = NSStackView()
            keys.orientation = .horizontal
            keys.alignment = .centerY
            keys.spacing = 3
            for key in group {
                keys.addArrangedSubview(KeycapView(key))
            }
            row.addArrangedSubview(keys)
        }
        return row
    }
}

// MARK: - Model

private struct GuideRow {
    let label: String
    let value: Value

    init(_ label: String, _ value: Value) {
        self.label = label
        self.value = value
    }

    enum Value {
        case keys([[String]])   // alternative keycap groups, joined with "/"
        case note(String)       // plain descriptive text (e.g. drag actions)
    }
}

// MARK: - Keycap

/// A single key rendered as a small rounded "keycap" box. Colors are set in
/// `updateLayer` so they track light/dark appearance.
private final class KeycapView: NSView {
    init(_ text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
