import CoreGraphics
import Testing
@testable import SnugCore

@Suite("按设备比例屏幕适配 ScreenFit")
struct ScreenFitTests {
    private func area(for profile: PhoneScreenSize, width: Int? = nil) -> CGSize {
        let width = width ?? profile.width
        var result = ScreenFit.size(width: width, for: profile)
        result.height -= 25 + ScreenFit.homeBarHeight(screenWidth: CGFloat(width), for: profile)
        return result
    }

    @Test("只有两组原画面像素，档位逐10点递增并包含精确最大值", arguments: PhoneScreenSize.allCases)
    func ladder(profile: PhoneScreenSize) {
        let widths = ScreenFit.widths(for: profile)
        #expect(widths.first == profile.width)
        #expect(widths.last == profile.width * 2)
        #expect(Set(widths).count == widths.count)
        #expect(zip(widths, widths.dropFirst()).allSatisfy { $1 > $0 && $1 - $0 <= 10 })
        #expect(widths.dropLast().enumerated().allSatisfy { $0.element == profile.width + $0.offset * 10 })
        #expect(ScreenFit.size(width: profile.width, for: profile) == CGSize(width: profile.width, height: profile.height))
        #expect(ScreenFit.maxPixels(for: profile) == CGSize(width: profile.width * 2, height: profile.height * 2))
        for width in widths {
            let size = ScreenFit.size(width: width, for: profile)
            #expect(abs(size.height - CGFloat(width) * CGFloat(profile.height) / CGFloat(profile.width)) <= 0.5)
        }
    }

    @Test("iPhone585不截成584，最宽1170不落在步长上也登记")
    func oddBaseAndLastStep() {
        #expect(ScreenFit.widths(for: .iphone13).prefix(2) == [585, 595])
        #expect(ScreenFit.widths(for: .iphone13).suffix(2) == [1165, 1170])
        #expect(ScreenFit.widths(for: .redmi).suffix(2) == [968, 976])
        #expect(ScreenFit.size(width: 585, for: .iphone13) == CGSize(width: 585, height: 1266))
    }

    @Test("装得下就不换，保留两点取整容差", arguments: PhoneScreenSize.allCases)
    func fits(profile: PhoneScreenSize) {
        let available = area(for: profile)
        #expect(ScreenFit.width(toFit: available, in: available, at: profile.width, for: profile) == profile.width)
        #expect(ScreenFit.width(toFit: CGSize(width: 400, height: 600), in: available, at: profile.width, for: profile) == profile.width)
        #expect(ScreenFit.width(toFit: CGSize(width: available.width + 2, height: available.height + 1), in: available, at: profile.width, for: profile) == profile.width)
    }

    @Test("选容纳宽度的最窄档，不用旧540基准")
    func wider() {
        let redmi = area(for: .redmi)
        let iphone = area(for: .iphone13)
        #expect(ScreenFit.width(toFit: CGSize(width: 740, height: redmi.height), in: redmi, at: 488, for: .redmi) == 748)
        #expect(ScreenFit.width(toFit: CGSize(width: 740, height: iphone.height), in: iphone, at: 585, for: .iphone13) == 745)
        #expect(ScreenFit.width(toFit: CGSize(width: 588, height: redmi.height), in: redmi, at: 488, for: .redmi) == 588)
        #expect(ScreenFit.width(toFit: CGSize(width: 785, height: iphone.height), in: iphone, at: 585, for: .iphone13) == 785)
    }

    @Test("高度超出也按相同比例找档", arguments: PhoneScreenSize.allCases)
    func taller(profile: PhoneScreenSize) {
        let available = area(for: profile)
        let result = ScreenFit.width(toFit: CGSize(width: available.width, height: available.height * 1.25),
                                     in: available, at: profile.width, for: profile)
        #expect(result == (profile == .redmi ? 618 : 735))
        #expect(result > profile.width)
    }

    @Test("宽高都超按较大比例，超过最大档则封顶", arguments: PhoneScreenSize.allCases)
    func capped(profile: PhoneScreenSize) {
        let available = area(for: profile)
        #expect(ScreenFit.width(toFit: CGSize(width: profile.width * 3, height: profile.height * 3),
                                in: available, at: profile.width, for: profile) == profile.width * 2)
        let maxArea = area(for: profile, width: profile.width * 2)
        #expect(ScreenFit.width(toFit: CGSize(width: maxArea.width + 100, height: maxArea.height),
                                in: maxArea, at: profile.width * 2, for: profile) == profile.width * 2)
    }

    @Test("更宽档继续扩展按当前档比例", arguments: PhoneScreenSize.allCases)
    func fromWiderStep(profile: PhoneScreenSize) {
        let widths = ScreenFit.widths(for: profile)
        let current = widths[10]
        let next = widths[20]
        let available = area(for: profile, width: current)
        #expect(ScreenFit.width(toFit: CGSize(width: CGFloat(next), height: available.height),
                                in: available, at: current, for: profile) == next)
    }

    @Test("面板与底栏随档位缩放，两设备各自基准为1", arguments: PhoneScreenSize.allCases)
    func scale(profile: PhoneScreenSize) {
        #expect(ScreenFit.scale(screenWidth: CGFloat(profile.width), for: profile) == 1)
        #expect(ScreenFit.scale(screenWidth: CGFloat(profile.width * 2), for: profile) == 2)
        #expect(ScreenFit.homeBarHeight(screenWidth: CGFloat(profile.width), for: profile) == 28)
        #expect(ScreenFit.homeBarHeight(screenWidth: CGFloat(profile.width * 2), for: profile) == 56)
    }

    @Test("可放区域暂为空时不除零或擅自换档", arguments: PhoneScreenSize.allCases)
    func unavailableArea(profile: PhoneScreenSize) {
        #expect(ScreenFit.width(toFit: CGSize(width: 700, height: 1000), in: .zero, at: profile.width, for: profile) == profile.width)
    }
}
