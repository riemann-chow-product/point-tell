import Cocoa
import ApplicationServices

// MARK: - 上下文数据结构

/// 一次「指着某处」所捕获到的全部上下文。
struct CapturedContext {
    var appName: String = ""
    var bundleID: String = ""
    var pid: pid_t = 0
    var windowTitle: String = ""

    var role: String = ""
    var subrole: String = ""
    var elementTitle: String = ""
    var elementDescription: String = ""

    var value: String = ""
    var selectedText: String = ""
    var snippet: String = ""
    var ancestors: [String] = []
    var tablePreview: String = ""

    var elementFrame: NSRect?
    var isEditable: Bool = false
    var isSecure: Bool = false
    var capturedAt: Date = Date()

    var hasElement: Bool { return !role.isEmpty }

    var roleText: String { return friendlyRole(role) }

    /// 面板顶部那一行摘要（应用名已经在标题里了，这里只补充细节）
    var summaryLine: String {
        var parts: [String] = []
        if hasElement { parts.append(roleText) }
        if !windowTitle.isEmpty { parts.append(windowTitle.truncated(28)) }
        if !selectedText.isEmpty {
            parts.append("已选中 \(selectedText.count) 字")
        } else if !snippet.isEmpty {
            parts.append("上下文 \(snippet.count) 字")
        } else {
            parts.append("无可见文本")
        }
        return parts.joined(separator: " · ")
    }

    /// 给模型看的上下文块
    func promptBlock() -> String {
        var lines: [String] = []
        lines.append("【应用】\(appName.isEmpty ? "未知" : appName)")
        if !windowTitle.isEmpty { lines.append("【窗口】\(windowTitle)") }
        if hasElement {
            var roleLine = "【控件】\(role)"
            if !subrole.isEmpty { roleLine += " / \(subrole)" }
            if isEditable { roleLine += "（可编辑）" }
            lines.append(roleLine)
        }
        if !elementTitle.isEmpty { lines.append("【控件标题】\(elementTitle.truncated(120))") }
        if !elementDescription.isEmpty { lines.append("【控件描述】\(elementDescription.truncated(120))") }
        if !ancestors.isEmpty { lines.append("【层级】\(ancestors.joined(separator: " > "))") }
        if !selectedText.isEmpty {
            lines.append("【光标处已选中】")
            lines.append(selectedText)
        }
        if !snippet.isEmpty {
            lines.append("【光标附近内容】")
            lines.append(snippet)
        }
        if !tablePreview.isEmpty {
            lines.append("【所在表格片段】")
            lines.append(tablePreview)
        }
        if lines.count <= 1 && snippet.isEmpty {
            lines.append("（未捕获到具体文本，只能依据用户描述回答）")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - AX 底层读取

enum AX {

    /// 和单个应用通信的超时。
    ///
    /// 默认值是 6 秒：目标应用一旦无响应（Word 卡住、网页正在加载、Electron 假死），
    /// 每次 AX 调用都会**阻塞主线程**最多 6 秒。capture 里有几十次调用，
    /// 热键按下去面板能几十秒不出来 —— 用户会认为「热键坏了 / 程序卡死」。
    /// 超时设短，最坏情况也只是上下文抓少一点，绝不拖住界面。
    static let messagingTimeout: Float = 0.35

    /// 对元素所属的应用设置通信超时（per-app 生效，设一次就够）
    static func applyTimeout(_ el: AXUIElement) {
        AXUIElementSetMessagingTimeout(el, messagingTimeout)
    }

    static func copyAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, name as CFString, &v)
        return err == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        guard let v = copyAttr(el, name) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func bool(_ el: AXUIElement, _ name: String) -> Bool? {
        guard let v = copyAttr(el, name) else { return nil }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = copyAttr(el, name) else { return nil }
        guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXUIElement.self)
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        guard let v = copyAttr(el, kAXChildrenAttribute as String) else { return [] }
        guard CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        let arr = unsafeBitCast(v, to: CFArray.self)
        let count = CFArrayGetCount(arr)
        var out: [AXUIElement] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            if let raw = CFArrayGetValueAtIndex(arr, i) {
                out.append(unsafeBitCast(raw, to: AXUIElement.self))
            }
        }
        return out
    }

    /// 当前鼠标位置（CG 全局坐标，左上原点）下的控件
    static func elementUnderCursor() -> AXUIElement? {
        guard let loc = CGEvent(source: nil)?.location else { return nil }
        let system = AXUIElementCreateSystemWide()
        // 这一步同样要限时：跨进程查询在最坏情况下会等满超时
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var el: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(system, Float(loc.x), Float(loc.y), &el)
        guard err == .success, let found = el else { return nil }
        applyTimeout(found)
        return found
    }

    /// 控件在屏幕上的位置（NS 坐标，左下原点）
    static func frame(of el: AXUIElement) -> NSRect? {
        guard let posVal = copyAttr(el, kAXPositionAttribute as String),
              let sizeVal = copyAttr(el, kAXSizeAttribute as String) else { return nil }
        guard CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        let axPos = unsafeBitCast(posVal, to: AXValue.self)
        let axSize = unsafeBitCast(sizeVal, to: AXValue.self)
        guard AXValueGetValue(axPos, .cgPoint, &point),
              AXValueGetValue(axSize, .cgSize, &size) else { return nil }
        if size.width <= 0 || size.height <= 0 { return nil }
        // AX 是「全局左上原点」，NSWindow 是「本屏左下原点」。
        // 多显示器下不能一律用主屏高度换算，否则高亮框会跑到别的屏幕去。
        let anchor = CGPoint(x: point.x, y: point.y)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let maxY = screen?.frame.maxY ?? (NSScreen.screens.first?.frame.height ?? 0)
        return NSRect(x: point.x, y: maxY - point.y - size.height,
                      width: size.width, height: size.height)
    }

    static func selectedRange(of el: AXUIElement) -> NSRange? {
        guard let v = copyAttr(el, kAXSelectedTextRangeAttribute as String) else { return nil }
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        let axVal = unsafeBitCast(v, to: AXValue.self)
        guard AXValueGetValue(axVal, .cfRange, &range) else { return nil }
        if range.location == kCFNotFound || range.location < 0 { return nil }
        return NSRange(location: range.location, length: max(0, range.length))
    }

    /// 单元格 / 文本控件里真正显示的文字。
    /// `budget` 是访问节点数的硬上限：表格里一层就有几百个子节点，
    /// 不设限的话光这一段就能在主线程跑上好几秒。
    static func text(of el: AXUIElement, depth: Int = 0, budget: inout Int) -> String {
        if let v = string(el, kAXValueAttribute as String), !v.isEmpty { return v }
        if depth >= 3 { return "" }
        for child in children(el) {
            if budget <= 0 { return "" }
            budget -= 1
            let t = text(of: child, depth: depth + 1, budget: &budget)
            if !t.isEmpty { return t }
        }
        return ""
    }

    static func text(of el: AXUIElement) -> String {
        var budget = 60
        return text(of: el, depth: 0, budget: &budget)
    }
}

// MARK: - 上下文捕获

enum ContextCapture {

    /// 第一步：只做最少的 AX 调用（取元素 + 角色 + 位置），必须在主线程、且足够快。
    /// 面板能不能「一按就出来」取决于这里 —— 所以这里不做递归、不抓表格。
    static func probe() -> (CapturedContext, AXUIElement?) {
        var ctx = CapturedContext()
        ctx.capturedAt = Date()

        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != AppInfo.bundleID {
            ctx.appName = front.localizedName ?? ""
            ctx.bundleID = front.bundleIdentifier ?? ""
            ctx.pid = front.processIdentifier
        }

        guard AXIsProcessTrusted() else {
            PTLog.write("capture: accessibility not trusted")
            return (ctx, nil)
        }
        guard let el = AX.elementUnderCursor() else {
            PTLog.write("capture: no element under cursor")
            return (ctx, nil)
        }

        ctx.role = AX.string(el, kAXRoleAttribute as String) ?? ""
        ctx.subrole = AX.string(el, kAXSubroleAttribute as String) ?? ""
        ctx.elementTitle = AX.string(el, kAXTitleAttribute as String) ?? ""
        ctx.elementDescription = AX.string(el, kAXDescriptionAttribute as String) ?? ""
        ctx.isSecure = (ctx.subrole == "AXSecureTextField")
        ctx.elementFrame = AX.frame(of: el)
        // 只按角色判断可编辑性：问系统 AXEditable 要走一次 IPC，能省则省
        ctx.isEditable = ctx.role == "AXTextArea" || ctx.role == "AXTextField" || ctx.role == "AXComboBox"

        // 悬停所在的进程可能和 frontmost 不同（比如面板已经抢焦点）
        if let pidEl = pidOf(el) {
            ctx.pid = pidEl
            if let app = NSRunningApplication(processIdentifier: pidEl) {
                ctx.appName = app.localizedName ?? ctx.appName
                ctx.bundleID = app.bundleIdentifier ?? ctx.bundleID
            }
        }
        return (ctx, el)
    }

    /// 第二步：把上下文补全（窗口标题 / 值 / 选区 / 层级 / 表格）。
    /// 这一步可能耗时（目标应用慢时单次调用就能等满 0.35s），所以放后台跑。
    /// 用 `notify` 回调回主线程，由调用方判断「这次结果还该不该用」。
    static func enrich(_ el: AXUIElement,
                       from base: CapturedContext,
                       completion: @escaping (CapturedContext) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var ctx = base

            // 窗口标题
            if let win = AX.element(el, kAXWindowAttribute as String),
               let t = AX.string(win, kAXTitleAttribute as String), !t.isEmpty {
                ctx.windowTitle = t
            }

            let rawValue = AX.string(el, kAXValueAttribute as String) ?? ""
            let selRange = AX.selectedRange(of: el)
            let selText = AX.string(el, kAXSelectedTextAttribute as String) ?? ""

            ctx.value = rawValue
            ctx.selectedText = selText
            ctx.isEditable = ctx.isEditable || detectEditable(el, role: ctx.role)

            let limit = max(200, Settings.shared.maxContextChars)
            ctx.snippet = makeSnippet(value: rawValue, selection: selRange, limit: limit)

            // 拿不到值时退一步：子节点文本 / 标题
            if ctx.snippet.isEmpty && ctx.selectedText.isEmpty {
                let childText = AX.text(of: el)
                if !childText.isEmpty {
                    ctx.snippet = makeSnippet(value: childText, selection: nil, limit: limit)
                } else if !ctx.elementTitle.isEmpty {
                    ctx.snippet = ctx.elementTitle.truncated(limit)
                }
            }

            ctx.ancestors = ancestorChain(el)
            if Settings.shared.includeTableContext {
                ctx.tablePreview = tablePreview(from: el)
            }

            PTLog.write("capture: app=\(ctx.appName) role=\(ctx.role) snippetLen=\(ctx.snippet.count) tableLen=\(ctx.tablePreview.count)")
            DispatchQueue.main.async { completion(ctx) }
        }
    }

    /// 老入口：同步抓全量上下文。自检和命令行里还用得上，主流程走 probe + enrich。
    static func capture() -> CapturedContext {
        let (base, maybeEl) = probe()
        guard let element = maybeEl else { return base }
        // enrich 会把结果切回主线程；在主线程等它就是死锁，直接返回探测到的部分
        if Thread.isMainThread { return base }
        var out = base
        let sem = DispatchSemaphore(value: 0)
        enrich(element, from: base) { ctx in
            out = ctx
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        return out
    }

    // MARK: 细节

    private static func pidOf(_ el: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        if AXUIElementGetPid(el, &pid) == .success, pid > 0 { return pid }
        return nil
    }

    private static func detectEditable(_ el: AXUIElement, role: String) -> Bool {
        if role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox" { return true }
        if let e = AX.bool(el, "AXEditable"), e { return true }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        return false
    }

    /// 从光标/选区附近截一段，而不是把整个文档塞给模型
    private static func makeSnippet(value: String, selection: NSRange?, limit: Int) -> String {
        if value.isEmpty { return "" }
        let ns = value as NSString
        if ns.length <= limit { return value }

        guard let sel = selection, sel.location != NSNotFound, sel.location <= ns.length, sel.location > 0 else {
            return ns.substring(to: limit) + "…"
        }

        let pad = limit / 3
        var start = max(0, sel.location - pad)
        var end = min(ns.length, start + limit)
        if end - start < limit { start = max(0, end - limit) }

        // 尽量对齐到行首/行尾，读起来更像一段完整代码
        let prefixRange = ns.range(of: "\n", options: .backwards,
                                   range: NSRange(location: 0, length: start))
        if prefixRange.location != NSNotFound { start = prefixRange.location + 1 }
        let tailRange = ns.range(of: "\n", options: [],
                                 range: NSRange(location: end, length: ns.length - end))
        if tailRange.location != NSNotFound { end = tailRange.location }

        if end <= start { return value.truncated(limit) }
        var out = ns.substring(with: NSRange(location: start, length: end - start))
        if start > 0 { out = "…\n" + out }
        if end < ns.length { out += "\n…" }
        return out
    }

    private static func ancestorChain(_ el: AXUIElement) -> [String] {
        var chain: [String] = []
        var current: AXUIElement? = AX.element(el, kAXParentAttribute as String)
        var depth = 0
        while let c = current, depth < 5 {
            let role = AX.string(c, kAXRoleAttribute as String) ?? ""
            if role.isEmpty { break }
            var label = friendlyRole(role)
            if let t = AX.string(c, kAXTitleAttribute as String), !t.isEmpty {
                label += "(\(t.truncated(24)))"
            }
            chain.append(label)
            current = AX.element(c, kAXParentAttribute as String)
            depth += 1
        }
        return chain.reversed()
    }

    /// 「指着表格问数据」的关键：把表头 + 当前行抓出来
    private static func tablePreview(from el: AXUIElement) -> String {
        var current: AXUIElement? = el
        var table: AXUIElement?
        var depth = 0
        while let c = current, depth < 7 {
            let role = AX.string(c, kAXRoleAttribute as String) ?? ""
            if role == "AXTable" || role == "AXGrid" || role == "AXOutline" {
                table = c
                break
            }
            current = AX.element(c, kAXParentAttribute as String)
            depth += 1
        }
        guard let t = table else { return "" }

        let rows = AX.children(t).filter {
            (AX.string($0, kAXRoleAttribute as String) ?? "") == "AXRow"
        }
        if rows.isEmpty { return "" }

        // 当前行索引
        // 注意：AX 每次返回的都是新的 CF 包装对象，`===` 永远不相等，
        // 必须用 CFEqual 比较底层元素身份，否则当前行永远定位到第 0 行。
        var currentRowIndex = 0
        var probe: AXUIElement? = el
        var guard1 = 0
        while let p = probe, guard1 < 7 {
            if (AX.string(p, kAXRoleAttribute as String) ?? "") == "AXRow" {
                if let idx = rows.firstIndex(where: { CFEqual($0, p) }) {
                    currentRowIndex = idx
                }
                break
            }
            probe = AX.element(p, kAXParentAttribute as String)
            guard1 += 1
        }

        func rowValues(_ row: AXUIElement) -> [String] {
            var out: [String] = []
            for cell in AX.children(row).prefix(10) {
                out.append(AX.text(of: cell).replacingOccurrences(of: "\n", with: " ").truncated(24))
            }
            return out
        }

        var lines: [String] = []
        if let header = rows.first {
            let vals = rowValues(header)
            if !vals.isEmpty { lines.append("表头: " + vals.joined(separator: " | ")) }
        }
        if currentRowIndex > 0 && currentRowIndex < rows.count {
            let vals = rowValues(rows[currentRowIndex])
            if !vals.isEmpty { lines.append("当前行: " + vals.joined(separator: " | ")) }
        }
        // 上下一行，给趋势判断一点参照
        if currentRowIndex + 1 < rows.count {
            let vals = rowValues(rows[currentRowIndex + 1])
            if !vals.isEmpty { lines.append("下一行: " + vals.joined(separator: " | ")) }
        }
        return lines.joined(separator: "\n")
    }
}
