// 设置窗口：macOS App 设置窗口的标准做法，顶部工具栏标签页「通用 / 关于」（关于页见 AboutView）。
// 通用页：顶部是此刻的状态，需要处理的问题每个一行、各带解决它的按钮；下面是总开关和两项微调，再下面是开机启动和权限。
// 每行配 SF Symbols 图标，说明只用短词。只读 AppState，意图走 AppIntents
import AppKit
import SwiftUI
import SnugCore

struct SettingsView: View {
    let state: AppState
    let intents: any AppIntents
    let navigation: any Navigation

    var body: some View {
        Form {
            Section { StatusHeader(state: state, navigation: navigation) }
            if !issues.isEmpty {
                Section {
                    ForEach(issues) { IssueRow(issue: $0) }
                }
            }
            Section {
                Toggle(isOn: binding(state.config.phoneScreen, intents.setPhoneScreen)) {
                    SettingLabel("手机屏", detail: "UU远程 中增加竖屏", symbol: "iphone", tint: .blue)
                }
                Picker(selection: binding(state.config.screenSize, intents.setScreenSize)) {
                    ForEach(PhoneScreenSize.allCases, id: \.self) { size in Text(size.label).tag(size) }
                } label: {
                    SettingLabel("基础尺寸", detail: "下次建屏生效 · 大窗口自动适配", symbol: "rectangle.portrait", tint: .blue)
                }
                .disabled(!state.config.phoneScreen)
                Toggle(isOn: binding(state.config.gestures, intents.setGestures)) {
                    SettingLabel("触控手势", detail: "单指滚动 · 长按选择 · 长按松开右键", symbol: "hand.draw.fill", tint: .orange)
                }
                .disabled(!state.config.phoneScreen)
                LabeledContent {
                    ZoomSlider(steps: binding(state.config.zoomSteps, intents.setZoomSteps))
                } label: {
                    SettingLabel("字号放大", detail: "ChatGPT、终端、编辑器", symbol: "textformat.size", tint: .green)
                }
                .disabled(!state.config.phoneScreen)
            }
            Section {
                Toggle(isOn: binding(state.launchAtLogin, intents.setLaunchAtLogin)) {
                    SettingLabel("开机启动", symbol: "power", tint: .gray)
                }
                // 没授权时「授权…」在顶部状态里，这里只写状态
                LabeledContent {
                    PermissionStatus(granted: state.accessibilityTrusted)
                } label: {
                    SettingLabel.accessibility
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("退出 Snug") { intents.quit() }
                        .help("还原窗口后退出")
                }
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsWindowController.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 需要用户处理的问题，和解决它的按钮（有的话）
    private var issues: [Issue] {
        var list: [Issue] = []
        if state.legacyAppRunning {
            list.append(Issue(id: "legacy", text: StatusText(headline: "旧版「UU远程伴侣」运行中", detail: "与 Snug 同时运行将相互干扰"),
                              action: ("退出旧版", intents.quitLegacyApp)))
        }
        if let issue = state.loginItemIssue {
            list.append(Issue(id: "login", text: issue.text,
                              action: issue == .needsApproval ? ("前往允许", intents.openLoginItemsSettings) : nil))
        }
        if state.configSaveFailed {
            list.append(Issue(id: "config", text: StatusText(headline: "设置未保存", detail: "修改未生效，请重试"), action: nil))
        }
        return list
    }

    private func binding<T>(_ value: T, _ set: @escaping @MainActor (T) -> Void) -> Binding<T> {
        Binding(get: { value }, set: { set($0) })
    }
}

/// 顶部：此刻的状态；缺权限时主按钮「授权…」就在这里
private struct StatusHeader: View {
    let state: AppState
    let navigation: any Navigation

    var body: some View {
        let text = StatusText(state)
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(state.statusColor.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(text.headline).font(.headline)
                if let detail = text.detail { Text(detail).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            if !state.accessibilityTrusted {
                Button("授权…") { navigation.openWelcome() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        if !state.accessibilityTrusted { return "hand.raised.fill" }
        switch state.connection {
        case .idle: return "iphone.gen3"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .connected: return "iphone.gen3.radiowaves.left.and.right"
        }
    }
}

private struct Issue: Identifiable {
    let id: String
    let text: StatusText
    let action: (title: String, run: @MainActor () -> Void)?
}

/// 一个问题一行：警示图标、出了什么事、去哪里处理，右边是解决它的按钮
private struct IssueRow: View {
    let issue: Issue

    var body: some View {
        LabeledContent {
            if let action = issue.action { Button(action.title, action: action.run) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.text.headline)
                    if let detail = issue.text.detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

/// 字号放大：系统「文字大小」那样的带刻度滑块，两端小 A、大 A，每档一格
private struct ZoomSlider: View {
    @Binding var steps: Int

    var body: some View {
        let range = AppConfig.zoomStepsRange
        Slider(value: Binding(get: { Double(steps) }, set: { steps = Int($0.rounded()) }),
               in: Double(range.lowerBound)...Double(range.upperBound), step: 1) {
            Text("字号放大")
        } minimumValueLabel: {
            Image(systemName: "textformat.size.smaller")
        } maximumValueLabel: {
            Image(systemName: "textformat.size.larger")
        }
        .labelsHidden()
        .frame(width: 160)
        .accessibilityValue(steps == 0 ? "不放大" : "+\(steps) 级")
    }
}

/// 设置窗口：两个标签页各是一个 SwiftUI 视图。NSTabViewController 自己会让窗口标题跟着当前页走，
/// 高度跟着当前页的内容（切页、出现提示）变，左上角不动（实测）
@MainActor
final class SettingsWindowController {
    enum Tab: Int {
        case general, about
    }

    static let width: CGFloat = 520

    private let state: AppState
    private let intents: any AppIntents
    private weak var navigation: (any Navigation)?
    private var window: NSWindow?
    private var tabs: NSTabViewController?

    init(state: AppState, intents: any AppIntents, navigation: any Navigation) {
        self.state = state
        self.intents = intents
        self.navigation = navigation
    }

    func show(_ tab: Tab = .general, activating: Bool = true) {
        if window == nil, let navigation {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.addTabViewItem(Self.item("通用", symbol: "gearshape",
                                          SettingsView(state: state, intents: intents, navigation: navigation)))
            tabs.addTabViewItem(Self.item("关于", symbol: "info.circle",
                                          AboutView(state: state, intents: intents, navigation: navigation)))
            // 先选好页再建窗口：窗口按这一页的大小建，居中才是正的
            tabs.selectedTabViewItemIndex = tab.rawValue
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            // 只在建好时居中：之后关了再开，还在用户拖到的地方
            w.center()
            self.tabs = tabs
            window = w
        } else {
            tabs?.selectedTabViewItemIndex = tab.rawValue
        }
        window?.present(activating: activating)
    }

    private static func item(_ label: String, symbol: String, _ view: some View) -> NSTabViewItem {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        hosting.title = label   // 窗口标题跟着当前页走
        let item = NSTabViewItem(viewController: hosting)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }
}
