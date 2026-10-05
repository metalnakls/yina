import Cocoa

/// Shared blur-only timing. Opacity remains monotonic even when blur overshoots.
enum DissolveEasing: Int, CaseIterable {
  case linear, easeIn, easeOut, easeInOut

  var titleKey: String {
    switch self {
    case .linear: return "sidebar.ease_linear"
    case .easeIn: return "sidebar.ease_in"
    case .easeOut: return "sidebar.ease_out"
    case .easeInOut: return "sidebar.ease_in_out"
    }
  }

  func value(at progress: Double, overshoot: Double = 0) -> Double {
    let t = min(max(progress, 0), 1)
    func ease(_ x: Double) -> Double {
      switch self {
      case .linear: return x
      case .easeIn: return x * x * x
      case .easeOut: return 1 - pow(1 - x, 3)
      case .easeInOut: return x * x * (3 - 2 * x)
      }
    }
    let amount = overshoot.isFinite ? min(max(overshoot, 0), 1) : 0
    guard amount > 0 else { return ease(t) }
    // Reach beyond the destination, then smoothly settle exactly at it.
    let split = 0.72
    if t <= split {
      let approach = ease(t / split)
      return (1 + amount) * approach * approach * (3 - 2 * approach)
    }
    let settle = (t - split) / (1 - split)
    return 1 + amount * (1 - settle * settle * (3 - 2 * settle))
  }
}

/// A short, main-run-loop-only animation of mpv's existing text-subtitle style.
/// Never writes preferences or replaces a track's ASS style overrides.
final class SubtitleDissolve: NSObject {
  static let styleOptions = [MPVOption.Subtitles.subBlur, MPVOption.Subtitles.subColor,
                             MPVOption.Subtitles.subOutlineColor, MPVOption.Subtitles.subBackColor]

  private struct Style {
    let blur: Double
    let colors: [(name: String, original: String, color: NSColor)]
  }

  private unowned let mpv: MPVController
  private var style: Style?
  private var timer: Timer?
  private var startTime: CFTimeInterval = 0
  private var duration: TimeInterval = 0
  private var startOpacity: Double = 1
  private var extraBlur: Double = 4
  private var startBlur: Double = 0
  private var targetBlur: Double = 0
  private var blurEasing = DissolveEasing.easeInOut
  private var blurOvershoot: Double = 0
  private(set) var targetVisibility: Bool?

  init(mpv: MPVController) { self.mpv = mpv }

  private func opacity(at time: CFTimeInterval) -> Double {
    let progress = min(max((time - startTime) / max(duration, 0.001), 0), 1)
    let eased = progress * progress * (3 - 2 * progress)
    let target = targetVisibility == true ? 1.0 : 0.0
    return startOpacity + (target - startOpacity) * eased
  }

  private func blur(at time: CFTimeInterval) -> Double {
    let progress = (time - startTime) / max(duration, 0.001)
    let eased = blurEasing.value(at: progress, overshoot: blurOvershoot)
    return min(max(startBlur + (targetBlur - startBlur) * eased, 0), 20)
  }

  @discardableResult
  func animate(to visible: Bool) -> Bool {
    assert(Thread.isMainThread)
    if targetVisibility == visible { return true }
    let now = CACurrentMediaTime()
    let interruptedBlur = style == nil ? nil : blur(at: now)
    let from = style == nil ? (mpv.getFlag(MPVOption.Subtitles.subVisibility) ? 1.0 : 0.0)
                            : opacity(at: now)
    if style == nil {
      var colors: [(String, String, NSColor)] = []
      for name in Self.styleOptions.dropFirst() {
        guard let original = mpv.getString(name), let color = NSColor(mpvColorString: original) else {
          return false
        }
        colors.append((name, original, color))
      }
      style = Style(blur: mpv.getDouble(MPVOption.Subtitles.subBlur), colors: colors)
      // Force the cached sRGB components to be rebuilt for the newly captured style.
      resolvedSRGBComponents = []
    }
    timer?.invalidate()
    startTime = now
    startOpacity = from
    let configuredDuration = Double(Preference.float(for: visible ? .subDissolveAppearDuration
                                                                 : .subDissolveDisappearDuration))
    duration = configuredDuration.isFinite ? min(max(configuredDuration, 0), 60) : (visible ? 0.12 : 0.16)
    let configuredBlur = Double(Preference.float(for: .subDissolveBlurRadius))
    extraBlur = configuredBlur.isFinite ? min(max(configuredBlur, 0), 20) : 4
    blurEasing = DissolveEasing(rawValue: Preference.integer(for: .subDissolveEasing)) ?? .easeInOut
    blurOvershoot = Double(Preference.float(for: .subDissolveOvershoot))
    let baseline = style!.blur
    startBlur = interruptedBlur ?? min(20, baseline + extraBlur * (1 - from))
    targetBlur = visible ? baseline : min(20, baseline + extraBlur)
    targetVisibility = visible
    if duration == 0 {
      finish()
      return true
    }

    // Prepare the invisible style before revealing; keep mpv visible until fade-out completes.
    apply(opacity: from, blur: startBlur)
    mpv.setFlag(MPVOption.Subtitles.subVisibility, true, level: .verbose)
    let timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(tick),
                      userInfo: nil, repeats: true)
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
    return true
  }

  @objc private func tick() {
    let now = CACurrentMediaTime()
    if now - startTime >= duration {
      finish()
    } else {
      apply(opacity: opacity(at: now), blur: blur(at: now))
    }
  }

  /// sRGB components of each style colour, resolved once per dissolve.
  ///
  /// `mpvColorString` normalises the colour to sRGB and interpolates four components into a string.
  /// The dissolve timer runs at 60 fps, so resolving the components on every frame repeated that
  /// work for colours that do not change during the animation. Only the alpha varies per frame.
  private var resolvedSRGBComponents: [(name: String, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)] = []

  private func resolveColors(of style: Style) {
    resolvedSRGBComponents = style.colors.map { name, _, color in
      let rgb = color.usingColorSpace(.sRGB) ?? color
      var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
      rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
      return (name, red, green, blue, alpha)
    }
  }

  private func apply(opacity: Double, blur: Double) {
    guard let style else { return }
    if resolvedSRGBComponents.isEmpty { resolveColors(of: style) }
    mpv.setDouble(MPVOption.Subtitles.subBlur, blur, level: .verbose)
    for component in resolvedSRGBComponents {
      let fadedAlpha = component.alpha * opacity
      let value = "\(component.red)/\(component.green)/\(component.blue)/\(fadedAlpha)"
      mpv.setString(component.name, value, level: .verbose)
    }
  }

  /// Complete before saving state, changing tracks/styles, seeking, or shutting down mpv.
  func finish() {
    assert(Thread.isMainThread)
    timer?.invalidate()
    timer = nil
    guard let style, let visible = targetVisibility else { return }
    // Hide first so restoring the normal style cannot flash the subtitle on fade-out.
    mpv.setFlag(MPVOption.Subtitles.subVisibility, visible, level: .verbose)
    mpv.setDouble(MPVOption.Subtitles.subBlur, style.blur, level: .verbose)
    for (name, original, _) in style.colors {
      mpv.setString(name, original, level: .verbose)
    }
    self.style = nil
    targetVisibility = nil
  }

  /// mpv-initiated shutdown: cancel without touching an already terminated core.
  func abandon() {
    timer?.invalidate()
    timer = nil
    style = nil
    targetVisibility = nil
  }
}
