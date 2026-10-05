// Compile with KeyRecordView.swift and KeyRecordViewController.swift using -parse-as-library.
// This isolated AppKit harness does not launch yina. The command tree/key translation
// are stand-ins; checks exercise the production view's layout, input, and ownership.
import Cocoa
extension NSAppearance {
  func applyAppearanceFor(_ block: () -> Void) { performAsCurrentDrawingAppearance(block) }
}
extension Notification.Name {
  static let yinaKeyBindingInputChanged = Notification.Name("KeyBindingInputChanged")
}
class Criterion: NSObject {
  let name: String
  init(_ name: String) { self.name = name }
  func child(at index: Int) -> Criterion { fatalError() }
  func childrenCount() -> Int { 0 }
  func displayValue() -> Any { name }
}
enum KeyBindingDataLoader {
  static func load() -> [Criterion] { [Criterion("ignore"), Criterion("cycle pause")] }
}
enum KeyBindingTranslator {
  static func string(fromCriteria criteria: [Criterion]) -> String { criteria.map(\.name).joined(separator: " ") }
}
enum KeyCodeHelper {
  static func mpvKeyCode(from event: NSEvent) -> String { event.charactersIgnoringModifiers ?? "" }
}
func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
@main struct Smoke {
  static func main() {
    _ = NSApplication.shared
    weak var released: KeyRecordViewController?
    autoreleasepool {
      let controller = KeyRecordViewController()
      released = controller
      controller.keyCode = "SPACE"
      controller.action = "cycle pause"
      let view = controller.view
      view.layoutSubtreeIfNeeded()
      precondition(view.frame.size == NSSize(width: 480, height: 155))
      precondition(controller.keyCode == "SPACE" && controller.action == "cycle pause")
      let recorder = controller.keyRecordView!
      precondition(recorder.frame.height == 46 && recorder.layer?.cornerRadius == 4)
      let rule = descendants(view).compactMap { $0 as? NSRuleEditor }.first!
      precondition(rule.numberOfRows == 1 && rule.nestingMode == .single && !rule.canRemoveAllRows)
      let command = descendants(view).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
      precondition(command.frame.height == 22 && command.frame.minY == 7)
      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!
      recorder.keyDown(with: event)
      precondition(controller.keyCode == "x" && controller.ready)
      command.stringValue = ""
      controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
      precondition(!controller.ready)
      NotificationCenter.default.post(name: .yinaKeyBindingInputChanged, object: nil)
      precondition(!controller.action.isEmpty && controller.ready)
      print("PASS: pending values, original layout, rule editor, key recording, command readiness.")
    }
    precondition(released == nil, "the recorder delegate must not retain the controller")
    NotificationCenter.default.post(name: .yinaKeyBindingInputChanged, object: nil)
    print("PASS: controller released and observer removed after dialog closes.")
  }
}
