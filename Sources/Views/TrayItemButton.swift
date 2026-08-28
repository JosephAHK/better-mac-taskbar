import AppKit

/// Shared chrome for the labelled tray buttons (Downloads, Trash, Clock).
///
/// These sit at the right end of the bar and each show an icon with its name
/// beside it, so the layout, hover highlight and open-state tint live here rather
/// than being copy-pasted per button. Width is intrinsic — driven by the label —
/// so `TrayView` must not pin these to a square.
class TrayItemButtonView: NSView {
    var onToggle: (() -> Void)?

    var isOpen = false {
        didSet { refreshAppearance() }
    }

    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")

    private var tracking: NSTrackingArea?

    /// Matches TaskButtonView's labelled style so the tray reads as the same bar.
    static let labelFont = NSFont.systemFont(ofSize: 12)
    private static let horizontalPadding: CGFloat = 10
    private static let iconTextGap: CGFloat = 7
    private static let iconSize: CGFloat = 22

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = title

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = Self.labelFont
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.iconTextGap),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Hook for buttons whose icon reflects live state (Trash fullness).
    func refreshIcon() {}

    private func refreshAppearance() {
        if isOpen {
            layer?.backgroundColor = NSColor(calibratedRed: 0, green: 0.47, blue: 0.84, alpha: 1).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        refreshIcon()
        if !isOpen {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }
}
