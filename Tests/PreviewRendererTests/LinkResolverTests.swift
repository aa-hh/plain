import XCTest
@testable import PreviewRenderer

final class LinkResolverTests: XCTestCase {
    let resolver = LinkResolver(projectRoot: URL(fileURLWithPath: "/proj"), currentFile: URL(fileURLWithPath: "/proj/docs/note.md"),
                                homeFolder: URL(fileURLWithPath: "/Users/me"))

    // Turns red if a leading `file://` is no longer stripped.
    func testStripsFileScheme() {
        XCTAssertEqual(resolver.resolve("file:///tmp/a.png"), "/proj/tmp/a.png")
    }

    // Turns red if full URLs or `#anchors` get rewritten.
    func testLeavesURLsAndAnchors() {
        XCTAssertEqual(resolver.resolve("https://example.com/a%20b"), "https://example.com/a%20b")
        XCTAssertEqual(resolver.resolve("mailto:a@b.c"), "mailto:a@b.c")
        XCTAssertEqual(resolver.resolve("#top"), "#top")
    }

    // Turns red if paths are no longer URL-decoded.
    func testDecodesPaths() {
        XCTAssertEqual(resolver.resolve("my%20pic.png"), "/proj/docs/my pic.png")
    }

    // Turns red if `~/` stops meaning the home folder.
    func testHomeFolder() {
        XCTAssertEqual(resolver.resolve("~/Pictures/a.png"), "/Users/me/Pictures/a.png")
    }

    // Turns red if a path starting with `/` is no longer joined to the project root, or is joined without one.
    func testRootedPaths() {
        XCTAssertEqual(resolver.resolve("/img/a.png"), "/proj/img/a.png")
        XCTAssertEqual(LinkResolver(projectRoot: nil, currentFile: nil).resolve("/img/a.png"), "/img/a.png")
    }

    // Turns red if relative paths stop joining the open file's folder or overlapping segments are repeated.
    func testRelativePaths() {
        XCTAssertEqual(resolver.resolve("a.png"), "/proj/docs/a.png")
        XCTAssertEqual(resolver.resolve("docs/a.png"), "/proj/docs/a.png")
        XCTAssertEqual(resolver.resolve("../b.png"), "/proj/docs/../b.png")
    }

    // Turns red if a path is changed when there is neither a project root nor an open file.
    func testNoRootNoFile() {
        XCTAssertEqual(LinkResolver(projectRoot: nil, currentFile: nil).resolve("a%20b.png"), "a b.png")
    }
}
