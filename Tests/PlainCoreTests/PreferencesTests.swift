import XCTest
@testable import PlainCore

@MainActor
final class PreferencesTests: XCTestCase {
    // Turns red if `Preferences.set` stops clamping numbers to the key's min and max.
    func testClamping() {
        let preferences = Preferences()
        preferences.set("fontSize", .number(50))
        XCTAssertEqual(preferences.number("fontSize"), 30)
        preferences.set("lineHeight", .number(1))
        XCTAssertEqual(preferences.number("lineHeight"), 1.5)
    }

    // Turns red if the YAML body stops following `order`, includes silent keys, or changes number formatting.
    func testYAMLOrdering() {
        let body = Preferences().yamlBody()
        XCTAssertEqual(body.split(separator: "\n").map { String($0.split(separator: ":")[0]) },
                       ["font", "fontSize", "codeFont", "codeFontSize", "lineHeight", "lineWidth", "tabSize", "useLargeFontInHeadings"])
        XCTAssertTrue(body.contains("fontSize: 15"))
        XCTAssertTrue(body.contains("codeFont: \"Roboto Mono\""))
        XCTAssertFalse(body.contains("nightMode"))
        XCTAssertTrue(SettingsFiles.preferencesMarkdown(yamlBody: body).contains("```yaml\nfont: system-ui"))
    }
}
