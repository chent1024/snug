// 只创建并操纵本测试子进程的两个普通窗口与一个最小化窗口。
// 没有权限、锁屏或桌面只读接口不可用时退出77；不请求授权、不改变显示拓扑。
import AppKit
import ApplicationServices
import Foundation
import SnugCore

private struct FixtureReady: Codable {
    var pid: Int32
    var ordinary: [UInt32]
    var minimized: UInt32
}

private enum CheckError: Error {
    case unavailable(String)
    case failed(String)
}

@main
@MainActor
enum WorkspaceNative {
    static func main() {
        do {
            if CommandLine.arguments.contains("--fixture") {
                try fixture()
            } else {
                try controller()
            }
        } catch CheckError.unavailable(let reason) {
            print("SKIP: \(reason); no permissions requested and no user windows manipulated")
            exit(77)
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    /// 只用明确的活动内置屏，避免把第三方虚拟显示器误认为物理屏。
    private static func physicalScreen() throws -> NSScreen {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
            return CGDisplayIsBuiltin(id) != 0 && CGDisplayIsActive(id) != 0
        }), screen.visibleFrame.width >= 760, screen.visibleFrame.height >= 600 else {
            throw CheckError.unavailable("no sufficiently large active built-in physical screen")
        }
        return screen
    }

    private static func fixture() throws {
        guard CommandLine.arguments.count == 4 else { throw CheckError.failed("invalid fixture arguments") }
        let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let area = try physicalScreen().visibleFrame
        let frames = [
            CGRect(x: area.minX + 70, y: area.maxY - 430, width: 560, height: 340),
            CGRect(x: area.minX + 130, y: area.maxY - 510, width: 620, height: 380),
            CGRect(x: area.minX + 180, y: area.maxY - 470, width: 480, height: 300),
        ]
        let windows = frames.map { frame in
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Snug isolated workspace fixture"
            window.minSize = CGSize(width: 240, height: 160)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.orderBack(nil)
            return window
        }
        try String(getpid()).write(to: output.appendingPathComponent("fixture.pid"), atomically: true, encoding: .utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            app.unhideWithoutActivation()
            windows[2].miniaturize(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            do {
                guard windows.allSatisfy({ $0.windowNumber > 0 }), windows[2].isMiniaturized else {
                    throw CheckError.failed("fixture windows did not reach their native initial state")
                }
                let ready = FixtureReady(pid: getpid(), ordinary: windows.prefix(2).map { UInt32($0.windowNumber) },
                                         minimized: UInt32(windows[2].windowNumber))
                try JSONEncoder().encode(ready).write(to: output.appendingPathComponent("ready.json"), options: .atomic)
            } catch {
                print("fixture setup failed: \(error)")
                app.terminate(nil)
            }
        }
        withExtendedLifetime(windows) { app.run() }
    }

    private static func controller() throws {
        guard CommandLine.arguments.count == 3 else { throw CheckError.failed("expected fixture App and temporary directory") }
        guard !WindowIdentity.screenLocked else { throw CheckError.unavailable("Mac is locked") }
        guard AXIsProcessTrusted() else { throw CheckError.unavailable("native test controller has no Accessibility grant") }
        AX.configureTimeout()
        let screen = try physicalScreen()
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let app = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let child = Process()
        child.executableURL = app.appendingPathComponent("Contents/MacOS/workspace-native")
        child.arguments = ["--fixture", app.path, output.path]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            pump(until: { !child.isRunning }, seconds: 2)
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        let readyURL = output.appendingPathComponent("ready.json")
        pump(until: { FileManager.default.fileExists(atPath: readyURL.path) || !child.isRunning }, seconds: 6)
        guard child.isRunning, let data = try? Data(contentsOf: readyURL) else {
            throw CheckError.failed("isolated fixture did not become ready")
        }
        let ready = try JSONDecoder().decode(FixtureReady.self, from: data)
        guard ready.pid == child.processIdentifier,
              let application = NSRunningApplication(processIdentifier: ready.pid),
              application.bundleIdentifier == "com.chent1024.snug.workspace-fixture" else {
            throw CheckError.failed("fixture process identity did not match the launched child")
        }
        let snapshot = try captureAndCollect(application, ready: ready, screen: screen)
        let file = output.appendingPathComponent("workspace.json")
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        let loaded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: file))
        guard loaded == snapshot else { throw CheckError.failed("persisted workspace snapshot did not round-trip") }

        // 不复用capture/collect阶段的AX引用；验证从持久记录重新定位同一窗口实例。
        let fresh = WorkspaceWindows(applications: [application])
        let restoration = WorkspaceLayout(access: fresh, windows: loaded.windows)
        try converge(restoration, goal: .restore)
        for original in loaded.windows {
            guard case .window(let current) = fresh.read(original.id) else {
                throw CheckError.failed("restored fixture window \(original.id.id) is unreadable")
            }
            guard current.minimized == original.state.minimized,
                  current.fullScreen == original.state.fullScreen else {
                throw CheckError.failed("fixture minimized/fullscreen state changed")
            }
            if !original.state.minimized {
                guard near(current.frame, original.state.frame), current.desktop == original.state.desktop else {
                    throw CheckError.failed("fixture geometry or desktop ownership differs after restore")
                }
            }
        }
        print("PASS: native WorkspaceWindows + WorkspaceLayout collected 2 isolated ordinary windows, restored serialized geometry within 1 point with a fresh access instance, retained original desktop ownership and preserved 1 minimized window; no display topology or user-window writes")
    }

    private static func captureAndCollect(_ child: NSRunningApplication, ready: FixtureReady, screen: NSScreen) throws -> WorkspaceSnapshot {
        let expected = Set(ready.ordinary + [ready.minimized])
        let access = WorkspaceWindows(applications: [child])
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var captured: [WorkspaceWindow]?
        repeat {
            guard !WindowIdentity.screenLocked else { throw CheckError.unavailable("Mac locked during fixture setup") }
            if let windows = access.capture(), Set(windows.map(\.id.id)) == expected,
               windows.filter({ !$0.state.minimized }).allSatisfy({ $0.visible }),
               windows.filter({ $0.state.minimized }).count == 1 {
                captured = windows
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while ProcessInfo.processInfo.systemUptime < deadline
        guard let captured else {
            let reason = access.captureFailure ?? "fixture did not expose exactly 2 visible and 1 minimized window"
            if reason.contains("desktop") || reason.contains("authorization") || reason.contains("error=-25211") {
                throw CheckError.unavailable(reason)
            }
            throw CheckError.failed("fixture capture: \(reason)")
        }
        guard captured.allSatisfy({ $0.id.pid == ready.pid && $0.id.launchTime != nil && $0.id.bootSession != nil }),
              Set(captured.filter({ !$0.state.minimized }).map(\.id.id)) == Set(ready.ordinary),
              captured.first(where: { $0.id.id == ready.minimized })?.state.minimized == true else {
            throw CheckError.failed("capture escaped fixture identity or lost required window states")
        }
        guard captured.filter({ !$0.state.minimized }).allSatisfy({ $0.state.desktop != nil }) else {
            throw CheckError.unavailable("native desktop metadata unavailable")
        }
        let visible = axRect(screen.visibleFrame)
        let area = CGRect(x: visible.minX + 36, y: visible.minY + 36, width: 380, height: 260)
        guard visible.contains(area) else { throw CheckError.failed("test area is outside the physical visible screen") }
        let session = WorkspaceLayout(access: access, windows: captured)
        try converge(session, goal: .collect(area))
        for original in captured {
            guard case .window(let current) = access.read(original.id) else { throw CheckError.failed("collected fixture window unreadable") }
            if original.state.minimized {
                guard current.minimized else { throw CheckError.failed("collection expanded the minimized fixture") }
            } else {
                guard near(current.frame, area), current.desktop == original.state.desktop,
                      !near(current.frame, original.state.frame) else {
                    throw CheckError.failed("collection did not move/resize within the same physical desktop")
                }
            }
        }
        return WorkspaceSnapshot(windows: captured)
    }

    private static func converge(_ layout: WorkspaceLayout, goal: WorkspaceLayout.Goal) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard !WindowIdentity.screenLocked else { throw CheckError.unavailable("Mac locked during native verification") }
            guard AXIsProcessTrusted() else { throw CheckError.unavailable("Accessibility authorization was withdrawn") }
            switch layout.advance(goal) {
            case .pending, .waitingForMetadata:
                RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            case .complete(let verified, let skipped):
                guard verified == 2, skipped == 1 else { throw CheckError.failed("unexpected native verification counts: \(verified)/\(skipped)") }
                return
            case .failed(let ids):
                let reasons = layout.mismatchReasons.values.joined(separator: "; ")
                if reasons.contains("desktop metadata") || reasons.contains("display absent") {
                    throw CheckError.unavailable(reasons)
                }
                throw CheckError.failed("native readback failed for fixture IDs \(ids): \(reasons)")
            }
        }
        throw CheckError.failed("native workspace convergence exceeded 30 seconds")
    }

    private static func pump(until ready: () -> Bool, seconds: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !ready(), ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 &&
            abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    private static func axRect(_ frame: CGRect) -> CGRect {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        return CGRect(x: frame.minX, y: (primary?.frame.height ?? 0) - frame.maxY,
                      width: frame.width, height: frame.height)
    }
}
