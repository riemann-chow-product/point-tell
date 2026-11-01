import Cocoa

/// 菜单栏图标 + 菜单
final class StatusBarController: NSObject, NSMenuDelegate {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    /// 权限那一条单独留个引用，菜单弹出前刷新它的文案。
    /// 之前文案只在 buildMenu() 里算一次，用户去系统设置里勾完回来，
    /// 菜单不重建就一直显示「未授权」，看着像授权没生效。
    private weak var accessItem: NSMenuItem?

    var onOpen: (() -> Void)?
    var onSettings: (() -> Void)?
    var onOnboarding: (() -> Void)?
    var onQuit: (() -> Void)?

    func setup() {
        if let button = item.button {
            button.image = StatusBarController.statusIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "\(AppInfo.name) · \(Settings.shared.hotkeyText)"
        }
        item.menu = buildMenu()
    }

    func refresh() {
        if let button = item.button {
            button.toolTip = "\(AppInfo.name) · \(Settings.shared.hotkeyText)"
        }
        item.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let open = NSMenuItem(title: "指哪改哪", action: #selector(openTapped), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let hint = NSMenuItem(title: "   快捷键 \(Settings.shared.hotkeyText)", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(NSMenuItem.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(settingsTapped), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // 每次重建都新建，不要复用同一个 NSMenuItem 实例：
        // 把已经属于某个菜单的 item 再 addItem 到新菜单会踩到 AppKit 的内部断言，
        // 表现为点保存后进程直接 SIGSEGV（-performClick: 里 rethrow 的 ObjC 异常）
        let access = NSMenuItem(title: Self.accessTitle(),
                                action: #selector(accessibilityTapped),
                                keyEquivalent: "")
        access.target = self
        menu.addItem(access)
        accessItem = access

        let guide = NSMenuItem(title: "使用说明", action: #selector(guideTapped), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)

        menu.addItem(NSMenuItem.separator())

        let about = NSMenuItem(title: "关于 \(AppInfo.name)", action: #selector(aboutTapped), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出", action: #selector(quitTapped), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private static func accessTitle() -> String {
        return AXIsProcessTrusted() ? "辅助功能权限：已授权" : "辅助功能权限：未授权（点此开启）"
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        accessItem?.title = Self.accessTitle()
    }

    @objc private func openTapped() { onOpen?() }
    @objc private func settingsTapped() { onSettings?() }
    @objc private func guideTapped() { onOnboarding?() }
    @objc private func quitTapped() { onQuit?() }

    @objc private func accessibilityTapped() {
        if AXIsProcessTrusted() {
            openAccessibilityPane()
            return
        }

        // 先走一次带 prompt 的检查：系统会把「当前这个签名的可执行文件」注册进
        // 辅助功能列表（并弹一次系统提示）。
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)

        // 这里要解释一个很容易踩的坑：列表里那条「PointTell 已勾选」可能是旧版本
        // 留下的记录。每次重新编译 cdhash 都会变，旧记录就对不上了，勾着也不生效。
        // 用户看到开关是开的，自然会觉得「我已经授权了」，然后卡在这里。
        let alert = NSAlert()
        alert.messageText = "如果列表里的 PointTell 已经是勾选状态"
        alert.informativeText = """
        那多半是旧版本留下的记录，勾了也不生效。

        请这样重来一次：
        1. 在「辅助功能」列表里选中 PointTell，点「−」移除
        2. 点「+」，选择下面这个文件：
           \(Bundle.main.bundlePath)
        3. 打开新出现的 PointTell 开关
        4. 回到菜单栏，重新打开本菜单确认变成「已授权」

        说明：应用重新编译后签名会变，系统会把它当成另一个程序，所以旧记录必须清掉。
        """
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "在 Finder 中显示")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openAccessibilityPane()
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        default:
            break
        }
    }

    private func openAccessibilityPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func aboutTapped() {
        let alert = NSAlert()
        alert.messageText = "\(AppInfo.name) \(AppInfo.version)"
        alert.informativeText = """
        \(AppInfo.tagline)

        光标指到哪，AI 就改哪。
        上下文只在你按下快捷键的那一刻抓取，且默认只发给本机模型。

        日志：/tmp/pointtell.log
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    static func statusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.black.setFill()
        NSColor.black.setStroke()

        // 一个「指过去」的箭头 + 一点火花
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 3.5, y: 16))
        arrow.line(to: NSPoint(x: 3.5, y: 3.5))
        arrow.line(to: NSPoint(x: 7.2, y: 7.2))
        arrow.line(to: NSPoint(x: 9.6, y: 2.4))
        arrow.line(to: NSPoint(x: 11.8, y: 3.4))
        arrow.line(to: NSPoint(x: 9.4, y: 8.2))
        arrow.line(to: NSPoint(x: 14.2, y: 8.2))
        arrow.close()
        arrow.fill()

        let spark = NSBezierPath()
        spark.lineWidth = 1.3
        spark.move(to: NSPoint(x: 13.5, y: 12.5))
        spark.line(to: NSPoint(x: 13.5, y: 15.5))
        spark.move(to: NSPoint(x: 12, y: 14))
        spark.line(to: NSPoint(x: 15, y: 14))
        spark.stroke()

        img.unlockFocus()
        img.isTemplate = true
        return img
    }
}
