import Cocoa

@main struct PiPTraceSmoke {
  static func main() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let kind = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "pip"
    let duration: TimeInterval = kind == "pip" ? 4 : 12
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for index in 0..<45 {
      try Data().write(to: root.appendingPathComponent(String(format: "\(kind)-%04d.jsonl", index)))
    }
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 180),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let video = NSView(frame: window.contentView!.bounds)
    let overlay = NSView(frame: video.frame)
    window.contentView!.addSubview(video)
    window.contentView!.addSubview(overlay)
    let trace = PiPTransitionTrace(source: window, video: video, overlay: overlay, directory: root, kind: kind, duration: duration)
    var finished = false
    trace.onFinish = { finished = true }
    trace.onSample = { [weak trace] in trace?.record("state-sample-hook") }
    DispatchQueue.global().async {
      for index in 0..<500 { trace.record("render-probe", "index=\(index)") }
    }
    overlay.isHidden = true
    trace.sample("hidden-probe")
    // Change a view without emitting a window notification or calling sample().
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { overlay.isHidden = false }
    let deadline = Date().addingTimeInterval(duration + 4)
    while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    precondition(finished && !trace.isActive, "Trace must stop automatically")
    trace.record("after-finish-must-not-appear")
    var rows: [[String: Any]] = []
    while Date() < deadline {
      let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      precondition(files.count == 40, "Retention must keep exactly 40 traces")
      let newest = files.sorted { $0.lastPathComponent > $1.lastPathComponent }.first!
      let text = try String(contentsOf: newest, encoding: .utf8)
      rows = try text.split(separator: "\n").map {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
      }
      if rows.contains(where: { $0["event"] as? String == "end" }) { break }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(rows.contains { $0["event"] as? String == "begin" })
    precondition(rows.contains { $0["event"] as? String == "end" })
    precondition(rows.filter { $0["event"] as? String == "render-probe" }.count == 500)
    precondition(rows.contains { $0["event"] as? String == "hidden-probe" && ($0["detail"] as? String)?.contains("hidden=true") == true })
    precondition(!rows.contains { $0["event"] as? String == "after-finish-must-not-appear" })
    precondition(rows.contains { $0["event"] as? String == "state-sample-hook" })
    precondition(rows.count <= Int(duration * 1024))
    let detailed = rows.filter { ($0["detail"] as? String)?.contains("source={") == true }.count
    let ticks = rows.filter { $0["event"] as? String == "tick" }
    precondition(ticks.count > Int(duration * 30), "Keep frame-cadence timing evidence")
    precondition(detailed < ticks.count / 4, "Stable windows must not get full descriptions every tick")
    precondition(rows.contains { $0["event"] as? String == "visual-state-changed" &&
      ($0["detail"] as? String)?.contains("overlay={hidden=false") == true }, "Detect view changes without notifications")
    let bytes = try JSONSerialization.data(withJSONObject: rows).count
    print("COMPARISON: \(kind) ticks=\(rows.filter { $0["event"] as? String == "tick" }.count) detailed=\(detailed) bytes=\(bytes)")
    print("PASS: automatic \(duration)-second \(kind) capture, concurrent render events, window state, JSONL persistence, retention and shutdown (\(rows.count) events)")
  }
}
