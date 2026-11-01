import Cocoa

// 离屏渲染面板示意（不需要录屏权限）。
// 用法：./scripts/render-preview.sh

let previewApp = NSApplication.shared
previewApp.setActivationPolicy(.accessory)
previewApp.appearance = NSAppearance(named: .aqua)

struct Mock {
    let context: CapturedContext
    let mode: EditMode
    let input: String
    let result: String
    let monospaced: Bool
}

func mockCode() -> Mock {
    var c = CapturedContext()
    c.appName = "Visual Studio Code"
    c.role = "AXTextArea"
    c.windowTitle = "order_service.py"
    c.isEditable = true
    c.snippet = """
    def create_order(user_id, items):
        total = 0
        for it in items:
            total += it["price"] * it["qty"]
        return db.insert("orders", {"user": user_id, "total": total})
    """
    c.ancestors = ["窗口(order_service.py)", "容器", "文本区域"]
    return Mock(
        context: c,
        mode: .rewrite,
        input: "给这个函数加参数校验",
        result: """
        def create_order(user_id, items):
            if not isinstance(user_id, int) or user_id <= 0:
                raise ValueError("user_id must be a positive int")
            if not items:
                raise ValueError("items must not be empty")
            total = 0
            for it in items:
                total += it["price"] * it["qty"]
            return db.insert("orders", {"user": user_id, "total": total})
        """,
        monospaced: true
    )
}

func mockTable() -> Mock {
    var c = CapturedContext()
    c.appName = "Microsoft Excel"
    c.role = "AXCell"
    c.windowTitle = "2026Q1-区域销售.xlsx"
    c.tablePreview = """
    表头: 区域 | 1月 | 2月 | 3月
    当前行: 华东 | 1,280 | 1,450 | 1,390
    下一行: 华南 | 980 | 1,120 | 1,260
    """
    c.snippet = "华东"
    return Mock(
        context: c,
        mode: .ask,
        input: "这块的环比趋势怎么样",
        result: "华东 1→2 月 +13.3%，2→3 月 -4.1%，整体先涨后回落；\n华南则连续两月上升（+14.3%、+12.5%），趋势相反。",
        monospaced: false
    )
}

func render(_ mock: Mock, to path: String, panelDark: Bool = false, backdropDark: Bool? = nil) {
    let backDark = backdropDark ?? panelDark
    let card = OverlayCardView(frame: NSRect(x: 0, y: 0, width: OverlayCardView.width, height: 200))
    card.update(context: mock.context, mode: mock.mode, appIconImage: nil)
    card.setSuggestions(PromptBuilder.suggestions(mode: mock.mode, context: mock.context))
    card.setMode(mock.mode)
    card.inputView.string = mock.input
    if !mock.result.isEmpty {
        card.setPlainResult(mock.result, monospaced: mock.monospaced)
    }

    let h = card.preferredHeight()
    // 用和真实面板一样的路径切外观：整卡（含 panel）一起换
    card.applyBackdrop(dark: panelDark)
    card.background.isHidden = true   // 离屏渲染画不出毛玻璃，用容器底色代替
    card.frame = NSRect(x: 20, y: 20, width: OverlayCardView.width, height: h)

    let container = NSView(frame: NSRect(x: 0, y: 0, width: OverlayCardView.width + 40, height: h + 40))
    container.wantsLayer = true
    container.appearance = NSAppearance(named: panelDark ? .darkAqua : .aqua)
    // 模拟「面板背后是什么」：深色主题编辑器 vs 浅色文档
    container.layer?.backgroundColor = backDark
        ? NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        : NSColor(calibratedWhite: 0.90, alpha: 1).cgColor

    container.addSubview(card)

    container.layoutSubtreeIfNeeded()
    card.layoutSubtreeIfNeeded()
    // 结果区高度要按「布局后的真实宽度」量一次
    if card.fitResultHeight() {
        let nh = card.preferredHeight()
        card.frame = NSRect(x: 20, y: 20, width: OverlayCardView.width, height: nh)
        container.frame = NSRect(x: 0, y: 0, width: OverlayCardView.width + 40, height: nh + 40)
        container.layoutSubtreeIfNeeded()
        card.layoutSubtreeIfNeeded()
    }
    card.resultView.scrollToBeginningOfDocument(nil)
    card.displayIfNeeded()
    container.displayIfNeeded()

    guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
    container.cacheDisplay(in: container.bounds, to: rep)

    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)  \(Int(card.frame.width))x\(Int(h))  panelDark=\(panelDark) backdropDark=\(backDark)")
}

render(mockCode(), to: "demo/preview-rewrite.png")
render(mockTable(), to: "demo/preview-ask.png")

let base = mockCode()
let idle = Mock(context: base.context, mode: base.mode, input: "", result: "", monospaced: true)
render(idle, to: "demo/preview-idle.png")

// 配色自适应：深色界面 → 深色面板，浅色界面 → 浅色面板
render(mockCode(), to: "demo/preview-rewrite-dark.png", panelDark: true)
render(mockTable(), to: "demo/preview-ask-dark.png", panelDark: true)

// 兜底：没屏幕录制权限时面板仍跟随系统（浅色），但背后是深色编辑器 ——
// 这就是「文字看不清」的原始场景，靠底衬把对比度拉回来
render(mockCode(), to: "demo/preview-fallback-darkbg.png", panelDark: false, backdropDark: true)
