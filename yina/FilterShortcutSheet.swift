import Cocoa

/// Shared AppKit content for saving a filter and editing a saved filter.
/// The filter controller continues to own validation, persistence, and sheet actions.
final class FilterShortcutSheet: CommonWindow {
  let nameTextField = NSTextField(string: "")
  let filterStringTextField = NSTextField(string: "")
  let keyRecordView = KeyRecordView(frame: .zero)
  let keyLabel = NSTextField(labelWithString: "Press any button to record")
  let submitButton: NSButton
  let cancelButton: NSButton

  init(editing: Bool, target: AnyObject, submitAction: Selector, cancelAction: Selector) {
    let size = NSSize(width: editing ? 393 : 403, height: editing ? 240 : 230)
    submitButton = NSButton(title: editing ? "Save" : "Add", target: target, action: submitAction)
    cancelButton = NSButton(title: "Cancel", target: target, action: cancelAction)
    super.init(contentRect: NSRect(origin: .zero, size: size),
               styleMask: [.titled, .closable, .miniaturizable, .resizable],
               backing: .buffered, defer: false)
    title = editing ? "Edit Filter" : "Save Filter"
    allowsToolTipsWhenApplicationIsInactive = false
    autorecalculatesKeyViewLoop = false
    contentMinSize = size
    setFrameAutosaveName(editing ? "EditFilterWindow" : "SaveFilterWindow")

    let content = NSView(frame: NSRect(origin: .zero, size: size))
    contentView = content
    let heading = NSTextField(labelWithString: title)
    heading.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
    content.addSubview(heading)
    heading.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
      heading.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
      heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 12)
    ])

    // Keep the original form order and spacing, including the save-only explanation.
    var previous: NSView = heading
    if !editing {
      let explanation = NSTextField(wrappingLabelWithString:
        "By saving a filter, you can enable or disable it conveniently and even assign a shortcut key to it.")
      addRow(explanation, below: previous, spacing: 4, in: content)
      previous = explanation
    }
    let nameLabel = smallLabel("Name:")
    addRow(nameLabel, below: previous, spacing: 8, in: content)
    addRow(nameTextField, below: nameLabel, spacing: 4, in: content, height: 22)
    previous = nameTextField
    if editing {
      let filterLabel = smallLabel("Filter string:")
      addRow(filterLabel, below: previous, spacing: 8, in: content)
      addRow(filterStringTextField, below: filterLabel, spacing: 4, in: content, height: 22)
      previous = filterStringTextField
    }
    let shortcutLabel = smallLabel("Shortcut key:")
    addRow(shortcutLabel, below: previous, spacing: 8, in: content)
    addRow(keyRecordView, below: shortcutLabel, spacing: 4, in: content, height: 48)
    keyRecordView.addSubview(keyLabel)
    keyLabel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      keyLabel.centerXAnchor.constraint(equalTo: keyRecordView.centerXAnchor),
      keyLabel.centerYAnchor.constraint(equalTo: keyRecordView.centerYAnchor),
      keyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: keyRecordView.leadingAnchor, constant: 4),
      keyLabel.trailingAnchor.constraint(lessThanOrEqualTo: keyRecordView.trailingAnchor, constant: -4)
    ])

    for button in [submitButton, cancelButton] {
      button.bezelStyle = .rounded
      button.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(button)
    }
    submitButton.keyEquivalent = "\r"
    cancelButton.keyEquivalent = "\u{1b}"
    NSLayoutConstraint.activate([
      submitButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
      submitButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
      submitButton.topAnchor.constraint(greaterThanOrEqualTo: keyRecordView.bottomAnchor, constant: 8),
      cancelButton.trailingAnchor.constraint(equalTo: submitButton.leadingAnchor, constant: -12),
      cancelButton.centerYAnchor.constraint(equalTo: submitButton.centerYAnchor),
      cancelButton.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 12)
    ])
    initialFirstResponder = nameTextField
    nameTextField.nextKeyView = editing ? filterStringTextField : keyRecordView
    if editing { filterStringTextField.nextKeyView = keyRecordView }
    keyRecordView.nextKeyView = cancelButton
    cancelButton.nextKeyView = submitButton
    submitButton.nextKeyView = nameTextField
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func smallLabel(_ title: String) -> NSTextField {
    let label = NSTextField(labelWithString: title)
    label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    return label
  }

  private func addRow(_ row: NSView, below previous: NSView, spacing: CGFloat,
                      in content: NSView, height: CGFloat? = nil) {
    row.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
      row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
      row.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: spacing)
    ])
    if let height { row.heightAnchor.constraint(equalToConstant: height).isActive = true }
  }
}
