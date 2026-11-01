import Cocoa
import Carbon

// MARK: - 日志

enum PTLog {
    private static let path = "/tmp/pointtell.log"
    private static let queue = DispatchQueue(label: "pointtell.log")

    static func write(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        queue.async {
            append(line)
        }
    }

    /// 崩溃前用：同步写，避免异步队列没来得及落盘就没了
    static func writeSync(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        queue.sync { append(line) }
    }

    private static func append(_ line: String) {
        if let data = line.data(using: .utf8) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    /// ObjC 异常在 Swift 里抓不到，会直接 unwind 成 SIGSEGV。
    /// 装这个处理器，至少能把 name/reason 留下来，不然只有一个空白的崩溃报告。
    static func installExceptionLogger() {
        // C 函数指针不能捕获上下文，所以走全局函数
        NSSetUncaughtExceptionHandler { exception in
            ptLogCrash("UNCAUGHT EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "(no reason)")")
            ptLogCrash("stack:\n    " + exception.callStackSymbols.prefix(18).joined(separator: "\n    "))
        }
    }
}

/// 崩溃路径专用：同步落盘，并顺手把异步队列里没写完的日志刷出去
private func ptLogCrash(_ text: String) {
    PTLog.writeSync(text)
}

// MARK: - 字符串工具

extension String {
    var trimmed: String {
        return trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func truncated(_ limit: Int) -> String {
        if count <= limit { return self }
        let idx = index(startIndex, offsetBy: limit)
        return String(self[..<idx]) + "…"
    }
}

// MARK: - AX 角色 → 人话

func friendlyRole(_ role: String) -> String {
    switch role {
    case "AXTextArea": return "文本区域"
    case "AXTextField": return "输入框"
    case "AXStaticText": return "文本"
    case "AXCell": return "表格单元格"
    case "AXRow": return "表格行"
    case "AXTable", "AXGrid", "AXOutline": return "表格"
    case "AXButton": return "按钮"
    case "AXLink": return "链接"
    case "AXWebArea": return "网页"
    case "AXImage": return "图片"
    case "AXComboBox": return "下拉框"
    case "AXMenuItem": return "菜单项"
    case "AXScrollArea": return "滚动区域"
    case "AXGroup": return "容器"
    case "AXWindow": return "窗口"
    default: return role.isEmpty ? "未知控件" : role
    }
}

// MARK: - 快捷键显示

func hotkeyDisplayString(keyCode: UInt32, carbonModifiers: UInt32) -> String {
    var s = ""
    if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
    if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
    if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
    if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }

    let map: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 32: "U", 34: "I", 31: "O", 35: "P",
        37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9", 29: "0",
        49: "空格", 36: "回车"
    ]
    s += map[keyCode] ?? "?"
    return s
}

// MARK: - 通用 UI 小工具

func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = NSFont.systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    l.drawsBackground = false
    return l
}

func makeFlatButton(_ title: String, size: CGFloat = 12) -> NSButton {
    let b = NSButton(title: title, target: nil, action: nil)
    b.isBordered = false
    b.font = NSFont.systemFont(ofSize: size, weight: .medium)
    b.contentTintColor = NSColor.controlAccentColor
    return b
}

/// 非活动窗口里第一次点击就能生效的按钮。
/// 默认的 NSButton 在窗口不是 key window 时会吞掉这一下（只激活窗口），
/// 表现为「点了没反应」，必须再点一次——设置窗口里这很容易被当成 bug。
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

/// 会记日志的窗口：鼠标事件到底有没有进到窗口，靠它一句话说清。
/// 「点了没反应」只有三种可能，日志能一次区分：
///   1. 完全没有 sendEvent 记录 → 事件被系统吞了（应用未激活 / 被别的窗口挡住）
///   2. 有记录但 hit=nil 或不是按钮 → 点到了别的东西
///   3. 有记录且 hit 是按钮 → 按钮的 target/action 有问题
final class DiagnosticWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let hit = contentView?.hitTest(event.locationInWindow)
            PTLog.write("win.event down at \(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y)) "
                + "hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") "
                + "key=\(isKeyWindow) active=\(NSApp.isActive)")
        case .leftMouseUp:
            PTLog.write("win.event up key=\(isKeyWindow)")
        default:
            break
        }
        super.sendEvent(event)
    }
}
