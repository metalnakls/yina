import Cocoa
import Metal

enum Logger {
  static func fatal(_ message: String) -> Never { fatalError(message) }
  static func log(_ message: String) {}
}

final class TestMPV {
  var mpvRenderContext: OpaquePointer?
  func shouldRenderUpdateFrame() -> Bool {
    guard let mpvRenderContext else { return false }
    return mpv_render_context_update(mpvRenderContext) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0
  }
  func mpvUninitRendering() {
    if let mpvRenderContext { mpv_render_context_free(mpvRenderContext) }
    mpvRenderContext = nil
  }
}

final class TestPlayer { let mpv = TestMPV() }
final class VideoView: NSView {
  let player = TestPlayer()
  var isPresentedInSystemPiP = false
  @ReadWriteAtomic var isUninited = false
  override func viewDidHide() { super.viewDidHide(); DispatchQueue.main.async { [weak self] in (self?.layer as? ViewLayer)?.refreshPresentationEligibility() } }
  override func viewDidUnhide() { super.viewDidUnhide(); DispatchQueue.main.async { [weak self] in (self?.layer as? ViewLayer)?.refreshPresentationEligibility() } }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); (layer as? ViewLayer)?.refreshPresentationEligibility() }
}

final class ResizeProbeLayer: ViewLayer, @unchecked Sendable {
  struct Sample { let size: CGSize; let edge: UInt32; let center: UInt32 }
  private let sampleLock = NSLock()
  private var samples: [Sample] = []
  private var acquisitions = 0
  var acquisitionCount: Int { sampleLock.lock(); defer { sampleLock.unlock() }; return acquisitions }
  var sampleCount: Int { sampleLock.lock(); defer { sampleLock.unlock() }; return samples.count }
  var latest: Sample? { sampleLock.lock(); defer { sampleLock.unlock() }; return samples.last }

  override func nextDrawable() -> CAMetalDrawable? {
    sampleLock.lock(); acquisitions += 1; sampleLock.unlock()
    guard let drawable = super.nextDrawable() else { return nil }
    drawable.addPresentedHandler { [weak self, texture = drawable.texture] _ in
      guard let self, let queue = device?.makeCommandQueue(),
            let command = queue.makeCommandBuffer(),
            let buffer = device?.makeBuffer(length: 512, options: .storageModeShared),
            let blit = command.makeBlitCommandEncoder() else { return }
      for (index, y) in [1, texture.height / 2].enumerated() {
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: texture.width / 2, y: y, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer,
                  destinationOffset: index * 256, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
      }
      blit.endEncoding()
      command.commit()
      command.waitUntilCompleted()
      let sample = Sample(size: CGSize(width: texture.width, height: texture.height),
                          edge: buffer.contents().load(as: UInt32.self),
                          center: buffer.contents().advanced(by: 256).load(as: UInt32.self))
      sampleLock.lock(); samples.append(sample); sampleLock.unlock()
    }
    return drawable
  }
}

@main struct PausedMetalResizeSmoke {
  static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    NSApp.finishLaunching()
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.level = .floating
    let view = VideoView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    let layer = ResizeProbeLayer(view)
    layer.contentsScale = 1
    view.layer = layer
    view.wantsLayer = true
    window.contentView!.addSubview(view)
    window.orderFrontRegardless()
    layer.layoutSublayers()
    let mpv = mpv_create()!
    for (key, value) in ["config": "no", "load-scripts": "no", "vo": "libmpv", "ao": "null",
                         "pause": "yes", "hwdec": "no", "target-trc": "srgb", "target-prim": "bt.709"] {
      precondition(mpv_set_option_string(mpv, key, value) >= 0)
    }
    precondition(mpv_initialize(mpv) >= 0)
    var metal = mpv_metal_init_params(layer: Unmanaged.passUnretained(layer).toOpaque(),
                                     metal_device: Unmanaged.passUnretained(layer.device! as AnyObject).toOpaque())
    "metal".withCString { api in
      withUnsafeMutablePointer(to: &metal) { metal in
        var params = [mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                                       data: UnsafeMutableRawPointer(mutating: api)),
                      mpv_render_param(type: MPV_RENDER_PARAM_METAL_INIT_PARAMS, data: metal),
                      mpv_render_param()]
        precondition(mpv_render_context_create(&view.player.mpv.mpvRenderContext, mpv, &params) >= 0)
      }
    }
    mpv_render_context_set_update_callback(view.player.mpv.mpvRenderContext, { context in
      Unmanaged<ViewLayer>.fromOpaque(context!).takeUnretainedValue().update()
    }, Unmanaged.passUnretained(layer).toOpaque())
    let path = CommandLine.arguments[1].replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    precondition(mpv_command_string(mpv, "loadfile \"\(path)\"") >= 0)
    waitUntil("initial paused frame") {
      return layer.latest?.size == CGSize(width: 320, height: 180)
    }

    // Model the PiP return race: the window's frame observer requests a draw
    // before Core Animation has laid out the final full-size drawable.
    layer.update(force: true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    view.frame.size = CGSize(width: 800, height: 600)
    layer.layoutSublayers()
    waitUntil("a fitted 800x600 frame after returning from PiP while still paused") {
      layer.latest?.size == CGSize(width: 800, height: 600)
    }
    let sample = layer.latest!
    precondition(sample.edge & 0x00ffffff == 0, "Paused resized video lost its letterbox")
    precondition(sample.center & 0x00ffffff != 0, "Paused frame was not rendered")
    precondition(layer.contentsGravity == .resizeAspect, "Stale drawable must fit while a resized frame is pending")
    layer.contentsScale = 2
    layer.layoutSublayers()
    waitUntil("a paused redraw at the new backing scale") {
      layer.latest?.size == CGSize(width: 1600, height: 1200)
    }
    precondition(layer.latest!.edge & 0x00ffffff == 0, "Backing-scale change lost the letterbox")
    var paused: Int32 = 0
    precondition(mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &paused) >= 0 && paused == 1)
    let baseline = CommandLine.arguments.contains("--baseline")
    func compare(_ label: String) {
      pump(0.25)
      let before = layer.acquisitionCount
      for _ in 0..<12 { layer.update(force: true) }
      pump(0.5)
      let acquired = layer.acquisitionCount - before
      print("COMPARISON: \(label) drawable acquisitions=\(acquired) for 12 forced updates")
      if !baseline { precondition(acquired == 0, "Hidden video must service updates without acquiring drawables") }
    }
    view.isHidden = true
    compare("hidden view")
    let afterHidden = layer.acquisitionCount
    view.isHidden = false
    if baseline { layer.update(force: true) }
    waitUntil("visible redraw") { layer.acquisitionCount > afterHidden }
    window.orderOut(nil)
    compare("hidden window")
    let afterWindow = layer.acquisitionCount
    window.orderFrontRegardless()
    if baseline { layer.update(force: true) }
    waitUntil("restored window redraw") { layer.acquisitionCount > afterWindow }
    let cover = NSWindow(contentRect: window.frame.insetBy(dx: -20, dy: -20),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    cover.isReleasedWhenClosed = false
    cover.isOpaque = true
    cover.backgroundColor = .black
    cover.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
    cover.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    cover.orderFrontRegardless()
    waitUntil("fully covered window occlusion") { !window.occlusionState.contains(.visible) }
    compare("fully covered window")
    let covered = layer.acquisitionCount
    cover.orderOut(nil)
    if baseline { layer.update(force: true) }
    waitUntil("uncovered redraw") { layer.acquisitionCount > covered }
    // A PiP-style host change must use the new window, not the hidden source.
    let host = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 320, height: 180),
                        styleMask: [.borderless], backing: .buffered, defer: false)
    host.isReleasedWhenClosed = false
    host.level = .floating
    host.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    host.contentView!.addSubview(view)
    view.frame = host.contentView!.bounds
    window.orderOut(nil)
    host.orderFrontRegardless()
    layer.layoutSublayers()
    let beforeHost = layer.acquisitionCount
    waitUntil("new host redraw while source hidden") { layer.acquisitionCount > beforeHost }
    host.orderOut(nil)
    pump(0.2)
    if !baseline {
      let beforeSnapshot = layer.acquisitionCount
      var complete = false
      Task { @MainActor in
        _ = await layer.captureSnapshot()
        complete = true
      }
      waitUntil("explicit snapshot while host hidden") { complete }
      precondition(layer.acquisitionCount > beforeSnapshot, "Explicit snapshots must bypass occlusion suppression")
    }
    if !baseline {
      // Unlike a normal NSWindow, the system's remotely hosted PiP window can
      // remain occluded according to AppKit while displaying its video onscreen.
      let pip = PIPViewController()
      let videoController = NSViewController()
      view.isPresentedInSystemPiP = true
      videoController.view = view
      pip.aspectRatio = CGSize(width: 320, height: 180)
      pip.presentAsPicture(inPicture: videoController)
      waitUntil("actual system PiP attachment") { view.window != nil && view.window !== host }
      pump(0.3)
      layer.refreshPresentationEligibility()
      let presented = layer.sampleCount
      precondition(mpv_set_property_string(mpv, "pause", "no") >= 0)
      pump(0.6)
      precondition(layer.sampleCount > presented + 2, "Actual system PiP must keep presenting video frames")
      print("PASS: actual system PiP presented \(layer.sampleCount - presented) frames; host occlusion=\(view.window!.occlusionState.rawValue)")
      precondition(mpv_set_property_string(mpv, "pause", "yes") >= 0)
      pip.dismiss(videoController)
      pump(0.4)
      host.contentView!.addSubview(view)
      view.isPresentedInSystemPiP = false
      layer.refreshPresentationEligibility()
      pump(0.2)
    }
    if !baseline {
      var beforeTime = 0.0
      precondition(mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &beforeTime) >= 0)
      precondition(mpv_set_property_string(mpv, "pause", "no") >= 0)
      pump(0.7)
      var afterTime = 0.0
      precondition(mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &afterTime) >= 0)
      precondition(afterTime - beforeTime > 0.2, "Hidden playback must keep advancing")
      print("PASS: hidden playback advanced \(afterTime - beforeTime) seconds while presentation was suppressed")
    }
    view.$isUninited.withWriteLock { $0 = true }
    layer.uninitRendering()
    mpv_terminate_destroy(mpv)
    window.orderOut(nil)
    print("PASS: paused PiP return and backing-scale changes redraw fitted pixels without resuming playback")
  }

  static func pump(_ seconds: Double) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
      while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
    }
  }

  static func waitUntil(_ description: String, _ condition: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 5)
    while !condition() && Date() < deadline {
      while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
        NSApp.sendEvent(event)
      }
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    if !condition() {
      fputs("FAIL: no \(description)\n", stderr)
      exit(1)
    }
  }
}
