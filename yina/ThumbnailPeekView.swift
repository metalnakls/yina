//
//  ThumbnailPeekView.swift
//  yina
//
//  Created by lhc on 12/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

class ThumbnailPeekView: NSView {

  var imageView: NSImageView!

  func setHDRPlaybackEnabled(_ enabled: Bool) {
    imageView.preferredImageDynamicRange = enabled ? .high : .standard
  }

  func setImage(_ image: NSImage, rotation: Int, hdrEnabled: Bool) {
    setHDRPlaybackEnabled(hdrEnabled)
    let rotation = ((rotation % 360) + 360) % 360
    guard rotation != 0, rotation % 90 == 0,
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      imageView.image = image
      return
    }
    // Rotate the packed pixels without a drawing context or color conversion.
    // lockFocus would reduce HDR to 8-bit SDR; the transfer function must survive.
    guard cgImage.bitsPerPixel % 8 == 0, let colorSpace = cgImage.colorSpace,
          let sourceData = cgImage.dataProvider?.data as Data? else {
      imageView.image = image
      return
    }
    let bytesPerPixel = cgImage.bitsPerPixel / 8
    let width = rotation == 180 ? cgImage.width : cgImage.height
    let height = rotation == 180 ? cgImage.height : cgImage.width
    let bytesPerRow = width * bytesPerPixel
    guard bytesPerPixel > 0, sourceData.count >= cgImage.bytesPerRow * cgImage.height else {
      imageView.image = image
      return
    }
    var pixels = Data(count: bytesPerRow * height)
    sourceData.withUnsafeBytes { source in
      pixels.withUnsafeMutableBytes { destination in
        for y in 0..<cgImage.height {
          for x in 0..<cgImage.width {
            let targetX = rotation == 90 ? cgImage.height - 1 - y : rotation == 180 ? cgImage.width - 1 - x : y
            let targetY = rotation == 90 ? x : rotation == 180 ? cgImage.height - 1 - y : cgImage.width - 1 - x
            destination.baseAddress!.advanced(by: targetY * bytesPerRow + targetX * bytesPerPixel)
              .copyMemory(from: source.baseAddress!.advanced(by: y * cgImage.bytesPerRow + x * bytesPerPixel),
                          byteCount: bytesPerPixel)
          }
        }
      }
    }
    guard let provider = CGDataProvider(data: pixels as CFData),
          let output = CGImage(width: width, height: height, bitsPerComponent: cgImage.bitsPerComponent,
                               bitsPerPixel: cgImage.bitsPerPixel, bytesPerRow: bytesPerRow,
                               space: colorSpace, bitmapInfo: cgImage.bitmapInfo, provider: provider,
                               decode: nil, shouldInterpolate: true, intent: cgImage.renderingIntent) else {
      imageView.image = image
      return
    }
    let tagged = CGImageCreateCopyWithContentHeadroom(max(1, cgImage.contentHeadroom), output) ?? output
    imageView.image = NSImage(cgImage: tagged, size: .zero)
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setup()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  private func setup() {
    wantsLayer = true
    layer?.cornerRadius = 4
    layer?.masksToBounds = true
    layer?.borderWidth = 1
    layer?.borderColor = CGColor(gray: 0.6, alpha: 0.5)

    let s = NSShadow()
    s.shadowBlurRadius = 2
    s.shadowColor = .black
    shadow = s

    imageView = NSImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.wantsLayer = true
    imageView.layer?.cornerRadius = 4
    imageView.layer?.masksToBounds = true
    imageView.imageScaling = .scaleAxesIndependently
    addSubview(imageView)
    imageView.padding(.all(0))
  }

}
