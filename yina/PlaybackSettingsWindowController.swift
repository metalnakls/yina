import AppKit
import SwiftUI

/// AppKit owns a stable window; SwiftUI owns controls. Content never resizes the
/// window in response to a slider value or an asynchronous playback notification.
@MainActor
final class PlaybackSettingsWindowController: NSWindowController, NSWindowDelegate {
  private static var instance: PlaybackSettingsWindowController?
  static var shared: PlaybackSettingsWindowController {
    if let instance { return instance }
    let controller = PlaybackSettingsWindowController()
    instance = controller
    return controller
  }

  static func isShown(for player: PlayerCore) -> Bool {
    instance?.isShown(for: player) == true
  }

  let model: PlaybackSettingsModel
  private weak var player: PlayerCore?
  private var observations: [NSObjectProtocol] = []
  private var applicationObservations: [NSObjectProtocol] = []
  private let preferences = Preference.Observer()
  private var audioDevices: [PlaybackSettingsAudioDevice] = []
  private var audioDevice = "auto"
  private var deviceRefreshGeneration: UInt64 = 0

  private init() {
    model = PlaybackSettingsModel(styles: SubtitleStyleID.allCases.map {
      PlaybackSettingsStyle(id: $0.rawValue, title: $0 == .none ? "Embedded" : $0.localizedName,
                            preview: Self.preview(for: $0))
    }, overrides: Preference.SubOverrideLevel.allCases.map {
      PlaybackSettingsChoice(id: $0.rawValue, title: $0.description)
    })

    let panel = PlaybackSettingsPanel(model: model)
    super.init(window: panel)
    panel.delegate = self
    panel.center()
    if !AppEnvironment.isCleanStart { panel.setFrameAutosaveName("YINAPlaybackSettings") }
    model.perform = { [weak self] in self?.perform($0) }
    preferences.addAll([.subStyle, .subOverrideLevel, .subVisibility]) { [weak self] _ in
      DispatchQueue.main.async { self?.refresh() }
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(for player: PlayerCore) {
    bind(to: player)
    if applicationObservations.isEmpty {
      applicationObservations.append(NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
      ) { [weak self] notification in
        MainActor.assumeIsolated {
          guard let controller = (notification.object as? NSWindow)?.windowController as? PlayerWindowController else { return }
          self?.bind(to: controller.player)
        }
      })
    }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NotificationCenter.default.post(name: .yinaSidebarStatusChanged, object: nil)
  }

  func isShown(for player: PlayerCore) -> Bool {
    self.player === player && window?.isVisible == true
  }

  func windowWillClose(_ notification: Notification) {
    deviceRefreshGeneration &+= 1
    (observations + applicationObservations).forEach(NotificationCenter.default.removeObserver)
    observations.removeAll()
    applicationObservations.removeAll()
    player = nil
    NotificationCenter.default.post(name: .yinaSidebarStatusChanged, object: nil)
  }

  private func bind(to player: PlayerCore) {
    if self.player !== player {
      observations.forEach(NotificationCenter.default.removeObserver)
      observations.removeAll()
      model.setEditing(false)
      self.player = player
      audioDevices = []
      audioDevice = "auto"
      deviceRefreshGeneration &+= 1
      let names: [Notification.Name] = [
        .yinaTracklistChanged, .yinaVIDChanged, .yinaAIDChanged, .yinaSIDChanged,
        .yinaVideoEqualizerChanged, .yinaAFChanged, .yinaSubVisibilityChanged,
        .yinaFileLoaded, .yinaPlayerStopped, .yinaPlayerShutdown,
      ]
      for name in names {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: player, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated {
            if name == .yinaFileLoaded { self?.refreshDevices() }
            else { self?.refresh() }
          }
        })
      }
      refreshDevices()
    }
    refresh()
  }

  private func refresh() {
    guard let player else { return }
    let info = player.info
    func tracks(_ kind: MPVTrack.TrackType) -> [PlaybackSettingsChoice] {
      info.trackList(kind).map { PlaybackSettingsChoice(id: $0.id, title: $0.readableTitle) }
    }
    var snapshot = PlaybackSettingsSnapshot()
    snapshot.hasMedia = info.state.active
    snapshot.videoValues = [info.brightness, info.contrast, info.saturation, info.gamma, info.hue].map(Double.init)
    snapshot.audioGains = Self.equalizerGains(from: info.audioEqFilter?.stringFormat)
    snapshot.videoTracks = tracks(.video)
    snapshot.audioTracks = tracks(.audio)
    snapshot.audioDevices = audioDevices
    snapshot.audioDevice = audioDevice
    snapshot.subtitleTracks = tracks(.sub)
    snapshot.videoID = info.vid ?? 0
    snapshot.audioID = info.aid ?? 0
    snapshot.subtitleID = info.sid ?? 0
    snapshot.subtitleStyle = Preference.integer(for: .subStyle)
    snapshot.subtitleOverride = Preference.integer(for: .subOverrideLevel)
    snapshot.subtitleVisible = info.isSubVisible
    snapshot.imageSubtitles = info.currentTrack(.sub)?.isImageSub == true
    model.receive(snapshot)
  }

  private func refreshDevices() {
    guard let player, player.info.state.active else { return }
    deviceRefreshGeneration &+= 1
    let generation = deviceRefreshGeneration
    let url = player.info.currentURL
    player.mpv.getPropertiesAsync([MPVProperty.audioDeviceList, MPVProperty.audioDevice]) { [weak self, weak player] values in
      guard let self, let player, self.player === player,
            self.deviceRefreshGeneration == generation,
            player.info.state.active, player.info.currentURL == url else { return }
      let raw = values[MPVProperty.audioDeviceList] as? [[String: Any]] ?? []
      let ignoredDriver = Preference.bool(for: .audioDriverEnableAVFoundation) ? "coreaudio" : "avfoundation"
      self.audioDevices = raw.compactMap { device -> MPVAudioDevice? in
        guard let name = device["name"] as? String,
              let description = device["description"] as? String else { return nil }
        return MPVAudioDevice(desc: description, name: name)
      }.filter { $0.driver != ignoredDriver }.map {
        PlaybackSettingsAudioDevice(id: $0.name, title: $0.desc.isEmpty ? $0.name : $0.desc)
      }
      self.audioDevice = values[MPVProperty.audioDevice] as? String ?? "auto"
      self.refresh()
    }
  }

  private func perform(_ action: PlaybackSettingsAction) {
    // Appearance preferences also work before a video has been opened.
    switch action {
    case .style(let id):
      guard let style = SubtitleStyleID(rawValue: id) else { return }
      SubtitleStyles.apply(style)
      if style == .none {
        // Embedded really means the file's styling, regardless of shipped defaults.
        Preference.set(Preference.SubOverrideLevel.no.rawValue, for: .subOverrideLevel)
        Preference.set(Preference.SubOverrideLevel.no.rawValue, for: .secondarySubOverrideLevel)
      }
      refresh()
      return
    case .subtitleOverride(let value):
      Preference.set(value, for: .subOverrideLevel)
      return
    case .subtitleVisibility(let visible):
      if let player { player.requestSubtitleVisibility(visible) }
      else { Preference.set(visible, for: .subVisibility) }
      return
    default: break
    }
    guard let player, player.info.state.active else { return }
    switch action {
    case .image(let index, let value):
      let options: [PlayerCore.VideoEqualizerType] = [.brightness, .contrast, .saturation, .gamma, .hue]
      guard options.indices.contains(index) else { return }
      player.setVideoEqualizer(forOption: options[index], value: value)
    case .equalizer(let gains): player.setAudioEq(fromGains: gains)
    case .track(let kind, let id):
      let type: MPVTrack.TrackType = kind == .video ? .video : kind == .audio ? .audio : .sub
      player.setTrack(id, forType: type)
    case .crop(let ratio):
      guard player.info.videoWidth != nil, player.info.videoHeight != nil else { return }
      player.setCrop(fromString: ratio)
    case .audioDevice(let device):
      deviceRefreshGeneration &+= 1
      audioDevice = device
      player.setAudioDevice(device)
    case .externalAudio: loadExternalFile(audio: true, player: player)
    case .externalSubtitles: loadExternalFile(audio: false, player: player)
    default: break
    }
  }

  private func loadExternalFile(audio: Bool, player: PlayerCore) {
    let media = player.info.currentURL
    Utility.quickOpenPanel(title: audio ? "Load External Audio" : "Load External Subtitles",
                          chooseDir: false, dir: player.info.currentURL?.deletingLastPathComponent(),
                          sheetWindow: window,
                          allowedFileTypes: audio ? Utility.supportedFileExt[.audio]! : Utility.containsSubExt) { [weak player] url in
      guard let player, player.info.state.active, player.info.currentURL == media else { return }
      if audio { player.loadExternalAudioFile(url) }
      else { player.loadExternalSubFile(url, delay: true) }
    }
  }

  static func equalizerGains(from filter: String?) -> [Double] {
    guard let filter, let start = filter.firstIndex(of: "["), let end = filter.lastIndex(of: "]") else {
      return Array(repeating: 0, count: 10)
    }
    let values = filter[filter.index(after: start)..<end].split(separator: ",").compactMap { part -> Double? in
      guard let gain = part.split(separator: ":").first(where: { $0.hasPrefix("g=") }),
            let number = Double(gain.dropFirst(2)), number.isFinite else { return nil }
      return min(12, max(-12, number))
    }
    return values.count == 10 ? values : Array(repeating: 0, count: 10)
  }

  /// Render six immutable content samples once, never during layout or a slider
  /// update. These are illustrative subtitle samples, not custom controls.
  private static func preview(for style: SubtitleStyleID) -> NSImage {
    let size = NSSize(width: 320, height: 180) // A 16:9 video sample, independent of window geometry.
    let profile = SubtitleStyles.profile(for: style)
    return NSImage(size: size, flipped: false) { rect in
      NSGradient(starting: .darkGray, ending: .black)?.draw(in: rect, angle: -90)
      let fontSize = CGFloat(profile?.size ?? 42)
      let base = NSFont(name: profile?.font ?? "Helvetica", size: fontSize) ?? .systemFont(ofSize: fontSize)
      let font = profile?.bold == true ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
      let shadow = NSShadow()
      shadow.shadowColor = profile?.shadowColor.flatMap(NSColor.init(mpvColorString:)) ?? .clear
      shadow.shadowBlurRadius = CGFloat(profile?.blur ?? 0)
      shadow.shadowOffset = NSSize(width: CGFloat(profile?.shadowSize ?? 0), height: -CGFloat(profile?.shadowSize ?? 0))
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: profile?.textColor.flatMap(NSColor.init(mpvColorString:)) ?? NSColor.white,
        .shadow: shadow,
      ]
      if let outline = profile?.outlineSize, outline > 0 {
        attributes[.strokeWidth] = -CGFloat(outline)
        attributes[.strokeColor] = profile?.outlineColor.flatMap(NSColor.init(mpvColorString:)) ?? NSColor.black
      }
      let sample = NSAttributedString(string: "Aa", attributes: attributes)
      let sampleSize = sample.size()
      let sampleRect = NSRect(x: rect.midX - sampleSize.width / 2, y: rect.midY - sampleSize.height / 2,
                              width: sampleSize.width, height: sampleSize.height)
      if profile?.borderStyle == .opaqueBox {
        NSColor.black.setFill()
        sampleRect.insetBy(dx: -fontSize / 4, dy: 0).fill()
      }
      sample.draw(in: sampleRect)
      return true
    }
  }
}
