// 状态文案：一个标题 + 一个短说明。把 AppState 翻成菜单栏和设置窗口共用的状态，也给手机屏上的提示用；
// 手机屏列表里窗口、App 的几处说法也在这里。只用短词，书面、克制
import SnugCore
import SwiftUI

struct StatusText: Equatable {
    var headline: String
    var detail: String?

    init(headline: String, detail: String?) {
        self.headline = headline
        self.detail = detail
    }

    @MainActor
    init(_ s: AppState) {
        headline = Self.headline(s)
        detail = Self.detail(s)
    }

    @MainActor
    private static func headline(_ s: AppState) -> String {
        if s.quitting { return "正在退出" }
        if !s.accessibilityTrusted { return "需要\(PermissionName.accessibility)权限" }
        switch s.connection {
        case .idle: return "等待连接"
        case .reconnecting: return "连接中断"
        case .connected: return s.controllers.isEmpty ? "远程中" : "\(s.controllers.joined(separator: "、")) · 远程中"
        }
    }

    @MainActor
    private static func detail(_ s: AppState) -> String? {
        if s.quitting { return "正在还原窗口" }
        if !s.accessibilityTrusted { return "用于移动窗口与转换手势" }
        if !s.config.phoneScreen { return "手机屏已关闭" }
        if s.phone.notice == .workspacePending { return "窗口原位待核验，恢复记录保留" }
        if s.phone.notice == .workspaceCaptureUnavailable { return "完整布局未就绪，尚未批量移动窗口" }
        if s.connection == .idle { return nil }
        if s.gesturesFailed { return "手势转换未启用" }
        switch s.phone.screen {
        case .preparing: return "正在准备手机屏"
        case .failed: return "手机屏创建失败"
        case .ready:
            guard s.phoneInUse else { return "手机屏已就绪" }
            return s.phone.placed.map { "手机屏 · \($0.window.app)" } ?? (s.phone.workspaceActive ? "工作区已收拢 · 结束后统一归位" : "手机屏使用中")
        case .off:
            return ControllerKind.wantsPhoneScreen(s.controllers) ? nil : "电脑控制端，不提供手机屏"
        }
    }
}

extension AppState {
    /// 状态的颜色，菜单栏的圆点和设置页顶部的图标共用：绿色远程中；橙色要处理（缺权限、连接中断）；灰色等待连接、手机屏关着
    var statusColor: Color {
        guard accessibilityTrusted else { return .orange }
        guard config.phoneScreen else { return .gray }
        switch connection {
        case .connected: return .green
        case .reconnecting: return .orange
        case .idle: return .gray
        }
    }
}

extension LoginItemIssue {
    /// 设置页的问题行：出了什么事，去哪里处理
    var text: StatusText {
        switch self {
        case .needsApproval: StatusText(headline: "开机启动待允许", detail: "系统设置 › 通用 › 登录项")
        case .notInApplications: StatusText(headline: "开机启动未生效", detail: "需位于「应用程序」")
        case .failed: StatusText(headline: "开机启动未生效", detail: "请稍后重试")
        }
    }
}

extension PhoneDesk.Notice {
    /// 手机屏列表顶部的提示：出了什么事，和接下来怎么办。不出现技术词
    var text: StatusText {
        switch self {
        case .windowGone(let app): StatusText(headline: "\(app) 窗口已关闭", detail: "请另选一个窗口")
        case .windowUnresponsive(let app): StatusText(headline: "\(app) 无响应", detail: "可能正忙，请稍后再试")
        case .workspacePending: StatusText(headline: "工作区布局待核验", detail: "原位记录保留；锁屏时解锁后继续")
        case .workspaceCaptureUnavailable: StatusText(headline: "完整布局尚未就绪", detail: "未批量移动窗口；归还当前窗口后可重连准备")
        case .recordUnwritable: StatusText(headline: "无法保存原位置", detail: "为确保能放回原处，窗口未移动")
        case .screenNotReady: StatusText(headline: "手机屏未就绪", detail: "屏幕正在调整，请稍后再试")
        case .openFailed(let app): StatusText(headline: "无法打开 \(app)", detail: "请稍后再试")
        case .noNewWindow(let app): StatusText(headline: "\(app) 无法新建窗口", detail: "可点 App 打开已有窗口")
        case .noWindow(let app): StatusText(headline: "未找到 \(app) 的窗口", detail: "App 已打开，但没有可显示的窗口")
        case .quitStalled(let app, _): StatusText(headline: "\(app) 未退出", detail: "强制退出将丢失未存储的内容")
        }
    }
}

extension WindowInfo {
    /// 列表里显示的标题
    var displayTitle: String { title.isEmpty ? "无标题" : title }
}

extension RunningApp {
    /// 开着几个窗口
    var windowSummary: String { windows.isEmpty ? "没有窗口" : "\(windows.count) 个窗口" }
}
