// Compile with yina/QuickLookSetup.swift; this harness never displays its dialog.
import AVFoundation
import AppKit
import Foundation

enum Logger {
  enum Level { case warning, error }
  static func log(_ message: String, level: Level) { print(message) }
}

@main
struct QuickLookSetupSmoke {
  static func main() async {
    let disabled = NSError(domain: AVFoundationErrorDomain, code: AVError.mediaExtensionDisabled.rawValue)
    precondition(QuickLookAvailability.isDisabledError(disabled))
    let decoderDisabled = NSError(domain: NSOSStatusErrorDomain, code: -17697)
    let wrapped = NSError(domain: AVFoundationErrorDomain, code: AVError.invalidSourceMedia.rawValue,
                          userInfo: [NSUnderlyingErrorKey: decoderDisabled])
    precondition(QuickLookAvailability.isDisabledError(wrapped))
    let unrelated = NSError(domain: AVFoundationErrorDomain, code: AVError.invalidSourceMedia.rawValue)
    precondition(!QuickLookAvailability.isDisabledError(unrelated))
    precondition(!QuickLookAvailability.isDisabledError(NSError(domain: "Other", code: disabled.code)))
    let multiple = NSError(domain: NSCocoaErrorDomain, code: 1,
                           userInfo: [NSMultipleUnderlyingErrorsKey: [unrelated, disabled]])
    precondition(QuickLookAvailability.isDisabledError(multiple))
    precondition(NSWorkspace.shared.urlForApplication(toOpen: QuickLookSetup.settingsURL) != nil)
    print("PASS: disabled reader/decoder errors, nested errors, unrelated failures and Settings URL handler")
    if let path = CommandLine.arguments.dropFirst().first {
      let result = await QuickLookAvailability.check(probeURL: URL(fileURLWithPath: path))
      print("System probe: \(result)")
      precondition(result != .unavailable, "The probe must distinguish enabled from disabled on the installed build")
    }
  }
}
