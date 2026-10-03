//
//  ScreenshotOSDView.swift
//  yina
//
//  Created by Collider LI on 17/8/2020.
//  Copyright © 2020 lhc. All rights reserved.
//

import Cocoa
import SwiftUI

private enum ScreenshotOSDActionLabels {
  static let delete = NSLocalizedString(
    "JGi-s6-8NZ.title",
    tableName: "ScreenshotOSDView",
    value: "DELETE",
    comment: "Delete screenshot")
  static let edit = NSLocalizedString(
    "H12-rV-dHF.title",
    tableName: "ScreenshotOSDView",
    value: "EDIT",
    comment: "Edit screenshot")
  static let reveal = NSLocalizedString(
    "5fX-iV-Qu2.title",
    tableName: "ScreenshotOSDView",
    value: "REVEAL",
    comment: "Reveal screenshot in Finder")
}

private struct ScreenshotOSDContent: View {
  let image: NSImage
  let imageSize: NSSize
  let showsFileActions: Bool
  let deleteAction: () -> Void
  let editAction: () -> Void
  let revealAction: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Image(nsImage: image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: imageSize.width, height: imageSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
          RoundedRectangle(cornerRadius: 4)
            .stroke(Color(nsColor: NSColor.gridColor).opacity(0.6), lineWidth: 1)
        )

      if showsFileActions {
        HStack(spacing: 12) {
          Button(action: deleteAction) {
            Text(ScreenshotOSDActionLabels.delete)
              .lineLimit(1)
              .truncationMode(.tail)
          }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .bold))
            .frame(width: 54, height: 16)
            .accessibilityLabel(Text(ScreenshotOSDActionLabels.delete))
          Button(action: editAction) {
            Text(ScreenshotOSDActionLabels.edit)
              .lineLimit(1)
              .truncationMode(.tail)
          }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .bold))
            .frame(width: 35, height: 16)
            .accessibilityLabel(Text(ScreenshotOSDActionLabels.edit))
          Button(action: revealAction) {
            Text(ScreenshotOSDActionLabels.reveal)
              .lineLimit(1)
              .truncationMode(.tail)
          }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .bold))
            .frame(width: 56, height: 16)
            .accessibilityLabel(Text(ScreenshotOSDActionLabels.reveal))
        }
      }
    }
    .padding(.vertical, 8)
    .frame(width: imageSize.width, alignment: .topLeading)
  }
}

class ScreenshotOSDView: NSViewController {

  private var image: NSImage?
  private var size: NSSize?
  private var fileURL: URL?
  private var hostingView: NSHostingView<ScreenshotOSDContent>?

  func setImage(_ image: NSImage, size: NSSize, fileURL: URL?) {
    self.image = image
    self.size = size
    self.fileURL = fileURL
    if isViewLoaded {
      hostingView?.rootView = makeContent()
    }
  }

  override func loadView() {
    let hostingView = NSHostingView(rootView: makeContent())
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    self.hostingView = hostingView
    view = hostingView
  }

  private func makeContent() -> ScreenshotOSDContent {
    guard let image, let size else {
      fatalError("ScreenshotOSDView requires setImage(_:size:fileURL:) before loading its view")
    }

    return ScreenshotOSDContent(
      image: image,
      imageSize: size,
      showsFileActions: fileURL != nil,
      deleteAction: { [weak self] in self?.deleteBtnAction(()) },
      editAction: { [weak self] in self?.editBtnAction(()) },
      revealAction: { [weak self] in self?.revealBtnAction(()) }
    )
  }

  @IBAction func deleteBtnAction(_ sender: Any) {
    guard let fileURL else { return }
    try? FileManager.default.removeItem(at: fileURL)
    PlayerCore.active.hideOSD()
  }

  @IBAction func revealBtnAction(_ sender: Any) {
    guard let fileURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    PlayerCore.active.hideOSD()
  }

  @IBAction func editBtnAction(_ sender: Any) {
    guard let fileURL else { return }
    NSWorkspace.shared.open(fileURL)
    PlayerCore.active.hideOSD()
  }
}
