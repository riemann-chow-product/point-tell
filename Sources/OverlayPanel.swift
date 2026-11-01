import Cocoa

// MARK: - 悬浮面板

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: OverlayCardView.width, height: 200),
                   styleMask: [.borderless, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
}

// MARK: - 指令输入框

final class PromptTextView: NSTextView {

    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }

    var onSubmit: (() -> Void)?
    var onApply: (() -> Void)?
    var onCancel: (() -> Void)?
    var onModeKey: ((Int) -> Void)?
    var onPushToTalkStart: (() -> Void)?
    var onPushToTalkEnd: (() -> Void)?

    private var optionHeld = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let font = self.font ?? NSFont.systemFont(ofSize: 14)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let padding = textContainer?.lineFragmentPadding ?? 5
        let rect = NSRect(x: textContainerInset.width + padding,
                          y: textContainerInset.height,
                          width: bounds.width - (textContainerInset.width + padding) * 2,
                          height: font.pointSize + 4)
        (placeholder as NSString).draw(in: rect, withAttributes: attrs)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 53 { // esc
            onCancel?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 { // return / enter
            if flags.contains(.shift) {
                super.keyDown(with: event)
                return
            }
            if flags.contains(.command) {
                onApply?()
            } else {
                onSubmit?()
            }
            return
        }
        if flags.contains(.command), let chars = event.charactersIgnoringModifiers {
            if chars == "1" { onModeKey?(0); return }
            if chars == "2" { onModeKey?(1); return }
        }
        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let down = event.modifierFlags.contains(.option)
        if down && !optionHeld {
            optionHeld = true
            onPushToTalkStart?()
        } else if !down && optionHeld {
            optionHeld = false
            onPushToTalkEnd?()
        }
        super.flagsChanged(with: event)
    }
}

// MARK: - 快捷指令小胶囊

final class ChipButton: NSButton {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    }

    func setChip(_ text: String) {
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        attributedTitle = attr
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    }
}

// MARK: - 圆角描边容器（不用 layer，纯 draw，离屏渲染/截图都稳定）

final class RoundedBox: NSView {
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    var strokeColor: NSColor = .clear { didSet { needsDisplay = true } }
    var radius: CGFloat = 9 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        if fillColor.alphaComponent > 0 {
            fillColor.setFill()
            path.fill()
        }
        if strokeColor.alphaComponent > 0 {
            strokeColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - 卡片本体

final class OverlayCardView: NSView {

    static let width: CGFloat = 600

    // 回调
    var onRun: (() -> Void)?
    var onApply: (() -> Void)?
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    var onToggleContext: (() -> Void)?
    var onModeChange: ((EditMode) -> Void)?
    var onChip: ((String) -> Void)?
    var onMic: (() -> Void)?
    var onInputChanged: (() -> Void)?
    var onPushToTalkStart: (() -> Void)?
    var onPushToTalkEnd: (() -> Void)?

    // 布局常量
    private let padX: CGFloat = 16
    private let padY: CGFloat = 13
    private let headerH: CGFloat = 22
    private let ctxH: CGFloat = 17
    private let chipsH: CGFloat = 21
    private let footerH: CGFloat = 20
    private let gapS: CGFloat = 7
    private let gapM: CGFloat = 10

    // 子视图
    let background = NSVisualEffectView()
    /// 底衬：盖在毛玻璃之上、内容之下。
    /// 毛玻璃透出的是背后界面的颜色，背后是深色编辑器时整块会变暗，
    /// 深色文字就糊了。这层把面板底色朝「当前外观」拉一把，保证任何背景下
    /// 文字都有对比度；alpha 不拉满，保留一点毛玻璃的透感。
    let scrim = RoundedBox()
    let appIcon = NSImageView()
    let appLabel = makeLabel("", size: 12, weight: .semibold)
    let roleLabel = makeLabel("", size: 11, color: .secondaryLabelColor)
    let modeControl = NSSegmentedControl()
    let ctxLabel = makeLabel("", size: 11, color: .secondaryLabelColor)
    let ctxButton = makeFlatButton("查看上下文", size: 11)
    let chipsContainer = NSView()
    let inputBox = RoundedBox()
    let inputScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 34))
    let inputView = PromptTextView()
    let micButton = NSButton()
    let resultBox = RoundedBox()
    let resultScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 160))
    let resultView = NSTextView()
    let hintLabel = makeLabel("", size: 10.5, color: .tertiaryLabelColor)
    let applyButton = NSButton()
    let copyButton = NSButton()
    let closeButton = NSButton()

    private var chips: [ChipButton] = []

    // 状态
    var showChips: Bool = true { didSet { needsLayout = true } }
    var showResult: Bool = false { didSet { needsLayout = true } }
    var inputHeight: CGFloat = 46 { didSet { needsLayout = true } }
    var resultHeight: CGFloat = 180 { didSet { needsLayout = true } }
    private(set) var isBusy = false

    // MARK: 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        wantsLayer = true

        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        background.autoresizingMask = [.width, .height]
        addSubview(background)

        scrim.radius = 14
        scrim.autoresizingMask = [.width, .height]
        addSubview(scrim)

        appIcon.imageScaling = .scaleProportionallyDown
        addSubview(appIcon)
        addSubview(appLabel)
        addSubview(roleLabel)

        modeControl.segmentCount = 2
        modeControl.setLabel("改写", forSegment: 0)
        modeControl.setLabel("问答", forSegment: 1)
        modeControl.segmentStyle = .rounded
        modeControl.controlSize = .small
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.font = NSFont.systemFont(ofSize: 11)
        addSubview(modeControl)

        addSubview(ctxLabel)
        ctxButton.target = self
        ctxButton.action = #selector(toggleContext)
        addSubview(ctxButton)

        addSubview(chipsContainer)

        inputBox.radius = 9
        addSubview(inputBox)

        configureScroll(inputScroll, textView: inputView, editable: true)
        inputView.placeholder = "指哪改哪…  例：给这个函数加参数校验"
        inputView.onSubmit = { [weak self] in self?.onRun?() }
        inputView.onApply = { [weak self] in self?.onApply?() }
        inputView.onCancel = { [weak self] in self?.onClose?() }
        inputView.onModeKey = { [weak self] idx in
            self?.modeControl.selectedSegment = idx
            self?.onModeChange?(EditMode(rawValue: idx) ?? .rewrite)
        }
        inputView.onPushToTalkStart = { [weak self] in self?.onPushToTalkStart?() }
        inputView.onPushToTalkEnd = { [weak self] in self?.onPushToTalkEnd?() }
        inputView.delegate = self
        inputBox.addSubview(inputScroll)

        micButton.isBordered = false
        micButton.image = OverlayCardView.micIcon(active: false)
        micButton.target = self
        micButton.action = #selector(micTapped)
        micButton.toolTip = "按住 ⌥ 说话（或点这里）"
        addSubview(micButton)

        resultBox.radius = 9
        resultBox.isHidden = true
        addSubview(resultBox)

        configureScroll(resultScroll, textView: resultView, editable: false)
        resultView.isSelectable = true
        resultBox.addSubview(resultScroll)

        addSubview(hintLabel)

        styleButton(applyButton, title: "应用", primary: true)
        applyButton.target = self
        applyButton.action = #selector(applyTapped)
        addSubview(applyButton)

        styleButton(copyButton, title: "复制", primary: false)
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        addSubview(copyButton)

        styleButton(closeButton, title: "关闭", primary: false)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        addSubview(closeButton)

        hintLabel.stringValue = "↵ 执行 · ⌘↵ 应用 · 按住 ⌥ 说话 · esc 关闭"
        applyLayerColors()
    }

    /// 强制面板用深色 / 浅色外观。nil = 跟随系统。
    ///
    /// 面板是半透明毛玻璃，透出来的是背后的界面颜色。文字色如果只跟系统外观走，
    /// 「系统浅色 + 编辑器深色主题」就会变成深底黑字 —— 糊成一片。
    /// 这里把整张卡片（连同 panel）的外观一起换掉，语义色（labelColor /
    /// textBackgroundColor / tertiaryLabelColor）就会全部按新外观重新解析。
    func applyBackdrop(dark: Bool?) {
        let appearance = dark.flatMap { NSAppearance(named: $0 ? .darkAqua : .aqua) }
        self.appearance = appearance
        window?.appearance = appearance
        applyLayerColors()
        refreshTextColors()
        needsLayout = true
    }

    /// attributed string 里存的是动态色，换外观后要让结果区重画一遍
    private func refreshTextColors() {
        resultView.needsDisplay = true
        inputView.needsDisplay = true
        inputView.needsDisplay = true
    }

    /// layer 的 CGColor 不会跟着外观自动变，切换深浅色时手动刷一遍
    private func applyLayerColors() {
        background.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        // 底衬朝当前外观的窗口色靠，深色外观下变深、浅色外观下变白
        scrim.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.62)
        inputBox.fillColor = NSColor.textBackgroundColor.withAlphaComponent(0.60)
        inputBox.strokeColor = NSColor.labelColor.withAlphaComponent(0.16)
        resultBox.fillColor = NSColor.textBackgroundColor.withAlphaComponent(0.45)
        resultBox.strokeColor = NSColor.labelColor.withAlphaComponent(0.10)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerColors()
        needsLayout = true
    }

    /// 面板不是 key window 时（比如应用后面板留在屏幕上），
    /// 第一次点击也要能直接落到卡片上，而不是被系统吞掉只做激活
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    private func configureScroll(_ scroll: NSScrollView, textView: NSTextView, editable: Bool) {
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .allowed

        textView.isRichText = false
        textView.drawsBackground = false
        textView.isEditable = editable
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.font = NSFont.systemFont(ofSize: 13.5)
        textView.frame = NSRect(x: 0, y: 0, width: 100, height: 30)

        scroll.documentView = textView
    }

    private func styleButton(_ button: NSButton, title: String, primary: Bool) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11, weight: primary ? .semibold : .regular)
        // 两种状态都要显式设置：来回切模式时残留的强调色会让两个按钮看起来一样重
        button.bezelColor = primary ? NSColor.controlAccentColor : nil
        button.contentTintColor = primary ? .white : nil
    }

    // MARK: 高度与布局

    func preferredHeight() -> CGFloat {
        var h: CGFloat = padY * 2 + headerH + gapS + ctxH + gapS + 3 + inputHeight + gapM + footerH
        if showChips { h += chipsH + gapS }
        if showResult { h += gapM + resultHeight }
        return ceil(h)
    }

    private struct Rects {
        var header = NSRect.zero
        var ctx = NSRect.zero
        var chips = NSRect.zero
        var input = NSRect.zero
        var result = NSRect.zero
        var footer = NSRect.zero
    }

    private func rects(forHeight H: CGFloat) -> Rects {
        let W = bounds.width
        var r = Rects()
        var top = H - padY

        func take(_ h: CGFloat) -> NSRect {
            top -= h
            return NSRect(x: padX, y: top, width: W - padX * 2, height: h)
        }

        r.header = take(headerH)
        top -= gapS
        r.ctx = take(ctxH)
        top -= gapS
        if showChips {
            r.chips = take(chipsH)
            top -= gapS
        }
        top -= 3
        r.input = take(inputHeight)
        if showResult {
            top -= gapM
            r.result = take(resultHeight)
        }
        top -= gapM
        r.footer = take(footerH)
        return r
    }

    override func layout() {
        super.layout()
        applyLayerColors()
        scrim.frame = bounds
        let r = rects(forHeight: bounds.height)

        appIcon.frame = NSRect(x: r.header.minX, y: r.header.midY - 8, width: 16, height: 16)

        appLabel.sizeToFit()
        let appW = min(appLabel.frame.width, 160)
        appLabel.frame = NSRect(x: r.header.minX + 22, y: r.header.midY - 8, width: appW, height: 16)

        modeControl.frame = NSRect(x: r.header.maxX - 104, y: r.header.midY - 11, width: 104, height: 22)

        roleLabel.sizeToFit()
        let roleRight = modeControl.frame.minX - 10
        let roleLeft = r.header.minX + 22 + appW + 8
        let roleW = max(0, min(roleLabel.frame.width, roleRight - roleLeft))
        roleLabel.frame = NSRect(x: roleRight - roleW, y: r.header.midY - 7, width: roleW, height: 14)
        roleLabel.isHidden = roleW < 20

        ctxButton.frame = NSRect(x: r.ctx.maxX - 68, y: r.ctx.minY, width: 68, height: 16)
        ctxLabel.frame = NSRect(x: r.ctx.minX, y: r.ctx.minY + 1, width: r.ctx.width - 74, height: 15)

        layoutChips(in: r.chips)

        inputBox.frame = r.input
        micButton.frame = NSRect(x: r.input.maxX - 26, y: r.input.minY + 9, width: 18, height: 18)
        // 注意：inputScroll 是 inputBox 的子视图，坐标相对 inputBox
        inputScroll.frame = NSRect(x: 10,
                                   y: 8,
                                   width: r.input.width - 44,
                                   height: r.input.height - 16)

        resultBox.isHidden = !showResult
        resultBox.frame = r.result
        resultScroll.frame = NSRect(x: 10,
                                    y: 8,
                                    width: r.result.width - 20,
                                    height: r.result.height - 16)

        closeButton.frame = NSRect(x: r.footer.maxX - 46, y: r.footer.minY, width: 46, height: 20)
        if copyButton.isHidden {
            applyButton.frame = NSRect(x: closeButton.frame.minX - 8 - 58, y: r.footer.minY, width: 58, height: 20)
        } else {
            copyButton.frame = NSRect(x: closeButton.frame.minX - 6 - 46, y: r.footer.minY, width: 46, height: 20)
            applyButton.frame = NSRect(x: copyButton.frame.minX - 8 - 58, y: r.footer.minY, width: 58, height: 20)
        }
        hintLabel.frame = NSRect(x: r.footer.minX,
                                 y: r.footer.minY + 3,
                                 width: max(0, applyButton.frame.minX - r.footer.minX - 8),
                                 height: 14)

        fitDocument(inputScroll)
        fitDocument(resultScroll)
    }

    /// NSTextView 放进 NSScrollView 后必须自己跟住可视宽度，否则文本会按初始宽度换行
    private func fitDocument(_ scroll: NSScrollView) {
        guard let doc = scroll.documentView else { return }
        let target = scroll.contentSize
        var f = doc.frame
        var changed = false
        if abs(f.width - target.width) > 0.5 {
            f.size.width = target.width
            changed = true
        }
        if f.height < target.height {
            f.size.height = target.height
            changed = true
        }
        if changed { doc.frame = f }
    }

    private func layoutChips(in rect: NSRect) {
        chipsContainer.frame = rect
        var x: CGFloat = 0
        for chip in chips {
            chip.sizeToFit()
            var w = chip.frame.width + 18
            if w < 44 { w = 44 }
            if x + w > rect.width { break }
            chip.frame = NSRect(x: x, y: 0, width: w, height: rect.height)
            x += w + 6
        }
    }

    // MARK: 对外更新接口

    func update(context: CapturedContext, mode: EditMode, appIconImage: NSImage?) {
        appIcon.image = appIconImage
        appLabel.stringValue = context.appName.isEmpty ? "未知应用" : context.appName
        roleLabel.stringValue = context.hasElement ? context.roleText : "未捕获控件"
        modeControl.selectedSegment = mode.rawValue
        ctxLabel.stringValue = context.summaryLine
        needsLayout = true
    }

    func setContextSummary(_ text: String) {
        ctxLabel.stringValue = text
    }

    /// 同步分段控件 + 按钮主次。
    ///
    /// 以前问答模式会把「应用」整个换成「复制」：用户指着编辑器说「翻译成英文」，
    /// 面板里却只有「复制」，找不到应用按钮 —— 而他明明就是想写回原处。
    /// 现在「应用」永远在，只是问答模式下「复制」才是高亮的那个。
    func setMode(_ mode: EditMode) {
        modeControl.selectedSegment = mode.rawValue
        let applyPrimary = (mode == .rewrite)
        styleButton(applyButton, title: "应用", primary: applyPrimary)
        styleButton(copyButton, title: "复制", primary: !applyPrimary)
        applyButton.isHidden = false
        copyButton.isHidden = false
        applyButton.isEnabled = !isBusy
        copyButton.isEnabled = !isBusy
        needsLayout = true
    }

    func setSuggestions(_ items: [String]) {
        for chip in chips {
            chip.removeFromSuperview()
        }
        chips.removeAll()
        for item in items {
            let chip = ChipButton(frame: NSRect(x: 0, y: 0, width: 60, height: 20))
            chip.setChip(item)
            chip.target = self
            chip.action = #selector(chipTapped(_:))
            chip.toolTip = item
            chipsContainer.addSubview(chip)
            chips.append(chip)
        }
        showChips = !chips.isEmpty
        needsLayout = true
    }

    func clearResult() {
        resultView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        showResult = false
        resultHeight = 180
        setStatus("")
    }

    func appendResult(_ text: String, monospaced: Bool) {
        guard let storage = resultView.textStorage else { return }
        let font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            : NSFont.systemFont(ofSize: 13)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        storage.append(NSAttributedString(string: text, attributes: attrs))
        resultView.scrollToEndOfDocument(nil)
        if !showResult {
            showResult = true
        }
    }

    func setPlainResult(_ text: String, monospaced: Bool) {
        resultView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        appendResult(text, monospaced: monospaced)
        fitResultHeight()
    }

    /// 按真实排版高度撑开结果区，避免出现「内容被裁掉半行」
    @discardableResult
    func fitResultHeight(maxHeight: CGFloat = 320) -> Bool {
        guard showResult, let lm = resultView.layoutManager, let tc = resultView.textContainer else {
            return false
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let target = min(max(ceil(used) + 26, 96), maxHeight)
        if abs(target - resultHeight) > 1 {
            resultHeight = target
            return true
        }
        return false
    }

    func setStatus(_ text: String) {
        hintLabel.stringValue = text.isEmpty
            ? "↵ 执行 · ⌘↵ 应用 · 按住 ⌥ 说话 · esc 关闭"
            : text
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        applyButton.isEnabled = !busy
        copyButton.isEnabled = !busy
        // 生成中改文案，结束后恢复。不碰主次样式，否则高亮会丢
        applyButton.title = busy ? "生成中…" : "应用"
    }

    func setMicActive(_ active: Bool) {
        micButton.image = OverlayCardView.micIcon(active: active)
    }

    func focusInput() {
        window?.makeFirstResponder(inputView)
    }

    func updateInputHeight() {
        guard let lm = inputView.layoutManager, let tc = inputView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        var h = used + 18
        h = min(max(h, 46), 96)
        if abs(h - inputHeight) > 0.5 {
            inputHeight = h
            onInputChanged?()
        }
    }

    // MARK: 动作

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        onModeChange?(EditMode(rawValue: sender.selectedSegment) ?? .rewrite)
    }

    @objc private func toggleContext() {
        onToggleContext?()
    }

    @objc private func chipTapped(_ sender: ChipButton) {
        onChip?(sender.attributedTitle.string)
    }

    @objc private func micTapped() {
        onMic?()
    }

    @objc private func applyTapped() {
        onApply?()
    }

    @objc private func copyTapped() {
        onCopy?()
    }

    @objc private func closeTapped() {
        onClose?()
    }

    // MARK: 图标

    static func micIcon(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        let color = active ? NSColor.systemRed : NSColor.secondaryLabelColor
        color.setStroke()
        color.setFill()

        // 话筒头
        let capsule = NSBezierPath(roundedRect: NSRect(x: 6.6, y: 7.6, width: 4.8, height: 7.4),
                                   xRadius: 2.4, yRadius: 2.4)
        capsule.fill()

        // 拾音弧
        let arc = NSBezierPath()
        arc.lineWidth = 1.5
        arc.lineCapStyle = .round
        arc.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 5.2,
                      startAngle: 205, endAngle: 335, clockwise: false)
        arc.stroke()

        // 支架
        let stem = NSBezierPath()
        stem.lineWidth = 1.5
        stem.lineCapStyle = .round
        stem.move(to: NSPoint(x: 9, y: 4.2))
        stem.line(to: NSPoint(x: 9, y: 2.2))
        stem.stroke()

        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

// MARK: - 输入框代理

extension OverlayCardView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        inputView.needsDisplay = true
        updateInputHeight()
    }
}
