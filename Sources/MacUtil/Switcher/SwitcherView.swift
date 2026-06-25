import AppKit

/// One window card in the switcher: a thumbnail above an app-icon + title row.
/// Shows the app icon as a placeholder until the live thumbnail arrives.
final class SwitcherCard: NSView {
    static let size = NSSize(width: 180, height: 150)

    private let thumbnailView = NSImageView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let onHover: () -> Void
    private let onClick: () -> Void

    var isSelected = false {
        didSet { updateSelection() }
    }

    init(window: SwitchWindow, thumbnail: NSImage?, onHover: @escaping () -> Void, onClick: @escaping () -> Void) {
        self.onHover = onHover
        self.onClick = onClick
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 10

        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        // Thumbnail is captured before the panel is shown, so it's set once here —
        // no icon→preview swap, no flicker. Falls back to the app icon only for
        // windows ScreenCaptureKit can't capture.
        thumbnailView.image = thumbnail ?? window.icon
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = window.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = window.title
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(thumbnailView)
        addSubview(iconView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            thumbnailView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            thumbnailView.heightAnchor.constraint(equalToConstant: 96),

            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
        ])

        updateSelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)

        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover()
    }

    override func mouseMoved(with event: NSEvent) {
        onHover()
    }

    override func mouseDown(with event: NSEvent) {
        onHover()
    }

    override func mouseUp(with event: NSEvent) {
        onClick()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func updateSelection() {
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.30).cgColor
            : NSColor.clear.cgColor
    }
}
