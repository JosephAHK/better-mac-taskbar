import AppKit

/// Menu item that runs a closure. The context menus here are built fresh for each
/// click around one specific item, so a target/selector pair would need a throwaway
/// object per item anyway.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.image = image
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() {
        handler()
    }
}
