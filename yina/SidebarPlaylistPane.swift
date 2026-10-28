//
//  SidebarPlaylistPane.swift
//  yina
//
//  Created by Hechen Li on 2026-06-19.
//  Copyright © 2026 lhc. All rights reserved.
//

fileprivate let PrefixMinLength = 7
fileprivate let FilenameMinLength = 12

fileprivate let MenuItemTagCut = 601
fileprivate let MenuItemTagCopy = 602
fileprivate let MenuItemTagPaste = 603
fileprivate let MenuItemTagDelete = 604


fileprivate let ui = UIHelper.shared

fileprivate extension LayoutValue {
  static let toolbarPaddingVertical = LayoutValue(10, 6)
  static let toolbarPaddingHorizontal = LayoutValue(12, 10)
  static let tableRowHeight = LayoutValue(30, 26)
}


class SidebarPlaylistPane: NSView, SidebarPane {
  let prefObserver = Preference.Observer()
  weak var player: PlayerCore!

  private var scrollView: NSScrollView!
  private let indexTable = NSTableView()
  private let indexDate = NSTextField(labelWithString: "")
  private let indexPane = NSStackView()
  private let playlistColumn = NSStackView()
  private var indexSnapshot: ShowEpisodeIndexReader.Snapshot?
  private var indexEpisodes: [ShowEpisodeIndexReader.Episode] = []
  private var indexExpiry: Timer?
  private var indexGeneration = 0
  private let indexReads: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "YINAReadShowInventory"
    queue.qualityOfService = .utility
    queue.maxConcurrentOperationCount = 1
    return queue
  }()
  var tableView: NSTableView!
  private var totalLengthLabel: NSTextField!

  var horizontalScroll: ((Bool) -> Void)?

  @Atomic private var playlistTotalLengthIsReady = false
  @Atomic private var playlistTotalLength: Double? = nil

  var selectedRows: IndexSet?

  init(player: PlayerCore) {
    self.player = player
    super.init(frame: .zero)

    totalLengthLabel = NSTextField(labelWithString: "")
    totalLengthLabel.textColor = .secondaryLabelColor
    totalLengthLabel.font = .controlContentFont(ofSize: 11)
    totalLengthLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    hideTotalLength()

    self.scrollView = NSScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false

    self.tableView = NSTableView()
    tableView.style = .fullWidth
    tableView.intercellSpacing = .init(width: 4, height: 2)
    tableView.allowsColumnResizing = false
    tableView.allowsEmptySelection = true
    tableView.allowsMultipleSelection = true
    tableView.delegate = self
    tableView.dataSource = self
    tableView.menu = NSMenu()
    tableView.menu!.delegate = self
    tableView.target = self
    tableView.doubleAction = #selector(doubleAction)
    tableView.headerView = nil
    tableView.backgroundColor = .sidebarTableBackground
    tableView.gridStyleMask = [.solidHorizontalGridLineMask]

    tableView.rowHeight = LayoutValue.tableRowHeight.get()
    LayoutValue.tableRowHeight.use { [weak self] val in
      self?.tableView.rowHeight = val
      self?.tableView.reloadData()
      self?.indexTable.rowHeight = val
      self?.indexTable.reloadData()
    }

    let isChosenColumn = NSTableColumn(identifier: .isChosen)
    isChosenColumn.width = 16
    tableView.addTableColumn(isChosenColumn)
    tableView.addTableColumn(NSTableColumn(identifier: .trackName))

    scrollView.documentView = tableView

    let buttonContainer = NSView()
    buttonContainer.translatesAutoresizingMaskIntoConstraints = false

    let buttonStack = ui.hStack(spacing: 8)
    buttonStack.distribution = .gravityAreas

    buttonStack.addView(totalLengthLabel, in: .center)
    buttonContainer.addSubview(buttonStack)
    buttonStack.padding(.horizontal(.toolbarPaddingHorizontal), .vertical(.toolbarPaddingVertical))

    indexTable.headerView = nil
    indexTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("inventory")))
    indexTable.delegate = self
    indexTable.dataSource = self
    indexTable.rowHeight = LayoutValue.tableRowHeight.get()
    indexTable.selectionHighlightStyle = .none
    indexTable.backgroundColor = .clear
    let indexScroll = NSScrollView()
    indexScroll.translatesAutoresizingMaskIntoConstraints = false
    indexScroll.documentView = indexTable
    indexScroll.drawsBackground = false
    indexScroll.hasVerticalScroller = true
    indexScroll.autohidesScrollers = true
    let heading = NSTextField(labelWithString: NSLocalizedString("playlist.unavailable_episodes", value: "Unavailable Episodes", comment: ""))
    heading.font = .preferredFont(forTextStyle: .headline)
    indexDate.font = .preferredFont(forTextStyle: .caption1)
    indexDate.textColor = .secondaryLabelColor
    indexPane.translatesAutoresizingMaskIntoConstraints = false
    indexPane.orientation = .vertical
    indexPane.alignment = .width
    [heading, indexDate, indexScroll].forEach { indexPane.addArrangedSubview($0) }
    indexPane.isHidden = true
    playlistColumn.orientation = .vertical
    playlistColumn.alignment = .width
    playlistColumn.distribution = .fillEqually
    playlistColumn.detachesHiddenViews = true
    [scrollView!, indexPane].forEach { playlistColumn.addArrangedSubview($0) }
    playlistColumn.translatesAutoresizingMaskIntoConstraints = false
    addSubview(playlistColumn)
    addSubview(buttonContainer)
    playlistColumn.padding(.top, .horizontal).spacing(.bottom, to: buttonContainer)
    buttonContainer.padding(.bottom, .horizontal)

    prefObserver.addAll(.playlistShowMetadata, .playlistShowMetadataInMusicMode) { [unowned self] _ in
      updateTable()
    }

    player.observe(.yinaFileLoaded) { [unowned self] _ in
      updateTable()
      readEpisodeIndex()
    }
    player.observe(.yinaPlayerStopped) { [unowned self] _ in
      indexGeneration &+= 1
      indexReads.cancelAllOperations()
      showEpisodeIndex(nil)
    }



    player.observe(.yinaPlaylistChanged) { [unowned self] _ in
      playlistTotalLengthIsReady = false
      updateTable()
    }

    updateTable()
  }

  private func update() {
    updateTable()
  }

  private func updateTable() {
    guard player.info.state.active else { return }
    player.getPlaylist()
    tableView.reloadData()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      indexGeneration &+= 1
      indexReads.cancelAllOperations()
      indexExpiry?.invalidate()
    } else { readEpisodeIndex() }
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    readEpisodeIndex()
  }

  private func readEpisodeIndex() {
    indexGeneration &+= 1
    indexReads.cancelAllOperations()
    showEpisodeIndex(nil)
    guard window != nil, !isHiddenOrHasHiddenAncestor,
          let media = player.info.currentURL, media.isFileURL else { return }
    let generation = indexGeneration
    let operation = BlockOperation()
    operation.addExecutionBlock { [weak self, weak operation] in
      guard operation?.isCancelled == false else { return }
      let snapshot = ShowEpisodeIndexReader.read(for: media)
      guard operation?.isCancelled == false else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.indexGeneration == generation,
              self.player.info.currentURL == media, self.window != nil else { return }
        self.showEpisodeIndex(snapshot)
      }
    }
    indexReads.addOperation(operation)
  }

  private func showEpisodeIndex(_ snapshot: ShowEpisodeIndexReader.Snapshot?) {
    indexExpiry?.invalidate()
    indexSnapshot = snapshot
    let fresh = snapshot?.isFresh() == true
    indexEpisodes = snapshot?.episodes.filter { episode in
      !(fresh && episode.size > 0 && episode.received >= episode.size &&
        episode.exists == true && episode.localSize == episode.size)
    } ?? []
    indexPane.isHidden = indexEpisodes.isEmpty
    indexTable.reloadData()
    guard let snapshot else { indexDate.stringValue = ""; return }
    let date = DateFormatter.localizedString(from: snapshot.capturedAt, dateStyle: .short, timeStyle: .short)
    indexDate.stringValue = snapshot.isFresh() ? "Snapshot from Glass · \(date)" : "Snapshot from Glass · \(date) · status may be out of date"
    if snapshot.isFresh() {
      let delay = snapshot.capturedAt.addingTimeInterval(ShowEpisodeIndexReader.freshnessLimit).timeIntervalSinceNow
      indexExpiry = Timer.scheduledTimer(withTimeInterval: max(0, delay), repeats: false) { [weak self] _ in
        self?.showEpisodeIndex(snapshot)
      }
    }
  }

  private func episodeCell(at row: Int) -> NSView? {
    guard indexEpisodes.indices.contains(row), let snapshot = indexSnapshot else { return nil }
    let episode = indexEpisodes[row]
    let status: String
    if episode.exists == false { status = "Missing locally" }
    else if !snapshot.isFresh() { status = "Status unknown (old snapshot)" }
    else if episode.size > 0 && episode.received >= episode.size {
      status = episode.localSize == nil ? "Local availability not checked" : "Local file size differs from snapshot"
    } else if episode.wanted == false { status = "Not selected" }
    else if episode.wanted == true { status = episode.received > 0 ? "Incomplete" : "Selected" }
    else { status = "Status unknown" }
    let label = NSTextField(labelWithString: "\(episode.path) — \(status)")
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingMiddle
    label.toolTip = episode.path
    return label
  }

  // MARK: - Total length

  private func showTotalLength() {
    guard let playlistTotalLength, playlistTotalLengthIsReady else { return }
    totalLengthLabel.isHidden = false
    if tableView.numberOfSelectedRows > 0 {
      let info = player.info
      let selectedDuration = info.calculateTotalDuration(tableView.selectedRowIndexes)
      totalLengthLabel.stringValue = String(format: NSLocalizedString("playlist.total_length_with_selected", comment: "%@ of %@ selected"),
                                            VideoTime(selectedDuration).stringRepresentation,
                                            VideoTime(playlistTotalLength).stringRepresentation)
    } else {
      totalLengthLabel.stringValue = String(format: NSLocalizedString("playlist.total_length", comment: "%@ in total"),
                                            VideoTime(playlistTotalLength).stringRepresentation)
    }
  }

  private func hideTotalLength() {
    totalLengthLabel.stringValue = ""
    totalLengthLabel.isHidden = true
  }

  func refreshTotalLength() {
    let totalDuration: Double? = player.info.calculateTotalDuration()
    if let duration = totalDuration {
      playlistTotalLengthIsReady = true
      playlistTotalLength = duration
      DispatchQueue.main.async {
        self.showTotalLength()
      }
    } else {
      DispatchQueue.main.async {
        self.hideTotalLength()
      }
    }
  }

  // MARK: - Actions

  @objc func copy(_ sender: NSMenuItem) {
    copyToPasteboard(tableView, writeRowsWith: tableView.selectedRowIndexes, to: .general)
  }

  @objc func doubleAction(_ sender: AnyObject) {
    guard tableView.numberOfSelectedRows > 0 else { return }
    player.playFileInPlaylist(tableView.selectedRow)
    tableView.deselectAll(self)
    tableView.reloadData()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

// MARK: - Table view

extension SidebarPlaylistPane: NSTableViewDelegate, NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    if tableView === indexTable { return indexEpisodes.count }
    return player.info.$playlist.withLock { $0.count }
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    return LayoutValue.tableRowHeight.get()
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard notification.object as? NSTableView === tableView else { return }
    showTotalLength()
  }



  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { tableView !== indexTable }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    if tableView === indexTable { return NSTableRowView() }
    let identifier = NSUserInterfaceItemIdentifier("PlaylistRowView")
    if let rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? PlaylistRowView {
      return rowView
    }
    let rowView = PlaylistRowView()
    rowView.identifier = identifier
    return rowView
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    if tableView === indexTable { return episodeCell(at: row) }

    guard let identifier = tableColumn?.identifier else { return nil }

    let item: MPVPlaylistItem? = player.info.$playlist.withLock { playlist in
      guard row < playlist.count else { return nil }
      return playlist[row]
    }
    guard let item else { return nil }

    if identifier == .isChosen {
      let view = tableView.makeView(withIdentifier: identifier, owner: self) as? PlaylistIsChosenCellView ?? {
        let cell = PlaylistIsChosenCellView()
        cell.identifier = identifier
        return cell
      }()

      let pointer = userInterfaceLayoutDirection == .rightToLeft ?
      Constants.String.blackLeftPointingTriangle :  Constants.String.blackRightPointingTriangle
      view.label.stringValue = item.isPlaying ? pointer : ""
      return view
    } else if identifier == .trackName {
      let view = tableView.makeView(withIdentifier: identifier, owner: self) as? PlaylistTrackCellView ?? {
        let cell = PlaylistTrackCellView()
        cell.identifier = identifier
        return cell
      }()

      view.update(pane: self, player: player, item: item, row: row)
      return view
    }

    return nil
  }

  // Drag and Drop
  
  func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
    if tableView === self.tableView {
      copyToPasteboard(tableView, writeRowsWith: rowIndexes, to: pboard)
      return true
    }
    return false
  }

  func copyToPasteboard(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) {
    do {
      let indexesData = try NSKeyedArchiver.archivedData(withRootObject: rowIndexes, requiringSecureCoding: true)
      let filePaths = player.info.$playlist.withLock { playlist in
        rowIndexes.map { playlist[$0].filename }
      }
      pboard.declareTypes([.iinaPlaylistItem, .nsFilenames], owner: tableView)
      pboard.setData(indexesData, forType: .iinaPlaylistItem)
      pboard.setPropertyList(filePaths, forType: .nsFilenames)
    } catch {
      // Internal error, archivedData should not fail.
      Logger.log("Failed to copy from playlist to pasteboard: \(error)", level: .error,
                 subsystem: player.subsystem)
    }
  }

}

// MARK: - Context menu

extension SidebarPlaylistPane: NSMenuDelegate, NSMenuItemValidation {
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {

    switch menuItem.tag {
    case MenuItemTagCopy:
      return tableView.selectedRow != -1
    case MenuItemTagCut, MenuItemTagPaste, MenuItemTagDelete:
      return false
    default:
      return menuItem.isEnabled
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    let selectedRow = tableView.selectedRowIndexes
    let clickedRow = tableView.clickedRow
    var target = IndexSet()

    if clickedRow != -1 {
      if selectedRow.contains(clickedRow) {
        target = selectedRow
      } else {
        target.insert(clickedRow)
      }
    }

    selectedRows = target
    menu.removeAllItems()
    let items = buildMenu(forRows: target).items
    for item in items {
      menu.addItem(item)
    }
  }

  @IBAction func contextMenuPlayInNewWindow(_ sender: NSMenuItem) {
    let files = {
      self.player.info.$playlist.withLock { playlist in
        self.selectedRows!.enumerated().map { (_, i) in
          URL(fileURLWithPath: playlist[i].filename)
        }}
    }()
    PlayerCore.newPlayerCore.openURLs(files)
  }

  @IBAction func contextMenuDeleteFile(_ sender: NSMenuItem) {
    guard let selectedRows else { return }
    Logger.log("User chose to delete files from playlist at indexes: \(selectedRows.map{$0})", subsystem: player.subsystem)

    var successes = IndexSet()
    for index in selectedRows {
      let playlistItem = player.info.$playlist.withLock { $0[index] }
      guard !playlistItem.isNetworkResource else { continue }
      let url = URL(fileURLWithPath: playlistItem.filename)
      do {
        Logger.log("Trashing row \(index): \(url.standardizedFileURL)", subsystem: player.subsystem)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        successes.insert(index)
      } catch let error {
        Utility.showAlert("playlist.error_deleting", arguments: [error.localizedDescription])
      }
    }
    if !successes.isEmpty {
      player.playlistRemove(successes)
    }
  }

  @IBAction func contextMenuDeleteFileAfterPlayback(_ sender: NSMenuItem) {
    // WIP
  }

  @IBAction func contextMenuShowInFinder(_ sender: NSMenuItem) {
    guard let selectedRows else { return }
    var urls: [URL] = []
    player.info.$playlist.withLock { playlist in
      for index in selectedRows {
        if !playlist[index].isNetworkResource {
          urls.append(URL(fileURLWithPath: playlist[index].filename))
        }
      }
    }
    tableView.deselectAll(nil)
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  @IBAction func contextMenuAddSubtitle(_ sender: NSMenuItem) {
    guard let selectedRows, let index = selectedRows.first else { return }
    let filename = player.info.$playlist.withLock { $0[index].filename }
    let fileURL = URL(fileURLWithPath: filename).deletingLastPathComponent()
    Utility.quickMultipleOpenPanel(title: NSLocalizedString("alert.choose_media_file.title", comment: "Choose Media File"), dir: fileURL, canChooseDir: true) { subURLs in
      for subURL in subURLs {
        guard Utility.supportedFileExt[.sub]!.contains(subURL.pathExtension.lowercased()) else { return }
        self.player.info.$matchedSubs.withLock { $0[filename, default: []].append(subURL) }
      }
      self.tableView.reloadData(forRowIndexes: selectedRows, columnIndexes: IndexSet(integersIn: 0...1))
    }
  }

  @IBAction func contextMenuWrongSubtitle(_ sender: NSMenuItem) {
    guard let selectedRows else { return }
    for index in selectedRows {
      let filename = player.info.$playlist.withLock { $0[index].filename }
      player.info.$matchedSubs.withLock { $0[filename]?.removeAll() }
      tableView.reloadData(forRowIndexes: selectedRows, columnIndexes: IndexSet(integersIn: 0...1))
    }
  }

  @IBAction func contextOpenInBrowser(_ sender: NSMenuItem) {
    guard let selectedRows else { return }
    selectedRows.forEach { i in
      let info = player.info.playlist[i]
      if info.isNetworkResource, let url = URL(string: info.filename) {
        NSWorkspace.shared.open(url)
      }
    }
  }

  @IBAction func contextCopyURL(_ sender: NSMenuItem) {
    guard let selectedRows else { return }
    let urls = selectedRows.compactMap { i -> String? in
      let info = player.info.playlist[i]
      return info.isNetworkResource ? info.filename : nil
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([urls.joined(separator: "\n") as NSString])
  }

  private func buildMenu(forRows rows: IndexSet) -> NSMenu {
    let result = NSMenu()
    let isSingleItem = rows.count == 1

    if !rows.isEmpty {
      let matchedSubCount = rows.map { index in
        player.info.$playlist.withLock {
          player.info.getMatchedSubs($0[index].filename)?.count ?? 0
        }
      }.reduce(0, +)
      let title: String = isSingleItem ?
        player.info.$playlist.withLock { $0[rows.first!] }.filenameForDisplay:
        String(format: NSLocalizedString("pl_menu.title_multi", comment: "%d Items"), rows.count)

      result.addItem(withTitle: title)
      result.addItem(NSMenuItem.separator())
      result.addItem(.sectionHeader(title: NSLocalizedString("pl_menu.playback", comment: "Playback")))
      result.addItem(withTitle: NSLocalizedString("pl_menu.play_in_new_window", comment: "Play in New Window"), action: #selector(self.contextMenuPlayInNewWindow(_:)))

      if !player.isInMiniPlayer && (isSingleItem || matchedSubCount != 0) {
        result.addItem(NSMenuItem.separator())
        result.addItem(.sectionHeader(title: String(format: NSLocalizedString("pl_menu.subtitles", comment: "Subtitles (%@ loaded)"), matchedSubCount)))
        if isSingleItem {
          result.addItem(withTitle: NSLocalizedString("pl_menu.add_sub", comment: "Add Subtitle…"), action: #selector(self.contextMenuAddSubtitle(_:)))
        }
        if matchedSubCount != 0 {
          result.addItem(withTitle: NSLocalizedString("pl_menu.wrong_sub", comment: "Wrong Subtitle"), action: #selector(self.contextMenuWrongSubtitle(_:)))
        }
      }

      result.addItem(NSMenuItem.separator())
      // network resources related operations
      let networkCount = player.info.$playlist.withLock { playlist in
        rows.filter { playlist[$0].isNetworkResource }
      }.count
      if networkCount != 0 {
        result.addItem(.sectionHeader(title: NSLocalizedString("pl_menu.network_resources", comment: "Network Resources")))
        result.addItem(withTitle: NSLocalizedString("pl_menu.browser", comment: "Open in Browser"), action: #selector(self.contextOpenInBrowser(_:)))
        result.addItem(withTitle: NSLocalizedString(networkCount == 1 ? "pl_menu.copy_url" : "pl_menu.copy_url_multi", comment: "Copy URL(s)"), action: #selector(self.contextCopyURL(_:)))
        result.addItem(NSMenuItem.separator())
      }
      // file related operations
      let localCount = rows.count - networkCount
      if localCount != 0 {
        result.addItem(.sectionHeader(title: NSLocalizedString("pl_menu.file_operations", comment: "File Operations")))
        result.addItem(withTitle: NSLocalizedString(localCount == 1 ? "pl_menu.delete" : "pl_menu.delete_multi", comment: "Delete"), action: #selector(self.contextMenuDeleteFile(_:)))
        // result.addItem(withTitle: NSLocalizedString(isSingleItem ? "pl_menu.delete_after_play" : "pl_menu.delete_after_play_multi", comment: "Delete After Playback"), action: #selector(self.contextMenuDeleteFileAfterPlayback(_:)))

        result.addItem(withTitle: NSLocalizedString("pl_menu.show_in_finder", comment: "Show in Finder"), action: #selector(self.contextMenuShowInFinder(_:)))
        result.addItem(NSMenuItem.separator())
      }
    }

    // menu items from plugins
    var hasPluginMenuItems = false
    let filenames = Array(rows)
    let pluginMenuItems = player.plugins.map {
      plugin -> (JavascriptPluginInstance, [JavascriptPluginMenuItem]) in
      if let builder = (plugin.apis["playlist"] as! JavascriptAPIPlaylist).menuItemBuilder?.value,
        let value = builder.call(withArguments: [filenames]),
        value.isObject,
        let items = value.toObject() as? [JavascriptPluginMenuItem] {
        hasPluginMenuItems = true
        return (plugin, items)
      }
      return (plugin, [])
    }
    if hasPluginMenuItems {
      result.addItem(withTitle: NSLocalizedString("pl_menu.plugin", comment: "Plugin"))
      for (plugin, items) in pluginMenuItems {
        for item in items {
          add(menuItemDef: item, to: result, for: plugin)
        }
      }
      result.addItem(NSMenuItem.separator())
    }

    return result
  }

  @discardableResult
  private func add(menuItemDef item: JavascriptPluginMenuItem,
                   to menu: NSMenu,
                   for plugin: JavascriptPluginInstance) -> NSMenuItem {
    if (item.isSeparator) {
      let item = NSMenuItem.separator()
      menu.addItem(item)
      return item
    }

    let menuItem: NSMenuItem
    if item.action == nil {
      menuItem = menu.addItem(withTitle: item.title, action: nil, target: plugin, obj: item)
    } else {
      menuItem = menu.addItem(withTitle: item.title,
                              action: #selector(plugin.playlistMenuItemAction(_:)),
                              target: plugin,
                              obj: item)
    }

    menuItem.isEnabled = item.enabled
    menuItem.state = item.selected ? .on : .off
    if !item.items.isEmpty {
      menuItem.submenu = NSMenu()
      for submenuItem in item.items {
        add(menuItemDef: submenuItem, to: menuItem.submenu!, for: plugin)
      }
    }
    return menuItem
  }
}


class PlaylistIsChosenCellView: NSTableCellView {
  let label: NSTextField

  override init(frame frameRect: NSRect) {
    self.label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    super.init(frame: frameRect)
    addSubview(label)
    label.padding(.horizontal(2)).center(.y)
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}


class PlaylistTrackCellView: NSTableCellView {
  private var stackView: NSStackView!
  private var prefixBtn: PlaylistPrefixButton!
  private var trackNameLabel: NSTextField!
  private var infoLabel: NSTextField!
  private var durationLabel: NSTextField!

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    self.prefixBtn = PlaylistPrefixButton()
    self.trackNameLabel = ui.label("")
    trackNameLabel.lineBreakMode = .byTruncatingMiddle
    trackNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    self.infoLabel = ui.label("", font: .boldSystemFont(ofSize: 11), isSecondary: true)
    self.durationLabel = ui.label("", isSmall: true, isSecondary: true, canCompress: false)
    self.stackView = ui.hStack(
      spacing: 4,
      prefixBtn,
      trackNameLabel,
      ui.flexibleSpace(),
      infoLabel,
      durationLabel,
    )
    stackView.setCustomSpacing(0, after: prefixBtn)

    addSubview(stackView)
    stackView.padding(.horizontal(2), .vertical)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setPrefix(_ prefix: String?) {
    if let prefix {
      stackView.setVisibilityPriority(.mustHold, for: prefixBtn)
      prefixBtn.text = prefix
    } else {
      stackView.setVisibilityPriority(.notVisible, for: prefixBtn)
    }
  }

  private func setAdditionalInfo(_ string: String?) {
    if let string {
      stackView.setVisibilityPriority(.mustHold, for: infoLabel)
      infoLabel.stringValue = string
      infoLabel.toolTip = string
    } else {
      stackView.setVisibilityPriority(.notVisible, for: infoLabel)
      infoLabel.stringValue = ""
    }
  }

  private func setTitle(_ title: String) {
    trackNameLabel.stringValue = title
    trackNameLabel.toolTip = title
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    setPrefix(nil)
    setAdditionalInfo(nil)
  }

  func update(pane: SidebarPlaylistPane, player: PlayerCore, item: MPVPlaylistItem, row: Int) {
    // file name
    let filename = item.filenameForDisplay
    let displayStr: String = NSString(string: filename).deletingPathExtension

    func getCachedMetadata() -> (artist: String, title: String)? {
      guard Preference.bool(for: .playlistShowMetadata) else { return nil }
      if Preference.bool(for: .playlistShowMetadataInMusicMode) && !player.isInMiniPlayer {
        return nil
      }
      guard let metadata = player.info.getCachedMetadata(item.filename) else { return nil }
      guard let artist = metadata.artist, let title = metadata.title else { return nil }
      return (artist, title)
    }

    if let prefix = player.info.currentVideosInfo.first(where: { $0.path == item.filename })?.prefix,
       !prefix.isEmpty,
       prefix.count <= displayStr.count,  // check whether prefix length > filename length
       prefix.count >= PrefixMinLength,
       filename.count > FilenameMinLength {
      setPrefix(prefix)
      setTitle(String(filename[filename.index(filename.startIndex, offsetBy: prefix.count)...]))
    } else {
      setPrefix(nil)
      setTitle(filename)
    }
    // playback progress and duration
    durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    durationLabel.stringValue = ""
    player.playlistQueue.async { [weak self] in
      guard let self else { return }
      if let (artist, title) = getCachedMetadata() {
        DispatchQueue.main.async {
          self.setTitle(title)
          self.setAdditionalInfo(artist)
        }
      }
      if let cached = player.info.getCachedVideoDurationAndProgress(item.filename),
         let duration = cached.duration {
        // if it's cached
        if duration > 0 {
          // if FFmpeg got the duration successfully
          DispatchQueue.main.async {
            self.durationLabel.stringValue = VideoTime(duration).stringRepresentation
            if let progress = cached.progress,
               let rowView = self.superview as? PlaylistRowView {
              rowView.percentage = progress / duration
              rowView.needsDisplay = true
            }
          }
          pane.refreshTotalLength()
        }
      } else {
        // get related data and schedule a reload
        if Preference.bool(for: .prefetchPlaylistVideoDuration) {
          player.refreshCachedVideoInfo(forVideoPath: item.filename)
          // Only schedule a reload if data was obtained and cached to avoid looping
          if let cached = player.info.getCachedVideoDurationAndProgress(item.filename),
             let duration = cached.duration, duration > 0 {
            // if FFmpeg got the duration successfully
            pane.refreshTotalLength()
            DispatchQueue.main.async {
              pane.tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0...1))
            }
          }
        }
      }
    }
  }
}


class PlaylistRowView: NSTableRowView {
  var percentage: Double = 0
  private static let barHeight: CGFloat = 3

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let width = bounds.width * CGFloat(percentage)
    guard width > 0 else { return }
    let rect = NSRect(x: 0, y: bounds.height - Self.barHeight, width: width, height: Self.barHeight)
    let fillColor = NSColor.controlAccentColor.blended(withFraction: 0.2, of: .white) ?? .controlAccentColor
    fillColor.setFill()
    NSBezierPath(rect: rect).fill()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    percentage = 0
    needsDisplay = true
  }
}


class PlaylistPrefixButton: NSButton {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    bezelStyle = .smallSquare
    isBordered = false
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  var text = "" {
    didSet {
      refresh()
    }
  }

  var isFolded = true {
    didSet {
      refresh()
    }
  }

  override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
    isFolded = !isFolded
    return true
  }

  private func refresh() {
    self.title = isFolded ? "…" : text
  }
}
