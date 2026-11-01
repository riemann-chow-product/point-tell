import Foundation

enum AppInfo {
    static let name = "PointTell"
    static let tagline = "指哪改哪 · 光标 AI 副驾"
    static let version = "0.1.0"
    static let bundleID = "com.pointtell.app"
    static let keychainService = "com.pointtell.apikey"
}

/// 编辑模式：就地改写 / 就地问答
enum EditMode: Int {
    case rewrite = 0
    case ask = 1

    var title: String {
        switch self {
        case .rewrite: return "改写"
        case .ask: return "问答"
        }
    }
}
