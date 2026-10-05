import Cocoa

/// Inspector content and toolbar. Playback queries remain in the window controller.
final class InspectorWindowContentView: NSView, NSToolbarDelegate {
  let tabView = NSTabView()
  let tabButtonGroup: NSSegmentedControl
  let trackPopup = NSPopUpButton()
  let watchTableView = NSTableView()
  let watchTableContainerView = NSView()
  let deleteButton: NSButton
  private(set) var fields: [String: NSTextField] = [:]
  private var toolbarItem: NSToolbarItem!

  init(target: AnyObject, tabAction: Selector, trackAction: Selector,
       addAction: Selector, removeAction: Selector) {
    tabButtonGroup = NSSegmentedControl(labels: ["General", "Tracks", "File", "Status"],
      trackingMode: .selectOne, target: target, action: tabAction)
    deleteButton = Self.imageButton(NSImage.removeTemplateName, target: target, action: removeAction)
    super.init(frame: NSRect(x: 0, y: 0, width: 468, height: 481))
    wantsLayer = true
    tabButtonGroup.controlSize = .small
    tabButtonGroup.segmentStyle = .rounded
    tabButtonGroup.selectedSegment = 0
    tabButtonGroup.setAccessibilityLabel("Inspector tabs")
    tabView.tabViewType = .noTabsNoBorder
    tabView.drawsBackground = false
    tabView.controlSize = .small
    addSubview(tabView)
    pin(tabView, to: self, horizontal: 12, vertical: 8)
    trackPopup.target = target
    trackPopup.action = trackAction
    trackPopup.controlSize = .small
    trackPopup.setAccessibilityLabel("Track")

    let general = NSView(frame: NSRect(x: 0, y: 0, width: 444, height: 465))
    addField(to: general, key: nil, title: "VIDEO",
      left: 10, top: 8, width: 46, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: nil, title: "Format:",
      left: 10, top: 36, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: "vformatField", title: "",
      left: 94, top: 36, width: 340, expands: true, bold: false, accessibilityLabel: "Format")
    addField(to: general, key: nil, title: "Codec:",
      left: 10, top: 58, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: "vcodecField", title: "",
      left: 94, top: 58, width: 340, expands: true, bold: false, accessibilityLabel: "Codec")
    addField(to: general, key: nil, title: "Hw Decoder:",
      left: 10, top: 80, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: "vdecoderField", title: "",
      left: 94, top: 80, width: 340, expands: true, bold: false, accessibilityLabel: "Hw Decoder")
    addField(to: general, key: nil, title: "Primaries:",
      left: 10, top: 102, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: "vprimariesField", title: "",
      left: 94, top: 102, width: 340, expands: true, bold: false, accessibilityLabel: "Primaries")
    addField(to: general, key: nil, title: "Colorspace:",
      left: 10, top: 124, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: "vcolorspaceField", title: "",
      left: 94, top: 124, width: 340, expands: true, bold: false, accessibilityLabel: "Colorspace")
    addField(to: general, key: nil, title: "Pixel Format:",
      left: 10, top: 146, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: "vPixelFormat", title: "",
      left: 94, top: 146, width: 340, expands: true, bold: false, accessibilityLabel: "Pixel Format")
    addField(to: general, key: nil, title: "Driver:",
      left: 10, top: 168, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: "voField", title: "",
      left: 94, top: 168, width: 340, expands: true, bold: false, accessibilityLabel: "Driver")
    addField(to: general, key: nil, title: "Size:",
      left: 10, top: 190, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: "vsizeField", title: "",
      left: 94, top: 190, width: 340, expands: true, bold: false, accessibilityLabel: "Size")
    addField(to: general, key: nil, title: "Bit Rate:",
      left: 10, top: 212, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: "vbitrateField", title: "",
      left: 94, top: 212, width: 340, expands: true, bold: false, accessibilityLabel: "Bit Rate")
    addField(to: general, key: nil, title: "FPS:",
      left: 10, top: 234, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: "vfpsField", title: "",
      left: 94, top: 234, width: 340, expands: true, bold: false, accessibilityLabel: "FPS")
    addField(to: general, key: nil, title: "AUDIO",
      left: 10, top: 273, width: 47, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: nil, title: "Format:",
      left: 10, top: 301, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: "aformatField", title: "",
      left: 94, top: 301, width: 340, expands: true, bold: false, accessibilityLabel: "Format")
    addField(to: general, key: nil, title: "Codec:",
      left: 10, top: 323, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: "acodecField", title: "",
      left: 94, top: 323, width: 340, expands: true, bold: false, accessibilityLabel: "Codec")
    addField(to: general, key: nil, title: "Driver:",
      left: 10, top: 345, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: "aoField", title: "",
      left: 94, top: 345, width: 340, expands: true, bold: false, accessibilityLabel: "Driver")
    addField(to: general, key: nil, title: "Channels:",
      left: 10, top: 367, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: "achannelsField", title: "",
      left: 94, top: 367, width: 340, expands: true, bold: false, accessibilityLabel: "Channels")
    addField(to: general, key: nil, title: "Bit Rate:",
      left: 10, top: 389, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: "abitrateField", title: "",
      left: 94, top: 389, width: 340, expands: true, bold: false, accessibilityLabel: "Bit Rate")
    addField(to: general, key: nil, title: "Sample Rate:",
      left: 10, top: 411, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: general, key: "asamplerateField", title: "",
      left: 94, top: 411, width: 340, expands: true, bold: false, accessibilityLabel: "Sample Rate")
    addSeparator(to: general, top: 258)
    addTab("General", content: general)

    let tracks = NSView(frame: NSRect(x: 0, y: 0, width: 444, height: 465))
    addField(to: tracks, key: nil, title: "Track:",
      left: 10, top: 12, width: 42, expands: false, bold: false, accessibilityLabel: nil)
    addField(to: tracks, key: nil, title: "ID:",
      left: 10, top: 57, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: tracks, key: "trackIdField", title: "",
      left: 94, top: 57, width: 340, expands: true, bold: false, accessibilityLabel: "ID")
    addField(to: tracks, key: nil, title: "Properties:",
      left: 10, top: 79, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: tracks, key: "trackDefaultField", title: "Default",
      left: 94, top: 79, width: 42, expands: false, bold: false, accessibilityLabel: "Properties")
    addField(to: tracks, key: "trackForcedField", title: "Forced",
      left: 140, top: 79, width: 41, expands: false, bold: false, accessibilityLabel: "Properties")
    addField(to: tracks, key: "trackSelectedField", title: "Selected",
      left: 185, top: 79, width: 51, expands: false, bold: false, accessibilityLabel: "Properties")
    addField(to: tracks, key: "trackExternalField", title: "External",
      left: 240, top: 79, width: 47, expands: false, bold: false, accessibilityLabel: "Properties")
    addField(to: tracks, key: nil, title: "Source ID:",
      left: 10, top: 101, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: tracks, key: "trackSourceIdField", title: "",
      left: 94, top: 101, width: 340, expands: true, bold: false, accessibilityLabel: "Source ID")
    addField(to: tracks, key: nil, title: "Title:",
      left: 10, top: 123, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: tracks, key: "trackTitleField", title: "",
      left: 94, top: 123, width: 340, expands: true, bold: false, accessibilityLabel: "Title")
    addField(to: tracks, key: nil, title: "Language:",
      left: 10, top: 143, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: tracks, key: "trackLangField", title: "",
      left: 94, top: 143, width: 340, expands: true, bold: false, accessibilityLabel: "Language")
    addField(to: tracks, key: nil, title: "File Path:",
      left: 10, top: 163, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: tracks, key: "trackFilePathField", title: "",
      left: 94, top: 163, width: 340, expands: true, bold: false, accessibilityLabel: "File Path")
    addField(to: tracks, key: nil, title: "Codec:",
      left: 10, top: 183, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: tracks, key: "trackCodecField", title: "",
      left: 94, top: 183, width: 340, expands: true, bold: false, accessibilityLabel: "Codec")
    addField(to: tracks, key: nil, title: "Decoder:",
      left: 10, top: 203, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: tracks, key: "trackDecoderField", title: "",
      left: 94, top: 203, width: 340, expands: true, bold: false, accessibilityLabel: "Decoder")
    addField(to: tracks, key: nil, title: "FPS:",
      left: 10, top: 223, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: tracks, key: "trackFPSField", title: "",
      left: 94, top: 223, width: 340, expands: true, bold: false, accessibilityLabel: "FPS")
    addField(to: tracks, key: nil, title: "Channels:",
      left: 10, top: 243, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: tracks, key: "trackChannelsField", title: "",
      left: 94, top: 243, width: 340, expands: true, bold: false, accessibilityLabel: "Channels")
    addField(to: tracks, key: nil, title: "Sample Rate:",
      left: 10, top: 263, width: 78, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: tracks, key: "trackSampleRateField", title: "",
      left: 94, top: 263, width: 340, expands: true, bold: false, accessibilityLabel: "Sample Rate")
    addSeparator(to: tracks, top: 42)
    tracks.addSubview(trackPopup)
    trackPopup.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      trackPopup.leadingAnchor.constraint(equalTo: tracks.leadingAnchor, constant: 60),
      trackPopup.trailingAnchor.constraint(equalTo: tracks.trailingAnchor, constant: -12),
      trackPopup.topAnchor.constraint(equalTo: tracks.topAnchor, constant: 12)
    ])
    addTab("Tracks", content: tracks)

    let file = NSView(frame: NSRect(x: 0, y: 0, width: 444, height: 465))
    addField(to: file, key: nil, title: "File path:",
      left: 10, top: 12, width: 56, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: file, key: "pathField", title: "",
      left: 10, top: 30, width: 424, expands: true, bold: false, accessibilityLabel: "")
    addField(to: file, key: nil, title: "Title:",
      left: 10, top: 69, width: 62, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: file, key: "titleField", title: "",
      left: 78, top: 69, width: 356, expands: true, bold: false, accessibilityLabel: "Title")
    addField(to: file, key: nil, title: "Comment:",
      left: 10, top: 91, width: 62, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: file, key: "commentField", title: "",
      left: 78, top: 91, width: 356, expands: true, bold: false, accessibilityLabel: "Comment")
    addField(to: file, key: nil, title: "Size:",
      left: 10, top: 113, width: 62, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: file, key: "fileSizeField", title: "",
      left: 78, top: 113, width: 356, expands: true, bold: false, accessibilityLabel: "Size")
    addField(to: file, key: nil, title: "Format:",
      left: 10, top: 135, width: 62, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: file, key: "fileFormatField", title: "",
      left: 78, top: 135, width: 356, expands: true, bold: false, accessibilityLabel: "Format")
    addField(to: file, key: nil, title: "Duration:",
      left: 10, top: 157, width: 62, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: file, key: "durationField", title: "",
      left: 78, top: 157, width: 356, expands: true, bold: false, accessibilityLabel: "Duration")
    addField(to: file, key: nil, title: "Chapters:",
      left: 10, top: 179, width: 62, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: file, key: "chaptersField", title: "",
      left: 78, top: 179, width: 356, expands: true, bold: false, accessibilityLabel: "Chapters")
    addField(to: file, key: nil, title: "Editions:",
      left: 10, top: 201, width: 62, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: file, key: "editionsField", title: "",
      left: 78, top: 201, width: 356, expands: true, bold: false, accessibilityLabel: "Editions")
    addSeparator(to: file, top: 54)
    addTab("File", content: file)

    let status = FlippedView(frame: NSRect(x: 0, y: 0, width: 444, height: 465))
    addField(to: status, key: nil, title: "A/V Sync Diff:",
      left: 10, top: 12, width: 131, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: status, key: "avsyncField", title: "",
      left: 147, top: 12, width: 287, expands: true, bold: false, accessibilityLabel: "A/V Sync Diff")
    addField(to: status, key: nil, title: "Total A/V Sync:",
      left: 10, top: 32, width: 131, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: status, key: "totalAvsyncField", title: "",
      left: 147, top: 32, width: 287, expands: true, bold: false, accessibilityLabel: "Total A/V Sync")
    addField(to: status, key: nil, title: "Dropped Frames:",
      left: 10, top: 52, width: 131, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: status, key: "droppedFramesField", title: "",
      left: 147, top: 52, width: 287, expands: true, bold: false, accessibilityLabel: "Dropped Frames")
    addField(to: status, key: nil, title: "Mistimed Frames:",
      left: 10, top: 72, width: 131, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: status, key: "mistimedFramesField", title: "",
      left: 147, top: 72, width: 287, expands: true, bold: false, accessibilityLabel: "Mistimed Frames")
    addField(to: status, key: nil, title: "Display FPS:",
      left: 10, top: 92, width: 131, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: status, key: "displayFPSField", title: "",
      left: 147, top: 92, width: 287, expands: true, bold: false, accessibilityLabel: "Display FPS")
    addField(to: status, key: nil, title: "Estimated Output FPS:",
      left: 10, top: 112, width: 131, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: status, key: "voFPSField", title: "",
      left: 147, top: 112, width: 287, expands: true, bold: false, accessibilityLabel: "Estimated Output FPS")
    addField(to: status, key: nil, title: "Estimated Disp FPS",
      left: 10, top: 132, width: 131, expands: false, bold: true, accessibilityLabel: nil)
    addField(to: status, key: "edispFPSField", title: "",
      left: 147, top: 132, width: 287, expands: true, bold: false, accessibilityLabel: "Estimated Disp FPS")
    addField(to: status, key: nil, title: "Watch",
      left: 10, top: 171, width: 40, expands: false, bold: true, accessibilityLabel: nil)
    addSeparator(to: status, top: 156)
    configureWatchTable()
    status.addSubview(watchTableContainerView)
    let add = Self.imageButton(NSImage.addTemplateName, target: target, action: addAction)
    add.setAccessibilityLabel("Add watch property")
    deleteButton.setAccessibilityLabel("Remove selected watch properties")
    status.addSubview(add)
    status.addSubview(deleteButton)
    watchTableContainerView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      watchTableContainerView.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: 12),
      watchTableContainerView.trailingAnchor.constraint(equalTo: status.trailingAnchor, constant: -12),
      watchTableContainerView.topAnchor.constraint(equalTo: status.topAnchor, constant: 197),
      watchTableContainerView.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -10),
      add.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: 12),
      add.bottomAnchor.constraint(equalTo: status.bottomAnchor, constant: -10),
      deleteButton.leadingAnchor.constraint(equalTo: add.trailingAnchor),
      deleteButton.centerYAnchor.constraint(equalTo: add.centerYAnchor)
    ])
    // Scroll the entire status page when its watch list exceeds the available height.
    // The table itself remains unscrolled so translucent headers cannot overlap rows.
    let statusScroll = NSScrollView()
    statusScroll.drawsBackground = false
    statusScroll.hasVerticalScroller = true
    statusScroll.autohidesScrollers = true
    statusScroll.documentView = status
    status.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      status.leadingAnchor.constraint(equalTo: statusScroll.contentView.leadingAnchor),
      status.topAnchor.constraint(equalTo: statusScroll.contentView.topAnchor),
      status.widthAnchor.constraint(equalTo: statusScroll.contentView.widthAnchor),
      status.heightAnchor.constraint(greaterThanOrEqualTo: statusScroll.contentView.heightAnchor),
      status.heightAnchor.constraint(greaterThanOrEqualToConstant: 465)
    ])
    let preferredHeight = status.heightAnchor.constraint(equalTo: statusScroll.contentView.heightAnchor)
    preferredHeight.priority = .defaultLow
    preferredHeight.isActive = true
    addTab("Status", content: statusScroll)
    tabView.selectTabViewItem(at: 0)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func makeToolbar() -> NSToolbar {
    let toolbar = NSToolbar(identifier: "InspectorToolbar")
    toolbar.allowsUserCustomization = false
    toolbar.autosavesConfiguration = false
    toolbar.displayMode = .iconOnly
    toolbarItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("InspectorTabs"))
    toolbarItem.view = tabButtonGroup
    toolbar.delegate = self
    return toolbar
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [toolbarItem.itemIdentifier]
  }
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarAllowedItemIdentifiers(toolbar)
  }
  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
               willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    identifier == toolbarItem.itemIdentifier ? toolbarItem : nil
  }

  private func addTab(_ title: String, content: NSView) {
    let item = NSTabViewItem(identifier: title)
    item.label = title
    content.autoresizingMask = [.width, .height]
    item.view = content
    tabView.addTabViewItem(item)
  }

  private func addField(to parent: NSView, key: String?, title: String,
                        left: CGFloat, top: CGFloat, width: CGFloat, expands: Bool,
                        bold: Bool, accessibilityLabel: String?) {
    let field = NSTextField(labelWithString: title)
    field.font = bold ? .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
                      : .systemFont(ofSize: NSFont.smallSystemFontSize)
    if title == "VIDEO" || title == "AUDIO" {
      field.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    } else if title == "Track:" {
      field.font = .systemFont(ofSize: NSFont.systemFontSize)
    }
    field.textColor = key == nil ? .secondaryLabelColor : .labelColor
    field.lineBreakMode = .byTruncatingTail
    field.cell?.isScrollable = true
    field.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(field)
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: left),
      field.topAnchor.constraint(equalTo: parent.topAnchor, constant: top)
    ])
    if expands {
      field.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -10).isActive = true
    } else {
      field.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
    if let key {
      fields[key] = field
      field.isSelectable = true
      if let accessibilityLabel, !accessibilityLabel.isEmpty { field.setAccessibilityLabel(accessibilityLabel) }
    }
  }

  private func addSeparator(to parent: NSView, top: CGFloat) {
    let line = NSBox()
    line.boxType = .separator
    line.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(line)
    NSLayoutConstraint.activate([
      line.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 12),
      line.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -12),
      line.topAnchor.constraint(equalTo: parent.topAnchor, constant: top)
    ])
  }

  private func configureWatchTable() {
    watchTableView.style = .fullWidth
    watchTableView.rowHeight = 17
    watchTableView.intercellSpacing = NSSize(width: 0, height: 2)
    watchTableView.backgroundColor = .clear
    watchTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    watchTableView.allowsColumnReordering = false
    watchTableView.allowsMultipleSelection = true
    watchTableView.allowsTypeSelect = false
    watchTableView.autosaveName = "InspectorWatchTable"
    watchTableView.setAccessibilityLabel("Watched mpv properties")
    for (id, title, width, maximum) in [("Key", "Name", 180.0, 1000.0), ("Value", "Value", 228.0, 10000.0)] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.title = title
      column.width = width
      column.minWidth = 120
      column.maxWidth = maximum
      column.isEditable = false
      watchTableView.addTableColumn(column)
    }
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.verticalScrollElasticity = .none
    scroll.horizontalScrollElasticity = .none
    scroll.documentView = watchTableView
    watchTableContainerView.addSubview(scroll)
    pin(scroll, to: watchTableContainerView)
  }

  static func watchCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier
    let text = NSTextField(labelWithString: "")
    text.isSelectable = true
    text.lineBreakMode = .byTruncatingTail
    text.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(text)
    cell.textField = text
    NSLayoutConstraint.activate([
      text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
      text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
      text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
    ])
    return cell
  }

  private static func imageButton(_ image: NSImage.Name, target: AnyObject, action: Selector) -> NSButton {
    let button = NSButton(image: NSImage(named: image)!, target: target, action: action)
    button.isBordered = false
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 16),
      button.heightAnchor.constraint(equalToConstant: 20)
    ])
    return button
  }

  private func pin(_ child: NSView, to parent: NSView, horizontal: CGFloat = 0, vertical: CGFloat = 0) {
    child.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: horizontal),
      child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -horizontal),
      child.topAnchor.constraint(equalTo: parent.topAnchor, constant: vertical),
      child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -vertical)
    ])
  }
}
