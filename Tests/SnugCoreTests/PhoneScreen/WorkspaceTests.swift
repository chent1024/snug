import Foundation
import CoreGraphics
import Testing
@testable import SnugCore

@Suite("整会话工作窗口")
@MainActor
struct WorkspaceTests {
    @Test("进入手机屏才统一收拢，最小化/全屏保持，切换留在手机屏，断开统一归位")
    func sessionLifecycle() async throws {
        let r = try Rig()
        await r.ready()
        #expect(r.windows.window(ghostty.key)?.frame == ghosttyHome)
        #expect(!FileManager.default.fileExists(atPath: r.paths.workspace.path))
        r.desk.enterWorkspace(); await r.desk.idle()
        #expect(r.windows.window(ghostty.key)?.frame.origin == phoneArea.origin)
        #expect(r.windows.window(finder.key)?.frame.origin == phoneArea.origin)
        #expect(r.windows.window(safari.key)?.fullScreen == true)
        #expect(r.windows.window(safari.key)?.frame == safariHome)
        #expect(r.windows.window(notes.key)?.minimized == true)
        let frozen = try #require(JSONFile<WorkspaceSnapshot>(url: r.paths.workspace).loadValue)
        #expect(frozen.windows.first { $0.id == ghostty.key }?.state.frame == ghosttyHome)
        await r.pull(ghostty)
        #expect(r.windows.window(ghostty.key)?.zoom == 2)
        await r.pull(finder)
        #expect(r.windows.window(ghostty.key)?.zoom == 0)
        #expect(r.windows.window(ghostty.key)?.frame.minX == phoneArea.minX)
        #expect(r.windows.window(ghostty.key)?.frame != ghosttyHome)
        #expect(try Data(contentsOf: r.paths.workspace) == (try JSONEncoder.workspace.encode(frozen)))
        r.desk.setWanted(false); await r.desk.idle()
        #expect(r.windows.window(ghostty.key)?.frame == ghosttyHome)
        #expect(r.windows.window(finder.key)?.frame == finderHome)
        #expect(r.windows.window(safari.key)?.fullScreen == true)
        #expect(r.windows.window(notes.key)?.minimized == true)
        #expect(!FileManager.default.fileExists(atPath: r.paths.workspace.path))
        #expect(r.record == nil)
    }

    @Test("ChatGPT四级字号只反转本轮增量，断开后恢复原窗口")
    func targetZoomAndRestore() async throws {
        let r = try Rig()
        let target = WindowInfo(key: testWindowKey(pid: 99, id: 90), app: "ChatGPT", bundleID: "com.openai.codex", title: "fixture")
        r.windows.add(target.key, frame: ghosttyHome, info: target)
        r.desk.setDefaultZoom(4)
        await r.ready(); r.desk.enterWorkspace(); await r.desk.idle()
        await r.pull(target)
        #expect(r.windows.window(target.key)?.zoom == 4)
        #expect(r.record?.zoom == 4)
        await r.pull(finder)
        #expect(r.windows.window(target.key)?.zoom == 0)
        #expect(r.windows.window(target.key)?.frame.minX == phoneArea.minX)
        r.desk.setWanted(false); await r.desk.idle()
        #expect(r.windows.window(target.key)?.frame == ghosttyHome)
        #expect(r.windows.window(target.key)?.zoom == 0)
        #expect(r.record == nil)
    }

    @Test("主动退出或关闭前归还工作区几何，失败时不发关闭请求")
    func explicitCloseRestoresFirst() async throws {
        let r = try Rig()
        let appInfo = AppInfo(bundleID: "com.mitchellh.ghostty", name: "Ghostty", path: "/fixture/Ghostty.app")
        let app = r.apps.run(appInfo, pid: ghostty.key.pid, windows: [ghostty])
        r.apps.onQuit(appInfo, .refuses)
        await r.ready(); r.desk.enterWorkspace(); await r.desk.idle()
        await r.pull(ghostty)
        r.desk.quit(app); await r.desk.idle()
        #expect(r.windows.window(ghostty.key)?.frame == ghosttyHome)
        #expect(r.windows.window(ghostty.key)?.zoom == 0)
        #expect(r.journal.all.contains("quit 10"))
        #expect(FileManager.default.fileExists(atPath: r.paths.workspace.path))
        r.windows.onClose(finder.key, .stalls)
        r.desk.close(finder); await r.desk.idle()
        #expect(r.windows.window(finder.key)?.frame == finderHome)
        #expect(r.journal.all.contains("close 8"))

        let failed = try Rig(); let failedApp = failed.apps.run(appInfo, pid: 10)
        await failed.ready(); failed.desk.enterWorkspace(); await failed.desk.idle()
        failed.windows.failWorkspaceRestore.withLock { $0 = true }
        failed.desk.quit(failedApp); await failed.desk.idle()
        failed.desk.close(finder); await failed.desk.idle()
        #expect(!failed.journal.all.contains("quit 10"))
        #expect(!failed.journal.all.contains("close 8"))
        #expect(failed.desk.state.notice == .workspacePending)
    }

    @Test("未进入手机屏不回放正常桌面上的用户改动")
    func neverEnteredDoesNotReplay() async throws {
        let r = try Rig(); await r.ready()
        let userFrame = CGRect(x: 900, y: 80, width: 700, height: 600)
        r.windows.setFrame(ghostty.key, userFrame)
        r.desk.setWanted(false); await r.desk.idle()
        #expect(r.windows.window(ghostty.key)?.frame == userFrame)
        #expect(!r.journal.all.contains("workspace restore"))
    }

    @Test("失败保留原位，不让新会话覆盖待恢复记录")
    func failedRestorePreservesBaseline() async throws {
        let r = try Rig(); await r.ready(); r.desk.enterWorkspace(); await r.desk.idle()
        let baseline = try Data(contentsOf: r.paths.workspace)
        r.windows.failWorkspaceRestore.withLock { $0 = true }
        r.desk.setWanted(false); await r.desk.idle()
        #expect(r.desk.state.notice == .workspacePending)
        #expect(try Data(contentsOf: r.paths.workspace) == baseline)
        let creates = r.journal.all.filter { $0 == "create" }.count
        r.desk.setWanted(true); await r.desk.idle()
        #expect(r.journal.all.filter { $0 == "create" }.count == creates)
        #expect(try Data(contentsOf: r.paths.workspace) == baseline)
    }

    @Test("锁屏撤屏后保留记录，解锁自动续行，不把锁屏当窗口关闭")
    func lockAndResume() async throws {
        let r = try Rig(); await r.ready(); r.desk.enterWorkspace(); await r.desk.idle()
        await r.pull(ghostty)
        r.windows.screenLocked.withLock { $0 = true }
        r.desk.setWanted(false); await r.desk.idle()
        #expect(r.desk.state.screen == .off)
        #expect(FileManager.default.fileExists(atPath: r.paths.workspace.path))
        #expect(r.record?.zoom == 2)
        r.windows.screenLocked.withLock { $0 = false }
        r.desk.verifyPlacement(); await r.desk.idle()
        #expect(r.windows.window(ghostty.key)?.zoom == 0)
        #expect(r.windows.window(ghostty.key)?.frame == ghosttyHome)
        #expect(r.windows.window(finder.key)?.frame == finderHome)
        #expect(!FileManager.default.fileExists(atPath: r.paths.workspace.path))
        #expect(r.record == nil)
    }

    @Test("重开后从同一记录恢复，不把收拢后的尺寸当成原位")
    func restartRecovery() async throws {
        let first = try Rig(); await first.ready(); first.desk.enterWorkspace(); await first.desk.idle()
        let second = try Rig(dataDirectory: first.paths.dataDirectory)
        second.windows.setFrame(ghostty.key, phoneArea)
        second.windows.setFrame(finder.key, phoneArea)
        second.desk.recover(); await second.desk.idle()
        #expect(second.windows.window(ghostty.key)?.frame == ghosttyHome)
        #expect(second.windows.window(finder.key)?.frame == finderHome)
        #expect(!FileManager.default.fileExists(atPath: second.paths.workspace.path))
    }

    @Test("原窗口关闭跳过，不影响其它窗口归位")
    func closedWindowIsNotReplaced() async throws {
        let r = try Rig(); await r.ready(); r.desk.enterWorkspace(); await r.desk.idle()
        r.windows.vanish(ghostty.key)
        r.desk.setWanted(false); await r.desk.idle()
        #expect(r.windows.window(ghostty.key) == nil)
        #expect(r.windows.window(finder.key)?.frame == finderHome)
        #expect(!FileManager.default.fileExists(atPath: r.paths.workspace.path))
    }

    @Test("捕获不可读不批量移动，也不隐藏已有虚拟屏")
    func missingCaptureIsNotPartialBaseline() async throws {
        let r = try Rig(); r.windows.block()
        await r.ready(); r.desk.enterWorkspace(); await r.desk.idle()
        #expect(r.desk.state.display != nil)
        #expect(r.desk.state.notice == .workspaceCaptureUnavailable)
        #expect(r.windows.window(ghostty.key)?.frame == ghosttyHome)
        #expect(!FileManager.default.fileExists(atPath: r.paths.workspace.path))
    }

    @Test("损坏原位记录不被隔离后静默覆盖")
    func corruptBaselineStopsTakeover() async throws {
        let tmp = try TempDir(); let path = tmp.url.appendingPathComponent("workspace.json")
        let bytes = Data("{bad".utf8); try bytes.write(to: path)
        let r = try Rig(dataDirectory: tmp.url)
        r.desk.setWanted(true); await r.desk.idle()
        #expect(!r.journal.all.contains("create"))
        #expect(try Data(contentsOf: path) == bytes)
        #expect(r.desk.state.notice == .workspacePending)
    }

    @Test("暂缺元数据不当作关闭；其他桌面不被强搬且不虚报恢复成功")
    func metadataAndOtherDesktop() async throws {
        let r = try Rig()
        let snapshot = try #require(await r.windows.captureWorkspace())
        let engine = WorkspaceLayout(access: r.windows, windows: snapshot.windows)
        r.windows.hideWorkspaceMetadata.withLock { $0 = true }
        #expect(engine.advance(.collect(phoneArea), now: 0) == .waitingForMetadata)
        #expect(r.windows.window(ghostty.key)?.frame == ghosttyHome)
        #expect(engine.advance(.collect(phoneArea), now: 16) == .failed(snapshot.windows.map { $0.id.id }.sorted()))
        r.windows.hideWorkspaceMetadata.withLock { $0 = false }
        var hidden = try #require(snapshot.windows.first { $0.id == ghostty.key })
        hidden.visible = false
        let other = WorkspaceLayout(access: r.windows, windows: [hidden])
        var last = WorkspaceLayout.Progress.pending
        for tick in 0..<4 { last = other.advance(.collect(phoneArea), now: Double(tick)) }
        #expect(last == .complete(verified: 0, skipped: 1))
        #expect(r.windows.window(ghostty.key)?.frame == ghosttyHome)
        let changed = CGRect(x: 200, y: 100, width: 600, height: 500)
        r.windows.setFrame(ghostty.key, changed)
        let restore = WorkspaceLayout(access: r.windows, windows: [hidden])
        for tick in 0..<18 { last = restore.advance(.restore, now: Double(tick)) }
        #expect(last == .failed([ghostty.key.id]))
        #expect(r.windows.window(ghostty.key)?.frame == changed)
    }

    @Test("内核启动小数秒无损保存，第三方旧弱身份不能成为工作区基线")
    func strongIdentityRoundTrip() throws {
        let tmp = try TempDir()
        let key = WindowKey(pid: 55, id: 100, launchTime: 123.987654, bootSession: "boot")
        let desktop = WorkspaceDesktop(display: "physical", space: 1, uuid: "space", soleUserSpace: true)
        let s = WorkspaceSnapshot(windows: [.init(id: key, state: .init(frame: ghosttyHome, desktop: desktop), visible: true)])
        let f = JSONFile<WorkspaceSnapshot>(url: tmp.url.appendingPathComponent("workspace.json"))
        try f.save(s)
        #expect(f.loadValue == s)
        #expect(f.loadValue?.windows[0].id.launchTime == 123.987654)
        let weak = WorkspaceSnapshot(windows: [.init(id: .init(pid: 55, id: 100), state: .init(frame: ghosttyHome), visible: true)])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(weak)) }
    }
}

private extension JSONFile {
    var loadValue: Value? { if case .loaded(let value) = load() { return value }; return nil }
}
private extension JSONEncoder {
    static var workspace: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }
}
