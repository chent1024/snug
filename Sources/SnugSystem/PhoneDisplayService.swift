// 手机屏的建、撤、换档。每次create冻结设备尺寸；后续设置只影响下次创建。
// 各档一次登记为标准1×，换档由短命帮手完成，主程序不提交模式事务。
import AppKit
import CGVirtualDisplayBridge
import SnugCore

@MainActor
public final class PhoneDisplayService: PhoneDisplays {
    static let onlineTimeout: TimeInterval = 6
    static let offlineTimeout: TimeInterval = 10
    nonisolated static let helperTimeout: TimeInterval = 10
    static let screenUpdateTimeout: TimeInterval = 2

    private struct OwnedDisplay {
        let object: CGVirtualDisplay
        let size: PhoneScreenSize
        let bornAt: TimeInterval
    }

    private var displays: [DisplayID: OwnedDisplay] = [:]
    private let helper: URL
    public var nextSize: PhoneScreenSize

    public init(helper: URL, size: PhoneScreenSize) {
        self.helper = helper
        nextSize = size
    }

    public func profile(_ id: DisplayID) -> PhoneScreenSize? { displays[id]?.size }

    public func create() async throws -> DisplayID {
        let size = nextSize
        var lastError: any Error = PhoneScreenError.createFailed
        for serial in PhoneScreenSpec.serials(for: size) {
            try Task.checkCancellation()
            guard let made = make(serial: serial, size: size) else {
                Log.warn("手机屏（serial=\(serial)）建不出来，换备用身份")
                continue
            }
            let id = made.id
            lastError = PhoneScreenError.neverOnline
            guard made.applied else {
                // 对象已交给WindowServer；等初次热插拔落定再释放，不丢局部对象造成立即撤屏。
                _ = await wait(id, online: true, timeout: Self.onlineTimeout)
                lastError = PhoneDisplayFailure.applyFailed(size)
                await retire(id)
                continue
            }
            guard await wait(id, online: true, timeout: Self.onlineTimeout) else {
                Log.warn("手机屏 #\(id) 建好 \(Int(Self.onlineTimeout)) 秒没上线，换备用身份")
                await retire(id)
                continue
            }
            await settle(0.8)
            guard await waitForReadableMode(id) else {
                lastError = PhoneDisplayFailure.modeNotReady(size)
                await retire(id)
                continue
            }
            if width(id) != size.width { await setWidth(id, size.width) }
            guard await waitForWidth(id, size.width) else {
                lastError = PhoneDisplayFailure.modeNotReady(size)
                Log.warn("手机屏 #\(id) 基础尺寸未匹配 \(size.label)：\(DisplayMode.describe(id))，撤回")
                await retire(id)
                continue
            }
            return id
        }
        throw lastError
    }

    public func retire(_ id: DisplayID) async {
        // 这里只取出生时刻，不能把含object的OwnedDisplay局部变量留到释放等待结束。
        guard let bornAt = displays[id]?.bornAt else {
            Log.warn("要撤的手机屏 #\(id) 不是本进程建的")
            return
        }
        let remaining = PhoneScreenSpec.minimumLifetime - (ProcessInfo.processInfo.systemUptime - bornAt)
        if remaining > 0 { await settle(remaining) }
        autoreleasepool { displays[id] = nil }
        if await !wait(id, online: false, timeout: Self.offlineTimeout) {
            Log.warn("手机屏 #\(id) 释放 \(Int(Self.offlineTimeout)) 秒后仍在线")
        }
        await settle(1)
    }

    public func width(_ id: DisplayID) -> Int? {
        guard let size = profile(id) else { return nil }
        return DisplayMode.standardWidth(id, for: size)
    }

    public func setWidth(_ id: DisplayID, _ width: Int) async {
        guard let size = profile(id), ScreenFit.widths(for: size).contains(width) else {
            Log.warn("手机屏 #\(id) 没有登记 \(width) 宽的档位")
            return
        }
        if self.width(id) == width {
            // 模式已正确、只是NSScreen还没刷新时，只等界面，不重复提交同一档位。
            if await !waitForWidth(id, width) { Log.warn("手机屏 #\(id) 模式已为 \(width) 宽，界面仍未认到尺寸") }
            return
        }
        // 缺模式元数据先只读等待，不能靠重复配置事务试探WindowServer是否准备好。
        guard await waitForReadableMode(id) else {
            Log.warn("手机屏 #\(id) 模式元数据暂不可读，未提交换档")
            return
        }
        guard !Task.isCancelled, profile(id) == size else { return }
        let from = DisplayMode.describe(id)
        let status = await runHelper(id, width: width, size: size)
        guard status == 0 else {
            Log.warn("手机屏 #\(id) 换不到 \(width) 宽（帮手退出码 \(status.map(String.init) ?? "启动失败")），现在 \(DisplayMode.describe(id))")
            return
        }
        if await waitForWidth(id, width) {
            Log.info("手机屏 #\(id) 换到 \(width) 宽（原来 \(from)）")
        } else {
            Log.warn("手机屏 #\(id) 换档返回后实际界面未匹配 \(width) 宽，现在 \(DisplayMode.describe(id))")
        }
    }

    public func bounds(_ id: DisplayID) -> CGRect? {
        guard displays[id] != nil else { return nil }
        let rect = CGDisplayBounds(id)
        return rect.isEmpty ? nil : rect
    }

    public func windowArea(_ id: DisplayID) -> CGRect? {
        guard let size = profile(id), let screen = Screens.screen(for: id) else { return nil }
        var area = Screens.axRect(fromAppKit: screen.visibleFrame)
        area.size.height -= ScreenFit.homeBarHeight(screenWidth: screen.frame.width, for: size)
        return area
    }

    public func mainArea() -> CGRect? {
        Screens.primary.map { Screens.axRect(fromAppKit: $0.visibleFrame) }
    }

    // MARK: 内部

    /// 对象只由字典持有，create的等待作用域不会留下阻止retire释放的强引用。
    private func make(serial: UInt32, size: PhoneScreenSize) -> (id: DisplayID, applied: Bool)? {
        let descriptor = CGVirtualDisplayDescriptor()
        let maximum = ScreenFit.maxPixels(for: size)
        let millimeters = PhoneScreenSpec.millimeters(for: size)
        descriptor.name = PhoneScreenSpec.name
        descriptor.maxPixelsWide = UInt32(maximum.width)
        descriptor.maxPixelsHigh = UInt32(maximum.height)
        descriptor.sizeInMillimeters = CGSize(width: millimeters.width, height: millimeters.height)
        descriptor.vendorID = PhoneScreenSpec.vendorID
        descriptor.productID = PhoneScreenSpec.productID
        descriptor.serialNum = serial
        guard let display = autoreleasepool(invoking: { CGVirtualDisplay(descriptor: descriptor) }) else { return nil }
        let id = display.displayID
        displays[id] = OwnedDisplay(object: display, size: size, bornAt: ProcessInfo.processInfo.systemUptime)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = false
        settings.modes = ScreenFit.widths(for: size).map { width in
            let frame = ScreenFit.size(width: width, for: size)
            return CGVirtualDisplayMode(width: UInt(frame.width), height: UInt(frame.height), refreshRate: 60)
        }
        let applied = autoreleasepool { display.apply(settings) }
        if !applied { Log.warn("手机屏（serial=\(serial)）apply 失败，稳定后撤回") }
        return (id, applied)
    }

    private func matchesScreen(_ id: DisplayID, _ width: Int) -> Bool {
        guard let size = profile(id), self.width(id) == width, let screen = Screens.screen(for: id) else { return false }
        return screen.frame.size == ScreenFit.size(width: width, for: size)
    }

    private func waitForReadableMode(_ id: DisplayID) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + Self.onlineTimeout
        repeat {
            if CGDisplayCopyDisplayMode(id)?.isUsableForDesktopGUI() == true { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .seconds(0.1))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func waitForWidth(_ id: DisplayID, _ width: Int) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + Self.screenUpdateTimeout
        repeat {
            if matchesScreen(id, width) { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .seconds(0.05))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func wait(_ id: DisplayID, online: Bool, timeout: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while Self.isOnline(id) != online {
            if ProcessInfo.processInfo.systemUptime >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(for: .seconds(0.25))
        }
        return true
    }

    /// 最小存活和释放后的稳定等待不因任务取消而缩短。
    private func settle(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }

    private static func isOnline(_ id: DisplayID) -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains(id)
    }

    private func runHelper(_ id: DisplayID, width: Int, size: PhoneScreenSize) async -> Int32? {
        let process = Process()
        process.executableURL = helper
        let height = Int(ScreenFit.size(width: width, for: size).height)
        process.arguments = ["--set-mode", "\(id)", "\(width)", "\(height)"]
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                Log.error("帮手进程起不来（\(helper.path)）：\(error)")
                continuation.resume(returning: nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.helperTimeout) {
                guard process.isRunning else { return }
                Log.error("帮手进程 \(Int(Self.helperTimeout))s 没退出（屏 #\(id)），结束它")
                process.terminate()
            }
        }
    }
}

private enum PhoneDisplayFailure: Error, CustomStringConvertible {
    case applyFailed(PhoneScreenSize)
    case modeNotReady(PhoneScreenSize)

    var description: String {
        switch self {
        case .applyFailed(let size): "手机屏模式申请失败：\(size.label)"
        case .modeNotReady(let size): "手机屏基础尺寸未通过实际读回：\(size.label)"
        }
    }
}
