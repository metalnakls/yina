//
//  ShowFolder.swift
//  yina
//

import Cocoa

struct ShowFolderHistoryItem {
  let url: URL
  let lastPlayedAt: Date
  let position: Double
  let duration: Double
  let thumbnailCacheName: String
}

struct ShowFolder: Equatable {
  enum Kind: Equatable {
    case folder
    case file
  }

  static let inactivityInterval: TimeInterval = 60 * 24 * 60 * 60

  let kind: Kind
  let folderURL: URL
  /// The visually dominant card title: show name for folders, filename for standalone items.
  let primaryTitle: String
  let resumeURL: URL
  /// Supporting context: episode filename for shows, containing folder for standalone items.
  let secondaryTitle: String
  let lastPlayedAt: Date
  let position: Double
  let duration: Double
  let thumbnailCacheName: String

  var identityPath: String {
    switch kind {
    case .folder: folderURL.standardizedFileURL.path
    case .file: resumeURL.standardizedFileURL.path
    }
  }

  var progress: Double {
    guard duration.isFinite, duration > 0 else { return 0 }
    return min(max(position / duration, 0), 1)
  }

  /// The actual file that will resume, independent of its visual position on the card.
  var resumeItemTitle: String {
    Self.fileDisplayName(for: resumeURL)
  }

  /// The folder or show containing the resumable file.
  var containerTitle: String {
    folderURL.lastPathComponent
  }

  var resumeActionLabel: String {
    "Resume \(resumeItemTitle)"
  }

  var resumeActionHelp: String {
    "Opens \(resumeItemTitle) from \(containerTitle) at your saved position"
  }

  private static func fileDisplayName(for url: URL) -> String {
    url.deletingPathExtension().lastPathComponent
  }

  /// A folder is only a show when its playable files consistently identify
  /// episodes. Folder size or container metadata are not classification signals.
  static func isEpisodeFileURL(_ url: URL) -> Bool {
    let name = fileDisplayName(for: url)
    let pattern = #"(?i)(?:^|[^a-z0-9])(?:s\d{1,3}(?:[\s._-]*e\d{1,4})+|\d{1,3}x\d{1,4}|ep(?:isode)?[\s._-]*\d{1,4})(?:[^a-z0-9]|$)"#
    return name.range(of: pattern, options: .regularExpression) != nil
  }

  static func isEpisodeCollection(_ urls: [URL]) -> Bool {
    var paths = Set<String>()
    let distinctURLs = urls.filter { paths.insert($0.standardizedFileURL.path).inserted }
    return distinctURLs.count >= 2 && distinctURLs.allSatisfy(isEpisodeFileURL)
  }

  static func groupedFolderPaths(from items: [ShowFolderHistoryItem],
                                 volumeRootPaths: Set<String> = mountedVolumeRootPaths()) -> Set<String> {
    let grouped = Dictionary(grouping: items.filter(\.url.isFileURL)) {
      $0.url.deletingLastPathComponent().standardizedFileURL.path
    }
    return Set(grouped.compactMap { path, entries in
      guard !volumeRootPaths.contains(path), !isVolumeRootPath(path),
            isEpisodeCollection(entries.map(\.url)) else { return nil }
      return path
    })
  }

  static func make(from items: [ShowFolderHistoryItem], folderPaths: Set<String>? = nil,
                   now: Date = Date(),
                   inactivityInterval: TimeInterval = inactivityInterval,
                   dismissedAtByFolder: [String: Date] = [:],
                   volumeRootPaths: Set<String> = mountedVolumeRootPaths()) -> [ShowFolder] {
    let grouped = Dictionary(grouping: items.filter(\.url.isFileURL)) {
      $0.url.deletingLastPathComponent().standardizedFileURL.path
    }

    return grouped.values.compactMap { entries in
      guard let latest = entries.max(by: { $0.lastPlayedAt < $1.lastPlayedAt }) else { return nil }
      let folderURL = latest.url.deletingLastPathComponent().standardizedFileURL
      let isShowFolder = folderPaths?.contains(folderURL.path) ?? isEpisodeCollection(entries.map(\.url))
      guard isShowFolder,
            now.timeIntervalSince(latest.lastPlayedAt) <= inactivityInterval else { return nil }
      guard !volumeRootPaths.contains(folderURL.path), !isVolumeRootPath(folderURL.path) else { return nil }
      if let dismissedAt = dismissedAtByFolder[folderURL.path], latest.lastPlayedAt <= dismissedAt {
        return nil
      }
      return ShowFolder(kind: .folder,
                        folderURL: folderURL,
                        primaryTitle: folderURL.lastPathComponent,
                        resumeURL: latest.url,
                        // Filename is authoritative for the episode line. Do not
                        // replace it with noisy container media-title metadata.
                        secondaryTitle: fileDisplayName(for: latest.url),
                        lastPlayedAt: latest.lastPlayedAt,
                        position: latest.position,
                        duration: latest.duration,
                        thumbnailCacheName: latest.thumbnailCacheName)
    }.sorted { lhs, rhs in
      if lhs.lastPlayedAt != rhs.lastPlayedAt { return lhs.lastPlayedAt > rhs.lastPlayedAt }
      return lhs.primaryTitle.localizedStandardCompare(rhs.primaryTitle) == .orderedAscending
    }
  }

  static func makeLatestFile(from items: [ShowFolderHistoryItem], excludingFolderPaths: Set<String>,
                             now: Date = Date(), inactivityInterval: TimeInterval = inactivityInterval,
                             dismissedAtByFolder: [String: Date] = [:]) -> ShowFolder? {
    guard let latest = items.filter(\.url.isFileURL).max(by: { $0.lastPlayedAt < $1.lastPlayedAt }) else {
      return nil
    }
    let url = latest.url.standardizedFileURL
    guard now.timeIntervalSince(latest.lastPlayedAt) <= inactivityInterval,
          !excludingFolderPaths.contains(url.deletingLastPathComponent().path) else { return nil }
    if let dismissedAt = dismissedAtByFolder[url.path], latest.lastPlayedAt <= dismissedAt {
      return nil
    }
    return ShowFolder(kind: .file,
                      folderURL: url.deletingLastPathComponent(),
                      primaryTitle: fileDisplayName(for: latest.url),
                      resumeURL: url,
                      secondaryTitle: url.deletingLastPathComponent().lastPathComponent,
                      lastPlayedAt: latest.lastPlayedAt,
                      position: latest.position,
                      duration: latest.duration,
                      thumbnailCacheName: latest.thumbnailCacheName)
  }

  static func mountedVolumeRootPaths() -> Set<String> {
    Set(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                               options: [.skipHiddenVolumes])?
      .map { $0.standardizedFileURL.path } ?? [])
  }

  /// A disconnected share is no longer reported by the workspace as mounted,
  /// but history URLs still identify the mount root unambiguously.
  static func isVolumeRootPath(_ path: String) -> Bool {
    URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
      .deletingLastPathComponent().path == "/Volumes"
  }
}

enum ShowFolderSnapshotStore {
  private static let key = "YINAWelcomeShelfSnapshotV1"
  private static let cardsKey = "YINAWelcomeShelfCardsV1"

  private struct Card: Codable {
    let isFolder: Bool
    let folderURL: String
    let primaryTitle: String
    let resumeURL: String
    let secondaryTitle: String
    let lastPlayedAt: Date
    let position: Double
    let duration: Double
    let thumbnailCacheName: String

    init(_ show: ShowFolder) {
      isFolder = show.kind == .folder
      folderURL = show.folderURL.absoluteString
      primaryTitle = show.primaryTitle
      resumeURL = show.resumeURL.absoluteString
      secondaryTitle = show.secondaryTitle
      lastPlayedAt = show.lastPlayedAt
      position = show.position
      duration = show.duration
      thumbnailCacheName = show.thumbnailCacheName
    }

    var show: ShowFolder? {
      guard let folderURL = URL(string: folderURL),
            let resumeURL = URL(string: resumeURL) else { return nil }
      return ShowFolder(kind: isFolder ? .folder : .file,
                        folderURL: folderURL,
                        primaryTitle: primaryTitle,
                        resumeURL: resumeURL,
                        secondaryTitle: secondaryTitle,
                        lastPlayedAt: lastPlayedAt,
                        position: position,
                        duration: duration,
                        thumbnailCacheName: thumbnailCacheName)
    }
  }

  static func load(defaults: UserDefaults = .standard) -> Set<String> {
    Set(defaults.stringArray(forKey: key) ?? [])
  }

  static func save(_ folderPaths: Set<String>, defaults: UserDefaults = .standard) {
    defaults.set(folderPaths.sorted(), forKey: key)
  }

  static func loadCards(now: Date = Date(), defaults: UserDefaults = .standard) -> [ShowFolder] {
    guard let data = defaults.data(forKey: cardsKey),
          let cards = try? PropertyListDecoder().decode([Card].self, from: data) else { return [] }
    return cards.compactMap(\.show).filter {
      now.timeIntervalSince($0.lastPlayedAt) <= ShowFolder.inactivityInterval
    }
  }

  static func save(_ shows: [ShowFolder], defaults: UserDefaults = .standard) {
    let cards = shows.map(Card.init)
    if let data = try? PropertyListEncoder().encode(cards) {
      defaults.set(data, forKey: cardsKey)
    }
    save(Set(shows.compactMap {
      $0.kind == .folder ? $0.folderURL.standardizedFileURL.path : nil
    }), defaults: defaults)
  }
}

enum WelcomeRecentSnapshotStore {
  private static let key = "YINAWelcomeRecentDocumentsV1"

  private struct Snapshot: Codable {
    let savedAt: Date
    let urls: [String]
  }

  static func load(now: Date = Date(), defaults: UserDefaults = .standard) -> [URL] {
    guard let data = defaults.data(forKey: key),
          let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: data),
          now.timeIntervalSince(snapshot.savedAt) <= ShowFolder.inactivityInterval else { return [] }
    return snapshot.urls.compactMap(URL.init(string:))
  }

  static func save(_ urls: [URL], defaults: UserDefaults = .standard) {
    let snapshot = Snapshot(savedAt: Date(), urls: urls.map(\.absoluteString))
    if let data = try? PropertyListEncoder().encode(snapshot) {
      defaults.set(data, forKey: key)
    }
  }
}

enum ShowFolderDismissalStore {
  private static let key = "YINADismissedShowFolders"

  static func dismissedAtByFolder(defaults: UserDefaults = .standard) -> [String: Date] {
    guard let values = defaults.dictionary(forKey: key) as? [String: TimeInterval] else { return [:] }
    return values.mapValues(Date.init(timeIntervalSince1970:))
  }

  static func dismiss(_ show: ShowFolder, at date: Date = Date(), defaults: UserDefaults = .standard) {
    var values = defaults.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
    values[show.identityPath] = date.timeIntervalSince1970
    defaults.set(values, forKey: key)
  }
}

private enum ShowFolderCardMetrics {
  static let size = NSSize(width: 240, height: 128)
  // A taller card needs a larger radius to carry the same visual curvature as the 24-point floating OSC.
  static let cornerRadius: CGFloat = 32
  static let contentInset: CGFloat = 20
  static let controlSpacing: CGFloat = 12
  static let playButtonSize: CGFloat = 48
  static let progressLineWidth: CGFloat = 2
}

struct ShowFolderCardArtwork {
  let image: CGImage

  static func make(from image: NSImage) -> ShowFolderCardArtwork? {
    var proposedRect = NSRect(origin: .zero, size: image.size)
    guard let source = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else { return nil }
    return ShowFolderCardArtwork(image: source)
  }
}

final class ShowFolderCardView: NSView {
  static let size = ShowFolderCardMetrics.size

  private let glassView = NSGlassEffectView()
  private let cardContentView = NSView()
  private let artworkView = ShowFolderArtworkView()
  private let artworkLegibilityEffect = NSVisualEffectView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let episodeLabel = NSTextField(labelWithString: "")
  private let playButton = NSButton()
  private let button = NSButton()
  private let progressView = ShowFolderCardProgressView()
  private(set) var show: ShowFolder
  private(set) var hasThumbnail = false

  init(show: ShowFolder, target: AnyObject, openAction: Selector, dismissAction: Selector) {
    self.show = show
    super.init(frame: NSRect(origin: .zero, size: Self.size))
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.masksToBounds = false
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.20
    layer?.shadowRadius = 9
    layer?.shadowOffset = NSSize(width: 0, height: -5)

    glassView.translatesAutoresizingMaskIntoConstraints = false
    glassView.style = .clear
    glassView.cornerRadius = ShowFolderCardMetrics.cornerRadius
    glassView.effectIsInteractive = true
    glassView.contentView = cardContentView

    artworkView.translatesAutoresizingMaskIntoConstraints = false

    artworkLegibilityEffect.translatesAutoresizingMaskIntoConstraints = false
    artworkLegibilityEffect.material = .hudWindow
    artworkLegibilityEffect.blendingMode = .withinWindow
    artworkLegibilityEffect.state = .active
    artworkLegibilityEffect.maskImage = Self.makeLegibilityMask()

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = NSFontManager.shared.convert(.preferredFont(forTextStyle: .title2),
                                                   toHaveTrait: .boldFontMask)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.stringValue = show.primaryTitle

    episodeLabel.translatesAutoresizingMaskIntoConstraints = false
    episodeLabel.font = .preferredFont(forTextStyle: .footnote)
    episodeLabel.textColor = .secondaryLabelColor
    episodeLabel.lineBreakMode = .byTruncatingTail
    episodeLabel.stringValue = show.secondaryTitle

    playButton.translatesAutoresizingMaskIntoConstraints = false
    playButton.isBordered = false
    let playConfiguration = NSImage.SymbolConfiguration(
      pointSize: max(32, NSFont.preferredFont(forTextStyle: .largeTitle).pointSize),
      weight: .bold)
    playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Resume")?
      .withSymbolConfiguration(playConfiguration)
    playButton.contentTintColor = .labelColor
    playButton.imagePosition = .imageOnly
    playButton.wantsLayer = true
    playButton.layer?.shadowColor = NSColor.black.cgColor
    playButton.layer?.shadowOpacity = 0.82
    playButton.layer?.shadowRadius = 3
    playButton.layer?.shadowOffset = NSSize(width: 0, height: -1)
    playButton.target = target
    playButton.action = openAction
    playButton.identifier = NSUserInterfaceItemIdentifier(show.identityPath)
    playButton.setAccessibilityLabel(show.resumeActionLabel)

    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.title = ""
    button.target = target
    button.action = openAction
    button.identifier = NSUserInterfaceItemIdentifier(show.identityPath)
    button.toolTip = "\(show.resumeActionLabel) — \(show.containerTitle)"
    button.setAccessibilityLabel(show.resumeActionLabel)
    button.setAccessibilityHelp(show.resumeActionHelp)

    let contextMenu = NSMenu()
    let dismissItem = NSMenuItem(title: "Dismiss",
                                 action: dismissAction,
                                 keyEquivalent: "")
    dismissItem.target = target
    dismissItem.representedObject = show.identityPath
    contextMenu.addItem(dismissItem)
    menu = contextMenu
    button.menu = contextMenu
    playButton.menu = contextMenu

    addSubview(glassView)
    progressView.translatesAutoresizingMaskIntoConstraints = false
    [artworkView, artworkLegibilityEffect, titleLabel, episodeLabel, button, playButton, progressView]
      .forEach(cardContentView.addSubview)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: Self.size.width),
      heightAnchor.constraint(equalToConstant: Self.size.height),
      glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
      glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
      glassView.topAnchor.constraint(equalTo: topAnchor),
      glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
      artworkView.leadingAnchor.constraint(equalTo: cardContentView.leadingAnchor),
      artworkView.trailingAnchor.constraint(equalTo: cardContentView.trailingAnchor),
      artworkView.topAnchor.constraint(equalTo: cardContentView.topAnchor),
      artworkView.bottomAnchor.constraint(equalTo: cardContentView.bottomAnchor),
      artworkLegibilityEffect.leadingAnchor.constraint(equalTo: cardContentView.leadingAnchor),
      artworkLegibilityEffect.trailingAnchor.constraint(equalTo: cardContentView.trailingAnchor),
      artworkLegibilityEffect.topAnchor.constraint(equalTo: cardContentView.topAnchor),
      artworkLegibilityEffect.bottomAnchor.constraint(equalTo: cardContentView.bottomAnchor),
      // Give the drawing view room for the native Core Graphics shadow. The
      // path itself stays on the card perimeter, but its soft halo must not be
      // clipped at the card's rectangular backing store.
      progressView.leadingAnchor.constraint(equalTo: cardContentView.leadingAnchor, constant: -12),
      progressView.trailingAnchor.constraint(equalTo: cardContentView.trailingAnchor, constant: 12),
      progressView.topAnchor.constraint(equalTo: cardContentView.topAnchor, constant: -12),
      progressView.bottomAnchor.constraint(equalTo: cardContentView.bottomAnchor, constant: 12),
      titleLabel.leadingAnchor.constraint(equalTo: cardContentView.leadingAnchor,
                                          constant: ShowFolderCardMetrics.contentInset),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: playButton.leadingAnchor,
                                           constant: -ShowFolderCardMetrics.controlSpacing),
      episodeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      episodeLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      episodeLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
      episodeLabel.bottomAnchor.constraint(equalTo: cardContentView.bottomAnchor,
                                           constant: -ShowFolderCardMetrics.contentInset),
      playButton.trailingAnchor.constraint(equalTo: cardContentView.trailingAnchor,
                                           constant: -ShowFolderCardMetrics.contentInset),
      playButton.bottomAnchor.constraint(equalTo: cardContentView.bottomAnchor,
                                         constant: -ShowFolderCardMetrics.contentInset),
      playButton.widthAnchor.constraint(equalToConstant: ShowFolderCardMetrics.playButtonSize),
      playButton.heightAnchor.constraint(equalToConstant: ShowFolderCardMetrics.playButtonSize),
      button.leadingAnchor.constraint(equalTo: cardContentView.leadingAnchor),
      button.trailingAnchor.constraint(equalTo: cardContentView.trailingAnchor),
      button.topAnchor.constraint(equalTo: cardContentView.topAnchor),
      button.bottomAnchor.constraint(equalTo: cardContentView.bottomAnchor),
    ])
    updateThumbnailPresentation()
  }

  func setThumbnail(_ artwork: ShowFolderCardArtwork) {
    artworkView.artwork = artwork
    hasThumbnail = true
    updateThumbnailPresentation()
  }

  func update(show: ShowFolder) {
    let thumbnailChanged = self.show.thumbnailCacheName != show.thumbnailCacheName
    self.show = show
    if thumbnailChanged {
      artworkView.artwork = nil
      hasThumbnail = false
    }
    titleLabel.stringValue = show.primaryTitle
    episodeLabel.stringValue = show.secondaryTitle
    button.identifier = NSUserInterfaceItemIdentifier(show.identityPath)
    playButton.identifier = NSUserInterfaceItemIdentifier(show.identityPath)
    playButton.setAccessibilityLabel(show.resumeActionLabel)
    button.toolTip = "\(show.resumeActionLabel) — \(show.containerTitle)"
    button.setAccessibilityLabel(show.resumeActionLabel)
    button.setAccessibilityHelp(show.resumeActionHelp)
    updateThumbnailPresentation()
  }

  override func layout() {
    super.layout()
    let roundedPath = CGPath(roundedRect: bounds, cornerWidth: ShowFolderCardMetrics.cornerRadius,
                             cornerHeight: ShowFolderCardMetrics.cornerRadius, transform: nil)
    layer?.shadowPath = roundedPath

  }

  private func updateThumbnailPresentation() {
    titleLabel.textColor = hasThumbnail ? .white : .labelColor
    episodeLabel.textColor = hasThumbnail ? NSColor.white.withAlphaComponent(0.82) : .secondaryLabelColor
    playButton.contentTintColor = hasThumbnail ? .white : .labelColor
    progressView.usesLightTrack = hasThumbnail
    progressView.set(progress: show.progress, position: show.position, duration: show.duration)
    glassView.style = hasThumbnail ? .clear : .regular
    artworkLegibilityEffect.isHidden = !hasThumbnail
  }

  private static func makeLegibilityMask() -> NSImage {
    let size = ShowFolderCardMetrics.size
    let image = NSImage(size: size, flipped: false) { rect in
      guard let context = NSGraphicsContext.current?.cgContext,
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                      colors: [NSColor(deviceWhite: 1, alpha: 1).cgColor,
                                               NSColor(deviceWhite: 0, alpha: 0).cgColor] as CFArray,
                                      locations: [0, 1]) else { return false }
      context.drawRadialGradient(gradient,
                                 startCenter: CGPoint(x: rect.minX, y: rect.minY), startRadius: 0,
                                 endCenter: CGPoint(x: rect.minX, y: rect.minY),
                                 endRadius: rect.width * 0.72,
                                 options: [.drawsAfterEndLocation])
      return true
    }
    return image
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

enum ShowFolderProgressGeometry {
  struct StrokeSegment {
    let start: CGPoint
    let end: CGPoint
    let width: CGFloat
  }

  struct Result {
    let trackPath: CGPath
    let valuePath: CGPath?
    let valueSegments: [StrokeSegment]
    let valueLength: CGFloat
    let leadingCurveLength: CGFloat
    let straightLength: CGFloat

    var isVisible: Bool { valuePath != nil }
  }

  static func make(in bounds: CGRect, cornerRadius: CGFloat, progress: Double,
                   isEligible: Bool) -> Result {
    let inset = ShowFolderCardMetrics.progressLineWidth
    let radius = max(0, min(cornerRadius - inset, (bounds.height / 2) - inset))
    let centerY = radius + inset
    let leftCenterX = radius + inset
    let rightCenterX = bounds.width - radius - inset
    let straightLength = max(0, rightCenterX - leftCenterX)
    let leadingCurveLength = .pi * radius / 2
    let totalLength = max(1, straightLength + (2 * leadingCurveLength))
    let valueLength = CGFloat(min(max(progress, 0), 1)) * totalLength

    let trackPath = CGMutablePath()
    trackPath.move(to: CGPoint(x: inset, y: centerY))
    trackPath.addArc(center: CGPoint(x: leftCenterX, y: centerY), radius: radius,
                     startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
    trackPath.addLine(to: CGPoint(x: rightCenterX, y: inset))
    trackPath.addArc(center: CGPoint(x: rightCenterX, y: centerY), radius: radius,
                     startAngle: -.pi / 2, endAngle: 0, clockwise: false)

    guard isEligible, valueLength > leadingCurveLength else {
      return Result(trackPath: trackPath, valuePath: nil, valueSegments: [], valueLength: valueLength,
                    leadingCurveLength: leadingCurveLength, straightLength: straightLength)
    }

    let valuePath = CGMutablePath()
    valuePath.move(to: CGPoint(x: inset, y: centerY))
    valuePath.addArc(center: CGPoint(x: leftCenterX, y: centerY), radius: radius,
                     startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
    let remaining = valueLength - leadingCurveLength
    if remaining <= straightLength {
      valuePath.addLine(to: CGPoint(x: leftCenterX + remaining, y: inset))
    } else {
      valuePath.addLine(to: CGPoint(x: rightCenterX, y: inset))
      let rightCurveFraction = min(1, (remaining - straightLength) / max(leadingCurveLength, 1))
      valuePath.addArc(center: CGPoint(x: rightCenterX, y: centerY), radius: radius,
                       startAngle: -.pi / 2,
                       endAngle: (-.pi / 2) + ((.pi / 2) * rightCurveFraction),
                       clockwise: false)
    }
    // Sample the same perimeter into short segments so the trace can taper as
    // it enters/leaves the vertical portions of the rounded corners. A single
    // stroked path cannot express that width change and makes the old hard
    // blue border look especially heavy at the ends.
    var points = [CGPoint(x: inset, y: centerY)]
    let leftFraction = min(1, valueLength / max(leadingCurveLength, 1))
    let leftSamples = max(2, Int(ceil(12 * leftFraction)))
    for index in 1...leftSamples {
      let fraction = leftFraction * CGFloat(index) / CGFloat(leftSamples)
      let angle = CGFloat.pi + (CGFloat.pi / 2 * fraction)
      points.append(CGPoint(x: leftCenterX + cos(angle) * radius,
                            y: centerY + sin(angle) * radius))
    }
    let remainingForSegments = valueLength - leadingCurveLength
    if remainingForSegments > 0 {
      let lineFraction = min(1, remainingForSegments / max(straightLength, 1))
      let lineSamples = max(1, Int(ceil(16 * lineFraction)))
      for index in 1...lineSamples {
        let fraction = lineFraction * CGFloat(index) / CGFloat(lineSamples)
        points.append(CGPoint(x: leftCenterX + straightLength * fraction, y: inset))
      }
      if remainingForSegments > straightLength {
        let rightFraction = min(1, (remainingForSegments - straightLength) / max(leadingCurveLength, 1))
        let rightSamples = max(2, Int(ceil(12 * rightFraction)))
        for index in 1...rightSamples {
          let fraction = rightFraction * CGFloat(index) / CGFloat(rightSamples)
          let angle = -CGFloat.pi / 2 + (CGFloat.pi / 2 * fraction)
          points.append(CGPoint(x: rightCenterX + cos(angle) * radius,
                                y: centerY + sin(angle) * radius))
        }
      }
    }
    var distances = [CGFloat](repeating: 0, count: points.count)
    for index in 1..<points.count {
      let previousPoint = points[index - 1]
      let point = points[index]
      let segmentLength = hypot(point.x - previousPoint.x, point.y - previousPoint.y)
      distances[index] = distances[index - 1] + segmentLength
    }
    let sampledLength = max(distances.last ?? 1, 1)
    let taperLength = min(12, sampledLength / 3)
    let segments = zip(points, points.dropFirst()).enumerated().map { index, pair in
      let midpoint = (distances[index] + distances[index + 1]) / 2
      let leading = min(1, midpoint / max(taperLength, 1))
      let trailing = min(1, (sampledLength - midpoint) / max(taperLength, 1))
      return StrokeSegment(start: pair.0, end: pair.1,
                           width: ShowFolderCardMetrics.progressLineWidth *
                            max(0.22, min(1, min(leading, trailing))))
    }
    return Result(trackPath: trackPath, valuePath: valuePath, valueSegments: segments,
                  valueLength: valueLength, leadingCurveLength: leadingCurveLength,
                  straightLength: straightLength)
  }
}

private final class ShowFolderCardProgressView: NSView {
  private var progress = 0.0
  private var isEligible = false

  func set(progress: Double, position: Double, duration: Double) {
    self.progress = min(max(progress, 0), 1)
    isEligible = duration >= 60 && position >= 20
    needsDisplay = true
  }

  var usesLightTrack = false {
    didSet { needsDisplay = true }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let cardBounds = bounds.insetBy(dx: 12, dy: 12)
    let geometry = ShowFolderProgressGeometry.make(in: cardBounds,
                                                    cornerRadius: ShowFolderCardMetrics.cornerRadius,
                                                    progress: progress,
                                                    isEligible: isEligible)
    guard isEligible,
          let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.setLineCap(.round)
    guard geometry.valuePath != nil else {
      context.restoreGState()
      return
    }

    // A continuous wide pass establishes the diffuse trace. It is intentionally
    // not followed by an opaque one-pixel core: that is what made the previous
    // indicator read as a border rather than light reflected in the glass.
    context.saveGState()
    context.setLineWidth(ShowFolderCardMetrics.progressLineWidth * 4.5)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.13).cgColor)
    context.setShadow(offset: .zero, blur: 7,
                      color: NSColor.white.withAlphaComponent(0.58).cgColor)
    context.addPath(geometry.valuePath!)
    context.strokePath()
    context.restoreGState()
    // The tapered overlay only softens the two vertical ends; the full trace
    // above remains one uninterrupted path, eliminating segment seams.
    for segment in geometry.valueSegments {
      context.setLineWidth(segment.width)
      context.setStrokeColor(NSColor.white.withAlphaComponent(0.42).cgColor)
      context.move(to: segment.start)
      context.addLine(to: segment.end)
      context.strokePath()
    }
    context.restoreGState()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

private final class ShowFolderArtworkView: NSView {
  private let imageLayer = CALayer()
  private let placeholderView = NSImageView()

  var artwork: ShowFolderCardArtwork? {
    didSet { updateImage() }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = ShowFolderCardMetrics.cornerRadius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true

    imageLayer.contentsGravity = .resizeAspectFill
    imageLayer.masksToBounds = true
    imageLayer.opacity = 1
    layer?.addSublayer(imageLayer)
    alphaValue = 0

    placeholderView.translatesAutoresizingMaskIntoConstraints = false
    // The empty glass surface is the loading state. Do not add a guessed icon
    // or change the card's dimensions while artwork is being decoded.
    placeholderView.isHidden = true
    addSubview(placeholderView)
    NSLayoutConstraint.activate([
      placeholderView.centerXAnchor.constraint(equalTo: centerXAnchor),
      placeholderView.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  override func layout() {
    super.layout()
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    imageLayer.frame = bounds
    imageLayer.contentsScale = scale
  }

  private func updateImage() {
    guard let artwork else {
      imageLayer.contents = nil
      alphaValue = 0
      placeholderView.isHidden = false
      return
    }
    imageLayer.contents = artwork.image
    placeholderView.isHidden = true
    let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ||
      UserDefaults.standard.bool(forKey: "disableAnimations")
    let fadeDuration = reducedMotion ? 0 : 1.8
    guard fadeDuration > 0, alphaValue < 0.99 else {
      alphaValue = 1
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = fadeDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animator().alphaValue = 1
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

private final class ShowFolderShelfItemView: NSView {
  static let width: CGFloat = ShowFolderCardView.size.width + 24

  let card: ShowFolderCardView
  private(set) var widthConstraint: NSLayoutConstraint!

  init(card: ShowFolderCardView) {
    self.card = card
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    card.translatesAutoresizingMaskIntoConstraints = false
    addSubview(card)
    widthConstraint = widthAnchor.constraint(equalToConstant: Self.width)
    NSLayoutConstraint.activate([
      widthConstraint,
      heightAnchor.constraint(equalToConstant: ShowFolderShelfView.height),
      card.centerXAnchor.constraint(equalTo: centerXAnchor),
      card.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class ShowFolderShelfView: NSView {
  static let height: CGFloat = ShowFolderCardView.size.height + 48

  private let scrollView = NSScrollView()
  private let glassContainer = NSGlassEffectContainerView()
  private let stackView = NSStackView()
  private let leadingSpacer = NSView()
  private let trailingSpacer = NSView()
  private var leadingSpacerWidth: NSLayoutConstraint!
  private var trailingSpacerWidth: NSLayoutConstraint!
  private var cards: [String: ShowFolderCardView] = [:]
  private var items: [String: ShowFolderShelfItemView] = [:]
  private var dismissingPaths = Set<String>()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.horizontalScrollElasticity = .allowed
    scrollView.verticalScrollElasticity = .none
    scrollView.usesPredominantAxisScrolling = true

    glassContainer.translatesAutoresizingMaskIntoConstraints = false
    glassContainer.spacing = 0
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.orientation = .horizontal
    stackView.alignment = .centerY
    stackView.spacing = 0
    leadingSpacer.translatesAutoresizingMaskIntoConstraints = false
    trailingSpacer.translatesAutoresizingMaskIntoConstraints = false
    leadingSpacerWidth = leadingSpacer.widthAnchor.constraint(equalToConstant: 0)
    trailingSpacerWidth = trailingSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
    leadingSpacerWidth.isActive = true
    trailingSpacerWidth.isActive = true
    stackView.addArrangedSubview(leadingSpacer)
    stackView.addArrangedSubview(trailingSpacer)
    glassContainer.contentView = stackView
    scrollView.documentView = glassContainer
    addSubview(scrollView)

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      glassContainer.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
      glassContainer.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
      glassContainer.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
      glassContainer.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
      glassContainer.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),
      stackView.leadingAnchor.constraint(equalTo: glassContainer.leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: glassContainer.trailingAnchor),
      stackView.topAnchor.constraint(equalTo: glassContainer.topAnchor),
      stackView.bottomAnchor.constraint(equalTo: glassContainer.bottomAnchor),
    ])
  }

  override func layout() {
    super.layout()
    let edgeSpace = Self.leadingCardInset(for: bounds.width)
    leadingSpacerWidth.constant = edgeSpace
    trailingSpacerWidth.constant = edgeSpace
  }

  static func leadingCardInset(for shelfWidth: CGFloat) -> CGFloat {
    let columnWidth = min(400, max(0, shelfWidth - 128))
    let cardInset = (ShowFolderShelfItemView.width - ShowFolderCardView.size.width) / 2
    return max(0, (shelfWidth - columnWidth) / 2 - cardInset)
  }

  func reload(shows: [ShowFolder], target: AnyObject, openAction: Selector, dismissAction: Selector) {
    let desiredPaths = Set(shows.map(\.identityPath))
    for (path, item) in items where !desiredPaths.contains(path) && !dismissingPaths.contains(path) {
      stackView.removeArrangedSubview(item)
      item.removeFromSuperview()
      cards.removeValue(forKey: path)
      items.removeValue(forKey: path)
    }

    // Reconcile by identity instead of rebuilding the stack. Cards are the
    // skeleton state while artwork loads, so retaining their views is what
    // keeps both their geometry and their native glass stable.
    for show in shows {
      let path = show.identityPath
      if dismissingPaths.contains(path) { continue }
      if let card = cards[path] {
        card.update(show: show)
        continue
      }
      let card = ShowFolderCardView(show: show, target: target,
                                    openAction: openAction, dismissAction: dismissAction)
      let item = ShowFolderShelfItemView(card: card)
      stackView.insertArrangedSubview(item, at: stackView.arrangedSubviews.count - 1)
      cards[path] = card
      items[path] = item
    }

    // A history refresh can change recency without changing identities.
    // Keep AppKit's arranged subviews in model order without replacing card
    // instances (and therefore without replaying the loading placeholder).
    for (index, show) in shows.enumerated() {
      guard let item = items[show.identityPath] else { continue }
      let desiredIndex = index + 1 // the leading spacer remains first
      if stackView.arrangedSubviews.indices.contains(desiredIndex),
         stackView.arrangedSubviews[desiredIndex] !== item {
        stackView.removeArrangedSubview(item)
        stackView.insertArrangedSubview(item, at: desiredIndex)
      }
    }
  }

  func dismissCard(for show: ShowFolder, completion: @escaping () -> Void) {
    let path = show.identityPath
    guard dismissingPaths.insert(path).inserted else { return }
    guard let item = items[path] else {
      dismissingPaths.remove(path)
      completion()
      return
    }

    let motionDisabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ||
      UserDefaults.standard.bool(forKey: "disableAnimations")
    let fadeDuration = motionDisabled ? 0 : 0.14
    let reflowDuration = motionDisabled ? 0 : 0.14
    NSAnimationContext.runAnimationGroup { context in
      context.duration = fadeDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      context.allowsImplicitAnimation = true
      item.animator().alphaValue = 0
    } completionHandler: { [weak self, weak item] in
      guard let self, let item else {
        completion()
        return
      }
      // Once the dismissed card is fully invisible, collapse only its layout
      // slot. The remaining native stack items then slide into place without
      // showing a second shrinking copy of the dismissed card.
      NSAnimationContext.runAnimationGroup { context in
        context.duration = reflowDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        context.allowsImplicitAnimation = true
        item.widthConstraint.constant = 0
        self.stackView.animator().layoutSubtreeIfNeeded()
      } completionHandler: {
        self.stackView.removeArrangedSubview(item)
        item.removeFromSuperview()
        self.cards.removeValue(forKey: path)
        self.items.removeValue(forKey: path)
        self.dismissingPaths.remove(path)
        completion()
      }
    }
  }

  func setThumbnail(_ artwork: ShowFolderCardArtwork, for show: ShowFolder) {
    cards[show.identityPath]?.setThumbnail(artwork)
  }

  func needsThumbnail(for show: ShowFolder) -> Bool {
    cards[show.identityPath]?.hasThumbnail != true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
