import AppKit

@main
@MainActor
struct BeQuietApp {
    /// `NSApplication.delegate` is a weak reference, so the delegate lives here.
    private static let delegate = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.delegate = delegate
        application.run()
    }
}
