//
//  Data.swift
//  yina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

struct AppData {

  /** time interval to sync play pos */
  static let syncTimeInterval: Double = 0.1
  static let syncTimePreciseInterval: Double = 0.04

  /** speed values when clicking left / right arrow button */

//  static let availableSpeedValues: [Double] = [-32, -16, -8, -4, -2, -1, 1, 2, 4, 8, 16, 32]
  // Stopgap for https://github.com/mpv-player/mpv/issues/4000
  static let availableSpeedValues: [Double] = [0.03125, 0.0625, 0.125, 0.25, 0.5, 1, 2, 4, 8, 16, 32]

  // Min/max speed for playback speed slider in Quick Settings
  static let minSpeed = 0.25
  static let maxSpeed = 16.0

  /// Lowest possible speed allowed by mpv (0.01x)
  static let mpvMinPlaybackSpeed = 0.01

  /** generate aspect and crop options in menu */
  static let aspects: [String] = ["4:3", "5:4", "16:9", "16:10", "1:1", "3:2", "2.21:1", "2.35:1", "2.39:1"]

  static let aspectsInPanel: [String] = ["Default", "4:3", "16:9", "16:10", "21:9", "5:4"]
  static let cropsInPanel: [String] = ["None", "4:3", "16:9", "16:10", "21:9", "5:4"]

  static let rotations: [Int] = [0, 90, 180, 270]

  /** Seek amount */
  static let seekAmountMap = [0, 0.05, 0.1, 0.25, 0.5]
  static let seekAmountMapMouse = [0, 0.5, 1, 2, 4]
  static let volumeMap = [0, 0.25, 0.5, 0.75, 1]
  static let playbackSpeedMap = [0, 0.001, 0.002, 0.005, 0.01]

  static let encodings = CharEncoding.list

  static let userInputConfFolder = "input_conf"
  static let watchLaterFolder = "watch_later"
  static let pluginsFolder = "plugins"
  static let binariesFolder = "bin"
  static let historyFile = "history.plist"
  static let thumbnailCacheFolder = "thumb_cache"
  static let screenshotCacheFolder = "screenshot_cache"
  static let networkMediaCacheFolder = "network_media_cache"

  static let githubLink = "https://github.com/iina/iina"
  static let contributorsLink = "https://github.com/iina/iina/graphs/contributors"
  static let crowdinMembersLink = "https://crowdin.com/project/iina"
  static let wikiLink = "https://github.com/iina/iina/wiki"
  static let websiteLink = "https://iina.io"
  static let ytdlHelpLink = "https://github.com/rg3/youtube-dl/blob/master/README.md#readme"
  static let appcastLink = "https://metalnakls.github.io/yina/appcast.xml"
  static let appcastBetaLink = "https://metalnakls.github.io/yina/appcast-beta.xml"
  static let assrtRegisterLink = "https://secure.assrt.net/user/register.xml?redir=http%3A%2F%2Fassrt.net%2Fusercp.php"
  static let chromeExtensionLink = "https://chrome.google.com/webstore/detail/open-in-iina/pdnojahnhpgmdhjdhgphgdcecehkbhfo"
  static let firefoxExtensionLink = "https://addons.mozilla.org/addon/open-in-iina-x"
  static let toneMappingHelpLink = "https://en.wikipedia.org/wiki/Tone_mapping"
  static let disableAnimationsHelpLink = "https://developer.apple.com/design/human-interface-guidelines/accessibility#Cognitive"
  static let mpvManualLink = "https://mpv.io/manual/stable"

  static let widthWhenNoVideo = 640
  static let heightWhenNoVideo = 360
  static let sizeWhenNoVideo = NSSize(width: widthWhenNoVideo, height: heightWhenNoVideo)
  static let mainWindowMinSize = NSMakeSize(285, 120)
}


struct Constants {
  struct String {
    static let degree = "°"
    static let dot = "●"
    static let blackRightPointingTriangle = "▶︎"
    static let blackLeftPointingTriangle = "◀"
    static let mpvDefaultFont = "sans-serif"
    static let videoTimePlaceholder = "--:--:--"
    static let trackNone = NSLocalizedString("track.none", comment: "<None>")
    static let chapter = "Chapter"
    static let fullScreen = NSLocalizedString("menu.fullscreen", comment: "Fullscreen")
    static let exitFullScreen = NSLocalizedString("menu.exit_fullscreen", comment: "Exit Fullscreen")
    static let pause = NSLocalizedString("menu.pause", comment: "Pause")
    static let resume = NSLocalizedString("menu.resume", comment: "Resume")
    static let `default` = NSLocalizedString("quicksetting.item_default", comment: "Default")
    static let none = NSLocalizedString("quicksetting.item_none", comment: "None")
    static let pip = NSLocalizedString("menu.pip", comment: "Enter Picture-in-Picture")
    static let exitPIP = NSLocalizedString("menu.exit_pip", comment: "Exit Picture-in-Picture")
    static let miniPlayer = NSLocalizedString("menu.mini_player", comment: "Enter Music Mode")
    static let exitMiniPlayer = NSLocalizedString("menu.exit_mini_player", comment: "Exit Music Mode")
    static let custom = NSLocalizedString("menu.crop_custom", comment: "Custom crop size")
    static let findOnlineSubtitles = NSLocalizedString("menu.find_online_sub", comment: "Find Online Subtitles")
    static let chaptersPanel = NSLocalizedString("menu.chapters", comment: "Show Chapters Panel")
    static let hideChaptersPanel = NSLocalizedString("menu.hide_chapters", comment: "Hide Chapters Panel")
    static let playlistPanel = NSLocalizedString("menu.playlist", comment: "Show Playlist Panel")
    static let hidePlaylistPanel = NSLocalizedString("menu.hide_playlist", comment: "Hide Playlist Panel")
    static let videoPanel = NSLocalizedString("menu.video", comment: "Show Video Panel")
    static let hideVideoPanel = NSLocalizedString("menu.hide_video", comment: "Hide Video Panel")
    static let audioPanel = NSLocalizedString("menu.audio", comment: "Show Audio Panel")
    static let hideAudioPanel = NSLocalizedString("menu.hide_audio", comment: "Hide Audio Panel")
    static let subtitlesPanel = NSLocalizedString("menu.subtitles", comment: "Show Subtitles Panel")
    static let hideSubtitlesPanel = NSLocalizedString("menu.hide_subtitles", comment: "Hide Subtitles Panel")
    static let hideSubtitles = NSLocalizedString("menu.sub_hide", comment: "Hide Subtitles")
    static let showSubtitles = NSLocalizedString("menu.sub_show", comment: "Show Subtitles")
    static let hideSecondSubtitles = NSLocalizedString("menu.sub_second_hide", comment: "Hide Second Subtitles")
    static let showSecondSubtitles = NSLocalizedString("menu.sub_second_show", comment: "Show Second Subtitles")
    static let managePlugins = NSLocalizedString("menu.manage_plugins", comment: "Manage Plugins…")
    static let showPluginsPanel = NSLocalizedString("menu.show_plugins_panel", comment: "Show Plugins Panel")
    static let hidePluginsPanel = NSLocalizedString("menu.hide_plugins_panel", comment: "Hide Plugins Panel")
  }
  struct Time {
    static let infinite = VideoTime(999, 0, 0)
  }
  struct WindowAutosaveName {
    static let videoFilters = "VideoFilters"
    static let audioFilters = "AudioFilters"
  }
  struct FilterName {
    static let crop = "iina_crop"
    static let flip = "iina_flip"
    static let mirror = "iina_mirror"
    static let audioEq = "iina_aeq"
    static let delogo = "iina_delogo"
  }
}

extension Notification.Name {
  static let yinaMainWindowChanged = Notification.Name("YINAMainWindowChanged")
  static let yinaMusicModeChanged = Notification.Name("YINAMusicModeChanged")
  static let yinaPlaylistChanged = Notification.Name("YINAPlaylistChanged")
  static let yinaChapterListChanged = Notification.Name("YINAChapterListChanged")
  static let yinaTracklistChanged = Notification.Name("YINATracklistChanged")
  static let yinaLoopStatusChanged = Notification.Name("yinaLoopStatusChanged")

  static let yinaVIDChanged = Notification.Name("yinaVIDChanged")
  static let yinaAIDChanged = Notification.Name("yinaAIDChanged")
  static let yinaSIDChanged = Notification.Name("yinaSIDChanged")
  static let yinaSpeedChanged = Notification.Name("YINASpeedChanged")
  static let yinaMediaTitleChanged = Notification.Name("YINAMediaTitleChanged")
  static let yinaVideoParamsChanged = Notification.Name("yinaVideoParamsChanged")
  static let yinaVFChanged = Notification.Name("YINAVfChanged")
  static let yinaVideoEqualizerChanged = Notification.Name("yinaVideoEqualizerChanged")
  static let yinaDeinterlaceChanged = Notification.Name("yinaDeinterlaceChanged")
  static let yinaHwdecChanged = Notification.Name("yinaHwdecChanged")
  static let yinaHDRChanged = Notification.Name("yinaHDRChanged")
  static let yinaAFChanged = Notification.Name("YINAAfChanged")
  static let yinaAudioDelayChanged = Notification.Name("yinaAudioDelayChanged")
  static let yinaSubScaleChanged = Notification.Name("yinaSubScaleChanged")
  static let yinaSubPositionChanged = Notification.Name("yinaSubPositionChanged")
  static let yinaSubDelayChanged = Notification.Name("yinaSubDelayChanged")
  static let yinaSubVisibilityChanged = Notification.Name("yinaSubVisibilityChanged")

  static let yinaKeyBindingInputChanged = Notification.Name("YINAKeyBindingInputChanged")
  static let yinaFileLoaded = Notification.Name("YINAFileLoaded")
  static let yinaHistoryUpdated = Notification.Name("YINAHistoryUpdated")
  static let yinaGlobalKeyBindingsChanged = Notification.Name("yinaGlobalKeyBindingsChanged")
  static let yinaKeyBindingChanged = Notification.Name("yinaKeyBindingChanged")
  static let yinaPluginChanged = Notification.Name("YINAPluginChanged")
  static let yinaPlayerStopped = Notification.Name("yinaPlayerStopped")
  static let yinaPlayerShutdown = Notification.Name("yinaPlayerShutdown")
  static let yinaPlaySliderLoopKnobChanged = Notification.Name("yinaPlaySliderLoopKnobChanged")
  static let yinaLogoutCompleted = Notification.Name("iinaLoggedOutOfSubtitleProvider")
  static let yinaHistoryTaskFinished = Notification.Name("yinaHistoryTaskFinished")
  static let yinaPIPStatusChanged = Notification.Name("yinaPIPStatusChanged")
  static let yinaFullscreenChanged = Notification.Name("yinaFullscreenChanged")
  static let yinaSidebarStatusChanged = Notification.Name("yinaSidebarStatusChanged")
  static let yinaLogAppended = Notification.Name("yinaLogAppended")
}

enum YINAError: Error {
  case unsupportedMPVNodeFormat(UInt32)
}


extension AppData {
  /// A list of mpv commands that cannot access arbitrary files or execute other commands.
  static let safeMPVCommands: Set<String> = [
    MPVCommand.seek.rawValue,
    MPVCommand.revertSeek.rawValue,
    MPVCommand.subSeek.rawValue,
    MPVCommand.frameStep.rawValue,
    MPVCommand.frameBackStep.rawValue,
    MPVCommand.stop.rawValue,
    MPVCommand.dropBuffers.rawValue,
    MPVCommand.abLoop.rawValue,
    MPVCommand.abLoopAlignCache.rawValue,

    MPVCommand.playlistNext.rawValue,
    MPVCommand.playlistPrev.rawValue,
    MPVCommand.playlistNextPlaylist.rawValue,
    MPVCommand.playlistPrevPlaylist.rawValue,
    MPVCommand.playlistPlayIndex.rawValue,
    MPVCommand.playlistClear.rawValue,
    MPVCommand.playlistRemove.rawValue,
    MPVCommand.playlistMove.rawValue,
    MPVCommand.playlistShuffle.rawValue,
    MPVCommand.playlistUnshuffle.rawValue,

    MPVCommand.subRemove.rawValue,
    MPVCommand.subReload.rawValue,
    MPVCommand.subStep.rawValue,
    MPVCommand.audioRemove.rawValue,
    MPVCommand.audioReload.rawValue,
    MPVCommand.videoRemove.rawValue,
    MPVCommand.videoReload.rawValue,

    MPVCommand.printText.rawValue,
    MPVCommand.expandText.rawValue,
    MPVCommand.escapeAss.rawValue,
    MPVCommand.showText.rawValue,
    MPVCommand.showProgress.rawValue,
    MPVCommand.overlayRemove.rawValue,
    MPVCommand.osdOverlay.rawValue,

    MPVCommand.screenshotRaw.rawValue,
    MPVCommand.ignore.rawValue,
    MPVCommand.beginVoDragging.rawValue,
    MPVCommand.contextMenu.rawValue,
    MPVCommand.quit.rawValue,
  ]

  /// A list of mpv options that should be allowed in the URL scheme.
  /// Ensure absolutely no possibility of local file read/write.
  static let safeMPVOptions = Set([
    // track selection
    "aid", "vid", "sid", "secondary-sid",
    "alang", "slang", "vlang", "edition", "track-auto-selection",
    "subs-with-matching-audio", "subs-match-os-language", "subs-fallback", "subs-fallback-forced",
    // playback control
    "start", "end", "length", "frames", "speed", "pitch", "pause", "sstep", "correct-pts", "container-fps-override",
    "loop-file", "loop-playlist", "ab-loop-a", "ab-loop-b", "ab-loop-count", "play-direction",
    "rebase-start-time", "hr-seek", "hr-seek-framedrop",
    // video
    "deinterlace", "deinterlace-field-parity", "hwdec", "hwdec-codecs",
    "video-aspect-override", "video-aspect-method", "video-rotate", "video-crop",
    "video-zoom", "video-pan-x", "video-pan-y", "video-align-x", "video-align-y",
    "video-unscaled", "video-scale-x", "video-scale-y", "video-recenter",
    "video-margin-ratio-left", "video-margin-ratio-right", "video-margin-ratio-top", "video-margin-ratio-bottom",
    "video-output-levels", "panscan", "framedrop", "video-latency-hacks", "display-fps-override",
    "vd-lavc-skiploopfilter", "vd-lavc-skipidct", "vd-lavc-skipframe", "vd-lavc-threads", "vd-lavc-framedrop", "vd-lavc-fast", "vd-lavc-film-grain", "vd-lavc-dr",
    "vd-apply-cropping", "hwdec-extra-frames", "hwdec-image-format", "hwdec-threads", "hwdec-software-fallback", "vd-lavc-check-hw-profile", "swapchain-depth",
    "brightness", "contrast", "saturation", "gamma", "hue",
    // audio
    "volume", "volume-max", "volume-gain", "volume-gain-max", "volume-gain-min", "mute",
    "audio-delay", "audio-pitch-correction", "audio-channels", "audio-display",
    "audio-samplerate", "audio-format", "audio-exclusive", "audio-spdif",
    "gapless-audio", "initial-audio-sync", "replaygain", "replaygain-preamp", "replaygain-clip", "replaygain-fallback",
    "ad-lavc-ac3drc", "ad-lavc-downmix", "ad-lavc-threads",
    "audio-stream-silence", "audio-wait-open", "audio-buffer", "audio-normalize-downmix", "audio-set-media-role",
    // subtitles
    "sub-delay", "secondary-sub-delay",
    "sub-scale", "sub-scale-signs", "sub-scale-by-window", "sub-scale-with-window", "sub-ass-scale-with-window",
    "sub-pos", "secondary-sub-pos", "sub-speed", "sub-visibility", "secondary-sub-visibility",
    "sub-ass", "sub-ass-justify",
    "sub-ass-override", "secondary-sub-ass-override", "sub-ass-force-margins", "sub-use-margins",
    "sub-ass-use-video-data", "sub-vsfilter-bidi-compat", "sub-ass-vsfilter-color-compat",
    "sub-font", "sub-font-size", "sub-color", "sub-outline-color", "sub-outline-size", "sub-back-color",
    "sub-shadow-offset", "sub-bold", "sub-italic", "sub-blur",
    "sub-margin-x", "sub-margin-y", "sub-align-x", "sub-align-y", "sub-justify",
    "sub-border-style", "sub-spacing", "sub-line-spacing", "sub-hinting", "sub-shaper",
    "sub-codepage", "sub-fix-timing", "sub-fix-timing-threshold", "sub-fix-timing-keep",
    "sub-stretch-durations", "sub-gauss", "sub-gray", "sub-forced-events-only", "sub-fps",
    "sub-filter-sdh", "sub-filter-sdh-harder", "sub-filter-sdh-enclosures",
    "sub-clear-on-seek", "sub-create-cc-track", "sub-past-video-end", "sub-font-provider", "sub-hdr-peak", "image-subs-hdr-peak",
    "sub-ass-style-overrides", "stretch-dvd-subs", "stretch-image-subs-to-screen", "image-subs-video-resolution",
    "embeddedfonts", "sub-ass-video-aspect-override", "sub-ass-prune-delay", "teletext-page",
    // window
    "fullscreen", "geometry", "ontop", "keep-open", "keep-open-pause", "image-display-duration", "stop-screensaver",
    // network
    "user-agent", "referrer", "network-timeout", "tls-verify", "rtsp-transport", "hls-bitrate",
    "cache", "cache-secs", "cache-pause", "cache-pause-wait", "cache-pause-initial", "force-seekable",
    "http-header-fields", "cookies",
    // demuxer, audio resampler, others
    "demuxer-readahead-secs", "demuxer-mkv-subtitle-preroll", "demuxer-mkv-subtitle-preroll-secs",
    "demuxer-lavf-analyzeduration", "demuxer-lavf-probescore", "demuxer-lavf-probesize",
    "demuxer-max-bytes", "demuxer-max-back-bytes",
    "audio-resample-filter-size", "audio-resample-phase-shift", "audio-resample-cutoff", "audio-resample-linear", "audio-resample-max-output-size",
    "video-sync", "interpolation",
  ])
}
