import Cocoa

/// 一个只有描边的透明窗口，用来告诉用户「AI 现在指的是这一块」。
final class HighlightWindow: NSWindow {

    private let shape = HighlightView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = shape
    }

    func show(around rect: NSRect) {
        guard rect.width > 1, rect.height > 1 else { return }
        let padded = rect.insetBy(dx: -2, dy: -2)
        setFrame(padded, display: true)
        orderFront(nil)
    }

    func hide() {
        orderOut(nil)
    }
}

final class HighlightView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
