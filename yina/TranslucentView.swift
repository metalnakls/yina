//
//  TranslucentView.swift
//  yina
//
//  Created by Hechen Li on 2026-05-27.
//  Copyright © 2026 lhc. All rights reserved.
//

class TranslucentView: NSView {
  enum Style {
    case liquidGlass
    case visualEffect
  }

  enum ContentPlacement {
    case insideMaterial
    case aboveMaterial
  }

  private var liquidGlassCornerRadius: CGFloat
  private var vevCornerRadius: CGFloat
  private var padding: (CGFloat, CGFloat)
  private let contentPlacement: ContentPlacement
  var content: NSView?
  var container: NSView?
  private var contentPlane: NSView?
  private var contentEDREnabled = false
  private var contentEDRHeadroom: CGFloat = 1
  var style: Style
  private var appliedStyle: Style?

  init(liquidGlassCornerRadius: CGFloat = 16, vevCornerRadius: CGFloat = 8,
       padding: (CGFloat, CGFloat), contentPlacement: ContentPlacement = .insideMaterial) {
    self.liquidGlassCornerRadius = liquidGlassCornerRadius
    self.vevCornerRadius = vevCornerRadius
    self.padding = padding
    self.contentPlacement = contentPlacement
    self.style = .liquidGlass
    super.init(frame: .zero)

    self.translatesAutoresizingMaskIntoConstraints = false
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    if let vev = container as? NSVisualEffectView {
      vev.state = .followsWindowActiveState
    }
  }

  func setContent(_ content: NSView) {
    self.content = content
    content.translatesAutoresizingMaskIntoConstraints = false
    setStyle(style, force: true)
  }

  func setStyle(_ newStyle: Style, force: Bool = false) {
    self.style = newStyle
    let force = force || (appliedStyle != newStyle)
    guard let content, force else { return }

    let wrapper = NSView()
    wrapper.translatesAutoresizingMaskIntoConstraints = false

    // [    [         [--padding--[      ]]]]
    // self container wrapper     content
    //
    // We can't control the padding between the container (Glass/VE View)
    // and its content, so we need the wrapper

    wrapper.addSubview(content)
    addContentPadding()

    switch newStyle {
    case .liquidGlass:
      let view = NSGlassEffectView()
      view.cornerRadius = liquidGlassCornerRadius
      view.translatesAutoresizingMaskIntoConstraints = false
      if contentPlacement == .insideMaterial {
        view.contentView = wrapper
      }
      container = view
    case .visualEffect:
      let view = NSVisualEffectView()
      view.clipsToBounds = true
      view.translatesAutoresizingMaskIntoConstraints = false
      view.blendingMode = .withinWindow
      view.material = .popover
      if contentPlacement == .insideMaterial {
        view.addSubview(wrapper)
        wrapper.padding(.all)
      }
      view.wantsLayer = true
      view.layer?.cornerRadius = vevCornerRadius
      container = view
    }

    subviews.forEach { $0.removeFromSuperview() }
    addSubview(container!)
    container!.padding(.all)
    if contentPlacement == .aboveMaterial {
      addSubview(wrapper, positioned: .above, relativeTo: container)
      wrapper.padding(.all)
    }
    contentPlane = wrapper
    if contentPlacement == .aboveMaterial {
      container?.setOwnExtendedDynamicRange(contentEDREnabled, headroom: contentEDRHeadroom)
      wrapper.setExtendedDynamicRange(contentEDREnabled, headroom: contentEDRHeadroom)
    }

    appliedStyle = style
  }

  func setContentExtendedDynamicRange(_ enabled: Bool, headroom: CGFloat) {
    contentEDREnabled = enabled
    contentEDRHeadroom = headroom
    if contentPlacement == .aboveMaterial {
      container?.setOwnExtendedDynamicRange(enabled, headroom: headroom)
    }
    contentPlane?.setExtendedDynamicRange(enabled, headroom: headroom)
  }

  func addContentPadding() {
    content!.padding(.horizontal(padding.0), .vertical(padding.1))
  }

  func setCornerRadius(liquidGlass: CGFloat, vev: CGFloat) {
    liquidGlassCornerRadius = liquidGlass
    vevCornerRadius = vev
    switch appliedStyle {
    case .liquidGlass:
      let view = container as! NSGlassEffectView
      view.cornerRadius = liquidGlassCornerRadius
    case .visualEffect:
      let view = container as! NSVisualEffectView
      view.layer?.cornerRadius = vevCornerRadius
    default:
      break
    }
  }

  override func rightMouseDown(with event: NSEvent) {}
  override func rightMouseUp(with event: NSEvent) {}
}
