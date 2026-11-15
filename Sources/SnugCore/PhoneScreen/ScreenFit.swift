// 屏幕适配沿用上游的按窗口最小尺寸选档：基础档到两倍宽，比例由当前设备决定。
// 所有档位都是标准1×画面像素，红米488与iPhone13的585不被隐式翻倍或取整成另一宽度。
import CoreGraphics

public enum ScreenFit {
    public static let step = 10
    static let baseHomeBarHeight: CGFloat = 28

    public static func baseWidth(for profile: PhoneScreenSize) -> Int { profile.width }
    public static func maxWidth(for profile: PhoneScreenSize) -> Int { profile.width * 2 }

    public static func widths(for profile: PhoneScreenSize) -> [Int] {
        let maximum = maxWidth(for: profile)
        var result = Array(stride(from: profile.width, through: maximum, by: step))
        // 488与585的两倍不都落在10点的步长上，最宽一档必须精确登记。
        if result.last != maximum { result.append(maximum) }
        return result
    }

    public static func size(width: Int, for profile: PhoneScreenSize) -> CGSize {
        CGSize(width: CGFloat(width), height: (CGFloat(width) * CGFloat(profile.height) / CGFloat(profile.width)).rounded())
    }

    public static func maxPixels(for profile: PhoneScreenSize) -> CGSize {
        size(width: maxWidth(for: profile), for: profile)
    }

    public static func scale(screenWidth: CGFloat, for profile: PhoneScreenSize) -> CGFloat {
        screenWidth / CGFloat(profile.width)
    }

    public static func homeBarHeight(screenWidth: CGFloat, for profile: PhoneScreenSize) -> CGFloat {
        (baseHomeBarHeight * scale(screenWidth: screenWidth, for: profile)).rounded()
    }

    /// 当前档装得下就保留；按超出比例选能容纳窗口的最窄档，最多扩到两倍基础宽。
    public static func width(toFit window: CGSize, in area: CGSize, at current: Int, for profile: PhoneScreenSize) -> Int {
        let tolerance: CGFloat = 2
        guard window.width > area.width + tolerance || window.height > area.height + tolerance else { return current }
        guard area.width > 0, area.height > 0 else { return current }
        let base = CGFloat(current)
        let needed = max(base * window.width / area.width, base * window.height / area.height)
        return widths(for: profile).first { CGFloat($0) >= needed.rounded(.up) } ?? maxWidth(for: profile)
    }
}
