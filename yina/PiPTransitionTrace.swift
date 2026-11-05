import Cocoa
import QuartzCore
import Metal

/// Temporary, automatic diagnostics for the full-screen PiP entry flash.
/// AppKit sampling is main-thread-only; render callbacks only append scalar events
/// under the lock. File operations are serialized off the UI/render queues.
final class PiPTransitionTrace: @unchecked Sendable {
  private static let writer = DispatchQueue(label: "tsmc.yina.pip-trace", qos: .utility)
  private let lock = NSLock()
  private let started = CACurrentMediaTime()
  private let file: URL
  private var pending: [String] = []
  private var count = 0
  private var active = true
  private var timer: Timer?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private weak var source: NSWindow?
  private weak var video: NSView?
  private weak var overlay: NSView?
  private var ticks = 0
  var onFinish: (() -> Void)?

  var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }

  init(source: NSWindow?, video: NSView, overlay: NSView, directory: URL? = nil) {
    precondition(Thread.isMainThread)
    self.source = source
    self.video = video
    self.overlay = overlay
    let root = directory ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/tsmc.yina/PiPTransitions", isDirectory: true)
    file = root.appendingPathComponent("pip-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).jsonl")
    let file = self.file
    Self.writer.async {
      do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
          .filter { $0.lastPathComponent.hasPrefix("pip-") && $0.pathExtension == "jsonl" }
          .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in previous.dropFirst(39) { try FileManager.default.removeItem(at: old) }
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
          throw CocoaError(.fileWriteUnknown)
        }
      } catch { NSLog("[PiPTrace] Cannot create trace: %@", String(describing: error)) }
    }
    record("begin", "wall=\(Date().timeIntervalSince1970) build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown") os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    let names: [Notification.Name] = [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification]
    // Observe only relevant windows; never capture titles, filenames, or media URLs.
    let windowNames = names + [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
      NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification,
      NSWindow.didChangeBackingPropertiesNotification, NSWindow.didResizeNotification,
      NSWindow.didMoveNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
    for name in windowNames {
      observe(.default, name) { [weak self] note in
        guard let self, let window = note.object as? NSWindow,
              window === self.source || window === self.video?.window else { return }
        self.sample("notification:\(name.rawValue)")
      }
    }
    for name in [NSApplication.didChangeScreenParametersNotification,
                 NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
      observe(.default, name) { [weak self] _ in self?.sample("notification:\(name.rawValue)") }
    }
    observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification) {
      [weak self] _ in self?.sample("active-space-changed")
    }
    sample("before-entry")
    flush()
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.sample("tick")
      self.ticks += 1
      if self.ticks % 15 == 0 { self.flush() }
      if CACurrentMediaTime() - self.started >= 4 { self.finish() }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                       handler: @escaping (Notification) -> Void) {
    observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: handler)))
  }

  func record(_ event: String, _ detail: String = "") {
    let time = CACurrentMediaTime() - started
    lock.lock()
    defer { lock.unlock() }
    guard active, count < 4096 else { return }
    // JSON encoding is deferred to the writer, avoiding allocation-heavy serialization
    // in Metal presentation callbacks. Keep fields delimited until then.
    pending.append("\(time)\t\(event)\t\(detail)")
    count += 1
  }

  func sample(_ event: String) {
    precondition(Thread.isMainThread)
    guard isActive else { return }
    var detail = "source={\(windowState(source))} videoHost={\(windowState(video?.window))}"
    detail += " video={\(viewState(video))} overlay={\(viewState(overlay))} appActive=\(NSApp.isActive)"
    if let metal = video?.layer as? CAMetalLayer {
      detail += " drawable=\(metal.drawableSize) pixelFormat=\(metal.pixelFormat.rawValue) edr=\(metal.wantsExtendedDynamicRangeContent) colorspace=\(String(describing: metal.colorspace?.name)) headroom=\(metal.contentsHeadroom)"
    }
    record(event, detail)
  }

  private func windowState(_ window: NSWindow?) -> String {
    guard let window else { return "nil" }
    let screen = window.screen
    return "id=\(window.windowNumber) visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) space=\(window.isOnActiveSpace) style=\(window.styleMask.rawValue) level=\(window.level.rawValue) alpha=\(window.alphaValue) frame=\(window.frame) display=\(String(describing: screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")])) edr=\(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 0)/\(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 0)"
  }

  private func viewState(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    var value = "hidden=\(view.isHiddenOrHasHiddenAncestor) alpha=\(view.alphaValue) frame=\(view.frame)"
    var layer = view.layer
    var depth = 0
    while let current = layer, depth < 6 {
      value += " L\(depth)[\(type(of: current)) hidden=\(current.isHidden) opacity=\(current.opacity) bounds=\(current.bounds) animations=\(current.animationKeys() ?? []) presentedOpacity=\(current.presentation()?.opacity ?? -1)]"
      layer = current.superlayer
      depth += 1
    }
    return value
  }

  private func flush() {
    lock.lock()
    let batch = pending
    pending.removeAll(keepingCapacity: true)
    lock.unlock()
    guard !batch.isEmpty else { return }
    let file = self.file
    Self.writer.async {
      do {
        var data = Data()
        for row in batch {
          let fields = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
          let object: [String: Any] = ["seconds": Double(fields[0]) ?? 0,
                                       "event": String(fields[1]), "detail": String(fields[2])]
          data.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
          data.append(10)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
      } catch { NSLog("[PiPTrace] Cannot write trace: %@", String(describing: error)) }
    }
  }

  func finish() {
    precondition(Thread.isMainThread)
    guard isActive else { return }
    sample("end")
    lock.lock(); active = false; lock.unlock()
    timer?.invalidate()
    timer = nil
    observers.forEach { $0.0.removeObserver($0.1) }
    observers.removeAll()
    flush()
    onFinish?()
    onFinish = nil
  }

  deinit {
    timer?.invalidate()
    observers.forEach { $0.0.removeObserver($0.1) }
    flush()
  }
}
