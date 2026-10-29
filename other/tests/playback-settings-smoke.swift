// xcrun swiftc -parse-as-library yina/PlaybackSettingsView.swift other/tests/playback-settings-smoke.swift -o /tmp/yina-settings-smoke
import AppKit
import SwiftUI

@main
struct PlaybackSettingsSmoke {
  @MainActor static func main() throws {
    let darkRender = CommandLine.arguments.contains("--dark-render")
    let isolatedHome = FileManager.default.temporaryDirectory.appendingPathComponent("yina-settings-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
    setenv("CFFIXED_USER_HOME", isolatedHome.path, 1)
    defer { try? FileManager.default.removeItem(at: isolatedHome) }
    _ = NSApplication.shared
    precondition(!NSScreen.screens.isEmpty,
                 "Run this native panel fixture with WindowServer access; restoration checks require a display")
    NSApp.appearance = NSAppearance(named: darkRender ? .darkAqua : .aqua)
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

    let bounds = PlaybackSettingsPanel.self
    precondition((700...780).contains(bounds.preferredContentSize.width) &&
                 (600...900).contains(bounds.preferredContentSize.height), "Preferred panel is outside the intended range")
    precondition(bounds.minimumContentSize.width <= bounds.preferredContentSize.width &&
                 bounds.maximumContentSize.width >= bounds.preferredContentSize.width &&
                 bounds.minimumContentSize.height <= bounds.preferredContentSize.height &&
                 bounds.maximumContentSize.height >= bounds.preferredContentSize.height,
                 "Preferred panel is outside its resize bounds")
    let visible = NSSize(width: 1000, height: 1000)
    precondition(bounds.normalizedContentSize(NSSize(width: 400, height: 300), visibleSize: visible)
                 == bounds.minimumContentSize, "Tiny restored content did not normalize")
    precondition(bounds.normalizedContentSize(NSSize(width: 1400, height: 1400), visibleSize: visible)
                 == bounds.maximumContentSize, "Oversized restored content did not normalize")
    precondition(bounds.normalizedContentSize(bounds.preferredContentSize, visibleSize: visible)
                 == bounds.preferredContentSize, "Preferred size changed")
    precondition(bounds.normalizedContentSize(NSSize(width: 1400, height: 1400),
                                              visibleSize: NSSize(width: 660, height: 550))
                 == NSSize(width: 660, height: 550), "Small-display bounds not honored")

    let panel = PlaybackSettingsPanel(model: model)
    func settle() {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
      panel.contentView?.layoutSubtreeIfNeeded()
    }
    func findScroll(_ view: NSView) -> NSScrollView? {
      if let scroll = view as? NSScrollView { return scroll }
      return view.subviews.lazy.compactMap(findScroll).first
    }
    precondition(panel.contentMinSize == bounds.minimumContentSize &&
                 panel.contentMaxSize == bounds.maximumContentSize, "Panel resize bounds missing")
    for width in [bounds.minimumContentSize.width, bounds.preferredContentSize.width,
                  bounds.maximumContentSize.width] {
      panel.setContentSize(NSSize(width: width, height: bounds.preferredContentSize.height))
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
    func allSubviews(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap(allSubviews)
    }
    panel.setContentSize(bounds.preferredContentSize)
    settle()
    func rotarySliders() -> [String: PlaybackSettingsRotarySlider] {
      Dictionary(uniqueKeysWithValues: allSubviews(panel.contentView!).compactMap {
        guard let slider = $0 as? PlaybackSettingsRotarySlider else { return nil }
        return (slider.accessibilityIdentifier(), slider)
      })
    }
    var rotary = rotarySliders()
    precondition(Set(rotary.keys) == ["PlaybackSettingsToneBass", "PlaybackSettingsToneMid", "PlaybackSettingsToneTreble"],
                 "Native rotary controls not present")
    for (id, slider) in rotary {
      precondition(slider.sliderType == .circular && slider.minValue == -12 && slider.maxValue == 12,
                   "\(id) is not a native -12…12 rotary slider")
      precondition(slider.isContinuous && slider.isEnabled && slider.target != nil && slider.action != nil,
                   "\(id) action/enabled state missing")
      precondition(slider.accessibilityLabel() == String(id.dropFirst("PlaybackSettingsTone".count)),
                   "\(id) accessibility label missing")
    }
    let priorMid = model.snapshot.audioGains[3..<7].map { $0 }
    let bass = rotary["PlaybackSettingsToneBass"]!
    bass.doubleValue = 6.7
    _ = bass.sendAction(bass.action!, to: bass.target)
    precondition(model.snapshot.audioGains[0..<3].allSatisfy { $0 == 7 } &&
                 model.snapshot.audioGains[3..<7].elementsEqual(priorMid),
                 "Rotary action lost integer stepping or other bands")
    _ = panel.makeFirstResponder(bass)
    precondition(panel.firstResponder === bass, "Native rotary cannot receive keyboard focus")
    let beforeAX = bass.doubleValue
    bass.accessibilityPerformIncrement()
    precondition(beforeAX == 7 && bass.doubleValue == 8 && model.gain(0) == 8,
                 "Accessibility increment did not route through the rotary action")
    let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                               windowNumber: panel.windowNumber, context: nil, characters: rightArrow,
                               charactersIgnoringModifiers: rightArrow, isARepeat: false, keyCode: 124)!
    var keyEditTransitions: [Bool] = []
    bass.editingChanged = { keyEditTransitions.append($0); model.setEditing($0) }
    bass.keyDown(with: key)
    precondition(keyEditTransitions == [true, false] && !bass.isEditing &&
                 bass.doubleValue == 9 && model.gain(0) == 9,
                 "Keyboard step did not update and finish its rotary edit")

    let noMedia = PlaybackSettingsSnapshot()
    model.receive(noMedia)
    settle()
    rotary = rotarySliders()
    precondition(rotary.values.allSatisfy { !$0.isEnabled }, "Tone controls active without media")
    model.receive(state)
    settle()

    // AppKit autosave is exercised with unique keys under a temporary home.
    for stale in [NSSize(width: 400, height: 300), NSSize(width: 1400, height: 1400)] {
      let name = "YINAPlaybackSettingsFixture-\(UUID().uuidString)"
      let writer = NSPanel(contentRect: NSRect(origin: .zero, size: stale),
                           styleMask: [.titled, .resizable], backing: .buffered, defer: false)
      writer.setFrameAutosaveName(name)
      writer.saveFrame(usingName: name)
      let restored = PlaybackSettingsPanel(model: model)
      guard let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(name)") else {
        fatalError("AppKit did not persist the test frame")
      }
      restored.setFrame(from: saved)
      // AppKit may clamp setFrame(from:) immediately. On a real display, force
      // the legacy size to exercise our screen-aware migration as well.
      if !NSScreen.screens.isEmpty {
        restored.setFrame(writer.frame, display: false)
        let preNormalizationSize = restored.contentRect(forFrameRect: restored.frame).size
        if stale.width < bounds.minimumContentSize.width {
          precondition(preNormalizationSize.width < bounds.minimumContentSize.width,
                       "Tiny saved frame was not restored before normalization")
        } else {
          precondition(preNormalizationSize.width > bounds.maximumContentSize.width,
                       "Oversized saved frame was not restored before normalization")
        }
      }
      let oldTop = restored.frame.maxY
      restored.normalizeSavedFrame()
      let firstNormalized = restored.frame
      restored.normalizeSavedFrame()
      precondition(restored.frame == firstNormalized, "Restored frame normalization drifted")
      let size = restored.contentRect(forFrameRect: restored.frame).size
      precondition(size.width >= restored.contentMinSize.width - 1 &&
                   size.width <= restored.contentMaxSize.width + 1 &&
                   size.height >= restored.contentMinSize.height - 1 &&
                   size.height <= restored.contentMaxSize.height + 1,
                   "Restored frame escaped bounded content size")
      if let visible = restored.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
        precondition(restored.frame.minX >= visible.minX - 1 &&
                     restored.frame.maxX <= visible.maxX + 1 &&
                     restored.frame.minY >= visible.minY - 1 &&
                     restored.frame.maxY <= visible.maxY + 1,
                     "Restored frame escaped the visible screen")
        if oldTop <= visible.maxY && oldTop >= visible.minY + restored.frame.height {
          precondition(abs(restored.frame.maxY - oldTop) <= 1,
                       "Normalizing a saved frame moved its on-screen top")
        }
      }
      NSWindow.removeFrame(usingName: name)
    }

    for (name, appearance) in [(darkRender ? "dark" : "light",
                                darkRender ? NSAppearance.Name.darkAqua : .aqua)] {
      NSApp.appearance = NSAppearance(named: appearance)
      let capture = PlaybackSettingsPanel(model: model)
      capture.appearance = NSAppearance(named: appearance)
      capture.contentView?.appearance = NSAppearance(named: appearance)
      capture.setContentSize(bounds.preferredContentSize)
      if let scroll = findScroll(capture.contentView!) {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
      }
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
      capture.contentView?.layoutSubtreeIfNeeded()
      let view = capture.contentView!
      guard let host = allSubviews(view).compactMap({ $0 as? NSHostingView<AnyView> }).first else {
        fatalError("Capture omitted the native SwiftUI host")
      }
      precondition(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance,
                   "Capture host did not inherit \(name) appearance")
      if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to:
          URL(fileURLWithPath: "/tmp/yina-settings-\(name).png"))
      }
      capture.setContentSize(bounds.minimumContentSize)
      if let scroll = findScroll(capture.contentView!) {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
      }
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
      capture.contentView?.layoutSubtreeIfNeeded()
      if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to:
          URL(fileURLWithPath: "/tmp/yina-settings-min-\(name).png"))
      }
    }
    NSApp.appearance = nil
    model.receive(noMedia)
    panel.setContentSize(bounds.minimumContentSize)
    settle()
    precondition(panel.contentRect(forFrameRect: panel.frame).width == bounds.minimumContentSize.width,
                 "Empty state resized the panel")
    if !darkRender {
      let dark = Process()
      dark.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      dark.arguments = ["--dark-render"]
      try dark.run()
      dark.waitUntilExit()
      precondition(dark.terminationStatus == 0, "Separate dark appearance fixture failed")
    }
    print("PASS: EQ preservation, delayed notifications, bounded panel/restoration, native rotary action/AX/disabled states, stable geometry, and light/dark renders")
  }
}
