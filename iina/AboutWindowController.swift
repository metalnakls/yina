//
//  AboutWindowController.swift
//  iina
//
//  Created by lhc on 31/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa
import Just
import SwiftUI

struct Contributor: Decodable, Identifiable {
  let avatarURL: String

  var id: String { avatarURL }

  enum CodingKeys: String, CodingKey {
    case avatarURL = "avatar_url"
  }
}

private enum AboutLocalizedString {
  static let title = value("F0z-JX-Cv5.title", fallback: "About")
  static let license = value("jEf-xN-6xb.title", fallback: "License")
  static let contributors = value("XWg-VQ-fRV.title", fallback: "Contributors")
  static let credits = value("zCH-uO-acx.title", fallback: "Credits")
  static let translators = value("JlJ-V6-PVY.title", fallback: "Translators:")
  static let localizationCredit = value("HLj-vT-kNp.title", fallback: "IINA localization is powered by Crowdin.")

  private static func value(_ key: String, fallback: String) -> String {
    NSLocalizedString(key, tableName: "AboutWindowController", bundle: .main, value: fallback, comment: "")
  }
}

private struct AboutBuildInfo {
  let version: String
  let mpvVersion: String
  let ffmpegVersion: String
  let branch: String?
  let date: String?
  let commitURL: URL?

  init() {
    let (version, build) = InfoDictionary.shared.version
    self.version = "\(version) Build \(build)"
    mpvVersion = MPVOptionDefaults.shared.mpvVersion
    ffmpegVersion = "FFmpeg \(String(cString: av_version_info()))"

    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium

    switch InfoDictionary.shared.buildType {
    case .nightly:
      if let buildDate = InfoDictionary.shared.buildDate,
         let buildSHA = InfoDictionary.shared.shortCommitSHA {
        branch = "NIGHTLY \(buildSHA)"
        date = formatter.string(from: buildDate)
      } else {
        branch = nil
        date = nil
      }
    case .debug:
      if let buildDate = InfoDictionary.shared.buildDate,
         let buildBranch = InfoDictionary.shared.buildBranch,
         let buildSHA = InfoDictionary.shared.shortCommitSHA {
        branch = "\(buildBranch) \(buildSHA)"
        date = formatter.string(from: buildDate)
      } else {
        branch = nil
        date = nil
      }
    default:
      branch = nil
      date = nil
    }

    commitURL = InfoDictionary.shared.buildCommit.flatMap {
      URL(string: "https://github.com/iina/iina/commit/\($0)")
    }
  }
}

private final class ContributorsModel: ObservableObject {
  @Published private(set) var contributors: [Contributor] = []

  init() {
    loadContributors(from: "https://api.github.com/repos/iina/iina/contributors")
  }

  private func loadContributors(from url: String) {
    Just.get(url, asyncCompletionHandler: { [weak self] response in
      guard let self,
            let data = response.content,
            let contributors = try? JSONDecoder().decode([Contributor].self, from: data) else {
        return
      }

      DispatchQueue.main.async {
        self.contributors.append(contentsOf: contributors)
        if let nextURL = response.links["next"]?["url"] {
          self.loadContributors(from: nextURL)
        }
      }
    })
  }
}

class AboutWindowController: NSWindowController {

  override init(window: NSWindow?) {
    super.init(window: window)
  }

  convenience init() {
    let window = CommonWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = AboutLocalizedString.title
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.minSize = NSSize(width: 640, height: 400)

    self.init(window: window)
    window.contentViewController = NSHostingController(rootView: AboutWindowView(
      buildInfo: AboutBuildInfo(),
      openURL: { [weak self] url in self?.open(url) }
    ))
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func open(_ url: URL) {
    NSWorkspace.shared.open(url)
  }
}

private struct AboutWindowView: View {
  private enum Section: Hashable {
    case license
    case contributors
    case credits
  }

  let buildInfo: AboutBuildInfo
  let openURL: (URL) -> Void

  @StateObject private var contributors = ContributorsModel()
  @State private var section: Section = .license

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: 220)

      content
        .padding(.top, 36)
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }
    .frame(minWidth: 640, minHeight: 400)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .scaledToFit()
        .frame(width: 80, height: 80)
        .padding(.top, 40)

      Text("IINA")
        .font(.system(size: 24, weight: .light))
        .padding(.top, 8)

      Text(buildInfo.version)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.top, 8)

      HStack(spacing: 6) {
        Text(buildInfo.mpvVersion)
          .multilineTextAlignment(.trailing)
        Text(buildInfo.ffmpegVersion)
          .multilineTextAlignment(.leading)
      }
      .font(.system(size: 9))
      .foregroundStyle(.secondary)
      .padding(.top, 4)

      if let branch = buildInfo.branch, let date = buildInfo.date, let commitURL = buildInfo.commitURL {
        VStack(spacing: 2) {
          Button(branch) { openURL(commitURL) }
            .buttonStyle(.link)
            .font(.system(size: 9))
          Text(date)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
      }

      Spacer(minLength: 8)

      sectionButton(AboutLocalizedString.license, for: .license)
      sectionButton(AboutLocalizedString.contributors, for: .contributors)
        .padding(.top, 10)
      sectionButton(AboutLocalizedString.credits, for: .credits)
        .padding(.top, 10)
        .padding(.bottom, 50)
    }
    .padding(.horizontal, 40)
  }

  @ViewBuilder
  private var content: some View {
    switch section {
    case .license:
      AboutRichTextView(resource: "Contribution")
    case .contributors:
      contributorsView
    case .credits:
      AboutRichTextView(resource: "Credits")
    }
  }

  private var contributorsView: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 32, maximum: 32), spacing: 4)], spacing: 4) {
          ForEach(contributors.contributors) { contributor in
            AboutWindowContributorAvatarItem(avatarURL: contributor.avatarURL)
              .frame(width: 32, height: 32)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 12)
      }

      VStack(spacing: 8) {
        Button("iina/contributors") {
          openURL(URL(string: AppData.contributorsLink)!)
        }
        .buttonStyle(.link)
        .font(.system(size: NSFont.smallSystemFontSize, weight: .semibold))

        Text(AboutLocalizedString.localizationCredit)
          .frame(maxWidth: .infinity, alignment: .leading)

        Text(AboutLocalizedString.translators)
          .frame(maxWidth: .infinity, alignment: .leading)

        Button("Crowdin") {
          openURL(URL(string: AppData.crowdinMembersLink)!)
        }
        .buttonStyle(.link)
        .font(.system(size: NSFont.smallSystemFontSize, weight: .semibold))
      }
      .font(.system(size: NSFont.systemFontSize))
      .padding(.top, 8)
      .padding(.bottom, 2)
      .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
    }
  }

  private func sectionButton(_ title: String, for section: Section) -> some View {
    Button(title) { self.section = section }
      .buttonStyle(AboutSectionButtonStyle(isSelected: self.section == section))
      .frame(maxWidth: .infinity, minHeight: 24)
  }
}

private struct AboutSectionButtonStyle: ButtonStyle {
  let isSelected: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(maxWidth: .infinity, minHeight: 24)
      .foregroundStyle(isSelected ? Color.white : Color(nsColor: .labelColor))
      .background(isSelected ? Color.accentColor : Color.clear)
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

private struct AboutRichTextView: NSViewRepresentable {
  let resource: String

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true

    let textView = NSTextView()
    textView.isEditable = false
    textView.drawsBackground = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainerInset = NSSize(width: 0, height: 0)
    if let path = Bundle.main.path(forResource: resource, ofType: "rtf") {
      textView.readRTFD(fromFile: path)
    }
    textView.textColor = .secondaryLabelColor
    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
