import AppKit

/// The floating overlay that shows the grid of window cards.
///
/// A borderless, non-activating `NSPanel`: it appears above everything without
/// activating MacUtil, so the previously-focused app stays frontmost. Cards are
/// built with their thumbnails already in place (captured before show) so there
/// is no icon→preview flicker.
final class SwitcherPanel {
    private var panel: NSPanel?
    private var cards: [SwitcherCard] = []

    private let spacing: CGFloat = 12
    private let rowSpacing: CGFloat = 12
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
        let maxPanelWidth = screen.visibleFrame.width - 80
        let maxPanelHeight = screen.visibleFrame.height - 80
        let maxContentWidth = max(cardSize.width, maxPanelWidth - padding * 2)
        let maxColumns = max(1, Int((maxContentWidth + spacing) / (cardSize.width + spacing)))
        let columns = max(1, min(windows.count, maxColumns))
        let rows = Int(ceil(Double(windows.count) / Double(columns)))
        let contentWidth = CGFloat(columns) * cardSize.width + CGFloat(max(0, columns - 1)) * spacing
        let contentHeight = CGFloat(rows) * cardSize.height + CGFloat(max(0, rows - 1)) * rowSpacing
        let panelWidth = contentWidth + padding * 2
        let panelHeight = min(contentHeight + padding * 2, max(cardSize.height + padding * 2, maxPanelHeight))

        var builtCards: [SwitcherCard] = []
        for (index, window) in windows.enumerated() {
            let card = SwitcherCard(
                window: window,
                thumbnail: thumbnails[window.id],
                onHover: { onHover(index) },
                onClick: { onClick(index) }
            )
            card.setFrameSize(cardSize)
            builtCards.append(card)
        }

        let grid = SwitcherGridView(
            cards: builtCards,
            columns: columns,
            cardSize: cardSize,
            spacing: spacing,
            rowSpacing: rowSpacing
        )
        grid.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)

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
        scroll.hasVerticalScroller = contentHeight + padding * 2 > panelHeight
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .allowed
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = grid

        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: padding),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -padding),
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: padding),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -padding),
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

private final class SwitcherGridView: NSView {
    private let cards: [SwitcherCard]
    private let columns: Int
    private let cardSize: NSSize
    private let spacing: CGFloat
    private let rowSpacing: CGFloat

    override var isFlipped: Bool { true }

    init(
        cards: [SwitcherCard],
        columns: Int,
        cardSize: NSSize,
        spacing: CGFloat,
        rowSpacing: CGFloat
    ) {
        self.cards = cards
        self.columns = columns
        self.cardSize = cardSize
        self.spacing = spacing
        self.rowSpacing = rowSpacing
        super.init(frame: .zero)

        for card in cards {
            addSubview(card)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let rows = Int(ceil(Double(cards.count) / Double(columns)))
        return NSSize(
            width: CGFloat(columns) * cardSize.width + CGFloat(max(0, columns - 1)) * spacing,
            height: CGFloat(rows) * cardSize.height + CGFloat(max(0, rows - 1)) * rowSpacing
        )
    }

    override func layout() {
        super.layout()

        for (index, card) in cards.enumerated() {
            let column = index % columns
            let row = index / columns
            card.frame = NSRect(
                x: CGFloat(column) * (cardSize.width + spacing),
                y: CGFloat(row) * (cardSize.height + rowSpacing),
                width: cardSize.width,
                height: cardSize.height
            )
        }
    }
}
