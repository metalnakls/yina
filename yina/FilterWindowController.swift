//
//  FilterWindowController.swift
//  yina
//
//  Created by lhc on 25/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

class FilterWindowController: NSWindowController, NSWindowDelegate {

  private let frameAutosaveName: String
  private var newFilterController: NewFilterSheetViewController!
  private(set) var splitView: NSSplitView!
  private(set) var currentFiltersTableView: NSTableView!
  private(set) var savedFiltersTableView: NSTableView!
  private(set) var newFilterSheet: NSWindow!

  // init(window: nil) does not provide AppKit's nib-driven lazy lifecycle.
  override var window: NSWindow? {
    get {
      if super.window == nil {
        loadWindow()
        windowDidLoad()
      }
      return super.window
    }
    set { super.window = newValue }
  }

  override func loadWindow() {
    let window = CommonWindow(contentRect: NSRect(x: 608, y: 562, width: 640, height: 382),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.allowsToolTipsWhenApplicationIsInactive = false
    window.autorecalculatesKeyViewLoop = false
    window.minSize = NSSize(width: 240, height: 300)
    let content = FilterWindowContentView(target: self,
      addAction: #selector(addFilterAction(_:)), removeAction: #selector(removeFilterAction(_:)))
    splitView = content.splitView
    currentFiltersTableView = content.currentFiltersTableView
    savedFiltersTableView = content.savedFiltersTableView
    removeButton = content.removeButton
    window.contentView = content
    self.window = window
    windowFrameAutosaveName = frameAutosaveName
  }
  private(set) var saveFilterSheet: FilterShortcutSheet!
  private(set) var editFilterSheet: FilterShortcutSheet!
  private var saveFilterNameTextField: NSTextField!
  private var keyRecordView: KeyRecordView!
  private var keyRecordViewLabel: NSTextField!
  private var editFilterNameTextField: NSTextField!
  private var editFilterStringTextField: NSTextField!
  private var editFilterKeyRecordView: KeyRecordView!
  private var editFilterKeyRecordViewLabel: NSTextField!
  private(set) var removeButton: NSButton!

  var loaded = false

  var filterType: String!

  var filters: [MPVFilter] = []
  var savedFilters: [SavedFilter] = []
  private var filterIsSaved: [Bool] = []

  private var currentFilter: MPVFilter?
  private var currentSavedFilter: SavedFilter?

  init(filterType: String, autosaveName: String) {
    self.filterType = filterType
    self.frameAutosaveName = autosaveName
    super.init(window: nil)
    Logger.log("Init \(autosaveName)", level: .verbose)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func windowDidLoad() {
    super.windowDidLoad()
    loaded = true
    window?.delegate = self

    // title
    window?.title = filterType == MPVProperty.af ? NSLocalizedString("filter.audio_filters", comment: "Audio Filters") : NSLocalizedString("filter.video_filters", comment: "Video Filters")

    window?.contentView?.layoutSubtreeIfNeeded()
    splitView.setPosition(splitView.frame.height - 140, ofDividerAt: 0)
    currentFiltersTableView.delegate = self
    currentFiltersTableView.dataSource = self
    savedFiltersTableView.delegate = self
    savedFiltersTableView.dataSource = self
    savedFiltersTableView.target = self

    newFilterController = NewFilterSheetViewController(filterWindow: self)
    let presetView = newFilterController.view as! FilterPresetContentView
    newFilterSheet = CommonWindow(contentRect: presetView.frame,
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    newFilterSheet.title = "New Filter"
    newFilterSheet.isReleasedWhenClosed = false
    newFilterSheet.isRestorable = false
    newFilterSheet.contentViewController = newFilterController
    newFilterSheet.contentMinSize = NSSize(width: max(450, presetView.presetsWidthConstraint.constant + 212), height: 200)
    newFilterSheet.setFrameAutosaveName("NewFilterWindow")
    newFilterSheet.initialFirstResponder = presetView.tableView

    savedFilters = (Preference.array(for: filterType == MPVProperty.af ? .savedAudioFilters : .savedVideoFilters) ?? []).compactMap(SavedFilter.init(dict:))
    filters = PlayerCore.lastActive.mpv.getFilters(filterType)
    updateSavedFilterStates()
    currentFiltersTableView.reloadData()
    savedFiltersTableView.reloadData()

    saveFilterSheet = FilterShortcutSheet(editing: false, target: self,
      submitAction: #selector(addSavedFilterAction(_:)), cancelAction: #selector(cancelSavingFilterAction(_:)))
    saveFilterNameTextField = saveFilterSheet.nameTextField
    keyRecordView = saveFilterSheet.keyRecordView
    keyRecordViewLabel = saveFilterSheet.keyLabel
    editFilterSheet = FilterShortcutSheet(editing: true, target: self,
      submitAction: #selector(saveEditedFilterAction(_:)), cancelAction: #selector(cancelEditingFilterAction(_:)))
    editFilterNameTextField = editFilterSheet.nameTextField
    editFilterStringTextField = editFilterSheet.filterStringTextField
    editFilterKeyRecordView = editFilterSheet.keyRecordView
    editFilterKeyRecordViewLabel = editFilterSheet.keyLabel

    keyRecordView.delegate = self
    editFilterKeyRecordView.delegate = self

    // Double-click saved filter to edit
    savedFiltersTableView.doubleAction = #selector(self.editSavedFilterAction(_:))

    updateButtonStatus()

    // notifications
    let notiName: Notification.Name = filterType == MPVProperty.af ? .yinaAFChanged : .yinaVFChanged
    NotificationCenter.default.addObserver(self, selector: #selector(reloadTableInMainThread), name: notiName, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(reloadTable), name: .yinaMainWindowChanged, object: nil)
  }

  @objc
  func reloadTableInMainThread() {
    DispatchQueue.main.async {
      self.reloadTable()
    }
  }

  @objc
  func reloadTable() {
    let pc = PlayerCore.lastActive
    // When YINA is terminating player windows are closed, which causes the yinaMainWindowChanged
    // notification to be posted and that results in the observer established above calling this
    // method. Thus this method may be called after YINA has commanded mpv to shutdown. Once mpv has
    // been told to shutdown mpv APIs must not be called as it can trigger a crash in mpv.
    guard pc.info.state.active else { return }
    filters = pc.mpv.getFilters(filterType)
    updateSavedFilterStates()
    currentFiltersTableView.reloadData()
    savedFiltersTableView.reloadData()
  }

  private func updateSavedFilterStates() {
    filterIsSaved = [Bool](repeatElement(false, count: filters.count))
    savedFilters.forEach { savedFilter in
      if let asObject = MPVFilter(rawString: savedFilter.filterString),
         let index = filters.firstIndex(of: asObject) {
        savedFilter.isEnabled = true
        filterIsSaved[index] = true
      } else {
        savedFilter.isEnabled = false
      }
    }
  }

  func setFilters() {
    PlayerCore.lastActive.mpv.setFilters(filterType, filters: filters)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func addFilter(_ filter: MPVFilter) -> Bool {
    if filterType == MPVProperty.vf {
      guard PlayerCore.lastActive.addVideoFilter(filter) else {
        Utility.showAlert("filter.incorrect", sheetWindow: window)
        return false
      }
    } else {
      guard PlayerCore.lastActive.addAudioFilter(filter) else {
        Utility.showAlert("filter.incorrect", sheetWindow: window)
        return false
      }
    }
    filters.append(filter)
    reloadTable()
    return true
  }

  func saveFilter(_ filter: MPVFilter) {
    currentFilter = filter
    window!.beginSheet(saveFilterSheet)
  }

  private func syncSavedFilter() {
    Preference.set(savedFilters.map { $0.toDict() }, for: filterType == MPVProperty.af ? .savedAudioFilters : .savedVideoFilters)
    AppDelegate.shared.menuController?.updateSavedFilters(forType: filterType, from: savedFilters)
    AppEnvironment.defaults.synchronize()
  }

  /// Forms and returns a string representation of the list of configured filters.
  ///
  /// The string returned will contain one line for each filter in the list. If there are no filters configured then the string will be empty. The
  /// string representation returned is intended to be used for developer debugging.
  /// - Returns: String containing the list of configured filters with a prefix indicating the array index of the filter.
  private func filtersAsString() -> String {
    var result = ""
    for (index, filter) in filters.enumerated() {
      if !result.isEmpty {
        result += "\n"
      }
      result += "[\(index)] \(String(reflecting: filter))"
    }
    return result
  }

  // MARK: - IBAction

  @IBAction func addFilterAction(_ sender: Any) {
    saveFilterNameTextField.stringValue = ""
    keyRecordViewLabel.stringValue = ""
    window!.beginSheet(newFilterSheet)
  }

  @IBAction func removeFilterAction(_ sender: Any) {
    let pc = PlayerCore.lastActive
    let selectedRow = currentFiltersTableView.selectedRow
    if selectedRow >= 0 {
      let success: Bool
      if filterType == MPVProperty.vf {
        success = pc.removeVideoFilter(filters[selectedRow], selectedRow)
      } else {
        success = pc.removeAudioFilter(filters[selectedRow], selectedRow)
      }
      if success {
        reloadTable()
        pc.sendOSD(.removeFilter)
        // FIXME: For some reason, after removeFilterAction is called, tableViewSelectionDidChange(_:)
        // for currentFiltersTableView is not called. This is a workaround to ensure
        // tableViewSelectionDidChange(_:) is called.
        currentFiltersTableView.deselectAll(self)
      }
    }
  }

  @IBAction func saveFilterAction(_ sender: NSButton) {
    let row = currentFiltersTableView.row(for: sender)
    saveFilter(filters[row])
  }

  /// User activates or deactivates previously saved audio or video filter
  /// - Parameter sender: A checkbox in lower portion of filter window
  @IBAction func toggleSavedFilterAction(_ sender: NSButton) {
    let row = savedFiltersTableView.row(for: sender)
    let savedFilter = savedFilters[row]
    let pc = PlayerCore.lastActive

    // choose appropriate add/remove functions for .af/.vf
    var addFilterFunction: (String) -> Bool
    var removeFilterFunction: (String, Int) -> Bool
    var removeFilterUsingStringFunction: (String) -> Bool
    if filterType == MPVProperty.vf {
      addFilterFunction = pc.addVideoFilter
      removeFilterFunction = pc.removeVideoFilter
      removeFilterUsingStringFunction = pc.removeVideoFilter
    } else {
      addFilterFunction = pc.addAudioFilter
      removeFilterFunction = pc.removeAudioFilter
      removeFilterUsingStringFunction = pc.removeAudioFilter
    }

    if sender.state == .on {  // user activated filter
      if addFilterFunction(savedFilter.filterString) {
        pc.sendOSD(.addFilter(savedFilter.name))
      }
    } else {  // user deactivated filter
      if let asObject = MPVFilter(rawString: savedFilter.filterString),
         let index = filters.firstIndex(of: asObject) {
        // Remove the filter based on the index within the list of configured filters. This is the
        // preferred way to remove a filter as using the string representation is unreliable due to
        // filters that take multiple parameters having multiple valid string representations.
        if removeFilterFunction(savedFilter.filterString, index) {
          pc.sendOSD(.removeFilter)
        }
      } else {
        // If this occurs the MPVFilter method parseRawParamString may have not been able to parse
        // this kind of filter. Log the issue and attempt to remove the filter using the string
        // representation. For filters that have multiple valid string representations mpv may or
        // may not find and remove the filter.
        Logger.log("""
          Failed to locate filter: \(savedFilter.filterString)\nIn the list of filters:
          \n\(filtersAsString())
          """, level: .warning)
        if removeFilterUsingStringFunction(savedFilter.filterString) {
          pc.sendOSD(.removeFilter)
        }
      }
    }

    reloadTable()
  }

  @IBAction func deleteSavedFilterAction(_ sender: NSButton) {
    let row = savedFiltersTableView.row(for: sender)
    savedFilters.remove(at: row)
    reloadTable()
    syncSavedFilter()
  }

  @IBAction func editSavedFilterAction(_ sender: NSButton) {
    var row = savedFiltersTableView.clickedRow  // if double-clicking
    if row < 0 {
      row = savedFiltersTableView.row(for: sender)  // If using Edit button
    }
    guard row >= 0 && row < savedFiltersTableView.numberOfRows else {
      Logger.log("Cannot edit saved filter! Invalid row: \(row)", level: .verbose)
      return
    }
    Logger.log("Editing saved filter for row \(row)", level: .verbose)
    currentSavedFilter = savedFilters[row]
    editFilterNameTextField.stringValue = currentSavedFilter!.name
    editFilterStringTextField.stringValue = currentSavedFilter!.filterString
    editFilterKeyRecordView.currentKey = currentSavedFilter!.shortcutKey
    editFilterKeyRecordView.currentKeyModifiers = currentSavedFilter!.shortcutKeyModifiers
    editFilterKeyRecordViewLabel.stringValue = currentSavedFilter!.readableShortCutKey
    window!.beginSheet(editFilterSheet)
  }
}

extension FilterWindowController: NSTableViewDelegate, NSTableViewDataSource {

  func numberOfRows(in tableView: NSTableView) -> Int {
    if tableView == currentFiltersTableView {
      return filters.count
    } else {
      return savedFilters.count
    }
  }

  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    if tableView == currentFiltersTableView {
      if tableColumn?.identifier == .key {
        return row.description
      } else if tableColumn?.identifier == .value {
        return filters[at: row]?.stringFormat
      } else {
        return filterIsSaved[at: row] ?? false
      }
    } else {
      return savedFilters[at: row]
    }
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let column = tableColumn else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("FilterCell.\(column.identifier.rawValue)")
    if let cell = tableView.makeView(withIdentifier: identifier, owner: self) { return cell }
    let cell: NSTableCellView
    if tableView == savedFiltersTableView {
      cell = SavedFilterCellView(target: self, toggleAction: #selector(toggleSavedFilterAction(_:)),
        editAction: #selector(editSavedFilterAction(_:)), deleteAction: #selector(deleteSavedFilterAction(_:)))
    } else if column.identifier == .key {
      cell = FilterViewFactory.textCell(aligned: .right)
    } else if column.identifier == .value {
      cell = FilterViewFactory.textCell(editable: true)
    } else {
      cell = FilterViewFactory.saveCell(target: self, action: #selector(saveFilterAction(_:)))
    }
    cell.identifier = identifier
    return cell
  }

  func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
    guard let value = object as? String, tableColumn?.identifier == .value else { return }

    if tableView == currentFiltersTableView {
      if let newFilter = MPVFilter(rawString: value) {
        filters[row] = newFilter
        setFilters()
      } else {
        Utility.showAlert("filter.incorrect", sheetWindow: window)
      }
    }
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    updateButtonStatus()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    updateButtonStatus()
  }

  private func updateButtonStatus() {
    removeButton.isEnabled = currentFiltersTableView.selectedRow >= 0
  }

}

extension FilterWindowController: KeyRecordViewDelegate {

  func keyRecordView(_ view: KeyRecordView, recordedKeyDownWith event: NSEvent) {
    (view == keyRecordView ? keyRecordViewLabel : editFilterKeyRecordViewLabel).stringValue = event.charactersIgnoringModifiers != nil ? event.readableKeyDescription.0 : ""
  }

}


extension FilterWindowController {

  @IBAction func addSavedFilterAction(_ sender: Any) {
    if let currentFilter {
      let filter = SavedFilter(name: saveFilterNameTextField.stringValue,
                               filterString: currentFilter.stringFormat,
                               shortcutKey: keyRecordView.currentKey,
                               modifiers: keyRecordView.currentKeyModifiers)
      savedFilters.append(filter)
      reloadTable()
      syncSavedFilter()
    }
    window!.endSheet(saveFilterSheet)
  }

  @IBAction func cancelSavingFilterAction(_ sender: Any) {
    window!.endSheet(saveFilterSheet)
  }

  @IBAction func saveEditedFilterAction(_ sender: Any) {
    if let currentFilter = currentSavedFilter {
      currentFilter.name = editFilterNameTextField.stringValue
      currentFilter.filterString = editFilterStringTextField.stringValue
      currentFilter.shortcutKey = editFilterKeyRecordView.currentKey
      currentFilter.shortcutKeyModifiers = editFilterKeyRecordView.currentKeyModifiers
      reloadTable()
      syncSavedFilter()
    }
    window!.endSheet(editFilterSheet)
  }

  @IBAction func cancelEditingFilterAction(_ sender: Any) {
    window!.endSheet(editFilterSheet)
  }
}
