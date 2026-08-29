//
//  SidebarPane.swift
//  iina
//
//  Created by Hechen Li on 2026-05-30.
//  Copyright © 2026 lhc. All rights reserved.
//

extension NSImage.SymbolConfiguration {
  static let sidebarIconConfig = {
    NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
  }()
}


protocol SidebarPane: NSView {
  var horizontalScroll: ((Bool) -> Void)? { get set }
}

class SidebarScrollView: NSScrollView, SidebarPane {
  class Container: NSBox {
    init(_ view: NSView, _ block: (NSView) -> Void) {
      super.init(frame: .zero)
      contentView = view
      translatesAutoresizingMaskIntoConstraints = false
      clipsToBounds = true
      boxType = .custom
      borderColor = .sidebarContainerBorder
      cornerRadius = 8
      fillColor = .gray.withAlphaComponent(0.1)
      block(view)
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
  }

  // swipe gesture callback, argument is true if is forward
  var horizontalScroll: ((Bool) -> Void)?

  private var deltaX: CGFloat = 0
  private var deltaY: CGFloat = 0
  private let angleThreshold: CGFloat = 5
  private let normThreshold: CGFloat = 80

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    drawsBackground = false
    hasVerticalScroller = true
    autohidesScrollers = true

    documentView = FlippedView()
    documentView!.translatesAutoresizingMaskIntoConstraints = false
    documentView!.padding(.top, .leading, .trailing, from: contentView)
  }
  
  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }
  
  override func scrollWheel(with event: NSEvent) {
    super.scrollWheel(with: event)

    // only handle trackpad events
    guard event.phase != [] || event.momentumPhase != [] else { return }

    switch event.phase {
    case .began:
      deltaX = 0
      deltaY = 0
    case .changed:
      deltaX += event.scrollingDeltaX
      deltaY += event.scrollingDeltaY
    case .ended:
      let angle = abs(deltaX / deltaY)
      let norm = sqrt(deltaX * deltaX + deltaY * deltaY)
      if angle > angleThreshold && norm > normThreshold {
        horizontalScroll?(deltaX < 0)
      }
      deltaX = 0
      deltaY = 0
    default:
      break
    }
  }
}
