// xcrun swiftc -parse-as-library yina/PlaybackSettingsView.swift other/tests/playback-settings-smoke.swift -o /tmp/yina-settings-smoke
import AppKit
import SwiftUI

@main
struct PlaybackSettingsSmoke {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let sample = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { rect in
      NSGradient(starting: .darkGray, ending: .black)!.draw(in: rect, angle: -90)
      NSAttributedString(string: "Aa", attributes: [.foregroundColor: NSColor.white,
                         .font: NSFont.systemFont(ofSize: 42)]).draw(at: NSPoint(x: 130, y: 65))
      return true
    }
    let titles = ["Bitchy", "Classic Yellow", "White on Black", "Netflix", "Beefy", "Embedded"]
    let model = PlaybackSettingsModel(styles: titles.enumerated().map {
      PlaybackSettingsStyle(id: $0.offset, title: $0.element, preview: sample)
    }, overrides: [PlaybackSettingsChoice(id: 0, title: "No")])
    var state = PlaybackSettingsSnapshot()
    state.hasMedia = true
    state.audioGains = [-3, -2, -1, 1, 2, 3, 4, 5, 6, 7]
    model.receive(state)
    var sentGains: [Double]?
    model.perform = { if case .equalizer(let gains) = $0 { sentGains = gains } }
    model.gainBinding(1).wrappedValue = 8
    precondition(sentGains == [-3, -2, -1, 8, 8, 8, 8, 5, 6, 7], "Editing mid erased another EQ band")
    model.setEditing(true)
    model.imageBinding(0).wrappedValue = 72
    state.subtitleVisible = false
    model.receive(state)
    precondition(model.snapshot.videoValues[0] == 72, "Delayed notification moved a dragged thumb")
    precondition(!model.snapshot.subtitleVisible, "Drag swallowed an unrelated setting change")
    model.setEditing(false)
    model.receive(state)
    precondition(model.snapshot.videoValues[0] == 0)

    let panel = PlaybackSettingsPanel(model: model)
    func settle() {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
      panel.contentView?.layoutSubtreeIfNeeded()
    }
    func findScroll(_ view: NSView) -> NSScrollView? {
      if let scroll = view as? NSScrollView { return scroll }
      return view.subviews.lazy.compactMap(findScroll).first
    }
    for width: CGFloat in [400, 600, 800] {
      panel.setContentSize(NSSize(width: width, height: 480))
      settle()
      let frame = panel.frame
      guard let scroll = findScroll(panel.contentView!) else { fatalError("Missing native scrolling") }
      let documentSize = scroll.documentView!.frame.size
      scroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
      scroll.reflectScrolledClipView(scroll.contentView)
      let origin = scroll.contentView.bounds.origin
      for value in [-100.0, -9, 0, 9, 100] {
        model.imageBinding(0).wrappedValue = value
        model.gainBinding(0).wrappedValue = value / 10
        model.snapshot.subtitleStyle = value < 0 ? 0 : 5
        settle()
        precondition(panel.frame == frame, "A setting resized the window")
        precondition(scroll.documentView!.frame.size == documentSize, "Value changed content geometry")
        precondition(scroll.contentView.bounds.origin == origin, "Value changed scroll position")
      }
      panel.setFrameOrigin(NSPoint(x: panel.frame.minX + 40, y: panel.frame.minY + 40))
      settle()
      precondition(panel.frame.size == frame.size, "Moving changed the panel size")
    }
    panel.setContentSize(NSSize(width: 600, height: 760))
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      panel.appearance = NSAppearance(named: appearance)
      settle()
      let view = panel.contentView!
      if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to:
          URL(fileURLWithPath: "/tmp/yina-settings-\(name).png"))
      }
      let rendered = ImageRenderer(content: PlaybackSettingsView(model: model)
        .environment(\.colorScheme, name == "dark" ? .dark : .light)
        .frame(width: 600, height: 760)
        .background(name == "dark" ? Color(nsColor: .darkGray) : Color(nsColor: .windowBackgroundColor)))
      if let cgImage = rendered.cgImage {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        try bitmap.representation(using: .png, properties: [:])!.write(to:
          URL(fileURLWithPath: "/tmp/yina-settings-rendered-\(name).png"))
      }
    }
    model.receive(PlaybackSettingsSnapshot())
    settle()
    precondition(panel.frame.width == 600, "Empty state resized the panel")
    print("PASS: EQ preservation, delayed notifications, stable slider/style geometry at 400/600/800, native scrolling, window moves, and empty state")
  }
}
