import Foundation

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let windows: [WorkspaceWindow]

    public init(windows: [WorkspaceWindow]) {
        version = 1; self.windows = windows
    }

    public var eligible: Set<WindowKey> {
        Set(windows.filter { $0.visible && !$0.state.minimized && !$0.state.fullScreen }.map(\.id))
    }

    private enum CodingKeys: String, CodingKey { case version, windows }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        windows = try c.decode([WorkspaceWindow].self, forKey: .windows)
        guard version == 1, Set(windows.map(\.id)).count == windows.count,
              windows.allSatisfy({ w in
                  let f = w.state.frame
                  return w.id.pid > 0 && w.id.id > 0 && w.id.launchTime?.isFinite == true &&
                    w.id.bootSession?.isEmpty == false && f.minX.isFinite && f.minY.isFinite &&
                    f.width.isFinite && f.height.isFinite && abs(f.minX) <= Double(Int32.max) &&
                    abs(f.minY) <= Double(Int32.max) && f.width > 0 && f.height > 0 &&
                    f.width <= 65536 && f.height <= 65536
              }) else { throw DecodingError.dataCorruptedError(forKey: .windows, in: c, debugDescription: "invalid workspace baseline") }
    }
}

public enum WorkspaceOutcome: Equatable, Sendable {
    case complete(verified: Int, skipped: Int)
    case deferred
    case failed([UInt32])
}
