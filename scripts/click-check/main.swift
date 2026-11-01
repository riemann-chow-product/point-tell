import Cocoa

// v4：验证 first-mouse 语义
// 问题：应用未激活时点击窗口，第一下只激活、不派发 → 「点保存没动静」
// acceptsFirstMouse 是唯一的解药，所以要确认它到底返回什么

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: .aqua)

let wc = SettingsWindowController.shared
wc.show()
guard let win = wc.window, let content = win.contentView else { print("NO WINDOW"); exit(1) }
content.layoutSubtreeIfNeeded()

func findButton(_ title: String) -> NSButton? {
    func walk(_ v: NSView) -> NSButton? {
        if let b = v as? NSButton, b.title == title { return b }
        for sub in v.subviews { if let r = walk(sub) { return r } }
        return nil
    }
    return walk(content)
}

guard let save = findButton("保存") else { print("❌"); exit(1) }

let r = save.convert(save.bounds, to: nil)
let pt = NSPoint(x: r.midX, y: r.midY)
let now = ProcessInfo.processInfo.systemUptime
let down = NSEvent.mouseEvent(with: .leftMouseDown, location: pt, modifierFlags: [],
                              timestamp: now, windowNumber: win.windowNumber, context: nil,
                              eventNumber: 0, clickCount: 1, pressure: 1)!

print("=== first-mouse 语义 ===")
print("  按钮类 = \(type(of: save))")
print("  acceptsFirstMouse(for: nil)   = \(save.acceptsFirstMouse(for: nil))")
print("  acceptsFirstMouse(for: event) = \(save.acceptsFirstMouse(for: down))")

let hitView = content.hitTest(content.convert(pt, from: nil))
print("  hitTest 视图 = \(hitView.map { String(describing: type(of: $0)) } ?? "nil")")
print("  hitView.acceptsFirstMouse(for: event) = \(hitView?.acceptsFirstMouse(for: down) as Any)")

print("\n=== 视图链上每一层的 first-mouse 态度 ===")
var v: NSView? = hitView
while let cur = v {
    print(String(format: "  %-28@ acceptsFirstMouse=%@", String(describing: type(of: cur)) as NSString,
                 cur.acceptsFirstMouse(for: down) ? "YES" : "NO"))
    v = cur.superview
}

print("\n=== 窗口状态 ===")
print("  isKeyWindow=\(win.isKeyWindow) canBecomeKey=\(win.canBecomeKey) isMain=\(win.isMainWindow)")
print("  acceptsMouseMovedEvents=\(win.acceptsMouseMovedEvents)")
print("  contentView 类 = \(type(of: content))")

// 模拟「应用未激活」下 sendEvent 的行为差异
print("\n=== 应用激活状态 ===")
print("  NSApp.isActive = \(NSApp.isActive)")
print("  NSApp.activationPolicy = \(NSApp.activationPolicy().rawValue)  (0=regular 1=accessory 2=prohibited)")
