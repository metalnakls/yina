//
//  VideoPIPViewController.swift
//  yina
//
//  Created by low-batt on 3/29/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Cocoa

class VideoPIPViewController: PIPViewController, NSWindowDelegate {

  private var currentScreen: NSScreen?
  private weak var observedWindow: NSWindow?
  private var windowObservers: [NSObjectProtocol] = []

  /// Force a draw, if needed.
  ///
  /// The `forceDraw` method in `PlayerWindowController` will check to see if drawing is really needed and if so, force a
  /// draw of the view.
  private func forceDraw(_ reason: String) {
    guard let controller = delegate as? MainWindowController else { return }
    controller.forceDraw(reason)
  }

  /// Force a draw after entering PiP.
  ///
  /// If playback is paused then after entering PiP mode the PiP window will sometimes be white. Force a draw to ensure this does not
  /// happen and a frame is displayed. See PR #3973 for details.
  ///
  /// Any changes in this area must be tested on multiple macOS versions. Under 10.15, `presentAsPictureInPicture` behaves
  /// asynchronously.
  override func viewDidLayout() {
    super.viewDidLayout()
    forceDraw("entered PiP")
    guard let window = view.window else {
      // Internal error, should not occur.
      Logger.log("VideoPIPViewController.viewDidLayout window is nil", level: .error)
      return
    }
    window.backgroundColor = .black
    window.contentView?.wantsLayer = true
    window.contentView?.layer?.backgroundColor = NSColor.black.cgColor
    window.delegate = self
    if observedWindow !== window {
      windowObservers.forEach(NotificationCenter.default.removeObserver)
      windowObservers.removeAll()
      observedWindow = window
      for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                   NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification] {
        windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window,
          queue: .main) { [weak self] _ in
          (self?.delegate as? MainWindowController)?.pipHostGeometryChanged()
        })
      }
    }
    (delegate as? MainWindowController)?.pipHostWindowDidChange(window)
    if !window.isVisible {
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window, self.observedWindow === window else { return }
        (self.delegate as? MainWindowController)?.pipHostGeometryChanged()
      }
    }
  }

  /// Force a draw after exiting PiP.
  ///
  /// If playback is paused then after exiting PiP mode the main window will sometimes be black. Force a draw to ensure this does not
  /// happen and a frame is displayed. See issue #4268 and PR #4286 for details.
  override func viewDidDisappear() {
    super.viewDidDisappear()
    windowObservers.forEach(NotificationCenter.default.removeObserver)
    windowObservers.removeAll()
    observedWindow = nil
    (delegate as? MainWindowController)?.pipHostWindowDidChange(nil)
    forceDraw("exited PiP")
  }

  /// PiP window has changed screens.
  ///
  /// When the PiP window moves to a new screen the configuration of the display link may need to be changed and the ability of the
  /// screen to support HDR needs to be re-evaluated.
  func windowDidChangeScreen(_ notification: Notification) {
    let screen = self.view.window?.screen
    guard currentScreen != screen else { return }
    currentScreen = screen
    NSScreen.log("PiP window moved to screen", screen)
    guard let controller = self.delegate as? PlayerWindowController else {
      // Internal error, should not occur.
      Logger.log("VideoPIPViewController.windowDidChangeScreen delegate", level: .error)
      return
    }
    controller.videoView.updateDisplayLink()
    (delegate as? MainWindowController)?.pipHostGeometryChanged()
  }
}

enum PiPSubtitleGeometry {
  static func frame(below host: NSRect, height: CGFloat, in visibleFrame: NSRect) -> NSRect? {
    guard host.width > 0, height > 0 else { return nil }
    let frame = NSRect(x: host.minX, y: host.minY - height,
                       width: host.width, height: height)
    return visibleFrame.contains(frame) ? frame : nil
  }
}

/// Plain-text subtitle surface attached to the system PiP window. AppKit keeps
/// a child window in relative position when the PiP window moves; explicit
/// geometry updates handle PiP resize and screen changes.
final class PiPSubtitlePanel {
  private let panel: NSPanel
  private let primary = NSTextField(labelWithString: "")
  private let secondary = NSTextField(labelWithString: "")
  private weak var host: NSWindow?
  private var hasText = false
  /// Preference.swift registers 55 as the default mpv subtitle font size.
  /// AppKit title text supplies a native screen-point reference for PiP text.
  private let defaultSubtitleSize: CGFloat = 55

  init() {
    panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: true)
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
    let content = NSView(frame: .zero)
    panel.contentView = content
    for field in [primary, secondary] {
      field.isEditable = false
      field.isSelectable = false
      field.isBezeled = false
      field.drawsBackground = false
      field.alignment = .center
      field.lineBreakMode = .byWordWrapping
      field.maximumNumberOfLines = 0
      content.addSubview(field)
    }
    panel.alphaValue = 0
  }

  /// Returns false when there is no stable host or no room beneath the video.
  /// The caller then leaves mpv's native subtitle rendering enabled.
  func attach(to window: NSWindow, primaryText: String, secondaryText: String,
              showPrimary: Bool, showSecondary: Bool) -> Bool {
    guard window.isVisible, let visibleFrame = window.screen?.visibleFrame,
          window.occlusionState.contains(.visible) else { detach(); return false }
    let width = window.frame.width
    let baseFont = NSFont.preferredFont(forTextStyle: .title2)
    let fontSize = max(1, baseFont.pointSize *
      CGFloat(Preference.float(for: .subTextSize)) / defaultSubtitleSize *
      CGFloat(Preference.float(for: .subScale)))
    let fontName = Preference.string(for: .subTextFont) ?? ""
    if fontName != Constants.String.mpvDefaultFont && NSFont(name: fontName, size: fontSize) == nil {
      detach()
      return false
    }
    var font = fontName == Constants.String.mpvDefaultFont ?
      (NSFont(descriptor: baseFont.fontDescriptor, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)) :
      (NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize))
    if Preference.bool(for: .subBold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
    if Preference.bool(for: .subItalic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
    let primaryValue = showPrimary ? primaryText : ""
    let secondaryValue = showSecondary ? secondaryText : ""
    let margin = baseFont.pointSize * CGFloat(Preference.float(for: .subMarginX)) / defaultSubtitleSize
    guard margin >= 0, width > 2 * margin else { detach(); return false }
    let textWidth = width - 2 * margin
    let alignment = Preference.enum(for: .subAlignX) as Preference.SubAlignX
    let textAlignment: NSTextAlignment = alignment == .left ? .left : alignment == .right ? .right : .center
    primary.alignment = textAlignment
    secondary.alignment = textAlignment
    let primaryHeight = set(primary, text: primaryValue, font: font, width: textWidth,
                            reserveLine: showPrimary)
    let secondaryHeight = set(secondary, text: secondaryValue, font: font, width: textWidth,
                              reserveLine: showSecondary)
    let height = primaryHeight + secondaryHeight
    guard height > 0 else { detach(); return false }
    guard let frame = PiPSubtitleGeometry.frame(below: window.frame, height: height,
                                               in: visibleFrame) else { detach(); return false }
    panel.setFrame(frame, display: false)
    primary.frame = NSRect(x: margin, y: 0, width: textWidth, height: primaryHeight)
    secondary.frame = NSRect(x: margin, y: primaryHeight, width: textWidth, height: secondaryHeight)
    if host !== window {
      detach()
      window.addChildWindow(panel, ordered: .above)
      host = window
      panel.orderFront(nil)
    }
    hasText = !primaryValue.isEmpty || !secondaryValue.isEmpty
    return true
  }

  func reveal() { panel.alphaValue = hasText ? 1 : 0 }
  func conceal() { panel.alphaValue = 0 }

  func detach() {
    panel.alphaValue = 0
    host?.removeChildWindow(panel)
    panel.orderOut(nil)
    host = nil
  }

  private func set(_ field: NSTextField, text: String, font: NSFont,
                   width: CGFloat, reserveLine: Bool) -> CGFloat {
    guard reserveLine else { field.attributedStringValue = NSAttributedString(string: ""); return 0 }
    let color = Preference.string(for: .subTextColorString).flatMap(NSColor.init(mpvColorString:)) ?? .white
    let outline = Preference.string(for: .subBorderColorString).flatMap(NSColor.init(mpvColorString:)) ?? .black
    let shadowColor = Preference.string(for: .subShadowColorString).flatMap(NSColor.init(mpvColorString:)) ?? .clear
    let shadow = NSShadow()
    shadow.shadowColor = shadowColor
    shadow.shadowBlurRadius = CGFloat(Preference.float(for: .subBlur))
    let offset = CGFloat(Preference.float(for: .subShadowSize))
    shadow.shadowOffset = NSSize(width: offset, height: -offset)
    let border = CGFloat(Preference.float(for: .subBorderSize))
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .shadow: shadow]
    let spacing = CGFloat(Preference.float(for: .subSpacing))
    if spacing != 0 { attributes[.kern] = spacing }
    if border > 0 {
      attributes[.strokeColor] = outline
      attributes[.strokeWidth] = -100 * border / max(font.pointSize, 1)
    }
    let rendered = NSAttributedString(string: text, attributes: attributes)
    field.attributedStringValue = rendered
    let measured = rendered.boundingRect(with: NSSize(width: max(width, 1), height: 10000),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
    return ceil(max(font.ascender - font.descender, measured.height))
  }
}
