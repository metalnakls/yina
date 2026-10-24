// Compiled by mpv-preview-smoke.py with the production preview renderer.
import Cocoa
import Metal

final class ProbeLayer: CAMetalLayer {
  private let sampleLock = NSLock()
  private var samples: [UInt64] = []
  var sampleCount: Int { sampleLock.lock(); defer { sampleLock.unlock() }; return samples.count }
  var pixel: UInt64 { sampleLock.lock(); defer { sampleLock.unlock() }; return samples.last ?? 0 }

  override func nextDrawable() -> CAMetalDrawable? {
    guard let drawable = super.nextDrawable() else { return nil }
    drawable.addPresentedHandler { [weak self, texture = drawable.texture] _ in
      guard let self, let device = self.device,
            let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer(),
            let buffer = device.makeBuffer(length: 256, options: .storageModeShared),
            let blit = command.makeBlitCommandEncoder() else { return }
      blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: texture.width / 2, y: texture.height / 2, z: 0),
                sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer,
                destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
      blit.endEncoding(); command.commit(); command.waitUntilCompleted()
      let value = buffer.contents().load(as: UInt64.self)
      sampleLock.lock(); samples.append(value); sampleLock.unlock()
    }
    return drawable
  }
}

NSApplication.shared.setActivationPolicy(.prohibited)
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 180),
                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
func surface(_ x: CGFloat) -> ProbeLayer {
  let view = NSView(frame: NSRect(x: x, y: 0, width: 320, height: 180))
  let layer = ProbeLayer(); layer.device = MTLCreateSystemDefaultDevice()
  layer.framebufferOnly = false; layer.maximumDrawableCount = 3
  layer.drawableSize = CGSize(width: 320, height: 180)
  view.layer = layer; view.wantsLayer = true; window.contentView!.addSubview(view)
  return layer
}
let first = surface(0), reference = surface(320)
let firstView = window.contentView!.subviews[0]
firstView.isHidden = true
window.title = "Generated video renderer test"
window.orderFrontRegardless()
let renderer = MPVPreviewRenderer(layer: first)
let referenceRenderer = MPVPreviewRenderer(layer: reference)
let directory = CommandLine.arguments[1]
func frame(_ renderer: MPVPreviewRenderer, _ layer: ProbeLayer, _ file: String,
           _ options: [String: String], seconds: Double = 0.25) -> UInt64 {
  var done: Bool?
  let before = layer.sampleCount
  renderer.request(path: directory + "/" + file, seconds: seconds, options: options) { success in
    DispatchQueue.main.async {
      firstView.isHidden = false
      done = success
    }
  }
  let deadline = Date(timeIntervalSinceNow: 8)
  while Date() < deadline && (done == nil || layer.sampleCount == before) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
  }
  precondition(done == true && layer.sampleCount > before, "No presented frame for \(file): done=\(String(describing: done)), samples=\(layer.sampleCount), before=\(before), format=\(layer.pixelFormat)")
  precondition(layer.pixel != 0, "Renderer presented an empty frame")
  return layer.pixel
}
func components(_ pixel: UInt64, hdr: Bool) -> [Int] {
  hdr ? [Int(pixel & 65535), Int((pixel >> 16) & 65535), Int((pixel >> 32) & 65535)] :
    [Int(pixel & 255), Int((pixel >> 8) & 255), Int((pixel >> 16) & 255)]
}
func equal(_ a: UInt64, _ b: UInt64, hdr: Bool) {
  for (x,y) in zip(components(a,hdr:hdr),components(b,hdr:hdr)) {
    precondition(abs(x-y) <= (hdr ? 128 : 2), "Preview differs from independently rendered reference: \(a), \(b)")
  }
}
let sdr = ["hwdec":"no", "target-trc":"auto", "target-prim":"auto", "target-peak":"auto",
           "inverse-tone-mapping":"no", "brightness":"0", "contrast":"0", "gamma":"0",
           "saturation":"0", "hdr-compute-peak":"no", "dither-depth":"-1"]
let original = frame(renderer, first, "sdr.mkv", sdr)
equal(original, frame(referenceRenderer, reference, "sdr.mkv", sdr), hdr:false)
var adjusted = sdr; adjusted["brightness"] = "20"; adjusted["contrast"] = "15"
let changed = frame(renderer, first, "sdr.mkv", adjusted)
equal(changed, frame(referenceRenderer, reference, "sdr.mkv", adjusted), hdr:false)
precondition(abs(components(changed,hdr:false)[1] - components(original,hdr:false)[1]) > 10,
             "Live equalizer settings did not change the rendered pixels")
var hdr = sdr; hdr["target-trc"] = "pq"; hdr["target-prim"] = "bt.2020"
let native = frame(renderer, first, "pq.mkv", hdr)
precondition(first.wantsExtendedDynamicRangeContent && first.pixelFormat == .bgra10_xr,
             "PQ preview silently fell back to SDR")
precondition(first.colorspace?.name == CGColorSpace.itur_2100_PQ)
// Calibrate the actual 64-bit XR storage with GPU clear colors, avoiding any
// assumptions about packing or component alignment in Metal's pixel format.
func clearPixel(_ value: Double) -> UInt64 {
 let device=first.device!
 let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra10_xr,width:1,height:1,mipmapped:false)
 descriptor.usage = [.renderTarget]; descriptor.storageMode = .private
 let texture=device.makeTexture(descriptor:descriptor)!
 let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=texture
 pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
 pass.colorAttachments[0].clearColor=MTLClearColorMake(value,value,value,1)
 let command=device.makeCommandQueue()!.makeCommandBuffer()!
 command.makeRenderCommandEncoder(descriptor:pass)!.endEncoding()
 let buffer=device.makeBuffer(length:256,options:.storageModeShared)!
 let blit=command.makeBlitCommandEncoder()!
 blit.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),
           sourceSize:MTLSize(width:1,height:1,depth:1),to:buffer,destinationOffset:0,
           destinationBytesPerRow:256,destinationBytesPerImage:256)
 blit.endEncoding();command.commit();command.waitUntilCompleted()
 return buffer.contents().load(as:UInt64.self)
}
let zero=Double(components(clearPixel(0),hdr:true)[1])
let white=Double(components(clearPixel(1),hdr:true)[1])
let pqSignal=(Double(components(native,hdr:true)[1])-zero)/(white-zero)
precondition(abs(pqSignal-0.508)<0.015,"100-nit PQ patch received another luminance transform: \(pqSignal)")
equal(native, frame(referenceRenderer, reference, "pq.mkv", hdr), hdr:true)
// A preceding SDR expansion must not leak its gain/peak into the next HDR frame.
var expanded = hdr; expanded["inverse-tone-mapping"] = "yes"; expanded["target-peak"] = "1000"
_ = frame(renderer, first, "sdr.mkv", expanded)
equal(frame(renderer, first, "pq.mkv", hdr), native, hdr:true)
var hlg = hdr; hlg["target-trc"] = "hlg"
_ = frame(renderer, first, "hlg.mkv", hlg)
precondition(first.wantsExtendedDynamicRangeContent && first.colorspace?.name == CGColorSpace.itur_2100_HLG)
// Coalesce fast pointer movement and discard canceled work.
var staleCompletions = 0
for index in 0..<30 {
 renderer.request(path:directory+"/pq.mkv", seconds:Double(index)/30,options:hdr) { _ in
  DispatchQueue.main.async { staleCompletions += 1 }
 }
}
renderer.cancel()
equal(frame(renderer,first,"sdr.mkv",adjusted,seconds:0.75), changed, hdr:false)
precondition(staleCompletions == 0, "A superseded request published a stale frame")
window.orderOut(nil)
print("PASS: real presented SDR/PQ/HLG pixels, live equalizer parity, SDR-expansion reset and latest-seek cancellation")
