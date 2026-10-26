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
    /// h1 to h6 font weights; empty means inherit `headingWeight`.
    public var headingWeights: [String]
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
    /// CSS `border` shorthand on the code block wrapper. "none" where the theme draws no border.
    public var codeBlockBorder: String
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

/// The page's colours and sizes (the editor while View > Show Markdown Source is off), from the `page-*` variables of
/// the design library.
public struct PageTokens: Sendable {
    public let backgroundPair = ColorPair(rgb(0xFFFFFF), rgb(0x1C1C1C))
    public let textPair = ColorPair(rgb(0x2D2C29), rgb(0xE6E6E4))
    public let textSecondaryPair = ColorPair(rgb(0x75746F), rgb(0x9B9A97))
    public let textTertiaryPair = ColorPair(rgb(0xA8A7A3), rgb(0x6B6A67))
    public let borderPair = ColorPair(rgb(0xE6E6E3), rgb(0xFFFFFF, CGFloat(0x1A) / 255))
    public let codeBackgroundPair = ColorPair(rgb(0xF6F5F2), rgb(0xFFFFFF, CGFloat(0x0F) / 255))
    public let hoverPair = ColorPair(rgb(0x2D2C29, CGFloat(0x0D) / 255), rgb(0xFFFFFF, CGFloat(0x0D) / 255))
    public let menuBackgroundPair = ColorPair(rgb(0xFFFFFF), rgb(0x252525))
    public let accentPair = ColorPair(rgb(0x2F80ED), rgb(0x4A90E2))
    public let selectionPair = ColorPair(rgb(0x2F80ED, CGFloat(0x33) / 255), rgb(0x4A90E2, CGFloat(0x4D) / 255))
    public let shadowPair = ColorPair(rgb(0x0F0F0F, CGFloat(0x1F) / 255), rgb(0x000000, CGFloat(0x5C) / 255))

    // The same colours, following the drawing appearance.
    public let background: NSColor
    public let text: NSColor
    public let textSecondary: NSColor
    public let textTertiary: NSColor
    public let border: NSColor
    public let codeBackground: NSColor
    public let hover: NSColor
    public let menuBackground: NSColor
    public let accent: NSColor
    public let selection: NSColor
    public let shadow: NSColor

    init() {
        background = backgroundPair.dynamic
        text = textPair.dynamic
        textSecondary = textSecondaryPair.dynamic
        textTertiary = textTertiaryPair.dynamic
        border = borderPair.dynamic
        codeBackground = codeBackgroundPair.dynamic
        hover = hoverPair.dynamic
        menuBackground = menuBackgroundPair.dynamic
        accent = accentPair.dynamic
        selection = selectionPair.dynamic
        shadow = shadowPair.dynamic
    }

    // Text sizes and line heights.
    public let bodySize: CGFloat = 16
    /// Line height as a multiple of the body size.
    public let bodyLine: CGFloat = 1.5
    /// h1 to h6.
    public let headingSizes: [CGFloat] = [30, 24, 20, 16, 16, 16]
    public let headingSpaceAbove: [CGFloat] = [24, 24, 16, 16, 16, 16]
    public let headingSpaceBelow: CGFloat = 4
    public let codeSize: CGFloat = 14
    public let codeLine: CGFloat = 1.6
    public let smallTextSize: CGFloat = 14
    public let footnoteSize: CGFloat = 11
    public let footnoteRaise: CGFloat = 6
    public let footnoteNumberWidth: CGFloat = 20

    // Page layout.
    public let radius: CGFloat = 6
    public let blockGap: CGFloat = 2
    public let topPadding: CGFloat = 96
    public let markerBox: CGFloat = 24
    public let markerGap: CGFloat = 4
    public let levelIndent: CGFloat = 24
    public let checkbox: CGFloat = 16
    public let checkboxRadius: CGFloat = 3
    public let checkboxStroke: CGFloat = 1.5
    public let quoteBar: CGFloat = 3
    public let quoteIndent: CGFloat = 17
    public let dividerSpace: CGFloat = 12
    public let codePadSides: CGFloat = 32
    public let codePadTop: CGFloat = 24
    public let codePadBottom: CGFloat = 24
    public let codeHeaderSize: CGFloat = 12
    public let codeHeaderGap: CGFloat = 12
    public let cellPadV: CGFloat = 8
    public let cellPadH: CGFloat = 10
    public let cellTextSize: CGFloat = 14
    public let chipRadius: CGFloat = 4
    public let chipPadH: CGFloat = 4
    public let chipPadV: CGFloat = 2
    public let imageRadius: CGFloat = 4
    public let captionGap: CGFloat = 8
    public let captionSize: CGFloat = 14
    public let frontKeyWidth: CGFloat = 96
    public let frontRowPad: CGFloat = 2

    // Editing tools.
    public let handleBox: CGFloat = 24
    public let handleIcon: CGFloat = 18
    public let handleBoxRadius: CGFloat = 4
    public let menuWidth: CGFloat = 240
    public let menuRow: CGFloat = 32
    public let menuIcon: CGFloat = 16
    public let menuLabel: CGFloat = 14
    public let menuSmall: CGFloat = 12
    public let slashWidth: CGFloat = 320
    public let slashRow: CGFloat = 48
    public let slashTile: CGFloat = 40
    public let slashMaxRows: Int = 10
    public let toolbarHeight: CGFloat = 36
    public let toolbarButton: CGFloat = 28
    public let linkEditorWidth: CGFloat = 320
    public let languageListWidth: CGFloat = 220
    public let dropLine: CGFloat = 3
    public let cellOutline: CGFloat = 2
    public let addBar: CGFloat = 12

    /// Menu card shadow: offset y 4, blur 16, drawn in SwiftUI as `.shadow(color:radius: shadowRadius, x: 0, y: shadowY)`.
    public let shadowY: CGFloat = 4
    public let shadowBlur: CGFloat = 16
    public let shadowRadius: CGFloat = 8

    /// Code colours on the page by Prism token name: plain code text, punctuation, operators, interpolation and keys in
    /// `page-text`, comments in `page-text-tertiary`, every other token as in the source view.
    public var codeText: ColorPair { textPair }
    public var codeTokenColours: [String: ColorPair] {
        Tokens.prismTokenColours.merging([
            "punctuation": textPair, "operator": textPair, "interpolation": textPair, "key": textPair,
            "comment": textTertiaryPair, "shell-comment": textTertiaryPair,
        ]) { $1 }
    }
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

    public static let page = PageTokens()

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
    /// The sidebar's default width, and its range when dragged; below `sidebarCloseWidth` it closes
    /// (docs/navigation-spec.md, Width).
    public static let sidebarWidth: CGFloat = 200
    public static let sidebarMinWidth: CGFloat = 160
    public static let sidebarMaxWidth: CGFloat = 400
    public static let sidebarCloseWidth: CGFloat = 120
    /// Space above every sidebar section header but the first.
    public static let sidebarSectionGap: CGFloat = 12
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
        headingWeights: ["", "", "", "", "", ""],
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
        codeBlockBorder: "none",
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
        headingWeights: ["", "", "", "", "", ""],
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
        codeBlockBorder: "none",
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
        headingWeights: ["", "", "", "", "", ""],
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
        codeBlockBorder: "none",
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

    /// Preview theme for the Claude pair, measured against the Claude desktop app's assistant messages.
    /// Colours are Plain's own choices: the reference records the palette as unrecovered.
    public static let previewClaude = PreviewThemeTokens(
        name: "Claude",
        background: "#FFFFFF",
        bodyFont: "system-ui, sans-serif",
        bodySize: "15px",
        bodyLineHeight: "22.5px",
        bodyColor: "#1F1F1F",
        contentMaxWidth: "626px",
        paddingVertical: "100.8px",
        paddingSides: "80px",
        paragraphMargin: "22.5px 0",
        headingFont: "system-ui, sans-serif",
        headingWeight: "600",
        headingSizes: ["22px", "18px", "16px", "16px", "14px", "14px"],
        headingMargins: ["12px 0 -4px", "12px 0 -4px", "8px 0 -4px", "8px 0 -4px", "8px 0 -4px", "8px 0 -4px"],
        headingWeights: ["bold", "bold", "bold", "600", "bold", "600"],
        linkColor: "#0B5FCE",
        inlineCodeFont: "inherit",
        inlineCodeSize: "1em",
        inlineCodeColor: "inherit",
        inlineCodeBackground: "rgba(0,0,0,0.05)",
        inlineCodeRadius: "4px",
        inlineCodePadding: "1px 4px",
        inlineCodeMargin: "0",
        codeBlockBackground: "rgba(0,0,0,0.04)",
        codeBlockRadius: "8px",
        codeBlockPadding: "14px",
        codeBlockMargin: "22.5px 0",
        codeBlockFont: "\"Roboto Mono\", monospace",
        codeBlockSize: "14px",
        codeBlockLineHeight: "22.75px",
        codeBlockColor: "inherit",
        codeBlockBorder: "0.5px solid rgba(0,0,0,0.12)",
        codeTokens: previewCodeTokenColours,
        quoteBorder: "4px solid rgba(0,0,0,0.1)",
        quotePadding: "0 0 0 16px",
        quoteColor: "#6B6B6B",
        quoteMargin: "22.5px 40px 22.5px 0",
        listPadding: "32px",
        tableRuleColor: "rgba(0,0,0,0.12)",
        tableCellPadding: "8px 16px 8px 0",
        rule: "0.5px solid rgba(0,0,0,0.12)",
        ruleMargin: "12px 6px",
        mathBlockSize: "15px",
        mathBlockAlign: "left",
        mathBlockPadding: "11.25px 0",
        mathBlockMargin: "22.5px 0",
        selection: nil,
        printFontSize: "14px"
    )

    public static let previewClaudeDark = PreviewThemeTokens(
        name: "Claude Dark",
        background: "#1A1A1A",
        bodyFont: "system-ui, sans-serif",
        bodySize: "15px",
        bodyLineHeight: "22.5px",
        bodyColor: "#EDEDED",
        contentMaxWidth: "626px",
        paddingVertical: "100.8px",
        paddingSides: "80px",
        paragraphMargin: "22.5px 0",
        headingFont: "system-ui, sans-serif",
        headingWeight: "600",
        headingSizes: ["22px", "18px", "16px", "16px", "14px", "14px"],
        headingMargins: ["12px 0 -4px", "12px 0 -4px", "8px 0 -4px", "8px 0 -4px", "8px 0 -4px", "8px 0 -4px"],
        headingWeights: ["bold", "bold", "bold", "600", "bold", "600"],
        linkColor: "#7AB3FF",
        inlineCodeFont: "inherit",
        inlineCodeSize: "1em",
        inlineCodeColor: "inherit",
        inlineCodeBackground: "rgba(255,255,255,0.06)",
        inlineCodeRadius: "4px",
        inlineCodePadding: "1px 4px",
        inlineCodeMargin: "0",
        codeBlockBackground: "rgba(255,255,255,0.05)",
        codeBlockRadius: "8px",
        codeBlockPadding: "14px",
        codeBlockMargin: "22.5px 0",
        codeBlockFont: "\"Roboto Mono\", monospace",
        codeBlockSize: "14px",
        codeBlockLineHeight: "22.75px",
        codeBlockColor: "inherit",
        codeBlockBorder: "0.5px solid rgba(255,255,255,0.14)",
        codeTokens: previewDarkCodeTokenColours,
        quoteBorder: "4px solid rgba(255,255,255,0.12)",
        quotePadding: "0 0 0 16px",
        quoteColor: "#9B9B9B",
        quoteMargin: "22.5px 40px 22.5px 0",
        listPadding: "32px",
        tableRuleColor: "rgba(255,255,255,0.14)",
        tableCellPadding: "8px 16px 8px 0",
        rule: "0.5px solid rgba(255,255,255,0.14)",
        ruleMargin: "12px 6px",
        mathBlockSize: "15px",
        mathBlockAlign: "left",
        mathBlockPadding: "11.25px 0",
        mathBlockMargin: "22.5px 0",
        selection: nil,
        printFontSize: "14px"
    )

    public static let previewThemes: [PreviewThemeTokens] = [
        previewDefault, previewGitHub, previewDark, previewClaude, previewClaudeDark,
    ]
}
