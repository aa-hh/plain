import XCTest
import PlainVendor

final class VendorFilesTests: XCTestCase {
    // Turns red if `scripts/fetch-vendor.sh` stops writing a file that `VendorFiles` points at.
    func testEveryVendorFileExists() throws {
        for url in VendorFiles.all {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
        let fonts = try FileManager.default.contentsOfDirectory(atPath: VendorFiles.katexFontsFolder.path)
        XCTAssertEqual(fonts.count, 60)
        XCTAssertTrue(FileManager.default.fileExists(atPath: VendorFiles.prismFolder.appendingPathComponent("prism-core.min.js").path))
    }
}
