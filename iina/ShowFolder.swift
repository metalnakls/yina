//
//  ShowFolder.swift
//  iina
//

import Cocoa

struct ShowFolderHistoryItem {
  let url: URL
  let lastPlayedAt: Date
  let position: Double
  let duration: Double
  let displayTitle: String
  let thumbnailCacheName: String
}

struct ShowFolder: Equatable {
  static let inactivityInterval: TimeInterval = 30 * 24 * 60 * 60

  let folderURL: URL
  let title: String
  let resumeURL: URL
  let episodeTitle: String
  let lastPlayedAt: Date
  let position: Double
  let duration: Double
  let thumbnailCacheName: String

  var progress: Double {
    guard duration.isFinite, duration > 0 else { return 0 }
    return min(max(position / duration, 0), 1)
  }

  static func make(from items: [ShowFolderHistoryItem], now: Date = Date(),
                   inactivityInterval: TimeInterval = inactivityInterval) -> [ShowFolder] {
    let grouped = Dictionary(grouping: items.filter(\.url.isFileURL)) {
      $0.url.deletingLastPathComponent().standardizedFileURL.path
    }

    return grouped.values.compactMap { entries in
      let distinctFiles = Set(entries.map { $0.url.standardizedFileURL.path })
      guard distinctFiles.count >= 2,
            let latest = entries.max(by: { $0.lastPlayedAt < $1.lastPlayedAt }),
            now.timeIntervalSince(latest.lastPlayedAt) <= inactivityInterval else { return nil }
      let folderURL = latest.url.deletingLastPathComponent().standardizedFileURL
      return ShowFolder(folderURL: folderURL,
                        title: folderURL.lastPathComponent,
                        resumeURL: latest.url,
                        episodeTitle: latest.displayTitle,
                        lastPlayedAt: latest.lastPlayedAt,
                        position: latest.position,
                        duration: latest.duration,
                        thumbnailCacheName: latest.thumbnailCacheName)
    }.sorted { lhs, rhs in
      if lhs.lastPlayedAt != rhs.lastPlayedAt { return lhs.lastPlayedAt > rhs.lastPlayedAt }
      return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
  }
}

final class ShowFolderCardView: NSView {
  static let size = NSSize(width: 184, height: 104)

  private let imageView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let episodeLabel = NSTextField(labelWithString: "")
  private let progress = NSProgressIndicator()
  private let button = NSButton()
  private(set) var show: ShowFolder

  init(show: ShowFolder, target: AnyObject, action: Selector) {
    self.show = show
    super.init(frame: NSRect(origin: .zero, size: Self.size))
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.cornerCurve = .continuous
    layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
    layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
    layer?.borderWidth = 0.5

    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.image = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)
      ?? NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.symbolConfiguration = .init(pointSize: 28, weight: .regular)
    imageView.contentTintColor = .secondaryLabelColor

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.stringValue = show.title

    episodeLabel.translatesAutoresizingMaskIntoConstraints = false
    episodeLabel.font = .systemFont(ofSize: 11)
    episodeLabel.textColor = .secondaryLabelColor
    episodeLabel.lineBreakMode = .byTruncatingTail
    episodeLabel.stringValue = show.episodeTitle

    progress.translatesAutoresizingMaskIntoConstraints = false
    progress.style = .bar
    progress.controlSize = .mini
    progress.minValue = 0
    progress.maxValue = 1
    progress.doubleValue = show.progress
    progress.isIndeterminate = false

    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.title = ""
    button.target = target
    button.action = action
    button.identifier = NSUserInterfaceItemIdentifier(show.folderURL.standardizedFileURL.path)
    button.toolTip = "Resume \(show.title): \(show.episodeTitle)"
    button.setAccessibilityLabel("Resume \(show.title)")
    button.setAccessibilityHelp("Opens \(show.episodeTitle) at your saved position")

    [imageView, titleLabel, episodeLabel, progress, button].forEach(addSubview)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: Self.size.width),
      heightAnchor.constraint(equalToConstant: Self.size.height),
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      imageView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      imageView.widthAnchor.constraint(equalToConstant: 36),
      imageView.heightAnchor.constraint(equalToConstant: 36),
      titleLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 10),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13),
      episodeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      episodeLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      episodeLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
      progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  func setThumbnail(_ image: NSImage) {
    imageView.image = image
    imageView.contentTintColor = nil
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class ShowFolderShelfView: NSView {
  static let height: CGFloat = ShowFolderCardView.size.height

  private let scrollView = NSScrollView()
  private let stackView = NSStackView()
  private var cards: [String: ShowFolderCardView] = [:]

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.horizontalScrollElasticity = .automatic
    scrollView.verticalScrollElasticity = .none
    scrollView.usesPredominantAxisScrolling = true

    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.orientation = .horizontal
    stackView.alignment = .centerY
    stackView.spacing = 10
    stackView.edgeInsets = .init(top: 0, left: 0, bottom: 0, right: 12)
    scrollView.documentView = stackView
    addSubview(scrollView)

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
      stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
      stackView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
      stackView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
    ])
  }

  func reload(shows: [ShowFolder], target: AnyObject, action: Selector) {
    stackView.arrangedSubviews.forEach { stackView.removeArrangedSubview($0); $0.removeFromSuperview() }
    cards.removeAll()
    for show in shows {
      let card = ShowFolderCardView(show: show, target: target, action: action)
      stackView.addArrangedSubview(card)
      cards[show.folderURL.standardizedFileURL.path] = card
    }
  }

  func setThumbnail(_ image: NSImage, for folderURL: URL) {
    cards[folderURL.standardizedFileURL.path]?.setThumbnail(image)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
