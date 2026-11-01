import Foundation

/// 一次请求所需的全部参数。抽出来是为了让「测试连接」能拿界面上的临时值试，
/// 而不是先把用户没保存的输入写进配置再试。
struct LLMConfig {
    var provider: LLMProvider
    var baseURL: String
    var model: String
    var apiKey: String
    var temperature: Double
    /// 隐私开关的当前值。设置窗口里「测试连接」要按界面上的勾选状态判断，而不是已保存的值。
    var localOnly: Bool

    static func current() -> LLMConfig {
        let s = Settings.shared
        return LLMConfig(provider: s.provider,
                         baseURL: s.baseURL,
                         model: s.model,
                         apiKey: s.apiKey,
                         temperature: s.temperature,
                         localOnly: s.localOnly)
    }

    var endpointURL: URL? { return LLMClient.endpoint(for: self) }

    var endpointDescription: String {
        return endpointURL?.absoluteString ?? "\(baseURL)（地址无效）"
    }

    /// 隐私模式拦截。返回 nil 表示放行。
    func gateError() -> String? {
        if localOnly && !provider.isLocal {
            return "已开启「仅本地运行」，不会向云端发请求。要测云端模型，请先取消勾选「仅本地运行」。"
        }
        return nil
    }
}

/// 轻量探测：只问「服务在不在、有哪些模型」，不发对话请求。
/// 用于「测试连接」第一步——比直接对话快得多，也能区分「服务没起」和「模型没装」。
final class LLMProbe {

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false

    static func modelsEndpoint(for config: LLMConfig) -> URL? {
        guard let chat = LLMClient.endpoint(for: config) else { return nil }
        var s = chat.absoluteString
        switch config.provider {
        case .ollama:
            if s.hasSuffix("/api/chat") { s = String(s.dropLast("/api/chat".count)) + "/api/tags" }
        case .openAI:
            if s.hasSuffix("/chat/completions") { s = String(s.dropLast("/chat/completions".count)) + "/models" }
        case .anthropic:
            if s.hasSuffix("/v1/messages") { s = String(s.dropLast("/v1/messages".count)) + "/v1/models" }
        }
        return URL(string: s)
    }

    /// completion(models, error)。models 为 nil 表示探测失败。
    func fetchModels(config: LLMConfig,
                     timeout: TimeInterval = 8,
                     completion: @escaping ([String]?, String?) -> Void) {
        guard let url = Self.modelsEndpoint(for: config) else {
            completion(nil, "接口地址无效：\(config.baseURL)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        if !config.apiKey.isEmpty {
            if config.provider == .anthropic {
                request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("Bearer " + config.apiKey, forHTTPHeaderField: "Authorization")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer " + config.apiKey, forHTTPHeaderField: "Authorization")
            }
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 5
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["Accept-Encoding": "identity"]

        let sess = URLSession(configuration: cfg)
        session = sess

        let t = sess.dataTask(with: request) { data, response, error in
            defer { sess.invalidateAndCancel() }
            if self.finished { return }
            self.finished = true

            if let e = error as NSError? {
                if e.code == NSURLErrorTimedOut {
                    completion(nil, "探测超时（\(url.absoluteString)），服务可能没在响应")
                } else if e.code == NSURLErrorCannotFindHost {
                    let host = url.host ?? config.baseURL
                    completion(nil, "域名解析失败：\(host) 不存在。检查是否拼错（i / l、1 / I 这类形近字符最容易错），或该域名需要内网/VPN")
                } else if e.code == NSURLErrorCannotConnectToHost {
                    completion(nil, "连不上 \(config.baseURL)。Ollama 是否已启动？试试 ollama serve")
                } else {
                    completion(nil, "探测失败：\(e.localizedDescription)")
                }
                return
            }

            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                // Anthropic 兼容层不一定实现 /v1/models，404 不代表服务不可用
                if http.statusCode == 404 && config.provider == .anthropic {
                    completion([], nil)
                    return
                }
                if http.statusCode == 401 || http.statusCode == 403 {
                    completion(nil, "API Key 无效或没填（HTTP \(http.statusCode)）")
                } else {
                    completion(nil, "HTTP \(http.statusCode)：\(body.truncated(160))")
                }
                return
            }

            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, "服务返回的不是预期格式：\(url.absoluteString)")
                return
            }

            var names: [String] = []
            if let list = obj["models"] as? [[String: Any]] {          // Ollama /api/tags
                for m in list {
                    if let n = m["name"] as? String { names.append(n) }
                    else if let n = m["model"] as? String { names.append(n) }
                }
            } else if let list = obj["data"] as? [[String: Any]] {      // OpenAI /v1/models
                for m in list {
                    if let n = m["id"] as? String { names.append(n) }
                }
            }
            completion(names, nil)
        }
        task = t
        t.resume()
    }

    func cancel() {
        finished = true
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
    }
}

/// 极简流式 LLM 客户端，同时兼容 Ollama(/api/chat, NDJSON) 与 OpenAI(/v1/chat/completions, SSE)。
/// 只做一件事：把增量文本吐出来。
final class LLMClient: NSObject {

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = ""
    private var rawBody = ""
    private var statusCode = 0
    private var sawDelta = false
    private var finished = false
    private var provider: LLMProvider = .ollama
    private var config: LLMConfig = .current()
    /// 看门狗：距离上一次收到数据的秒数。URLSession 的总超时是 180s，
    /// 但网络切换 / 代理挂掉时连接会「半开」——不报错也不来数据，
    /// 用户就干等三分钟，看起来就是卡死。这里 25 秒没动静直接判失败。
    private var idleTimer: DispatchSourceTimer?
    private var lastDataAt = Date()
    private let idleLimit: TimeInterval = 45
    /// 累计的「思考」字符数。思考模型（如 hy4-preview、claude 4.5、deepseek-r1）
    /// 会先吐一大段 thinking 再出正文，中间可能几十秒没有正文 —— 界面必须让用户知道它还活着。
    private var thinkingChars = 0
    /// 累计的正文（不含思考）。用于结束时识别网关把状态字当正文吐回来的情况。
    private var accumulated = ""

    var onDelta: ((String) -> Void)?
    /// 思考阶段的进度（累计字符数）。只用来更新状态栏文案，不进结果区。
    var onThinking: ((Int) -> Void)?
    var onFinish: ((String?) -> Void)?   // nil = 正常结束，否则为错误描述

    // MARK: 发起请求

    func start(messages: [ChatMessage],
               config: LLMConfig = .current(),
               timeout: TimeInterval = 180,
               maxTokens: Int? = nil) {
        self.config = config
        self.provider = config.provider
        self.accumulated = ""

        if let gate = config.gateError() {
            finish(error: gate)
            return
        }
        guard let url = Self.endpoint(for: config) else {
            finish(error: "接口地址无效：\(config.baseURL)\n示例：http://127.0.0.1:11434")
            return
        }
        if config.model.trimmed.isEmpty {
            finish(error: "模型名不能为空")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let key = config.apiKey
        PTLog.write("llm auth: provider=\(provider.rawValue) keyLen=\(key.count) "
            + (key.isEmpty ? "(空！)" : "head=\(String(key.prefix(4)))…"))
        // 云端模型没有 key 一定 401，提前说清楚，别让用户对着「认证失败」猜
        if key.isEmpty && !provider.isLocal {
            finish(error: "没有读到 API Key（当前服务商：\(provider.displayName)）。\n"
                + "打开设置 → 模型，把 Key 重新粘贴一次再保存。\n"
                + "如果刚重新编译过应用，旧钥匙串条目会因为签名变化读不出来，重存一次即可。")
            return
        }
        if provider == .anthropic {
            // Anthropic 官方用 x-api-key；部分中转/网关只认 Bearer，两个都带上，多出来的会被忽略
            if !key.isEmpty {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !key.isEmpty {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any]
        switch provider {
        case .ollama:
            var options: [String: Any] = ["temperature": config.temperature]
            if let cap = maxTokens { options["num_predict"] = cap }
            body = [
                "model": config.model,
                "stream": true,
                "messages": messages.map { $0.jsonObject() },
                "options": options
            ]

        case .openAI:
            body = [
                "model": config.model,
                "stream": true,
                "messages": messages.map { $0.jsonObject() },
                "temperature": config.temperature
            ]
            if let cap = maxTokens { body["max_tokens"] = cap }

        case .anthropic:
            // Anthropic 的 system 是顶层字段，不是一条 role=system 的消息；max_tokens 必填
            let systemText = messages
                .filter { $0.role == "system" }
                .map { $0.content }
                .joined(separator: "\n\n")
            var b: [String: Any] = [
                "model": config.model,
                // 推理模型会先用掉大量 token 思考，4096 常常不够，正文直接被截空
                "max_tokens": maxTokens ?? 8192,
                "stream": true,
                "temperature": min(max(config.temperature, 0), 1),
                "messages": messages
                    .filter { $0.role != "system" }
                    .map { $0.jsonObject() }
            ]
            // 推理/思考模型（hy4-preview、deepseek-r1、claude 思考版等）会把 thinking 与正文
            // 共用 max_tokens 预算：思考一膨胀就把正文截断成乱码（如 UNREGISTERED）。
            // 本工具是就地快改/翻译，不需要长篇推理，关掉思考既修这个 bug，又更快更省。
            if Self.isReasoningModel(config.model) {
                b["thinking"] = ["type": "disabled"]
            }
            if !systemText.isEmpty { b["system"] = systemText }
            body = b
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["Accept-Encoding": "identity"]

        let sess = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = sess
        let t = sess.dataTask(with: request)
        task = t
        lastDataAt = Date()
        startWatchdog()
        t.resume()

        PTLog.write("llm start: \(provider.rawValue) \(url.absoluteString) model=\(config.model)")
    }

    /// 每 5 秒看一次：超过 idleLimit 没收到任何字节就主动收尾
    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.finished else { return }
            let idle = Date().timeIntervalSince(self.lastDataAt)
            if idle >= self.idleLimit {
                PTLog.write("llm watchdog: \(Int(idle))s 没有数据，主动中断")
                self.finish(error: "模型 \(Int(idle)) 秒没有任何响应，已中断。\n"
                    + "可能是网络切换、代理断开，或服务端排队。稍后重试一次即可。")
            }
        }
        timer.resume()
        idleTimer = timer
    }

    private func stopWatchdog() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    /// 按模型名粗略判断是否为「推理/思考模型」。这类模型会先吐一大段 thinking，
    /// 与正文共用 max_tokens 预算，容易把正文截断，故对本工具默认关闭思考。
    private static func isReasoningModel(_ model: String) -> Bool {
        let m = model.lowercased()
        let marks = ["preview", "r1", "-r1", "reasoning", "thinking",
                     "deepseek-r", "o1", "o3", "o4", "qwq", "qwen3-thinking"]
        return marks.contains { m.contains($0) }
    }

    func cancel() {
        finished = true
        stopWatchdog()
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: 地址归一

    /// 把用户随手输入的地址补成可用的 endpoint。
    /// 常见手误：漏 http://、多结尾斜杠、已经填了完整路径。
    static func endpoint(for config: LLMConfig) -> URL? {
        var base = config.baseURL.trimmed
        if base.isEmpty { base = config.provider.defaultBaseURL }

        // 没写协议就补一个：本机/局域网用 http，公网用 https
        if !base.contains("://") {
            let hostPort = base.split(separator: "/").first.map(String.init) ?? base
            let host = hostPort.split(separator: ":").first.map(String.init) ?? hostPort
            let isLocal = !host.contains(".")
                || host.hasPrefix("127.")
                || host.hasPrefix("192.168.")
                || host.hasPrefix("10.")
                || host.hasPrefix("0.0.0.0")
                || host == "localhost"
            base = (isLocal ? "http://" : "https://") + base
        }
        while base.hasSuffix("/") { base = String(base.dropLast()) }

        var full: String
        switch config.provider {
        case .ollama:
            if base.hasSuffix("/api/chat") { full = base }
            else if base.hasSuffix("/api") { full = base + "/chat" }
            else { full = base + "/api/chat" }
        case .openAI:
            if base.hasSuffix("/chat/completions") { full = base }
            else if base.hasSuffix("/v1") { full = base + "/chat/completions" }
            else { full = base + "/v1/chat/completions" }
        case .anthropic:
            if base.hasSuffix("/messages") { full = base }
            else if base.hasSuffix("/v1") { full = base + "/messages" }
            else { full = base + "/v1/messages" }
        }

        guard let url = URL(string: full),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    // MARK: 内部

    private func emit(_ text: String) {
        if text.isEmpty { return }
        accumulated += text
        sawDelta = true
        DispatchQueue.main.async { [weak self] in
            self?.onDelta?(text)
        }
    }

    /// 思考增量：只累计长度，用来告诉用户「还在跑，已经想了 N 字」
    private func emitThinking(_ text: String) {
        if text.isEmpty { return }
        thinkingChars += text.count
        let total = thinkingChars
        DispatchQueue.main.async { [weak self] in
            self?.onThinking?(total)
        }
    }

    private func finish(error: String?) {
        if finished { return }
        finished = true
        stopWatchdog()
        session?.invalidateAndCancel()
        session = nil
        // 成功结束时，若正文整个就是一个网关状态字（如 UNREGISTERED），
        // 说明它不是真结果，而是 Key/模型未注册等状态被当正文吐回来了，转成清晰报错。
        var finalError = error
        if finalError == nil, sawDelta,
           let sentinel = Self.gatewayErrorIfSentinel(accumulated) {
            finalError = sentinel
        }
        let err = finalError
        DispatchQueue.main.async { [weak self] in
            self?.onFinish?(err)
        }
    }

    /// 某些中转/网关在 Key 或模型未注册、额度不足时，不返回标准错误，
    /// 而是把 "UNREGISTERED" / "INVALID_KEY" 这类状态字当成正文（HTTP 200）流式吐回来。
    /// 这种内容不是改写结果，要转成清晰报错，否则用户会看到裸状态字被当成翻译。
    private static func gatewayErrorIfSentinel(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 必须整段就是一个状态代号：长度受限，且只允许大写字母/数字/下划线
        //（无小写、无中文、无空格断句），避免误伤正常改写结果。
        guard (4...40).contains(t.count),
              t.range(of: "^[A-Z0-9_]+$", options: .regularExpression) != nil else { return nil }
        let u = t.uppercased()
        let markers = ["REGISTER", "QUOTA", "UNAUTH", "AUTH", "INVALID",
                       "EXPIRE", "FORBID", "DENY", "BAN", "DISABLE",
                       "UNAVAILABLE", "NOT_FOUND", "NOT_REGISTER"]
        guard markers.contains(where: { u.contains($0) }) else { return nil }
        return "模型接口返回了无效状态「\(t)」，通常是该 Key 或模型未在网关注册，或额度不足。\n"
            + "请到对应控制台确认 Key 对当前模型的访问权限，或更换一个已订阅的模型。"
    }

    private func handleLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }

        switch provider {
        case .openAI:
            guard trimmed.hasPrefix("data:") else { return }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                return
            }
            if let choices = obj["choices"] as? [[String: Any]],
               let first = choices.first {
                if let delta = first["delta"] as? [String: Any] {
                    // DeepSeek / 混元等推理模型把思考放在 reasoning_content
                    if let r = delta["reasoning_content"] as? String {
                        emitThinking(r)
                    }
                    if let c = delta["content"] as? String {
                        emit(c)
                    }
                } else if let message = first["message"] as? [String: Any],
                          let c = message["content"] as? String {
                    emit(c)
                }
            }

        case .anthropic:
            // SSE 里 event: 行不带内容，真正的内容都在 data: 的 content_block_delta
            guard trimmed.hasPrefix("data:") else { return }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                return
            }
            let type = obj["type"] as? String ?? ""
            if type == "content_block_delta", let delta = obj["delta"] as? [String: Any] {
                // 同一个事件里只会有一个字段：text / thinking / input_json_delta
                if let text = delta["text"] as? String {
                    emit(text)
                } else if let th = delta["thinking"] as? String {
                    emitThinking(th)
                }
            } else if type == "error" {
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "模型返回了错误"
                finish(error: msg)
            }

        case .ollama:
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                return
            }
            if let err = obj["error"] as? String {
                finish(error: err)
                return
            }
            if let message = obj["message"] as? [String: Any],
               let c = message["content"] as? String {
                emit(c)
            }
        }
    }
}

extension LLMClient: URLSessionDataDelegate {

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            statusCode = http.statusCode
            let ct = http.value(forHTTPHeaderField: "Content-Type") ?? "-"
            PTLog.write("llm resp: HTTP \(http.statusCode) type=\(ct)")
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lastDataAt = Date()
        guard let text = String(data: data, encoding: .utf8) else { return }
        rawBody += text
        if rawBody.count <= 800 {
            PTLog.write("llm chunk \(data.count)B: \(text.truncated(200).replacingOccurrences(of: "\n", with: "⏎"))")
        }

        if statusCode >= 400 {
            if rawBody.count > 4000 { rawBody = String(rawBody.suffix(4000)) }
            return
        }

        buffer += text
        while let nl = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<nl.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<nl.upperBound)
            handleLine(line)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        PTLog.write("llm done: status=\(statusCode) sawDelta=\(sawDelta) bodyLen=\(rawBody.count) err=\(error.map { "\($0)" } ?? "nil")")
        if finished { return }

        if let e = error {
            let ns = e as NSError
            if ns.code == NSURLErrorCancelled { return }
            finish(error: friendlyError(ns))
            return
        }

        if statusCode >= 400 {
            finish(error: httpError(statusCode, body: rawBody))
            return
        }

        // 服务端没走流式：把整个 body 当一次性响应解析
        if !sawDelta && !rawBody.isEmpty {
            parseWholeBody()
        }

        // 思考模型把预算全花在 thinking 上时，正文是空的 —— 这不是「没反应」，得说清楚
        if !sawDelta && thinkingChars > 0 {
            finish(error: "模型只输出了思考过程（\(thinkingChars) 字），没有产出正文。\n"
                + "通常是输出预算被思考吃完了：把指令说得更具体，或换一个非推理模型再试。")
            return
        }

        if !sawDelta && rawBody.isEmpty {
            finish(error: "模型没有返回内容")
            return
        }
        finish(error: nil)
    }

    private func parseWholeBody() {
        guard let data = rawBody.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return
        }
        if provider == .ollama,
           let message = obj["message"] as? [String: Any],
           let c = message["content"] as? String {
            emit(c)
            return
        }
        if provider == .anthropic, let blocks = obj["content"] as? [[String: Any]] {
            for b in blocks where (b["type"] as? String) == "text" {
                if let t = b["text"] as? String { emit(t) }
            }
            return
        }
        if let choices = obj["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let c = message["content"] as? String {
            emit(c)
        }
    }

    /// HTTP 状态码 → 告诉用户该改哪个框
    private func httpError(_ code: Int, body: String) -> String {
        let detail = body.trimmed.isEmpty ? "" : "：\(body.truncated(200))"
        switch code {
        case 401, 403:
            return "认证失败（HTTP \(code)），API Key 可能无效或没填\(detail)"
        case 404:
            switch provider {
            case .ollama:
                return "接口或模型不存在（HTTP 404）。检查「接口地址」是否为 http://127.0.0.1:11434，「模型名」是否已 ollama pull\(detail)"
            case .openAI:
                return "接口路径不存在（HTTP 404）。「接口地址」通常应填到 .../v1\(detail)"
            case .anthropic:
                return "接口路径不存在（HTTP 404）。Anthropic 兼容地址要填到 .../anthropic 这一层，例如 https://api.lkeap.cloud.tencent.com/plan/anthropic\(detail)"
            }
        case 429:
            return "请求被限流或额度不足（HTTP 429）\(detail)"
        case 500...599:
            return "模型服务内部错误（HTTP \(code)）\(detail)"
        default:
            return "HTTP \(code)\(detail)"
        }
    }

    private func friendlyError(_ e: NSError) -> String {
        let host = URL(string: config.baseURL.contains("://") ? config.baseURL : "https://" + config.baseURL)?.host
            ?? config.baseURL
        switch e.code {
        case NSURLErrorCannotFindHost:
            // 域名解析失败 = 拼写错误或需要内网/VPN，和「服务没启动」是两回事
            return "域名解析失败：\(host) 不存在。检查是否拼错（形近字母 i / l、1 / I 最容易错），或该域名需要内网/VPN 才能访问"
        case NSURLErrorCannotConnectToHost:
            if config.provider == .ollama {
                return "连不上模型服务（\(config.baseURL)）。Ollama 是否已启动？试试 ollama serve"
            }
            return "连不上 \(host) 的 \(URL(string: config.baseURL.contains("://") ? config.baseURL : "https://" + config.baseURL)?.port ?? 443) 端口，检查地址和网络"
        case NSURLErrorTimedOut:
            return "请求超时。本地小模型可能太慢，或服务没在响应"
        case NSURLErrorNotConnectedToInternet:
            return "网络不可用"
        case NSURLErrorUnsupportedURL, NSURLErrorBadURL:
            return "接口地址格式不对：\(config.baseURL)\n示例：http://127.0.0.1:11434"
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "系统拦下了明文 HTTP 请求（ATS）"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "TLS 握手失败：\(host) 的证书有问题，或该地址其实是 http 不是 https"
        default:
            return "请求失败：\(e.localizedDescription)"
        }
    }
}
