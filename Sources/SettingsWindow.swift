import Cocoa
import Carbon
import Security

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {

    static let shared = SettingsWindowController()

    private enum StatusKind {
        case info, success, warning, error
    }

    // 控件
    private var providerPopup: NSPopUpButton!
    private var baseURLField: NSTextField!
    private var modelField: NSTextField!
    private var keyField: NSSecureTextField!
    private var endpointLabel: NSTextField!
    private var localOnlyCheck: NSButton!
    private var tableCheck: NSButton!
    private var autoApplyCheck: NSButton!
    private var speechPopup: NSPopUpButton!
    private var themePopup: NSPopUpButton!
    private var themeHint: NSTextField!
    private var themeAuthButton: NSButton!
    private var contextField: NSTextField!
    private var hotkeyPopup: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var testButton: NSButton!
    private var spinner: NSProgressIndicator!

    private var built = false
    private var editingProvider: LLMProvider = .ollama
    private var testing = false
    private var testClient: LLMClient?
    private var probe: LLMProbe?
    private var keyMonitor: Any?

    // 未保存的草稿：切来切去不丢输入，也不落盘
    private var draftBaseURL: [LLMProvider: String] = [:]
    private var draftModel: [LLMProvider: String] = [:]
    private var draftKey: [LLMProvider: String] = [:]

    private let hotkeyPresets: [(String, UInt32, UInt32)] = [
        ("⌃⌥P", 35, UInt32(controlKey | optionKey)),
        ("⌃⌥空格", 49, UInt32(controlKey | optionKey)),
        ("⌥⌘P", 35, UInt32(optionKey | cmdKey)),
        ("⌃⇧空格", 49, UInt32(controlKey | shiftKey))
    ]

    // MARK: - 显示

    func show() {
        buildIfNeeded()
        reloadFields()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        // accessory 应用第一次 activate 偶尔不生效，补一次；
        // 否则窗口看起来在前台，其实不是 key，第一次点击只用来激活、按钮收不到
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self, let w = self.window, w.isVisible else { return }
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if !w.isKeyWindow { w.makeKeyAndOrderFront(nil) }
            PTLog.write("settings: shown key=\(w.isKeyWindow) active=\(NSApp.isActive)")
        }

        installKeyMonitor()
    }

    /// ⌘S 也能保存——按钮万一被系统吞掉一次，用户还有第二条路
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            let isS = event.charactersIgnoringModifiers?.lowercased() == "s"
            if event.modifierFlags.contains(.command), isS {
                self.saveAndClose()
                return nil
            }
            return event
        }
    }

    private func buildIfNeeded() {
        if built { return }

        let width: CGFloat = 600
        let window = DiagnosticWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 520),
                                      styleMask: [.titled, .closable],
                                      backing: .buffered,
                                      defer: false)
        window.title = "PointTell 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 520))
        window.contentView = content
        let inner = width - 48

        // ---- 控件 ----
        providerPopup = makePopup(LLMProvider.allCases.map { $0.displayName })
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)

        baseURLField = makeField("http://127.0.0.1:11434")
        modelField = makeField("qwen2.5-coder:7b")
        keyField = NSSecureTextField(string: "")
        keyField.font = NSFont.systemFont(ofSize: 12.5)
        keyField.isEditable = true
        keyField.isSelectable = true
        keyField.isEnabled = true
        keyField.isBezeled = true
        keyField.bezelStyle = .squareBezel
        keyField.placeholderString = "留空即可（本地 Ollama 不需要）"
        keyField.delegate = self
        keyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        keyField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        endpointLabel = makeLabel("", size: 11, color: .secondaryLabelColor)
        endpointLabel.lineBreakMode = .byTruncatingMiddle

        localOnlyCheck = NSButton(checkboxWithTitle: "仅本地运行（禁止任何出网请求）", target: self, action: #selector(localOnlyToggled))
        tableCheck = NSButton(checkboxWithTitle: "抓取表格表头 + 当前行（指着 Excel 问数据时有用）", target: nil, action: nil)
        autoApplyCheck = NSButton(checkboxWithTitle: "生成完自动粘贴回光标处", target: nil, action: nil)

        speechPopup = makePopup(["中文（普通话）", "English (US)"])
        speechPopup.widthAnchor.constraint(equalToConstant: 190).isActive = true

        themePopup = makePopup(PanelTheme.allCases.map { $0.displayName })
        themePopup.widthAnchor.constraint(equalToConstant: 190).isActive = true
        themePopup.target = self
        themePopup.action = #selector(themeChanged)

        themeHint = makeLabel("", size: 11, color: .tertiaryLabelColor)
        themeHint.lineBreakMode = .byWordWrapping
        themeHint.maximumNumberOfLines = 2
        themeHint.preferredMaxLayoutWidth = width - 48

        themeAuthButton = makeFlatButton("授权屏幕录制", size: 11)
        themeAuthButton.target = self
        themeAuthButton.action = #selector(requestScreenPermission)

        let themeRow = NSStackView(views: [themePopup, themeAuthButton, themeHint])
        themeRow.orientation = .horizontal
        themeRow.spacing = 10
        themeRow.alignment = .centerY

        contextField = makeField("1200")
        contextField.alignment = .right
        contextField.delegate = self
        contextField.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let contextHint = makeLabel("字（200–8000）", size: 11, color: .tertiaryLabelColor)
        let contextRow = NSStackView(views: [contextField, contextHint])
        contextRow.orientation = .horizontal
        contextRow.spacing = 8
        contextRow.alignment = .centerY

        hotkeyPopup = makePopup(hotkeyPresets.map { $0.0 })
        hotkeyPopup.widthAnchor.constraint(equalToConstant: 130).isActive = true

        providerPopup.widthAnchor.constraint(equalToConstant: 190).isActive = true

        // ---- 行 ----
        let rows: [NSView] = [
            row("模型来源", providerPopup, stretch: false),
            row("接口地址", baseURLField),
            row("实际请求", endpointLabel),
            row("模型名", modelField),
            row("API Key", keyField),
            row("", localOnlyCheck, stretch: false),
            row("", tableCheck, stretch: false),
            row("", autoApplyCheck, stretch: false),
            row("语音语言", speechPopup, stretch: false),
            row("面板配色", themeRow),
            row("上下文字符上限", contextRow, stretch: false),
            row("全局快捷键", hotkeyPopup, stretch: false)
        ]

        let vstack = NSStackView(views: rows)
        vstack.orientation = .vertical
        vstack.alignment = .leading
        vstack.spacing = 11
        vstack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(vstack)
        for r in rows {
            r.widthAnchor.constraint(equalTo: vstack.widthAnchor).isActive = true
        }

        // ---- 状态 / 说明 ----
        statusLabel = makeLabel("", size: 11, color: .secondaryLabelColor)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = width - 48
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let note = makeLabel("上下文只在按下快捷键时抓取，不会持续监听屏幕。",
                             size: 11, color: .tertiaryLabelColor)
        note.translatesAutoresizingMaskIntoConstraints = false

        // ---- 底部 ----
        let presetButton = FirstMouseButton(title: "地址预设…", target: self, action: #selector(showPresets))
        presetButton.isBordered = false
        presetButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        presetButton.contentTintColor = NSColor.controlAccentColor
        presetButton.translatesAutoresizingMaskIntoConstraints = false

        testButton = FirstMouseButton(title: "测试连接", target: self, action: #selector(testConnection))
        testButton.bezelStyle = .rounded
        testButton.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = FirstMouseButton(title: "保存", target: self, action: #selector(saveAndClose))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.toolTip = "保存（回车 / ⌘S）"
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(presetButton)
        footer.addSubview(spinner)
        footer.addSubview(testButton)
        footer.addSubview(saveButton)
        content.addSubview(footer)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        note.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)
        content.addSubview(note)

        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            vstack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            vstack.widthAnchor.constraint(equalToConstant: inner),

            statusLabel.topAnchor.constraint(equalTo: vstack.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            statusLabel.widthAnchor.constraint(equalToConstant: inner),
            statusLabel.heightAnchor.constraint(equalToConstant: 44),

            note.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            note.widthAnchor.constraint(lessThanOrEqualToConstant: inner),

            footer.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 14),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            footer.widthAnchor.constraint(equalToConstant: inner),
            footer.heightAnchor.constraint(equalToConstant: 30),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),

            presetButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            presetButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            saveButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            saveButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            testButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            testButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            spinner.trailingAnchor.constraint(equalTo: testButton.leadingAnchor, constant: -6),
            spinner.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14)
        ])

        built = true

        // 让窗口高度跟着内容走，避免底部控件被裁掉
        content.layoutSubtreeIfNeeded()
        let needed = content.fittingSize.height
        window.setContentSize(NSSize(width: width, height: max(needed, 460)))
        content.layoutSubtreeIfNeeded()
    }

    // MARK: - 控件工厂

    private func makeField(_ placeholder: String) -> NSTextField {
        let f = NSTextField(string: "")
        f.placeholderString = placeholder
        f.font = NSFont.systemFont(ofSize: 12.5)
        f.isEditable = true
        f.isSelectable = true
        f.isEnabled = true
        f.isBezeled = true
        f.bezelStyle = .squareBezel
        f.drawsBackground = true
        f.usesSingleLineMode = true
        f.lineBreakMode = .byTruncatingTail
        f.delegate = self
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    private func makePopup(_ items: [String]) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: items)
        p.controlSize = .regular
        p.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return p
    }

    private func label(_ text: String) -> NSTextField {
        let l = makeLabel(text, size: 12, color: .secondaryLabelColor)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 104).isActive = true
        return l
    }

    private func row(_ title: String, _ control: NSView, stretch: Bool = true) -> NSView {
        var views: [NSView] = [label(title), control]
        if !stretch {
            // 不需要拉伸的控件（下拉框、复选框）后面放一块弹性空白，避免被 stack 撑满整行
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            views.append(spacer)
        }
        let h = NSStackView(views: views)
        h.orientation = .horizontal
        h.spacing = 14
        h.alignment = .centerY
        h.distribution = .fill
        h.translatesAutoresizingMaskIntoConstraints = false
        return h
    }

    // MARK: - 读写

    private func reloadFields() {
        let s = Settings.shared
        draftBaseURL.removeAll()
        draftModel.removeAll()
        draftKey.removeAll()

        editingProvider = s.provider
        providerPopup.selectItem(at: LLMProvider.allCases.firstIndex(of: s.provider) ?? 0)

        baseURLField.stringValue = s.baseURL(for: s.provider)
        modelField.stringValue = s.model(for: s.provider)
        keyField.stringValue = s.apiKey
        keyField.placeholderString = keyPlaceholder(for: s.provider)

        localOnlyCheck.state = s.localOnly ? .on : .off
        tableCheck.state = s.includeTableContext ? .on : .off
        autoApplyCheck.state = s.autoApply ? .on : .off
        speechPopup.selectItem(at: s.speechLocale.hasPrefix("en") ? 1 : 0)
        themePopup.selectItem(at: PanelTheme.allCases.firstIndex(of: s.panelTheme) ?? 0)
        refreshThemeHint()
        contextField.stringValue = "\(s.maxContextChars)"

        if let idx = hotkeyPresets.firstIndex(where: {
            $0.1 == s.hotkeyKeyCode && $0.2 == s.hotkeyModifiers
        }) {
            hotkeyPopup.selectItem(at: idx)
        } else {
            hotkeyPopup.selectItem(at: 0)
        }

        refreshEndpointPreview()
        setStatus("", kind: .info)
    }

    private func stashCurrentFields() {
        draftBaseURL[editingProvider] = baseURLField.stringValue.trimmed
        draftModel[editingProvider] = modelField.stringValue.trimmed
        draftKey[editingProvider] = keyField.stringValue.trimmed
    }

    private func loadFields(for p: LLMProvider) {
        let s = Settings.shared
        baseURLField.stringValue = draftBaseURL[p] ?? s.baseURL(for: p)
        modelField.stringValue = draftModel[p] ?? s.model(for: p)
        keyField.stringValue = draftKey[p] ?? Keychain.get(account: p.rawValue)
        keyField.placeholderString = keyPlaceholder(for: p)
        refreshEndpointPreview()
    }

    private func keyPlaceholder(for p: LLMProvider) -> String {
        switch p {
        case .ollama: return "留空即可（本地 Ollama 不需要）"
        case .openAI: return "sk-…（云端必填）"
        case .anthropic: return "sk-…（必填，按 x-api-key 发送）"
        }
    }

    /// 返回非 nil 表示有需要用户知道的问题（目前只有钥匙串写入失败）
    private func commit() -> String? {
        stashCurrentFields()
        let s = Settings.shared
        var keyProblem: String?

        PTLog.write("commit: start")

        // 一次保存改十几项，包成一批只发一次变更通知
        s.batch {
            for (p, v) in draftBaseURL { s.setBaseURL(v, for: p) }
            for (p, v) in draftModel { s.setModel(v, for: p) }
            for (p, v) in draftKey {
                if let problem = Keychain.set(v, account: p.rawValue) {
                    keyProblem = problem
                }
            }

            s.provider = editingProvider
            s.localOnly = localOnlyCheck.state == .on
            s.includeTableContext = tableCheck.state == .on
            s.autoApply = autoApplyCheck.state == .on
            s.speechLocale = speechPopup.indexOfSelectedItem == 1 ? "en-US" : "zh-CN"
            s.panelTheme = PanelTheme.allCases[max(0, themePopup.indexOfSelectedItem)]

            let chars = Int(contextField.stringValue.trimmed) ?? 1200
            s.maxContextChars = min(max(chars, 200), 8000)

            let idx = max(0, hotkeyPopup.indexOfSelectedItem)
            s.hotkeyKeyCode = hotkeyPresets[idx].1
            s.hotkeyModifiers = hotkeyPresets[idx].2
        }

        PTLog.write("commit: done")
        return keyProblem
    }

    // MARK: - 校验

    private func currentConfig() -> LLMConfig {
        return LLMConfig(provider: editingProvider,
                         baseURL: baseURLField.stringValue.trimmed,
                         model: modelField.stringValue.trimmed,
                         apiKey: keyField.stringValue.trimmed,
                         temperature: Settings.shared.temperature,
                         localOnly: localOnlyCheck?.state == .on)
    }

    /// 返回第一处问题；nil 表示可以发请求
    private func validate() -> String? {
        let cfg = currentConfig()
        if cfg.model.isEmpty {
            return "「模型名」不能为空。本地示例 qwen2.5-coder:7b，云端示例 gpt-4o-mini"
        }
        if LLMClient.endpoint(for: cfg) == nil {
            let shown = cfg.baseURL.isEmpty ? "（空）" : cfg.baseURL
            return "「接口地址」无效：\(shown)。示例 http://127.0.0.1:11434"
        }
        if cfg.provider != .ollama && cfg.apiKey.isEmpty {
            return "「API Key」为空，\(cfg.provider.displayName)需要鉴权。请填入控制台生成的 key"
        }
        return nil
    }

    /// 地址里写着 /anthropic 却选了 OpenAI 协议（或反过来）——这种错配一定会 404，提前点破
    private func protocolMismatchHint() -> String? {
        let lower = baseURLField.stringValue.lowercased()
        if editingProvider != .anthropic && lower.contains("/anthropic") {
            return "地址里有 /anthropic，这是 Anthropic 协议端点。请把「模型来源」改成「Anthropic 兼容协议」"
        }
        if editingProvider == .anthropic && lower.contains("/chat/completions") {
            return "地址是 OpenAI 协议的 /chat/completions。请把「模型来源」改成「OpenAI 兼容 API」"
        }
        return nil
    }

    private func refreshEndpointPreview() {
        let cfg = currentConfig()
        guard let url = cfg.endpointURL else {
            endpointLabel.stringValue = "地址无效"
            endpointLabel.textColor = .systemRed
            return
        }
        var text = "POST " + url.absoluteString
        if let _ = protocolMismatchHint() {
            text += "　（协议可能不对）"
            endpointLabel.textColor = .systemOrange
        } else if localOnlyCheck?.state == .on && !cfg.provider.isLocal {
            text += "　（会被「仅本地运行」拦下）"
            endpointLabel.textColor = .systemOrange
        } else {
            endpointLabel.textColor = .secondaryLabelColor
        }
        endpointLabel.stringValue = text
    }

    @objc private func themeChanged() {
        refreshThemeHint()
    }

    @objc private func requestScreenPermission() {
        ScreenSampler.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        setStatus("授权后请退出并重新打开 PointTell，「自动」配色才会生效", kind: .warning)
    }

    /// 「自动」需要屏幕录制权限才能看到背后界面的颜色，这里把状态说清楚
    private func refreshThemeHint() {
        guard themeHint != nil else { return }
        let theme = PanelTheme.allCases[max(0, themePopup.indexOfSelectedItem)]
        switch theme {
        case .dark:
            themeAuthButton?.isHidden = true
            themeHint.stringValue = "面板固定用深色，适合深色主题的编辑器"
            themeHint.textColor = .tertiaryLabelColor
        case .light:
            themeAuthButton?.isHidden = true
            themeHint.stringValue = "面板固定用浅色"
            themeHint.textColor = .tertiaryLabelColor
        case .auto:
            if ScreenSampler.hasPermission {
                themeAuthButton?.isHidden = true
                themeHint.stringValue = "按光标处界面的明暗自动切换"
                themeHint.textColor = .tertiaryLabelColor
            } else {
                themeAuthButton?.isHidden = false
                themeHint.stringValue = "需要「屏幕录制」权限才能看到背后的颜色"
                themeHint.textColor = .systemOrange
            }
        }
    }

    private func setStatus(_ text: String, kind: StatusKind) {        statusLabel.stringValue = text
        switch kind {
        case .info: statusLabel.textColor = .secondaryLabelColor
        case .success: statusLabel.textColor = .systemGreen
        case .warning: statusLabel.textColor = .systemOrange
        case .error: statusLabel.textColor = .systemRed
        }
    }

    // MARK: - 文本变化

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }

        // 字符上限只允许数字
        if field === contextField {
            let digits = field.stringValue.filter { $0.isNumber }
            if digits != field.stringValue { field.stringValue = digits }
        }

        refreshEndpointPreview()

        // 用户一改输入，就清掉上一次的测试结果，避免误导
        refreshIdleStatus()
    }

    /// 空闲状态：没有测试结果时，只在有明确隐患（协议错配）时给提示
    private func refreshIdleStatus() {
        guard !testing else { return }
        if let hint = protocolMismatchHint() {
            setStatus("⚠️ " + hint, kind: .warning)
        } else {
            setStatus("", kind: .info)
        }
    }

    // MARK: - 动作

    @objc private func localOnlyToggled() {
        refreshEndpointPreview()
        refreshIdleStatus()
    }

    @objc private func providerChanged() {
        // 先把当前来源的输入收进草稿，再切
        stashCurrentFields()

        let idx = providerPopup.indexOfSelectedItem
        editingProvider = LLMProvider.allCases[max(0, idx)]
        loadFields(for: editingProvider)
        refreshIdleStatus()
    }

    // MARK: - 地址预设

    /// 手输长域名最容易错一个字母（比如 ikeap / lkeap），这里给现成的
    @objc private func showPresets(_ sender: NSButton) {
        let menu = NSMenu()

        menu.addItem(presetItem("Ollama 本机 · 127.0.0.1:11434",
                                provider: .ollama,
                                base: "http://127.0.0.1:11434",
                                model: "qwen2.5-coder:7b"))
        menu.addItem(presetItem("OpenAI 官方 · api.openai.com/v1",
                                provider: .openAI,
                                base: "https://api.openai.com/v1",
                                model: "gpt-4o-mini"))
        menu.addItem(presetItem("Anthropic 官方 · api.anthropic.com",
                                provider: .anthropic,
                                base: "https://api.anthropic.com",
                                model: "claude-sonnet-4-5"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(presetItem("腾讯云 Anthropic 兼容 · TokenHub 计划版",
                                provider: .anthropic,
                                base: "https://api.lkeap.cloud.tencent.com/plan/anthropic",
                                model: nil))
        menu.addItem(presetItem("腾讯云 Anthropic 兼容 · 知识引擎",
                                provider: .anthropic,
                                base: "https://api.lkeap.cloud.tencent.com/api/anthropic",
                                model: nil))

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 4),
                   in: sender)
    }

    private func presetItem(_ title: String, provider: LLMProvider, base: String, model: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(applyPreset(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = [provider.rawValue, base, model ?? ""]
        return item
    }

    @objc private func applyPreset(_ item: NSMenuItem) {
        guard let info = item.representedObject as? [String], info.count == 3,
              let p = LLMProvider(rawValue: info[0]) else { return }

        if p != editingProvider {
            stashCurrentFields()
            editingProvider = p
            providerPopup.selectItem(at: LLMProvider.allCases.firstIndex(of: p) ?? 0)
        }
        baseURLField.stringValue = info[1]
        draftBaseURL[p] = info[1]
        if !info[2].isEmpty {
            modelField.stringValue = info[2]
            draftModel[p] = info[2]
        }
        keyField.placeholderString = keyPlaceholder(for: p)
        refreshEndpointPreview()
        setStatus("已填入 \(p.displayName) 预设地址，确认后点保存", kind: .info)
    }

    @objc private func saveAndClose() {
        PTLog.write("save: clicked")
        if let problem = validate() {
            PTLog.write("save: blocked by validation — \(problem)")
            setStatus("✗ " + problem, kind: .error)
            return
        }

        let keyProblem = commit()

        if let warning = keyProblem {
            // 配置存下了，但 key 没存进钥匙串——不关窗，否则用户根本看不到这句话
            PTLog.write("save: keychain problem — \(warning)")
            setStatus("⚠️ " + warning, kind: .warning)
            return
        }

        PTLog.write("save: committed, closing")
        setStatus("已保存", kind: .success)
        // 让「已保存」先露个脸，再关窗
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.window?.close()
        }
    }

    @objc private func testConnection() {
        guard !testing else { return }

        if let problem = validate() {
            setStatus("✗ " + problem, kind: .error)
            return
        }

        let cfg = currentConfig()
        if let gate = cfg.gateError() {
            setStatus("⚠️ " + gate, kind: .warning)
            return
        }
        if let hint = protocolMismatchHint() {
            setStatus("⚠️ " + hint, kind: .warning)
            return
        }

        testing = true
        testButton.isEnabled = false
        testButton.title = "测试中…"
        spinner.startAnimation(nil)
        setStatus("正在检查服务：\(cfg.endpointDescription)", kind: .info)

        // 第一步：探测服务与模型列表（秒回），能区分「服务没起」和「模型没装」
        let probe = LLMProbe()
        self.probe = probe
        probe.fetchModels(config: cfg, timeout: 8) { [weak self] models, error in
            guard let self = self else { return }
            self.probe = nil

            if let error = error {
                self.endTest()
                self.setStatus("✗ " + error, kind: .error)
                return
            }

            let list = models ?? []
            if cfg.provider == .ollama, !list.isEmpty,
               !SettingsWindowController.modelListed(cfg.model, in: list) {
                let shown = list.prefix(4).joined(separator: "、")
                self.setStatus("⚠️ 服务可达，但没有模型「\(cfg.model)」。已安装：\(shown)\(list.count > 4 ? " 等" : "")。仍尝试生成…",
                               kind: .warning)
            } else if list.isEmpty {
                self.setStatus("✓ 服务可达，正在试生成…", kind: .info)
            } else {
                self.setStatus("✓ 服务可达（发现 \(list.count) 个模型），正在试生成…", kind: .info)
            }
            self.startChatProbe(cfg: cfg, knownModels: list)
        }
    }

    /// 第二步：真的让模型吐两个字，确认生成链路通
    private func startChatProbe(cfg: LLMConfig, knownModels: [String]) {
        let client = LLMClient()
        testClient = client
        var reply = ""
        let startedAt = Date()

        client.onDelta = { text in
            if reply.isEmpty {
                self.setStatus("✓ 服务与模型都正常，正在生成…", kind: .info)
            }
            reply += text
        }
        client.onFinish = { [weak self] error in
            guard let self = self else { return }
            self.endTest()
            let seconds = String(format: "%.1fs", Date().timeIntervalSince(startedAt))

            if let error = error {
                if error.contains("超时") {
                    self.setStatus("⚠️ 服务与模型都在，但生成超时。本地模型首次加载较慢，稍等再试，或换更小的模型",
                                   kind: .warning)
                } else if error.contains("404"), cfg.provider == .ollama, !knownModels.isEmpty {
                    let shown = knownModels.prefix(4).joined(separator: "、")
                    self.setStatus("✗ 模型「\(cfg.model)」不可用。已安装：\(shown)", kind: .error)
                } else {
                    self.setStatus("✗ " + error, kind: .error)
                }
                return
            }

            let visible = SettingsWindowController.visibleReply(reply)
            if visible.isEmpty {
                self.setStatus("✓ 连接成功（\(seconds)）· 模型只返回了思考过程，链路正常", kind: .success)
            } else {
                self.setStatus("✓ 连接成功（\(seconds)）· 回复「\(visible.truncated(12))」· \(cfg.endpointDescription)",
                               kind: .success)
            }
        }
        client.start(messages: [ChatMessage(role: "user", content: "只回复两个字：正常")],
                     config: cfg,
                     timeout: cfg.provider == .ollama ? 90 : (cfg.provider == .anthropic ? 60 : 30),
                     // 推理模型会先花掉一大截预算思考，给太小会「只回思考、没有正文」
                     maxTokens: 512)
    }

    /// 推理模型（deepseek-r1 等）会把 思考过程 混在输出里，状态栏只显示给用户看的部分
    private static func visibleReply(_ raw: String) -> String {
        var t = raw
        while let open = t.range(of: "<think>"),
              let close = t.range(of: "</think>", range: open.upperBound..<t.endIndex) {
            t.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if let open = t.range(of: "<think>") {
            t = String(t[..<open.lowerBound])
        }
        return t.trimmed
    }

    /// 模型名比对：忽略大小写，忽略 :latest 之类的 tag 差异
    private static func modelListed(_ name: String, in list: [String]) -> Bool {
        let target = name.lowercased()
        let targetBase = target.split(separator: ":").first.map(String.init) ?? target
        for item in list {
            let l = item.lowercased()
            if l == target { return true }
            let base = l.split(separator: ":").first.map(String.init) ?? l
            if base == targetBase { return true }
        }
        return false
    }

    private func endTest() {
        testing = false
        testButton.isEnabled = true
        testButton.title = "测试连接"
        spinner.stopAnimation(nil)
        DispatchQueue.main.async { [weak self] in
            self?.testClient = nil
        }
    }
}

// MARK: - 窗口状态日志

extension SettingsWindowController: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        PTLog.write("settings: became key")
    }

    func windowDidResignKey(_ notification: Notification) {
        PTLog.write("settings: resigned key")
    }

    func windowWillClose(_ notification: Notification) {
        PTLog.write("settings: will close")
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: - 命令行自检用（正式构建也保留，只被启动参数触发）

extension SettingsWindowController {
    /// 找到标题匹配的按钮，直接触发一次——用来在真应用环境里验证保存链路
    @discardableResult
    func triggerButton(titled title: String) -> Bool {
        func walk(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton, b.title == title { return b }
            for sub in v.subviews { if let r = walk(sub) { return r } }
            return nil
        }
        guard let content = window?.contentView, let b = walk(content) else { return false }
        PTLog.write("selftest: clicking 「\(title)」 enabled=\(b.isEnabled) "
            + "target=\(b.target.map { String(describing: type(of: $0)) } ?? "nil") "
            + "action=\(b.action.map(NSStringFromSelector) ?? "nil")")
        b.performClick(nil)
        return true
    }

    /// 自检用：像用户那样把几个输入框填上
    func fillForTesting(providerIndex: Int, baseURL: String, model: String, key: String) {
        providerPopup.selectItem(at: providerIndex)
        providerChanged()
        baseURLField.stringValue = baseURL
        modelField.stringValue = model
        keyField.stringValue = key
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: baseURLField))
    }

    /// 自检用：读回界面上的值
    func readForTesting() -> String {
        return "provider=\(providerPopup.titleOfSelectedItem ?? "?") "
            + "baseURL=\(baseURLField.stringValue) "
            + "model=\(modelField.stringValue) "
            + "keyLen=\(keyField.stringValue.count) "
            + "endpoint=\(endpointLabel.stringValue) "
            + "localOnly=\(localOnlyCheck.state == .on) "
            + "status=「\(statusLabel.stringValue)」"
    }
}

#if DEBUG
// 仅命令行自检探针编译时可见（build.sh 不带 -D DEBUG，正式包不会包含这些入口）
extension SettingsWindowController {
    func dbgStatus() -> String { return statusLabel.stringValue }
    func dbgResetStatus() { setStatus("", kind: .info) }
    func dbgTesting() -> Bool { return testing }
    func dbgEndpointText() -> String { return endpointLabel.stringValue }
    func dbgTestButton() -> NSButton { return testButton }
    func dbgProviderPopup() -> NSPopUpButton { return providerPopup }

    func dbgSetLocalOnly(_ on: Bool) {
        localOnlyCheck.state = on ? .on : .off
        localOnlyToggled()
    }

    func dbgSet(baseURL: String? = nil, model: String? = nil, key: String? = nil) {
        if let v = baseURL { baseURLField.stringValue = v }
        if let v = model { modelField.stringValue = v }
        if let v = key { keyField.stringValue = v }
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: baseURLField))
    }

    func dbgControls() -> [String: NSTextField] {
        return ["baseURL": baseURLField, "model": modelField, "key": keyField, "context": contextField]
    }
}
#endif
