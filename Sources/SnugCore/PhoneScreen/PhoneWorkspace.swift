// 整次手机工作区的物理原位。PhoneRecord仍只记录当前焦点的临时字号/铺满，不能覆盖这里的基线。
import Foundation
import CoreGraphics

@MainActor
final class PhoneWorkspace {
    private let file: JSONFile<WorkspaceSnapshot>
    private let windows: any WindowControl
    private(set) var snapshot: WorkspaceSnapshot?
    private(set) var active = false
    private(set) var pending = false
    private(set) var blocked = false
    private(set) var captureUnavailable = false
    private var requested = false

    init(paths: SnugPaths, windows: any WindowControl) {
        file = JSONFile(url: paths.workspace); self.windows = windows
        switch file.load() {
        case .missing: break
        case .loaded(let saved): snapshot = saved; pending = true; requested = true
        case .corrupt(let error):
            blocked = true; pending = true
            Log.error("工作区原位记录不可读，保留文件并停止覆盖：\(error)")
        }
    }

    func captureBeforeScreen() async {
        guard snapshot == nil, !pending, !blocked else { return }
        guard let captured = await windows.captureWorkspace() else { captureUnavailable = true; return }
        // 先冻结在内存；用户尚未进入手机屏时，不应在崩溃后重放其正常桌面操作。
        snapshot = captured; captureUnavailable = false
    }

    func contains(_ key: WindowKey) -> Bool { active && snapshot?.eligible.contains(key) == true }
    func original(_ key: WindowKey) -> CGRect? { snapshot?.windows.first { $0.id == key }?.state.frame }

    func collect(in area: CGRect) async -> WorkspaceOutcome {
        guard !blocked, !pending, let snapshot else { return .deferred }
        if !requested {
            do { try file.save(snapshot) } catch {
                captureUnavailable = true
                Log.error("工作区原位无法保存，未移动任何窗口：\(error)")
                return .deferred
            }
        }
        requested = true; active = true
        return await windows.applyWorkspace(snapshot, goal: .collect(area))
    }

    /// 显式关闭/退出前归还该应用的几何，避免应用把手机窄尺寸记成下次启动尺寸。
    /// 会话原位文件仍保留；取消退出后也不重新捕获被修改过的布局。
    func restoreBeforeClosing(pid: Int32, window: WindowKey? = nil) async -> Bool {
        guard active, let snapshot else { return true }
        let selected = snapshot.windows.filter {
            snapshot.eligible.contains($0.id) && $0.id.pid == pid && (window == nil || window == $0.id)
        }
        guard !selected.isEmpty else { return true }
        switch await windows.applyWorkspace(WorkspaceSnapshot(windows: selected), goal: .restore) {
        case .complete: return true
        case .deferred, .failed: return false
        }
    }

    func screenRetired() {
        active = false
        if requested { pending = true }
    }

    func restore() async -> WorkspaceOutcome {
        guard !blocked else { return .failed([]) }
        guard let snapshot else { pending = false; return .complete(verified: 0, skipped: 0) }
        // 从未进入工作区时，正常建撤屏已由原有快照保护；异常重启的pending仍必须完整核验。
        if !requested && !pending { return clear() }
        let result = await windows.applyWorkspace(snapshot, goal: .restore)
        switch result {
        case .complete:
            let cleared = clear()
            if case .failed = cleared { return cleared }
        case .deferred: pending = true
        case .failed: pending = true; blocked = true
        }
        return result
    }

    private func clear() -> WorkspaceOutcome {
        do { try file.remove() } catch {
            pending = true; blocked = true
            Log.error("原位已核验但工作区记录未清理：\(error)")
            return .failed([])
        }
        snapshot = nil; pending = false; active = false; requested = false; captureUnavailable = false
        return .complete(verified: 0, skipped: 0)
    }
}
