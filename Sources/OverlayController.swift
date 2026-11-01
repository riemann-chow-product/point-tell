import Cocoa
import ApplicationServices

/// 面板的生命周期 + 一次完整的「指 → 说 → 改」闭环。
final class OverlayController {

    private var panel: OverlayPanel?
    private var card: OverlayCardView?
    private var highlight: HighlightWindow?

    private var context = CapturedContext()
    private var mode: EditMode = .rewrite
    private var client: LLMClient?
    private let speech = SpeechRecognizer()

    private var resultText = ""
    private var isVisible = false
    private var showingContext = false
    private var targetApp: NSRunningApplication?
    private var anchorTop: CGFloat = 0
    /// 面板打开时刻。用于忽略「刚弹出就失焦」这种假信号
    private var openedAt = Date.distantPast
    /// 用户点了「应用」但结果还没生成出来 —— 等生成完自动应用，而不是静默吞掉。
    private var pendingApply = false
    /// 用户点了「复制」但结果还没生成出来
    private var pendingCopy = false
    /// 用户自己拨过「改写 / 问答」。拨过之后就别再被后台的可编辑性判断改回去。
    private var userTouchedMode = false

    private var isDictating = false
    /// 应用之后面板要留一会儿让用户确认，这期间「失焦自动收起」必须让路
    private var keepOpenAfterApply = false
    private var autoCloseTimer: Timer?
    private var autoCloseDeadline = Date.distantPast
    private var autoCloseNote = ""
    private var stayMonitor: Any?
    /// 用户「想不想在录」。和 isDictating 分开是因为申请权限是异步的：
    /// 按住 ⌥ → 申请权限（可能弹系统框）→ 回调里才真正开始录。
    /// 如果这中间用户已经松手了，回调必须放弃启动，否则麦克风会一直开着、
    /// 界面永远停在「正在听…」，只能再按一次 ⌥ 才能解开。
    private var dictationWanted = false
    private var dictationBase = ""
    private var keyMonitor: Any?
    /// 上下文还在后台补全（表格 / 正文这些要跑几十次 AX 调用）
    private var contextPending = false

    // MARK: - 打开 / 关闭

    func toggle() {
        if isVisible {
            close()
        } else {
            open()
        }
    }

    func open() {
        guard ensureAccessibility() else { return }

        if isVisible {
            card?.focusInput()
            return
        }

        // 上一次应用后的倒计时不能把这一次的面板关掉
        cancelAutoClose()
        keepOpenAfterApply = false
        // 捕获必须在抢焦点之前完成。
        // 但只有「取元素 + 角色」是同步的（一次 IPC，带 0.35s 超时）；
        // 窗口标题、正文、表格这些要跑几十次 IPC，放到后台补，
        // 否则目标应用一卡，热键按下去要等几十秒面板才出来。
        targetApp = AppFocusTracker.shared.lastExternalApp
        let (base, el) = ContextCapture.probe()
        context = base
        mode = context.isEditable ? .rewrite : .ask
        resultText = ""
        showingContext = false
        pendingApply = false
        pendingCopy = false
        userTouchedMode = false

        buildIfNeeded()
        guard let card = card else { return }

        // 配色：面板是半透明毛玻璃，文字色必须和「透出来的背景」一致。
        // 必须在面板真正显示之前采样，否则会截到面板自己。
        card.applyBackdrop(dark: resolveBackdropDarkness())

        card.clearResult()
        card.update(context: context, mode: mode, appIconImage: appIcon(for: context))
        card.setSuggestions(PromptBuilder.suggestions(mode: mode, context: context))
        card.setMode(mode)
        card.inputView.string = ""
        card.inputView.placeholder = placeholder(for: context)
        card.updateInputHeight()

        layoutPanel(placeNearCursor: true)
        panel?.alphaValue = 1
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        card.focusInput()
        isVisible = true
        openedAt = Date()

        if let rect = context.elementFrame {
            ensureHighlight().show(around: rect)
        }
        installKeyMonitor()
        PTLog.write("panel open at \(NSEvent.mouseLocation)")

        // 后台补全上下文，回来了再刷新面板。
        // 用 capturedAt 判断「这次结果还属于当前这一轮」，避免上一次的慢查询覆盖新面板。
        contextPending = false
        if let el = el {
            let stamp = base.capturedAt
            contextPending = true
            ContextCapture.enrich(el, from: base) { [weak self] full in
                guard let self = self, self.isVisible, self.context.capturedAt == stamp else { return }
                self.contextPending = false
                self.context = full
                // probe 只按 role 判可编辑：Sublime / Electron / 网页编辑区的 role
                // 往往是 AXGroup / AXScrollArea，会被误判成「问答」，面板里就只剩
                // 「复制」。enrich 读到 AXEditable 之后纠正一次。
                // 用户自己拨过模式、或者已经开跑/输入了，就不动。
                if !self.userTouchedMode,
                   self.resultText.isEmpty,
                   (self.card?.inputView.string.trimmed.isEmpty ?? true),
                   full.isEditable != (self.mode == .rewrite) {
                    self.mode = full.isEditable ? .rewrite : .ask
                    PTLog.write("mode: corrected to \(self.mode == .rewrite ? "rewrite" : "ask") after enrich")
                    self.card?.setMode(self.mode)
                    self.card?.setSuggestions(PromptBuilder.suggestions(mode: self.mode, context: full))
                }
                self.card?.update(context: full, mode: self.mode, appIconImage: self.appIcon(for: full))
                self.card?.setSuggestions(PromptBuilder.suggestions(mode: self.mode, context: full))
                if let rect = full.elementFrame {
                    self.ensureHighlight().show(around: rect)
                }
            }
        }

        // 「自动配色」要读屏幕，没权限时只提示一次，别每次唤起都唠叨
        if Settings.shared.panelTheme == .auto, !ScreenSampler.hasPermission,
           !UserDefaults.standard.bool(forKey: "hintedScreenCapture") {
            UserDefaults.standard.set(true, forKey: "hintedScreenCapture")
            card.setStatus("配色自适应需要「屏幕录制」权限：菜单栏 → 设置 → 面板配色 → 授权屏幕录制")
        }
    }

    /// 面板该用深色还是浅色。nil = 跟随系统外观。
    private func resolveBackdropDarkness() -> Bool? {
        switch Settings.shared.panelTheme {
        case .dark: return true
        case .light: return false
        case .auto:
            let dark = ScreenSampler.isDarkBackdrop(around: context.elementFrame)
            if dark == nil {
                PTLog.write("theme: 采样不可用（多半是没给屏幕录制权限），跟随系统外观")
            }
            return dark
        }
    }

    func close(reactivate: Bool = true) {
        PTLog.write("close: reactivate=\(reactivate) client=\(client == nil ? "nil" : "running") resultLen=\(resultText.count)")
        cancelAutoClose()
        keepOpenAfterApply = false
        dictationWanted = false
        speech.stop()
        isDictating = false
        pendingApply = false
        pendingCopy = false
        client?.cancel()
        client = nil
        highlight?.hide()
        panel?.orderOut(nil)
        isVisible = false
        removeKeyMonitor()
        if reactivate {
            targetApp?.activate(options: [.activateIgnoringOtherApps])
        }
    }

    // MARK: - 构建

    private func buildIfNeeded() {
        if panel != nil { return }
        let p = OverlayPanel()
        let c = OverlayCardView(frame: NSRect(x: 0, y: 0, width: OverlayCardView.width, height: 220))
        c.autoresizingMask = [.width, .height]
        p.contentView = c

        c.onRun = { [weak self] in self?.scheduleRun() }
        c.onApply = { [weak self] in self?.applyResult() }
        c.onCopy = { [weak self] in self?.copyResult() }
        c.onClose = { [weak self] in self?.close() }
        c.onToggleContext = { [weak self] in self?.toggleContextPreview() }
        c.onModeChange = { [weak self] newMode in self?.changeMode(newMode) }
        c.onChip = { [weak self] text in
            guard let self = self, let card = self.card else { return }
            card.inputView.string = text
            card.updateInputHeight()
            card.focusInput()
        }
        c.onMic = { [weak self] in self?.toggleDictation() }
        c.onInputChanged = { [weak self] in self?.layoutPanel(placeNearCursor: false) }
        c.onPushToTalkStart = { [weak self] in
            guard let self = self, !self.isDictating else { return }
            self.startDictation()
        }
        c.onPushToTalkEnd = { [weak self] in
            guard let self = self, self.isDictating else { return }
            self.stopDictation()
        }

        panel = p
        card = c

        // 点到别的地方就收起面板（正在生成时保留，别把结果丢了）
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                              object: p,
                                              queue: .main) { [weak self] _ in
            guard let self = self, self.isVisible, self.client == nil else { return }
            // 应用后有一段「留着让用户确认」的时间，这期间失焦不算数
            // （Paster 会把目标应用切到前台，面板必然 resignKey）
            guard !self.keepOpenAfterApply else {
                PTLog.write("panel: keep open after apply, ignore resignKey")
                return
            }
            // 刚弹出的头 0.4 秒不认「失焦」：
            // 系统通知横幅、别的应用抢 key、activate 还没落地都会让面板瞬间 resignKey，
            // 结果是面板闪一下就没了 —— 用户只会觉得「快捷键没反应」。
            guard Date().timeIntervalSince(self.openedAt) > 0.4 else {
                PTLog.write("panel: ignore early resignKey")
                // 但也不能一直挂着：半秒后确实还没拿到键盘焦点，就正常收起
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self, self.isVisible, self.client == nil else { return }
                    if self.panel?.isKeyWindow == false {
                        PTLog.write("panel: still not key after grace, closing")
                        self.close(reactivate: false)
                    }
                }
                return
            }
            self.close(reactivate: false)
        }
    }

    private func ensureHighlight() -> HighlightWindow {
        if let h = highlight { return h }
        let h = HighlightWindow()
        highlight = h
        return h
    }

    // MARK: - 布局

    private func layoutPanel(placeNearCursor: Bool) {
        guard let panel = panel, let card = card else { return }
        let height = card.preferredHeight()
        let width = OverlayCardView.width
        var frame = NSRect(x: panel.frame.minX, y: panel.frame.minY, width: width, height: height)

        if placeNearCursor {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

            var x = mouse.x + 14
            var y = mouse.y - height - 16
            if y < visible.minY + 10 { y = mouse.y + 22 }
            if y + height > visible.maxY - 10 { y = visible.maxY - height - 10 }
            if x + width > visible.maxX - 10 { x = visible.maxX - width - 10 }
            if x < visible.minX + 10 { x = visible.minX + 10 }
            if y < visible.minY + 10 { y = visible.minY + 10 }
            frame.origin = NSPoint(x: x, y: y)
            anchorTop = frame.maxY
        } else {
            frame.origin.y = anchorTop - height
            let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.minX, y: frame.midY)) }
            if let visible = screen?.visibleFrame, frame.minY < visible.minY + 10 {
                frame.origin.y = visible.minY + 10
            }
        }

        panel.setFrame(frame, display: true)
        card.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
    }

    // MARK: - 执行

    /// 等上下文补全再开跑。
    /// 表格的「表头 + 当前行」是后台抓的，用户如果点得很快，正文/表格还没到位，
    /// 这时候直接生成就会退化成「只有应用名和控件类型」的瞎猜。
    /// 最多等 1 秒，等不到就用现有上下文跑 —— 绝不因为读不到上下文把流程卡死。
    private func scheduleRun(attempts: Int = 0) {
        if !contextPending || attempts >= 4 {
            run()
            return
        }
        if attempts == 0 {
            card?.setStatus("正在读取上下文…")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }
            self.scheduleRun(attempts: attempts + 1)
        }
    }

    private func run() {
        // scheduleRun 可能排了 1 秒的延时；这期间用户按 esc 关掉了面板，
        // 不能再偷偷发请求（否则日志里会出现「关了面板还在调模型」）
        guard isVisible else {
            PTLog.write("run: panel closed, aborted")
            return
        }
        guard let card = card else { return }
        // 重新生成意味着用户想继续，别让上一次的收起倒计时把面板关了
        cancelAutoClose()
        keepOpenAfterApply = false
        let question = card.inputView.string.trimmed
        guard !question.isEmpty else {
            pendingApply = false
            pendingCopy = false
            card.setStatus("先给一句指令，比如「给这个函数加参数校验」")
            return
        }
        if let gate = Settings.shared.requestGate() {
            pendingApply = false
            pendingCopy = false
            card.setStatus("⚠️ " + gate)
            return
        }

        // 上一次还在跑就换掉：两个流同时往 resultText 里追加，结果会串成两段
        if client != nil {
            PTLog.write("run: cancelling previous request")
            client?.cancel()
            client = nil
        }

        speech.stop()
        isDictating = false
        card.setMicActive(false)

        resultText = ""
        card.clearResult()
        card.setBusy(true)
        card.setStatus("读取上下文 → 生成中…")

        let messages = PromptBuilder.messages(mode: mode, context: context, question: question)
        let c = LLMClient()
        client = c
        c.onDelta = { [weak self] delta in
            guard let self = self else { return }
            self.resultText += delta
            self.card?.appendResult(delta, monospaced: self.mode == .rewrite)
            self.growForResult()
        }
        // 思考阶段可能长达几十秒且一个字正文都没有 —— 不刷新状态栏，用户会以为卡死/没反应
        c.onThinking = { [weak self] chars in
            guard let self = self, self.resultText.isEmpty else { return }
            self.card?.setStatus("🧠 模型思考中…（已 \(chars) 字，正文还没开始）")
        }
        c.onFinish = { [weak self] error in
            guard let self = self else { return }
            PTLog.write("onFinish: err=\(error ?? "nil") resultLen=\(self.resultText.count)")
            self.client = nil
            self.card?.setBusy(false)
            if let error = error {
                self.pendingApply = false
                self.pendingCopy = false
                // 出错时清掉结果区可能已流式显示出的废话（如网关状态字 UNREGISTERED）
                self.resultText = ""
                self.card?.clearResult()
                self.card?.setStatus("⚠️ " + error)
                PTLog.write("llm error: \(error)")
                return
            }
            self.card?.setStatus("完成 · ⌘↵ 应用 · ⌘C 复制")

            // 用户是先点了按钮、后才有结果的：这里补上那次动作
            if self.pendingApply || self.pendingCopy {
                let wantApply = self.pendingApply
                self.pendingApply = false
                self.pendingCopy = false
                guard !self.resultText.isEmpty else {
                    // 模型只回了 thinking 块、正文为空时不能再去 apply，
                    // 否则 applyResult 会因为「没结果」再调 run()，死循环。
                    self.card?.setStatus("⚠️ 模型没有返回正文内容")
                    PTLog.write("pending: result empty — aborted")
                    return
                }
                PTLog.write("pending: replaying \(wantApply ? "apply" : "copy")")
                if wantApply {
                    self.applyResult()
                } else {
                    self.copyResult()
                }
                return
            }

            if Settings.shared.autoApply, self.mode == .rewrite, !self.resultText.isEmpty {
                self.applyResult()
            }
        }
        c.start(messages: messages)
    }

    private func growForResult() {
        guard let card = card else { return }
        if card.fitResultHeight() {
            layoutPanel(placeNearCursor: false)
        }
    }

    private func applyResult() {
        // 问答模式下「应用」也真的写回去。
        // 以前这里第一行就是 `if mode == .ask { copyResult(); return }` ——
        // 配合「问答模式把应用按钮换成复制」，等于用户指着编辑器说
        // 「翻译成英文」时，整条写回路径都被堵死了。现在两条路都在，
        // 写不进去（目标不可编辑）才退回复制。
        // 还没生成结果就点了「应用」：先把输入框里的指令跑一遍，生成完再自动应用。
        // 之前这里是 `guard !resultText.isEmpty else { return }` —— 直接静默返回，
        // 用户看到的就是「点了应用没反应」。
        if resultText.isEmpty {
            let question = card?.inputView.string.trimmed ?? ""
            guard !question.isEmpty else {
                card?.setStatus("先给一句指令，比如「翻译成英文」")
                return
            }
            guard client == nil else {
                // 正在生成中，标记一下，等这次生成结束就应用
                pendingApply = true
                card?.setStatus("生成中… 完成后自动应用")
                return
            }
            pendingApply = true
            PTLog.write("apply: no result yet, running first — \(question)")
            scheduleRun()
            return
        }

        guard let dest = targetApp, dest.bundleIdentifier != AppInfo.bundleID else {
            // 没有可回写的目标应用：别装作成功，明确告诉用户结果在剪贴板
            Paster.copy(resultText)
            card?.setStatus("没有可回写的目标应用，结果已复制到剪贴板（⌘V 手动粘贴）")
            PTLog.write("apply: no target app, copied to clipboard instead")
            return
        }

        PTLog.write("apply: inserting \(resultText.count) chars into \(dest.localizedName ?? "nil")")

        // 不立刻关面板。
        // 以前这里是先 close 再 insert：内容确实粘过去了，但面板同时消失，
        // 用户根本没机会确认「改得对不对」—— 只剩一个已经变了的文档和一点疑惑。
        // 现在改成：先粘贴 → 面板留在原地显示倒计时 → 到点自己收起。
        keepOpenAfterApply = true
        Paster.insert(resultText, into: dest) { ok in
            DispatchQueue.main.async {
                guard ok else {
                    // 没能切回目标应用：内容在剪贴板里，必须让用户看见这句话，否则等于丢了
                    PTLog.write("apply: fallback to clipboard (target never came frontmost)")
                    self.keepOpenAfterApply = false
                    self.panel?.alphaValue = 1
                    self.panel?.makeKeyAndOrderFront(nil)
                    self.isVisible = true
                    self.installKeyMonitor()
                    self.card?.setStatus("没能切回 \(dest.localizedName ?? "目标应用")，结果已复制到剪贴板（⌘V 手动粘贴）")
                    return
                }
                // 光标处不是可编辑控件时，⌘V 打不进去。别装作成功 —— 说明白并留下剪贴板
                let name = dest.localizedName ?? "目标应用"
                let note = self.context.isEditable
                    ? "已应用到 \(name)"
                    : "已发送 ⌘V 到 \(name)（这里不可编辑，没粘上就手动 ⌘V）"
                self.scheduleAutoClose(note: note)
            }
        }
    }

    // MARK: - 应用后的停留

    /// 停留时长按结果长度算：几十字给 5 秒，几百字给十几秒，够看完再走。
    /// 以前是点完立刻关，用户反馈「还没看完窗口就没了」。
    /// 按中文阅读速度 ~20 字/秒 估，下限 5 秒兜底。
    private func autoCloseDelay() -> TimeInterval {
        let chars = Double(resultText.count)
        return min(15, max(5, chars / 20.0))
    }

    private func scheduleAutoClose(note: String) {
        cancelAutoClose()
        autoCloseNote = note
        autoCloseDeadline = Date().addingTimeInterval(autoCloseDelay())
        PTLog.write("apply: panel stays for \(String(format: "%.1f", autoCloseDelay()))s")

        updateAutoCloseStatus()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if Date() >= self.autoCloseDeadline {
                self.cancelAutoClose()
                self.close(reactivate: false)
                return
            }
            self.updateAutoCloseStatus()
        }
        // 用 common mode：面板不在交互时 default mode 的定时器可能被挂起
        RunLoop.main.add(timer, forMode: .common)
        autoCloseTimer = timer
        installStayMonitor()
    }

    private func updateAutoCloseStatus() {
        let left = max(0, Int(ceil(autoCloseDeadline.timeIntervalSinceNow)))
        card?.setStatus("✓ \(autoCloseNote) · \(left) 秒后收起（点一下面板可留下）")
    }

    /// 倒计时期间只要用户动了面板（点击 / 按键），就当作「我还要看」，取消自动收起
    private func installStayMonitor() {
        guard stayMonitor == nil else { return }
        stayMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            guard let self = self, self.autoCloseTimer != nil else { return event }
            PTLog.write("apply: user interacted, cancel auto-close")
            self.cancelAutoClose()
            self.card?.setStatus("✓ \(self.autoCloseNote) · esc 关闭")
            return event
        }
    }

    private func cancelAutoClose() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        if let m = stayMonitor {
            NSEvent.removeMonitor(m)
            stayMonitor = nil
        }
    }

    private func copyResult() {
        guard !resultText.isEmpty else {
            // 还没生成就点「复制」：同样不能静默吞掉，否则用户以为按钮坏了
            let question = card?.inputView.string.trimmed ?? ""
            guard !question.isEmpty else {
                card?.setStatus("先给一句指令，再点复制")
                return
            }
            guard client == nil else {
                pendingCopy = true
                card?.setStatus("生成中… 完成后自动复制")
                return
            }
            pendingCopy = true
            PTLog.write("copy: no result yet, running first — \(question)")
            scheduleRun()
            return
        }
        Paster.copy(resultText)
        card?.setStatus("已复制到剪贴板")
    }

    private func changeMode(_ newMode: EditMode) {
        // 用户自己选过模式，就别再被后台补全的可编辑性判断改回去
        userTouchedMode = true
        mode = newMode
        card?.setMode(newMode)
        card?.setSuggestions(PromptBuilder.suggestions(mode: newMode, context: context))
        layoutPanel(placeNearCursor: false)
        card?.focusInput()
    }

    private func toggleContextPreview() {
        guard let card = card else { return }
        showingContext = !showingContext
        if showingContext {
            card.setPlainResult(context.promptBlock(), monospaced: true)
            card.setStatus("以上是将要发送给模型的内容（不含剪贴板内容）")
        } else {
            card.clearResult()
            if !resultText.isEmpty {
                card.setPlainResult(resultText, monospaced: mode == .rewrite)
            }
        }
        layoutPanel(placeNearCursor: false)
    }

    // MARK: - 语音

    private func toggleDictation() {
        if isDictating {
            stopDictation()
        } else {
            startDictation()
        }
    }

    private func startDictation() {
        dictationWanted = true
        SpeechRecognizer.requestPermissions { [weak self] ok, error in
            guard let self = self else { return }
            // 等权限的这段时间里用户可能已经松手 / 关掉面板了
            guard self.dictationWanted, self.isVisible else { return }
            guard ok else {
                self.dictationWanted = false
                self.card?.setStatus("⚠️ " + (error ?? "语音不可用"))
                return
            }
            guard let card = self.card else { return }
            self.dictationBase = card.inputView.string
            self.isDictating = true
            card.setMicActive(true)
            card.setStatus("🎙 正在听…  松开 ⌥ 结束")

            self.speech.onPartial = { [weak self] text in
                self?.applyDictation(text)
            }
            self.speech.onFinal = { [weak self] text in
                guard let self = self else { return }
                self.applyDictation(text)
                self.stopDictation()
            }
            self.speech.onError = { [weak self] message in
                self?.card?.setStatus("⚠️ " + message)
                self?.stopDictation()
            }
            self.speech.start()
        }
    }

    private func applyDictation(_ text: String) {
        guard let card = card else { return }
        let prefix = dictationBase.trimmed
        let combined = prefix.isEmpty ? text : prefix + " " + text
        card.inputView.string = combined
        card.updateInputHeight()
        layoutPanel(placeNearCursor: false)
    }

    private func stopDictation() {
        dictationWanted = false
        speech.stop()
        isDictating = false
        card?.setMicActive(false)
        card?.setStatus("")
        card?.focusInput()
    }

    // MARK: - 杂项

    private func placeholder(for context: CapturedContext) -> String {
        if !context.tablePreview.isEmpty {
            return "指着这块问：这块的环比趋势怎么样？"
        }
        if context.isEditable {
            return "给这个函数加参数校验 / 补注释 / 改得更简洁…"
        }
        if !context.snippet.isEmpty {
            return "把这句话改简洁 / 解释一下这段…"
        }
        return "没捕获到文本，直接说你想做什么…"
    }

    private func appIcon(for context: CapturedContext) -> NSImage? {
        if context.pid > 0,
           let app = NSRunningApplication(processIdentifier: context.pid) {
            return app.icon
        }
        return nil
    }

    private func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        OnboardingController.shared.show()
        return false
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            if event.keyCode == 53 {
                self.close()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }
}

// MARK: - 命令行自检（正式构建也保留，只被启动参数触发）

extension OverlayController {

    /// 打开面板并填入指令，模拟用户「输完话直接点应用」
    func dbgOpenWithInstruction(_ text: String) {
        open()
        card?.inputView.string = text
        card?.updateInputHeight()
        layoutPanel(placeNearCursor: false)
    }

    /// 自检用：强制切到某个模式（改写 / 问答）
    func dbgForceMode(_ m: EditMode) {
        mode = m
        card?.setMode(m)
    }

    /// 直接触发一次「应用」，等价于点那个按钮
    func dbgTapApply() {        PTLog.writeSync("dbg: tap apply — resultLen=\(resultText.count) "
            + "input=\(card?.inputView.string ?? "") client=\(client == nil ? "nil" : "running")")
        applyResult()
    }

    func dbgSnapshot() -> String {
        let applyBtn = card.map { "\($0.applyButton.title)\($0.applyButton.isHidden ? "(hidden)" : "")" } ?? "-"
        let copyBtn = card.map { "\($0.copyButton.title)\($0.copyButton.isHidden ? "(hidden)" : "")" } ?? "-"
        return "resultLen=\(resultText.count) pendingApply=\(pendingApply) "
            + "visible=\(isVisible) client=\(client == nil ? "nil" : "running") "
            + "keepOpen=\(keepOpenAfterApply) autoClose=\(autoCloseTimer != nil) "
            + "mode=\(mode == .rewrite ? "rewrite" : "ask") "
            + "buttons=[\(applyBtn)|\(copyBtn)]"
    }
}
