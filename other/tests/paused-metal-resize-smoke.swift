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
  @ReadWriteAtomic var isUninited = false
}

final class ResizeProbeLayer: ViewLayer, @unchecked Sendable {
  struct Sample { let size: CGSize; let edge: UInt32; let center: UInt32 }
  private let sampleLock = NSLock()
  private var samples: [Sample] = []
  var latest: Sample? { sampleLock.lock(); defer { sampleLock.unlock() }; return samples.last }

  override func nextDrawable() -> CAMetalDrawable? {
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
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
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
    waitUntil("initial paused frame") { layer.latest?.size == CGSize(width: 320, height: 180) }

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
    view.$isUninited.withWriteLock { $0 = true }
    layer.uninitRendering()
    mpv_terminate_destroy(mpv)
    window.orderOut(nil)
    print("PASS: paused PiP return and backing-scale changes redraw fitted pixels without resuming playback")
  }

  static func waitUntil(_ description: String, _ condition: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 5)
    while !condition() && Date() < deadline {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    if !condition() {
      fputs("FAIL: no \(description)\n", stderr)
      exit(1)
    }
  }
}
