import Foundation

/// Locations of the files `scripts/fetch-vendor.sh` writes into this target's `Resources` folder.
public enum VendorFiles {
    /// The copied `Resources` folder; also the folder holding every vendor licence (`*/LICENSE`, `fonts/OFL.txt`).
    /// Swift 6.4's build puts it inside the bundle's `Contents/Resources`; Swift 6.3 builds a flat bundle in which the
    /// copied folder is itself the bundle's resource folder.
    public static let root: URL = {
        let resources = Bundle.module.resourceURL!
        let nested = resources.appendingPathComponent("Resources", isDirectory: true)
        return FileManager.default.fileExists(atPath: nested.path) ? nested : resources
    }()

    public static let katexJS = root.appendingPathComponent("katex/katex.min.js")
    public static let katexCSS = root.appendingPathComponent("katex/katex.min.css")
    public static let katexFontsFolder = root.appendingPathComponent("katex/fonts", isDirectory: true)
    public static let prismFolder = root.appendingPathComponent("prism/components", isDirectory: true)
    public static let prismComponentsJSON = root.appendingPathComponent("prism/components.json")
    public static let emojiJSON = root.appendingPathComponent("emoji/emoji.json")
    public static let robotoMonoRegular = root.appendingPathComponent("fonts/RobotoMono-Regular.ttf")
    public static let robotoMonoBold = root.appendingPathComponent("fonts/RobotoMono-Bold.ttf")
    public static let licencesFolder = root
    /// Lucide's SVG icons, by icon name (for example "folder-open").
    public static func lucideIcon(_ name: String) -> URL { root.appendingPathComponent("lucide/\(name).svg") }

    /// Every URL above, for checks that the vendor files exist.
    public static let all: [URL] = [
        katexJS, katexCSS, katexFontsFolder, prismFolder, prismComponentsJSON,
        emojiJSON, robotoMonoRegular, robotoMonoBold, licencesFolder, lucideIcon("folder"),
    ]
}
