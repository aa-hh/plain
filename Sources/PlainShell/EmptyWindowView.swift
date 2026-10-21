import PlainCore
import SwiftUI

/// The editor area with no tab open: a centred 52 pt `×` in the tertiary colour.
public struct EmptyWindowView: View {
    public init() {}

    public var body: some View {
        Text("×")
            .font(.system(size: Tokens.emptyGlyphFontSize))
            .foregroundStyle(Color.tertiaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.material)
    }
}
