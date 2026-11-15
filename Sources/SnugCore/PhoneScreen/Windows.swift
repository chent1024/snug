// 窗口的身份。窗口用「进程号 + 系统窗口编号」认（WindowKey）：编号在本次登录内唯一，
// 不会像辅助功能的窗口对象那样过期，也能写进还原记录，崩溃重启后照样找得到
import CoreGraphics
import Foundation

public struct WindowKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let pid: Int32
    /// CGWindowID
    public let id: UInt32
    /// 内核进程启动秒数与本次开机身份；可选仅用于读取旧单窗记录。
    public let launchTime: Double?
    public let bootSession: String?

    public init(pid: Int32, id: UInt32, launchTime: Double? = nil, bootSession: String? = nil) {
        self.pid = pid
        self.id = id
        self.launchTime = launchTime
        self.bootSession = bootSession
    }

    public var description: String { "\(pid)/\(id)" }
}

/// App 资源库里的一个窗口
public struct WindowInfo: Equatable, Identifiable, Sendable {
    public let key: WindowKey
    public let app: String
    public let bundleID: String?
    public let title: String
    /// 列表上标「已最小化」
    public let minimized: Bool

    public init(key: WindowKey, app: String, bundleID: String?, title: String, minimized: Bool = false) {
        self.key = key
        self.app = app
        self.bundleID = bundleID
        self.title = title
        self.minimized = minimized
    }

    public var id: WindowKey { key }
    /// 日志里用：App 名 +「标题前 30 个字」
    public var label: String { title.isEmpty ? app : "\(app)「\(title.prefix(30))」" }

    /// 去掉标题里看不见的格式字符（零宽空格、方向标记……）：有的网页往标题里塞隐形水印，卡片上白占一截宽度。
    /// 零宽连接符留着，组合表情要靠它
    public static func visibleTitle(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter { $0.properties.generalCategory != .format || $0 == "\u{200D}" }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
    }
}

extension CGRect {
    /// 两个框在 2 点以内算对上（App 会把尺寸取整，跨屏还会差一两点）
    public func matches(_ other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) < tolerance && abs(minY - other.minY) < tolerance
            && abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }

    /// 日志里用：(x,y 宽x高)
    public var short: String { "(\(Int(minX)),\(Int(minY)) \(Int(width))x\(Int(height)))" }
}
