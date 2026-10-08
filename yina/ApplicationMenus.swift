import Cocoa

/// Owns the former main nib's menu tree. Dynamic playback menus remain in MenuController.
final class ApplicationMenus {
  enum Target { case responderChain, applicationDelegate, updater, fontManager }
  struct Definition {
    let title: String
    let binding: String?
    let items: [Item]
    static func menu(_ title: String, binding: String?, items: [Item]) -> Definition {
      Definition(title: title, binding: binding, items: items)
    }
  }
  struct Item {
    let title: String
    let binding: String?
    let key: String
    let modifiers: NSEvent.ModifierFlags
    let action: String?
    let target: Target
    let tag: Int
    let hidden: Bool
    let enabled: Bool
    let alternate: Bool
    let separator: Bool
    let submenu: Definition?
    static func item(_ title: String, binding: String? = nil, key: String = "",
                     modifiers: NSEvent.ModifierFlags = [.command], action: String? = nil,
                     target: Target = .responderChain, tag: Int = 0, hidden: Bool = false,
                     enabled: Bool = true, alternate: Bool = false, submenu: Definition? = nil) -> Item {
      Item(title: title, binding: binding, key: key, modifiers: modifiers, action: action,
           target: target, tag: tag, hidden: hidden, enabled: enabled, alternate: alternate,
           separator: false, submenu: submenu)
    }
    static func separator(binding: String? = nil, hidden: Bool = false) -> Item {
      Item(title: "", binding: binding, key: "", modifiers: [], action: nil,
           target: .responderChain, tag: 0, hidden: hidden, enabled: true,
           alternate: false, separator: true, submenu: nil)
    }
  }

  private var menuBindings: [String: NSMenu] = [:]
  private var itemBindings: [String: NSMenuItem] = [:]
  private var targets: [Target: AnyObject]
  private var recentDocuments: RecentDocumentsMenuController?
  private(set) var mainMenu: NSMenu!
  private(set) var dockMenu: NSMenu!

  init(applicationDelegate: AnyObject, updater: AnyObject, fontManager: AnyObject) {
    targets = [.applicationDelegate: applicationDelegate, .updater: updater, .fontManager: fontManager]
    mainMenu = build(Self.mainDefinition)
#if DEBUG
    itemBindings["exportManagedDefaults"]?.isHidden = false
#endif
    dockMenu = build(Self.dockDefinition)
    // Menu items retain neither their targets nor their delegates.
    targets.removeAll()
  }

  func menu(_ binding: String) -> NSMenu { menuBindings[binding]! }
  func item(_ binding: String) -> NSMenuItem { itemBindings[binding]! }

  func install(in application: NSApplication) {
    application.mainMenu = mainMenu
    application.servicesMenu = menu("servicesMenu")
    application.windowsMenu = menu("windowsMenu")
    application.helpMenu = menu("helpMenu")
  }

  func configureRecentDocuments(target: AnyObject, openAction: Selector,
                                urls: @escaping () -> [URL], clear: @escaping () -> Void) {
    let controller = RecentDocumentsMenuController(target: target, openAction: openAction, urls: urls, clear: clear)
    recentDocuments = controller
    let recentMenu = menu("recentDocumentsMenu")
    recentMenu.autoenablesItems = false
    recentMenu.delegate = controller
    controller.menuNeedsUpdate(recentMenu)
  }

  private func build(_ definition: Definition) -> NSMenu {
    let menu = NSMenu(title: definition.title)
    if let binding = definition.binding { menuBindings[binding] = menu }
    for definition in definition.items {
      let item = definition.separator ? NSMenuItem.separator() : NSMenuItem(
        title: definition.title, action: definition.action.map(NSSelectorFromString), keyEquivalent: definition.key)
      item.keyEquivalentModifierMask = definition.modifiers
      item.target = targets[definition.target]
      item.tag = definition.tag
      item.isHidden = definition.hidden
      item.isEnabled = definition.enabled
      item.isAlternate = definition.alternate
      if let binding = definition.binding { itemBindings[binding] = item }
      if let submenu = definition.submenu { item.submenu = build(submenu) }
      menu.addItem(item)
    }
    return menu
  }

  private static let mainDefinition: Definition =
    .menu("Main Menu", binding: "mainMenu", items: [
      .item("yina", modifiers: [], submenu:
        .menu("yina", binding: "applicationMenu", items: [
          .item("About yina", modifiers: [], action: "showAboutWindow:", target: .applicationDelegate),
          .item("Check for Updates...", modifiers: [], action: "checkForUpdates:", target: .updater),
          .separator(),
          .item("Preferences…", key: ",", action: "showPreferences:", target: .applicationDelegate),
          .item("Export Current Settings as Defaults…", binding: "exportManagedDefaults", modifiers: [], action: "exportManagedDefaults:", target: .applicationDelegate, hidden: true),
          .separator(),
          .item("Services", modifiers: [], submenu:
            .menu("Services", binding: "servicesMenu", items: [
            ])),
          .separator(),
          .item("Hide yina", key: "h", action: "hide:"),
          .item("Hide Others", key: "h", modifiers: [.option, .command], action: "hideOtherApplications:"),
          .item("Show All", modifiers: [], action: "unhideAllApplications:"),
          .separator(),
          .item("Quit yina", key: "q", action: "terminate:"),
        ])),
      .item("File", modifiers: [], submenu:
        .menu("File", binding: "fileMenu", items: [
          .item("Open…", binding: "open", key: "o", action: "openFile:", target: .applicationDelegate),
          .item("Open in New Window…", binding: "openAlternative", key: "o", modifiers: [.option, .command], action: "openFile:", target: .applicationDelegate, tag: 1, alternate: true),
          .item("Open URL…", binding: "openURL", key: "O", modifiers: [.shift, .command], action: "openURL:", target: .applicationDelegate),
          .item("Open URL in New Window…", binding: "openURLAlternative", key: "O", modifiers: [.shift, .option, .command], action: "openURL:", target: .applicationDelegate, tag: 1, alternate: true),
          .item("Open Recent", modifiers: [], tag: 901, submenu:
            .menu("Open Recent", binding: "recentDocumentsMenu", items: [
              .item("Clear Menu", modifiers: [], action: "clearRecentDocuments:"),
            ])),
          .separator(binding: "newWindowSeparator", hidden: true),
          .item("New Window", binding: "newWindow", key: "n", action: "menuNewWindow:", target: .applicationDelegate, hidden: true),
          .separator(),
          .item("Playback History", key: "H", modifiers: [.shift, .command], action: "showHistoryWindow:", target: .applicationDelegate),
          .separator(),
          .item("Show Current File in Finder", binding: "showCurrentFileInFinder", modifiers: []),
          .item("Delete Current File", binding: "deleteCurrentFile", modifiers: []),
          .item("Save Current Playlist...", binding: "savePlaylist", modifiers: []),
          .separator(),
          .item("Close", key: "w", action: "performClose:"),
          .item("Other Actions From Key Bindings", modifiers: [], hidden: true, submenu:
            .menu("Other Actions From Key Bindings", binding: "otherKeyBindingsMenu", items: [
            ])),
        ])),
      .item("Edit", modifiers: [], hidden: true, submenu:
        .menu("Edit", binding: nil, items: [
          .item("Undo", key: "z", action: "undo:"),
          .item("Redo", key: "Z", action: "redo:"),
          .separator(),
          .item("Cut", key: "x", action: "cut:", tag: 601),
          .item("Copy", key: "c", action: "copy:", tag: 602),
          .item("Paste", key: "v", action: "paste:", tag: 603),
          .item("Delete", modifiers: [], action: "delete:", tag: 604),
          .item("Select All", key: "a", action: "selectAll:"),
          .separator(),
          .item("Transformations", modifiers: [], submenu:
            .menu("Transformations", binding: nil, items: [
              .item("Make Upper Case", modifiers: [], action: "uppercaseWord:"),
              .item("Make Lower Case", modifiers: [], action: "lowercaseWord:"),
              .item("Capitalize", modifiers: [], action: "capitalizeWord:"),
            ])),
          .item("Speech", modifiers: [], submenu:
            .menu("Speech", binding: nil, items: [
              .item("Start Speaking", modifiers: [], action: "startSpeaking:"),
              .item("Stop Speaking", modifiers: [], action: "stopSpeaking:"),
            ])),
        ])),
      .item("Playback", modifiers: [], submenu:
        .menu("Playback", binding: "playbackMenu", items: [
          .item("Pause", binding: "pause", modifiers: []),
          .item("Stop and Clear Playlists", binding: "stop", modifiers: []),
          .separator(),
          .item("Step Forward 5s", binding: "forward", modifiers: []),
          .item("Next Frame", binding: "nextFrame", modifiers: [], alternate: true),
          .item("Step Backward 5s", binding: "backward", modifiers: [], tag: 1),
          .item("Previous Frame", binding: "previousFrame", modifiers: [], tag: 1, alternate: true),
          .item("Jump to Beginning", binding: "jumpToBegin", modifiers: []),
          .item("Jump to…", binding: "jumpTo", key: "j"),
          .separator(),
          .item("Speed:", binding: "speedIndicator", modifiers: [], enabled: false),
          .item("Speed Up to 2x", binding: "speedUp", modifiers: []),
          .item("Speed Up to 1.1x", binding: "speedUpSlightly", modifiers: [], tag: 2, alternate: true),
          .item("Speed Down to 0.5x", binding: "speedDown", modifiers: [], tag: 1),
          .item("Speed Down to 0.9x", binding: "speedDownSlightly", modifiers: [], tag: 3, alternate: true),
          .item("Reset Speed", binding: "speedReset", modifiers: [], tag: 5),
          .separator(),
          .item("Take a Screenshot", binding: "screenshot", key: "S", modifiers: [.shift, .command]),
          .item("Go to Screenshot Folder", binding: "gotoScreenshotFolder", modifiers: []),
          .item("Advanced Screenshot...", binding: "advancedScreenshot", modifiers: [], hidden: true),
          .separator(),
          .item("A-B Loop", binding: "abLoop", modifiers: []),
          .item("File Loop", binding: "fileLoop", modifiers: []),
          .separator(),
          .item("Show Playlist Panel", binding: "playlistPanel", modifiers: []),
          .item("Playlist Loop", binding: "playlistLoop", modifiers: []),
          .item("Playlist", binding: "playlist", modifiers: [], submenu:
            .menu("Playlist", binding: "playlistMenu", items: [
            ])),
          .separator(),
          .item("Next Media", binding: "nextMedia", modifiers: []),
          .item("Previous Media", binding: "previousMedia", modifiers: []),
          .separator(),
          .item("Show Chapters Panel", binding: "chapterPanel", modifiers: []),
          .item("Chapters", binding: "chapter", modifiers: [], submenu:
            .menu("Chapters", binding: "chapterMenu", items: [
            ])),
          .separator(),
          .item("Next Chapter", binding: "nextChapter", modifiers: []),
          .item("Previous Chapter", binding: "previousChapter", modifiers: []),
        ])),
      .item("Video", modifiers: [], submenu:
        .menu("Video", binding: "videoMenu", items: [
          .item("Show Video Panel", binding: "quickSettingsVideo", modifiers: []),
          .separator(),
          .item("Cycle Video Tracks", binding: "cycleVideoTracks", modifiers: []),
          .item("Video Track", binding: "videoTrack", modifiers: [], submenu:
            .menu("Video Track", binding: "videoTrackMenu", items: [
            ])),
          .separator(),
          .item("Half Size", binding: "halfSize", modifiers: []),
          .item("Normal Size", binding: "normalSize", modifiers: []),
          .item("Normal Size (Retina)", binding: "normalSizeRetina", key: "1", modifiers: [.option, .command], hidden: true, alternate: true),
          .item("Double Size", binding: "doubleSize", modifiers: []),
          .item("Fit to Screen", binding: "fitToScreen", modifiers: []),
          .separator(),
          .item("Bigger Size", binding: "biggerSize", modifiers: [], tag: 11),
          .item("Smaller Size", binding: "smallerSize", modifiers: [], tag: 10),
          .separator(),
          .item("Enter Picture in Picture", binding: "pictureInPicture", modifiers: []),
          .item("Enter Full Screen", binding: "fullScreen", modifiers: []),
          .item("Float on Top", binding: "alwaysOnTop", modifiers: []),
          .item("Lock Window Aspect Ratio", binding: "lockAspectRatio", modifiers: []),
          .item("Live Text", binding: "liveText", modifiers: []),
          .separator(),
          .item("Enter Music Mode", binding: "miniPlayer", modifiers: []),
          .separator(),
          .item("Aspect Ratio", modifiers: [], submenu:
            .menu("", binding: "aspectMenu", items: [
            ])),
          .item("Crop", modifiers: [], submenu:
            .menu("Crop", binding: "cropMenu", items: [
            ])),
          .item("Rotation", modifiers: [], submenu:
            .menu("Rotation", binding: "rotationMenu", items: [
            ])),
          .item("Flip", modifiers: [], submenu:
            .menu("Flip", binding: "flipMenu", items: [
              .item("Horizontal (Mirror)", binding: "mirror", modifiers: []),
              .item("Vertical (Flip)", binding: "flip", modifiers: []),
            ])),
          .item("Deinterlace", binding: "deinterlace", modifiers: []),
          .item("Delogo", binding: "delogo", modifiers: []),
          .separator(),
          .item("Video Filters…", binding: "videoFilters", key: "F", modifiers: [.shift, .command]),
          .item("Saved Video Filters", modifiers: [], submenu:
            .menu("Saved Video Filters", binding: "savedVideoFiltersMenu", items: [
            ])),
        ])),
      .item("Audio", modifiers: [], submenu:
        .menu("Audio", binding: "audioMenu", items: [
          .item("Show Audio Panel", binding: "quickSettingsAudio", modifiers: []),
          .separator(),
          .item("Cycle Audio Tracks", binding: "cycleAudioTracks", modifiers: [], tag: 1),
          .item("Audio Track", modifiers: [], submenu:
            .menu("Audio Track", binding: "audioTrackMenu", items: [
            ])),
          .item("Load External Audio…", binding: "loadExternalAudio", modifiers: []),
          .separator(),
          .item("Volume:", binding: "volumeIndicator", modifiers: [], enabled: false),
          .item("Volume + 5%", binding: "increaseVolume", modifiers: [], tag: 10),
          .item("Volume + 1%", binding: "increaseVolumeSlightly", modifiers: [], tag: 1, alternate: true),
          .item("Volume - 5%", binding: "decreaseVolume", modifiers: [], tag: 10),
          .item("Volume - 1%", binding: "decreaseVolumeSlightly", modifiers: [], tag: 1, alternate: true),
          .item("Mute", binding: "mute", modifiers: []),
          .separator(),
          .item("Audio Delay:", binding: "audioDelayIndicator", modifiers: [], enabled: false),
          .item("Audio Delay + 0.5s", binding: "increaseAudioDelay", modifiers: []),
          .item("Audio Delay + 0.1s", binding: "increaseAudioDelaySlightly", modifiers: [], alternate: true),
          .item("Audio Delay - 0.5s", binding: "decreaseAudioDelay", modifiers: []),
          .item("Audio Delay - 0.1s", binding: "decreaseAudioDelaySlightly", modifiers: [], alternate: true),
          .item("Reset Audio Delay", binding: "resetAudioDelay", modifiers: []),
          .separator(),
          .item("Audio Device", modifiers: [], submenu:
            .menu("Audio Device", binding: "audioDeviceMenu", items: [
            ])),
          .separator(),
          .item("Audio Filters…", binding: "audioFilters", key: "G", modifiers: [.shift, .command]),
          .item("Saved Audio Filters", modifiers: [], submenu:
            .menu("Saved Audio Filters", binding: "savedAudioFiltersMenu", items: [
            ])),
        ])),
      .item("Subtitles", modifiers: [], submenu:
        .menu("Subtitles", binding: "subMenu", items: [
          .item("Show Subtitles Panel", binding: "quickSettingsSub", modifiers: []),
          .separator(),
          .item("Cycle Subtitles", binding: "cycleSubtitles", modifiers: [], tag: 2),
          .item("Subtitle", modifiers: [], submenu:
            .menu("Subtitle", binding: "subTrackMenu", items: [
              .item("<None>", modifiers: [], action: "orderFrontFontPanel:", target: .fontManager),
            ])),
          .item("Hide Subtitles", binding: "hideSubtitles", modifiers: []),
          .item("Secondary Subtitle", modifiers: [], submenu:
            .menu("Secondary Subtitle", binding: "secondSubTrackMenu", items: [
              .item("<None>", modifiers: [], action: "orderFrontFontPanel:", target: .fontManager),
            ])),
          .item("Hide Secondary Subtitles", binding: "hideSecondSubtitles", modifiers: []),
          .item("Load External Subtitle…", binding: "loadExternalSub", modifiers: []),
          .separator(),
          .item("Find Online Subtitles…", binding: "findOnlineSub", modifiers: []),
          .item("Find Online Subtitles from", modifiers: [], submenu:
            .menu("Find Online Subtitles from", binding: "onlineSubSourceMenu", items: [
            ])),
          .item("Save Downloaded Subtitle…", binding: "saveDownloadedSub", modifiers: []),
          .separator(),
          .item("Encoding", modifiers: [], submenu:
            .menu("Encoding", binding: "encodingMenu", items: [
            ])),
          .separator(),
          .item("Scale Up", binding: "increaseTextSize", modifiers: [], action: "toggleToolbarShown:", tag: 5),
          .item("Scale Down", binding: "decreaseTextSize", modifiers: [], tag: -5),
          .item("Reset Subtitle Scale", binding: "resetTextSize", modifiers: []),
          .separator(),
          .item("Subtitle Delay: ", binding: "subDelayIndicator", modifiers: [], enabled: false),
          .item("Subtitle Delay + 0.5s", binding: "increaseSubDelay", modifiers: []),
          .item("Subtitle Delay + 0.1s", binding: "increaseSubDelaySlightly", modifiers: [], alternate: true),
          .item("Subtitle Delay - 0.5s", binding: "decreaseSubDelay", modifiers: [], action: "toggleToolbarShown:"),
          .item("Subtitle Delay - 0.1s", binding: "decreaseSubDelaySlightly", modifiers: [], action: "toggleToolbarShown:", alternate: true),
          .item("Reset Subtitle Delay", binding: "resetSubDelay", modifiers: []),
          .separator(),
          .item("Font...", binding: "subFont", modifiers: []),
        ])),
      .item("Plugin", binding: "pluginMenuItem", modifiers: [], submenu:
        .menu("Plugin", binding: "pluginMenu", items: [
        ])),
      .item("Window", modifiers: [], submenu:
        .menu("Window", binding: "windowsMenu", items: [
          .item("Minimize", key: "m", action: "performMiniaturize:"),
          .item("Zoom", modifiers: [], action: "performZoom:"),
          .separator(),
          .item("Inspector", binding: "inspector", key: "i"),
          .item("Log Viewer", key: "l", modifiers: [.control, .command], action: "showLogWindow:", target: .applicationDelegate),
          .separator(),
          .item("Bring All to Front", modifiers: [], action: "arrangeInFront:"),
        ])),
      .item("Help", modifiers: [], submenu:
        .menu("Help", binding: "helpMenu", items: [
          .item("yina Help", key: "?", action: "helpAction:", target: .applicationDelegate),
          .item("Dump Debug Info", binding: "debugDump", modifiers: [], action: "dumpDebugInfo:", target: .applicationDelegate),
          .separator(),
          .item("Release Highlights", modifiers: [], action: "showHighlights:", target: .applicationDelegate),
          .separator(),
          .item("GitHub", modifiers: [], action: "githubAction:", target: .applicationDelegate),
          .item("Website", modifiers: [], action: "websiteAction:", target: .applicationDelegate),
        ])),
    ])

  private static let dockDefinition: Definition =
    .menu("", binding: "dockMenu", items: [
      .item("Open...", modifiers: [], action: "openFile:", target: .applicationDelegate),
      .item("Open URL…", modifiers: [], action: "openURL:", target: .applicationDelegate),
    ])
}

/// Uses public document-controller APIs; the native recent-list storage remains authoritative.
final class RecentDocumentsMenuController: NSObject, NSMenuDelegate {
  private weak var target: AnyObject?
  private let openAction: Selector
  private let urls: () -> [URL]
  private let clear: () -> Void

  init(target: AnyObject, openAction: Selector, urls: @escaping () -> [URL], clear: @escaping () -> Void) {
    self.target = target
    self.openAction = openAction
    self.urls = urls
    self.clear = clear
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let documents = urls()
    for url in documents {
      let item = NSMenuItem(title: url.isFileURL ? url.lastPathComponent : url.absoluteString,
                            action: openAction, keyEquivalent: "")
      item.target = target
      item.representedObject = url
      item.toolTip = url.isFileURL ? url.path : url.absoluteString
      menu.addItem(item)
    }
    if !documents.isEmpty { menu.addItem(.separator()) }
    let clearItem = NSMenuItem(title: "Clear Menu", action: #selector(clearDocuments(_:)), keyEquivalent: "")
    clearItem.target = self
    clearItem.isEnabled = !documents.isEmpty
    menu.addItem(clearItem)
  }

  @objc private func clearDocuments(_ sender: NSMenuItem) {
    clear()
    if let menu = sender.menu { menuNeedsUpdate(menu) }
  }
}
