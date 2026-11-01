import Cocoa

/// 把结果送回目标应用：剪贴板 + 合成 ⌘V。
/// 这条路径对所有编辑器（VS Code / Xcode / Excel / 浏览器）都成立，比直接写 AXValue 稳。
enum Paster {

    /// 自检用：只走完流程但不真的发 ⌘V，避免把测试文本粘进用户正在编辑的文档
    static var dryRun = false

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// 插入到目标应用的光标处（会覆盖目标应用里当前的选区）。
    /// `completion(false)` 表示没能切回目标应用 —— 这时**不发 ⌘V**，
    /// 否则会把内容粘到用户当前的前台应用里（比如终端），是数据事故。
    static func insert(_ text: String,
                       into app: NSRunningApplication?,
                       completion: ((Bool) -> Void)? = nil) {
        guard !text.isEmpty else { return }

        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        PTLog.write("paste: clipboard set, \(text.count) chars")

        guard let target = app, target.bundleIdentifier != AppInfo.bundleID else {
            PTLog.write("paste: no target app — 结果留在剪贴板，请手动 ⌘V")
            completion?(false)
            return
        }

        target.activate(options: [.activateIgnoringOtherApps])

        // 不能固定 sleep 一下就发 ⌘V：Sublime / Electron 这类应用激活慢，
        // 事件会打到还没让出焦点的窗口上。改成轮询等它真的到前台。
        waitUntilFrontmost(target, attemptsLeft: 40) { ok in
            guard ok else {
                PTLog.write("paste: target never became frontmost — 不发 ⌘V，结果留在剪贴板")
                completion?(false)
                return
            }
            sendCmdV()
            completion?(true)
            // 把用户原来的剪贴板还回去，别破坏工作流。
            // 留足时间给目标应用读完剪贴板（慢应用会读到还原后的旧内容）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let prev = previous {
                    let pb2 = NSPasteboard.general
                    pb2.clearContents()
                    pb2.setString(prev, forType: .string)
                }
            }
        }
    }

    /// 每 50ms 查一次，最多 2 秒
    private static func waitUntilFrontmost(_ target: NSRunningApplication,
                                           attemptsLeft: Int,
                                           then: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
            then(true)
            return
        }
        if attemptsLeft <= 0 {
            then(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitUntilFrontmost(target, attemptsLeft: attemptsLeft - 1, then: then)
        }
    }

    private static func sendCmdV() {
        if dryRun {
            PTLog.write("paste: [dry-run] would send cmd+v to \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09 // V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            PTLog.write("paste: failed to build CGEvent")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        PTLog.write("paste: sent cmd+v to \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    }
}
