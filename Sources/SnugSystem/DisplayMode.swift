// 显示模式：读此刻是哪一档，以及帮手进程里真正去切。
// 主程序不亲自切模式：亲自切过模式的进程，这块虚拟屏释放后要拖 40 秒以上才下线（两次实测）；
// 交给短命的帮手进程（Snug --set-mode）切完就退出，释放照样 0.1 秒下线
import CoreGraphics
import SnugCore

public enum DisplayMode {
    public enum Outcome: Equatable, CustomStringConvertible {
        case switched
        /// 这块屏没有这一档的标准1倍模式
        case unavailable
        case failed(CGError)

        public var description: String {
            switch self {
            case .switched: "已切换"
            case .unavailable: "没有这一档的标准模式"
            case .failed(let err): "切换失败（CGError=\(err.rawValue)）"
            }
        }
    }

    /// 此刻标准1倍模式的宽度；像素与逻辑尺寸必须同时符合所选设备的已登记档位。
    public static func standardWidth(_ id: DisplayID, for profile: PhoneScreenSize) -> Int? {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.isUsableForDesktopGUI(),
              ScreenFit.widths(for: profile).contains(mode.width),
              mode.pixelWidth == mode.width, mode.pixelHeight == mode.height,
              mode.height == Int(ScreenFit.size(width: mode.width, for: profile).height) else { return nil }
        return mode.width
    }

    public static func describe(_ id: DisplayID) -> String {
        guard let m = CGDisplayCopyDisplayMode(id) else { return "无模式" }
        return "\(m.width)x\(m.height)pt/\(m.pixelWidth)x\(m.pixelHeight)px"
    }

    /// 帮手进程里调用：切到指定画面像素的标准1倍模式。只对本次登录生效。
    public static func switchToStandard(_ id: DisplayID, width: Int, height: Int) -> Outcome {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        guard let mode = modes.first(where: {
            $0.width == width && $0.height == height && $0.pixelWidth == width && $0.pixelHeight == height && $0.isUsableForDesktopGUI()
        }) else {
            return .unavailable
        }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success else { return .failed(begin) }
        let staged = CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        guard staged == .success else {
            CGCancelDisplayConfiguration(config)
            return .failed(staged)
        }
        let done = CGCompleteDisplayConfiguration(config, .forSession)
        if done != .success { CGCancelDisplayConfiguration(config) }
        return done == .success ? .switched : .failed(done)
    }
}
