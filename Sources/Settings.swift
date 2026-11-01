import Foundation
import Carbon

enum LLMProvider: String, CaseIterable {
    case ollama = "ollama"
    case openAI = "openai"
    case anthropic = "anthropic"

    var displayName: String {
        switch self {
        case .ollama: return "Ollama（本地）"
        case .openAI: return "OpenAI 兼容 API"
        case .anthropic: return "Anthropic 兼容协议"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .ollama: return "http://127.0.0.1:11434"
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        }
    }

    var defaultModel: String {
        switch self {
        case .ollama: return "qwen2.5-coder:7b"
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-4-5"
        }
    }

    var isLocal: Bool { return self == .ollama }

    /// 协议简称，用在提示文案里
    var protocolName: String {
        switch self {
        case .ollama: return "Ollama /api/chat"
        case .openAI: return "OpenAI /v1/chat/completions"
        case .anthropic: return "Anthropic /v1/messages"
        }
    }
}

/// 面板配色策略
enum PanelTheme: String, CaseIterable {
    /// 按光标处界面的亮度自动切（需要屏幕录制权限）
    case auto = "auto"
    case dark = "dark"
    case light = "light"

    var displayName: String {
        switch self {
        case .auto: return "自动（跟随背后界面）"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }
}

/// 全局配置。API Key 单独走 Keychain。
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("PointTellSettingsDidChange")

    private let d = UserDefaults.standard

    /// 批量写入期间挂起通知，避免一次保存触发十几次「重建状态栏菜单」
    private var batching = false
    private var pendingNotify = false

    private func notify() {
        if batching {
            pendingNotify = true
            return
        }
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }

    /// 一次性改多项配置：只在最后发一次变更通知
    func batch(_ body: () -> Void) {
        batching = true
        body()
        batching = false
        if pendingNotify {
            pendingNotify = false
            NotificationCenter.default.post(name: Settings.didChange, object: nil)
        }
    }

    // MARK: 模型

    var provider: LLMProvider {
        get { return LLMProvider(rawValue: d.string(forKey: "provider") ?? "") ?? .ollama }
        set { d.set(newValue.rawValue, forKey: "provider"); notify() }
    }

    var baseURL: String {
        get {
            if let v = d.string(forKey: "baseURL." + provider.rawValue), !v.isEmpty { return v }
            return provider.defaultBaseURL
        }
        set { d.set(newValue, forKey: "baseURL." + provider.rawValue); notify() }
    }

    var model: String {
        get {
            if let v = d.string(forKey: "model." + provider.rawValue), !v.isEmpty { return v }
            return provider.defaultModel
        }
        set { d.set(newValue, forKey: "model." + provider.rawValue); notify() }
    }

    var apiKey: String {
        get { return Keychain.get(account: provider.rawValue) }
    }

    func baseURL(for p: LLMProvider) -> String {
        if let v = d.string(forKey: "baseURL." + p.rawValue), !v.isEmpty { return v }
        return p.defaultBaseURL
    }

    func setBaseURL(_ value: String, for p: LLMProvider) {
        d.set(value, forKey: "baseURL." + p.rawValue)
        notify()
    }

    func model(for p: LLMProvider) -> String {
        if let v = d.string(forKey: "model." + p.rawValue), !v.isEmpty { return v }
        return p.defaultModel
    }

    func setModel(_ value: String, for p: LLMProvider) {
        d.set(value, forKey: "model." + p.rawValue)
        notify()
    }

    func setAPIKey(_ value: String) {
        Keychain.set(value, account: provider.rawValue)
        notify()
    }

    var temperature: Double {
        get {
            if d.object(forKey: "temperature") == nil { return 0.2 }
            return d.double(forKey: "temperature")
        }
        set { d.set(newValue, forKey: "temperature"); notify() }
    }

    // MARK: 行为

    /// 上下文最多带多少字符进模型（本地模型可以调小）
    var maxContextChars: Int {
        get {
            let v = d.integer(forKey: "maxContextChars")
            return v > 0 ? v : 1200
        }
        set { d.set(newValue, forKey: "maxContextChars"); notify() }
    }

    /// 表格控件是否额外抓取表头 + 当前行
    var includeTableContext: Bool {
        get {
            if d.object(forKey: "includeTableContext") == nil { return true }
            return d.bool(forKey: "includeTableContext")
        }
        set { d.set(newValue, forKey: "includeTableContext"); notify() }
    }

    /// 流式结束后自动粘贴回光标处
    var autoApply: Bool {
        get { return d.bool(forKey: "autoApply") }
        set { d.set(newValue, forKey: "autoApply"); notify() }
    }

    /// 隐私模式：只允许本机模型，禁止任何出网请求
    var localOnly: Bool {
        get {
            if d.object(forKey: "localOnly") == nil { return true }
            return d.bool(forKey: "localOnly")
        }
        set { d.set(newValue, forKey: "localOnly"); notify() }
    }

    var speechLocale: String {
        get { return d.string(forKey: "speechLocale") ?? "zh-CN" }
        set { d.set(newValue, forKey: "speechLocale"); notify() }
    }

    /// 面板配色：默认自动，按光标处界面的明暗切
    var panelTheme: PanelTheme {
        get { return PanelTheme(rawValue: d.string(forKey: "panelTheme") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "panelTheme"); notify() }
    }

    var preferOnDeviceSpeech: Bool {
        get {
            if d.object(forKey: "preferOnDeviceSpeech") == nil { return true }
            return d.bool(forKey: "preferOnDeviceSpeech")
        }
        set { d.set(newValue, forKey: "preferOnDeviceSpeech"); notify() }
    }

    // MARK: 快捷键

    var hotkeyKeyCode: UInt32 {
        get {
            if d.object(forKey: "hotkeyKeyCode") == nil { return 35 } // P
            return UInt32(d.integer(forKey: "hotkeyKeyCode"))
        }
        set { d.set(Int(newValue), forKey: "hotkeyKeyCode"); notify() }
    }

    var hotkeyModifiers: UInt32 {
        get {
            if d.object(forKey: "hotkeyModifiers") == nil { return UInt32(controlKey | optionKey) }
            return UInt32(d.integer(forKey: "hotkeyModifiers"))
        }
        set { d.set(Int(newValue), forKey: "hotkeyModifiers"); notify() }
    }

    var hotkeyText: String {
        return hotkeyDisplayString(keyCode: hotkeyKeyCode, carbonModifiers: hotkeyModifiers)
    }

    // MARK: 隐私守卫

    /// 当前配置是否允许发起请求
    func requestGate() -> String? {
        if localOnly && !provider.isLocal {
            return "隐私模式已开启：请切换到本地 Ollama，或在设置中关闭「仅本地」"
        }
        return nil
    }
}
