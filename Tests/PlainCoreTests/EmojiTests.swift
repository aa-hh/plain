import XCTest
@testable import PlainCore

final class EmojiTests: XCTestCase {
    // Turns red if `EmojiTable` stops loading the vendored emoji.json or mapping shortcodes to characters.
    func testShortcode() {
        XCTAssertEqual(EmojiTable.shared.byShortcode["smile"], "😄")
        XCTAssertEqual(EmojiTable.shared.shortcode(for: "😄"), "smile")
        XCTAssertTrue(EmojiTable.shared.search(prefix: "smil").prefix(5).contains { $0.emoji == "😄" })
    }

    // Turns red if `recordRecent` stops moving the emoji to the front of the saved list.
    func testRecent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(folder: folder)
        try await EmojiTable.shared.recordRecent("😄", in: store)
        try await EmojiTable.shared.recordRecent("🎉", in: store)
        try await EmojiTable.shared.recordRecent("😄", in: store)
        let recent = await EmojiTable.shared.recent(in: store)
        XCTAssertEqual(recent, ["😄", "🎉"])
    }
}
