// 手机屏的调度中枢：什么时候加屏、撤屏，窗口怎么放上来、放回去，字号怎么改，手机屏用哪一档；
// App 资源库的动作也在这里：打开 App、新建窗口时等新窗口出来再放，退出 App 前先还原它放上来的窗口。
// 所有动作排成一队依次做（加屏要等上线、搬窗口要核对重试，中间不能被别的动作插进来）。
// 退出 App、关窗口例外：请求发出之后不占着队等结果（Electron 类 App 退出要五六秒，「要存储吗」要等人回答），
// 另起一个盯着，期间别的动作照做；盯到对话框时再排进队把它放上手机屏。
// 屏幕适配（ScreenFit）：手机屏的宽度跟着屏上显示的东西走，露着列表是基准宽度，放着窗口是那个窗口要的一档。
// 工作区：进入手机屏才收拢当前桌面普通窗口；切换保留，撤屏统一核验原位。特殊状态不自动改变；
// 每一处改动先记账再动手，还原成功、或窗口确实没了才销账。没销的账（Snug 崩溃、App 卡住没放成）
// 在下次启动（recover()）、或下次放窗口之前按账还原，不会被新的记录盖掉
import CoreGraphics
import Foundation

@MainActor
public final class PhoneDesk {
    public struct State: Equatable, Sendable {
        public enum Screen: Equatable, Sendable {
            case off
            case preparing
            case ready(DisplayID)
            /// 加屏失败（详情在日志里）。按 retryDelays 自动重试，用完就停在这里，直到不要了再要
            case failed
        }

        public var screen = Screen.off
        public var profile: PhoneScreenSize?
        public var workspaceActive = false
        /// 手机屏上的窗口
        public var placed: Placed?
        /// 手机屏上露着 App 资源库。没放窗口时总是露着
        public var listVisible = true
        /// 正在做的事，做完回到 nil
        public var work: Work?
        /// 要让用户知道的事，下一个动作开始时、或这次远程结束时清掉
        public var notice: Notice?
        /// 已经请它退出、还在等它退完的 App（进程号）
        public var quitting: Set<Int32> = []
        /// 已经请它关掉、还在等它关上的窗口
        public var closing: Set<WindowKey> = []

        public init() {}

        public var display: DisplayID? {
            if case .ready(let id) = screen { id } else { nil }
        }
    }

    /// 要让用户知道的事，带上是哪个 App 的窗口。措辞归界面层
    public enum Notice: Equatable, Sendable {
        /// 要放的窗口已经关了
        case windowGone(app: String)
        /// 窗口还在，但读不到、挪不动、关不掉（App 没响应，或没有辅助功能权限）；或者请它退出、强制退出的请求没送到
        case windowUnresponsive(app: String)
        /// 还原记录写不进去，不敢动窗口
        case workspacePending
        case workspaceCaptureUnavailable
        case recordUnwritable
        /// 手机屏还没好（屏幕组合还在变）
        case screenNotReady
        /// App 打不开（启动失败）
        case openFailed(app: String)
        /// App 菜单里没有「新建窗口」，或 App 没响应
        case noNewWindow(app: String)
        /// 打开了，但等满了也没有可显示的窗口（收进菜单栏的 App 常这样）
        case noWindow(app: String)
        /// 请它退出了，等满了还没退，也没有对话框：可以强制退出
        case quitStalled(app: String, pid: Int32)
    }

    /// 盯着的 App 退完了、窗口关上了
    public enum Gone: Equatable, Sendable {
        case app(Int32)
        case window(WindowKey)
    }

    public struct Placed: Equatable, Sendable {
        public let window: WindowInfo
        /// 比原来放大了几级
        public var zoom: Int
        public var inWorkspace: Bool
        public var zoomable: Bool { ZoomBook.isZoomable(window.bundleID) }

        public init(window: WindowInfo, zoom: Int, inWorkspace: Bool = false) {
            self.window = window
            self.zoom = zoom
            self.inWorkspace = inWorkspace
        }
    }

    public enum Work: Equatable, Sendable {
        /// 正在打开这个 App（启动、唤回或新建窗口），等新窗口出来；出来了转成 placing
        case opening(AppInfo)
        /// 正在把这个窗口放上来（换窗口时含放回原来那个），窗口挪好就转成 zooming
        case placing(WindowInfo)
        case puttingBack
        case zooming
    }

    /// 屏幕配置一变，过这么久再检查一次（等系统折腾完）
    static let recheckDelay: TimeInterval = 1.5
    /// 窗口挪好、字号改完后等这么久再动下一步：App 要一点时间认到新的大小
    static let settleDelay: TimeInterval = 0.3
    /// 加屏失败后隔多久重试；这几次都不成就不再试，直到不要了再要
    static let retryDelays: [TimeInterval] = [5, 15, 30]
    /// 等新窗口出来时隔多久问一次（实测一次不到 1 毫秒）
    static let windowPoll: TimeInterval = 0.1
    /// 冷启动最多等多久出窗口（实测 ChatGPT 6.6 秒，更重的 App 更慢）；唤回、新建窗口实测都在 0.3 秒内，等 10 秒
    static let launchWait: TimeInterval = 30
    static let windowWait: TimeInterval = 10
    /// 请 App 退出、请窗口关掉之后隔多久看一次结果
    static let watchPoll: TimeInterval = 0.25
    /// 最多等多久才算没动静：退出给强制退出（实测 Electron 类 App 退出要五六秒），关窗口提示无响应
    static let quitWait: TimeInterval = 10
    static let closeWait: TimeInterval = 5
    /// 对话框答完后再等这么久：App 还在、窗口还在，就是点了取消（存储要一点时间，不能一没对话框就下结论）
    static let answerGrace: TimeInterval = 2
    /// 给了强制退出以后再看这么久、隔 stalledPoll 看一次：它自己退了（大型 App 退出要十几秒），提示就撤掉
    static let stalledFollow: TimeInterval = 60
    static let stalledPoll: TimeInterval = 1

    public private(set) var state = State() {
        didSet { if state != oldValue { onChange?(state) } }
    }
    public var onChange: ((State) -> Void)?
    /// 确认 App 退完、窗口关上的那一刻，在撤掉「正在退出 / 正在关闭」之前：数据源据此马上去掉它，
    /// 不然要等下一轮刷新，卡片会以原样闪回一下
    public var onGone: ((Gone) -> Void)?
    /// 即将加屏、撤屏：会话层据此暂缓断开判定（屏幕组合一变，UU 的信号会抖一下）
    public var onTopologyChange: (() -> Void)?
    /// 设置里的默认字号级数
    public private(set) var defaultZoom: Int

    private let displays: any PhoneDisplays
    private let windows: any WindowControl
    private let apps: any AppControl
    private let timeline: any Timeline
    private let workspace: PhoneWorkspace
    private var enteringWorkspace = false
    private var recoveringWorkspace = false
    private var workspaceEntered = false
    private let ledger: RestoreRecord<PhoneRecord>
    private let zoomFile: JSONFile<ZoomBook>
    private var zoomBook: ZoomBook
    private let lane = SerialLane()

    private var wanted = false
    private var display: (id: DisplayID, bornAt: TimeInterval)?
    private var placement: Placement? {
        didSet { state.placed = placement.map { Placed(window: $0.window, zoom: $0.record.zoom, inWorkspace: workspace.contains($0.window.key)) } }
    }
    private var recheckGeneration = 0
    private var pendingRecheck: Task<Void, Never>?
    private var failures = 0
    private var pendingRetry: Task<Void, Never>?
    private var verifying = false
    /// 盯着的请求：请它退出的 App、请它关掉的窗口
    private enum Watched: Hashable {
        case quit(Int32)
        case close(WindowKey)
    }
    private var watches: [Watched: Task<Void, Never>] = [:]

    public init(displays: any PhoneDisplays, windows: any WindowControl, apps: any AppControl,
                timeline: any Timeline = SystemTimeline(), paths: SnugPaths, defaultZoom: Int = 2) {
        self.displays = displays
        self.windows = windows
        self.apps = apps
        self.timeline = timeline
        self.defaultZoom = defaultZoom
        workspace = PhoneWorkspace(paths: paths, windows: windows)
        ledger = RestoreRecord(url: paths.phoneRecord)
        zoomFile = JSONFile(url: paths.zoomBook)
        zoomBook = zoomFile.loadOrQuarantine() ?? ZoomBook()
    }

    // MARK: 意图

    /// 要不要手机屏（会话、设置、权限合起来的结论）。变了才动
    public func setWanted(_ on: Bool) {
        guard on != wanted else { return }
        wanted = on
        if !on { cancelRetry() }
        lane.run { await self.reconcile() }
    }

    /// 真正进入手机屏（推流指向它，或用户点其中的卡片）才收拢；离开列表不提前归还物理原位。
    public func enterWorkspace() {
        guard display != nil, !enteringWorkspace, !workspaceEntered else { return }
        enteringWorkspace = true
        lane.run {
            defer { self.enteringWorkspace = false }
            guard let id = self.display?.id, let area = self.displays.windowArea(id) else { return }
            let outcome = await self.workspace.collect(in: area)
            self.state.workspaceActive = self.workspace.active
            switch outcome {
            case .complete(let verified, let skipped):
                self.workspaceEntered = true
                Log.info("工作区已收拢并读回：\(verified) 个，特殊/其它桌面跳过 \(skipped) 个")
            case .deferred:
                self.state.notice = self.workspace.captureUnavailable ? .workspaceCaptureUnavailable : .workspacePending
            case .failed(let ids):
                // 部分失败也已经接管，原位仍由会话记录保存；不重复写入收拢预算。
                self.workspaceEntered = true; self.state.notice = .workspacePending
                Log.warn("部分工作窗口未收拢，原位记录保留：\(ids)")
            }
        }
    }

    /// 把这个窗口放上手机屏（原来那个先放回原位）。正在退出的 App 的窗口不放：它退完会记住手机屏上那个窄位置
    public func pull(_ window: WindowInfo) {
        guard !state.quitting.contains(window.key.pid) else { return Log.info("\(window.app) 正在退出，不放 \(window.label)") }
        begin(.placing(window))
        lane.run {
            await self.place(window)
            self.state.work = nil
        }
    }

    /// 打开 App，等它的新窗口出来放上手机屏：没在跑就启动，在跑但没窗口就唤回（点在跑且有窗口的 App 是 pull，见 AppList.action）
    public func open(_ app: AppInfo) {
        begin(.opening(app))
        lane.run {
            await self.openWindow(of: app, newWindowIn: nil)
            self.state.work = nil
        }
    }

    /// 给在跑的 App 新建一个窗口（菜单里的 ⌘N），放上手机屏：从出现起就是手机宽度，终端不会因为尺寸剧变重排
    public func newWindow(_ app: RunningApp) {
        guard !state.quitting.contains(app.pid) else { return Log.info("\(app.app.name) 正在退出，不新建窗口") }
        begin(.opening(app.app))
        lane.run {
            await self.openWindow(of: app.app, newWindowIn: app.pid)
            self.state.work = nil
        }
    }

    /// 退出 App（同 ⌘Q）。手机屏上放着它的窗口就先还原（App 退出时会记住窗口位置，不先放回下次就是手机屏那么窄），
    /// 放不回去就不退。请它退出后另起一个盯着：退完了就好；弹出「要存储吗」就把那个窗口放上手机屏，在手机上就能选；
    /// 等满了还没退、也没有对话框，提示可以强制退出
    public func quit(_ app: RunningApp) {
        guard !state.quitting.contains(app.pid) else { return }
        state.notice = nil
        state.quitting.insert(app.pid)
        lane.run {
            if let p = self.placement, p.window.key.pid == app.pid {
                guard await self.returnToOriginal(p) else {
                    Log.warn("\(p.window.label) 放不回去，先不退出 \(app.app.name)")
                    self.state.quitting.remove(app.pid)
                    self.state.notice = .windowUnresponsive(app: p.window.app)
                    return
                }
                await self.matchWidth()
            }
            guard await self.workspace.restoreBeforeClosing(pid: app.pid) else {
                self.state.quitting.remove(app.pid)
                self.state.notice = .workspacePending
                return
            }
            Log.info("请 \(app.app.name) 退出")
            guard await self.apps.quit(pid: app.pid) else {
                self.state.quitting.remove(app.pid)
                self.state.notice = .windowUnresponsive(app: app.app.name)
                return
            }
            self.watchQuit(app)
        }
    }

    /// 强制退出（提示里的按钮）：未存储的内容会丢
    public func forceQuit(pid: Int32, app: String) {
        state.notice = nil
        unwatch(.quit(pid))
        Log.warn("强制退出 \(app)（pid \(pid)）")
        lane.run {
            if await !self.apps.forceQuit(pid: pid) { self.state.notice = .windowUnresponsive(app: app) }
        }
    }

    /// 关掉一个窗口（同点它的红色关闭按钮）。放在手机屏上的先还原位置和字号（App 会记住关掉的窗口在哪、多大，
    /// 不先放回，下次开出来就是手机屏那么窄），但不恢复全屏：马上就要关了。全屏的先退出全屏，
    /// 不然按关闭按钮没反应（实测 11-14，不论在不在当前桌面空间）。之后另起一个盯着，同退出：
    /// 关掉了就好；问「要存储吗」或「还有进程在跑」就把它放上手机屏；等满了还在、也没在问，提示无响应
    public func close(_ window: WindowInfo) {
        guard watches[.close(window.key)] == nil else { return }
        state.notice = nil
        state.closing.insert(window.key)
        lane.run {
            if let p = self.placement, p.window.key == window.key {
                guard await self.returnToOriginal(p, restoringState: false) else {
                    Log.warn("\(p.window.label) 放不回去，先不关")
                    self.state.closing.remove(window.key)
                    self.state.notice = .windowUnresponsive(app: p.window.app)
                    return
                }
                await self.matchWidth()
            }
            guard await self.workspace.restoreBeforeClosing(pid: window.key.pid, window: window.key) else {
                self.state.closing.remove(window.key)
                self.state.notice = .workspacePending
                return
            }
            if await self.windows.look(window.key)?.fullScreen == true { await self.windows.setFullScreen(window.key, false) }
            guard await self.windows.close(window.key) else {
                let notice = await self.unreachable(window)
                Log.warn("关不了 \(window.label)（\(Self.reason(notice, gone: "已经关了"))）")
                self.state.closing.remove(window.key)
                self.state.notice = notice
                return
            }
            Log.info("关闭 \(window.label)")
            self.watchClose(window)
        }
    }

    /// 关掉提示（「稍后」）。没退出的那个就不再盯了
    public func dismissNotice() {
        if case .quitStalled(_, let pid) = state.notice { unwatch(.quit(pid)) }
        state.notice = nil
    }

    /// 底部小横条：回到 App 资源库（马上露出来），手机屏换回基准宽度。
    /// 提示留着：列表收着时出的错（比如调字号没成），这时才看得到
    public func showList() {
        state.listVisible = true
        lane.run { await self.matchWidth() }
    }

    /// 列表左上角的返回键：回到手机屏上的窗口。换档要一会儿，期间和放窗口一样显示「正在打开」、列表点不了
    public func returnToPlaced() {
        guard let p = placement else { return }
        begin(.placing(p.window))
        lane.run {
            await self.reveal()
            self.state.work = nil
        }
    }

    /// 把手机屏上的窗口放回原位。放不回去（App 卡住）就留在手机屏上，提示一下，可以再点
    public func putBack() {
        guard placement != nil else { return }
        begin(.puttingBack)
        lane.run {
            if let p = self.placement, await !self.returnToOriginal(p) {
                self.state.notice = .windowUnresponsive(app: p.window.app)
            }
            await self.matchWidth()
            self.state.work = nil
        }
    }

    /// 字大 / 字小一级，并记到这个 App 名下。到了上下限什么都不做（界面上那个按钮已经点不了）
    public func zoom(by delta: Int) {
        guard let placed = state.placed, placed.zoomable,
              (placed.zoom + delta).clamped(to: ZoomBook.range) != placed.zoom else { return }
        begin(.zooming)
        lane.run {
            if await self.changeZoom(by: delta), let p = self.placement, let bundle = p.window.bundleID {
                self.zoomBook.remember(p.record.zoom, for: bundle)
                self.saveZoomBook()
            }
            self.state.work = nil
        }
    }

    /// 设置里改了默认级数：以它为准，各 App 记住的级数一起清掉（不然改了看起来不起作用）
    public func setDefaultZoom(_ steps: Int) {
        defaultZoom = steps
        guard !zoomBook.remembered.isEmpty else { return }
        zoomBook.forgetAll()
        saveZoomBook()
    }

    /// 屏幕配置变了（插拔外接屏、系统改模式、Snug 自己换档）：过一会儿检查手机屏还是不是该用的那一档、窗口还铺不铺满
    public func displaysChanged() {
        guard display != nil else { return }
        recheckGeneration += 1
        let generation = recheckGeneration
        pendingRecheck = Task {
            await timeline.sleep(Self.recheckDelay)
            guard generation == recheckGeneration else { return }
            lane.run { await self.recheck() }
        }
    }

    /// 定期调用：手机屏上的窗口被关掉了，就回到 App 资源库。只认窗口服务器的结论：App 一时没响应不算关了。
    /// 窗口还在却不在屏上（被最小化、App 被隐藏、关成了隐藏），手机屏上只剩空桌面：也回到列表，
    /// 但它照旧算放着、还原记录留着，可以返回它、还原或换一个
    public func verifyPlacement() {
        if display == nil, workspace.pending, !workspace.blocked, !recoveringWorkspace {
            recoveringWorkspace = true
            lane.run {
                defer { self.recoveringWorkspace = false }
                _ = await self.recoverWorkspace()
            }
        }
        guard placement != nil, state.work == nil, !verifying else { return }
        verifying = true
        lane.run {
            defer { self.verifying = false }
            guard let p = self.placement else { return }
            guard await self.windows.exists(p.window.key) else {
                Log.info("手机屏上的 \(p.window.label) 已经关了，回到 App 资源库")
                self.placement = nil
                self.state.listVisible = true
                self.settleRecord()
                await self.matchWidth()
                return
            }
            if !self.state.listVisible, await !self.windows.isShown(p.window.key) {
                Log.info("手机屏上的 \(p.window.label) 不在屏上了（最小化、隐藏或关成了隐藏），回到 App 资源库")
                self.state.listVisible = true
                await self.matchWidth()
            }
        }
    }

    /// 有辅助功能权限后调用：上次 Snug 没来得及放回去的窗口，按记录放回去。记录在队里轮到时才读，不会拿旧的放两遍
    public func recover() {
        lane.run {
            if self.workspace.pending { _ = await self.recoverWorkspace() }
            else { await self.putBackLeftover() }
        }
    }

    private func recoverWorkspace() async -> Bool {
        guard !workspace.blocked, !(await windows.isLocked()) else { state.notice = .workspacePending; return false }
        if let stuck = await putBackLeftover() {
            state.notice = .windowUnresponsive(app: stuck.app)
            return false
        }
        switch await workspace.restore() {
        case .complete(let verified, let skipped):
            state.notice = nil
            Log.info("工作区原位读回完成：\(verified) 个，已关闭/特殊状态跳过 \(skipped) 个")
            return true
        case .deferred: state.notice = .workspacePending; return false
        case .failed(let ids):
            state.notice = .workspacePending
            Log.warn("工作区归位未完成，保留记录并停止覆盖：\(ids)")
            return false
        }
    }

    /// 退出前：放回窗口、撤掉手机屏，做完才返回
    public func shutdown() async {
        wanted = false
        cancelRetry()
        await lane.run { await self.reconcile() }.value
    }

    /// 等排着的动作都做完，包括还没到点的重试和盯着的退出、关窗（测试用：真实时钟下最长要等 30 秒的重试）
    func idle() async {
        var retry: Task<Void, Never>?
        repeat {
            retry = pendingRetry
            await pendingRecheck?.value
            await retry?.value
            for watch in watches.values { await watch.value }
            await lane.drain()
        } while pendingRetry != retry || !watches.isEmpty
    }

    // MARK: 加屏、撤屏

    private func reconcile() async {
        if wanted, display == nil {
            if workspace.pending, await !recoverWorkspace() { return }
            if let stuck = await putBackLeftover() {
                if state.notice != .workspacePending { state.notice = .windowUnresponsive(app: stuck.app) }
                return
            }
            await addScreen()
        } else if !wanted, state.screen != .off {
            await removeScreen()
        }
    }

    private func addScreen() async {
        state.screen = .preparing
        let before = await windows.snapshot()
        await workspace.captureBeforeScreen()
        onTopologyChange?()
        do {
            let id = try await displays.create()
            display = (id, timeline.now)
            failures = 0
            await windows.restore(before, except: placement?.window.key)
            state.screen = .ready(id)
            state.profile = displays.profile(id)
            if workspace.captureUnavailable { state.notice = .workspaceCaptureUnavailable }
            Log.info("手机屏 #\(id) 已就绪（\(displays.width(id).map { "\($0) 宽" } ?? "模式待确认")）")
        } catch {
            await windows.restore(before, except: placement?.window.key)
            _ = await workspace.restore()
            state.screen = .failed
            Log.error("加手机屏失败：\(error)")
            scheduleRetry()
        }
    }

    /// 加屏失败后过一会儿再试：手机上没有任何入口能重来，不重试就要等这次远程结束
    private func scheduleRetry() {
        pendingRetry?.cancel()
        pendingRetry = nil
        guard failures < Self.retryDelays.count else {
            Log.error("加手机屏连续失败 \(failures + 1) 次，这次远程不再重试")
            return
        }
        let delay = Self.retryDelays[failures]
        failures += 1
        Log.info("\(Int(delay)) 秒后重试加手机屏（第 \(failures) 次重试）")
        pendingRetry = Task {
            await timeline.sleep(delay)
            guard !Task.isCancelled else { return }
            await lane.run { await self.reconcile() }.value
        }
    }

    private func cancelRetry() {
        pendingRetry?.cancel()
        pendingRetry = nil
        failures = 0
    }

    private func removeScreen() async {
        // 屏要撤了，手机屏上不再算有窗口；放不回去的留着还原记录，下次放窗口或下次启动再放
        if let p = placement, !(await windows.isLocked()) { await putBack(p.record) }
        placement = nil
        await retireDisplay()
        workspace.screenRetired()
        workspaceEntered = false
        state.workspaceActive = false
        state.screen = .off
        state.profile = nil
        state.listVisible = true
        // 这次远程的提示、没盯完的退出和关窗不带到下一次（App 照样在退，只是不再盯）
        state.notice = nil
        watches.values.forEach { $0.cancel() }
        watches = [:]
        state.quitting = []
        state.closing = []
        _ = await recoverWorkspace()
    }

    private func retireDisplay() async {
        guard let (id, bornAt) = display else { return }
        let age = timeline.now - bornAt
        if age < PhoneScreenSpec.minimumLifetime { await timeline.sleep(PhoneScreenSpec.minimumLifetime - age) }
        let gone = displays.bounds(id)
        let before = await windows.snapshot()
        onTopologyChange?()
        await displays.retire(id)
        display = nil
        // 原本就在手机屏上的窗口（手机上新开的）交给系统安置：那块屏已经没了，放回原处只会落到屏幕外
        let elsewhere = gone.map { screen in before.filter { !screen.contains(CGPoint(x: $0.value.midX, y: $0.value.midY)) } }
        await windows.restore(elsewhere ?? before, except: placement?.window.key)
        Log.info("已撤掉手机屏 #\(id)")
    }

    private func recheck() async {
        if state.listVisible { await matchWidth() } else { await refill(because: "屏幕配置变了") }
    }

    /// 窗口没铺好就重新铺：手机屏不在它那一档（刚从列表回来、换档没成、系统改了模式），
    /// 或者窗口被挪动、撑大了（换档时系统会挪它；终端类 App 调字号时会按行列数撑大窗口）。
    /// 跟上次挪完的样子比，不跟可放区域比：比最宽一档还宽的窗口本来就铺不满，再挪也一样
    private func refill(because reason: String) async {
        guard let id = display?.id, var p = placement, let frame = await windows.look(p.window.key)?.frame else { return }
        let moved = p.settled.map { !frame.matches($0) } ?? true
        guard moved || displays.width(id) != p.width else { return }
        let what = moved ? "变成了 \(frame.short)" : "要的 \(p.width) 宽不是手机屏现在这一档"
        Log.info("\(reason)，\(p.window.label) \(what)，重新铺满")
        await fill(&p, on: id)
        placement = p
    }

    // MARK: 屏幕适配

    /// 手机屏该用哪一档：露着列表（或没放窗口）是基准宽度，放着窗口是它那一档
    private var activeProfile: PhoneScreenSize { state.profile ?? .redmi }

    private var wantedWidth: Int {
        guard let p = placement, !state.listVisible else { return activeProfile.width }
        return p.width
    }

    /// 让手机屏跟上该用的那一档
    private func matchWidth() async {
        guard let id = display?.id else { return }
        await switchWidth(id, to: wantedWidth)
    }

    private func switchWidth(_ id: DisplayID, to width: Int) async {
        if displays.width(id) != width {
            await displays.setWidth(id, width)
            if workspace.active, let area = displays.windowArea(id) {
                if case .failed = await workspace.collect(in: area) { state.notice = .workspacePending }
            }
        }
    }

    /// 手机屏换到窗口那一档，把窗口铺满。铺不满（App 限定了最小尺寸）就按它实际的大小换到装得下的一档再铺。
    /// 换档没成时屏还是原来那一档，算出来的还是这一档，不会一直往上换。返回最后挪到的位置；挪不动（窗口关了、App 没响应）返回 nil
    @discardableResult
    private func fill(_ p: inout Placement, on id: DisplayID) async -> CGRect? {
        await switchWidth(id, to: p.width)
        guard let area = displays.windowArea(id), let got = await windows.move(p.window.key, to: area) else { return nil }
        p.settled = got
        // 窗口落到了区域原点、只是尺寸被夹住，才是 App 限定了最小尺寸；没挪过去（App 不认挪动）就不按它的大小换档
        let placed = abs(got.minX - area.minX) < 2 && abs(got.minY - area.minY) < 2
        guard placed, let current = displays.width(id) else { return got }
        let width = ScreenFit.width(toFit: got.size, in: area.size, at: current, for: activeProfile)
        guard width > current, width != p.width else { return got }
        Log.info("\(p.window.label) 在 \(current) 宽的手机屏上铺不满（App 限定了最小尺寸，实际 \(got.short)），换到 \(width) 宽")
        p.width = width
        return await fill(&p, on: id)
    }

    /// 收起列表、露出手机屏上的窗口：先换到它那一档、重新铺满，再收列表、激活它。
    /// 换档时列表还盖着，手机上看不到窗口被挪来挪去
    private func reveal() async {
        guard let id = display?.id, let p = placement else { return }
        // 先换档：App 一时读不到时 refill 什么都不做，档位也得对；换档触发的复查会在 App 恢复后补铺
        await switchWidth(id, to: p.width)
        await refill(because: "回到窗口")
        state.listVisible = false
        await windows.focus(p.window.key)
    }

    // MARK: 放窗口

    /// zoom 为 false：放的是在问用户的窗口（对话框、挂着 sheet 的文档），不调字号，按键会被对话框挡下
    private func place(_ window: WindowInfo, zoom: Bool = true) async {
        let started = timeline.now
        guard let id = readyDisplay(for: "放 \(window.label)") else {
            if workspace.pending { state.notice = .workspacePending }
            else if let record = ledger.pending() {
                state.notice = record.window.launchTime == nil ? .workspacePending : .windowUnresponsive(app: record.app)
            } else { state.notice = .screenNotReady }
            return
        }
        if placement?.window.key == window.key {
            await reveal()
            return
        }
        // 先确认要放的窗口够得着，再动手机屏上现在那个：点到刚关掉的卡片，不能先把现在的拆了、两头落空
        guard await reach(window) != nil else { return }
        // 原来那个、或上次没放回去的那个放不回去（App 卡住）就不放：两个窗口会叠在手机屏上，还原记录也只记得住一个
        if let p = placement, await !returnToOriginal(p) {
            Log.warn("\(p.window.label) 放不回去，先不换成 \(window.label)")
            state.notice = .windowUnresponsive(app: p.window.app)
            return
        }
        if let stuck = await putBackLeftover() {
            Log.warn("\(stuck.label) 还放不回去，先不放 \(window.label)")
            state.notice = .windowUnresponsive(app: stuck.app)
            return
        }
        // 放回别的窗口可能动到它（上次没放回去的就是它），重新读
        guard let look = await reach(window) else { return }
        // 先记账再动手。全屏的窗口这时读到的是全屏的位置，崩溃后按它放回再恢复全屏也对
        var next = Placement(window: window, record: PhoneRecord(
            window: window.key, app: window.app, label: window.label,
            original: workspace.contains(window.key) ? (workspace.original(window.key) ?? look.frame) : originalFrame(look.frame, offPhone: id),
            wasFullScreen: look.fullScreen, wasMinimized: look.minimized), width: activeProfile.width)
        guard write(next.record) else {
            state.notice = .recordUnwritable
            return
        }
        if look.minimized { await windows.setMinimized(window.key, false) }
        if look.fullScreen {
            await windows.setFullScreen(window.key, false)
            // 退出全屏后的位置才是它平时的位置：放回时回到这里再进全屏
            if let windowed = await windows.look(window.key)?.frame {
                next.record.original = originalFrame(windowed, offPhone: id)
                write(next.record)
            }
        }
        placement = next
        // 先按基准宽度铺，App 卡在自己的最小尺寸上时换档再铺；这时列表还盖着（「正在打开」）
        guard let got = await fill(&next, on: id) else {
            let notice = await unreachable(window)
            Log.warn("\(window.label) 挪不上手机屏（\(Self.reason(notice, gone: "刚关了"))），放回去")
            placement = nil
            await putBack(next.record)
            // 露着列表：手机屏可能停在铺的中途换过的那一档
            await matchWidth()
            state.notice = notice
            return
        }
        placement = next
        await windows.focus(window.key)
        state.listVisible = false
        let was = look.fullScreen ? "（原来全屏）" : look.minimized ? "（原来最小化）" : ""
        let took = String(format: "%.1f", timeline.now - started)
        let fill = Self.describeFill(got, in: displays.windowArea(id), width: displays.width(id) ?? next.width, profile: activeProfile)
        Log.info("\(window.label) 放上手机屏（\(took)s）：原位 \(next.record.original.short)\(was)，\(fill)")

        let steps = zoomBook.steps(for: window.bundleID, default: defaultZoom)
        guard zoom, steps != 0 else { return }
        // 窗口已经在手机屏上了，剩下的只是调字号
        state.work = .zooming
        await timeline.sleep(Self.settleDelay)
        await changeZoom(by: steps)
    }

    /// 原位：落在手机屏上的（App 按上次记住的位置把窗口开在了手机屏上）改成主屏居中，屏一撤那个位置就不存在了
    private func originalFrame(_ frame: CGRect, offPhone id: DisplayID) -> CGRect {
        guard let phone = displays.bounds(id), phone.contains(CGPoint(x: frame.midX, y: frame.midY)),
              let main = displays.mainArea() else { return frame }
        let size = CGSize(width: min(frame.width, main.width), height: min(frame.height, main.height))
        return CGRect(x: (main.midX - size.width / 2).rounded(), y: (main.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    // MARK: 打开、退出 App，关窗口

    /// 打开 App（newWindowIn 给了就是给这个进程新建窗口），等它此刻在屏上、之前不在屏上的标准窗口出来，放上手机屏。
    /// 认「之前不在屏上」而不认新编号：唤回时 App 常常重新显示原来那个窗口，编号不变
    private func openWindow(of app: AppInfo, newWindowIn running: Int32?) async {
        let started = timeline.now
        guard readyDisplay(for: "打开 \(app.name)") != nil else {
            state.notice = .screenNotReady
            return
        }
        let known = if let running { running } else { await apps.pid(of: app) }
        if let known, state.quitting.contains(known) { return Log.info("\(app.name) 正在退出，不打开") }
        var before: Set<WindowKey> = []
        if let known { before = Set(await windows.shownWindows(of: known).map(\.key)) }
        let pid: Int32
        if let running {
            guard await apps.newWindow(pid: running) else {
                Log.warn("\(app.name) 菜单里没有「新建窗口」（或没响应），没法新建窗口")
                state.notice = .noNewWindow(app: app.name)
                return
            }
            pid = running
        } else {
            guard let opened = await apps.open(app) else {
                Log.warn("打不开 \(app.name)（\(app.path ?? app.bundleID)）")
                state.notice = .openFailed(app: app.name)
                return
            }
            pid = opened
        }
        let wait = known == nil ? Self.launchWait : Self.windowWait
        switch await awaitWindow(of: pid, excluding: before, within: wait) {
        case .appeared(let window):
            let how = running != nil ? "新建窗口" : known == nil ? "启动" : "唤回"
            Log.info("\(app.name) \(how)后 \(String(format: "%.1f", timeline.now - started))s 出现 \(window.label)，放上手机屏")
            state.work = .placing(window)
            await place(window)
        case .appQuit:
            Log.warn("\(app.name) 打开后又退出了，没有窗口")
            state.notice = .openFailed(app: app.name)
        case .timedOut:
            Log.warn("\(app.name) 打开了，但 \(Int(wait))s 内没有可显示的窗口")
            state.notice = .noWindow(app: app.name)
        case .abandoned:
            Log.info("不要手机屏了，不再等 \(app.name) 的窗口")
        }
    }

    private enum Awaited {
        case appeared(WindowInfo)
        /// App 中途退了（启动就崩、自己退了）
        case appQuit
        case timedOut
        /// 不要手机屏了（远程结束、Snug 退出）：排在后面的撤屏不能干等
        case abandoned
    }

    private func awaitWindow(of pid: Int32, excluding known: Set<WindowKey>, within seconds: TimeInterval) async -> Awaited {
        let deadline = timeline.now + seconds
        while wanted {
            if let window = await windows.shownWindows(of: pid).first(where: { !known.contains($0.key) }) { return .appeared(window) }
            guard await apps.isRunning(pid: pid) else { return .appQuit }
            guard timeline.now < deadline else { return .timedOut }
            await timeline.sleep(Self.windowPoll)
        }
        return .abandoned
    }

    /// 盯着请它退出的 App：退完了就好；在问就放上手机屏等人答，答了取消就不再盯；
    /// 等满了还没退、也没在问，提示可以强制退出，之后再低频看一阵：它自己退了，提示就撤掉
    private func watchQuit(_ app: RunningApp) {
        watch(.quit(app.pid)) {
            defer { self.state.quitting.remove(app.pid) }
            let answer = await self.awaitAnswer(from: app.pid, within: Self.quitWait, done: { await !self.apps.isRunning(pid: app.pid) })
            guard !Task.isCancelled else { return }
            switch answer {
            case .done:
                Log.info("\(app.app.name) 已退出")
                self.onGone?(.app(app.pid))
            case .canceled: Log.info("\(app.app.name) 没退出（对话框里点了取消）")
            case .stalled:
                Log.warn("\(app.app.name) 请它退出 \(Int(Self.quitWait))s 后还在，也没有对话框")
                let stalled = Notice.quitStalled(app: app.app.name, pid: app.pid)
                self.state.notice = stalled
                self.state.quitting.remove(app.pid)
                let until = self.timeline.now + Self.stalledFollow
                while !Task.isCancelled, self.timeline.now < until, await self.apps.isRunning(pid: app.pid) {
                    await self.timeline.sleep(Self.stalledPoll)
                }
                guard !Task.isCancelled, await !self.apps.isRunning(pid: app.pid) else { return }
                Log.info("\(app.app.name) 后来自己退出了")
                self.onGone?(.app(app.pid))
                if self.state.notice == stalled { self.state.notice = nil }
            }
        }
    }

    /// 盯着请它关掉的窗口，同退出；等满了还在、也没在问，提示无响应
    private func watchClose(_ window: WindowInfo) {
        watch(.close(window.key)) {
            defer { self.state.closing.remove(window.key) }
            let answer = await self.awaitAnswer(from: window.key.pid, within: Self.closeWait, done: { await !self.windows.exists(window.key) })
            guard !Task.isCancelled else { return }
            switch answer {
            case .done:
                Log.info("\(window.label) 已关闭")
                self.onGone?(.window(window.key))
            case .canceled: Log.info("\(window.label) 没关（对话框里点了取消）")
            case .stalled:
                Log.warn("\(window.label) 请它关掉 \(Int(Self.closeWait))s 后还在，也没有对话框")
                self.state.notice = .windowUnresponsive(app: window.app)
            }
        }
    }

    /// 另起一个任务盯着，不占队。同一件事再盯一次（提示强制退出后又点了退出）先停掉旧的；撤屏时一起取消
    private func watch(_ id: Watched, _ body: @escaping @MainActor () async -> Void) {
        watches[id]?.cancel()
        watches[id] = Task {
            await body()
            // 取消的已经被换掉或清掉了，别把新的那个删了
            if !Task.isCancelled { watches[id] = nil }
        }
    }

    private func unwatch(_ id: Watched) {
        watches.removeValue(forKey: id)?.cancel()
    }

    private enum Answer {
        case done, canceled, stalled
    }

    /// 发出退出、关窗请求之后等结果：done 为真就是成了；App 在问用户（「要存储吗」「还有进程在跑」，
    /// 可能一连问好几次：多个未存储的文稿先问「要先检查吗」，再逐个问）就把问的窗口放上手机屏，问着就一直等；
    /// 问完了 done 还不成立，就是点了取消；一直没动静，等满 seconds 算卡住
    private func awaitAnswer(from pid: Int32, within seconds: TimeInterval, done: () async -> Bool) async -> Answer {
        let deadline = timeline.now + seconds
        var asked: WindowKey?
        var answeredAt: TimeInterval?
        while !Task.isCancelled {
            if await done() { return .done }
            if let asking = await windows.askingWindow(of: pid) {
                answeredAt = nil
                if asking.key != asked {
                    asked = asking.key
                    Log.info("\(asking.app) 在问，把 \(asking.label) 放上手机屏")
                    await placeAsking(asking)
                }
            } else if asked != nil {
                let at = answeredAt ?? timeline.now
                answeredAt = at
                if timeline.now - at >= Self.answerGrace { return .canceled }
            } else if timeline.now >= deadline {
                return .stalled
            }
            await timeline.sleep(Self.watchPoll)
        }
        return .canceled
    }

    /// 排进队里再放，状态也轮到它时才改：不然会被前面那个动作结束时的 work = nil 冲掉
    private func placeAsking(_ window: WindowInfo) async {
        guard !Task.isCancelled else { return }
        await lane.run {
            self.state.notice = nil
            self.state.work = .placing(window)
            await self.place(window, zoom: false)
            self.state.work = nil
        }.value
    }

    /// 放回原位、回到 App 资源库，返回放回去了没有。restoringState 为 false 时不恢复全屏、最小化（马上要关的窗口）。
    /// 没放回去时窗口还在手机屏上，照旧算放着（字号按实际缩回了多少算），还原记录也留着
    private func returnToOriginal(_ p: Placement, restoringState: Bool = true) async -> Bool {
        if let left = await putBack(p.record, restoringState: restoringState) {
            var p = p
            p.record = left
            placement = p
            return false
        }
        placement = nil
        state.listVisible = true
        return true
    }

    /// 按记录放回：缩回字号（窗口还在手机屏上、还是它 App 的当前窗口；缩完马上记账）→ 挪回原位 →
    /// 原来全屏的恢复全屏、原来最小化的再最小化。放回了、或窗口确实没了才销账，返回 nil；
    /// 窗口还在却缩不回、挪不动（App 没响应、没有权限）就留着记录（下次放窗口或下次启动再放），返回留下的这条
    @discardableResult
    private func putBack(_ record: PhoneRecord, restoringState: Bool = true) async -> PhoneRecord? {
        var record = record
        let zoom = record.zoom
        if zoom != 0 {
            // 缩不回就先不挪：挪回原位就销账了，多出来的字号再也没人缩
            guard await windows.zoom(record.window, steps: -zoom) else { return await stuckOrGone(record, "缩不回字号") }
            record.zoom = 0
            write(record)
        }
        if workspace.contains(record.window), let id = display?.id, let area = displays.windowArea(id) {
            guard let look = await windows.look(record.window) else { return await stuckOrGone(record, "窗口信息暂不可读") }
            if !look.minimized && !look.fullScreen {
                let target = CGRect(origin: area.origin, size: CGSize(width: min(record.original.width, area.width), height: min(record.original.height, area.height)))
                guard let got = await windows.move(record.window, to: target),
                      abs(got.minX - area.minX) <= 1, abs(got.minY - area.minY) <= 1, got.intersects(area) else { return record }
            }
            settleRecord()
            return nil
        }
        guard let got = await windows.move(record.window, to: record.original) else {
            return await stuckOrGone(record, "挪不动")
        }
        if restoringState, record.wasFullScreen {
            await timeline.sleep(Self.settleDelay)
            await windows.setFullScreen(record.window, true)
        } else if restoringState, record.wasMinimized {
            await windows.setMinimized(record.window, true)
        }
        guard got.matches(record.original) else {
            Log.warn("窗口原位尚未匹配，保留记录：\(record.window)")
            return record
        }
        settleRecord()
        let restored = !restoringState ? "" : record.wasFullScreen ? "并恢复全屏" : record.wasMinimized ? "并最小化" : ""
        Log.info("\(record.label) 已放回原位\(restored)\(zoom != 0 ? "，字号缩回 \(zoom) 级" : "")")
        return nil
    }

    /// 上次没放回去的窗口（Snug 崩溃，或 App 卡住没放成）：按还原记录放回去。
    /// 放下一个窗口之前必须先做，不然新记录会把它的原位和字号永远盖掉。返回仍然放不回去的那条
    @discardableResult
    private func putBackLeftover() async -> PhoneRecord? {
        guard placement == nil, let record = ledger.pending() else { return nil }
        guard record.window.launchTime != nil, record.window.bootSession != nil else {
            state.notice = .workspacePending
            Log.warn("旧单窗记录缺少启动身份，保留记录，未重放未知布局")
            return record
        }
        guard await windows.exists(record.window) else {
            Log.info("还原记录里的 \(record.label) 已经不在了（App 退出或窗口关了），记录作废")
            settleRecord()
            return nil
        }
        Log.info("\(record.label) 上次没放回去，现在放回 \(record.original.short)")
        return await putBack(record)
    }

    /// 放回时有一步做不了：窗口还在就留着记录、返回这条，确实没了就销账
    private func stuckOrGone(_ record: PhoneRecord, _ what: String) async -> PhoneRecord? {
        if await windows.exists(record.window) {
            Log.warn("\(record.label) 还在，但\(what)（App 没响应或没有辅助功能权限），还原记录留着，稍后再放回")
            return record
        }
        Log.info("\(record.label) 已经关了，不用放回")
        settleRecord()
        return nil
    }

    /// 先记账再发按键，改完核对窗口还铺不铺满。返回是否真的改了
    @discardableResult
    private func changeZoom(by delta: Int) async -> Bool {
        guard var p = placement else { return false }
        let before = p.record
        let target = (before.zoom + delta).clamped(to: ZoomBook.range)
        guard target != before.zoom else { return false }
        p.record.zoom = target
        guard write(p.record) else {
            state.notice = .recordUnwritable
            return false
        }
        guard await windows.zoom(p.window.key, steps: target - before.zoom) else {
            // 按键没发出去：记录改回原来的级数，不然还原时会多缩
            write(before)
            state.notice = await unreachable(p.window)
            Log.warn("\(p.window.label) 找不到了，字号没改")
            return false
        }
        placement = p
        Log.info("\(p.window.label) 字号比原来 \(target > 0 ? "+" : "")\(target) 级")
        await timeline.sleep(Self.settleDelay)
        // 在列表里调的字号：窗口被盖着，返回时 reveal 再补铺；这时铺会把屏换到窗口那一档
        if !state.listVisible { await refill(because: "字号改了") }
        return true
    }

    // MARK: 小工具

    private func begin(_ work: Work) {
        state.notice = nil
        state.work = work
    }

    /// 可以放窗口的手机屏；没好时写明是哪一步没好
    private func readyDisplay(for what: String) -> DisplayID? {
        guard let id = display?.id else {
            Log.warn("\(what)：没有手机屏（\(state.screen)）")
            return nil
        }
        guard displays.windowArea(id) != nil else {
            Log.warn("\(what)：读不到手机屏 #\(id) 的可放区域（屏幕组合可能还在变）")
            return nil
        }
        return id
    }

    /// 铺满了没有、用的哪一档。没铺满是 App 要的比最宽一档还宽，或者换档没成（见前面的日志）
    private static func describeFill(_ got: CGRect, in area: CGRect?, width: Int, profile: PhoneScreenSize) -> String {
        let screen = width == profile.width ? "" : "（手机屏 \(width) 宽）"
        if let area, got.matches(area) { return "已铺满\(screen)" }
        return "没铺满\(screen)，实际 \(got.short)"
    }

    /// 读要放的窗口；读不到就提示是关了还是 App 没响应
    private func reach(_ window: WindowInfo) async -> WindowLook? {
        if let look = await windows.look(window.key) { return look }
        let notice = await unreachable(window)
        Log.warn("读不到 \(window.label)（\(Self.reason(notice, gone: "已经关了"))），不放")
        state.notice = notice
        return nil
    }

    /// 读不到、挪不动的窗口：是关了，还是 App 没响应
    private func unreachable(_ window: WindowInfo) async -> Notice {
        await windows.exists(window.key) ? .windowUnresponsive(app: window.app) : .windowGone(app: window.app)
    }

    /// 日志里的原因
    private static func reason(_ notice: Notice, gone: String) -> String {
        if case .windowGone = notice { gone } else { "App 没响应或没有辅助功能权限" }
    }

    @discardableResult
    private func write(_ record: PhoneRecord) -> Bool {
        do {
            try ledger.record(record)
            return true
        } catch {
            Log.error("还原记录写不进去（\(record.label)）：\(error)")
            return false
        }
    }

    private func settleRecord() {
        do {
            try ledger.settle()
        } catch {
            // 删不掉的记录下次启动会再还原一次：窗口已经在原位，再挪一次也是原位
            Log.error("还原记录删不掉：\(error)")
        }
    }

    private func saveZoomBook() {
        do {
            try zoomFile.save(zoomBook)
        } catch {
            Log.error("记不住字号级数（zoom.json 写不进去）：\(error)")
        }
    }
}

/// 放在手机屏上的那个窗口：它的还原记录（写进盘里的就是这一份，不另抄字段）、它要的那一档和上次挪完的样子
private struct Placement {
    let window: WindowInfo
    var record: PhoneRecord
    /// 手机屏用哪一档（ScreenFit）：先按基准宽度，铺不满时换成装得下它的一档
    var width: Int
    /// 上次挪完的样子：比最宽一档还宽的窗口铺不满，以它为准判断窗口有没有被再挪动
    var settled: CGRect?
}

/// 一条队：动作按提交顺序一个做完再做下一个
@MainActor
final class SerialLane {
    private var tail: Task<Void, Never>?

    @discardableResult
    func run(_ operation: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }

    func drain() async {
        while let current = tail {
            await current.value
            if tail == current { return }
        }
    }
}
