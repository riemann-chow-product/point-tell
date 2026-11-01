import Cocoa
import Darwin

/// 判断「光标下面那块界面」是深色还是浅色。
///
/// 为什么需要它：面板是半透明毛玻璃，透出来的是背后的界面颜色。
/// 文字颜色如果只跟系统外观走，就会遇到最常见的翻车组合 ——
/// **系统是浅色、编辑器是深色主题**：毛玻璃透出深底，文字却还是黑的，糊成一片。
///
/// 所以每次唤起面板时采一次样，按背景亮度决定面板整体用深色还是浅色外观
/// （文字、输入框、结果区、按钮会一起跟着变）。
///
/// 需要「屏幕录制」权限。没权限时返回 nil，调用方退回跟随系统外观。
enum ScreenSampler {

    /// 命令行工具带的 SDK 头文件里没有 `CGPreflightScreenCaptureAccess`，
    /// 但 10.15+ 的系统库里一定有，所以运行时按符号找一次。
    private static let preflight: (() -> Bool)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                              "CGPreflightScreenCaptureAccess") else { return nil }
        typealias Fn = @convention(c) () -> Bool
        return unsafeBitCast(sym, to: Fn.self)
    }()

    /// 屏幕录制权限是否已授予
    static var hasPermission: Bool {
        guard let check = preflight else { return true }  // 老系统没有这个概念
        return check()
    }

    private static let request: (() -> Bool)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "CGRequestScreenCaptureAccess") else { return nil }
        typealias Fn = @convention(c) () -> Bool
        return unsafeBitCast(sym, to: Fn.self)
    }()

    /// 弹一次系统授权框，把本应用加进「屏幕录制」列表。
    /// 授权后系统通常要求退出并重新打开应用才生效。
    @discardableResult
    static func requestPermission() -> Bool {
        guard let ask = request else { return false }
        return ask()
    }

    /// NS 坐标（左下原点）→ CG 全局坐标（左上原点，以主屏为基准）
    private static func cgRect(from ns: NSRect) -> CGRect {
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: ns.minX, y: mainH - ns.maxY, width: ns.width, height: ns.height)
    }

    /// 采样一块区域的「代表亮度」：0 = 纯黑，1 = 纯白。取不到返回 nil。
    static func averageLuminance(in nsRect: NSRect) -> Double? {
        guard hasPermission else { return nil }
        let rect = cgRect(from: nsRect).integral
        guard rect.width >= 2, rect.height >= 2 else { return nil }
        guard let image = capture(rect) else { return nil }
        return medianLuminance(of: image)
    }

    @available(macOS, deprecated: 14.0, message: "CGWindowListCreateImage 在 14 之后标废弃，但 10.15 目标只能用这个")
    private static func capture(_ rect: CGRect) -> CGImage? {
        return CGWindowListCreateImage(rect, .optionOnScreenBelowWindow, kCGNullWindowID, [.bestResolution])
    }

    /// 先降采样到 8×8，再取**中位数**亮度。
    /// 用中位数而不是平均值：文字、光标、边框这些局部像素要么很黑要么很白，
    /// 平均值会被它们带偏，中位数基本就是「这块区域的地色」。
    private static func medianLuminance(of image: CGImage) -> Double? {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels,
                                  width: side, height: side,
                                  bitsPerComponent: 8,
                                  bytesPerRow: side * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var values: [Double] = []
        values.reserveCapacity(side * side)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255.0
            let g = Double(pixels[i + 1]) / 255.0
            let b = Double(pixels[i + 2]) / 255.0
            // sRGB 相对亮度（人眼对绿最敏感）
            values.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    /// 光标 / 控件附近是不是深色背景。
    /// - Parameter rect: 光标下控件的屏幕区域；为 nil 时退回鼠标周围一小块
    /// - Returns: true = 深色背景，false = 浅色背景，nil = 判断不了（没权限 / 取图失败）
    static func isDarkBackdrop(around rect: NSRect?) -> Bool? {
        let area: NSRect
        if let r = rect, r.width > 8, r.height > 8 {
            // 取控件中间那块，避开边框、圆角和滚动条
            let inset = min(r.width, r.height) * 0.25
            area = r.insetBy(dx: inset, dy: inset)
        } else {
            let m = NSEvent.mouseLocation
            area = NSRect(x: m.x - 30, y: m.y - 20, width: 60, height: 40)
        }
        guard let lum = averageLuminance(in: area) else { return nil }
        PTLog.write("sampler: luminance=\(String(format: "%.2f", lum)) → \(lum < 0.5 ? "深色" : "浅色")背景")
        return lum < 0.5
    }
}
