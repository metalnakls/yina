//
//  InitialWindowController.swift
//  iina
//
//  Created by lhc on 27/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa
import UniformTypeIdentifiers

class InitialWindowController: NSWindowController {

  private struct RecentDocument {
    let url: URL
    var isAvailable: Bool
  }

  weak var player: PlayerCore!

  var loaded = false

  let recentFilesTableView = NSTableView()
  private let recentScrollView = NSScrollView()
  private let visualEffectView = NSVisualEffectView()
  private let mainView = InitialWindowContentView()

  private let observedPrefKeys: [Preference.Key] = [.themeMaterial]
  private let availabilityQueue = DispatchQueue(label: "IINAInitialWindowAvailability", qos: .utility)
  private let coordinator = WelcomeWindowCoordinator()
  private let folderClassificationCache = WelcomeFolderClassificationCache()
  private var isCheckingAvailability = false
  private let showFolderShelf = ShowFolderShelfView()
  private let shelfAccessoryController = WelcomeShelfAccessoryController()
  private let showFolderHeader = NSTextField(labelWithString: "Continue Watching")
  private let recentFilesHeader = NSTextField(labelWithString: "Recents")
  private var showFolders: [ShowFolder] = []
  private var showFolderShelfHeightConstraint: NSLayoutConstraint?
  private var showFolderHeaderHeightConstraint: NSLayoutConstraint?
  private var documentIconCache: [String: NSImage] = [:]
  private var showFolderArtworkCache: [String: ShowFolderCardArtwork] = [:]
  private var artworkRequests: [String: WelcomeArtworkRequest] = [:]

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

  init(playerCore: PlayerCore) {
    self.player = playerCore
    let window = CommonWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
    window.contentView = mainView
    super.init(window: window)
    configureWelcomeWindow()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func documentIdentity(_ url: URL) -> String {
    url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
  }

  private static func isDocumentAvailable(_ url: URL) -> Bool {
    !url.isFileURL || FileManager.default.fileExists(atPath: url.path)
  }

  private static func nonShowContainerPaths() -> Set<String> {
    var paths = ShowFolder.mountedVolumeRootPaths()
    paths.insert(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
    paths.insert(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL.path)
    for directory in [FileManager.SearchPathDirectory.desktopDirectory,
                      .documentDirectory, .downloadsDirectory, .moviesDirectory] {
      if let url = FileManager.default.urls(for: directory, in: .userDomainMask).first {
        paths.insert(url.standardizedFileURL.path)
      }
    }
    return paths
  }

  private static func folderContainsMultiplePlayableFiles(_ folderURL: URL,
                                                          playableExtensions: Set<String>) -> Bool {
    guard let contents = try? FileManager.default.contentsOfDirectory(
      at: folderURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]) else { return false }
    var playableCount = 0
    for url in contents where playableExtensions.contains(url.pathExtension.lowercased()) {
      playableCount += 1
      if playableCount == 2 { return true }
    }
    return false
  }

  private static func folderHasIINAMetadata(_ folderURL: URL) -> Bool {
    FileManager.default.fileExists(atPath: folderURL
      .appendingPathComponent(".iina-multiplayer", isDirectory: true)
      .appendingPathComponent("room.json", isDirectory: false).path)
  }

  private func makeRecentDocumentsList(excludingFolderPaths: Set<String>,
                                       excludingDocumentIdentities: Set<String>) -> [RecentDocument] {
    let documentController = NSDocumentController.shared
    let appKitRecents = documentController.recentDocumentURLs
    let maximumCount = max(appKitRecents.count, Int(documentController.maximumRecentDocumentCount))
    let previousAvailability = Dictionary(uniqueKeysWithValues: recentDocuments.map {
      (documentIdentity($0.url), $0.isAvailable)
    })
    var seen = Set<String>()
    var urls: [URL] = []

    func append(_ url: URL) {
      guard urls.count < maximumCount else { return }
      let identity = documentIdentity(url)
      if url.isFileURL,
         excludingFolderPaths.contains(url.deletingLastPathComponent().standardizedFileURL.path) {
        return
      }
      guard !excludingDocumentIdentities.contains(identity), seen.insert(identity).inserted else { return }
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

  private func configureWelcomeWindow() {
    loaded = true
    configureWindowAppearance()
    configureCenteredLayout()
    configureShelfAccessory()

    recentFilesTableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recent")))
    recentFilesTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    recentFilesTableView.delegate = self
    recentFilesTableView.dataSource = self
    recentFilesTableView.target = self
    recentFilesTableView.action = #selector(self.onTableClicked)
    recentFilesTableView.style = .plain
    recentFilesTableView.headerView = nil
    recentFilesTableView.backgroundColor = .clear
    recentFilesTableView.selectionHighlightStyle = .regular
    recentFilesTableView.rowHeight = 32
    recentFilesTableView.intercellSpacing = NSSize(width: 0, height: 2)

    setMaterial(Preference.enum(for: .themeMaterial))

    observedPrefKeys.forEach { key in
      UserDefaults.standard.addObserver(self, forKeyPath: key.rawValue, options: .new, context: nil)
    }
    NotificationCenter.default.addObserver(self, selector: #selector(historyDidUpdate),
                                           name: .iinaHistoryUpdated, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(initialWindowWillClose),
                                           name: NSWindow.willCloseNotification, object: window)
    NotificationCenter.default.addObserver(self, selector: #selector(availabilityDidChange),
                                           name: NSApplication.didBecomeActiveNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(availabilityDidChange),
                                                      name: NSWorkspace.didMountNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(availabilityDidChange),
                                                      name: NSWorkspace.didUnmountNotification, object: nil)
    reloadData()
  }

  private func configureWindowAppearance() {
    guard let window else { return }
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("IINAWelcomeWindow")
    window.autorecalculatesKeyViewLoop = true
    window.contentMinSize = NSSize(width: 760, height: 560)
    window.contentView?.registerForDraggedTypes([.nsFilenames, .nsURL, .string])
    mainView.wantsLayer = true

  }

  private func configureCenteredLayout() {
    guard let window else { return }

    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true

    visualEffectView.translatesAutoresizingMaskIntoConstraints = false
    visualEffectView.material = .underWindowBackground
    visualEffectView.blendingMode = .behindWindow
    visualEffectView.state = .active
    mainView.addSubview(visualEffectView)

    showFolderShelf.translatesAutoresizingMaskIntoConstraints = false

    showFolderHeader.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    recentFilesHeader.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    [showFolderHeader, recentFilesHeader].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      $0.textColor = .secondaryLabelColor
      $0.setContentHuggingPriority(.required, for: .vertical)
    }

    recentScrollView.translatesAutoresizingMaskIntoConstraints = false
    recentScrollView.drawsBackground = false
    recentScrollView.borderType = .noBorder
    recentScrollView.hasHorizontalScroller = false
    recentScrollView.hasVerticalScroller = false
    recentScrollView.autohidesScrollers = true
    recentScrollView.automaticallyAdjustsContentInsets = false
    recentScrollView.scrollerStyle = .overlay
    recentScrollView.verticalScrollElasticity = .allowed
    recentScrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    recentScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
    recentScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    recentScrollView.documentView = recentFilesTableView
    mainView.addSubview(recentScrollView)
    let shelfHeight = showFolderShelf.heightAnchor.constraint(equalToConstant: ShowFolderShelfView.height)
    showFolderShelfHeightConstraint = shelfHeight
    let showHeaderHeight = showFolderHeader.heightAnchor.constraint(equalToConstant: 17)
    showFolderHeaderHeightConstraint = showHeaderHeight
    NSLayoutConstraint.activate([
      mainView.widthAnchor.constraint(greaterThanOrEqualToConstant: 760),
      mainView.heightAnchor.constraint(greaterThanOrEqualToConstant: 560),
      visualEffectView.leadingAnchor.constraint(equalTo: mainView.leadingAnchor),
      visualEffectView.trailingAnchor.constraint(equalTo: mainView.trailingAnchor),
      visualEffectView.topAnchor.constraint(equalTo: mainView.topAnchor),
      visualEffectView.bottomAnchor.constraint(equalTo: mainView.bottomAnchor),
      // The table occupies the full content plane. The titlebar accessory owns
      // the static shelf and AppKit applies the soft scroll edge as rows pass
      // beneath it.
      recentScrollView.topAnchor.constraint(equalTo: mainView.topAnchor),
      recentScrollView.bottomAnchor.constraint(equalTo: mainView.bottomAnchor),
      recentScrollView.centerXAnchor.constraint(equalTo: mainView.centerXAnchor),
      recentScrollView.widthAnchor.constraint(equalToConstant: 400),
      recentScrollView.widthAnchor.constraint(lessThanOrEqualTo: mainView.widthAnchor, constant: -128),
      shelfHeight,
      showHeaderHeight,
    ])
    mainView.layoutSubtreeIfNeeded()
    updateRecentLayout(resetScrollPosition: true)
  }

  private func configureShelfAccessory() {
    guard let window else { return }
    let root = shelfAccessoryController.view
    root.wantsLayer = true
    root.addSubview(showFolderHeader)
    root.addSubview(showFolderShelf)
    root.addSubview(recentFilesHeader)
    NSLayoutConstraint.activate([
      showFolderHeader.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      showFolderHeader.widthAnchor.constraint(equalToConstant: 400),
      showFolderHeader.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
      showFolderShelf.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      showFolderShelf.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      showFolderShelf.topAnchor.constraint(equalTo: showFolderHeader.bottomAnchor, constant: 6),
      recentFilesHeader.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      recentFilesHeader.widthAnchor.constraint(equalToConstant: 400),
      recentFilesHeader.topAnchor.constraint(equalTo: showFolderShelf.bottomAnchor, constant: 18),
    ])
    window.addTitlebarAccessoryViewController(shelfAccessoryController)
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    // Preserve the welcome window's established presentation lifecycle. The
    // centered layout has no useful compact state, so present it at its native
    // content size after AppKit has restored the autosaved frame.
    window?.setContentSize(NSSize(width: 760, height: 560))
    window?.center()
    updateRecentLayout(resetScrollPosition: true)
    startAvailabilityRefresh()
  }

  @objc private func historyDidUpdate() {
    guard window?.isVisible == true else { return }
    reloadData()
  }

  @objc private func availabilityDidChange() {
    guard window?.isVisible == true else { return }
    folderClassificationCache.invalidate()
    reloadData()
  }

  @objc private func initialWindowWillClose() {
    stopAvailabilityRefresh()
  }

  private func startAvailabilityRefresh() {
    refreshRecentDocumentAvailability()
  }

  private func stopAvailabilityRefresh() {
    coordinator.invalidate()
    cancelArtworkRequests()
  }

  private func refreshRecentDocumentAvailability() {
    guard !isCheckingAvailability, !recentDocuments.isEmpty else { return }
    isCheckingAvailability = true
    let generation = coordinator.currentGeneration
    let urls = recentDocuments.map(\.url)

    availabilityQueue.async { [weak self] in
      let availability = urls.map(Self.isDocumentAvailable)
      DispatchQueue.main.async {
        guard let self else { return }
        self.isCheckingAvailability = false
        guard self.isWindowLoaded, self.window?.isVisible == true else { return }
        guard self.coordinator.isCurrent(generation) else {
          self.refreshRecentDocumentAvailability()
          return
        }

        var changedRows = IndexSet()
        for index in self.recentDocuments.indices where self.recentDocuments[index].isAvailable != availability[index] {
          self.recentDocuments[index].isAvailable = availability[index]
          changedRows.insert(index)
        }
        guard !changedRows.isEmpty else { return }
        for row in changedRows {
          self.documentIconCache.removeValue(forKey: self.documentIdentity(self.recentDocuments[row].url))
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
    guard recentFilesTableView.selectedRow == -1,
          let firstAvailable = recentDocuments.firstIndex(where: \.isAvailable) else { return }
    recentFilesTableView.selectRowIndexes(IndexSet(integer: firstAvailable), byExtendingSelection: false)
  }

  private func reloadShowFolders() {
    let lastURL = Preference.url(for: .iinaLastPlayedFilePath)?.standardizedFileURL
    let lastPosition = Preference.double(for: .iinaLastPlayedFilePosition)
    let historyItems: [ShowFolderHistoryItem] = HistoryController.shared.$history.withLock { history in
      history.compactMap { entry in
        guard entry.url.isFileURL,
              Utility.playableFileExt.contains(entry.url.pathExtension.lowercased()) else { return nil }
        let url = entry.url.standardizedFileURL
        let savedPosition = Utility.playbackProgressFromWatchLater(entry.mpvMd5)?.second ??
          entry.mpvProgress?.second ?? 0
        let position = url == lastURL && lastPosition > 0 ? lastPosition : savedPosition
        return ShowFolderHistoryItem(url: url,
                                     lastPlayedAt: entry.addedDate,
                                     position: position,
                                     duration: entry.duration.second,
                                     displayTitle: entry.title ?? entry.name,
                                     thumbnailCacheName: entry.mpvMd5)
      }
    }
    let dismissals = ShowFolderDismissalStore.dismissedAtByFolder()
    let excludedContainerPaths = Self.nonShowContainerPaths()
    let historyGroupedPaths = ShowFolder.groupedFolderPaths(from: historyItems,
                                                            volumeRootPaths: excludedContainerPaths)
    let candidateFolders = Dictionary(grouping: historyItems.filter { item in
      Date().timeIntervalSince(item.lastPlayedAt) <= ShowFolder.inactivityInterval
    }) { item in
      item.url.deletingLastPathComponent().standardizedFileURL.path
    }.compactMap { path, _ in
      excludedContainerPaths.contains(path) ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }
    let playableExtensions = Set(Utility.playableFileExt)
    let generation = coordinator.currentGeneration
    availabilityQueue.async { [weak self] in
      var folderPaths = historyGroupedPaths
      for folderURL in candidateFolders {
        if self?.folderClassificationCache.isShowFolder(folderURL, playableExtensions: playableExtensions) == true {
          folderPaths.insert(folderURL.standardizedFileURL.path)
        }
      }

      var cards = ShowFolder.make(from: historyItems,
                                  folderPaths: folderPaths,
                                  dismissedAtByFolder: dismissals,
                                  volumeRootPaths: excludedContainerPaths)
      if let latestFile = ShowFolder.makeLatestFile(from: historyItems,
                                                    excludingFolderPaths: folderPaths,
                                                    dismissedAtByFolder: dismissals) {
        cards.append(latestFile)
      }
      cards.sort { lhs, rhs in
        if lhs.lastPlayedAt != rhs.lastPlayedAt { return lhs.lastPlayedAt > rhs.lastPlayedAt }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
      }

      DispatchQueue.main.async {
        guard let self, self.coordinator.isCurrent(generation) else { return }
        let previousCardIdentities = self.showFolders.map(\.identityPath)
        let cardIdentities = cards.map(\.identityPath)
        self.showFolders = cards
        self.showFolderShelf.reload(shows: cards,
                                    target: self,
                                    openAction: #selector(self.openShowFolderCard(_:)),
                                    dismissAction: #selector(self.dismissShowFolderCard(_:)))
        let hasShows = !cards.isEmpty
        let shelfVisibilityChanged = self.showFolderShelf.isHidden == hasShows
        self.showFolderHeader.isHidden = !hasShows
        self.showFolderShelf.isHidden = !hasShows
        self.showFolderHeaderHeightConstraint?.constant = hasShows ? 17 : 0
        self.showFolderShelfHeightConstraint?.constant = hasShows ? ShowFolderShelfView.height : 0
        if shelfVisibilityChanged {
          self.mainView.layoutSubtreeIfNeeded()
        }
        self.reloadRecents()
        self.updateRecentLayout(resetScrollPosition: previousCardIdentities != cardIdentities)

        // Publish the stable shelf before doing any thumbnail I/O or image
        // processing. The serial utility queue then fills these existing
        // cards; it never changes their count or geometry.
        self.availabilityQueue.async { [weak self] in
          self?.loadShowFolderArtwork(for: cards, generation: generation)
        }
      }
    }
  }

  private func loadShowFolderArtwork(for cards: [ShowFolder], generation: Int) {
    var artworkByPath: [String: ShowFolderCardArtwork] = [:]
    var artworkRequests: [ShowFolder] = []
    for show in cards {
      let cacheKey = WelcomeArtworkRequest.cacheName(for: show)
      if let artwork = showFolderArtworkCache[cacheKey] {
        artworkByPath[show.identityPath] = artwork
        continue
      }
      let highResolutionThumbnail = ThumbnailCache.fileIsCached(forName: cacheKey, forVideo: show.resumeURL)
        ? ThumbnailCache.read(forName: cacheKey)?.first?.image
        : nil
      let targetTime = show.position
      let cachedFrame = ThumbnailCache.fileIsCached(forName: show.thumbnailCacheName, forVideo: show.resumeURL)
        ? ThumbnailCache.read(forName: show.thumbnailCacheName)?.min(by: {
          abs($0.realTime - targetTime) < abs($1.realTime - targetTime)
        })?.image
        : nil
      if let thumbnail = highResolutionThumbnail ?? cachedFrame,
         Self.isBackingScaleSufficient(thumbnail),
         let artwork = ShowFolderCardArtwork.make(from: thumbnail) {
        showFolderArtworkCache[cacheKey] = artwork
        artworkByPath[show.identityPath] = artwork
      } else {
        artworkRequests.append(show)
      }
    }

    DispatchQueue.main.async { [weak self] in
      guard let self, self.coordinator.isCurrent(generation) else { return }
      for show in cards {
        if let artwork = artworkByPath[show.identityPath] {
          self.showFolderShelf.setThumbnail(artwork, for: show)
        }
      }
      artworkRequests.forEach { self.requestArtwork(for: $0, generation: generation) }
    }
  }

  private static func isBackingScaleSufficient(_ image: NSImage) -> Bool {
    var rect = NSRect(origin: .zero, size: image.size)
    guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return false }
    return cgImage.width >= 480 && cgImage.height >= 256
  }

  private func requestArtwork(for show: ShowFolder, generation: Int) {
    let cacheName = WelcomeArtworkRequest.cacheName(for: show)
    guard artworkRequests[show.identityPath] == nil else { return }
    let requestID = UUID()
    let request = WelcomeArtworkRequest(id: requestID, show: show) { [weak self] thumbnail in
      guard let self else { return }
      guard self.artworkRequests[show.identityPath]?.id == requestID else { return }
      defer { self.artworkRequests.removeValue(forKey: show.identityPath) }
      guard self.coordinator.isCurrent(generation),
            let thumbnail,
            let artwork = ShowFolderCardArtwork.make(from: thumbnail) else { return }
      self.showFolderArtworkCache[cacheName] = artwork
      self.showFolderShelf.setThumbnail(artwork, for: show)
    }
    artworkRequests[show.identityPath] = request
    request.start()
  }

  @objc private func openShowFolderCard(_ sender: NSButton) {
    guard let identifier = sender.identifier?.rawValue,
          let show = showFolders.first(where: { $0.identityPath == identifier }) else { return }
    player.openURL(show.resumeURL)
  }

  @objc private func dismissShowFolderCard(_ sender: NSMenuItem) {
    guard let identifier = sender.representedObject as? String,
          let show = showFolders.first(where: { $0.identityPath == identifier }) else { return }
    ShowFolderDismissalStore.dismiss(show)
    showFolders.removeAll { $0.identityPath == identifier }
    showFolderShelf.dismissCard(for: show) { [weak self] in
      guard let self else { return }
      self.showFolderHeader.isHidden = self.showFolders.isEmpty
      self.showFolderShelf.isHidden = self.showFolders.isEmpty
      self.showFolderShelfHeightConstraint?.constant = self.showFolders.isEmpty ? 0 : ShowFolderShelfView.height
      self.coordinator.invalidate()
      self.reloadRecents()
      self.updateRecentLayout(resetScrollPosition: true)
    }
  }

  private func setMaterial(_ theme: Preference.Theme?) {
    guard let window, let theme else { return }
    window.appearance = NSAppearance(iinaTheme: theme)
  }

  @objc func onTableClicked() {
    openRecentItemFromTable(recentFilesTableView.clickedRow)
  }

  private func openRecentItemFromTable(_ rowIndex: Int) {
    if let document = recentDocuments[at: rowIndex], document.isAvailable {
      player.openURL(document.url)
    }
  }

  func reloadData() {
    coordinator.invalidate()
    cancelArtworkRequests()
    reloadShowFolders()
    reloadRecents()
  }

  // AppDelegate refreshes this controller through the historical selector.
  // The rebuilt welcome surface derives all of its state in reloadData().
  func loadLastPlaybackInfo() { }

  private func reloadRecents() {
    let collapsedFolderPaths = Set(showFolders.compactMap {
      $0.kind == .folder ? $0.folderURL.standardizedFileURL.path : nil
    })
    let collapsedDocumentIdentities = Set(showFolders.compactMap {
      $0.kind == .file ? documentIdentity($0.resumeURL) : nil
    })
    let previousDocuments = recentDocuments
    recentDocuments = makeRecentDocumentsList(excludingFolderPaths: collapsedFolderPaths,
                                              excludingDocumentIdentities: collapsedDocumentIdentities)
    recentFilesHeader.isHidden = recentDocuments.isEmpty
    let documentListChanged = previousDocuments.count != recentDocuments.count ||
      zip(previousDocuments, recentDocuments).contains { old, new in
        documentIdentity(old.url) != documentIdentity(new.url) || old.isAvailable != new.isAvailable
      }
    if documentListChanged {
      recentFilesTableView.reloadData()
    }
    if window?.isVisible == true {
      refreshRecentDocumentAvailability()
    }

    if Logger.isEmitting(.verbose) {
      for (index, url) in NSDocumentController.shared.recentDocumentURLs.enumerated() {
        Logger.log("InitialWindow.reloadData(): RecentDocuments_Unfiltered[\(index)]: \(url.resolvingSymlinksInPath().path)", level: .verbose)
      }

      for (index, document) in recentDocuments.enumerated() {
        Logger.log("InitialWindow.reloadData(): Loaded RecentDocuments[\(index)]: \(document.url.path), available: \(document.isAvailable)", level: .verbose)
      }
    }
    
    selectFirstRecentDocumentIfNeeded()
  }

  private func updateRecentLayout(resetScrollPosition: Bool = false) {
    let headerHeight = max(showFolderHeader.intrinsicContentSize.height, 17)
    let recentHeaderHeight = max(recentFilesHeader.intrinsicContentSize.height, 17)
    let shelfHeight = showFolders.isEmpty ? CGFloat(0) : ShowFolderShelfView.height
    let sectionOffset = showFolders.isEmpty ? CGFloat(0) : headerHeight + 6 + shelfHeight + 18
    let accessoryHeight = 20 + sectionOffset + recentHeaderHeight + 6
    shelfAccessoryController.view.frame.size.height = accessoryHeight
    // The scroll edge begins at the accessory boundary. Keep the first row
    // below the Recents label instead of allowing the row selection to render
    // through that transition zone.
    let recentRowsTop = accessoryHeight + recentHeaderHeight + 12
    recentScrollView.contentInsets = NSEdgeInsets(top: recentRowsTop,
                                                  left: 0, bottom: 16, right: 0)
    if resetScrollPosition {
      recentFilesTableView.scrollToBeginningOfDocument(nil)
    }
  }

  private func cancelArtworkRequests() {
    artworkRequests.values.forEach { $0.cancel() }
    artworkRequests.removeAll()
  }
}

extension InitialWindowController: NSTableViewDelegate, NSTableViewDataSource {

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let rowView = InitialWindowRecentRowView()
    rowView.alphaValue = recentDocuments[row].isAvailable ? 1 : 0.45
    return rowView
  }

  func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
    IndexSet(proposedSelectionIndexes.filter { recentDocuments[$0].isAvailable })
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    return recentDocuments.count
  }

  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    let document = recentDocuments[row]
    let url = document.url
    let icon: NSImage
    let identity = documentIdentity(url)
    if let cachedIcon = documentIconCache[identity] {
      icon = cachedIcon
    } else if document.isAvailable {
      icon = NSWorkspace.shared.icon(forFile: url.path)
      documentIconCache[identity] = icon
    } else {
      let contentType = UTType(filenameExtension: url.pathExtension) ?? .data
      icon = NSWorkspace.shared.icon(for: contentType)
      documentIconCache[identity] = icon
    }
    return [
      "filename": url.lastPathComponent,
      "docIcon": icon
    ] as [String: Any]
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("InitialWindowRecentCell")
    let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
      ?? makeRecentCell(identifier: identifier)
    let document = recentDocuments[row]
    let icon = documentIcon(for: document)
    cell.textField?.stringValue = document.url.lastPathComponent
    cell.imageView?.image = icon
    return cell
  }

  private func documentIcon(for document: RecentDocument) -> NSImage {
    let identity = documentIdentity(document.url)
    if let icon = documentIconCache[identity] { return icon }
    let icon: NSImage
    if document.isAvailable {
      icon = NSWorkspace.shared.icon(forFile: document.url.path)
    } else {
      icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: document.url.pathExtension) ?? .data)
    }
    documentIconCache[identity] = icon
    return icon
  }

  private func makeRecentCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier
    let icon = NSImageView()
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.imageScaling = .scaleProportionallyDown
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail
    label.font = .systemFont(ofSize: NSFont.systemFontSize)
    label.textColor = .labelColor
    cell.addSubview(icon)
    cell.addSubview(label)
    cell.imageView = icon
    cell.textField = label
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 9),
      icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: -1),
      icon.widthAnchor.constraint(equalToConstant: 16),
      icon.heightAnchor.constraint(equalToConstant: 16),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 2),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: -1),
    ])
    return cell
  }

  override func keyDown(with event: NSEvent) {
    let keyChar = KeyCodeHelper.keyMap[event.keyCode]?.0
    switch keyChar {
      case "ENTER", "KP_ENTER":  // RETURN or (keypad ENTER)
        if recentFilesTableView.selectedRow >= 0 {
          // If user selected a row in the table using the keyboard, use that
          openRecentItemFromTable(recentFilesTableView.selectedRow)
        } else if recentFilesTableView.numberOfRows > 0 {
          // No selection yet: open the first available recent item.
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
        if recentFilesTableView.selectedRow <= 0 || recentDocuments.isEmpty {
          super.keyDown(with: event)  // invalid command: beep at user
          return
        }
        // default: let recentFilesTableView handle it
        recentFilesTableView.keyDown(with: event)
      default:
        super.keyDown(with: event)
    }
  }

}

private final class InitialWindowRecentRowView: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    guard selectionHighlightStyle != .none else { return }
    let selectionColor = isEmphasized
      ? NSColor.selectedContentBackgroundColor
      : NSColor.unemphasizedSelectedContentBackgroundColor
    selectionColor.setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
  }
}

/// System-owned shelf chrome. The public soft scroll edge is owned by AppKit,
/// so content scrolling beneath this titlebar accessory never uses a bitmap mask.
private final class WelcomeShelfAccessoryController: NSTitlebarAccessoryViewController {
  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 43))
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // A bottom titlebar accessory sits below the transparent titlebar and owns
    // a dynamically adjustable height. A top accessory replaces the titlebar
    // and clips this shelf to its initial titlebar-sized frame.
    layoutAttribute = .bottom
    automaticallyAdjustsSize = false
    preferredScrollEdgeEffectStyle = .soft
  }
}

/// Main-actor ownership boundary for every asynchronous welcome-surface result.
/// Workers capture a generation and may only publish while it remains current.
@MainActor
private final class WelcomeWindowCoordinator {
  private(set) var currentGeneration = 0

  func invalidate() {
    currentGeneration &+= 1
  }

  func isCurrent(_ generation: Int) -> Bool {
    generation == currentGeneration
  }
}

/// Filesystem classification is only performed once per folder generation. The
/// workspace mount/unmount event invalidates it before any new result publishes.
private final class WelcomeFolderClassificationCache {
  private let lock = NSLock()
  private var values: [String: Bool] = [:]

  func isShowFolder(_ folderURL: URL, playableExtensions: Set<String>) -> Bool {
    let path = folderURL.standardizedFileURL.path
    lock.lock()
    if let value = values[path] {
      lock.unlock()
      return value
    }
    lock.unlock()

    let metadataURL = folderURL.appendingPathComponent(".iina-multiplayer", isDirectory: true)
      .appendingPathComponent("room.json", isDirectory: false)
    let result: Bool
    if FileManager.default.fileExists(atPath: metadataURL.path) {
      result = true
    } else if let contents = try? FileManager.default.contentsOfDirectory(
      at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
      result = contents.lazy.filter { playableExtensions.contains($0.pathExtension.lowercased()) }.prefix(2).count == 2
    } else {
      result = false
    }
    lock.lock()
    values[path] = result
    lock.unlock()
    return result
  }

  func invalidate() {
    lock.lock()
    values.removeAll()
    lock.unlock()
  }
}

/// Bridges the established asynchronous FFmpeg controller to one sharp,
/// saved-position card frame. It owns its controller until the delegate gives a
/// terminal result; no thumbnail work occurs on the main actor.
private final class WelcomeArtworkRequest: NSObject, FFmpegControllerDelegate {
  let id: UUID
  private let show: ShowFolder
  private let completion: (NSImage?) -> Void
  private let controller = FFmpegController()

  init(id: UUID, show: ShowFolder, completion: @escaping (NSImage?) -> Void) {
    self.id = id
    self.show = show
    self.completion = completion
    super.init()
    controller.delegate = self
    controller.thumbnailCount = 1
  }

  static func cacheName(for show: ShowFolder) -> String {
    "welcome-artwork-480-\(show.thumbnailCacheName)"
  }

  func start() {
    controller.generateThumbnail(forFile: show.resumeURL.path, atTime: show.position, thumbWidth: 480)
  }

  func cancel() {
    controller.cancelThumbnailGeneration()
  }

  func didUpdate(_ thumbnails: [FFThumbnail]?, forFile filename: String, withProgress progress: Int) {
    // A single saved-position frame has no intermediate UI state.
  }

  func didGenerate(_ thumbnails: [FFThumbnail], forFile filename: String, succeeded: Bool) {
    let thumbnail = succeeded ? thumbnails.first : nil
    if let thumbnail {
      ThumbnailCache.write([thumbnail], forName: Self.cacheName(for: show), forVideo: show.resumeURL)
    }
    DispatchQueue.main.async { [completion] in
      completion(thumbnail?.image)
    }
  }
}


class InitialWindowContentView: NSView {

  override var cornerConfiguration: NSViewCornerConfiguration? {
    .uniformCorners(radius: .containerConcentric(28))
  }

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
