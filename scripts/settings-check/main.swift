import Cocoa

// 设置窗口自检：可编辑性 / 地址归一 / 测试连接（含成功、404、拒连、401、隐私拦截）/ 不落盘
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: .aqua)

let wc = SettingsWindowController.shared
wc.show()
guard let win = wc.window, let content = win.contentView else { print("NO WINDOW"); exit(1) }
content.layoutSubtreeIfNeeded()

func pump(_ s: TimeInterval) {
    let end = Date().addingTimeInterval(s)
    while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

func waitDone(_ timeout: TimeInterval) -> String {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        if !wc.dbgTesting() { return wc.dbgStatus() }
    }
    return "⚠️ 等待超时（客户端没回调）"
}

func runTest(_ timeout: TimeInterval = 15) {
    wc.dbgTestButton().performClick(nil)
    print("    → \(waitDone(timeout))")
}

func switchProvider(_ index: Int) {
    let p = wc.dbgProviderPopup()
    p.selectItem(at: index)
    _ = p.sendAction(p.action, to: p.target)
}

// ---------- 1. 可编辑性（真实键盘输入） ----------
print("=== 1. 输入框可编辑性 ===")
for (name, f) in wc.dbgControls().sorted(by: { $0.key < $1.key }) {
    win.makeFirstResponder(f)
    let gotFocus = win.firstResponder === f.currentEditor()
    let before = f.stringValue
    f.currentEditor()?.insertText("X")
    let typed = f.stringValue != before
    f.stringValue = before
    print(String(format: "  %-8@ editable=%@ selectable=%@ bezeled=%@ 焦点=%@ 键盘输入生效=%@",
                 name as NSString,
                 f.isEditable ? "Y" : "N",
                 f.isSelectable ? "Y" : "N",
                 f.isBezeled ? "Y" : "N",
                 gotFocus ? "Y" : "N",
                 typed ? "Y" : "N"))
}

// 字符上限只接受数字
wc.dbgSet(baseURL: "http://127.0.0.1:11500", model: "qwen2.5-coder:7b")
let ctx = wc.dbgControls()["context"]!
ctx.stringValue = "12ab00"
wc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: ctx))
print("  字符上限输入 '12ab00' → '\(ctx.stringValue)'")
ctx.stringValue = "1200"

// ---------- 2. 地址归一 / 实际请求预览 ----------
print("\n=== 2. 接口地址 → 实际请求 ===")
for c in ["127.0.0.1:11500", "http://127.0.0.1:11500/", "http://127.0.0.1:11500/api", "http://127.0.0.1:11500/api/chat"] {
    wc.dbgSet(baseURL: c)
    print("  \(c)\n    → \(wc.dbgEndpointText())")
}
switchProvider(1)
print("  -- 切到 OpenAI --")
for c in ["api.openai.com", "https://api.openai.com/v1", "https://api.openai.com/v1/chat/completions"] {
    wc.dbgSet(baseURL: c)
    print("  \(c)\n    → \(wc.dbgEndpointText())")
}
switchProvider(2)
print("  -- 切到 Anthropic --")
for c in ["api.anthropic.com",
          "https://api.lkeap.cloud.tencent.com/plan/anthropic",
          "https://api.lkeap.cloud.tencent.com/plan/anthropic/v1"] {
    wc.dbgSet(baseURL: c)
    print("  \(c)\n    → \(wc.dbgEndpointText())")
}

// ---------- 3. 测试连接 ----------
print("\n=== 3. 测试连接 ===")
switchProvider(0)
wc.dbgSetLocalOnly(true)
wc.dbgSet(baseURL: "http://127.0.0.1:11500", model: "qwen2.5-coder:7b")
print("  [A] 本地 Ollama 模拟服务（应成功）")
runTest()

wc.dbgSet(model: "missing")
print("  [B] 模型不存在（应 404 提示检查模型名）")
runTest()

wc.dbgSet(baseURL: "http://127.0.0.1:11499", model: "qwen2.5-coder:7b")
print("  [C] 端口没服务（应提示 Ollama 是否启动）")
runTest(20)

wc.dbgSet(baseURL: "http://127.0.0.1:11500", model: "")
print("  [D] 模型名为空（应就地拦下，不发请求）")
runTest(5)

wc.dbgSet(baseURL: "http://127.0.0.1:11500", model: "qwen2.5-coder:7b")
switchProvider(1)
wc.dbgSet(baseURL: "http://127.0.0.1:11500", model: "gpt-4o-mini", key: "sk-test")
wc.dbgSetLocalOnly(true)
print("  [E] OpenAI + 仅本地开启（应被隐私模式拦下）")
runTest(5)

wc.dbgSetLocalOnly(false)
print("  [F] OpenAI + 仅本地关闭 + 有 key（应成功）")
runTest()

wc.dbgSet(key: "bad-key")
print("  [G] OpenAI key 无效（应 401 提示检查 API Key）")
runTest()

switchProvider(2)
wc.dbgSetLocalOnly(false)
wc.dbgSet(baseURL: "http://127.0.0.1:11500/anthropic", model: "hy4-preview", key: "sk-test")
print("  [H] Anthropic 协议 + 有效 key（应成功，走 /v1/messages）")
runTest()

wc.dbgSet(key: "")
print("  [I] Anthropic 缺 key（应就地拦下，不发请求）")
runTest(5)

wc.dbgSet(key: "bad-key")
print("  [J] Anthropic key 无效（应 401）")
runTest()

switchProvider(1)
wc.dbgSet(baseURL: "https://api.lkeap.cloud.tencent.com/plan/anthropic", model: "hy4-preview", key: "sk-test")
print("  [K] OpenAI 来源 + /anthropic 地址（应被协议错配拦下）")
runTest(5)

// ---------- 4. 切来源不丢输入 ----------
print("\n=== 4. 切换来源是否丢输入 ===")
switchProvider(1)
wc.dbgSet(key: "sk-typed-but-not-saved")
switchProvider(0)
switchProvider(1)
print("  切走再切回后 key 字段 = '\(wc.dbgControls()["key"]!.stringValue)'")

// ---------- 5. 测试不该写盘 ----------
print("\n=== 5. 「测试连接」是否污染已保存配置 ===")
let d = UserDefaults.standard
let savedURL = d.string(forKey: "baseURL.ollama") ?? "(未设置=默认)"
let savedModel = d.string(forKey: "model.ollama") ?? "(未设置=默认)"
print("  测试前 defaults: baseURL=\(savedURL) model=\(savedModel)")
switchProvider(0)
wc.dbgSet(baseURL: "http://127.0.0.1:11500", model: "temp-model")
runTest(15)
let afterURL = d.string(forKey: "baseURL.ollama") ?? "(未设置=默认)"
let afterModel = d.string(forKey: "model.ollama") ?? "(未设置=默认)"
print("  测试后 defaults: baseURL=\(afterURL) model=\(afterModel)")
print("  结论：\(savedURL == afterURL && savedModel == afterModel ? "✅ 未写入" : "❌ 被写入")")

// ---------- 6. 截图 ----------
wc.dbgSet(baseURL: "http://127.0.0.1:11500", model: "qwen2.5-coder:7b")
runTest(15)
pump(0.3)
content.layoutSubtreeIfNeeded()
let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
content.cacheDisplay(in: content.bounds, to: rep)
if let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: "/tmp/settings_probe.png"))
    print("\nwrote /tmp/settings_probe.png \(Int(content.bounds.width))x\(Int(content.bounds.height))")
}
