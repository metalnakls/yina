//
//  ThumbnailPeekView.swift
//  yina
//
//  Created by lhc on 12/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

class ThumbnailPeekView: NSView {

  var imageView: NSImageView!
#if IINA_ENABLE_METAL_RENDERER
  private let previewSurface = NSView()
  private let previewLayer = CAMetalLayer()
  private var previewRenderer: MPVPreviewRenderer!
  private var previewGeneration: UInt64 = 0
  private weak var previewPlayer: PlayerCore?
  private var previewSeconds: Double?
  private var equalizerObserver: NSObjectProtocol?
  private var settingsObserver: NSObjectProtocol?
  private var previewOptions: [String: String]?
  private var optionsCapturedAt: Date?
  private weak var optionsPlayer: PlayerCore?
  private var optionsURL: URL?
  private var optionsVideoID: Int?
  private var optionsGeneration: UInt64 = 0
  private var previewHDREnabled: Bool?

  override var isHidden: Bool {
    didSet {
      if isHidden {
        previewGeneration &+= 1
        previewSeconds = nil
        previewRenderer?.cancel()
      }
    }
  }

  func renderPreview(player: PlayerCore, seconds: Double) {
    guard let url = player.info.currentURL, !player.info.isNetworkResource,
          player.info.state.loaded, Preference.bool(for: .enableThumbnailPreview) else {
      invalidateOptions()
      previewPlayer = nil
      isHidden = true
      return
    }
    previewPlayer = player
    previewSeconds = seconds
    let videoID = player.info.vid
    if optionsPlayer !== player || optionsURL != url || optionsVideoID != videoID {
      invalidateOptions()
      optionsPlayer = player
      optionsURL = url
      optionsVideoID = videoID
    }
    if let optionsCapturedAt, Date().timeIntervalSince(optionsCapturedAt) > 10 {
      // External IPC can change an unobserved option. Bound that exposure
      // without issuing a property batch on every timeline movement.
      invalidateOptions()
    }
    guard let options = previewOptions else {
      // One asynchronous batch serves all hover positions until a relevant
      // file, track, or rendering option changes.
      let generation = optionsGeneration
      if !optionsRefreshInFlight {
        optionsRefreshInFlight = true
        player.mpv.getStringsAsync(MPVPreviewRenderer.optionNames) { [weak self, weak player] values in
          guard let self, let player, self.optionsGeneration == generation,
                self.optionsPlayer === player, self.optionsURL == url else { return }
          self.optionsRefreshInFlight = false
          guard player.info.currentURL == url, player.info.state.loaded else { return }
          guard !values.isEmpty else { return }
          self.previewOptions = values
          self.optionsCapturedAt = Date()
          if let seconds = self.previewSeconds { self.renderPreview(player: player, seconds: seconds) }
        }
      }
      return
    }
    previewGeneration &+= 1
    let generation = previewGeneration
    let scale = window?.backingScaleFactor ?? 2
    previewLayer.contentsScale = scale
    previewLayer.drawableSize = CGSize(width: max(1, bounds.width * scale),
                                       height: max(1, bounds.height * scale))
    previewRenderer.request(path: url.path, seconds: seconds, options: options) { [weak self, weak player] success in
      DispatchQueue.main.async {
        guard let self, self.previewGeneration == generation else { return }
        guard player?.info.currentURL == url, player?.info.state.loaded == true else {
          self.isHidden = true
          return
        }
        self.isHidden = !success
      }
    }
  }
#endif

  func setHDRPlaybackEnabled(_ enabled: Bool) {
#if IINA_ENABLE_METAL_RENDERER
    if previewHDREnabled != enabled {
      previewHDREnabled = enabled
      invalidateOptions()
      synchronizePreview()
    }
#else
    imageView.preferredImageDynamicRange = enabled ? .high : .standard
#endif
  }

#if IINA_ENABLE_METAL_RENDERER
  private func synchronizePreview() {
    if let player = previewPlayer, let seconds = previewSeconds {
      renderPreview(player: player, seconds: seconds)
    }
  }

  private var optionsRefreshInFlight = false

  private func invalidateOptions() {
    optionsGeneration &+= 1
    optionsRefreshInFlight = false
    previewOptions = nil
    optionsCapturedAt = nil
    previewGeneration &+= 1
    previewRenderer?.cancel()
  }

  deinit {
    if let equalizerObserver { NotificationCenter.default.removeObserver(equalizerObserver) }
    if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
  }
#endif

  func setImage(_ image: NSImage, rotation: Int, hdrEnabled: Bool) {
    setHDRPlaybackEnabled(hdrEnabled)
    let rotation = ((rotation % 360) + 360) % 360
    guard rotation != 0, rotation % 90 == 0,
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      imageView.image = image
      return
    }
    // Rotate the packed pixels without a drawing context or color conversion.
    // lockFocus would reduce HDR to 8-bit SDR; the transfer function must survive.
    guard cgImage.bitsPerPixel % 8 == 0, let colorSpace = cgImage.colorSpace,
          let sourceData = cgImage.dataProvider?.data as Data? else {
      imageView.image = image
      return
    }
    let bytesPerPixel = cgImage.bitsPerPixel / 8
    let width = rotation == 180 ? cgImage.width : cgImage.height
    let height = rotation == 180 ? cgImage.height : cgImage.width
    let bytesPerRow = width * bytesPerPixel
    guard bytesPerPixel > 0, sourceData.count >= cgImage.bytesPerRow * cgImage.height else {
      imageView.image = image
      return
    }
    var pixels = Data(count: bytesPerRow * height)
    sourceData.withUnsafeBytes { source in
      pixels.withUnsafeMutableBytes { destination in
        for y in 0..<cgImage.height {
          for x in 0..<cgImage.width {
            let targetX = rotation == 90 ? cgImage.height - 1 - y : rotation == 180 ? cgImage.width - 1 - x : y
            let targetY = rotation == 90 ? x : rotation == 180 ? cgImage.height - 1 - y : cgImage.width - 1 - x
            destination.baseAddress!.advanced(by: targetY * bytesPerRow + targetX * bytesPerPixel)
              .copyMemory(from: source.baseAddress!.advanced(by: y * cgImage.bytesPerRow + x * bytesPerPixel),
                          byteCount: bytesPerPixel)
          }
        }
      }
    }
    guard let provider = CGDataProvider(data: pixels as CFData),
          let output = CGImage(width: width, height: height, bitsPerComponent: cgImage.bitsPerComponent,
                               bitsPerPixel: cgImage.bitsPerPixel, bytesPerRow: bytesPerRow,
                               space: colorSpace, bitmapInfo: cgImage.bitmapInfo, provider: provider,
                               decode: nil, shouldInterpolate: true, intent: cgImage.renderingIntent) else {
      imageView.image = image
      return
    }
    let tagged = CGImageCreateCopyWithContentHeadroom(max(1, cgImage.contentHeadroom), output) ?? output
    imageView.image = NSImage(cgImage: tagged, size: .zero)
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setup()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  private func setup() {
    wantsLayer = true
    layer?.cornerRadius = 4
    layer?.masksToBounds = true
    layer?.borderWidth = 1
    layer?.borderColor = CGColor(gray: 0.6, alpha: 0.5)

    let s = NSShadow()
    s.shadowBlurRadius = 2
    s.shadowColor = .black
    shadow = s

#if IINA_ENABLE_METAL_RENDERER
    previewLayer.device = MTLCreateSystemDefaultDevice()
    previewLayer.framebufferOnly = false
    previewLayer.maximumDrawableCount = 3
    previewLayer.allowsNextDrawableTimeout = true
    previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    previewSurface.layer = previewLayer
    previewSurface.wantsLayer = true
    previewSurface.translatesAutoresizingMaskIntoConstraints = false
    addSubview(previewSurface)
    previewSurface.padding(.all(0))
    previewRenderer = MPVPreviewRenderer(layer: previewLayer)
    equalizerObserver = NotificationCenter.default.addObserver(forName: .yinaVideoEqualizerChanged,
      object: nil, queue: .main) { [weak self] notification in
        guard let self, let player = notification.object as? PlayerCore,
              player === self.previewPlayer else { return }
        self.invalidateOptions()
        self.synchronizePreview()
      }
    settingsObserver = NotificationCenter.default.addObserver(forName: .yinaPreviewSettingsChanged,
      object: nil, queue: .main) { [weak self] notification in
        guard let self, let player = notification.object as? PlayerCore,
              player === self.previewPlayer else { return }
        self.invalidateOptions()
        self.synchronizePreview()
      }
#endif
    imageView = NSImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.wantsLayer = true
    imageView.layer?.cornerRadius = 4
    imageView.layer?.masksToBounds = true
    imageView.imageScaling = .scaleAxesIndependently
    addSubview(imageView)
    imageView.padding(.all(0))
#if IINA_ENABLE_METAL_RENDERER
    imageView.isHidden = true
#endif
  }

}
#if IINA_ENABLE_METAL_RENDERER
import Metal

/// The preview uses the same gpu-next/libplacebo Metal backend as playback.
/// Settings are snapshotted when they change; no HDR image decoding or second
/// image-view tone mapping is involved. Each worker owns exactly one mpv core.
final class MPVPreviewRenderer {
  static let optionNames = [
    "vid", "hwdec", "vf", "video-rotate", "video-aspect-override",
    "video-output-levels", "video-primaries", "video-gamma",
    "video-colorspace", "video-color-range", "video-chroma-location",
    "contrast", "brightness", "gamma", "saturation", "hue",
    "target-colorspace-hint", "target-colorspace-hint-mode", "target-colorspace-hint-strict",
    "target-trc", "target-prim", "target-peak", "target-contrast", "target-gamut",
    "hdr-reference-white", "tone-mapping", "tone-mapping-param", "inverse-tone-mapping",
    "tone-mapping-max-boost", "gamut-mapping-mode", "hdr-compute-peak",
    "hdr-peak-percentile", "hdr-peak-decay-rate", "hdr-scene-threshold-low",
    "hdr-scene-threshold-high", "hdr-contrast-recovery", "hdr-contrast-smoothness",
    "icc-profile", "icc-profile-auto", "icc-intent", "icc-force-contrast", "icc-use-luma",
    "scale", "cscale", "dscale", "linear-downscaling", "sigmoid-upscaling",
    "correct-downscaling", "deband", "deband-iterations", "deband-threshold",
    "deband-range", "deband-grain", "dither-depth", "dither", "glsl-shaders", "glsl-shader-opts"
  ]

  private struct Request {
    let id: UInt64
    let path: String
    let seconds: Double
    let options: [String: String]
    let completion: (Bool) -> Void
  }

  private final class Worker {
    let layer: CAMetalLayer
    let lock = NSLock()
    var pending: Request?
    var generation: UInt64 = 0
    var running = false
    var closed = false
    // Only the serial render queue accesses the core, context and loaded path.
    var core: OpaquePointer?
    var context: OpaquePointer?
    var loadedPath: String?
    var appliedOptions: [String: String] = [:]

    init(layer: CAMetalLayer) { self.layer = layer }

    func current(_ id: UInt64) -> Bool {
      lock.lock(); defer { lock.unlock() }
      return !closed && generation == id
    }

    func run() {
      while true {
        lock.lock()
        guard let request = pending, !closed else {
          running = false
          lock.unlock()
          return
        }
        pending = nil
        lock.unlock()
        let success = render(request)
        if current(request.id) { request.completion(success) }
      }
    }

    func initialize() -> Bool {
      if context != nil { return true }
      guard let core = mpv_create() else { return false }
      self.core = core
      for (name, value) in ["config": "no", "load-scripts": "no", "ytdl": "no",
                            "vo": "libmpv", "ao": "null", "audio": "no", "sid": "no",
                            "pause": "yes", "keep-open": "yes", "idle": "yes",
                            "osd-level": "0", "terminal": "no"] {
        guard mpv_set_option_string(core, name, value) >= 0 else { close(); return false }
      }
      guard mpv_initialize(core) >= 0 else { close(); return false }
      var metal = mpv_metal_init_params(layer: Unmanaged.passUnretained(layer).toOpaque(),
        metal_device: layer.device.map { Unmanaged.passUnretained($0 as AnyObject).toOpaque() })
      let api = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_METAL as NSString).utf8String)
      let result = withUnsafeMutablePointer(to: &metal) { pointer in
        var parameters = [mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
                          mpv_render_param(type: MPV_RENDER_PARAM_METAL_INIT_PARAMS, data: pointer),
                          mpv_render_param()]
        return mpv_render_context_create(&context, core, &parameters)
      }
      guard result >= 0 else { close(); return false }
      return true
    }

    func command(_ arguments: [String], id: UInt64) -> Bool {
      let strings = arguments.map { strdup($0) }
      defer { strings.forEach { free($0) } }
      var pointers = strings.map { UnsafePointer<CChar>($0) } + [nil]
      return mpv_command_async(core, id, &pointers) >= 0
    }

    private func skipPendingFrame(_ context: OpaquePointer) {
      guard mpv_render_context_update(context) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
      var skip: CInt = 1
      withUnsafeMutablePointer(to: &skip) { pointer in
        var parameters = [mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: pointer),
                          mpv_render_param()]
        _ = mpv_render_context_render(context, &parameters)
      }
    }

    private func applyOptions(_ request: Request, core: OpaquePointer, context: OpaquePointer) -> Bool {
      var outstanding: [UInt64: (String, String)] = [:]
      for (index, name) in MPVPreviewRenderer.optionNames.enumerated() {
        guard let value = request.options[name], appliedOptions[name] != value else { continue }
        let reply = request.id &* 128 &+ UInt64(index + 1)
        let result = value.withCString { valuePointer in
          var pointer: UnsafePointer<CChar>? = valuePointer
          return mpv_set_property_async(core, reply, name, MPV_FORMAT_STRING, &pointer)
        }
        if result >= 0 { outstanding[reply] = (name, value) }
      }
      let deadline = Date(timeIntervalSinceNow: 4)
      while !outstanding.isEmpty && current(request.id) && Date() < deadline {
        let event = mpv_wait_event(core, 0).pointee
        if event.event_id == MPV_EVENT_SET_PROPERTY_REPLY,
           let entry = outstanding.removeValue(forKey: event.reply_userdata), event.error >= 0 {
          appliedOptions[entry.0] = entry.1
        }
        skipPendingFrame(context)
        if event.event_id == MPV_EVENT_NONE { usleep(5_000) }
      }
      return outstanding.isEmpty && current(request.id)
    }

    func render(_ request: Request) -> Bool {
      guard current(request.id), initialize(), let core, let context else { return false }
      guard applyOptions(request, core: core, context: context) else { return false }
      // Discard completed events from the preceding request before issuing this seek.
      while mpv_wait_event(core, 0).pointee.event_id != MPV_EVENT_NONE {}
      let sameFile = loadedPath == request.path
      let arguments = sameFile ? ["seek", String(request.seconds), "absolute+exact"] :
        ["loadfile", request.path, "replace", "-1", "start=\(request.seconds)"]
      guard command(arguments, id: request.id &* 128) else { return false }
      var replied = false
      var fileLoaded = sameFile
      var seekStarted = false
      var restarted = false
      var positionRequested = false
      var positionReceived = false
      var fpsReceived = false
      var position: Double?
      var fps = 24.0
      let deadline = Date(timeIntervalSinceNow: 4)
      while current(request.id), Date() < deadline {
        // A zero timeout is the only mpv_wait_event variant permitted on an
        // mpv render thread. All property operations below are asynchronous.
        let event = mpv_wait_event(core, 0).pointee
        switch event.event_id {
        case MPV_EVENT_COMMAND_REPLY where event.reply_userdata == request.id &* 128:
          guard event.error >= 0 else { return false }
          replied = true
        case MPV_EVENT_GET_PROPERTY_REPLY where event.reply_userdata == request.id &* 128 &+ 60:
          positionReceived = true
          if event.error >= 0, let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
             property.format == MPV_FORMAT_DOUBLE, let data = property.data {
            position = data.assumingMemoryBound(to: Double.self).pointee
          }
        case MPV_EVENT_GET_PROPERTY_REPLY where event.reply_userdata == request.id &* 128 &+ 61:
          fpsReceived = true
          if event.error >= 0, let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
             property.format == MPV_FORMAT_DOUBLE, let data = property.data {
            fps = data.assumingMemoryBound(to: Double.self).pointee
          }
        case MPV_EVENT_FILE_LOADED:
          if !sameFile { fileLoaded = true; restarted = false }
        case MPV_EVENT_SEEK:
          seekStarted = true
          restarted = false
        case MPV_EVENT_PLAYBACK_RESTART:
          // Option changes can restart the OLD file before loadfile completes.
          // Never accept that event as completion of this requested frame.
          if fileLoaded && (!sameFile || seekStarted) { restarted = true }
        case MPV_EVENT_END_FILE:
          // Replacing the previous file emits END_FILE before the new one is loaded.
          if let data = event.data?.assumingMemoryBound(to: mpv_event_end_file.self),
             data.pointee.error < 0 { loadedPath = nil; return false }
        default: break
        }
        if replied && restarted {
          if !positionRequested {
            positionRequested = true
            if mpv_get_property_async(core, request.id &* 128 &+ 60, "time-pos", MPV_FORMAT_DOUBLE) < 0 {
              return false
            }
            if mpv_get_property_async(core, request.id &* 128 &+ 61, "container-fps", MPV_FORMAT_DOUBLE) < 0 {
              fpsReceived = true
            }
          }
          if positionReceived && fpsReceived {
            let tolerance = max(0.05, 1 / max(1, fps))
            if let position, abs(position - request.seconds) <= tolerance {
              guard current(request.id) else { return false }
              // Seeking and rendering are serialized: only the requested decoded frame
              // reaches the layer, after its playback color settings have been applied.
              var parameters = [mpv_render_param()]
              guard mpv_render_context_render(context, &parameters) >= 0 else { return false }
              CATransaction.flush()
              mpv_render_context_report_swap(context)
              loadedPath = request.path
              return true
            }
            // The decoder may still be settling on the requested frame.
            positionRequested = false
            positionReceived = false
            fpsReceived = false
            position = nil
          }
        }
        // Let mpv advance while decoding, without showing an intermediate frame.
        skipPendingFrame(context)
        if event.event_id == MPV_EVENT_NONE { usleep(5_000) }
      }
      loadedPath = nil
      return false
    }

    func close() {
      if let context { mpv_render_context_free(context); self.context = nil }
      if let core { mpv_terminate_destroy(core); self.core = nil }
      loadedPath = nil
      appliedOptions = [:]
    }
  }

  private let queue = DispatchQueue(label: "tsmc.yina.preview.metal", qos: .userInitiated)
  private let worker: Worker

  init(layer: CAMetalLayer) { worker = Worker(layer: layer) }

  func request(path: String, seconds: Double, options: [String: String], completion: @escaping (Bool) -> Void) {
    worker.lock.lock()
    worker.generation &+= 1
    worker.pending = Request(id: worker.generation, path: path, seconds: max(0, seconds),
                             options: options, completion: completion)
    let start = !worker.running && !worker.closed
    if start { worker.running = true }
    worker.lock.unlock()
    if start { queue.async { [worker] in worker.run() } }
  }

  func cancel() {
    worker.lock.lock()
    worker.generation &+= 1
    let idleGeneration = worker.generation
    worker.pending = nil
    worker.lock.unlock()
    // Repeated hovers reuse the warm decoder. A hidden preview releases its
    // media handle, render context, and mpv core after a short idle interval.
    queue.asyncAfter(deadline: .now() + 3) { [worker] in
      worker.lock.lock()
      let stillIdle = !worker.closed && !worker.running && worker.pending == nil &&
        worker.generation == idleGeneration
      worker.lock.unlock()
      if stillIdle { worker.close() }
    }
  }

  deinit {
    worker.lock.lock()
    worker.closed = true
    worker.generation &+= 1
    worker.pending = nil
    worker.lock.unlock()
    // Network teardown must never block AppKit's main thread.
    queue.async { [worker] in worker.close() }
  }
}
#endif
