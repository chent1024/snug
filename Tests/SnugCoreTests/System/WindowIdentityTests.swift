import Foundation
import Darwin
import Testing
@testable import SnugCore
@testable import SnugSystem

@Suite("只读内核窗口身份")
struct WindowIdentityTests {
    @Test("当前测试进程身份可读取、JSON无损，旧启动身份不匹配")
    func ownProcessOnly() throws {
        let pid = getpid()
        let launch = try #require(WindowIdentity.launchTime(pid))
        let boot = try #require(WindowIdentity.bootSession)
        let key = WindowKey(pid: pid, id: 1, launchTime: launch, bootSession: boot)
        #expect(WindowIdentity.status(key) == .same)
        let roundtrip = try JSONDecoder().decode(WindowKey.self, from: JSONEncoder().encode(key))
        #expect(roundtrip == key)
        #expect(WindowIdentity.status(roundtrip) == .same)
        #expect(WindowIdentity.status(WindowKey(pid: pid, id: 1, launchTime: launch - 1, bootSession: boot)) == .changed)
        #expect(WindowIdentity.status(WindowKey(pid: pid, id: 1, launchTime: launch, bootSession: "other-boot")) == .changed)
        #expect(WindowIdentity.status(WindowKey(pid: pid, id: 1)) == .unavailable)
    }
}
