//
//  VolumeButton.swift
//  yina
//
//  Created by Hechen Li on 2026-07-04.
//  Copyright © 2026 lhc. All rights reserved.
//


class VolumeButton: NSView {
  let imageView: NSImageView
  weak var player: PlayerCore!

  var target: Any?
  var action: Selector?

  private var previousIcon: String?
  var extendedDynamicRangeHeadroom: CGFloat = 1 {
    didSet {
      imageView.contentTintColor = extendedDynamicRangeHeadroom > 1
        ? .hdrWhite(intensity: 0.84, headroom: extendedDynamicRangeHeadroom)
        : nil
      imageView.needsDisplay = true
    }
  }

  init(player: PlayerCore, target: Any? = nil, action: Selector? = nil) {
    self.target = target
    self.action = action
    self.player = player

    self.imageView = NSImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.imageScaling = .scaleProportionallyDown

    super.init(frame: .zero)

    translatesAutoresizingMaskIntoConstraints = false
    addSubview(imageView)
    imageView.padding(.all)
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func mouseDown(with event: NSEvent) {
    guard let target, let action else { return }
    NSApp.sendAction(action, to: target, from: self)
  }

  func update() {
    let res = volumeIcon()
    guard let icon = res.image, res.name != previousIcon else { return }
    let useReplace = (previousIcon?.contains("slash") ?? false) || (res.name.contains("slash"))
    if useReplace {
      imageView.setSymbolImage(icon, contentTransition: .replace.offUp)
    } else {
      imageView.image = icon
    }
    previousIcon = res.name
  }

  private func volumeIcon() -> (image: NSImage?, name: String) {
    guard let player, !player.info.isMuted else {
      let name = "speaker.slash.fill"
      return (.sf(name), name)
    }
    let symbol = player.info.volume > PlayerCore.minimumVolume
      ? "speaker.wave.3.fill"
      : "speaker.fill"
    let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    return (.sf(symbol, withConfiguration: configuration), symbol)
  }
}
