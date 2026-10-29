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
  init(model: PlaybackSettingsModel) {
    // Existing Settings dimensions and minimum detail width.
    super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
               styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
               backing: .buffered, defer: false)
    title = "Settings"
    isReleasedWhenClosed = false
    hidesOnDeactivate = true
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    contentMinSize = NSSize(width: 400, height: 480)
    isMovableByWindowBackground = false
    titlebarAppearsTransparent = true
    isOpaque = false
    backgroundColor = .clear

    let glass = NSGlassEffectView()
    glass.autoresizingMask = [.width, .height]
    contentView = glass
    let content = NSView()
    glass.contentView = content
    let host = NSHostingView(rootView: PlaybackSettingsView(model: model))
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
}

struct PlaybackSettingsView: View {
  @ObservedObject var model: PlaybackSettingsModel
  private let imageLabels = ["Brightness", "Contrast", "Saturation", "Gamma", "Hue"]
  private let bandLabels = ["Bass", "Mid", "Treble"]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading) {
        if !model.snapshot.hasMedia {
          Label("Open a video to adjust picture and sound", systemImage: "play.rectangle")
            .font(.callout).foregroundStyle(.secondary)
            .padding(.bottom)
        }
        videoSection
        Divider().padding(.vertical)
        audioSection
        Divider().padding(.vertical)
        subtitleSection
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollEdgeEffectStyle(.soft, for: .top)
  }

  private var videoSection: some View {
    VStack(alignment: .leading) {
      HStack {
        Label("Video", systemImage: "film").font(.headline)
        Spacer()
        Button("Reset", action: model.resetImage)
          .disabled(!model.snapshot.hasMedia || model.snapshot.videoValues.allSatisfy { $0 == 0 })
        Menu { videoMenu } label: { Image(systemName: "ellipsis") }
          .menuStyle(.borderlessButton).fixedSize()
          .accessibilityLabel("Video options")
      }
      Grid {
        ForEach(imageLabels.indices, id: \.self) { index in
          sliderRow(imageLabels[index], value: model.imageBinding(index), range: -100...100, unit: "")
        }
      }
      .disabled(!model.snapshot.hasMedia)
    }
    .contextMenu { videoMenu }
  }

  private var audioSection: some View {
    VStack(alignment: .leading) {
      HStack {
        Label("Audio", systemImage: "waveform").font(.headline)
        Spacer()
        Button("Reset", action: model.resetAudio)
          .disabled(!model.snapshot.hasMedia || model.snapshot.audioGains.allSatisfy { $0 == 0 })
        Menu { audioMenu } label: { Image(systemName: "ellipsis") }
          .menuStyle(.borderlessButton).fixedSize()
          .accessibilityLabel("Audio options")
      }
      Grid {
        ForEach(bandLabels.indices, id: \.self) { index in
          sliderRow(bandLabels[index], value: model.gainBinding(index), range: -12...12, unit: " dB")
        }
      }
      .disabled(!model.snapshot.hasMedia)
    }
    .contextMenu { audioMenu }
  }

  private var subtitleSection: some View {
    VStack(alignment: .leading) {
      HStack {
        Label("Subtitles", systemImage: "captions.bubble").font(.headline)
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
      LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
        ForEach(model.styles) { style in
          Button {
            model.snapshot.subtitleStyle = style.id
            model.perform(.style(style.id))
          } label: {
            VStack {
              Image(nsImage: style.preview).resizable().aspectRatio(16 / 9, contentMode: .fit)
                .accessibilityHidden(true)
              HStack {
                Text(style.title).lineLimit(1)
                Image(systemName: "checkmark.circle.fill")
                  .opacity(model.snapshot.subtitleStyle == style.id ? 1 : 0)
              }
              .font(.caption)
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
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
    .contextMenu { subtitleMenu }
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
