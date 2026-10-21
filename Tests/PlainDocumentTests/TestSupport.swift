import Foundation
import XCTest

/// A fresh temp folder per test, removed (and made writable again) at teardown.
class TempFolderTestCase: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PlainDocumentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }

    func write(_ text: String, as name: String = "note.md") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
}
