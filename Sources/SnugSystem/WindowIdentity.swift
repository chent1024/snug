import Foundation
import Darwin
import CoreGraphics
import SnugCore

enum WindowIdentity {
    static var bootSession: String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    static func launchTime(_ pid: Int32) -> Double? {
        var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }

    static func key(pid: Int32, id: UInt32) -> WindowKey {
        WindowKey(pid: pid, id: id, launchTime: launchTime(pid), bootSession: bootSession)
    }

    enum Match { case same, changed, unavailable }
    static func status(_ key: WindowKey) -> Match {
        guard let originalBoot = key.bootSession, let originalLaunch = key.launchTime else { return .unavailable }
        guard let boot = bootSession else { return .unavailable }
        guard boot == originalBoot else { return .changed }
        if let live = launchTime(key.pid) { return live == originalLaunch ? .same : .changed }
        if kill(key.pid, 0) != 0, errno == ESRCH { return .changed }
        return .unavailable
    }
    static func matches(_ key: WindowKey) -> Bool { status(key) == .same }

    static var screenLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (d["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true
    }
}
