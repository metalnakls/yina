//
//  MainWindow.swift
//  yina
//
//  Created by Collider LI on 10/1/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa

class MainWindow: CommonWindow {
  override func keyDown(with event: NSEvent) {
    if menu?.performKeyEquivalent(with: event) == true {
      return
    }
    /// Forward all key events which the window receives to its controller.
    /// This allows `ESC` & `TAB` key bindings to work, instead of getting swallowed by
    /// MacOS keyboard focus navigation (which we don't use).
    if let controller = windowController as? MainWindowController {
      controller.keyDown(with: event)
    } else {
      super.keyDown(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    /// AppKit by default will prioritize menu item key equivalents over arrow key navigation
    /// (although for some reason it is the opposite for `ESC`, `TAB`, `ENTER` or `RETURN`).
    /// Need to add an explicit check here for arrow keys to ensure that they always work when desired.
    if let responder = firstResponder, shouldFavorArrowKeyNavigation(for: responder) {

      let keyCode = KeyCodeHelper.mpvKeyCode(from: event)
      let normalizedKeyCode = KeyCodeHelper.normalizeMpv(keyCode)

      switch normalizedKeyCode {
      case "UP", "DOWN", "LEFT", "RIGHT":
        // Send arrow keys to view to enable key navigation
        responder.keyDown(with: event)
        return true
      default:
        break
      }
    }
    return super.performKeyEquivalent(with: event)
  }

  private func shouldFavorArrowKeyNavigation(for responder: NSResponder) -> Bool {
    return responder as? NSTextView != nil
  }

}

class MainWindowContentView: NSView {
  override func resetCursorRects() {
    guard let controller = window?.windowController as? MainWindowController else { return }
    for side in [SidebarController.Side.leading, .trailing] where controller.sidebars.sideBar(for: side).status != .hidden {
      addCursorRect(controller.sidebars.resizeHandleRect(for: side), cursor: .resizeLeftRight)
    }
  }

  /// Invoked automatically when the view’s geometry changes such that its tracking areas need to be recalculated.
  ///
}

/// Hosts the video beneath AppKit's native soft titlebar edge effect. The video
/// fills the clip view and never scrolls; wheel events still reach the player.
final class VideoBackdropView: NSScrollView {
  private final class FixedClipView: NSClipView {
    override func scroll(to newOrigin: NSPoint) {
      super.scroll(to: .zero)
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
      NSRect(origin: .zero, size: proposedBounds.size)
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    contentView = FixedClipView()
    contentView.drawsBackground = false
    drawsBackground = false
    borderType = .noBorder
    hasHorizontalScroller = false
    hasVerticalScroller = false
    horizontalScrollElasticity = .none
    verticalScrollElasticity = .none
    allowsMagnification = false
    isTouchScrollingEnabled = false
    automaticallyAdjustsContentInsets = true
    translatesAutoresizingMaskIntoConstraints = false
  }

  override func scrollWheel(with event: NSEvent) {
    nextResponder?.scrollWheel(with: event)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
