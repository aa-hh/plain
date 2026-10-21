import Foundation

/// Locations of the files `scripts/fetch-vendor.sh` writes into this target's `Resources` folder.
public enum VendorFiles {
    /// The copied `Resources` folder; also the folder holding every vendor licence (`*/LICENSE`, `fonts/OFL.txt`).
    public static let root: URL = Bundle.module.resourceURL!.appendingPathComponent("Resources", isDirectory: true)

    public static let katexJS = root.appendingPathComponent("katex/katex.min.js")
    public static let katexCSS = root.appendingPathComponent("katex/katex.min.css")
    public static let katexFontsFolder = root.appendingPathComponent("katex/fonts", isDirectory: true)
    public static let prismFolder = root.appendingPathComponent("prism/components", isDirectory: true)
    public static let prismComponentsJSON = root.appendingPathComponent("prism/components.json")
    public static let emojiJSON = root.appendingPathComponent("emoji/emoji.json")
    public static let robotoMonoRegular = root.appendingPathComponent("fonts/RobotoMono-Regular.ttf")
    public static let robotoMonoBold = root.appendingPathComponent("fonts/RobotoMono-Bold.ttf")
    public static let licencesFolder = root

    /// Every URL above, for checks that the vendor files exist.
    public static let all: [URL] = [
        katexJS, katexCSS, katexFontsFolder, prismFolder, prismComponentsJSON,
        emojiJSON, robotoMonoRegular, robotoMonoBold, licencesFolder,
    ]
}
