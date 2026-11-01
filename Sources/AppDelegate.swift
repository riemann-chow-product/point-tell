import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let statusBar = StatusBarController()
    private let overlay = OverlayController()
    private let hotkey = HotkeyManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBuilder.install()
        AppFocusTracker.shared.start()

        statusBar.setup()
        statusBar.onOpen = { [weak self] in self?.overlay.toggle() }
        statusBar.onSettings = { SettingsWindowController.shared.show() }
        statusBar.onOnboarding = { OnboardingController.shared.show() }
        statusBar.onQuit = { NSApp.terminate(nil) }

        registerHotkey()

        NotificationCenter.default.addObserver(forName: Settings.didChange,
                                              object: nil,
                                              queue: .main) { [weak self] _ in
            self?.registerHotkey()
            self?.statusBar.refresh()
        }

        // 应用激活状态直接影响「第一次点击能不能落到按钮上」，出问题时这两行日志能定位
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                              object: nil, queue: .main) { _ in
            PTLog.write("app: became active")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                              object: nil, queue: .main) { _ in
            PTLog.write("app: resigned active")
        }

        PTLog.write("launched. accessibility=\(AXIsProcessTrusted()) hotkey=\(Settings.shared.hotkeyText) args=\(CommandLine.arguments.dropFirst().joined(separator: " "))")

        // 方便直接从命令行打开设置：open -a PointTell --args --settings
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                SettingsWindowController.shared.show()
            }
            return
        }

        // 自检：在真应用环境里跑一次「点保存」，验证 commit 是否落盘
        if CommandLine.arguments.contains("--selftest-save") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                SettingsWindowController.shared.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    PTLog.write("selftest: about to click save")
                    SettingsWindowController.shared.triggerButton(titled: "保存")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        let d = UserDefaults.standard
                        PTLog.write("selftest: provider=\(d.string(forKey: "provider") ?? "nil") "
                            + "baseURL.anthropic=\(d.string(forKey: "baseURL.anthropic") ?? "nil") "
                            + "visible=\(SettingsWindowController.shared.window?.isVisible ?? false)")
                        NSApp.terminate(nil)
                    }
                }
            }
            return
        }

        // 自检：填好一套 Anthropic 配置 → 保存 → 重新打开 → 看字段是否回填正确
        if CommandLine.arguments.contains("--selftest-roundtrip") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let wc = SettingsWindowController.shared
                wc.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    wc.fillForTesting(providerIndex: 2,
                                      baseURL: "https://api.lkeap.cloud.tencent.com/plan/anthropic",
                                      model: "hy4-preview",
                                      key: "sk-selftest-key-0123456789")
                    PTLog.writeSync("roundtrip: 填入后 \(wc.readForTesting())")
                    wc.triggerButton(titled: "保存")

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        PTLog.writeSync("roundtrip: 保存后 visible=\(wc.window?.isVisible ?? false)")
                        PTLog.writeSync("roundtrip: defaults provider=\(UserDefaults.standard.string(forKey: "provider") ?? "nil") "
                            + "baseURL=\(UserDefaults.standard.string(forKey: "baseURL.anthropic") ?? "nil") "
                            + "model=\(UserDefaults.standard.string(forKey: "model.anthropic") ?? "nil") "
                            + "localOnly=\(UserDefaults.standard.object(forKey: "localOnly") ?? "nil")")
                        PTLog.writeSync("roundtrip: keychain len=\(Keychain.get(account: LLMProvider.anthropic.rawValue).count)")

                        // 重新打开，验证回填
                        wc.show()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            PTLog.writeSync("roundtrip: 重开后 \(wc.readForTesting())")
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
            return
        }

        // 自检触发：命令行参数在 `open` 下不可靠，改用触发文件
        func wants(_ flag: String) -> Bool {
            if CommandLine.arguments.contains(flag) { return true }
            let path = "/tmp/pointtell-" + flag.replacingOccurrences(of: "--", with: "")
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
                return true
            }
            return false
        }

        // 自检：验证「输完指令直接点应用」能走完 生成 → 回写 全链路。
        // 用 dry-run 粘贴，避免把测试文本粘进用户正在编辑的文档。
        // `-rw` 变体强制改写模式，用来验证「应用后面板停留 + 倒计时收起」。
        // `ask-apply` 变体强制问答模式，验证「问答模式下也有应用按钮、也能写回」。
        let wantApplyRewrite = wants("--selftest-apply-rw")
        let wantAskApply = wants("--selftest-ask-apply")
        if wantApplyRewrite || wantAskApply || wants("--selftest-apply") {
            Paster.dryRun = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let ov = self.overlay
                ov.dbgOpenWithInstruction("给这个函数加参数校验")
                if wantApplyRewrite { ov.dbgForceMode(.rewrite) }
                if wantAskApply { ov.dbgForceMode(.ask) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    PTLog.writeSync("selftest: before apply — \(ov.dbgSnapshot())")
                    ov.dbgTapApply()
                    PTLog.writeSync("selftest: after apply — \(ov.dbgSnapshot())")

                    // 生成是流式的，等它跑完（最多 90s）
                    var waited = 0.0
                    func poll() {
                        waited += 1.0
                        let snap = ov.dbgSnapshot()
                        if snap.contains("client=nil") && !snap.contains("resultLen=0") {
                            PTLog.writeSync("selftest: generation done — \(snap)")
                            // 改写模式还要再等「应用后停留」的窗口，多观察 6 秒
                            let extra: Double = (wantApplyRewrite || wantAskApply) ? 6 : 1.5
                            DispatchQueue.main.asyncAfter(deadline: .now() + extra) {
                                PTLog.writeSync("selftest: final — \(ov.dbgSnapshot())")
                                NSApp.terminate(nil)
                            }
                            return
                        }
                        if waited >= 90 {
                            PTLog.writeSync("selftest: TIMEOUT — \(snap)")
                            NSApp.terminate(nil)
                            return
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { poll() }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { poll() }
                }
            }
            return
        }

        if !AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                OnboardingController.shared.show()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    private func registerHotkey() {
        let s = Settings.shared
        hotkey.register(keyCode: s.hotkeyKeyCode, carbonModifiers: s.hotkeyModifiers) { [weak self] in
            self?.overlay.toggle()
        }
    }
}

/// 没有主菜单的话，文本框里的 ⌘C / ⌘V / ⌘A 会失效，所以装一个最小的。
enum MenuBuilder {
    static func install() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 PointTell", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 PointTell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}
