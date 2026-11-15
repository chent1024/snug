// 两个用户设备的基础画面像素；自适应档位沿用所选设备的比例。
import Foundation

public enum PhoneScreenSize: String, CaseIterable, Codable, Sendable {
    case redmi
    case iphone13

    public var title: String { self == .redmi ? "红米" : "iPhone 13" }
    public var width: Int { self == .redmi ? 488 : 585 }
    public var height: Int { self == .redmi ? 1084 : 1266 }
    public var label: String { "\(title) · \(width)×\(height)" }
}

public enum PhoneScreenSpec {
    /// 在「显示器」设置和 UU远程 的屏幕列表里看到的名字
    public static let name = "Snug 手机屏"
    /// 'SN'：认出自己建的屏
    public static let vendorID: UInt32 = 0x534E
    public static let productID: UInt32 = 0x00F0
    /// 建好不到这么久就释放会让 WindowServer 卡死（原作者实测）
    public static let minimumLifetime: TimeInterval = 2.5

    /// 物理尺寸按像素上限、约 220ppi 折算。按手机的真实密度（460ppi）算，全新身份的屏永远不上线，
    /// 而且这个身份从此被系统「拉黑」，改回来也不行
    public static func millimeters(for size: PhoneScreenSize) -> (width: Double, height: Double) {
        let pixels = ScreenFit.maxPixels(for: size)
        return (Double(pixels.width) / 220 * 25.4, Double(pixels.height) / 220 * 25.4)
    }

    /// 身份（序列号）：固定一个，建了不上线就依次换备用的。
    /// 固定身份能让系统记住这块屏的设置；每多用一个新身份，系统就多存一份 ICC 文件。
    /// 设备之间及以前的单档/2倍模式均不复用身份，避免系统记住不相容的模式表。
    public static func serials(for size: PhoneScreenSize) -> [UInt32] {
        switch size {
        case .redmi: [200_110_008, 200_110_018, 200_110_028]
        case .iphone13: [200_210_008, 200_210_018, 200_210_028]
        }
    }
}
