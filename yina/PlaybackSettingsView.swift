import AppKit
import SwiftUI

enum PlaybackSettingsTrackKind { case video, audio, subtitles }

struct PlaybackSettingsChoice: Identifiable, Equatable {
  let id: Int
  let title: String
}

struct PlaybackSettingsAudioDevice: Identifiable, Equatable {
  let id: String
  let title: String
}

struct PlaybackSettingsStyle: Identifiable {
  let id: Int
  let title: String
  let preview: NSImage
}

/// Presentation values only. SwiftUI never reads mpv or resolves files while laying out.
struct PlaybackSettingsSnapshot: Equatable {
  var hasMedia = false
  var videoValues = Array(repeating: 0.0, count: 5)
  var audioGains = Array(repeating: 0.0, count: 10)
  var videoTracks: [PlaybackSettingsChoice] = []
  var audioTracks: [PlaybackSettingsChoice] = []
  var audioDevices: [PlaybackSettingsAudioDevice] = []
  var audioDevice = "auto"
  var subtitleTracks: [PlaybackSettingsChoice] = []
  var videoID = 0
  var audioID = 0
  var subtitleID = 0
  var secondarySubtitleID = 0
  var subtitleStyle = 0
  var subtitleOverride = 0
  var subtitleVisible = true
  var imageSubtitles = false
}

enum PlaybackSettingsAction {
  case image(Int, Int), equalizer([Double])
  case track(PlaybackSettingsTrackKind, Int), crop(String)
  case style(Int), subtitleOverride(Int), subtitleVisibility(Bool)
  case externalAudio, externalSubtitles
  case audioDevice(String)
}

@MainActor
final class PlaybackSettingsModel: ObservableObject {
  @Published var snapshot = PlaybackSettingsSnapshot()
  let styles: [PlaybackSettingsStyle]
  let overrides: [PlaybackSettingsChoice]
  var perform: (PlaybackSettingsAction) -> Void = { _ in }
  private var editing = false

  // Preserve the existing equalizer's frequency groups and gain limits. Editing
  // one group leaves the other groups (including custom ten-band gains) intact.
  static let audioBands = [0..<3, 3..<7, 7..<10]

  init(styles: [PlaybackSettingsStyle], overrides: [PlaybackSettingsChoice]) {
    self.styles = styles
    self.overrides = overrides
  }

  func receive(_ value: PlaybackSettingsSnapshot) {
    var next = value
    if editing && value.hasMedia {
      // Keep the thumb under the user's hand while accepting track, visibility,
      // and other playback changes. mpv notifications can lag a slider command.
      next.videoValues = snapshot.videoValues
      next.audioGains = snapshot.audioGains
    }
    if !value.hasMedia { editing = false }
    if next != snapshot { snapshot = next }
  }

  func setEditing(_ value: Bool) {
    editing = value
  }

  func imageBinding(_ index: Int) -> Binding<Double> {
    Binding(get: { self.snapshot.videoValues[index] }, set: { value in
      self.snapshot.videoValues[index] = value.rounded()
      self.perform(.image(index, Int(value.rounded())))
    })
  }

  func gain(_ band: Int) -> Double {
    let indices = Self.audioBands[band]
    return indices.map { snapshot.audioGains[$0] }.reduce(0, +) / Double(indices.count)
  }

  func gainBinding(_ band: Int) -> Binding<Double> {
    Binding(get: { self.gain(band) }, set: { value in
      for index in Self.audioBands[band] { self.snapshot.audioGains[index] = value.rounded() }
      self.perform(.equalizer(self.snapshot.audioGains))
    })
  }

  func resetImage() {
    for index in snapshot.videoValues.indices { imageBinding(index).wrappedValue = 0 }
  }

  func resetAudio() {
    snapshot.audioGains = Array(repeating: 0, count: 10)
    perform(.equalizer(snapshot.audioGains))
  }
}

/// The window has a fixed initial size and user-owned resizing. SwiftUI never
/// supplies window size constraints when a slider label or selection changes.
@MainActor
final class PlaybackSettingsPanel: NSPanel {
  // Playback panel dimensions belong to this window, not to SwiftUI content.
  static let preferredContentSize = NSSize(width: 740, height: 740)
  static let minimumContentSize = NSSize(width: 700, height: 600)
  static let maximumContentSize = NSSize(width: 780, height: 900)

  static func normalizedContentSize(_ proposed: NSSize, visibleSize: NSSize) -> NSSize {
    let maximumWidth = min(maximumContentSize.width, visibleSize.width)
    let maximumHeight = min(maximumContentSize.height, visibleSize.height)
    return NSSize(width: min(max(proposed.width, min(minimumContentSize.width, maximumWidth)), maximumWidth),
                  height: min(max(proposed.height, min(minimumContentSize.height, maximumHeight)), maximumHeight))
  }

  init(model: PlaybackSettingsModel) {
    super.init(contentRect: NSRect(origin: .zero, size: Self.preferredContentSize),
               styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
               backing: .buffered, defer: false)
    title = "Settings"
    isReleasedWhenClosed = false
    hidesOnDeactivate = true
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    contentMinSize = Self.minimumContentSize
    contentMaxSize = Self.maximumContentSize
    isMovableByWindowBackground = false
    titlebarAppearsTransparent = true
    isOpaque = false
    backgroundColor = .clear

    let glass = NSGlassEffectView()
    glass.autoresizingMask = [.width, .height]
    contentView = glass
    let content = NSView()
    glass.contentView = content
    let host = PlaybackSettingsHostingView(model: model)
    host.sizingOptions = []
    host.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(host)
    let guide = contentLayoutGuide as! NSLayoutGuide
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      host.topAnchor.constraint(equalTo: guide.topAnchor),
      host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
  }

  /// Apply the same bounds after AppKit restores a legacy autosaved frame.
  /// NSWindow's resize limits do not constrain a programmatic frame restore.
  func normalizeSavedFrame() {
    guard let screen = self.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
    let visible = screen.visibleFrame
    let availableContent = contentRect(forFrameRect: visible).size
    let restoredSize = contentRect(forFrameRect: frame).size
    let legacySize = restoredSize.width < Self.minimumContentSize.width ||
      restoredSize.width > Self.maximumContentSize.width ||
      restoredSize.height < Self.minimumContentSize.height ||
      restoredSize.height > Self.maximumContentSize.height
    let size = Self.normalizedContentSize(legacySize ? Self.preferredContentSize : restoredSize,
                                          visibleSize: availableContent)
    contentMinSize = NSSize(width: min(Self.minimumContentSize.width, availableContent.width),
                            height: min(Self.minimumContentSize.height, availableContent.height))
    contentMaxSize = NSSize(width: min(Self.maximumContentSize.width, availableContent.width),
                            height: min(Self.maximumContentSize.height, availableContent.height))
    var normalized = frameRect(forContentRect: NSRect(origin: .zero, size: size))
    normalized.origin.x = min(max(frame.minX, visible.minX), visible.maxX - normalized.width)
    normalized.origin.y = min(max(frame.maxY - normalized.height, visible.minY),
                              visible.maxY - normalized.height)
    setFrame(normalized, display: false)
  }
}

/// An offscreen or newly opened AppKit panel can acquire its appearance after
/// SwiftUI first resolves the environment. Keep the hosted controls in sync
/// when the panel switches between Aqua and Dark Aqua.
@MainActor
private final class PlaybackSettingsHostingView: NSHostingView<AnyView> {
  private let model: PlaybackSettingsModel

  init(model: PlaybackSettingsModel) {
    self.model = model
    super.init(rootView: AnyView(PlaybackSettingsView(model: model)))
    updateColorScheme()
  }

  @available(*, unavailable)
  required init(rootView: AnyView) { fatalError("Use init(model:)") }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(model:)") }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColorScheme()
  }

  private func updateColorScheme() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    rootView = AnyView(PlaybackSettingsView(model: model)
      .environment(\.colorScheme, dark ? .dark : .light))
  }
}

struct PlaybackSettingsView: View {
  @ObservedObject var model: PlaybackSettingsModel
  private let imageLabels = ["Brightness", "Contrast", "Saturation", "Gamma", "Hue"]
  private let bandLabels = ["Bass", "Mid", "Treble"]
  // These are local panel metrics, chosen for the compact two-column layout.
  private let columnSpacing: CGFloat = 14
  private let sectionSpacing: CGFloat = 20
  private let sectionInset: CGFloat = 18
  private let consoleHeight: CGFloat = 228

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: sectionSpacing) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Playback").font(.largeTitle.weight(.semibold))
            .foregroundStyle(Color(nsColor: .labelColor))
          Text("Picture, sound, and subtitles")
            .font(.subheadline).foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        if !model.snapshot.hasMedia {
          Label("Open a video to adjust picture and sound", systemImage: "play.rectangle")
            .font(.callout).foregroundStyle(.secondary)
        }
        HStack(alignment: .top, spacing: columnSpacing) {
          videoSection.frame(maxWidth: .infinity, alignment: .topLeading)
          audioSection.frame(maxWidth: .infinity, alignment: .topLeading)
        }
        subtitleSection
      }
      .padding(sectionSpacing)
      .frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(Color(nsColor: .labelColor))
    }
    .scrollEdgeEffectStyle(.soft, for: .top)
  }

  private var videoSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Label("Picture", systemImage: "film").font(.title3.weight(.semibold))
        Spacer()
        Button("Reset", action: model.resetImage)
          .buttonStyle(.borderless)
          .controlSize(.small)
          .disabled(!model.snapshot.hasMedia || model.snapshot.videoValues.allSatisfy { $0 == 0 })
        Menu { videoMenu } label: { Image(systemName: "ellipsis") }
          .menuStyle(.borderlessButton).fixedSize()
          .accessibilityLabel("Video options")
      }
      Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
      Grid(horizontalSpacing: 12, verticalSpacing: 8) {
        ForEach(imageLabels.indices, id: \.self) { index in
          sliderRow(imageLabels[index], value: model.imageBinding(index), range: -100...100, unit: "")
        }
      }
      .disabled(!model.snapshot.hasMedia)
    }
    .padding(sectionInset)
    .frame(height: consoleHeight, alignment: .top)
    .frame(maxWidth: .infinity)
    .background(consoleSurface)
    .contextMenu { videoMenu }
  }

  private var audioSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Label("Sound", systemImage: "waveform").font(.title3.weight(.semibold))
        Spacer()
        Button("Reset", action: model.resetAudio)
          .buttonStyle(.borderless)
          .controlSize(.small)
          .disabled(!model.snapshot.hasMedia || model.snapshot.audioGains.allSatisfy { $0 == 0 })
        Menu { audioMenu } label: { Image(systemName: "ellipsis") }
          .menuStyle(.borderlessButton).fixedSize()
          .accessibilityLabel("Audio options")
      }
      Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
      HStack(alignment: .top, spacing: 4) {
        ForEach(bandLabels.indices, id: \.self) { index in
          VStack(spacing: 6) {
            PlaybackSettingsRotaryControl(title: bandLabels[index],
                                          identifier: "PlaybackSettingsTone\(bandLabels[index])",
                                          value: model.gainBinding(index),
                                          enabled: model.snapshot.hasMedia,
                                          onEditingChanged: model.setEditing)
              .frame(width: 32, height: 32)
              .scaleEffect(2.2)
              .frame(width: 76, height: 76)
            Text(bandLabels[index]).font(.subheadline.weight(.medium))
            Text("\(Int(model.gain(index).rounded()).formatted(.number.sign(strategy: .always()))) dB")
              .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity)
        }
      }
    }
    .padding(sectionInset)
    .frame(height: consoleHeight, alignment: .top)
    .frame(maxWidth: .infinity)
    .background(consoleSurface)
    .contextMenu { audioMenu }
  }

  private var subtitleSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("Subtitles", systemImage: "captions.bubble").font(.title3.weight(.semibold))
        Spacer()
        Toggle("Show subtitles", isOn: Binding(get: { model.snapshot.subtitleID > 0 && model.snapshot.subtitleVisible }, set: {
          model.snapshot.subtitleVisible = $0
          model.perform(.subtitleVisibility($0))
        }))
        .toggleStyle(.switch).labelsHidden().fixedSize()
        .disabled(!model.snapshot.hasMedia || model.snapshot.subtitleID == 0)
        Menu { subtitleMenu } label: { Image(systemName: "ellipsis") }
          .menuStyle(.borderlessButton).fixedSize()
          .accessibilityLabel("Subtitle options")
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
        ForEach(model.styles) { style in
          Button {
            model.snapshot.subtitleStyle = style.id
            model.perform(.style(style.id))
          } label: {
            VStack(alignment: .leading, spacing: 8) {
              GeometryReader { geometry in
                Image(nsImage: style.preview)
                  .resizable().scaledToFill()
                  .frame(width: geometry.size.width, height: geometry.size.height)
                  .clipped()
              }
              .frame(height: 78)
              .clipShape(RoundedRectangle(cornerRadius: 7))
              .accessibilityHidden(true)
              HStack {
                Text(style.title).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "checkmark.circle.fill")
                  .opacity(model.snapshot.subtitleStyle == style.id ? 1 : 0)
              }
              .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(model.snapshot.subtitleStyle == style.id ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor).opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11)
              .strokeBorder(model.snapshot.subtitleStyle == style.id ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(style.title)
          .accessibilityAddTraits(model.snapshot.subtitleStyle == style.id ? .isSelected : [])
        }
      }
      .disabled(model.snapshot.imageSubtitles)
      if model.snapshot.imageSubtitles {
        Text("Image subtitles use their embedded appearance.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(sectionInset)
    .background(consoleSurface)
    .contextMenu { subtitleMenu }
  }

  private var consoleSurface: some View {
    RoundedRectangle(cornerRadius: 16)
      .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
      .overlay(RoundedRectangle(cornerRadius: 16)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1))
  }

  private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
    GridRow {
      Text(label).gridColumnAlignment(.leading)
      Slider(value: value, in: range, onEditingChanged: model.setEditing) { Text(label) }
        .labelsHidden()
      // Reserve the actual widest formatted value, rather than letting the value
      // determine the slider/window width during an edit. No invented width metric.
      Text("−100\(unit)").hidden()
        .overlay(alignment: .trailing) {
          Text("\(Int(value.wrappedValue.rounded()))\(unit)")
        }
        .monospacedDigit().foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder private var videoMenu: some View {
    Toggle("Video", isOn: Binding(get: {
      model.snapshot.videoTracks.contains { $0.id == model.snapshot.videoID }
    }, set: { enabled in
      model.perform(.track(.video, enabled ? (model.snapshot.videoTracks.first?.id ?? 0) : 0))
    }))
    .disabled(!model.snapshot.hasMedia || model.snapshot.videoTracks.isEmpty)
    trackPicker("Video track", tracks: model.snapshot.videoTracks, selected: model.snapshot.videoID, kind: .video)
    Menu("Crop") {
      Button("None") { model.perform(.crop("")) }
      ForEach(["16:9", "4:3", "1:1", "2.35:1"], id: \.self) { ratio in
        Button(ratio) { model.perform(.crop(ratio)) }
      }
    }.disabled(!model.snapshot.hasMedia)
  }

  @ViewBuilder private var audioMenu: some View {
    Toggle("Audio", isOn: Binding(get: {
      model.snapshot.audioTracks.contains { $0.id == model.snapshot.audioID }
    }, set: { enabled in
      model.perform(.track(.audio, enabled ? (model.snapshot.audioTracks.first?.id ?? 0) : 0))
    }))
    .disabled(!model.snapshot.hasMedia || model.snapshot.audioTracks.isEmpty)
    trackPicker("Audio track", tracks: model.snapshot.audioTracks, selected: model.snapshot.audioID, kind: .audio)
    Picker("Output", selection: Binding(get: { model.snapshot.audioDevice }, set: {
      model.snapshot.audioDevice = $0
      model.perform(.audioDevice($0))
    })) {
      ForEach(model.snapshot.audioDevices) { Text($0.title).tag($0.id) }
    }.disabled(!model.snapshot.hasMedia)
    Button("Load External Audio…") { model.perform(.externalAudio) }
      .disabled(!model.snapshot.hasMedia)
  }

  @ViewBuilder private var subtitleMenu: some View {
    trackPicker("Subtitle track", tracks: model.snapshot.subtitleTracks, selected: model.snapshot.subtitleID, kind: .subtitles)
    Button("Load External Subtitles…") { model.perform(.externalSubtitles) }
      .disabled(!model.snapshot.hasMedia)
    Picker("Style override", selection: Binding(get: { model.snapshot.subtitleOverride }, set: {
      model.snapshot.subtitleOverride = $0
      model.perform(.subtitleOverride($0))
    })) {
      ForEach(model.overrides) { Text($0.title).tag($0.id) }
    }
  }

  private func trackPicker(_ title: String, tracks: [PlaybackSettingsChoice], selected: Int,
                           kind: PlaybackSettingsTrackKind) -> some View {
    Menu(title) {
      ForEach(tracks) { track in
        Button {
          model.perform(.track(kind, track.id))
        } label: {
          if track.id == selected { Label(track.title, systemImage: "checkmark") }
          else { Text(track.title) }
        }
        .disabled(kind == .subtitles && track.id == model.snapshot.secondarySubtitleID)
      }
    }
    .disabled(!model.snapshot.hasMedia || tracks.isEmpty)
  }
}

/// AppKit supplies the dial, focus ring, and accessibility value. Edits are
/// bracketed so delayed mpv snapshots cannot move a dial during interaction;
/// arrow keys adjust the gain in whole decibels.
@MainActor
final class PlaybackSettingsRotarySlider: NSSlider {
  var editingChanged: (Bool) -> Void = { _ in }
  private(set) var isEditing = false

  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    isEditing = true
    editingChanged(true)
    defer { isEditing = false; editingChanged(false) }
    super.mouseDown(with: event)
  }

  override func keyDown(with event: NSEvent) {
    guard isEnabled,
          event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
      super.keyDown(with: event)
      return
    }
    isEditing = true
    editingChanged(true)
    defer { isEditing = false; editingChanged(false) }
    // Circular NSSlider does not step for arrow keys on every macOS release.
    // Keep the native control and focus ring, while making a focused dial
    // operable by keyboard in one-decibel increments.
    let step: Double
    switch event.keyCode {
    case 123, 125: step = -1 // Left, Down
    case 124, 126: step = 1  // Right, Up
    default:
      super.keyDown(with: event)
      return
    }
    doubleValue = min(maxValue, max(minValue, doubleValue.rounded() + step))
    sendAction(action, to: target)
  }
}

@MainActor
struct PlaybackSettingsRotaryControl: NSViewRepresentable {
  let title: String
  let identifier: String
  @Binding var value: Double
  let enabled: Bool
  let onEditingChanged: (Bool) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> PlaybackSettingsRotarySlider {
    let slider = PlaybackSettingsRotarySlider()
    slider.sliderType = .circular
    slider.controlSize = .large
    slider.minValue = -12
    slider.maxValue = 12
    slider.isContinuous = true
    slider.target = context.coordinator
    slider.action = #selector(Coordinator.changed(_:))
    slider.setAccessibilityIdentifier(identifier)
    slider.setAccessibilityLabel(title)
    slider.setAccessibilityHelp("Adjust from −12 to +12 decibels. Zero leaves this range unchanged.")
    slider.editingChanged = onEditingChanged
    return slider
  }

  func updateNSView(_ slider: PlaybackSettingsRotarySlider, context: Context) {
    context.coordinator.parent = self
    slider.editingChanged = onEditingChanged
    slider.isEnabled = enabled
    if !slider.isEditing { slider.doubleValue = value }
  }

  @MainActor final class Coordinator: NSObject {
    var parent: PlaybackSettingsRotaryControl
    init(_ parent: PlaybackSettingsRotaryControl) { self.parent = parent }

    @objc func changed(_ sender: NSSlider) {
      let rounded = sender.doubleValue.rounded()
      sender.doubleValue = rounded
      parent.value = rounded
    }
  }
}
