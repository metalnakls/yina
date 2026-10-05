// Compile with CommonWindow.swift, KeyRecordView.swift, and FilterShortcutSheet.swift.
// Isolated AppKit controls only; this does not launch yina or call mpv.
import Cocoa
extension NSAppearance {
  func applyAppearanceFor(_ block: () -> Void) { performAsCurrentDrawingAppearance(block) }
}
final class SheetActions: NSObject, KeyRecordViewDelegate {
  var saves = 0
  var cancels = 0
  var recorded = ""
  @objc func save(_ sender: Any?) { saves += 1 }
  @objc func cancel(_ sender: Any?) { cancels += 1 }
  func keyRecordView(_ view: KeyRecordView, recordedKeyDownWith event: NSEvent) {
    recorded = view.currentKey
  }
}
@main struct Smoke {
  static func main() {
    _ = NSApplication.shared
    let target = SheetActions()
    for editing in [false, true] {
      let sheet = FilterShortcutSheet(editing: editing, target: target,
        submitAction: #selector(SheetActions.save(_:)), cancelAction: #selector(SheetActions.cancel(_:)))
      // Persistent frame names are product behavior; do not read/write user frame preferences here.
      sheet.setFrameAutosaveName("")
      let view = sheet.contentView!
      view.layoutSubtreeIfNeeded()
      precondition(sheet.initialFirstResponder === sheet.nameTextField)
      precondition(sheet.nameTextField.nextKeyView === (editing ? sheet.filterStringTextField : sheet.keyRecordView))
      precondition(sheet.keyRecordView.frame.height == 48)
      precondition(sheet.submitButton.frame.maxY <= sheet.keyRecordView.frame.minY - 8)
      precondition(!view.hasAmbiguousLayout && !sheet.keyRecordView.hasAmbiguousLayout)
      precondition(sheet.submitButton.keyEquivalent == "\r" && sheet.cancelButton.keyEquivalent == "\u{1b}")
      precondition(sheet.filterStringTextField.superview != nil || !editing)
      sheet.nameTextField.stringValue = "Test filter"
      sheet.filterStringTextField.stringValue = "hflip"
      sheet.keyRecordView.delegate = target
      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0, context: nil, characters: "X", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!
      sheet.keyRecordView.keyDown(with: event)
      precondition(target.recorded == "x" && sheet.keyRecordView.currentKeyModifiers.contains(.shift))
      let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
      let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
      precondition(sheet.submitButton.performKeyEquivalent(with: enter))
      precondition(sheet.cancelButton.performKeyEquivalent(with: escape))
      // Resizing must retain form separation and keep the record area usable.
      sheet.setContentSize(NSSize(width: 600, height: 340))
      view.layoutSubtreeIfNeeded()
      precondition(sheet.keyRecordView.frame.width == 576)
      precondition(sheet.submitButton.frame.maxY <= sheet.keyRecordView.frame.minY - 8)
      print("PASS: \(editing ? "edit" : "save") layout, focus, keyboard shortcut, button targets, and resize.")
    }
    precondition(target.saves == 2 && target.cancels == 2)
  }
}
