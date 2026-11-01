import Cocoa
import ApplicationServices

/// 首次运行 / 手动打开的使用说明 + 权限引导
final class OnboardingController {

    static let shared = OnboardingController()

    private var window: NSWindow?

    func show() {
        if window == nil { build() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                         styleMask: [.titled, .closable],
                         backing: .buffered,
                         defer: false)
        w.title = "开始使用 PointTell"
        w.isReleasedWhenClosed = false
        window = w

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 440))
        w.contentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let title = makeLabel("光标指到哪，AI 就改哪", size: 20, weight: .semibold)
        stack.addArrangedSubview(title)

        let sub = makeLabel("不用复制、不用切窗口、不用解释「我在看什么」。\n把光标悬停在目标上，按 \(Settings.shared.hotkeyText)，说一句话。", size: 12.5, color: .secondaryLabelColor)
        sub.maximumNumberOfLines = 3
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(20, after: sub)

        stack.addArrangedSubview(stepRow(
            index: "1",
            title: "辅助功能权限（必须）",
            detail: "用来读取光标下方的控件文本，并把结果粘贴回去。",
            buttonTitle: "打开系统设置",
            action: #selector(openAccessibility)
        ))
        stack.addArrangedSubview(stepRow(
            index: "2",
            title: "麦克风 + 语音识别（可选）",
            detail: "按住 ⌥ 说话，指令直接变成文字。也可以纯键盘输入。",
            buttonTitle: "授权",
            action: #selector(requestSpeech)
        ))
        stack.addArrangedSubview(stepRow(
            index: "3",
            title: "模型：默认本机 Ollama",
            detail: "默认 http://127.0.0.1:11434，推荐 qwen2.5-coder:7b。\n不想本地跑就切到任意 OpenAI 兼容 API。",
            buttonTitle: "打开设置",
            action: #selector(openSettings)
        ))

        let footer = makeLabel("抓取只发生在按下快捷键的瞬间，不持续监听屏幕，也不上传剪贴板。", size: 11, color: .tertiaryLabelColor)
        footer.maximumNumberOfLines = 2
        stack.addArrangedSubview(footer)

        let start = NSButton(title: "知道了", target: self, action: #selector(closeSelf))
        start.bezelStyle = .rounded
        start.keyEquivalent = "\r"
        start.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(start)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),

            start.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            start.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
    }

    private func stepRow(index: String, title: String, detail: String, buttonTitle: String, action: Selector) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12

        let badge = makeLabel(index, size: 11, weight: .semibold, color: .white)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.layer?.cornerRadius = 9
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 18).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 18).isActive = true
        row.addArrangedSubview(badge)

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(makeLabel(title, size: 13, weight: .medium))
        let d = makeLabel(detail, size: 11.5, color: .secondaryLabelColor)
        d.maximumNumberOfLines = 3
        text.addArrangedSubview(d)
        row.addArrangedSubview(text)

        let button = NSButton(title: buttonTitle, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(button)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return row
    }

    @objc private func openAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func requestSpeech() {
        SpeechRecognizer.requestPermissions { ok, message in
            let alert = NSAlert()
            alert.messageText = ok ? "已授权" : "未授权"
            alert.informativeText = ok ? "现在可以按住 ⌥ 说话了。" : (message ?? "")
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func closeSelf() {
        window?.close()
    }
}
