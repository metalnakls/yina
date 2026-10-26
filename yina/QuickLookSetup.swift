//
//  QuickLookSetup.swift
//  yina
//

import AVFoundation
import Cocoa
import MediaToolbox
import VideoToolbox

enum QuickLookAvailability: Equatable, Sendable {
  case enabled
  case disabled
  case unavailable

  /// Exercise both the format reader and decoder with a bundled, synthetic VP8 WebM.
  /// Registration alone does not tell us whether macOS allows the extensions to run.
  static func check(probeURL: URL) async -> QuickLookAvailability {
    MTRegisterProfessionalVideoWorkflowFormatReaders()
    VTRegisterProfessionalVideoWorkflowVideoDecoders()
    let asset = AVURLAsset(url: probeURL)
    do {
      _ = try await asset.load(.duration)
      let generator = AVAssetImageGenerator(asset: asset)
      _ = try await generator.image(at: .zero)
      return .enabled
    } catch {
      if isDisabledError(error as NSError) { return .disabled }
      Logger.log("Quick Look availability check failed: \(error)", level: .warning)
      return .unavailable
    }
  }

  static func isDisabledError(_ error: NSError, depth: Int = 0) -> Bool {
    guard depth < 8 else { return false }
    if error.domain == AVFoundationErrorDomain && error.code == AVError.mediaExtensionDisabled.rawValue {
      return true
    }
    if error.domain == NSOSStatusErrorDomain && error.code == Int(kVTExtensionDisabledErr) {
      return true
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
       isDisabledError(underlying, depth: depth + 1) {
      return true
    }
    if let underlying = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
      return underlying.contains { isDisabledError($0, depth: depth + 1) }
    }
    return false
  }
}

@MainActor
final class QuickLookSetup {
  static let shared = QuickLookSetup()

  // The same System Settings entry point used by QuickLookVideo, focused on Media Extensions.
  static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.mediaextension.formatreader")!

  private var checkTask: Task<Void, Never>?
  private var pendingPrompt = false
  private var observers: [NSObjectProtocol] = []

  func checkAtLaunch() {
    guard checkTask == nil else { return }
    guard let probeURL = Bundle.main.url(forResource: "quicklook-probe", withExtension: "webm") else {
      Logger.log("Quick Look setup probe is missing", level: .error)
      return
    }
    // Do not place an alert over an open-file panel or another startup sheet.
    for name in [NSApplication.didBecomeActiveNotification, NSWindow.didEndSheetNotification,
                 NSWindow.willCloseNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.presentIfNeeded() }
      })
    }
    checkTask = Task { [weak self] in
      let availability = await Task.detached(priority: .utility) {
        await QuickLookAvailability.check(probeURL: probeURL)
      }.value
      guard !Task.isCancelled, let self else { return }
      pendingPrompt = availability == .disabled
      if !pendingPrompt { stopObserving() }
      presentIfNeeded()
    }
  }

  private func stopObserving() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
  }

  func cancel() {
    pendingPrompt = false
    checkTask?.cancel()
    stopObserving()
  }

  private func presentIfNeeded() {
    guard pendingPrompt, NSApp.isRunning, NSApp.isActive,
          NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil else { return }
    pendingPrompt = false
    stopObserving()
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = NSLocalizedString("quicklook.setup.title", comment: "Quick Look setup title")
    alert.informativeText = NSLocalizedString("quicklook.setup.message", comment: "Quick Look setup explanation")
    alert.addButton(withTitle: NSLocalizedString("quicklook.setup.open_settings", comment: "Open System Settings"))
    alert.addButton(withTitle: NSLocalizedString("quicklook.setup.not_now", comment: "Defer Quick Look setup"))
    if alert.runModal() == .alertFirstButtonReturn {
      if !NSWorkspace.shared.open(Self.settingsURL) {
        Logger.log("Unable to open Media Extensions in System Settings", level: .error)
      }
    }
  }
}
