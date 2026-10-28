//
//  InitialWindowController.swift
//  yina
//
//  Created by lhc on 27/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa
import SwiftUI
import UniformTypeIdentifiers

private final class WelcomeShelfDrawingView: NSView {
  let shelf: ShowFolderShelfView

  init(shelf: ShowFolderShelfView) {
    self.shelf = shelf
    super.init(frame: .zero)
    clipsToBounds = false
    shelf.translatesAutoresizingMaskIntoConstraints = true
    shelf.autoresizingMask = []
    addSubview(shelf)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard shelf.frame.contains(convert(point, from: superview)) else { return nil }
    return super.hitTest(point)
  }
}

class InitialWindowController: NSWindowController {

  private static let maximumShowFolderCount = 20
  private static let maximumRecentDocumentCount = 20
  private static let recentListWidth: CGFloat = 400
  private static let maximumRecentWindowHeight: CGFloat = 560
  private static let minimumVisibleRecentRows = 4
  private static let recentListBottomInset: CGFloat = 16
  private static let recentListTopInset: CGFloat = 32

  private struct RecentDocument {
    let url: URL
    var isAvailable: Bool
  }

  weak var player: PlayerCore!

  var loaded = false

  private let recentListModel = WelcomeRecentsModel()
  private var recentListHost: NSHostingView<WelcomeRecentsView>?
  private let visualEffectView = NSVisualEffectView()
  private let mainView = InitialWindowContentView()
  private let emptyStateView = NSStackView()

  private let observedPrefKeys: [Preference.Key] = [.themeMaterial]
  private let availabilityQueue = DispatchQueue(label: "YINAInitialWindowAvailability", qos: .utility)
  private let recentDocumentsQueue = DispatchQueue(label: "YINAInitialWindowRecents", qos: .utility)
  private let mediaOpenQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "YINAWelcomeMediaOpen"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 2
    return queue
  }()
  private var openRequestGeneration = 0
  private let iconQueue = DispatchQueue(label: "YINAInitialWindowIcons", qos: .utility)
  private var pendingIconExtensions = Set<String>()
  private let coordinator = WelcomeWindowCoordinator()
  private let folderClassificationCache = WelcomeFolderClassificationCache()
  private var isCheckingAvailability = false
  private var isRecentListKeyboardActive = false
  private let showFolderShelf = ShowFolderShelfView()
  private var shelfWindow: NSWindow?
  private var mainViewHeightConstraint: NSLayoutConstraint?
  private var recentScrollOffset: CGFloat = 0
  private var recentResizePending = false
  private var recentLayoutRevision = 0
  private var showFolders: [ShowFolder] = []
  private var documentIconCache: [String: NSImage] = [:]
  private var showFolderArtworkCache: [String: (position: Double, artwork: ShowFolderCardArtwork)] = [:]
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
    let window = CommonWindow(contentRect: NSRect(x: 0, y: 0, width: Self.recentListWidth,
                                                  height: Self.maximumRecentWindowHeight),
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
    url.isFileURL ? url.path : url.absoluteString
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

  private static func folderHasYINAMetadata(_ folderURL: URL) -> Bool {
    FileManager.default.fileExists(atPath: folderURL
      .appendingPathComponent(".yina-multiplayer", isDirectory: true)
      .appendingPathComponent("room.json", isDirectory: false).path)
  }

  private func makeRecentDocumentsList(excludingFolderPaths: Set<String>,
                                       excludingDocumentIdentities: Set<String>,
                                       appKitRecents: [URL],
                                       previousAvailability: [String: Bool]) -> [RecentDocument] {
    let now = Date()
    let cutoffDate = now.addingTimeInterval(-ShowFolder.inactivityInterval)
    var seen = Set<String>()
    var urls: [URL] = []

    func append(_ url: URL) {
      guard urls.count < Self.maximumRecentDocumentCount else { return }
      let identity = documentIdentity(url)
      if url.isFileURL,
         excludingFolderPaths.contains(url.deletingLastPathComponent().standardizedFileURL.path) {
        return
      }
      guard !excludingDocumentIdentities.contains(identity), seen.insert(identity).inserted else { return }
      urls.append(url)
    }

    if Preference.bool(for: .recordRecentFiles) {
      let history = HistoryController.shared.$history.withLock { $0.map { $0.detachedCopy() } }
      do {
        for entry in history.lazy
          .filter({ $0.addedDate >= cutoffDate })
          .prefix(Self.maximumRecentDocumentCount) {
          append(entry.resolvedURL())
        }
      }
    } else {
      appKitRecents.prefix(Self.maximumRecentDocumentCount).forEach(append)
    }

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
    configureShelfWindow()
    configureEmptyState()

    setMaterial(Preference.enum(for: .themeMaterial))

    observedPrefKeys.forEach { key in
      AppEnvironment.defaults.addObserver(self, forKeyPath: key.rawValue, options: .new, context: nil)
    }
    NotificationCenter.default.addObserver(self, selector: #selector(historyDidUpdate),
                                           name: .yinaHistoryUpdated, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(showExtensionsDidChange),
                                           name: Preference.showExtensionsDidChange, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(welcomeWindowMoved),
                                           name: NSWindow.didMoveNotification, object: window)
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
    window.autorecalculatesKeyViewLoop = true
    window.contentView?.registerForDraggedTypes([.nsFilenames, .nsURL, .string])
    mainView.translatesAutoresizingMaskIntoConstraints = false
    mainView.wantsLayer = true

  }

  private func configureCenteredLayout() {
    guard let window else { return }

    window.standardWindowButton(.closeButton)?.isHidden = true
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true

    visualEffectView.translatesAutoresizingMaskIntoConstraints = false
    visualEffectView.material = .underWindowBackground
    visualEffectView.blendingMode = .behindWindow
    visualEffectView.state = .active
    mainView.addSubview(visualEffectView)

    recentListModel.open = { [weak self] identity in
      guard let self, let row = self.recentDocuments.firstIndex(where: { self.documentIdentity($0.url) == identity }) else { return }
      self.openRecentItemFromTable(row)
    }
    recentListModel.selectionChanged = { [weak self] selection in
      guard let self else { return }
      self.isRecentListKeyboardActive = selection != nil
      self.showFolderShelf.setKeyboardSelectedCard(identityPath: selection == nil ? self.showFolders.first?.identityPath : nil)
    }
    recentListModel.scrolled = { [weak self] offset in self?.recentListDidScroll(offset) }
    let recentListHost = NSHostingView(rootView: WelcomeRecentsView(model: recentListModel))
    recentListHost.safeAreaRegions = []
    recentListHost.translatesAutoresizingMaskIntoConstraints = false
    recentListHost.wantsLayer = true
    recentListHost.layer?.backgroundColor = NSColor.clear.cgColor
    self.recentListHost = recentListHost
    mainView.addSubview(recentListHost)

    let rowHeight = CGFloat(32 + 2)
    let initialHeight = Self.recentListTopInset +
      rowHeight * CGFloat(Self.minimumVisibleRecentRows) + Self.recentListBottomInset
    let heightConstraint = mainView.heightAnchor.constraint(equalToConstant: initialHeight)
    mainViewHeightConstraint = heightConstraint
    NSLayoutConstraint.activate([
      mainView.widthAnchor.constraint(equalToConstant: Self.recentListWidth),
      heightConstraint,
      visualEffectView.leadingAnchor.constraint(equalTo: mainView.leadingAnchor),
      visualEffectView.trailingAnchor.constraint(equalTo: mainView.trailingAnchor),
      visualEffectView.topAnchor.constraint(equalTo: mainView.topAnchor),
      visualEffectView.bottomAnchor.constraint(equalTo: mainView.bottomAnchor),
      recentListHost.leadingAnchor.constraint(equalTo: mainView.leadingAnchor),
      recentListHost.trailingAnchor.constraint(equalTo: mainView.trailingAnchor),
      recentListHost.topAnchor.constraint(equalTo: mainView.topAnchor),
      recentListHost.bottomAnchor.constraint(equalTo: mainView.bottomAnchor),
    ])
    mainView.layoutSubtreeIfNeeded()
    updateRecentLayout(resetScrollPosition: true)
  }

  private func configureShelfWindow() {
    guard let window else { return }
    let shelf = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                            width: ShowFolderShelfView.cardSlotWidth,
                                            height: ShowFolderShelfView.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    shelf.isOpaque = false
    shelf.backgroundColor = .clear
    shelf.hasShadow = false
    shelf.isReleasedWhenClosed = false
    shelf.level = window.level
    shelf.collectionBehavior = [.transient, .auxiliary, .ignoresCycle]
    shelf.isExcludedFromWindowsMenu = true
    shelf.contentView = WelcomeShelfDrawingView(shelf: showFolderShelf)
    shelf.appearance = window.appearance
    shelfWindow = shelf
    window.addChildWindow(shelf, ordered: .above)
    updateShelfWindowFrame()
  }

  private func configureEmptyState() {
    let icon = NSImageView(image: NSImage(systemSymbolName: "play.circle", accessibilityDescription: nil)
      ?? NSImage(named: NSImage.applicationIconName)!)
    icon.contentTintColor = .secondaryLabelColor
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.setAccessibilityElement(false)
    let title = NSTextField(labelWithString: NSLocalizedString("welcome.play_something", value: "play something", comment: "Empty welcome window"))
    title.font = .systemFont(ofSize: 22, weight: .medium)
    title.textColor = .secondaryLabelColor
    title.alignment = .center
    emptyStateView.orientation = .vertical
    emptyStateView.alignment = .centerX
    emptyStateView.spacing = 16
    emptyStateView.translatesAutoresizingMaskIntoConstraints = false
    emptyStateView.addArrangedSubview(icon)
    emptyStateView.addArrangedSubview(title)
    mainView.addSubview(emptyStateView)
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 64),
      icon.heightAnchor.constraint(equalToConstant: 64),
      emptyStateView.centerXAnchor.constraint(equalTo: mainView.centerXAnchor),
      emptyStateView.centerYAnchor.constraint(equalTo: mainView.centerYAnchor),
    ])
    updateEmptyState()
  }

  private func updateEmptyState() {
    let isEmpty = showFolders.isEmpty && recentDocuments.isEmpty
    emptyStateView.isHidden = !isEmpty
    recentListHost?.isHidden = recentDocuments.isEmpty
    showFolderShelf.isHidden = showFolders.isEmpty
    updateShelfWindowVisibility()
  }

  override func showWindow(_ sender: Any?) {
    updateRecentLayout(resetScrollPosition: true, preserveTop: false)
    centerWelcomeComposition()
    super.showWindow(sender)
    updateShelfWindowFrame()
    isRecentListKeyboardActive = false
    reloadData()
    startAvailabilityRefresh()
  }

  @objc private func historyDidUpdate() {
    guard window?.isVisible == true else { return }
    reloadData()
  }

  @objc private func showExtensionsDidChange() {
    publishRecentItems()
  }

  @objc private func availabilityDidChange() {
    guard window?.isVisible == true else { return }
    folderClassificationCache.invalidate()
    reloadData()
  }

  @objc private func initialWindowWillClose() {
    openRequestGeneration &+= 1
    mediaOpenQueue.cancelAllOperations()
    stopAvailabilityRefresh()
    shelfWindow?.orderOut(nil)
  }

  private func centerWelcomeComposition() {
    guard let window, let screen = window.screen ?? NSScreen.main else { return }
    let visibleFrame = screen.visibleFrame
    let windowFrame = window.frame
    let cardOverflow = showFolders.isEmpty ? 0 : ShowFolderCardView.size.height * 3 / 4
    let lowerBound = visibleFrame.minY
    let upperBound = max(lowerBound, visibleFrame.maxY - windowFrame.height - cardOverflow)
    let originY = min(max(visibleFrame.midY - (windowFrame.height + cardOverflow) / 2,
                          lowerBound), upperBound)
    window.setFrameOrigin(NSPoint(x: visibleFrame.midX - windowFrame.width / 2, y: originY))
    updateShelfWindowFrame()
  }

  @objc private func welcomeWindowMoved(_ notification: Notification) {
    updateShelfWindowFrame()
  }

  private func updateShelfWindowFrame() {
    guard let parentWindow = window, let shelfWindow else { return }
    guard !showFolders.isEmpty else {
      updateShelfWindowVisibility()
      return
    }

    let screen = parentWindow.screen ?? NSScreen.main
    let availableWidth = screen?.visibleFrame.width ?? ShowFolderShelfView.cardSlotWidth
    let parentFrame = parentWindow.frame
    let centeredCardCount = min(showFolders.count, ShowFolderShelfView.maximumCenteredCardCount)
    let desiredWidth = max(parentFrame.width,
                           CGFloat(centeredCardCount) * ShowFolderShelfView.cardSlotWidth)
    let width = min(desiredWidth, availableWidth)
    let frame = NSRect(x: parentFrame.midX - width / 2,
                       y: parentFrame.maxY - ShowFolderShelfView.height / 2 + ShowFolderCardView.size.height / 4,
                       width: width,
                       height: ShowFolderShelfView.height)
    // Extend only the drawing strip horizontally; the native scroll viewport
    // retains its original size and stays clear of the recent-list rows.
    let screenFrame = screen?.frame ?? frame
    let drawingFrame = NSRect(x: min(frame.minX, screenFrame.minX), y: frame.minY,
                              width: max(frame.maxX, screenFrame.maxX) - min(frame.minX, screenFrame.minX),
                              height: frame.height)
    if shelfWindow.frame != drawingFrame { shelfWindow.setFrame(drawingFrame, display: false) }
    showFolderShelf.frame = frame.offsetBy(dx: -drawingFrame.minX, dy: -drawingFrame.minY)
    showFolderShelf.needsLayout = true
    showFolderShelf.layoutSubtreeIfNeeded()
    updateShelfWindowVisibility()
  }

  private func updateShelfWindowVisibility() {
    guard let shelfWindow else { return }
    let shouldShow = window?.isVisible == true && !showFolders.isEmpty
    shelfWindow.alphaValue = shouldShow ? 1 : 0
    shelfWindow.ignoresMouseEvents = !shouldShow
    if shouldShow && !shelfWindow.isVisible {
      shelfWindow.orderFront(nil)
    }
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
    let identities = urls.map(documentIdentity)

    availabilityQueue.async { [weak self] in
      let availabilityByIdentity = Dictionary(
        zip(identities, urls.map(Self.isDocumentAvailable)),
        uniquingKeysWith: { _, latest in latest })
      DispatchQueue.main.async {
        guard let self else { return }
        self.isCheckingAvailability = false
        guard self.isWindowLoaded, self.window?.isVisible == true else { return }
        guard self.coordinator.isCurrent(generation) else {
          self.refreshRecentDocumentAvailability()
          return
        }

        var changedRows = IndexSet()
        for index in self.recentDocuments.indices {
          let identity = self.documentIdentity(self.recentDocuments[index].url)
          guard let isAvailable = availabilityByIdentity[identity],
                self.recentDocuments[index].isAvailable != isAvailable else { continue }
          self.recentDocuments[index].isAvailable = isAvailable
          changedRows.insert(index)
        }
        guard !changedRows.isEmpty else { return }
        self.publishRecentItems()
        self.updateEmptyState()
      }
    }
  }

  private func reloadShowFolders() {
    let generation = coordinator.currentGeneration
    availabilityQueue.async { [weak self] in
      guard let self else { return }
      let now = Date()
      let cutoffDate = now.addingTimeInterval(-ShowFolder.inactivityInterval)
      let lastURL = Preference.url(for: .iinaLastPlayedFilePath)?.standardizedFileURL
      let lastPosition = Preference.double(for: .iinaLastPlayedFilePosition)
      let history = HistoryController.shared.$history.withLock { $0.map { $0.detachedCopy() } }
      let historyItems: [ShowFolderHistoryItem] = history.lazy
          .filter { $0.addedDate >= cutoffDate }
          .prefix(Self.maximumShowFolderCount)
          .compactMap { entry in
            let resolvedURL = entry.resolvedURL()
            guard resolvedURL.isFileURL,
                  Utility.playableFileExt.contains(resolvedURL.pathExtension.lowercased()) else { return nil }
            let url = resolvedURL.standardizedFileURL
            let savedPosition = entry.mpvProgress?.second ?? 0
            let position = url == lastURL && lastPosition > 0 ? lastPosition : savedPosition
            return ShowFolderHistoryItem(url: url,
                                         lastPlayedAt: entry.addedDate,
                                         position: position,
                                         duration: entry.duration.second,
                                         thumbnailCacheName: entry.mpvMd5)
          }
      let dismissals = ShowFolderDismissalStore.dismissedAtByFolder()
      let cachedFolderPaths = ShowFolderSnapshotStore.load()
      let excludedContainerPaths = Self.nonShowContainerPaths()
      let historyGroupedPaths = ShowFolder.groupedFolderPaths(from: historyItems,
                                                              volumeRootPaths: excludedContainerPaths)
      let candidateFolders = Dictionary(grouping: historyItems) {
        $0.url.deletingLastPathComponent().standardizedFileURL.path
      }.compactMap { path, _ in
        excludedContainerPaths.contains(path) ? nil : URL(fileURLWithPath: path, isDirectory: true)
      }
      let playableExtensions = Set(Utility.playableFileExt)
      var folderPaths = historyGroupedPaths
      for folderURL in candidateFolders {
        switch self.folderClassificationCache.classification(of: folderURL,
                                                              playableExtensions: playableExtensions) {
        case .show:
          folderPaths.insert(folderURL.standardizedFileURL.path)
        case .unavailable where cachedFolderPaths.contains(folderURL.standardizedFileURL.path):
          // A persisted card is proof that this was a real show folder while
          // the volume was reachable. Rebuild it from current history so its
          // progress and episode remain current, but keep it glass-only until
          // the source can be validated again.
          folderPaths.insert(folderURL.standardizedFileURL.path)
        case .notShow, .unavailable:
          break
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
        return lhs.primaryTitle.localizedStandardCompare(rhs.primaryTitle) == .orderedAscending
      }
      cards = Array(cards.prefix(Self.maximumShowFolderCount))

      DispatchQueue.main.async { [weak self] in
        guard let self, self.coordinator.isCurrent(generation) else { return }
        self.displayShowFolders(cards, saveSnapshot: true)
        self.reloadRecents()

        // Publish the stable shelf before doing any thumbnail I/O or image
        // processing. The serial utility queue then fills these existing
        // cards; it never changes their count or geometry.
        let cachedArtwork = self.showFolderArtworkCache
        self.availabilityQueue.async { [weak self] in
          self?.loadShowFolderArtwork(for: cards, generation: generation, cachedArtwork: cachedArtwork)
        }
      }
    }
  }

  private func loadShowFolderArtwork(for cards: [ShowFolder], generation: Int,
                                     cachedArtwork: [String: (position: Double, artwork: ShowFolderCardArtwork)]) {
    var preparedCache: [String: (position: Double, artwork: ShowFolderCardArtwork)] = [:]
    var artworkByPath: [String: ShowFolderCardArtwork] = [:]
    var artworkRequests: [ShowFolder] = []
    for show in cards {
      let cacheKey = WelcomeArtworkRequest.cacheName(for: show)
      if let cached = cachedArtwork[cacheKey], abs(cached.position - show.position) <= 1 {
        artworkByPath[show.identityPath] = cached.artwork
        continue
      }
      ThumbnailCache.importLegacyPreview(forName: cacheKey, forVideo: show.resumeURL)
      ThumbnailCache.importLegacyPreview(forName: show.thumbnailCacheName, forVideo: show.resumeURL)
      // Only one frame is needed here. Decoding the whole catalog and keeping a
      // single image costs megabytes per card and is repeated on every rescan.
      let highResolutionThumbnail = ThumbnailCache.fileIsCached(forName: cacheKey, forVideo: show.resumeURL, allowUnavailableVideo: true)
        ? ThumbnailCache.readOne(forName: cacheKey, nearest: show.position, maximumDistance: 1)
        : nil
      let targetTime = show.position
      let cachedFrame = highResolutionThumbnail == nil && ThumbnailCache.fileIsCached(forName: show.thumbnailCacheName, forVideo: show.resumeURL, allowUnavailableVideo: true)
        ? ThumbnailCache.readOne(forName: show.thumbnailCacheName, nearest: targetTime)
        : nil
      if let thumbnail = highResolutionThumbnail ?? cachedFrame,
         let artwork = ShowFolderCardArtwork.make(from: thumbnail) {
        artworkByPath[show.identityPath] = artwork
        if highResolutionThumbnail != nil && Self.isBackingScaleSufficient(thumbnail) {
          preparedCache[cacheKey] = (show.position, artwork)
        } else {
          // Show the available preview now and upgrade it without leaving the card blank.
          artworkRequests.append(show)
        }
      } else {
        artworkRequests.append(show)
      }
    }

    DispatchQueue.main.async { [weak self] in
      guard let self, self.coordinator.isCurrent(generation) else { return }
      self.showFolderArtworkCache.merge(preparedCache) { _, prepared in prepared }
      for show in cards where self.showFolders.contains(where: {
        $0.identityPath == show.identityPath && $0.resumeURL == show.resumeURL && $0.position == show.position
      }) {
        if let artwork = artworkByPath[show.identityPath] {
          self.showFolderShelf.setThumbnail(artwork, for: show)
        }
      }
      artworkRequests.filter { requested in
        self.showFolders.contains(where: {
          $0.identityPath == requested.identityPath && $0.resumeURL == requested.resumeURL && $0.position == requested.position
        })
      }.forEach { self.requestArtwork(for: $0, generation: generation) }
    }
  }

  private static func isBackingScaleSufficient(_ image: NSImage) -> Bool {
    var rect = NSRect(origin: .zero, size: image.size)
    guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return false }
    return cgImage.width >= 960 && cgImage.height >= 512
  }

  private func requestArtwork(for show: ShowFolder, generation: Int) {
    let cacheName = WelcomeArtworkRequest.cacheName(for: show)
    if let existing = artworkRequests[show.identityPath] {
      guard !existing.matches(show) else { return }
      existing.cancel()
      artworkRequests.removeValue(forKey: show.identityPath)
    }
    let requestID = UUID()
    let request = WelcomeArtworkRequest(id: requestID, show: show) { [weak self] artwork in
      guard let self else { return }
      guard self.artworkRequests[show.identityPath]?.id == requestID else { return }
      defer { self.artworkRequests.removeValue(forKey: show.identityPath) }
      guard self.coordinator.isCurrent(generation),
            self.showFolders.contains(where: {
              $0.identityPath == show.identityPath && $0.resumeURL == show.resumeURL && $0.position == show.position
            }),
            let artwork else { return }
      self.showFolderArtworkCache[cacheName] = (show.position, artwork)
      self.showFolderShelf.setThumbnail(artwork, for: show)
    }
    artworkRequests[show.identityPath] = request
    request.start()
  }

  @objc private func openShowFolderCard(_ sender: NSButton) {
    guard let identifier = sender.identifier?.rawValue,
          let show = showFolders.first(where: { $0.identityPath == identifier }) else { return }
    openMedia(show.resumeURL)
  }

  private func openMedia(_ url: URL) {
    openRequestGeneration &+= 1
    let generation = openRequestGeneration
    let player = self.player!
    mediaOpenQueue.cancelAllOperations()
    let operation = BlockOperation()
    operation.addExecutionBlock { [weak self, weak operation] in
      guard operation?.isCancelled == false,
            let media = player.prepareWelcomeMedia(url), operation?.isCancelled == false else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.openRequestGeneration == generation,
              self.window?.isVisible == true else { return }
        player.openPreparedWelcomeMedia(media)
      }
    }
    mediaOpenQueue.addOperation(operation)
  }

  private func selectRecentDocument(at index: Int) {
    guard recentDocuments.indices.contains(index), recentDocuments[index].isAvailable else { return }
    isRecentListKeyboardActive = true
    showFolderShelf.setKeyboardSelectedCard(identityPath: nil)
    let id = documentIdentity(recentDocuments[index].url)
    recentListModel.selection = id
    recentListModel.revealID = id
  }

  @objc private func dismissShowFolderCard(_ sender: NSMenuItem) {
    guard let identifier = sender.representedObject as? String,
          let show = showFolders.first(where: { $0.identityPath == identifier }) else { return }
    ShowFolderDismissalStore.dismiss(show)
    showFolders.removeAll { $0.identityPath == identifier }
    ShowFolderSnapshotStore.save(showFolders)
    showFolderShelf.dismissCard(for: show) { [weak self] in
      guard let self else { return }
      self.showFolderShelf.isHidden = self.showFolders.isEmpty
      self.coordinator.invalidate()
      self.cancelArtworkRequests()
      self.showFolderShelf.reload(shows: self.showFolders, target: self,
                                 openAction: #selector(self.openShowFolderCard(_:)),
                                 dismissAction: #selector(self.dismissShowFolderCard(_:)))
      let generation = self.coordinator.currentGeneration
      let cards = self.showFolders
      let cachedArtwork = self.showFolderArtworkCache
      self.availabilityQueue.async { [weak self] in
        self?.loadShowFolderArtwork(for: cards, generation: generation, cachedArtwork: cachedArtwork)
      }
      self.reloadRecents()
      self.updateRecentLayout(resetScrollPosition: true)
      self.updateEmptyState()
    }
  }

  private func setMaterial(_ theme: Preference.Theme?) {
    guard let window, let theme else { return }
    window.appearance = NSAppearance(yinaTheme: theme)
    shelfWindow?.appearance = window.appearance
  }



  private func openRecentItemFromTable(_ rowIndex: Int) {
    if let document = recentDocuments[at: rowIndex], document.isAvailable {
      openMedia(document.url)
    }
  }

  func reloadData() {
    coordinator.invalidate()
    cancelArtworkRequests()
    restoreWelcomeSnapshot()
    reloadRecents()
    reloadShowFolders()
  }

  // AppDelegate refreshes this controller through the historical selector.
  // The rebuilt welcome surface derives all of its state in reloadData().
  func loadLastPlaybackInfo() { }

  private func restoreWelcomeSnapshot() {
    let cachedCards = showFolders.isEmpty ? ShowFolderSnapshotStore.loadCards() : []
    if !cachedCards.isEmpty {
      displayShowFolders(cachedCards, saveSnapshot: false)
      let generation = coordinator.currentGeneration
      let cachedArtwork = showFolderArtworkCache
      availabilityQueue.async { [weak self] in
        self?.loadShowFolderArtwork(for: cachedCards, generation: generation, cachedArtwork: cachedArtwork)
      }
    }

    let cardsForExclusion = cachedCards.isEmpty ? showFolders : cachedCards
    let collapsedFolderPaths = Set(cardsForExclusion.compactMap {
      $0.kind == .folder ? $0.folderURL.path : nil
    })
    let collapsedDocumentIdentities = Set(cardsForExclusion.compactMap {
      $0.kind == .file ? documentIdentity($0.resumeURL) : nil
    })
    let cachedURLs = recentDocuments.isEmpty ? WelcomeRecentSnapshotStore.load().filter { url in
      if url.isFileURL,
         collapsedFolderPaths.contains(url.deletingLastPathComponent().path) {
        return false
      }
      return !collapsedDocumentIdentities.contains(documentIdentity(url))
    } : []
    guard !cachedURLs.isEmpty else { return }
    recentDocuments = cachedURLs.prefix(Self.maximumRecentDocumentCount).map {
      RecentDocument(url: $0, isAvailable: true)
    }
    publishRecentItems()
    updateRecentLayout(resetScrollPosition: true)
    updateEmptyState()
  }

  private func displayShowFolders(_ cards: [ShowFolder], saveSnapshot: Bool) {
    let previousCardIdentities = showFolders.map(\.identityPath)
    let cardIdentities = cards.map(\.identityPath)
    showFolders = cards
    if saveSnapshot {
      ShowFolderSnapshotStore.save(cards)
    }
    showFolderShelf.reload(shows: cards,
                           target: self,
                           openAction: #selector(openShowFolderCard(_:)),
                           dismissAction: #selector(dismissShowFolderCard(_:)))
    if previousCardIdentities != cardIdentities {
      showFolderShelf.resetHorizontalScrollPosition()
    }
    showFolderShelf.setKeyboardSelectedCard(
      identityPath: isRecentListKeyboardActive ? nil : cards.first?.identityPath)
    let hasShows = !cards.isEmpty
    let shelfVisibilityChanged = showFolderShelf.isHidden == hasShows
    showFolderShelf.isHidden = !hasShows
    if shelfVisibilityChanged { showFolderShelf.layoutSubtreeIfNeeded() }
    updateRecentLayout(resetScrollPosition: previousCardIdentities != cardIdentities)
    updateEmptyState()
    if previousCardIdentities.isEmpty, !cardIdentities.isEmpty, window?.isVisible == true {
      centerWelcomeComposition()
    }
  }

  private func reloadRecents() {
    if !isRecentListKeyboardActive {
      recentListModel.selection = nil
      showFolderShelf.setKeyboardSelectedCard(identityPath: showFolders.first?.identityPath)
    }
    let generation = coordinator.currentGeneration
    let collapsedFolderPaths = Set(showFolders.compactMap {
      $0.kind == .folder ? $0.folderURL.path : nil
    })
    let collapsedDocumentIdentities = Set(showFolders.compactMap {
      $0.kind == .file ? documentIdentity($0.resumeURL) : nil
    })
    let appKitRecents = AppEnvironment.isCleanStart || Preference.bool(for: .recordRecentFiles)
      ? [] : NSDocumentController.shared.recentDocumentURLs
    let previousAvailability = Dictionary(uniqueKeysWithValues: recentDocuments.map {
      (documentIdentity($0.url), $0.isAvailable)
    })
    recentDocumentsQueue.async { [weak self] in
      guard let self else { return }
      let documents = self.makeRecentDocumentsList(
        excludingFolderPaths: collapsedFolderPaths,
        excludingDocumentIdentities: collapsedDocumentIdentities,
        appKitRecents: appKitRecents,
        previousAvailability: previousAvailability)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.coordinator.isCurrent(generation) else { return }
        let previousDocuments = self.recentDocuments
        self.recentDocuments = documents
        WelcomeRecentSnapshotStore.save(documents.map(\.url))
        let documentListChanged = previousDocuments.count != documents.count ||
          zip(previousDocuments, documents).contains { old, new in
            self.documentIdentity(old.url) != self.documentIdentity(new.url) ||
              old.isAvailable != new.isAvailable
          }
        if documentListChanged {
          self.publishRecentItems()
        }
        self.updateRecentLayout()
        self.updateEmptyState()
        if self.window?.isVisible == true {
          self.refreshRecentDocumentAvailability()
        }

        if Logger.isEmitting(.verbose) {
          for (index, url) in appKitRecents.enumerated() {
            Logger.log("InitialWindow.reloadData(): RecentDocuments_Unfiltered[\(index)]: \(url.path)", level: .verbose)
          }
          for (index, document) in documents.enumerated() {
            Logger.log("InitialWindow.reloadData(): Loaded RecentDocuments[\(index)]: \(document.url.path), available: \(document.isAvailable)", level: .verbose)
          }
        }
      }
    }
  }

  private var recentTopInset: CGFloat {
    showFolders.isEmpty ? Self.recentListTopInset : ShowFolderShelfView.height / 2 - ShowFolderCardView.size.height / 4
  }

  private var recentMinimumHeight: CGFloat {
    recentTopInset + CGFloat((32 + 2) * Self.minimumVisibleRecentRows) + Self.recentListBottomInset
  }

  private var recentStartingHeight: CGFloat {
    min(Self.maximumRecentWindowHeight,
        max(recentMinimumHeight, recentTopInset + CGFloat((32 + 2) * recentDocuments.count) + Self.recentListBottomInset))
  }

  private func updateRecentLayout(resetScrollPosition: Bool = false, preserveTop: Bool = true) {
    recentLayoutRevision &+= 1
    recentResizePending = false
    if resetScrollPosition {
      recentScrollOffset = 0
      recentListModel.resetID += 1
    }
    recentListModel.topInset = recentTopInset
    recentListModel.coveredTop = showFolders.isEmpty ? 0 : ShowFolderCardView.size.height / 4
    window?.contentMinSize = NSSize(width: Self.recentListWidth, height: recentMinimumHeight)
    window?.contentMaxSize = NSSize(width: Self.recentListWidth, height: Self.maximumRecentWindowHeight)
    resizeRecentWindow(preserveTop: preserveTop)
  }

  private func recentListDidScroll(_ offset: CGFloat) {
    guard offset.isFinite else { return }
    recentScrollOffset = max(0, offset)
    guard window?.isVisible == true, !recentResizePending else { return }
    recentResizePending = true
    let revision = recentLayoutRevision
    DispatchQueue.main.async { [weak self] in
      guard let self, revision == self.recentLayoutRevision else { return }
      self.recentResizePending = false
      guard self.window?.isVisible == true else { return }
      self.resizeRecentWindow(preserveTop: true)
    }
  }

  private func resizeRecentWindow(preserveTop: Bool) {
    guard let window else { return }
    // Follow the remaining initial viewport, not the entire scroll document.
    let height = max(recentMinimumHeight, recentStartingHeight - recentScrollOffset)
    guard height.isFinite, abs((window.contentView?.frame.height ?? 0) - height) > 0.5 else { return }
    let top = window.frame.maxY
    mainViewHeightConstraint?.constant = height
    window.setContentSize(NSSize(width: Self.recentListWidth, height: height))
    mainView.layoutSubtreeIfNeeded()
    if preserveTop && window.isVisible {
      window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
    }
    updateShelfWindowFrame()
  }

  private func cancelArtworkRequests() {
    artworkRequests.values.forEach { $0.cancel() }
    artworkRequests.removeAll()
  }
}

extension InitialWindowController {
  private var selectedRecentRow: Int {
    guard let id = recentListModel.selection else { return -1 }
    return recentDocuments.firstIndex { documentIdentity($0.url) == id } ?? -1
  }

  private func publishRecentItems() {
    recentListModel.items = recentDocuments.map { document in
      WelcomeRecentItem(id: documentIdentity(document.url),
                        title: Preference.bool(for: .showExtensions) ? document.url.lastPathComponent : document.url.deletingPathExtension().lastPathComponent,
                        icon: documentIcon(for: document), available: document.isAvailable)
    }
    if let id = recentListModel.selection,
       !recentListModel.items.contains(where: { $0.id == id && $0.available }) {
      recentListModel.selection = nil
    }
  }

  private func documentIcon(for document: RecentDocument) -> NSImage {
    let ext = document.url.pathExtension.lowercased()
    if let icon = documentIconCache[ext] { return icon }
    // Use a visible system document symbol until Launch Services resolves the
    // extension's associated file icon in the background.
    let placeholder = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
      ?? NSWorkspace.shared.icon(for: .data)
    guard !ext.isEmpty, pendingIconExtensions.insert(ext).inserted else { return placeholder }
    iconQueue.async { [weak self] in
      let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.pendingIconExtensions.remove(ext)
        self.documentIconCache[ext] = icon
        let rows = IndexSet(self.recentDocuments.indices.filter {
          self.recentDocuments[$0].url.pathExtension.lowercased() == ext
        })
        if !rows.isEmpty {
          self.publishRecentItems()
        }
      }
    }
    return placeholder
  }

  override func keyDown(with event: NSEvent) {
    let keyChar = KeyCodeHelper.keyMap[event.keyCode]?.0
    switch keyChar {
      case "ENTER", "KP_ENTER":  // RETURN or (keypad ENTER)
        if isRecentListKeyboardActive {
          if recentDocuments.indices.contains(selectedRecentRow) {
            openRecentItemFromTable(selectedRecentRow)
          }
        } else if let show = showFolders.first {
          openMedia(show.resumeURL)
        } else if let firstAvailable = recentDocuments.firstIndex(where: \.isAvailable) {
          openMedia(recentDocuments[firstAvailable].url)
        }
      case "DOWN":  // DOWN arrow
        if !isRecentListKeyboardActive {
          guard let firstAvailable = recentDocuments.firstIndex(where: \.isAvailable) else {
            super.keyDown(with: event)
            return
          }
          selectRecentDocument(at: firstAvailable)
        } else {
          let selectedRow = selectedRecentRow
          let nextAvailable = recentDocuments.indices.first { index in
            index > selectedRow && recentDocuments[index].isAvailable
          }
          if let nextAvailable {
            selectRecentDocument(at: nextAvailable)
          }
        }
      case "UP":  // UP arrow
        if isRecentListKeyboardActive {
          let selectedRow = selectedRecentRow
          let previousAvailable = recentDocuments.indices.reversed().first { index in
            index < selectedRow && recentDocuments[index].isAvailable
          }
          if let previousAvailable {
            selectRecentDocument(at: previousAvailable)
          } else {
            recentListModel.selection = nil
            isRecentListKeyboardActive = false
            showFolderShelf.setKeyboardSelectedCard(identityPath: showFolders.first?.identityPath)
          }
        } else {
          super.keyDown(with: event)
        }
      default:
        super.keyDown(with: event)
    }
  }

}

private struct WelcomeRecentItem: Identifiable {
  let id: String
  let title: String
  let icon: NSImage
  let available: Bool
}

@MainActor
private final class WelcomeRecentsModel: ObservableObject {
  @Published var items: [WelcomeRecentItem] = []
  @Published var selection: String? { didSet { selectionChanged?(selection) } }
  @Published var revealID: String?
  @Published var topInset: CGFloat = 32
  @Published var coveredTop: CGFloat = 0
  @Published var resetID = 0
  var open: ((String) -> Void)?
  var scrolled: ((CGFloat) -> Void)?
  var selectionChanged: ((String?) -> Void)?
}

private struct WelcomeRecentsView: View {
  @ObservedObject var model: WelcomeRecentsModel

  var body: some View {
    ScrollViewReader { scroll in
      List(selection: $model.selection) {
        ForEach(model.items) { item in
          Button {
            guard item.available else { return }
            model.selection = item.id
            model.open?(item.id)
          } label: {
            HStack(spacing: 8) {
              Image(nsImage: item.icon).resizable().scaledToFit().frame(width: 16, height: 16)
              Text(item.title).font(.system(size: NSFont.systemFontSize)).lineLimit(1)
              Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .opacity(item.available ? 1 : 0.45)
          .selectionDisabled(!item.available)
          .tag(item.id)
          .id(item.id)
          .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
        }
      }
      .listStyle(.plain)
      .environment(\.defaultMinListRowHeight, 0)
      .scrollContentBackground(.hidden)
      .contentMargins(.horizontal, 0, for: .scrollContent)
      .contentMargins(.top, max(0, model.topInset - model.coveredTop), for: .scrollContent)
      .contentMargins(.bottom, 16, for: .scrollContent)
      .scrollEdgeEffectStyle(.soft, for: .top)
      .scrollEdgeEffectHidden(true, for: .bottom)
      .safeAreaBar(edge: .top, spacing: 0) {
        Color.clear.frame(height: model.coveredTop).allowsHitTesting(false)
      }
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        let offset = geometry.contentOffset.y + geometry.contentInsets.top
        return offset.isFinite ? offset : 0
      } action: { _, offset in
        model.scrolled?(offset)
      }
      .onChange(of: model.revealID) { _, id in
        if let id { scroll.scrollTo(id) }
      }
      .onKeyPress(.return) {
        guard let id = model.selection,
              model.items.contains(where: { $0.id == id && $0.available }) else { return .ignored }
        model.open?(id)
        return .handled
      }
      .id(model.resetID)
    }
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
private enum WelcomeFolderClassification {
  case show
  case notShow
  case unavailable
}

private final class WelcomeFolderClassificationCache {
  private struct Entry {
    let modificationDate: Date?
    let isShow: Bool
  }

  private let lock = NSLock()
  private var values: [String: Entry] = [:]

  func classification(of folderURL: URL,
                      playableExtensions: Set<String>) -> WelcomeFolderClassification {
    let path = folderURL.standardizedFileURL.path
    guard let resourceValues = try? folderURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
          resourceValues.isDirectory == true else { return .unavailable }
    let modificationDate = resourceValues.contentModificationDate
    lock.lock()
    if let entry = values[path], entry.modificationDate == modificationDate {
      lock.unlock()
      return entry.isShow ? .show : .notShow
    }
    lock.unlock()

    let result: Bool
    if let contents = try? FileManager.default.contentsOfDirectory(
      at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
      let playableFiles = contents.filter { playableExtensions.contains($0.pathExtension.lowercased()) }
      result = ShowFolder.isEpisodeCollection(playableFiles)
    } else {
      return .unavailable
    }
    lock.lock()
    values[path] = Entry(modificationDate: modificationDate, isShow: result)
    lock.unlock()
    return result ? .show : .notShow
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
  private let completion: (ShowFolderCardArtwork?) -> Void
  private let controller = FFmpegController()
  private let lifecycleQueue = DispatchQueue(label: "YINAWelcomeArtworkLifecycle", qos: .utility)

  init(id: UUID, show: ShowFolder, completion: @escaping (ShowFolderCardArtwork?) -> Void) {
    self.id = id
    self.show = show
    self.completion = completion
    super.init()
    controller.delegate = self
    controller.thumbnailCount = 1
  }

  static func cacheName(for show: ShowFolder) -> String {
    "welcome-artwork-960-\(show.thumbnailCacheName)"
  }

  func matches(_ show: ShowFolder) -> Bool {
    self.show.resumeURL == show.resumeURL && self.show.position == show.position
  }

  func start() {
    lifecycleQueue.async { [self] in
      controller.generateThumbnail(forFile: show.resumeURL.path, atTime: show.position, thumbWidth: 960)
    }
  }

  func cancel() {
    lifecycleQueue.async { [self] in controller.cancelThumbnailGeneration() }
  }

  func didUpdate(_ thumbnails: [FFThumbnail]?, forFile filename: String, withProgress progress: Int) {
    // A single saved-position frame has no intermediate UI state.
  }

  func didGenerate(_ thumbnails: [FFThumbnail], forFile filename: String, succeeded: Bool) {
    let thumbnail = succeeded ? thumbnails.first : nil
    if let thumbnail {
      ThumbnailCache.write([thumbnail], forName: Self.cacheName(for: show), forVideo: show.resumeURL)
    }
    // Finish image preparation before handing immutable pixels to AppKit.
    let artwork = thumbnail?.image.flatMap { ShowFolderCardArtwork.make(from: $0) }
    DispatchQueue.main.async { [completion] in
      completion(artwork)
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
    return player.openFromPasteboard(sender, useGlobalOpenRouting: true)
  }

}
