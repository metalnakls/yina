import Cocoa

/// Replaces the main nib's app-delegate ownership and application wiring.
@main enum ApplicationMain {
  static func main() {
    // Construct the delegate first so clean-start policy precedes AppKit initialization.
    let delegate = AppDelegate()
    let application = NSApplication.shared
    application.delegate = delegate
    delegate.installApplicationMenus(in: application)
    // Keep NSApplicationMain's normal argument, launch-event, and restoration handling.
    // NSApplication.delegate is weak, so retain the delegate for the entire run.
    _ = withExtendedLifetime(delegate) {
      NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
  }
}
