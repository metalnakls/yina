import Cocoa

@main struct PiPTraceSmoke {
  static func main() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for index in 0..<45 {
      try Data().write(to: root.appendingPathComponent(String(format: "pip-%04d.jsonl", index)))
    }
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 180),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let video = NSView(frame: window.contentView!.bounds)
    let overlay = NSView(frame: video.frame)
    window.contentView!.addSubview(video)
    window.contentView!.addSubview(overlay)
    let trace = PiPTransitionTrace(source: window, video: video, overlay: overlay, directory: root)
    var finished = false
    trace.onFinish = { finished = true }
    DispatchQueue.global().async {
      for index in 0..<500 { trace.record("render-probe", "index=\(index)") }
    }
    overlay.isHidden = true
    trace.sample("hidden-probe")
    let deadline = Date().addingTimeInterval(8)
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
    precondition(rows.count <= 4096)
    print("PASS: automatic four-second capture, concurrent render events, window state, JSONL persistence, retention and shutdown (\(rows.count) events)")
  }
}
