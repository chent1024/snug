import Foundation
import Testing
@testable import SnugCore

@Suite("应用字号快捷键规则")
struct ZoomShortcutTests {
    @Test("当前 OpenAI 客户端放大用 ⌘⇧=，缩小用 ⌘-；默认4级不再被跳过")
    func openAIClient() {
        let bundle = "com.openai.codex"
        #expect(ZoomBook.isZoomable(bundle))
        #expect(ZoomBook.shortcut(for: bundle, increasing: true) == .commandShiftEqual)
        #expect(ZoomBook.shortcut(for: bundle, increasing: false) == .commandMinus)
        #expect(ZoomBook().steps(for: bundle, default: 4) == 4)
    }

    @Test("原终端与编辑器快捷键保持 ⌘= / ⌘-", arguments: [
        "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
    ])
    func existingApps(bundle: String) {
        #expect(ZoomBook.shortcut(for: bundle, increasing: true) == .commandEqual)
        #expect(ZoomBook.shortcut(for: bundle, increasing: false) == .commandMinus)
    }

    @Test("未知与未验证标识不发送任何缩放快捷键", arguments: [
        "com.apple.finder", "com.apple.Safari", "com.google.Chrome", "com.openai.chat", "",
    ])
    func unsupportedApps(bundle: String) {
        #expect(ZoomBook.shortcut(for: bundle, increasing: true) == nil)
        #expect(ZoomBook.shortcut(for: bundle, increasing: false) == nil)
        #expect(ZoomBook().steps(for: bundle, default: 4) == 0)
    }

    @Test("缺少标识不发快捷键；目标应用记忆、边界及编码读回仍正常")
    func rememberedSteps() throws {
        #expect(ZoomBook.shortcut(for: nil, increasing: true) == nil)
        #expect(ZoomBook.shortcut(for: nil, increasing: false) == nil)
        var book = ZoomBook()
        book.remember(20, for: "com.openai.codex")
        #expect(book.steps(for: "com.openai.codex", default: 4) == 8)
        book.remember(-20, for: "com.openai.codex")
        #expect(book.steps(for: "com.openai.codex", default: 4) == -4)
        let loaded = try JSONDecoder().decode(ZoomBook.self, from: JSONEncoder().encode(book))
        #expect(loaded == book)
        book.forgetAll()
        #expect(book.steps(for: "com.openai.codex", default: 4) == 4)
    }
}
