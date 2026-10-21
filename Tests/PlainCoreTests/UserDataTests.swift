import XCTest
@testable import PlainCore

final class UserDataTests: XCTestCase {
    struct Bounds: Codable, Equatable { var x, y, width, height: Double }

    // Turns red if `StateStore.save` and `load` stop round-tripping a value through state/<name>.json.
    func testStateRoundTrip() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(folder: folder)
        let bounds = Bounds(x: 1, y: 2, width: 800, height: 600)
        try await store.save(StateName.windowBounds(3), bounds)
        let loaded = await store.load(StateName.windowBounds(3), as: Bounds.self)
        XCTAssertEqual(loaded, bounds)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("window-bounds-w3.json").path))
        let missing = await store.load("nothing", as: Bounds.self)
        XCTAssertNil(missing)
    }

    // Turns red if `OpenableFiles.fileKind` changes which extensions get the text or image icon.
    func testFileKind() {
        XCTAssertEqual(OpenableFiles.fileKind(for: URL(fileURLWithPath: "/tmp/none/a.md")), .text)
        XCTAssertEqual(OpenableFiles.fileKind(for: URL(fileURLWithPath: "/tmp/none/a.png")), .image)
        XCTAssertEqual(OpenableFiles.fileKind(for: URL(fileURLWithPath: "/tmp/none/a.zip")), .other)
        XCTAssertEqual(OpenableFiles.fileKind(for: URL(fileURLWithPath: "/tmp/none/dir/", isDirectory: true)), .folder)
        XCTAssertFalse(OpenableFiles.isOpenable(URL(fileURLWithPath: "/a.mdown")))
    }
}
