import AppKit

/// The floating overlay that shows the row of window cards.
///
/// A borderless, non-activating `NSPanel`: it appears above everything without
/// activating MacUtil, so the previously-focused app stays frontmost. Cards are
/// built with their thumbnails already in place (captured before show) so there
/// is no icon→preview flicker.
final class SwitcherPanel {
    private var panel: NSPanel?
    private var cards: [SwitcherCard] = []

    private let spacing: CGFloat = 12
    private let padding: CGFloat = 20

    func show(
        windows: [SwitchWindow],
        thumbnails: [CGWindowID: NSImage],
        on screen: NSScreen,
        onHover: @escaping (Int) -> Void,
        onClick: @escaping (Int) -> Void
    ) {
        hide()

        let cardSize = SwitcherCard.size

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        var builtCards: [SwitcherCard] = []
        for (index, window) in windows.enumerated() {
            let card = SwitcherCard(
                window: window,
                thumbnail: thumbnails[window.id],
                onHover: { onHover(index) },
                onClick: { onClick(index) }
            )
            card.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(equalToConstant: cardSize.width).isActive = true
            card.heightAnchor.constraint(equalToConstant: cardSize.height).isActive = true
            stack.addArrangedSubview(card)
            builtCards.append(card)
        }

        let contentWidth = CGFloat(windows.count) * cardSize.width
            + CGFloat(max(0, windows.count - 1)) * spacing
        let maxWidth = screen.visibleFrame.width - 80
        let panelWidth = min(contentWidth + padding * 2, maxWidth)
        let panelHeight = cardSize.height + padding * 2

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack

        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: padding),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -padding),
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: padding),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -padding),

            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.heightAnchor.constraint(equalToConstant: cardSize.height),
        ])

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = background

        let origin = NSPoint(
            x: screen.frame.midX - panelWidth / 2,
            y: screen.frame.midY - panelHeight / 2
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()

        self.panel = panel
        self.cards = builtCards
    }

    func select(index: Int) {
        for (i, card) in cards.enumerated() {
            card.isSelected = (i == index)
        }
        if cards.indices.contains(index) {
            let card = cards[index]
            card.scrollToVisible(card.bounds)
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        cards = []
    }
}
