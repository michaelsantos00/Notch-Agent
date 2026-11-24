import SwiftUI

@main
enum NotchAgentEntry {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == CursorActivityHooks.argument {
            CursorActivityHooks.runHelper()
        } else {
            NotchAgentMain.main()
        }
    }
}

struct NotchAgentMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The notch is the UI; the panel is put up by the delegate. This scene
        // exists only because `App` needs one.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
