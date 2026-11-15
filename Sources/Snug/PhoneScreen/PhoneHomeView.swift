// 手机屏上的「App 资源库」：盖住整块手机屏（连这块屏上的菜单栏一起），看起来像手机上的原生 App。
// 顶部固定一行返回键（放着窗口时才有，那一行一直留着，有没有返回键内容都不跳）；
// 标题和搜索框跟着列表滚走，分段控件「运行中 / 全部」滚到顶就停住、一直看得见，滚回顶部时页眉完整恢复。
// - 运行中：在跑的 App，窗口挂在各自的 App 下（见 PhoneAppCard）。放着窗口时它的 App 单列在最上面「当前 App」，其余在「其他 App」
// - 全部：本机所有 App 的图标网格，按字典序，正在运行的下方有圆点
// - 搜索：见 PhoneSearchPage
// - 正在打开、正在放：整屏讲明是哪个 App、哪个窗口；出了问题：顶部写明出了什么事、怎么办
// 每次回到列表、每次出了问题都从最上面看起。文字只用短词，图标全用 SF Symbols
import AppKit
import SnugCore
import SwiftUI

struct PhoneHomeView: View {
    let state: AppState
    let catalog: AppCatalog
    let search: PhoneSearch
    let intents: any PhoneIntents

    // CLT没有macOS27的SwiftUIMacros；用已有SwiftUI观察机制保存这两个本地状态。
    @StateObject private var local: LocalState
    private var tab: Tab { get { local.tab } nonmutating set { local.tab = newValue } }
    private var confirming: Confirm? { get { local.confirming } nonmutating set { local.confirming = newValue } }

    @MainActor
    private final class LocalState: ObservableObject {
        @Published var tab: Tab
        @Published var confirming: Confirm?
        init(tab: Tab, confirming: Confirm?) { self.tab = tab; self.confirming = confirming }
    }

    /// tab、confirming：渲染样例用
    init(state: AppState, catalog: AppCatalog, search: PhoneSearch, intents: any PhoneIntents,
         tab: Tab = .running, confirming: Confirm? = nil) {
        self.state = state
        self.catalog = catalog
        self.search = search
        self.intents = intents
        _local = StateObject(wrappedValue: LocalState(tab: tab, confirming: confirming))
    }

    enum Tab: CaseIterable, Identifiable {
        case running, all
        var id: Self { self }
        var title: String { self == .running ? "运行中" : "全部" }
    }

    /// 在等再点一下确认的：退出哪个 App、关哪个窗口。同一时刻只有一个；
    /// 有了别的动作、换了页、收起了列表就作废，防误触要的是连着按两下
    enum Confirm: Equatable {
        case quit(Int32)
        case close(WindowKey)
    }

    private static let top = "top"
    private var phone: PhoneDesk.State { state.phone }

    var body: some View {
        ZStack {
            if search.active {
                SearchPage(catalog: catalog, search: search, phone: phone, intents: intents)
            } else {
                home
            }
            if let busy = BusyView.Content(phone.work, catalog: catalog) {
                BusyView(content: busy).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: phone.work)
        .background(PhoneStyle.background)
        .onChange(of: phone.listVisible) { confirming = nil }
        .onChange(of: phone.work) { confirming = nil }
        .onChange(of: tab) { confirming = nil }
        .onChange(of: search.active) { confirming = nil }
    }

    private var home: some View {
        VStack(spacing: 0) {
            backRow
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        header.id(Self.top)
                        SwiftUI.Section {
                            page.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 24)
                        } header: {
                            TabPicker(selection: Binding(get: { tab }, set: { tab = $0 }))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(PhoneStyle.background)
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: phone.listVisible) { _, visible in
                    if visible { proxy.scrollTo(Self.top, anchor: .top) }
                }
                // 提示在页眉里：翻到下面时出了问题，滚回去让人看见
                .onChange(of: phone.notice) { _, notice in
                    if notice != nil { withAnimation { proxy.scrollTo(Self.top, anchor: .top) } }
                }
            }
        }
        .disabled(phone.work != nil)
    }

    /// 返回键那一行一直留着：有没有返回键，下面的内容都不跳
    private var backRow: some View {
        Group {
            if let placed = phone.placed {
                BackButton(app: placed.window.app) { intents.returnToPlaced() }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PhoneStyle.touchTarget)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App").font(PhoneStyle.largeTitle)
            Button { search.begin() } label: {
                SearchBar { Text("搜索 App").foregroundStyle(.secondary) }
            }
            .buttonStyle(PressableStyle())
            if let notice = phone.notice { NoticeBanner(notice: notice, intents: intents) }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    @ViewBuilder private var page: some View {
        switch tab {
        case .running: runningPage
        case .all: AllApps(catalog: catalog, quitting: phone.quitting, intents: intents)
        }
    }

    private var runningPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let placed = phone.placed {
                TitledSection("当前 App") { appCard(catalog.app(of: placed.window)) }
            }
            let others = catalog.running.filter { $0.pid != phone.placed?.window.key.pid }
            if !catalog.loaded {
                EmptyState(symbol: nil, text: "正在读取")
            } else if others.isEmpty {
                if phone.placed == nil { EmptyState(symbol: "square.grid.2x2", text: "没有正在运行的 App") }
            } else if phone.placed != nil {
                TitledSection("其他 App") { appCards(others) }
            } else {
                appCards(others)
            }
        }
    }

    private func appCards(_ apps: [RunningApp]) -> some View {
        LazyVStack(spacing: 12) {
            ForEach(apps) { appCard($0) }
        }
    }

    private func appCard(_ app: RunningApp) -> some View {
        AppCard(app: app, phone: phone, confirming: Binding(get: { confirming }, set: { confirming = $0 }), icon: catalog.icon(for: app.app), intents: intents)
    }
}

// MARK: 页眉

/// 分段控件：和 iOS 的一样，选中的那段浮起来
private struct TabPicker: View {
    @Binding var selection: PhoneHomeView.Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PhoneHomeView.Tab.allCases) { tab in
                Button { selection = tab } label: {
                    Text(tab.title)
                        .font(PhoneStyle.label.weight(selection == tab ? .semibold : .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(PhoneStyle.segment)
                                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(PhoneStyle.fill, in: RoundedRectangle(cornerRadius: PhoneStyle.cornerRadius, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// 回到手机屏上的窗口：和 iPhone 左上角「‹ App 名」回到上一个 App 一样
private struct BackButton: View {
    let app: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(PhoneStyle.headline)
                Text(app).font(PhoneStyle.body.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(PhoneStyle.tint)
            .padding(.leading, 16)
            .padding(.trailing, 20)
            .frame(height: PhoneStyle.touchTarget)
            .background(PhoneStyle.tint.opacity(0.12), in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("返回 \(app)")
    }
}

/// 出了什么事、怎么办；没退出的 App 给「稍后 / 强制退出」
private struct NoticeBanner: View {
    let notice: PhoneDesk.Notice
    let intents: any PhoneIntents

    var body: some View {
        let text = notice.text
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(text.headline).font(PhoneStyle.body.weight(.semibold))
                if let detail = text.detail {
                    Text(detail).font(PhoneStyle.body).foregroundStyle(.secondary)
                }
                if case .quitStalled(let app, let pid) = notice {
                    HStack(spacing: 12) {
                        PillButton(title: "稍后") { intents.dismissNotice() }
                        PillButton(title: "强制退出", destructive: true) { intents.forceQuit(pid: pid, app: app) }
                    }
                }
            }
        }
        .font(PhoneStyle.body)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: 全部

/// 本机所有 App：图标网格，4 列，按字典序；正在运行的下方有圆点，正在退出的点不了
private struct AllApps: View {
    let catalog: AppCatalog
    let quitting: Set<Int32>
    let intents: any PhoneIntents

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 4)

    var body: some View {
        if catalog.installed.isEmpty {
            EmptyState(symbol: nil, text: "正在读取")
        } else {
            let running = Dictionary(catalog.running.map { ($0.app.bundleID, $0.pid) }, uniquingKeysWith: { first, _ in first })
            LazyVGrid(columns: Self.columns, spacing: 20) {
                ForEach(catalog.installed) { item in
                    let pid = running[item.app.bundleID]
                    Button { intents.open(item.app) } label: {
                        VStack(spacing: 8) {
                            AppIcon(image: catalog.icon(for: item.app), size: 72)
                            Text(item.app.name).font(PhoneStyle.label).lineLimit(1).frame(maxWidth: 116)
                            Circle()
                                .fill(.secondary)
                                .frame(width: 6, height: 6)
                                .opacity(pid == nil ? 0 : 1)
                                .padding(.top, -4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(pid.map(quitting.contains) ?? false)
                }
            }
        }
    }
}

// MARK: 正在打开、正在放

/// 整屏讲明正在打开哪个 App、放哪个窗口。窗口挪好列表就收起，失败了回到列表、顶部写明原因
private struct BusyView: View {
    struct Content: Equatable {
        let icon: NSImage
        let title: String
        let subtitle: String?

        @MainActor
        init?(_ work: PhoneDesk.Work?, catalog: AppCatalog) {
            switch work {
            case .opening(let app):
                (icon, title, subtitle) = (catalog.icon(for: app), app.name, nil)
            case .placing(let window):
                (icon, title, subtitle) = (catalog.icon(for: window), window.app, window.title.isEmpty ? nil : window.title)
            default:
                return nil
            }
        }
    }

    let content: Content

    var body: some View {
        VStack(spacing: 16) {
            AppIcon(image: content.icon, size: PhoneStyle.iconSize * 2)
            VStack(spacing: 4) {
                Text(content.title).font(PhoneStyle.headline).lineLimit(1)
                if let subtitle = content.subtitle {
                    Text(subtitle).font(PhoneStyle.body).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            VStack(spacing: 8) {
                ProgressView()
                Text("正在打开").font(PhoneStyle.label).foregroundStyle(.secondary)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PhoneStyle.background)
    }
}
