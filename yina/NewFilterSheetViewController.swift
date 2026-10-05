import Cocoa

class NewFilterSheetViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {
  private static let textAndTableWidthDifference = 20.0

  private weak var filterWindow: FilterWindowController!
  private(set) var tableView: NSTableView!
  private var scrollContentView: NSView!
  private(set) var addButton: NSButton!
  private var presetsClipViewWidthConstraint: NSLayoutConstraint!

  init(filterWindow: FilterWindowController) {
    self.filterWindow = filterWindow
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func loadView() {
    let content = FilterPresetContentView(target: self,
      addAction: #selector(sheetAddBtnAction(_:)), cancelAction: #selector(sheetCancelBtnAction(_:)))
    tableView = content.tableView
    scrollContentView = content.scrollContentView
    addButton = content.addButton
    presetsClipViewWidthConstraint = content.presetsWidthConstraint
    view = content
  }

  private var currentPreset: FilterPreset?
  private var currentBindings: [String: NSControl] = [:]
  private var presets: [FilterPreset] = []

  override func viewDidLoad() {
    super.viewDidLoad()
    tableView.dataSource = self
    tableView.delegate = self
    presets = filterWindow.filterType == MPVProperty.vf ? FilterPreset.vfPresets : FilterPreset.afPresets

    // Different locales have different text width requirements. Examine all content and fit table to widest item.
    var maxWidth = 0.0
    for preset in presets {
      let presetString = NSMutableAttributedString(string: preset.localizedName)
      let fontSize = NSFont.systemFontSize(for: .regular)
      let textFont = NSFont.systemFont(ofSize: fontSize)
      presetString.addAttribute(.font, value: textFont, range: NSRange(location: 0, length: presetString.length))
      let textWidth = presetString.size().width
      if textWidth > maxWidth {
        maxWidth = textWidth
      }
    }
    presetsClipViewWidthConstraint.constant = maxWidth + NewFilterSheetViewController.textAndTableWidthDifference

    tableView.reloadData()

    // Select first filter preset in table if nothing already selected
    if tableView.selectedRowIndexes.isEmpty {
      tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    return presets.count
  }

  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    return presets[at: row]?.localizedName
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("FilterPresetCell")
    let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
      ?? FilterViewFactory.textCell()
    cell.identifier = identifier
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard let preset = presets[at: tableView.selectedRow] else { return }
    showSettings(for: preset)
  }

  /** Render parameter controls at right side when selected a filter in the table. */
  func showSettings(for preset: FilterPreset) {
    currentPreset = preset
    currentBindings.removeAll()
    scrollContentView.subviews.forEach { $0.removeFromSuperview() }
    addButton.isEnabled = true

    let stackView = NSStackView()
    stackView.orientation = .vertical
    stackView.alignment = .leading
    stackView.translatesAutoresizingMaskIntoConstraints = false
    scrollContentView.addSubview(stackView)
    Utility.quickConstraints(["H:|-4-[v]-4-|", "V:|-4-[v]-4-|"], ["v": stackView])

    let generateInputs: (String, FilterParameter) -> Void = { (name, param) in
      let label = self.quickLabel(title: preset.localizedParamName(name))
      stackView.addArrangedSubview(label)
      label.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
      let input = self.quickInput(param: param)
      // For preventing crash due to adding a filter with no name:
      if name == "name", preset.name.starts(with: "custom_"), let textField = input as? NSTextField {
        textField.delegate = self
        self.addButton.isEnabled = !textField.stringValue.isEmpty
      }
      stackView.addArrangedSubview(input)
      input.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
      self.currentBindings[name] = input
    }
    for name in preset.paramOrder {
      generateInputs(name, preset.params[name]!)
    }
  }

  private func quickLabel(title: String) -> NSTextField {
    let label = NSTextField(frame: NSRect(x: 0, y: 0,
                                          width: scrollContentView.frame.width,
                                          height: 17))
    label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    label.stringValue = title
    label.drawsBackground = false
    label.isBezeled = false
    label.isSelectable = false
    label.isEditable = false
    label.usesSingleLineMode = false
    label.lineBreakMode = .byWordWrapping
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }

  /** Create the control from a `FilterParameter` definition. */
  private func quickInput(param: FilterParameter) -> NSControl {
    switch param.type {
    case .text:
      // Text field
      let label = NSTextField(frame: NSRect(x: 0, y: 0,
                              width: scrollContentView.frame.width - 8,
                              height: 22))
      label.stringValue = param.defaultValue.stringValue
      label.isSelectable = false
      label.isEditable = true
      label.lineBreakMode = .byClipping
      label.usesSingleLineMode = true
      label.cell?.isScrollable = true
      return label
    case .int:
      // Slider
      let slider = NSSlider(frame: NSRect(x: 0, y: 0,
                                          width: scrollContentView.frame.width - 8,
                                          height: 19))
      slider.minValue = Double(param.minInt!)
      slider.maxValue = Double(param.maxInt!)
      if let step = param.step {
        slider.numberOfTickMarks = (param.maxInt! - param.minInt!) / step + 1
        slider.allowsTickMarkValuesOnly = true
        slider.frame.size.height = 24
      }
      slider.intValue = Int32(param.defaultValue.intValue)
      return slider
    case .float:
      // Slider
      let slider = NSSlider(frame: NSRect(x: 0, y: 0,
                                          width: scrollContentView.frame.width - 8,
                                          height: 19))
      slider.minValue = Double(param.min!)
      slider.maxValue = Double(param.max!)
      slider.floatValue = param.defaultValue.floatValue
      return slider
    case .choose:
      // Choose
      let popupBtn = NSPopUpButton(frame: NSRect(x: 0, y: 0,
                                                 width: scrollContentView.frame.width - 8,
                                                 height: 26))
      popupBtn.addItems(withTitles: param.choices)
      return popupBtn
    }
  }

  @IBAction func sheetAddBtnAction(_ sender: Any) {
    guard let preset = currentPreset else { return }
    // create instance
    let instance = FilterPresetInstance(from: preset)
    for (name, control) in currentBindings {
      switch preset.params[name]!.type {
      case .text:
        instance.params[name] = FilterParameterValue(string: control.stringValue)
      case .int:
        instance.params[name] = FilterParameterValue(int: Int(control.intValue))
      case .float:
        instance.params[name] = FilterParameterValue(float: control.floatValue)
      case .choose:
        instance.params[name] = FilterParameterValue(string: preset.params[name]!.choices[Int(control.intValue)])
      }
    }
    // Validate custom filter syntax before closing the sheet. MPVFilter rejects malformed labels,
    // such as a name beginning with "@" but lacking the required label separator.
    guard let filter = preset.transformer(instance) else {
      Utility.showAlert("filter.incorrect", sheetWindow: filterWindow.newFilterSheet)
      return
    }
    filterWindow.window!.endSheet(filterWindow.newFilterSheet, returnCode: .OK)
    if filterWindow.addFilter(filter) {
      PlayerCore.lastActive.sendOSD(.addFilter(preset.localizedName))
    }
  }

  @IBAction func sheetCancelBtnAction(_ sender: Any) {
    filterWindow.window!.endSheet(filterWindow.newFilterSheet, returnCode: .cancel)
  }

}

/* For preventing crash due to to adding filter with no name */
extension NewFilterSheetViewController: NSTextFieldDelegate {
  func controlTextDidChange(_ obj: Notification) {
    if let textField = obj.object as? NSTextField {
      self.addButton.isEnabled = !textField.stringValue.isEmpty
    }
  }
}
