//
//  SubChooseViewController.swift
//  yina
//
//  Created by Collider LI on 4/3/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa
import SwiftUI

class SubChooseViewController: NSViewController {
  fileprivate struct SubtitleRow: Identifiable {
    let id: Int
    let name: String
    let left: String
    let right: String
  }

  fileprivate final class ViewState: ObservableObject {
    @Published var rows: [SubtitleRow] = []
    @Published var selectedRows: Set<Int> = []

    func update(with subtitles: [OnlineSubtitle]) {
      rows = subtitles.enumerated().map { index, subtitle in
        let description = subtitle.getDescription()
        return SubtitleRow(id: index,
                           name: description.name,
                           left: description.left,
                           right: description.right)
      }
      selectedRows.formIntersection(Set(rows.map(\.id)))
    }
  }

  private let viewState = ViewState()

  var subtitles: [OnlineSubtitle] = []

  var userDoneAction: (([OnlineSubtitle]) -> Void)?
  var userCanceledAction: (() -> Void)?

  weak var player: PlayerCore?
  var context: Any?

  override func loadView() {
    viewState.update(with: subtitles)
    view = NSHostingView(rootView: SubtitleChooserView(
      state: viewState,
      download: { [weak self] in self?.downloadSelectedSubtitles() },
      cancel: { [weak self] in self?.cancelSubtitleSelection() }
    ))
    view.translatesAutoresizingMaskIntoConstraints = false
  }

  /// Refreshes the SwiftUI presentation after a subtitle provider updates `subtitles`.
  func refresh() {
    let subtitles = subtitles
    DispatchQueue.main.async { [weak self] in
      self?.viewState.update(with: subtitles)
    }
  }

  private func downloadSelectedSubtitles() {
    guard let userDoneAction else { return }
    let selectedSubtitles: [OnlineSubtitle] = viewState.selectedRows.sorted().compactMap { index in
      guard subtitles.indices.contains(index) else { return nil }
      return subtitles[index]
    }
    guard !selectedSubtitles.isEmpty else { return }
    userDoneAction(selectedSubtitles)
    player?.hideOnlineSubtitleWindow()
    context = nil
  }

  func cancelSubtitleSelection() {
    guard let userCanceledAction else { return }
    userCanceledAction()
    player?.hideOnlineSubtitleWindow()
    context = nil
  }
}

private struct SubtitleChooserView: View {
  @ObservedObject var state: SubChooseViewController.ViewState

  let download: () -> Void
  let cancel: () -> Void

  private var selectionPrompt: String {
    NSLocalizedString("vAl-Km-bkf.title",
                      tableName: "SubChooseViewController",
                      value: "Please click to select subtitles to download:",
                      comment: "Subtitle chooser selection prompt")
  }

  private var downloadTitle: String {
    NSLocalizedString("y68-ot-NOl.title",
                      tableName: "SubChooseViewController",
                      value: "DOWNLOAD",
                      comment: "Subtitle chooser download button")
  }

  private var cancelTitle: String {
    NSLocalizedString("pPz-om-Xit.title",
                      tableName: "SubChooseViewController",
                      value: "CANCEL",
                      comment: "Subtitle chooser cancel button")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(selectionPrompt)
        .foregroundColor(.secondary)

      List(selection: $state.selectedRows) {
        ForEach(state.rows) { row in
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
              Text(row.left)
                .lineLimit(1)
              Spacer(minLength: 8)
              Text(row.right)
                .lineLimit(1)
            }
            .font(.caption)
            .foregroundColor(.secondary)

            Text(row.name)
              .lineLimit(1)
          }
          .padding(.vertical, 6)
          .contentShape(Rectangle())
          .onTapGesture(count: 2, perform: download)
          .tag(row.id)
        }
      }
      .listStyle(.plain)
      .frame(minHeight: 152)

      HStack(spacing: 8) {
        Spacer()
        Button(cancelTitle, action: cancel)
          .fontWeight(.bold)
          .keyboardShortcut(.cancelAction)
        Button(downloadTitle, action: download)
          .fontWeight(.bold)
          .disabled(state.selectedRows.isEmpty)
      }
    }
    .frame(minWidth: 480, idealWidth: 600, maxWidth: 600,
           minHeight: 200, idealHeight: 200)
  }
}


/// Subtitle search is an interactive workflow, independent of playback OSD.
final class OnlineSubtitleWindowController: NSWindowController, NSWindowDelegate {
  private var chooser: SubChooseViewController?

  init() {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
    panel.title = "Online Subtitles"
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    super.init(window: panel)
    panel.delegate = self
    panel.center()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func present(_ message: OSDMessage, accessoryView: NSView?, chooser: SubChooseViewController?) {
    self.chooser = chooser
    guard let window else { return }
    if let accessoryView {
      window.contentView = accessoryView
    } else {
      let (title, type) = message.titleAndType()
      let label = NSTextField(wrappingLabelWithString: title)
      label.alignment = .center
      let stack = NSStackView(views: [label])
      stack.orientation = .vertical
      stack.alignment = .centerX
      if case .withText(let detail) = type {
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        stack.addArrangedSubview(detailLabel)
      }
      switch message {
      case .startFindingSub, .downloadingSub:
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        stack.addArrangedSubview(spinner)
      default: break
      }
      let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
      stack.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(stack)
      NSLayoutConstraint.activate([
        stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.layoutMarginsGuide.leadingAnchor),
        stack.trailingAnchor.constraint(lessThanOrEqualTo: content.layoutMarginsGuide.trailingAnchor),
      ])
      window.contentView = content
    }
    showWindow(nil)
    window.makeKeyAndOrderFront(nil)
  }

  func dismiss() {
    chooser = nil
    window?.orderOut(nil)
  }

  func windowWillClose(_ notification: Notification) {
    let selection = chooser
    chooser = nil
    selection?.cancelSubtitleSelection()
  }
}
