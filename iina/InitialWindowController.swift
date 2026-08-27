//
//  InitialWindowController.swift
//  iina
//
//  Created by lhc on 27/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa
import UniformTypeIdentifiers

fileprivate extension NSUserInterfaceItemIdentifier {
  static let openFile = NSUserInterfaceItemIdentifier("openFile")
  static let openURL = NSUserInterfaceItemIdentifier("openURL")
}

fileprivate class GrayHighlightRowView: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    if self.selectionHighlightStyle != .none {
      let selectionRect = NSInsetRect(self.bounds, 0, 0)
      NSColor.initialWindowLastFileBackground.setFill()
      let selectionPath = NSBezierPath.init(roundedRect: selectionRect, xRadius: 4, yRadius: 4)
      selectionPath.fill()
    }
  }

  func setHoverHighlight() {
    self.wantsLayer = true
    self.layer?.cornerRadius = 6
    self.layer?.backgroundColor = NSColor.initialWindowActionButtonBackgroundHover.cgColor
  }

  func unsetHoverHighlight() {
    self.wantsLayer = true
    self.layer?.cornerRadius = 6
    self.layer?.backgroundColor = NSColor.initialWindowActionButtonBackground.cgColor
  }
}

class InitialWindowController: NSWindowController {

  private struct RecentDocument {
    let url: URL
    var isAvailable: Bool
  }

  override var windowNibName: NSNib.Name {
    return NSNib.Name("InitialWindowController")
  }

  weak var player: PlayerCore!

  var loaded = false

  @IBOutlet weak var recentFilesTableView: NSTableView!
  @IBOutlet weak var appIcon: NSImageView!
  @IBOutlet weak var versionLabel: NSTextField!
  @IBOutlet weak var visualEffectView: NSVisualEffectView!
  @IBOutlet weak var leftOverlayView: NSView!
  @IBOutlet weak var mainView: NSView!
  @IBOutlet weak var betaIndicatorView: BetaIndicatorView!
  @IBOutlet weak var betaTextField: NSTextField!
  @IBOutlet weak var lastFileContainerView: InitialWindowViewActionButton!
  @IBOutlet weak var lastFileIcon: NSImageView!
  @IBOutlet weak var lastFileNameLabel: NSTextField!
  @IBOutlet weak var lastPositionLabel: NSTextField!
  @IBOutlet weak var recentFilesTableTopConstraint: NSLayoutConstraint!

  private let observedPrefKeys: [Preference.Key] = [.themeMaterial]
  private var currentlyHoveredRow: GrayHighlightRowView?
  private let availabilityQueue = DispatchQueue(label: "IINAInitialWindowAvailability", qos: .utility)
  private var availabilityRefreshTimer: Timer?
  private var availabilityCheckGeneration = 0
  private var isCheckingAvailability = false

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath, let change else { return }

    switch keyPath {

    case Preference.Key.themeMaterial.rawValue:
      if let newValue = change[.newKey] as? Int {
        setMaterial(Preference.Theme(rawValue: newValue))
      }

    default:
      return
    }
  }

  private var recentDocuments: [RecentDocument] = []
  private var lastPlaybackURL: URL?

  init(playerCore: PlayerCore) {
    self.player = playerCore
    super.init(window: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func documentIdentity(_ url: URL) -> String {
    url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
  }

  private var lastPlaybackCandidateURL: URL? {
    guard Preference.bool(for: .recordRecentFiles),
          Preference.bool(for: .resumeLastPosition) else { return nil }
    return Preference.url(for: .iinaLastPlayedFilePath)
  }

  private static func isDocumentAvailable(_ url: URL) -> Bool {
    !url.isFileURL || FileManager.default.fileExists(atPath: url.path)
  }

  private func makeRecentDocumentsList() -> [RecentDocument] {
    let documentController = NSDocumentController.shared
    let appKitRecents = documentController.recentDocumentURLs
    let maximumCount = max(appKitRecents.count, Int(documentController.maximumRecentDocumentCount))
    let lastPlaybackIdentity = lastPlaybackURL.map(documentIdentity)
    let previousAvailability = Dictionary(uniqueKeysWithValues: recentDocuments.map {
      (documentIdentity($0.url), $0.isAvailable)
    })
    var seen = Set<String>()
    var urls: [URL] = []

    func append(_ url: URL) {
      guard urls.count < maximumCount else { return }
      let identity = documentIdentity(url)
      guard identity != lastPlaybackIdentity, seen.insert(identity).inserted else { return }
      urls.append(url)
    }

    if Preference.bool(for: .recordRecentFiles) {
      HistoryController.shared.$history.withLock { history in
        history.map(\.url).forEach(append)
      }
    }
    appKitRecents.forEach(append)

    return urls.map { url in
      let identity = documentIdentity(url)
      return RecentDocument(url: url,
                            isAvailable: !url.isFileURL || previousAvailability[identity] == true)
    }
  }

  override func windowDidLoad() {
    super.windowDidLoad()
    loaded = true

    appIcon.unregisterDraggedTypes()

    window?.titlebarAppearsTransparent = true
    window?.titleVisibility = .hidden
    window?.isMovableByWindowBackground = true

    window?.contentView?.registerForDraggedTypes([.nsFilenames, .nsURL, .string])

    mainView.wantsLayer = true

    let infoDict = InfoDictionary.shared
    let (version, build) = infoDict.version

    betaTextField.stringValue = infoDict.buildType.description

    switch infoDict.buildType {
    case .release:
      versionLabel.stringValue = version
    case .beta:
      versionLabel.stringValue = "\(version) (build \(build))"
      betaIndicatorView.isHidden = false
    case .nightly:
      versionLabel.stringValue = "\(version)+g\(InfoDictionary.shared.shortCommitSHA ?? "")"
      betaIndicatorView.isHidden = false
    case .debug:
      versionLabel.stringValue = "\(version)+g\(InfoDictionary.shared.shortCommitSHA ?? "")"
      betaIndicatorView.isHidden = false
    }

    loadLastPlaybackInfo()

    recentFilesTableView.delegate = self
    recentFilesTableView.dataSource = self
    recentFilesTableView.action = #selector(self.onTableClicked)
    recentFilesTableView.addTrackingArea(NSTrackingArea(rect: recentFilesTableView.bounds,
                                        options: [.activeInKeyWindow, .mouseMoved], owner: self, userInfo: nil))
    recentFilesTableView.addTrackingArea(NSTrackingArea(rect: recentFilesTableView.bounds,
                                                        options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self, userInfo: nil))

    setMaterial(Preference.enum(for: .themeMaterial))

    observedPrefKeys.forEach { key in
      UserDefaults.standard.addObserver(self, forKeyPath: key.rawValue, options: .new, context: nil)
    }
    NotificationCenter.default.addObserver(self, selector: #selector(historyDidUpdate),
                                           name: .iinaHistoryUpdated, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(initialWindowWillClose),
                                           name: NSWindow.willCloseNotification, object: window)
    reloadData()
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    startAvailabilityRefresh()
  }

  @objc private func historyDidUpdate() {
    guard window?.isVisible == true else { return }
    reloadData()
  }

  @objc private func initialWindowWillClose() {
    stopAvailabilityRefresh()
  }

  private func startAvailabilityRefresh() {
    refreshRecentDocumentAvailability()
    guard availabilityRefreshTimer == nil else { return }
    availabilityRefreshTimer = Timer.scheduledTimerInCommonMode(withTimeInterval: 5) { [weak self] _ in
      guard let self else { return }
      guard self.window?.isVisible == true else {
        self.stopAvailabilityRefresh()
        return
      }
      self.refreshRecentDocumentAvailability()
    }
  }

  private func stopAvailabilityRefresh() {
    availabilityRefreshTimer?.invalidate()
    availabilityRefreshTimer = nil
  }

  private func refreshRecentDocumentAvailability() {
    let lastPlaybackCandidate = lastPlaybackCandidateURL
    guard !isCheckingAvailability,
          lastPlaybackCandidate != nil || !recentDocuments.isEmpty else { return }
    isCheckingAvailability = true
    let generation = availabilityCheckGeneration
    let urls = recentDocuments.map(\.url)
    let wasShowingLastPlayback = lastPlaybackURL != nil

    availabilityQueue.async { [weak self] in
      let lastPlaybackIsAvailable = lastPlaybackCandidate.map(Self.isDocumentAvailable) ?? false
      let availability = urls.map(Self.isDocumentAvailable)
      DispatchQueue.main.async {
        guard let self else { return }
        self.isCheckingAvailability = false
        guard generation == self.availabilityCheckGeneration else {
          if self.window?.isVisible == true {
            self.refreshRecentDocumentAvailability()
          }
          return
        }
        if wasShowingLastPlayback != lastPlaybackIsAvailable {
          self.reloadData()
          return
        }

        var changedRows = IndexSet()
        for index in self.recentDocuments.indices where self.recentDocuments[index].isAvailable != availability[index] {
          self.recentDocuments[index].isAvailable = availability[index]
          changedRows.insert(index)
        }
        guard !changedRows.isEmpty else { return }
        for row in changedRows {
          self.recentFilesTableView.rowView(atRow: row, makeIfNecessary: false)?.alphaValue =
            self.recentDocuments[row].isAvailable ? 1 : 0.45
        }
        self.recentFilesTableView.reloadData(forRowIndexes: changedRows,
                                             columnIndexes: IndexSet(integersIn: 0..<self.recentFilesTableView.numberOfColumns))
        if self.recentFilesTableView.selectedRow >= 0,
           !self.recentDocuments[self.recentFilesTableView.selectedRow].isAvailable {
          self.recentFilesTableView.deselectAll(nil)
        }
        self.selectFirstRecentDocumentIfNeeded()
      }
    }
  }

  private func selectFirstRecentDocumentIfNeeded() {
    guard lastFileContainerView.isHidden, recentFilesTableView.selectedRow == -1,
          let firstAvailable = recentDocuments.firstIndex(where: \.isAvailable) else { return }
    recentFilesTableView.selectRowIndexes(IndexSet(integer: firstAvailable), byExtendingSelection: false)
  }

  private func setMaterial(_ theme: Preference.Theme?) {
    guard let window, let theme else { return }
    window.appearance = NSAppearance(iinaTheme: theme)
    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = window.effectiveAppearance.isDark ?
      [NSColor.black.withAlphaComponent(0.4).cgColor, NSColor.black.withAlphaComponent(0).cgColor] :
      [NSColor.black.withAlphaComponent(0.1).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
    leftOverlayView.wantsLayer = true
    leftOverlayView.layer = gradientLayer
  }

  @objc func onTableClicked() {
    openRecentItemFromTable(recentFilesTableView.clickedRow)
  }

  private func openRecentItemFromTable(_ rowIndex: Int) {
    if let document = recentDocuments[at: rowIndex], document.isAvailable {
      player.openURL(document.url)
    }
  }

  func loadLastPlaybackInfo() {
    if let lastFile = lastPlaybackCandidateURL,
      Self.isDocumentAvailable(lastFile) {
      // if last file exists
      lastPlaybackURL = lastFile
      lastFileContainerView.isHidden = false
      lastFileContainerView.normalBackground = NSColor.initialWindowLastFileBackground
      lastFileContainerView.hoverBackground = NSColor.initialWindowLastFileBackgroundHover
      lastFileContainerView.pressedBackground = NSColor.initialWindowLastFileBackgroundPressed
      lastFileIcon.image = .sf("clock.arrow.trianglehead.counterclockwise.rotate.90", "clock")
      lastFileNameLabel.stringValue = lastFile.lastPathComponent
      let lastPosition = Preference.double(for: .iinaLastPlayedFilePosition)
      lastPositionLabel.stringValue = VideoTime(lastPosition).stringRepresentation
      recentFilesTableTopConstraint.constant = 42
    } else {
      lastPlaybackURL = nil
      lastFileContainerView.isHidden = true
      recentFilesTableTopConstraint.constant = 24
    }
  }

  func reloadData() {
    loadLastPlaybackInfo()
    recentDocuments = makeRecentDocumentsList()
    availabilityCheckGeneration += 1
    recentFilesTableView.reloadData()
    if window?.isVisible == true {
      refreshRecentDocumentAvailability()
    }

    if Logger.isEmitting(.verbose) {
      let last = lastPlaybackURL.flatMap { $0.resolvingSymlinksInPath().path } ?? "<none>"
      Logger.log("InitialWindow.reloadData(): LastPlaybackURL: \(last)", level: .verbose)

      for (index, url) in NSDocumentController.shared.recentDocumentURLs.enumerated() {
        Logger.log("InitialWindow.reloadData(): RecentDocuments_Unfiltered[\(index)]: \(url.resolvingSymlinksInPath().path)", level: .verbose)
      }

      for (index, document) in recentDocuments.enumerated() {
        Logger.log("InitialWindow.reloadData(): Loaded RecentDocuments[\(index)]: \(document.url.path), available: \(document.isAvailable)", level: .verbose)
      }
    }
    
    selectFirstRecentDocumentIfNeeded()
  }
}

extension InitialWindowController: NSTableViewDelegate, NSTableViewDataSource {

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    // uses custom highlight for table row
    let rowView = GrayHighlightRowView()
    rowView.alphaValue = recentDocuments[row].isAvailable ? 1 : 0.45
    return rowView
  }

  func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
    IndexSet(proposedSelectionIndexes.filter { recentDocuments[$0].isAvailable })
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    updateLastFileButtonHighlight()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    return recentDocuments.count
  }

  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    let document = recentDocuments[row]
    let url = document.url
    let icon: NSImage
    if document.isAvailable {
      icon = NSWorkspace.shared.icon(forFile: url.path)
    } else {
      let contentType = UTType(filenameExtension: url.pathExtension) ?? .data
      icon = NSWorkspace.shared.icon(for: contentType)
    }
    return [
      "filename": url.lastPathComponent,
      "docIcon": icon
    ] as [String: Any]
  }

  // facilitates highlight on hover
  override func mouseMoved(with event: NSEvent) {
    let mouseLocation = event.locationInWindow
    let point = recentFilesTableView.convert(mouseLocation, from: nil)
    let rowIndex = recentFilesTableView.row(at: point)

    if rowIndex >= 0 {
      guard let rowView = recentFilesTableView.rowView(atRow: rowIndex, makeIfNecessary: false) as? GrayHighlightRowView else {
        return
      }

      if (currentlyHoveredRow == rowView) {
        return
      }

      rowView.setHoverHighlight()
      currentlyHoveredRow?.unsetHoverHighlight()
      currentlyHoveredRow = rowView
    } else {
      currentlyHoveredRow?.unsetHoverHighlight()
      currentlyHoveredRow = nil
    }
  }

  override func mouseExited(with event: NSEvent) {
    currentlyHoveredRow?.unsetHoverHighlight()
    currentlyHoveredRow = nil
  }

  override func keyDown(with event: NSEvent) {
    let keyChar = KeyCodeHelper.keyMap[event.keyCode]?.0
    switch keyChar {
      case "ENTER", "KP_ENTER":  // RETURN or (keypad ENTER)
        if recentFilesTableView.selectedRow >= 0 {
          // If user selected a row in the table using the keyboard, use that
          openRecentItemFromTable(recentFilesTableView.selectedRow)
        } else if let lastURL = lastPlaybackURL {
          // If no row selected in table, most recent file button is selected. Use that if it exists
          player.openURL(lastURL)
        } else if recentFilesTableView.numberOfRows > 0 {
          // Most recent file no longer exists? Try to load next one
          openRecentItemFromTable(0)
        }
      case "DOWN":  // DOWN arrow
        if recentDocuments.count == 0 || (recentFilesTableView.selectedRow >= recentFilesTableView.numberOfRows - 1) {
          super.keyDown(with: event)  // invalid command: beep at user
        } else {
          // default: let recentFilesTableView handle it
          recentFilesTableView.keyDown(with: event)
        }
      case "UP":  // UP arrow
        if !lastFileContainerView.isHidden {   // recent file btn is displayed?
          if recentFilesTableView.selectedRow == -1 {  // ...and recent file btn already highlighted?
            super.keyDown(with: event)  // invalid command: beep at user
            return
          } else if recentFilesTableView.selectedRow == 0 {  // ... top row of table is highlighted?
            // yes: deselect all rows of table. This will fire selectionChanged which will highlight lastFileContainerView
            recentFilesTableView.selectRowIndexes(IndexSet(), byExtendingSelection: false)
            return
          }
        } else if recentFilesTableView.selectedRow == 0 || recentDocuments.isEmpty {
          super.keyDown(with: event)  // invalid command: beep at user
          return
        }
        // default: let recentFilesTableView handle it
        recentFilesTableView.keyDown(with: event)
      default:
        super.keyDown(with: event)
    }
  }

  func updateLastFileButtonHighlight() {
    if recentFilesTableView.selectedRow >= 0 {
      // remove "LastFile" button highlight
      lastFileContainerView.layer?.backgroundColor = NSColor.initialWindowActionButtonBackground.cgColor
    } else {
      // re-highlight "LastFile" button
      lastFileContainerView.layer?.backgroundColor = NSColor.initialWindowLastFileBackground.cgColor
    }
  }

}


class InitialWindowContentView: NSView {

  var player: PlayerCore {
    return (window!.windowController as! InitialWindowController).player
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    return player.acceptFromPasteboard(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return player.openFromPasteboard(sender)
  }

}


class InitialWindowViewActionButton: NSView {

  var normalBackground = NSColor.initialWindowActionButtonBackground {
    didSet {
      self.layer?.backgroundColor = normalBackground.cgColor
    }
  }
  var hoverBackground = NSColor.initialWindowActionButtonBackgroundHover
  var pressedBackground = NSColor.initialWindowActionButtonBackgroundPressed

  override func awakeFromNib() {
    self.wantsLayer = true
    self.layer?.cornerRadius = 6
    self.layer?.backgroundColor = normalBackground.cgColor
    self.addTrackingArea(NSTrackingArea(rect: self.bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self, userInfo: nil))
  }

  override func mouseEntered(with event: NSEvent) {
    if let windowController = window?.windowController as? InitialWindowController {
      if windowController.recentFilesTableView.selectedRow >= 0 {
        self.layer?.backgroundColor = NSColor.initialWindowActionButtonBackgroundHover.cgColor
      } else {
        self.layer?.backgroundColor = hoverBackground.cgColor
      }
    }
  }

  override func mouseExited(with event: NSEvent) {
    self.layer?.backgroundColor = normalBackground.cgColor
    if let windowController = window?.windowController as? InitialWindowController {
      windowController.updateLastFileButtonHighlight()
    }
  }

  override func mouseDown(with event: NSEvent) {
    self.layer?.backgroundColor = pressedBackground.cgColor
    if self.identifier == .openFile {
      AppDelegate.shared.openFile(self)
    } else if self.identifier == .openURL {
      AppDelegate.shared.openURL(self)
    } else {
      if let lastFile = Preference.url(for: .iinaLastPlayedFilePath),
        let windowController = window?.windowController as? InitialWindowController {
        windowController.player.openURL(lastFile)
      }
    }
  }

  override func mouseUp(with event: NSEvent) {
    self.layer?.backgroundColor = hoverBackground.cgColor
  }

}


class BetaIndicatorView: NSView {

  @IBOutlet var betaPopover: NSPopover!
  @IBOutlet var announcementLabel: NSTextField!
  @IBOutlet var text1: NSTextField!
  @IBOutlet var text2: NSTextField!

  override func awakeFromNib() {
    let buildType = InfoDictionary.shared.buildType
    switch buildType {
    case .nightly:
      self.layer?.backgroundColor = NSColor.initialWindowNightlyLabel.cgColor
    case .beta:
      self.layer?.backgroundColor = NSColor.initialWindowBetaLabel.cgColor
    case .debug:
      self.layer?.backgroundColor = NSColor.initialWindowDebugLabel.cgColor
    default:
      break
    }

    announcementLabel.stringValue = String(format: NSLocalizedString("initial.announcement", comment: "Version announcement"), buildType.rawValue)
    text1.setHTMLValue(NSLocalizedString("initial." + buildType.rawValue.lowercased() + ".desc", comment: "Build type desc"))
    text2.setHTMLValue(NSLocalizedString("initial.bug_report", comment: "Bug report desc"))

    self.layer?.cornerRadius = 4
    self.addTrackingArea(NSTrackingArea(rect: self.bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self, userInfo: nil))
  }

  override func mouseEntered(with event: NSEvent) {
    guard InfoDictionary.shared.buildType != .debug else { return }
    NSCursor.pointingHand.push()
  }

  override func mouseExited(with event: NSEvent) {
    guard InfoDictionary.shared.buildType != .debug else { return }
    NSCursor.pop()
  }

  override func mouseUp(with event: NSEvent) {
    guard InfoDictionary.shared.buildType != .debug else { return }
    if betaPopover.isShown {
      betaPopover.close()
    } else {
      betaPopover.show(relativeTo: self.bounds, of: self, preferredEdge: .maxX)
    }
  }

}
