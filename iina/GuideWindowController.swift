//
//  GuideWindowController.swift
//  iina
//
//  Created by Collider LI on 26/8/2020.
//  Copyright © 2020 lhc. All rights reserved.
//

import Cocoa
import SwiftUI
@preconcurrency import WebKit

fileprivate let highlightsLink = "https://iina.io/highlights"

private enum GuideLocalizedString {
  static let continueTitle = value(
    "pRW-Nk-MIQ.title",
    fallback: "Continue",
    comment: "Continue"
  )
  static let websiteTitle = value(
    "FJS-b9-ATj.title",
    fallback: "Website",
    comment: "Website"
  )
  static let loadingFailed = value(
    "oaH-Na-skD.title",
    fallback: "Failed to load highlights. Please visit our website https://iina.io for more information.",
    comment: "Failed to load highlights message"
  )

  private static func value(_ key: String, fallback: String, comment: String) -> String {
    NSLocalizedString(key, tableName: "GuideWindowController", bundle: .main, value: fallback, comment: comment)
  }
}

private enum GuideLoadState: Equatable {
  case loading
  case loaded
  case failed
}

private final class GuideWindowModel: ObservableObject {
  @Published var loadState: GuideLoadState = .loading
}

class GuideWindowController: NSWindowController {
  enum Page {
    case highlights
  }

  private let model = GuideWindowModel()
  private var highlightsWebView: WKWebView?

  override init(window: NSWindow?) {
    super.init(window: window)
  }

  convenience init() {
    let window = CommonWindow(
      contentRect: NSRect(x: 0, y: 0, width: 740, height: 588),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    self.init(window: window)

    let webView = WKWebView()
    webView.navigationDelegate = self
    highlightsWebView = webView

    window.title = NSLocalizedString("guide.highlights", comment: "Highlights")
    window.contentViewController = NSHostingController(rootView: GuideWindowView(
      webView: webView,
      model: model,
      continueAction: { [weak self] in self?.continueBtnAction() },
      websiteAction: { [weak self] in self?.visitIINAWebsite() }
    ))
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show(pages: [Page]) {
    _ = window
    loadHighlightsPage()
    showWindow(self)
  }

  private func loadHighlightsPage() {
    guard let webView = highlightsWebView else { return }

    model.loadState = .loading
    window?.title = NSLocalizedString("guide.highlights", comment: "Highlights")

    let (version, _) = InfoDictionary.shared.version
    let versionNumber = version.split(separator: "-").first!
    let url = URL(string: "\(highlightsLink)/\(versionNumber)/")!
    webView.load(URLRequest(url: url))
  }

  private func continueBtnAction() {
    window?.close()
  }

  private func visitIINAWebsite() {
    NSWorkspace.shared.open(URL(string: AppData.websiteLink)!)
  }
}

private struct GuideWindowView: View {
  let webView: WKWebView
  @ObservedObject var model: GuideWindowModel
  let continueAction: () -> Void
  let websiteAction: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      highlightsContent
        .frame(width: 740, height: 540)

      footer
        .frame(width: 740, height: 48)
    }
    .frame(width: 740, height: 588)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var highlightsContent: some View {
    ZStack {
      GuideWebView(webView: webView)
        .opacity(model.loadState == .loaded ? 1 : 0)
        .allowsHitTesting(model.loadState == .loaded)
        .accessibilityHidden(model.loadState != .loaded)

      switch model.loadState {
      case .loading:
        ProgressView()
          .frame(width: 32, height: 32)
      case .loaded:
        EmptyView()
      case .failed:
        failureView
      }
    }
    .frame(width: 740, height: 540)
  }

  private var failureView: some View {
    VStack(spacing: 16) {
      Text(GuideLocalizedString.loadingFailed)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)

      Button(GuideLocalizedString.websiteTitle, action: websiteAction)
        .buttonStyle(.bordered)
    }
    .padding(16)
    .frame(width: 360)
    .background(Color(nsColor: .windowBackgroundColor))
    .overlay(
      RoundedRectangle(cornerRadius: 4)
        .stroke(Color(nsColor: .tertiaryLabelColor))
    )
  }

  private var footer: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor)

      Button(GuideLocalizedString.continueTitle, action: continueAction)
        .buttonStyle(GuideContinueButtonStyle())
        .frame(width: 140, height: 32)
    }
  }
}

private struct GuideContinueButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundColor(.white)
      .frame(width: 140, height: 32)
      .background(
        RoundedRectangle(cornerRadius: 4)
          .fill(Color(nsColor: .systemBlue).opacity(configuration.isPressed ? 0.9 : 1))
          .shadow(color: Color.black.opacity(0.5), radius: 1)
      )
  }
}

private struct GuideWebView: NSViewRepresentable {
  let webView: WKWebView

  func makeNSView(context: Context) -> WKWebView {
    webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}
}

extension GuideWindowController: WKNavigationDelegate {
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if let url = navigationAction.request.url {
      if url.absoluteString.starts(with: "https://iina.io/highlights/") {
        decisionHandler(.allow)
        return
      } else {
        NSWorkspace.shared.open(url)
      }
    }
    decisionHandler(.cancel)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    model.loadState = .failed
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    model.loadState = .failed
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    model.loadState = .loaded
  }
}
