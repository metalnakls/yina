//
//  KeyRecordViewController.swift
//  yina
//
//  Created by lhc on 12/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

class KeyRecordViewController: NSViewController, KeyRecordViewDelegate, NSRuleEditorDelegate, NSTextFieldDelegate {

  private(set) var keyRecordView: KeyRecordView!
  private var keyLabel: NSTextField!
  private var actionTextField: NSTextField!
  private var ruleEditor: NSRuleEditor!

  private lazy var criterions: [Criterion] = KeyBindingDataLoader.load()

  private var keyBindingInputObserver: NSObjectProtocol?

  private var pendingKey: String?
  private var pendingAction: String?

  @objc dynamic var ready = false

  var keyCode: String {
    get {
      return keyLabel.stringValue
    }
    set {
      if let f = keyLabel {
        f.stringValue = newValue
      } else {
        pendingKey = newValue
      }
    }
  }

  var action: String {
    get {
      return actionTextField.stringValue
    }
    set {
      if let f = actionTextField {
        f.stringValue = newValue
      } else {
        pendingAction = newValue
      }
    }
  }

  override func loadView() {
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 155))
    keyRecordView = KeyRecordView(frame: .zero)
    keyLabel = NSTextField(labelWithString: "")
    keyLabel.font = NSFont(name: "Menlo-Regular", size: 22)
    keyLabel.alignment = .center
    keyLabel.lineBreakMode = .byClipping
    keyRecordView.addSubview(keyLabel)

    let actionLabel = NSTextField(labelWithString: "Select action:")
    let commandLabel = NSTextField(labelWithString: "Or enter a mpv command:")
    for label in [actionLabel, commandLabel] {
      label.font = NSFont.systemFont(ofSize: 11)
      label.controlSize = .small
    }

    let ruleScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 24))
    ruleScrollView.borderType = .lineBorder
    ruleScrollView.drawsBackground = false
    ruleScrollView.hasHorizontalScroller = false
    ruleScrollView.hasVerticalScroller = false
    ruleScrollView.horizontalScrollElasticity = .none
    ruleScrollView.verticalScrollElasticity = .none
    ruleEditor = NSRuleEditor(frame: ruleScrollView.contentView.bounds)
    ruleEditor.autoresizingMask = [.width, .height]
    ruleEditor.rowHeight = 24
    ruleScrollView.documentView = ruleEditor

    actionTextField = NSTextField(string: "")
    actionTextField.isBezeled = true
    actionTextField.bezelStyle = .squareBezel
    actionTextField.focusRingType = .none
    actionTextField.usesSingleLineMode = true
    actionTextField.lineBreakMode = .byClipping

    for subview in [keyRecordView!, actionLabel, ruleScrollView, commandLabel, actionTextField!] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(subview)
    }
    keyLabel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      keyRecordView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      keyRecordView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      keyRecordView.topAnchor.constraint(equalTo: contentView.topAnchor),
      keyRecordView.heightAnchor.constraint(equalToConstant: 46),
      keyLabel.leadingAnchor.constraint(equalTo: keyRecordView.leadingAnchor),
      keyLabel.trailingAnchor.constraint(equalTo: keyRecordView.trailingAnchor),
      keyLabel.topAnchor.constraint(equalTo: keyRecordView.topAnchor, constant: 8),
      keyLabel.bottomAnchor.constraint(equalTo: keyRecordView.bottomAnchor, constant: -7),
      actionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      actionLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
      actionLabel.topAnchor.constraint(equalTo: keyRecordView.bottomAnchor, constant: 12),
      actionLabel.heightAnchor.constraint(equalToConstant: 14),
      ruleScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      ruleScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      ruleScrollView.topAnchor.constraint(equalTo: actionLabel.bottomAnchor, constant: 4),
      ruleScrollView.heightAnchor.constraint(equalToConstant: 24),
      commandLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      commandLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
      commandLabel.topAnchor.constraint(equalTo: ruleScrollView.bottomAnchor, constant: 8),
      commandLabel.heightAnchor.constraint(equalToConstant: 14),
      actionTextField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      actionTextField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      actionTextField.topAnchor.constraint(equalTo: commandLabel.bottomAnchor, constant: 4),
      actionTextField.heightAnchor.constraint(equalToConstant: 22),
      actionTextField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -7)
    ])
    view = contentView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    keyRecordView.delegate = self

    ruleEditor.nestingMode = .single
    ruleEditor.canRemoveAllRows = false
    ruleEditor.delegate = self
    ruleEditor.addRow(self)

    keyLabel.delegate = self
    actionTextField.delegate = self

    if let pk = pendingKey {
      keyLabel.stringValue = pk
      pendingKey = nil
    }
    if let pa = pendingAction {
      actionTextField.stringValue = pa
      pendingAction = nil
    }

    keyBindingInputObserver = NotificationCenter.default.addObserver(
      forName: .yinaKeyBindingInputChanged, object: nil, queue: .main
    ) { [weak self] _ in
      self?.updateCommandField()
    }
  }

  deinit {
    if let keyBindingInputObserver {
      NotificationCenter.default.removeObserver(keyBindingInputObserver)
    }
  }

  func keyRecordView(_ view: KeyRecordView, recordedKeyDownWith event: NSEvent) {
    keyLabel.stringValue = KeyCodeHelper.mpvKeyCode(from: event)
    NotificationCenter.default.post(.init(name: NSControl.textDidChangeNotification, object: keyLabel))
  }

  // MARK: - NSRuleEditorDelegate

  func ruleEditor(_ editor: NSRuleEditor, child index: Int, forCriterion criterion: Any?, with rowType: NSRuleEditor.RowType) -> Any {
    if criterion == nil {
      return criterions[index]
    } else {
      return (criterion as! Criterion).child(at: index)
    }
  }

  func ruleEditor(_ editor: NSRuleEditor, numberOfChildrenForCriterion criterion: Any?, with rowType: NSRuleEditor.RowType) -> Int {
    if criterion == nil {
      return criterions.count
    } else {
      return (criterion as! Criterion).childrenCount()
    }
  }

  func ruleEditor(_ editor: NSRuleEditor, displayValueForCriterion criterion: Any, inRow row: Int) -> Any {
    return (criterion as! Criterion).displayValue()
  }

  func ruleEditorRowsDidChange(_ notification: Notification) {
    updateCommandField()
  }

  // MARK: IBAction

  @IBAction func ChooseMediaKeyAction(_ sender: NSPopUpButton) {
    switch sender.selectedTag() {
    case 0:
      keyLabel.stringValue = "PLAY"
    case 1:
      keyLabel.stringValue = "PREV"
    case 2:
      keyLabel.stringValue = "NEXT"
    default:
      break
    }
    NotificationCenter.default.post(.init(name: NSControl.textDidChangeNotification, object: keyLabel))
  }

  // MARK: - Other

  private func updateCommandField() {
    guard let criterions = ruleEditor.criteria(forRow: 0) as? [Criterion] else { return }
    actionTextField.stringValue = KeyBindingTranslator.string(fromCriteria: criterions)
    NotificationCenter.default.post(.init(name: NSControl.textDidChangeNotification, object: actionTextField))
  }

  func controlTextDidChange(_ obj: Notification) {
    ready = !keyCode.isEmpty && !action.isEmpty
  }
}

