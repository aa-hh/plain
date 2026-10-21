import PlainAppKit
import SwiftUI

@main
struct PlainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // The welcome folder and licence file ship in this target's resource bundle, which PlainAppKit cannot see.
        let resources = Bundle.module.resourceURL!.appendingPathComponent("Resources", isDirectory: true)
        delegate.welcomeSource = resources.appendingPathComponent("Welcome", isDirectory: true)
        delegate.licencesFile = Bundle.main.url(forResource: "Licences", withExtension: "md")
            ?? resources.appendingPathComponent("Licences.md")
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}
