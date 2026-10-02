//
//  PluginPermissionView.swift
//  yina
//
//  Created by Collider LI on 17/9/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa
import SwiftUI

class PluginPermissionView: NSViewController {
  var name: String
  var desc: String
  var isDangerous: Bool

  init(name: String, desc: String, isDangerous: Bool) {
    self.name = name
    self.desc = desc
    self.isDangerous = isDangerous
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let content = PluginPermissionContentView(name: name,
                                              desc: desc,
                                              isDangerous: isDangerous)
    let hostingView = NSHostingView(rootView: content)
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    hostingView.setContentHuggingPriority(.required, for: .vertical)
    hostingView.setContentCompressionResistancePriority(.required, for: .vertical)
    view = hostingView
  }
}

private struct PluginPermissionContentView: View {
  let name: String
  let desc: String
  let isDangerous: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .center, spacing: 8) {
        Text(name)
          .font(.system(size: NSFont.smallSystemFontSize, weight: .bold))
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)

        if isDangerous {
          Image(nsImage: NSImage(named: NSImage.Name("NSCaution")) ?? NSImage())
            .resizable()
            .scaledToFit()
            .frame(width: 16, height: 16)
            .accessibilityLabel(Text(NSLocalizedString("alert.title_warning", comment: "Warning")))
        }
      }
      .frame(minHeight: 16)

      Text(desc)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, 4)
    .padding(.horizontal, 8)
    .padding(.bottom, 6)
    .frame(minWidth: 251, minHeight: 46, alignment: .topLeading)
    .background {
      RoundedRectangle(cornerRadius: 4)
        .fill(isDangerous
              ? Color(nsColor: NSColor.systemRed.withAlphaComponent(0.3))
              : Color(nsColor: NSColor.alternatingContentBackgroundColors.last ?? .controlBackgroundColor))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 4)
        .stroke(Color(nsColor: .tertiaryLabelColor))
    }
  }
}
