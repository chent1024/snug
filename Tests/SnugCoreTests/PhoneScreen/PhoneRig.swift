import CoreGraphics
import Foundation
@testable import SnugCore

func testWindowKey(pid: Int32, id: UInt32) -> WindowKey {
    WindowKey(pid: pid, id: id, launchTime: Double(pid), bootSession: "test-boot")
}

// 手机屏调度的测试装置：一套假系统 + 一个 PhoneDesk，和几个常用的窗口

let ghostty = WindowInfo(key: testWindowKey(pid: 10, id: 7), app: "Ghostty", bundleID: "com.mitchellh.ghostty", title: "~/snug")
let finder = WindowInfo(key: testWindowKey(pid: 11, id: 8), app: "Finder", bundleID: "com.apple.finder", title: "下载")
let safari = WindowInfo(key: testWindowKey(pid: 12, id: 9), app: "Safari", bundleID: "com.apple.Safari", title: "GitHub")
let notes = WindowInfo(key: testWindowKey(pid: 13, id: 10), app: "备忘录", bundleID: "com.apple.Notes", title: "清单")
let ghosttyHome = CGRect(x: 100, y: 100, width: 1200, height: 800)
let finderHome = CGRect(x: 300, y: 200, width: 800, height: 500)
let safariHome = CGRect(x: 0, y: 25, width: 1512, height: 920)
/// Safari 退出全屏后的平时位置
let safariWindowed = CGRect(x: 200, y: 100, width: 1000, height: 700)
let notesHome = CGRect(x: 400, y: 300, width: 700, height: 500)
let phoneArea = FakeDisplays.area(width: PhoneScreenSize.redmi.width)

/// 一套假系统 + 一个 PhoneDesk。每个用例一个临时数据目录
@MainActor
final class Rig {
    let tmp: TempDir
    let paths: SnugPaths
    let journal = Journal()
    let displays: FakeDisplays
    let windows: FakeWindows
    let apps: FakeApps
    let timeline = ManualTimeline()
    let desk: PhoneDesk

    init(dataDirectory: URL? = nil) throws {
        let tmp = try TempDir()
        let dir = tmp.url
        self.tmp = tmp
        paths = SnugPaths(dataDirectory: dataDirectory ?? dir, logFile: dir.appendingPathComponent("Snug.log"))
        displays = FakeDisplays(journal: journal)
        windows = FakeWindows(journal: journal, ledger: paths.phoneRecord)
        windows.add(ghostty.key, frame: ghosttyHome, info: ghostty)
        windows.add(finder.key, frame: finderHome, info: finder)
        windows.add(safari.key, frame: safariHome, fullScreen: true, windowed: safariWindowed, info: safari)
        windows.add(notes.key, frame: notesHome, minimized: true, info: notes)
        apps = FakeApps(journal: journal, windows: windows, timeline: timeline)
        desk = PhoneDesk(displays: displays, windows: windows, apps: apps, timeline: timeline, paths: paths)
        let timeline = timeline
        displays.clock = { timeline.now }
        windows.clock.withLock { $0 = { timeline.now } }
    }

    var record: PhoneRecord? { RestoreRecord<PhoneRecord>(url: paths.phoneRecord).pending() }

    /// 加好手机屏，流水账清空
    func ready() async {
        desk.setWanted(true)
        await desk.idle()
        journal.clear()
    }

    func pull(_ w: WindowInfo) async {
        desk.pull(w)
        await desk.idle()
    }
}
