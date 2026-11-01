import Cocoa

/// 记住「用户上一个真正在用的应用」。
/// 面板弹出时 PointTell 会变成 frontmost，所以必须在打开面板之前就知道要把结果送回谁。
final class AppFocusTracker {

    static let shared = AppFocusTracker()

    private(set) var lastExternalApp: NSRunningApplication?

    func start() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != AppInfo.bundleID {
            lastExternalApp = front
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        if app.bundleIdentifier == AppInfo.bundleID { return }
        lastExternalApp = app
    }
}
