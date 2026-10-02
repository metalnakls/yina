//
//  VideoView.swift
//  yina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa


class VideoView: NSView {

  weak var player: PlayerCore!
#if IINA_ENABLE_METAL_RENDERER
  var link: CADisplayLink?
#else
  var link: CVDisplayLink?
#endif

  lazy var videoLayer: ViewLayer = {
    let layer = ViewLayer(self)
    return layer
  }()

  @ReadWriteAtomic var isUninited = false

  var draggingTimer: Timer?

  // whether auto show playlist is triggered
  var playlistShown: Bool = false

  // variable for tracing mouse position when dragging in the view
  var lastMousePosition: NSPoint?

  var hasPlayableFiles: Bool = false

  // cached indicator to prevent unnecessary updates of DisplayLink
  var currentDisplay: CGDirectDisplayID?
  private var currentDisplaySupportsEDR: Bool?

  var isIdle = true
  private var displayIdleTimer: Timer?

  private lazy var hdrSubsystem = Logger.makeSubsystem("hdr\(player.playerNumber)", ["circle.righthalf.filled"])

  lazy var subsystem = Logger.makeSubsystem("video\(player.playerNumber)", ["film"])

  static let SRGB = CGColorSpaceCreateDeviceRGB()

  // MARK: - Attributes

  override var mouseDownCanMoveWindow: Bool {
    return true
  }

  override var isOpaque: Bool {
    return true
  }

  // MARK: - Init

  init(frame: CGRect, player: PlayerCore) {
    self.player = player
    super.init(frame: frame)

    // set up layer
    layer = videoLayer
#if !IINA_ENABLE_METAL_RENDERER
    videoLayer.colorspace = VideoView.SRGB
#endif
    videoLayer.contentsScale = NSScreen.main!.backingScaleFactor
    wantsLayer = true

    // other settings
    autoresizingMask = [.width, .height]
#if !IINA_ENABLE_METAL_RENDERER
    wantsBestResolutionOpenGLSurface = true
    wantsExtendedDynamicRangeOpenGLSurface = true
#endif

    // dragging init
    registerForDraggedTypes([.nsFilenames, .nsURL, .string])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Uninitialize this view.
  ///
  /// This method will stop drawing and free the mpv render context. This is done before sending a quit command to mpv.
  /// - Important: Once mpv has been instructed to quit accessing the mpv core can result in a crash, therefore locks must be
  ///     used to coordinate uninitializing the view so that other threads do not attempt to use the mpv core while it is shutting down.
  func uninit() {
#if IINA_ENABLE_METAL_RENDERER
    let shouldUninit = $isUninited.withWriteLock() { isUninited -> Bool in
      guard !isUninited else { return false }
      isUninited = true
      return true
    }
    guard shouldUninit else { return }
    link?.invalidate()
    link = nil
    videoLayer.uninitRendering()
#else
    player.mpv.lockAndSetOpenGLContext()
    defer { player.mpv.unlockOpenGLContext() }
    $isUninited.withWriteLock() { isUninited in
      guard !isUninited else { return }
      isUninited = true

      stopDisplayLink()
      player.mpv.mpvUninitRendering()
    }
#endif
  }

  deinit {
    uninit()
  }

  override func draw(_ dirtyRect: NSRect) {
    // do nothing
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return Preference.bool(for: .videoViewAcceptsFirstMouse)
  }

  /// Workaround for issue #4183, Cursor remains visible after resuming playback with the touchpad using secondary click
  ///
  /// See `MainWindowController.workaroundCursorDefect` and the issue for details on this workaround.
  override func rightMouseDown(with event: NSEvent) {
    player.mainWindow.rightMouseDown(with: event)
    super.rightMouseDown(with: event)
  }

  // MARK: Drag and drop

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    hasPlayableFiles = (player.acceptFromPasteboard(sender, isPlaylist: true) == .copy)
    return player.acceptFromPasteboard(sender)
  }

  @objc func showPlaylist() {
    player.mainWindow.menuShowPlaylistPanel(.dummy)
    playlistShown = true
  }

  private func createTimer() {
    draggingTimer = Timer.scheduledTimer(timeInterval: TimeInterval(0.3), target: self,
                                         selector: #selector(showPlaylist), userInfo: nil, repeats: false)
  }

  private func destroyTimer() {
    if let draggingTimer {
      draggingTimer.invalidate()
    }
    draggingTimer = nil
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {

    guard !player.isInMiniPlayer && !playlistShown && hasPlayableFiles else { return super.draggingUpdated(sender) }

    func inTriggerArea(_ point: NSPoint?) -> Bool {
      guard let point, let frame = player.mainWindow.window?.frame else { return false }
      return point.x > (frame.maxX - frame.width * 0.2)
    }

    let position = NSEvent.mouseLocation

    if position != lastMousePosition {
      if inTriggerArea(lastMousePosition) {
        destroyTimer()
      }
      if inTriggerArea(position) {
        createTimer()
      }
      lastMousePosition = position
    }

    return super.draggingUpdated(sender)
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    destroyTimer()
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return player.openFromPasteboard(sender)
  }

  override func draggingEnded(_ sender: NSDraggingInfo) {
    if playlistShown {
      player.mainWindow.sidebars.hideAllSideBars()
    }
    playlistShown = false
    lastMousePosition = nil
  }

  // MARK: Display link

#if IINA_ENABLE_METAL_RENDERER
  func startDisplayLink() {
    if link == nil {
      link = displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
      link?.add(to: .main, forMode: .common)
    }
    guard link?.isPaused != false else { return }
    updateDisplayLink()
    link?.isPaused = false
    log("Display link started", level: .verbose)
  }

  @objc func stopDisplayLink() {
    guard link?.isPaused == false else { return }
    link?.isPaused = true
    log("Display link stopped", level: .verbose)
  }

  func updateDisplayLink() {
    guard let screen = window?.screen, let displayId = screen.displayId else { return }
    let supportsEDR = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
    guard currentDisplay != displayId || currentDisplaySupportsEDR != supportsEDR else { return }
    currentDisplay = displayId
    currentDisplaySupportsEDR = supportsEDR
    player.mpv.setDouble(MPVOption.Video.displayFpsOverride,
                         Double(screen.maximumFramesPerSecond))
    refreshEdrMode()
  }

  @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
    $isUninited.withReadLock() { isUninited in
      guard !isUninited else { return }
      player.mpv.mpvReportSwap()
    }
  }
#else
  /// Returns a [Core Video](https://developer.apple.com/documentation/corevideo) display link.
  ///
  /// If a display link has already been created then that link will be returned, otherwise a display link will be created and returned.
  ///
  /// - Note: Issue [#4520](https://github.com/iina/iina/issues/4520) reports a case where it appears the call to
  ///[CVDisplayLinkCreateWithActiveCGDisplays](https://developer.apple.com/documentation/corevideo/1456863-cvdisplaylinkcreatewithactivecgd) is failing. In case that failure is
  ///encountered again this method is careful to log any failure and include the [result code](https://developer.apple.com/documentation/corevideo/1572713-result_codes) in the alert displayed
  /// by `Logger.fatal`.
  /// - Returns: A [CVDisplayLink](https://developer.apple.com/documentation/corevideo/cvdisplaylink-k0k).
  private func obtainDisplayLink() -> CVDisplayLink {
    if let link { return link }
    let result = CVDisplayLinkCreateWithActiveCGDisplays(&link)
    checkResult(result, "CVDisplayLinkCreateWithActiveCGDisplays")
    guard let link = link else {
      Logger.fatal("Cannot create display link: \(codeToString(result)) (\(result))")
    }
    return link
  }

  func startDisplayLink() {
    let link = obtainDisplayLink()
    guard !CVDisplayLinkIsRunning(link) else { return }
    updateDisplayLink()
    checkResult(CVDisplayLinkSetOutputCallback(link, displayLinkCallback, mutableRawPointerOf(obj: self)),
                "CVDisplayLinkSetOutputCallback")
    checkResult(CVDisplayLinkStart(link), "CVDisplayLinkStart")
    log("Display link started", level: .verbose)
  }

  @objc func stopDisplayLink() {
    guard let link, CVDisplayLinkIsRunning(link) else { return }
    checkResult(CVDisplayLinkStop(link), "CVDisplayLinkStop")
    log("Display link stopped", level: .verbose)
  }

  // Refresh when the window changes displays or the display changes EDR capability.
  func updateDisplayLink() {
    guard let window, let link, let screen = window.screen,
          let displayId = screen.displayId else { return }

    let supportsEDR = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
    guard currentDisplay != displayId || currentDisplaySupportsEDR != supportsEDR else { return }
    currentDisplay = displayId
    currentDisplaySupportsEDR = supportsEDR

    checkResult(CVDisplayLinkSetCurrentCGDisplay(link, displayId), "CVDisplayLinkSetCurrentCGDisplay")
    let actualData = CVDisplayLinkGetActualOutputVideoRefreshPeriod(link)
    let nominalData = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
    var actualFps: Double = 0

    if (nominalData.flags & Int32(CVTimeFlags.isIndefinite.rawValue)) < 1 {
      let nominalFps = Double(nominalData.timeScale) / Double(nominalData.timeValue)

      if actualData > 0 {
        actualFps = 1/actualData
      }

      if abs(actualFps - nominalFps) > 1 {
        log("Falling back to nominal display refresh rate: \(nominalFps) from \(actualFps)")
        actualFps = nominalFps
      }
    } else {
      log("Falling back to standard display refresh rate: 60 from \(actualFps)")
      actualFps = 60
    }
    player.mpv.setDouble(MPVOption.Video.displayFpsOverride, actualFps)

    refreshEdrMode()
  }
#endif

  // MARK: - Reducing Energy Use

  /// Starts the display link if it has been stopped in order to save energy.
  func displayActive() {
    isIdle = false
    displayIdleTimer?.invalidate()
    startDisplayLink()
  }

  /// Reduces energy consumption when the display link does not need to be running.
  ///
  /// Adherence to energy efficiency best practices requires that YINA be absolutely idle when there is no reason to be performing any
  /// processing, such as when playback is paused. The [CVDisplayLink](https://developer.apple.com/documentation/corevideo/cvdisplaylink-k0k)
  /// is a high-priority thread that runs at the refresh rate of a display. If the display is not being updated it is desirable to stop the
  /// display link in order to not waste energy on needless processing.
  ///
  /// However, YINA will pause playback for short intervals when performing certain operations. In such cases it does not make sense to
  /// shutdown the display link only to have to immediately start it again. To avoid this a `Timer` is used to delay shutting down the
  /// display link. If playback becomes active again before the timer has fired then the `Timer` will be invalidated and the display link
  /// will not be shutdown.
  ///
  /// - Note: In addition to playback the display link must be running for operations such seeking, stepping and entering and leaving
  ///         full screen mode.
  func displayIdle() {
    isIdle = true
    displayIdleTimer?.invalidate()
    // Because the display link is critical there is an internal setting that can be changed to
    // disable shutting down the display link should any problems with this energy saving feature
    // be discovered.
    guard Preference.bool(for: .enableDisplayIdle) else { return }
    // The time of 6 seconds was picked to match up with the time QuickTime delays once playback is
    // paused before stopping audio. As mpv does not provide an event indicating a frame step has
    // completed the time used must not be too short or will catch mpv still drawing when stepping.
    displayIdleTimer = Timer(timeInterval: 6.0, target: self, selector: #selector(stopDisplayLink), userInfo: nil, repeats: false)
    RunLoop.current.add(displayIdleTimer!, forMode: .default)
  }

#if IINA_ENABLE_METAL_RENDERER
  /// Return the current ICC profile path for the active display.
  ///
  /// mpv's `icc-profile-auto` render parameter is not reliable with the fork's
  /// Metal/libmpv path. ColorSync remains the authority for selecting the
  /// display profile; this only resolves its existing profile URL so mpv can
  /// consume it through the regular `icc-profile` option.
  private func currentICCProfilePath() -> String? {
    guard let displayId = currentDisplay,
          let displayUUID = CGDisplayCreateUUIDFromDisplayID(displayId)?.takeRetainedValue() else {
      return nil
    }

    typealias ProfileData = (uuid: CFUUID, profileURL: URL?)
    var result: ProfileData = (displayUUID, nil)
    withUnsafeMutablePointer(to: &result) { pointer in
      ColorSyncIterateDeviceProfiles({ dictionary, rawPointer in
        guard let rawPointer,
              let info = dictionary as? [String: Any],
              let isCurrent = info["DeviceProfileIsCurrent"] as? Int,
              isCurrent == 1,
              let deviceID = info["DeviceID"],
              CFEqual(deviceID as CFTypeRef,
                      rawPointer.assumingMemoryBound(to: ProfileData.self).pointee.uuid),
              let profileURL = info["DeviceProfileURL"] as? URL else {
          return true
        }
        rawPointer.assumingMemoryBound(to: ProfileData.self).pointee.profileURL = profileURL
        return false
      }, pointer)
    }

    guard let path = result.profileURL?.path,
          FileManager.default.fileExists(atPath: path) else {
      return nil
    }
    return path
  }
#endif

  private func setICCProfile() {
    let screenColorSpace = player.mainWindow.window?.screen?.colorSpace
    if !Preference.bool(for: .loadIccProfile) {
      logHDR("Not using ICC profile due to user preference")
      player.mpv.setFlag(MPVOption.GPURendererOptions.iccProfileAuto, false)
#if IINA_ENABLE_METAL_RENDERER
      player.mpv.setString(MPVOption.GPURendererOptions.iccProfile, "")
#endif
    } else if let screenColorSpace {
      let name = screenColorSpace.localizedName ?? "unnamed"
      logHDR("Using the ICC profile of the color space \(name)")
#if IINA_ENABLE_METAL_RENDERER
      if let profilePath = currentICCProfilePath() {
        logHDR("Loading ICC profile: \(profilePath)")
        player.mpv.setString(MPVOption.GPURendererOptions.iccProfile, profilePath)
      } else {
        logHDR("Failed to find ICC profile to load", level: .error)
        player.mpv.setString(MPVOption.GPURendererOptions.iccProfile, "")
      }
#else
      // Set MPV_RENDER_PARAM_ICC_PROFILE before enabling icc-profile-auto to true as mpv requires
      // that parameter be set in the render context when icc-profile-auto is in use.
      videoLayer.setRenderICCProfile(screenColorSpace)
      player.mpv.setFlag(MPVOption.GPURendererOptions.iccProfileAuto, true)
#endif
    } else {
      logHDR("Failed to find display color space", level: .error)
      player.mpv.setFlag(MPVOption.GPURendererOptions.iccProfileAuto, false)
#if IINA_ENABLE_METAL_RENDERER
      player.mpv.setString(MPVOption.GPURendererOptions.iccProfile, "")
#endif
    }

#if IINA_ENABLE_METAL_RENDERER
    // libplacebo owns the CAMetalLayer format, color space, and EDR state.
    // YINA continues to own display detection and mpv's output policy.
    // Clear the HDR hint as well as PQ output when falling back to an SDR display.
    player.mpv.setFlag(MPVOption.GPURendererOptions.targetColorspaceHint, false)
    player.mpv.setFlag(MPVOption.GPURendererOptions.inverseToneMapping, false)
    player.mpv.setString(MPVOption.GPURendererOptions.targetTrc, "auto")
    player.mpv.setString(MPVOption.GPURendererOptions.targetPrim, "auto")
    player.mpv.setFlag(MPVOption.Screenshot.screenshotTagColorspace, false)
#else
    let sdrColorSpace = screenColorSpace?.cgColorSpace ?? VideoView.SRGB
    if videoLayer.colorspace != sdrColorSpace {
      let name: String = {
        if let name = sdrColorSpace.name { return name as String }
        if let screenColorSpace, let name = screenColorSpace.localizedName { return name }
        return "Unspecified"
      }()
      log("Setting layer color space to \(name)")
      videoLayer.colorspace = sdrColorSpace
      videoLayer.wantsExtendedDynamicRangeContent = false
      player.mpv.setString(MPVOption.GPURendererOptions.targetTrc, "auto")
      player.mpv.setString(MPVOption.GPURendererOptions.targetPrim, "auto")
      player.mpv.setFlag(MPVOption.Screenshot.screenshotTagColorspace, false)
    }
#endif
  }

  // MARK: - Error Logging

  /// Check the result of calling a [Core Video](https://developer.apple.com/documentation/corevideo) method.
  ///
  /// If the result code is not [kCVReturnSuccess](https://developer.apple.com/documentation/corevideo/kcvreturnsuccess)
  /// then a warning message will be logged. Failures are only logged because previously the result was not checked. We want to see if
  /// calls have been failing before taking any action other than logging.
  /// - Note: Error checking was added in response to issue [#4520](https://github.com/iina/iina/issues/4520)
  ///         where a core video method unexpectedly failed.
  /// - Parameters:
  ///   - result: The [CVReturn](https://developer.apple.com/documentation/corevideo/cvreturn)
  ///           [result code](https://developer.apple.com/documentation/corevideo/1572713-result_codes)
  ///           returned by the core video method.
  ///   - method: The core video method that returned the result code.
  private func checkResult(_ result: CVReturn, _ method: String) {
    guard result != kCVReturnSuccess else { return }
    log("Core video method \(method) returned: \(codeToString(result)) (\(result))", level: .warning)
  }

  /// Return a string describing the given [CVReturn](https://developer.apple.com/documentation/corevideo/cvreturn)
  ///           [result code](https://developer.apple.com/documentation/corevideo/1572713-result_codes).
  ///
  /// What is needed is an API similar to `strerr` for a `CVReturn` code. A search of Apple documentation did not find such a
  /// method.
  /// - Parameter code: The [CVReturn](https://developer.apple.com/documentation/corevideo/cvreturn)
  ///           [result code](https://developer.apple.com/documentation/corevideo/1572713-result_codes)
  ///           returned by a core video method.
  /// - Returns: A description of what the code indicates.
  private func codeToString(_ code: CVReturn) -> String {
    switch code {
    case kCVReturnSuccess:
      return "Function executed successfully without errors"
    case kCVReturnInvalidArgument:
      return "At least one of the arguments passed in is not valid. Either out of range or the wrong type"
    case kCVReturnAllocationFailed:
      return "The allocation for a buffer or buffer pool failed. Most likely because of lack of resources"
    case kCVReturnInvalidDisplay:
      return "A CVDisplayLink cannot be created for the given DisplayRef"
    case kCVReturnDisplayLinkAlreadyRunning:
      return "The CVDisplayLink is already started and running"
    case kCVReturnDisplayLinkNotRunning:
      return "The CVDisplayLink has not been started"
    case kCVReturnDisplayLinkCallbacksNotSet:
      return "The output callback is not set"
    case kCVReturnInvalidPixelFormat:
      return "The requested pixelformat is not supported for the CVBuffer type"
    case kCVReturnInvalidSize:
      return "The requested size (most likely too big) is not supported for the CVBuffer type"
    case kCVReturnInvalidPixelBufferAttributes:
      return "A CVBuffer cannot be created with the given attributes"
    case kCVReturnPixelBufferNotOpenGLCompatible:
      return "The Buffer cannot be used with OpenGL as either its size, pixelformat or attributes are not supported by OpenGL"
    case kCVReturnPixelBufferNotMetalCompatible:
      return "The Buffer cannot be used with Metal as either its size, pixelformat or attributes are not supported by Metal"
    case kCVReturnWouldExceedAllocationThreshold:
      return """
        The allocation request failed because it would have exceeded a specified allocation threshold \
        (see kCVPixelBufferPoolAllocationThresholdKey)
        """
    case kCVReturnPoolAllocationFailed:
      return "The allocation for the buffer pool failed. Most likely because of lack of resources. Check if your parameters are in range"
    case kCVReturnInvalidPoolAttributes:
      return "A CVBufferPool cannot be created with the given attributes"
    case kCVReturnRetry:
      return "a scan hasn't completely traversed the CVBufferPool due to a concurrent operation. The client can retry the scan"
    default:
      return "Unrecognized core video return code"
    }
  }
}

// MARK: - HDR

extension VideoView {
  func refreshEdrMode() {
    guard player.mainWindow.loaded, player.info.state.loaded, let displayId = currentDisplay else { return }
    if let screen = self.window?.screen {
      NSScreen.logEDR("Refreshing HDR for \(player.subsystem.rawValue) on display\(displayId)",
                      screen, subsystem: hdrSubsystem)
    }
    let edrEnabled: Bool?
    if isHDRVideo() {
      edrEnabled = requestEdrMode()
      setToneMappingForHDR()
    } else {
#if IINA_ENABLE_METAL_RENDERER
      edrEnabled = Preference.bool(for: .enableToneMapping) ? requestEdrModeForSDR() : false
#else
      edrEnabled = false
#endif
      setToneMappingForSDR(usingEDR: edrEnabled == true)
    }
    let edrAvailable = edrEnabled != false
    if player.info.hdrAvailable != edrAvailable {
      player.info.hdrAvailable = edrAvailable
      player.postNotification(.yinaHDRChanged)
    }
    if edrEnabled != true { setICCProfile() }
    player.mainWindow.updateOSCExtendedDynamicRange()
  }

  /// Returns `true` if the video being played is a HDR video.
  /// - Returns: `true` if the video is known to be a HDR video, `false` if the video is SDR or the required information is not
  ///     available.
  private func isHDRVideo() -> Bool {
    guard let mpv = player.mpv else { return false }
    guard let primaries = mpv.getString(MPVProperty.videoParamsPrimaries), let gamma = mpv.getString(MPVProperty.videoParamsGamma) else {
      logHDR("Video gamma and primaries not available")
      return false
    }
    let peak = mpv.getDouble(MPVProperty.videoParamsSigPeak)
    logHDR("Video gamma=\(gamma), primaries=\(primaries), sig_peak=\(peak)")

    // HDR videos use a Hybrid Log Gamma (HLG) or a Perceptual Quantization (PQ) transfer function.
    guard gamma == "hlg" || gamma == "pq" else { return false }

    switch primaries {
    case "bt.2020", "display-p3":
      return true

    case "bt.709":
      return false // SDR

    default:
      logHDR("Unsupported color space: gamma=\(gamma) primaries=\(primaries)", level: .warning)
      return false
    }
  }

  func requestEdrMode() -> Bool? {
    guard let mpv = player.mpv else { return false }

    guard (window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0) > 1.0 else {
      logHDR("HDR video was found but the display does not support EDR mode")
      return false
    }

    guard player.info.hdrEnabled else { return nil }

    guard let primaries = mpv.getString(MPVProperty.videoParamsPrimaries) else { return false }
    let name: CFString
    switch primaries {
    case "display-p3":
      name = CGColorSpace.displayP3_PQ

    case "bt.2020":
      name = CGColorSpace.itur_2100_PQ

    default:
      // Since isHDRVideo checked the primaries this should not occur.
      logHDR("Unsupported color space: primaries=\(primaries)", level: .error)
      return false
    }

    logHDR("Using HDR color space instead of ICC profile")

#if !IINA_ENABLE_METAL_RENDERER
    videoLayer.wantsExtendedDynamicRangeContent = true
    videoLayer.colorspace = CGColorSpace(name: name)
#endif
    mpv.setFlag(MPVOption.GPURendererOptions.iccProfileAuto, false)
#if IINA_ENABLE_METAL_RENDERER
    mpv.setFlag(MPVOption.GPURendererOptions.targetColorspaceHint, true)
    mpv.setString(MPVOption.GPURendererOptions.targetColorspaceHintMode, "target")
    mpv.setString(MPVOption.GPURendererOptions.iccProfile, "")
#endif
    mpv.setString(MPVOption.GPURendererOptions.targetPrim, primaries)
    // PQ videos will be display as it was, HLG videos will be converted to PQ
    mpv.setString(MPVOption.GPURendererOptions.targetTrc, "pq")
    mpv.setFlag(MPVOption.Screenshot.screenshotTagColorspace, true)
    return true
  }

#if IINA_ENABLE_METAL_RENDERER
  /// Ask mpv's gpu-next/libplacebo renderer to expand SDR into the display's EDR headroom.
  ///
  /// This keeps the conversion in mpv's per-frame color pipeline. YINA only selects an HDR output
  /// colorspace and reports the display peak; it does not render a second copy or apply its own shader.
  private func requestEdrModeForSDR() -> Bool? {
    guard let mpv = player.mpv else { return false }

    guard (window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0) > 1.0 else {
      logHDR("Tone mapping is enabled but the display does not support EDR mode")
      return false
    }

    guard player.info.hdrEnabled else { return nil }

    logHDR("Using mpv inverse tone mapping for SDR video")
    mpv.setFlag(MPVOption.GPURendererOptions.iccProfileAuto, false)
    mpv.setString(MPVOption.GPURendererOptions.iccProfile, "")
    mpv.setFlag(MPVOption.GPURendererOptions.targetColorspaceHint, true)
    mpv.setString(MPVOption.GPURendererOptions.targetColorspaceHintMode, "target")
    mpv.setString(MPVOption.GPURendererOptions.targetPrim, "display-p3")
    mpv.setString(MPVOption.GPURendererOptions.targetTrc, "pq")
    mpv.setFlag(MPVOption.Screenshot.screenshotTagColorspace, true)
    return true
  }
#endif

  /// Set the mpv tone mapping options appropriately for a HDR video.
  ///
  /// If tone mapping is enabled then this method will set the following mpv options based on YINA's tone mapping settings:
  /// - [target-peak](https://mpv.io/manual/stable/#options-target-peak)
  /// - [tone-mapping](https://mpv.io/manual/stable/#options-tone-mapping)
  ///
  /// Otherwise these options will be set to their default values.
  private func setToneMappingForHDR() {
    guard let mpv = player.mpv else { return }
    mpv.setFlag(MPVOption.GPURendererOptions.inverseToneMapping, false)
    guard Preference.bool(for: .enableToneMapping) else {
      // Reset options to their defaults.
      mpv.setStringToDefault(MPVOption.GPURendererOptions.targetPeak)
      mpv.setStringToDefault(MPVOption.GPURendererOptions.toneMapping)
      return
    }
    let targetPeak = toneMappingTargetPeak()
    let algorithm = String(describing: Preference.enum(for: .toneMappingAlgorithm) as
                           Preference.ToneMappingAlgorithmOption)
    logHDR("Will enable tone mapping: target-peak=\(targetPeak) algorithm=\(algorithm)")
    mpv.setString(MPVOption.GPURendererOptions.targetPeak, targetPeak)
    mpv.setString(MPVOption.GPURendererOptions.toneMapping, algorithm)
  }

  /// Return the output peak requested by the user, or YINA's best measurement of the display peak.
  private func toneMappingTargetPeak() -> String {
    if Preference.bool(for: .enableToneMappingTargetPeakOverride) {
      return String(Preference.integer(for: .toneMappingTargetPeakOverride))
    }

    // mpv cannot query display brightness on macOS, so supply it when CoreDisplay exposes it.
    var displayInfo: [String: AnyObject]?
    if let currentDisplay {
      displayInfo = CoreDisplay_DisplayCreateInfoDictionary(currentDisplay)?.takeRetainedValue()
        as? [String: AnyObject]
    }
    if let displayInfo {
      logHDR("Successfully obtained information about the display")
      if let hdrLuminance = displayInfo["NonReferencePeakHDRLuminance"] as? Int {
        logHDR("Found NonReferencePeakHDRLuminance: \(hdrLuminance)")
        return String(hdrLuminance)
      }
      if let hdrLuminance = displayInfo["DisplayBacklight"] as? Int {
        logHDR("Found DisplayBacklight: \(hdrLuminance)")
        return String(hdrLuminance)
      }
      logHDR("Display info dictionary:" + displayInfo.toStringForLog(), level: .verbose)
    } else {
      logHDR("Unable to obtain CoreDisplay information", level: .warning)
    }

    if let screen = window?.screen {
      let currentHeadroom = screen.maximumExtendedDynamicRangeColorComponentValue
      if currentHeadroom > 1 {
        let inferredPeak = Int((currentHeadroom * 203).rounded())
        logHDR("Using current EDR headroom to infer display peak: \(inferredPeak)")
        return String(inferredPeak)
      }
    }

    logHDR("Didn't find display luminance or usable EDR headroom, using mpv auto mode")
    return "auto"
  }

  /// Ask mpv to inverse-tone-map SDR into EDR when the display and renderer support it.
  private func setToneMappingForSDR(usingEDR: Bool) {
    guard let mpv = player.mpv else { return }
    guard Preference.bool(for: .enableToneMapping), usingEDR else {
      // Reset options to their defaults.
      mpv.setFlag(MPVOption.GPURendererOptions.inverseToneMapping, false)
      mpv.setStringToDefault(MPVOption.GPURendererOptions.targetPeak)
      mpv.setStringToDefault(MPVOption.GPURendererOptions.toneMapping)
      return
    }
    let targetPeak = toneMappingTargetPeak()
    let algorithm = String(describing: Preference.enum(for: .toneMappingAlgorithm) as
                           Preference.ToneMappingAlgorithmOption)
    logHDR("Will expand SDR into EDR: target-peak=\(targetPeak) algorithm=\(algorithm)")
    mpv.setFlag(MPVOption.GPURendererOptions.inverseToneMapping, true)
    mpv.setString(MPVOption.GPURendererOptions.targetPeak, targetPeak)
    mpv.setString(MPVOption.GPURendererOptions.toneMapping, algorithm)
  }

  // MARK: - Utils

  func logHDR(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: hdrSubsystem)
  }

  func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: subsystem)
  }
}

#if !IINA_ENABLE_METAL_RENDERER
fileprivate func displayLinkCallback(
  _ displayLink: CVDisplayLink, _ inNow: UnsafePointer<CVTimeStamp>,
  _ inOutputTime: UnsafePointer<CVTimeStamp>,
  _ flagsIn: CVOptionFlags,
  _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
  _ context: UnsafeMutableRawPointer?) -> CVReturn {
  let videoView = unsafeBitCast(context, to: VideoView.self)
  videoView.$isUninited.withReadLock() { isUninited in
    guard !isUninited else { return }
    videoView.player.mpv.mpvReportSwap()
  }
  return kCVReturnSuccess
}
#endif
