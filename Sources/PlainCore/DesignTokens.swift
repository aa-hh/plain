import AppKit

/// One spread-only ring of a popup shadow (0 offset, 0 blur).
public struct ShadowRing: Sendable {
    public var width: CGFloat
    public var color: NSColor
}

/// One colour set (light or dark) for the app chrome and editor.
public struct Palette: Sendable {
    public var material: NSColor
    public var materialSecondary: NSColor
    public var materialTransparent: NSColor
    public var materialLine: NSColor
    public var materialThumb: NSColor
    public var color: NSColor
    public var colorSecondary: NSColor
    public var colorTertiary: NSColor
    public var colorEm: NSColor
    public var colorBlue: NSColor
    public var colorRed: NSColor
    public var colorGold: NSColor
    public var selectionBlue: NSColor
    public var selectionNeutral: NSColor
    public var selectionYellow: NSColor
    public var selectionOrange: NSColor
    public var highlight: NSColor
    public var highlightInfo: NSColor
    public var highlightError: NSColor
    public var highlightInput: NSColor
    /// Native window colour before content paints.
    public var windowBackground: NSColor
    public var shadow: [ShadowRing]
    public var shadowSmall: [ShadowRing]
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// A light and a dark value for one colour role.
public struct ColorPair: Sendable {
    public var light: NSColor
    public var dark: NSColor

    public init(_ light: NSColor, _ dark: NSColor) {
        self.light = light
        self.dark = dark
    }

    /// A colour that resolves to `light` or `dark` by the drawing appearance.
    public var dynamic: NSColor {
        let light = light, dark = dark
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

/// Typography and colour values for one preview theme, as CSS values.
public struct PreviewThemeTokens: Sendable {
    public var name: String
    public var background: String
    public var bodyFont: String
    public var bodySize: String
    public var bodyLineHeight: String
    public var bodyColor: String
    public var contentMaxWidth: String
    public var paddingVertical: String
    public var paddingSides: String
    public var paragraphMargin: String
    public var headingFont: String
    public var headingWeight: String
    /// h1 to h6 font sizes.
    public var headingSizes: [String]
    /// h1 to h6 margins (CSS `margin` shorthand); empty means inherit the paragraph margin.
    public var headingMargins: [String]
    public var linkColor: String
    public var inlineCodeFont: String
    public var inlineCodeSize: String
    public var inlineCodeColor: String
    public var inlineCodeBackground: String
    public var inlineCodeRadius: String
    public var inlineCodePadding: String
    public var inlineCodeMargin: String
    public var codeBlockBackground: String
    public var codeBlockRadius: String
    public var codeBlockPadding: String
    public var codeBlockMargin: String
    public var codeBlockFont: String
    public var codeBlockSize: String
    public var codeBlockLineHeight: String
    public var codeBlockColor: String
    /// Prism token name to CSS colour.
    public var codeTokens: [String: String]
    public var quoteBorder: String
    public var quotePadding: String
    public var quoteColor: String
    public var quoteMargin: String
    public var listPadding: String
    public var tableRuleColor: String
    public var tableCellPadding: String
    public var rule: String
    public var ruleMargin: String
    public var mathBlockSize: String
    public var mathBlockAlign: String
    public var mathBlockPadding: String
    public var mathBlockMargin: String
    public var selection: String?
    public var printFontSize: String
}

public enum Tokens {
    public static let light = Palette(
        material: rgb(0xFAFAFA),
        materialSecondary: rgb(0xF0F0F0),
        materialTransparent: rgba(250, 250, 250, 0.95),
        materialLine: rgba(0, 0, 0, 0.1),
        materialThumb: rgba(82, 82, 82, 0.8),
        color: rgb(0x4C4C4C),
        colorSecondary: rgb(0x7F7F7F),
        colorTertiary: rgb(0xB3B3B3),
        colorEm: rgb(0x4C4C4C),
        colorBlue: rgb(0x8599AE),
        colorRed: rgb(0xD98C8C),
        colorGold: rgb(0xC18B8B),
        selectionBlue: rgba(71, 153, 235, 0.25),
        selectionNeutral: rgba(204, 204, 204, 0.25),
        selectionYellow: rgb(0xFEEBB5),
        selectionOrange: rgb(0xFEC7B5),
        highlight: rgba(0, 0, 0, 0.04),
        highlightInfo: rgba(140, 217, 179, 0.5),
        highlightError: rgba(255, 77, 77, 0.5),
        highlightInput: rgba(0, 0, 0, 0.08),
        windowBackground: rgb(0xF9F9F9),
        shadow: [ShadowRing(width: 1, color: rgba(0, 0, 0, 0.1)), ShadowRing(width: 7, color: rgba(0, 0, 0, 0.025))],
        shadowSmall: [ShadowRing(width: 1, color: rgba(0, 0, 0, 0.1)), ShadowRing(width: 5, color: rgba(0, 0, 0, 0.025))]
    )

    public static let dark = Palette(
        material: rgb(0x282828),
        materialSecondary: rgb(0x232323),
        materialTransparent: rgba(40, 40, 40, 0.97),
        materialLine: rgb(0x4D4D4D),
        materialThumb: rgba(153, 153, 153, 0.9),
        color: rgb(0xBFBFBF),
        colorSecondary: rgb(0x999999),
        colorTertiary: rgb(0x666666),
        colorEm: rgb(0xCCCCCC),
        colorBlue: rgb(0x8799AC),
        colorRed: rgba(232, 125, 125, 0.7),
        colorGold: rgb(0xA8998A),
        selectionBlue: rgba(95, 127, 159, 0.25),
        selectionNeutral: rgba(70, 70, 70, 0.25),
        selectionYellow: rgb(0x8A7E5C),
        selectionOrange: rgb(0x8F6456),
        highlight: rgba(255, 255, 255, 0.04),
        highlightInfo: rgba(61, 92, 92, 0.8),
        highlightError: rgb(0x995555),
        highlightInput: rgba(255, 255, 255, 0.1),
        windowBackground: rgb(0x1D1D1D),
        shadow: [ShadowRing(width: 1, color: rgb(0x4D4D4D)), ShadowRing(width: 7, color: rgba(40, 40, 40, 0.5))],
        shadowSmall: [ShadowRing(width: 1, color: rgb(0x4D4D4D)), ShadowRing(width: 5, color: rgba(40, 40, 40, 0.5))]
    )

    public static func palette(dark isDark: Bool) -> Palette { isDark ? dark : light }

    // Colours that follow the drawing appearance.
    public static let material = ColorPair(light.material, dark.material).dynamic
    public static let materialSecondary = ColorPair(light.materialSecondary, dark.materialSecondary).dynamic
    public static let materialTransparent = ColorPair(light.materialTransparent, dark.materialTransparent).dynamic
    public static let materialLine = ColorPair(light.materialLine, dark.materialLine).dynamic
    public static let materialThumb = ColorPair(light.materialThumb, dark.materialThumb).dynamic
    public static let color = ColorPair(light.color, dark.color).dynamic
    public static let colorSecondary = ColorPair(light.colorSecondary, dark.colorSecondary).dynamic
    public static let colorTertiary = ColorPair(light.colorTertiary, dark.colorTertiary).dynamic
    public static let colorEm = ColorPair(light.colorEm, dark.colorEm).dynamic
    public static let colorBlue = ColorPair(light.colorBlue, dark.colorBlue).dynamic
    public static let colorRed = ColorPair(light.colorRed, dark.colorRed).dynamic
    public static let colorGold = ColorPair(light.colorGold, dark.colorGold).dynamic
    public static let selectionBlue = ColorPair(light.selectionBlue, dark.selectionBlue).dynamic
    public static let selectionNeutral = ColorPair(light.selectionNeutral, dark.selectionNeutral).dynamic
    public static let selectionYellow = ColorPair(light.selectionYellow, dark.selectionYellow).dynamic
    public static let selectionOrange = ColorPair(light.selectionOrange, dark.selectionOrange).dynamic
    public static let highlight = ColorPair(light.highlight, dark.highlight).dynamic
    public static let highlightInfo = ColorPair(light.highlightInfo, dark.highlightInfo).dynamic
    public static let highlightError = ColorPair(light.highlightError, dark.highlightError).dynamic
    public static let highlightInput = ColorPair(light.highlightInput, dark.highlightInput).dynamic
    public static let windowBackground = ColorPair(light.windowBackground, dark.windowBackground).dynamic

    // Metrics in points.
    public static let tabStripHeight: CGFloat = 48
    public static let editorTopPadding: CGFloat = 48
    public static let editorBottomPadding: CGFloat = 96
    public static let editorSidePadding: CGFloat = 80
    public static let sidebarWidth: CGFloat = 200
    public static let rowPadding: CGFloat = 20
    public static let levelIndent: CGFloat = 16
    public static let popupWidth: CGFloat = 360
    public static let cornerRadius: CGFloat = 6
    public static let smallRadius: CGFloat = 3
    public static let line: CGFloat = 24

    // Font sizes and line heights in points.
    public static let uiFontSize: CGFloat = 13
    public static let uiLineHeight: CGFloat = 24
    public static let popupFilterFontSize: CGFloat = 26
    public static let popupFilterLineHeight: CGFloat = 72
    public static let emptyGlyphFontSize: CGFloat = 52
    public static let menuRowFontSize: CGFloat = 14
    public static let menuRowLineHeight: CGFloat = 26

    public static var uiFont: NSFont { .systemFont(ofSize: uiFontSize) }
    public static var popupFilterFont: NSFont { .systemFont(ofSize: popupFilterFontSize, weight: .light) }
    public static var emptyGlyphFont: NSFont { .systemFont(ofSize: emptyGlyphFontSize) }
    public static var menuRowFont: NSFont { .systemFont(ofSize: menuRowFontSize) }
    /// Margin heading labels (`h1`…`h6`): system monospaced at code size minus 2.
    public static func headingLabelFont(codeFontSize: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: codeFontSize - 2, weight: .regular)
    }

    /// Editor code token colours by Prism token name. Tokens not listed use `colorSecondary`.
    public static let prismTokenColours: [String: ColorPair] = [
        "keyword": ColorPair(rgb(0x997799), rgb(0x997799)),
        "function": ColorPair(rgb(0x997799), rgb(0x997799)),
        "tag": ColorPair(rgb(0x997799), rgb(0x997799)),
        "string": ColorPair(rgb(0xCC8888), rgb(0xAA7777)),
        "number": ColorPair(rgb(0x6688AA), rgb(0x6688AA)),
        "boolean": ColorPair(rgb(0x669999), rgb(0x669999)),
        "property": ColorPair(rgb(0xCC8888), rgb(0xAA7777)),
        "variable": ColorPair(rgb(0x668888), rgb(0x668888)),
        "attr-name": ColorPair(light.colorGold, dark.colorGold),
        "attr-value": ColorPair(rgb(0x6688AA), rgb(0xAA7777)),
        "comment": ColorPair(light.colorTertiary, dark.colorTertiary),
        "punctuation": ColorPair(light.colorTertiary, dark.colorTertiary),
        "shell-comment": ColorPair(light.colorTertiary, dark.colorTertiary),
        "operator": ColorPair(light.colorSecondary, dark.colorSecondary),
        "interpolation": ColorPair(light.colorSecondary, dark.colorSecondary),
        "key": ColorPair(light.colorSecondary, dark.colorSecondary),
    ]

    /// Preview code token colours shared by the Default and GitHub themes.
    public static let previewCodeTokenColours: [String: String] = [
        "keyword": "#AA77AA", "tag": "#AA77AA",
        "function": "#6688AA", "attr-value": "#6688AA",
        "string": "#66AA88", "number": "#66AA88", "boolean": "#66AA88", "regex": "#66AA88",
        "comment": "#AAAAAA",
        "punctuation": "#888888", "operator": "#888888",
        "selector": "#998877", "attr-name": "#998877", "url": "#998877",
        "variable": "#AA6666", "property": "#AA6666", "key": "#AA6666",
    ]

    /// Preview code token colours for the Dark theme.
    public static let previewDarkCodeTokenColours: [String: String] = previewCodeTokenColours.merging(
        ["comment": "#777777", "punctuation": "#999999", "operator": "#999999"]) { $1 }

    public static let previewDefault = PreviewThemeTokens(
        name: "Default",
        background: "#FFFFFF",
        bodyFont: "system-ui, sans-serif",
        bodySize: "16px",
        bodyLineHeight: "28.8px",
        bodyColor: "#333333",
        contentMaxWidth: "626px",
        paddingVertical: "100.8px",
        paddingSides: "80px",
        paragraphMargin: "16px 0 28.8px",
        headingFont: "system-ui, sans-serif",
        headingWeight: "bold",
        headingSizes: ["32px", "24px", "16px", "16px", "16px", "16px"],
        headingMargins: ["86.4px 0 57.6px", "64.8px 0 43.2px", "43.2px 0 28.8px", "", "", ""],
        linkColor: "#7799BB",
        inlineCodeFont: "\"Roboto Mono\", monospace",
        inlineCodeSize: "13.6px",
        inlineCodeColor: "#444444",
        inlineCodeBackground: "#F3F3F3",
        inlineCodeRadius: "2px",
        inlineCodePadding: "1.36px 6.8px",
        inlineCodeMargin: "0 2.72px",
        codeBlockBackground: "#F3F3F3",
        codeBlockRadius: "0",
        codeBlockPadding: "14.4px 15.6px",
        codeBlockMargin: "16px 0 28.8px",
        codeBlockFont: "\"Roboto Mono\", monospace",
        codeBlockSize: "13.6px",
        codeBlockLineHeight: "28.8px",
        codeBlockColor: "#444444",
        codeTokens: previewCodeTokenColours,
        quoteBorder: "2.6px solid #DDDDDD",
        quotePadding: "0 0 0 13px",
        quoteColor: "#999999",
        quoteMargin: "16px 40px 16px 0",
        listPadding: "31.2px",
        tableRuleColor: "#DDDDDD",
        tableCellPadding: "7.2px 7.8px",
        rule: "2.6px solid #DDDDDD",
        ruleMargin: "8px 0 28.8px",
        mathBlockSize: "19.2px",
        mathBlockAlign: "left",
        mathBlockPadding: "11.52px 0",
        mathBlockMargin: "19.2px 0 28px",
        selection: nil,
        printFontSize: "14px"
    )

    public static let previewGitHub = PreviewThemeTokens(
        name: "GitHub",
        background: "#FFFFFF",
        bodyFont: "\"Helvetica Neue\", Helvetica, \"Segoe UI\", Arial, freesans, sans-serif, \"Apple Color Emoji\", \"Segoe UI Emoji\", \"Segoe UI Symbol\"",
        bodySize: "16px",
        bodyLineHeight: "25.6px",
        bodyColor: "#333333",
        contentMaxWidth: "890px",
        paddingVertical: "84px",
        paddingSides: "80px",
        paragraphMargin: "0 0 16px",
        headingFont: "\"Helvetica Neue\", Helvetica, \"Segoe UI\", Arial, freesans, sans-serif",
        headingWeight: "bold",
        headingSizes: ["36px", "28px", "24px", "20px", "16px", "16px"],
        headingMargins: ["36px 0 16px", "28px 0 16px", "24px 0 16px", "20px 0 16px", "16px 0 16px", ""],
        linkColor: "#4078C0",
        inlineCodeFont: "Consolas, \"Liberation Mono\", Menlo, Courier, monospace",
        inlineCodeSize: "13.6px",
        inlineCodeColor: "#333333",
        inlineCodeBackground: "rgba(0,0,0,0.04)",
        inlineCodeRadius: "3px",
        inlineCodePadding: "2.72px 0",
        inlineCodeMargin: "0",
        codeBlockBackground: "#F7F7F7",
        codeBlockRadius: "3px",
        codeBlockPadding: "16px",
        codeBlockMargin: "0 0 16px",
        codeBlockFont: "Consolas, \"Liberation Mono\", Menlo, Courier, monospace",
        codeBlockSize: "13.6px",
        codeBlockLineHeight: "19.72px",
        codeBlockColor: "#333333",
        codeTokens: previewCodeTokenColours,
        quoteBorder: "4px solid #DDDDDD",
        quotePadding: "0 15px",
        quoteColor: "#777777",
        quoteMargin: "0 0 16px",
        listPadding: "32px",
        tableRuleColor: "#DDDDDD",
        tableCellPadding: "6px 13px",
        rule: "4px solid #E7E7E7",
        ruleMargin: "16px 0",
        mathBlockSize: "19.2px",
        mathBlockAlign: "center",
        mathBlockPadding: "7.8px 0",
        mathBlockMargin: "16px 0",
        selection: nil,
        printFontSize: "14px"
    )

    public static let previewDark = PreviewThemeTokens(
        name: "Dark",
        background: "rgb(20,20,20)",
        bodyFont: "system-ui, sans-serif",
        bodySize: "15px",
        bodyLineHeight: "24.7px",
        bodyColor: "#AAAAAA",
        contentMaxWidth: "626px",
        paddingVertical: "86.45px",
        paddingSides: "80px",
        paragraphMargin: "15px 0 24.7px",
        headingFont: "system-ui, sans-serif",
        headingWeight: "normal",
        headingSizes: ["26px", "22.1px", "18.2px", "18.2px", "18.2px", "18.2px"],
        headingMargins: ["37.05px 0 24.7px", "37.05px 0 24.7px", "", "", "", ""],
        linkColor: "#88AACC",
        inlineCodeFont: "\"Roboto Mono\", monospace",
        inlineCodeSize: "12.35px",
        inlineCodeColor: "#AAAAAA",
        inlineCodeBackground: "#292929",
        inlineCodeRadius: "2px",
        inlineCodePadding: "1.3px 6.5px",
        inlineCodeMargin: "0 2.6px",
        codeBlockBackground: "#292929",
        codeBlockRadius: "0",
        codeBlockPadding: "12.35px 15.6px",
        codeBlockMargin: "15px 0 24.7px",
        codeBlockFont: "\"Roboto Mono\", monospace",
        codeBlockSize: "12.35px",
        codeBlockLineHeight: "24.7px",
        codeBlockColor: "#AAAAAA",
        codeTokens: previewDarkCodeTokenColours,
        quoteBorder: "2.6px solid #333333",
        quotePadding: "0 0 0 13px",
        quoteColor: "#777777",
        quoteMargin: "15px 40px 15px 0",
        listPadding: "31.2px",
        tableRuleColor: "#333333",
        tableCellPadding: "6.175px 7.8px",
        rule: "2.6px solid #333333",
        ruleMargin: "7.5px 0 24.7px",
        mathBlockSize: "26px",
        mathBlockAlign: "left",
        mathBlockPadding: "7.8px 0",
        mathBlockMargin: "26px 0 28px",
        selection: "rgba(255,255,255,0.1)",
        printFontSize: "14px"
    )

    public static let previewThemes: [PreviewThemeTokens] = [previewDefault, previewGitHub, previewDark]
}
