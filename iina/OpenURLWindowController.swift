//
//  OpenURLWindowController.swift
//  iina
//
//  Created by Collider LI on 25/8/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa
import SwiftUI

@MainActor
private final class OpenURLViewModel: ObservableObject {
  @Published var urlText = ""
  @Published var username = ""
  @Published var password = ""
  @Published var rememberPassword = false
  @Published var errorMessage = ""
  @Published var showsError = false
  @Published var showsHTTPPrefix = false
  @Published var canOpen = true
  @Published var isLoading = false
  @Published var focusRequest = 0
}

private struct OpenURLView: View {
  @ObservedObject var model: OpenURLViewModel
  let validateURL: () -> Void
  let cancel: () -> Void
  let open: () -> Void
  let stopLoading: () -> Void

  @FocusState private var focusedField: Field?

  private enum Field {
    case url
    case username
    case password
  }

  private func localized(_ key: String, _ value: String) -> String {
    NSLocalizedString(key,
                      tableName: "OpenURLWindowController",
                      bundle: .main,
                      value: value,
                      comment: "")
  }

  var body: some View {
    ZStack {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 4) {
            if model.showsHTTPPrefix {
              Text("http://")
                .foregroundStyle(.secondary)
            }
            TextField(localized("XV7-VP-Ua2.placeholderString", "Please enter the URL here……"),
                      text: $model.urlText)
              .textFieldStyle(.plain)
              .foregroundStyle(model.showsError ? Color.red : Color.primary)
              .focused($focusedField, equals: .url)
              .onSubmit(open)
              .onChange(of: model.urlText) {
                validateURL()
              }
          }
          .font(.system(size: 20))

          if model.showsError {
            Text(model.errorMessage)
              .font(.caption2)
              .foregroundStyle(.red)
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
              VStack(alignment: .leading, spacing: 6) {
                Text(localized("Q1z-9O-n4X.title", "Username"))
                  .font(.caption)
                TextField("", text: $model.username)
                  .focused($focusedField, equals: .username)
              }
              VStack(alignment: .leading, spacing: 6) {
                Text(localized("uM6-Bp-Wdk.title", "Password"))
                  .font(.caption)
                SecureField("", text: $model.password)
                  .focused($focusedField, equals: .password)
              }
            }

            Toggle(localized("m0D-hR-3pr.title",
                             "Remember username and password for this host in keychain"),
                   isOn: $model.rememberPassword)
          }
          .padding(8)
        } label: {
          Text(localized("wxH-ic-Uug.title", "HTTP Authentication"))
            .fontWeight(.semibold)
        }

        HStack {
          Spacer()
          Button(localized("iNG-ee-EW6.title", "Cancel"), action: cancel)
            .keyboardShortcut(.cancelAction)
          Button(localized("8sC-lH-DOd.title", "Open"), action: open)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canOpen)
        }
      }
      .padding(16)
      .frame(minWidth: 544, minHeight: 225)

      if model.isLoading {
        ZStack {
          Rectangle()
            .fill(.ultraThinMaterial)
          VStack(spacing: 8) {
            ProgressView()
              .controlSize(.large)
            Text(NSLocalizedString("main.opening_stream", comment: "Opening stream…"))
              .font(.title3)
          }
          VStack {
            Spacer()
            HStack {
              Spacer()
              Button(localized("zbf-uh-uGz.title", "Stop Loading"), action: stopLoading)
            }
          }
          .padding(16)
        }
      }
    }
    .background(.ultraThinMaterial)
    .onAppear {
      focusedField = .url
    }
    .onChange(of: model.focusRequest) {
      focusedField = .url
    }
  }
}

@MainActor
class OpenURLWindowController: NSWindowController, NSWindowDelegate {

  private let viewModel = OpenURLViewModel()

  var isAlternativeAction = false
  var playerCore: PlayerCore?
  var loadingURL: String?

  private var invalidURLMessage: String {
    NSLocalizedString("alert.invalid_url", comment: "The URL is invalid.")
  }

  private var failedToOpenURLMessage: String {
    NSLocalizedString("alert.error_open", comment: "Cannot open file or stream!")
  }

  override func loadWindow() {
    let content = OpenURLView(model: viewModel,
                              validateURL: { [weak self] in self?.validateURL() },
                              cancel: { [weak self] in self?.window?.close() },
                              open: { [weak self] in self?.openURL() },
                              stopLoading: { [weak self] in self?.stopLoading() })
    let hostingView = NSHostingView(rootView: content)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 576, height: 257),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered,
                          defer: false)
    window.contentView = hostingView
    window.collectionBehavior.insert(.fullScreenNone)
    window.setFrameAutosaveName("IINAOpenURLWindow")
    window.isReleasedWhenClosed = false
    self.window = window
  }

  override func windowDidLoad() {
    super.windowDidLoad()
    window?.delegate = self
    window?.isMovableByWindowBackground = true
    window?.titlebarAppearsTransparent = true
    window?.titleVisibility = .hidden
    ([.closeButton, .miniaturizeButton, .zoomButton] as [NSWindow.ButtonType]).forEach {
      window?.standardWindowButton($0)?.isHidden = true
    }
  }

  func showLoadingScreen(playerCore: PlayerCore) {
    _ = window
    viewModel.isLoading = true
    window?.makeFirstResponder(nil)
    self.playerCore = playerCore
    loadingURL = playerCore.info.currentURL?.absoluteString
    NSApp.activate()
    showWindow(self)
  }

  func failedToLoadURL() {
    guard isWindowLoaded && window?.isVisible == true else { return }
    viewModel.urlText = loadingURL ?? ""
    viewModel.errorMessage = failedToOpenURLMessage
    viewModel.showsError = true
    viewModel.isLoading = false
  }

  func resetWindowState() {
    _ = window
    viewModel.urlText = ""
    viewModel.username = ""
    viewModel.password = ""
    viewModel.errorMessage = invalidURLMessage
    viewModel.showsError = false
    viewModel.rememberPassword = false
    viewModel.showsHTTPPrefix = false
    viewModel.canOpen = true
    viewModel.isLoading = false
    viewModel.focusRequest += 1
    playerCore = nil
    loadingURL = nil
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard let playerCore else { return true }
    playerCore.stop()
    return true
  }

  func windowWillClose(_ notification: Notification) {
    playerCore = nil
    viewModel.isLoading = false
  }

  override func cancelOperation(_ sender: Any?) {
    window?.close()
  }

  private func stopLoading() {
    guard let playerCore else { return }
    playerCore.stop()
    viewModel.isLoading = false
  }

  private func openURL() {
    if let url = getURL().url {
      if viewModel.rememberPassword,
         let host = url.host,
         !viewModel.username.isEmpty {
        try? KeychainAccess.write(username: viewModel.username,
                                  password: viewModel.password,
                                  forService: .httpAuth,
                                  server: host,
                                  port: url.port)
      }
      viewModel.isLoading = true
      window?.makeFirstResponder(nil)
      playerCore = PlayerCore.activeOrNewForMenuAction(isAlternative: isAlternativeAction)
      playerCore!.openURL(url)
    } else {
      Utility.showAlert("wrong_url_format")
    }
  }

  private func getURL() -> (url: URL?, hasScheme: Bool) {
    guard !viewModel.urlText.isEmpty else { return (nil, false) }
    let trimmedURLString = viewModel.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    var urlString = trimmedURLString
    var hasScheme = true
    if let url = URL(string: urlString), url.scheme == nil {
      urlString = "http://" + urlString
      hasScheme = false
    }
    guard let standardizedURL = NSURL(string: urlString)?.standardized,
          let components = NSURLComponents(url: standardizedURL, resolvingAgainstBaseURL: false) else {
      return (nil, false)
    }
    if !viewModel.username.isEmpty {
      components.user = viewModel.username
      if !viewModel.password.isEmpty {
        components.password = viewModel.password
      }
    }
    return (components.url, hasScheme)
  }

  private func validateURL() {
    if viewModel.urlText.isEmpty {
      viewModel.errorMessage = invalidURLMessage
      viewModel.showsError = false
      viewModel.showsHTTPPrefix = false
      viewModel.canOpen = true
      return
    }

    let (url, hasScheme) = getURL()
    if let url, let host = url.host {
      viewModel.showsError = false
      viewModel.canOpen = true
      viewModel.showsHTTPPrefix = !hasScheme
      if let (username, password) = try? KeychainAccess.read(username: nil,
                                                              forService: .httpAuth,
                                                              server: host,
                                                              port: url.port) {
        viewModel.username = username
        viewModel.password = password
      } else {
        viewModel.username = ""
        viewModel.password = ""
      }
    } else {
      viewModel.errorMessage = invalidURLMessage
      viewModel.showsError = true
      viewModel.showsHTTPPrefix = false
      viewModel.canOpen = false
    }
  }
}
