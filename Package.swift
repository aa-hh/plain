// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "Plain",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "Plain", targets: ["Plain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", revision: "bc55d614bc8608d74cdc18d3aa6413bd8661e444"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ],
    targets: [
        .target(name: "PlainVendor", resources: [.copy("Resources")]),
        .target(name: "PlainCore", dependencies: ["PlainVendor"]),
        .target(name: "MarkdownDocument", dependencies: [
            .product(name: "Markdown", package: "swift-markdown"), "PlainCore", "PlainVendor",
        ]),
        .target(name: "PlainDocument", dependencies: ["PlainCore"]),
        .target(name: "FolderIndex", dependencies: ["PlainCore"]),
        .target(name: "GitStatus", dependencies: ["PlainCore"]),
        .target(name: "Spellcheck", dependencies: ["PlainCore"]),
        .target(name: "EditorTextView", dependencies: [
            "MarkdownDocument", "PlainDocument", "Spellcheck", "GitStatus", "PlainCore", "PlainVendor",
        ]),
        .target(name: "PreviewRenderer", dependencies: ["MarkdownDocument", "PlainCore", "PlainVendor"]),
        .target(name: "PlainShell", dependencies: [
            "FolderIndex", "GitStatus", "MarkdownDocument", "PlainDocument", "PlainCore", "PlainVendor",
        ]),
        .target(name: "PlainAppKit", dependencies: [
            "PlainVendor", "PlainCore", "MarkdownDocument", "PlainDocument", "FolderIndex",
            "GitStatus", "Spellcheck", "EditorTextView", "PreviewRenderer", "PlainShell",
            .product(name: "Yams", package: "Yams"),
        ]),
        .executableTarget(name: "Plain", dependencies: ["PlainAppKit"], resources: [.copy("Resources")]),
        .testTarget(name: "PlainCoreTests", dependencies: ["PlainCore", "PlainVendor", "PreviewRenderer"]),
        .testTarget(name: "MarkdownDocumentTests", dependencies: ["MarkdownDocument"]),
        .testTarget(name: "PlainDocumentTests", dependencies: ["PlainDocument"]),
        .testTarget(name: "FolderIndexTests", dependencies: ["FolderIndex"]),
        .testTarget(name: "GitStatusTests", dependencies: ["GitStatus"]),
        .testTarget(name: "SpellcheckTests", dependencies: ["Spellcheck"]),
        .testTarget(name: "EditorTextViewTests", dependencies: ["EditorTextView"]),
        .testTarget(name: "PreviewRendererTests", dependencies: ["PreviewRenderer"]),
        .testTarget(name: "PlainShellTests", dependencies: ["PlainShell"]),
        .testTarget(name: "PlainTests", dependencies: ["PlainAppKit"]),
    ],
    swiftLanguageModes: [.v6]
)
