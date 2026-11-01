import Cocoa

// PointTell 入口：纯菜单栏 / 悬浮面板形态，不占用 Dock。
let ptApp = NSApplication.shared
let ptDelegate = AppDelegate()
ptApp.delegate = ptDelegate
ptApp.setActivationPolicy(.accessory)
PTLog.installExceptionLogger()
ptApp.run()
