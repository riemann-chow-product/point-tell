import Foundation

struct ChatMessage {
    let role: String
    let content: String

    func jsonObject() -> [String: Any] {
        return ["role": role, "content": content]
    }
}

enum PromptBuilder {

    static func systemPrompt(mode: EditMode, context: CapturedContext) -> String {
        switch mode {
        case .rewrite:
            var s = """
            你是 PointTell，一个运行在 macOS 上的「光标就地编辑器」。
            用户用光标指着某个应用里的一处内容，然后用一句自然语言告诉你要怎么改。
            你会收到该处的上下文（应用、控件类型、光标附近的原文或选中文本）。

            严格遵守：
            1. 只输出改写后的文本本身。不要解释、不要客套、不要 Markdown 代码围栏。
            2. 保持原有的缩进、换行、命名风格和编程语言；代码就输出代码。
            3. 如果原文是代码片段，只改动用户要求的部分，其余原样保留。
            4. 如果信息不足以完成，输出最保守的最小改动。
            5. 如果用户其实是在提问（而不是要求改写），直接给出简短答案，不要硬凑替换文本。
            """
            if context.isEditable {
                s += "\n6. 当前控件可编辑，你的输出会被直接粘贴回光标处，因此必须是「可替换的成品文本」。"
            } else {
                s += "\n6. 当前控件不可编辑，输出会展示给用户看，请保持简洁完整。"
            }
            return s

        case .ask:
            return """
            你是 PointTell，一个运行在 macOS 上的「光标问答助手」。
            用户用光标指着屏幕上的一处内容（一段文字、一个表格区域、一个单元格），然后问一句话。
            你会收到该处的上下文。

            严格遵守：
            1. 直接回答问题，必要时引用上下文里的具体值、代码行或单元格。
            2. 简洁优先：默认不超过 120 字；用户要求详细时再展开。
            3. 不确定就说不知道，不要编造上下文里没有的数据。
            4. 不要输出 Markdown 代码围栏，除非用户明确要代码。
            """
        }
    }

    static func userPrompt(mode: EditMode, context: CapturedContext, question: String) -> String {
        var text = context.promptBlock()
        text += "\n\n"
        switch mode {
        case .rewrite:
            text += "【指令】" + question
        case .ask:
            text += "【问题】" + question
        }
        return text
    }

    static func messages(mode: EditMode, context: CapturedContext, question: String) -> [ChatMessage] {
        return [
            ChatMessage(role: "system", content: systemPrompt(mode: mode, context: context)),
            ChatMessage(role: "user", content: userPrompt(mode: mode, context: context, question: question))
        ]
    }

    /// 面板上的快捷指令，按控件类型给不同的预设
    static func suggestions(mode: EditMode, context: CapturedContext) -> [String] {
        let role = context.role
        let isTable = !context.tablePreview.isEmpty
            || role == "AXCell" || role == "AXRow" || role == "AXTable"

        if mode == .ask {
            if isTable { return ["这块的趋势怎么样", "有没有异常值", "一句话总结这块数据"] }
            if context.isEditable { return ["这段有什么问题", "解释一下这段", "怎么改更好"] }
            return ["这句话什么意思", "帮我总结一下", "有什么问题"]
        }

        if isTable { return ["整理成一句话", "算出环比变化", "标出异常项"] }
        if context.isEditable || role == "AXTextArea" {
            return ["加注释", "加参数校验", "补错误处理"]
        }
        return ["改得更简洁", "翻译成英文", "改成正式语气"]
    }
}
