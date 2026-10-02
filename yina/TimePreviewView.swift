//
//  TimePreviewView.swift
//  yina
//
//  Created by Yuze Jiang on 2026/05/28.
//  Copyright © 2026 lhc. All rights reserved.
//

class TimePreviewView: TranslucentView {
  weak var mainWindow: MainWindowController!

  var textField: NSTextField!
  private var displayedChapterTitle: String?
  private var hasDisplayedContent = false
  private var chapterTransitionEndsAt: TimeInterval = 0

  init(mainWindow: MainWindowController) {
    self.mainWindow = mainWindow

    self.textField = NSTextField(labelWithString: "")
    textField.translatesAutoresizingMaskIntoConstraints = false
    textField.usesSingleLineMode = false
    textField.alignment = .center

    super.init(liquidGlassCornerRadius: 16, vevCornerRadius: 8, padding: (4, 4))

    let container = NSView()
    container.addSubview(textField)
    textField.padding(.all)
    setContent(container)
  }

  @MainActor required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Updates the preview and reports whether its glass capsule should morph to a new chapter.
  func update(chapterTitle: String?, time: String) -> Bool {
    let chapterChanged = hasDisplayedContent && displayedChapterTitle != chapterTitle
    displayedChapterTitle = chapterTitle
    hasDisplayedContent = true
    textField.stringValue = (chapterTitle.map { $0 + "\n" } ?? "") + time
    return chapterChanged
  }

  /// Moves and resizes the native glass surface with a short morph when chapter content changes.
  func setPreviewFrame(_ targetFrame: NSRect, chapterChanged: Bool) {
    let now = ProcessInfo.processInfo.systemUptime
    let animationsDisabled = Preference.bool(for: .disableAnimations) ||
      AccessibilityPreferences.motionReductionEnabled
    if chapterChanged && !animationsDisabled {
      chapterTransitionEndsAt = now + 0.12
    }

    let remaining = chapterTransitionEndsAt - now
    guard remaining > 0, !animationsDisabled else {
      frame = targetFrame
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = min(0.12, remaining)
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      animator().frame = targetFrame
    }
  }
}
