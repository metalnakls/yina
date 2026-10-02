//
//  FontPickerWindowController.swift
//  yina
//
//  Created by lhc on 25/10/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa
import SwiftUI

private enum FontPickerLocalizedString {
  static let windowTitle = value("F0z-JX-Cv5.title", fallback: "Choose a Font")
  static let chooseFont = value("TSI-Wt-Edx.title", fallback: "Choose a font:")
  static let searchPlaceholder = value("DwS-ve-MLJ.placeholderString", fallback: "Type to filter…")
  static let family = value("2Ld-md-U2v.headerCell.title", fallback: "Family")
  static let typeface = value("fez-Z3-dnL.headerCell.title", fallback: "Typeface")
  static let preview = value("XsF-e7-fXF.title", fallback: "Preview")
  static let previewText = value("qwM-r2-9ki.title", fallback: "Test")
  static let manualEntry = value("waR-LB-484.title", fallback: "Or enter the font name:")
  static let cancel = value("Ihd-HK-wsv.title", fallback: "Cancel")
  static let ok = value("S5m-SJ-Ggp.title", fallback: "OK")

  private static func value(_ key: String, fallback: String) -> String {
    NSLocalizedString(key,
                      tableName: "FontPickerWindowController",
                      bundle: .main,
                      value: fallback,
                      comment: "")
  }
}

@MainActor
private final class FontPickerModel: ObservableObject {
  struct Family: Identifiable, Hashable {
    let name: String
    let localizedName: String

    var id: String { name }
  }

  struct Typeface: Identifiable, Hashable {
    let name: String
    let localizedName: String

    var id: String { name }
  }

  @Published var families: [Family] = []
  @Published var searchText = "" {
    didSet { reconcileSelection() }
  }
  @Published var selectedFamily: String? {
    didSet {
      guard selectedFamily != oldValue else { return }
      updateTypefaces(selectFirst: true)
    }
  }
  @Published var typefaces: [Typeface] = []
  @Published var selectedTypeface: String? {
    didSet {
      guard selectedTypeface != oldValue, let selectedTypeface else { return }
      enteredFontName = selectedTypeface
    }
  }
  @Published var enteredFontName = "" {
    didSet {
      guard enteredFontName != oldValue else { return }
      matchEnteredFont()
    }
  }

  private var isSynchronizing = false

  var displayedFamilies: [Family] {
    guard !searchText.isEmpty else { return families }
    return families.filter {
      $0.localizedName.localizedCaseInsensitiveContains(searchText)
    }
  }

  var selectedFontName: String {
    enteredFontName.isEmpty ? Constants.String.mpvDefaultFont : enteredFontName
  }

  var previewFont: NSFont {
    guard let font = NSFont(name: enteredFontName, size: 24) else {
      return .systemFont(ofSize: 24)
    }
    return font
  }

  func loadFonts() {
    let manager = NSFontManager.shared
    families = manager.availableFontFamilies
      .filter { !$0.hasPrefix(".") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { Family(name: $0, localizedName: manager.localizedName(forFamily: $0, face: nil)) }
      .sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
    reconcileSelection()
  }

  func select(_ fontName: String) {
    enteredFontName = fontName == Constants.String.mpvDefaultFont ? "" : fontName
    if enteredFontName.isEmpty {
      selectedFamily = nil
      selectedTypeface = nil
      typefaces = []
    }
  }

  private func reconcileSelection() {
    guard !isSynchronizing else { return }
    if let selectedFamily, !displayedFamilies.contains(where: { $0.name == selectedFamily }) {
      isSynchronizing = true
      self.selectedFamily = nil
      selectedTypeface = nil
      typefaces = []
      isSynchronizing = false
    }
    matchEnteredFont()
  }

  private func updateTypefaces(selectFirst: Bool) {
    guard !isSynchronizing else { return }
    guard let selectedFamily,
          let family = displayedFamilies.first(where: { $0.name == selectedFamily }) else {
      typefaces = []
      selectedTypeface = nil
      return
    }

    typefaces = Self.typefaces(for: family)
    if selectFirst {
      selectedTypeface = typefaces.first?.name
    } else if let selectedTypeface, !typefaces.contains(where: { $0.name == selectedTypeface }) {
      self.selectedTypeface = nil
    }
  }

  private func matchEnteredFont() {
    guard !isSynchronizing, !enteredFontName.isEmpty else { return }

    for family in displayedFamilies {
      let familyTypefaces = Self.typefaces(for: family)
      guard familyTypefaces.contains(where: { $0.name == enteredFontName }) else { continue }

      isSynchronizing = true
      selectedFamily = family.name
      typefaces = familyTypefaces
      selectedTypeface = enteredFontName
      isSynchronizing = false
      return
    }
  }

  private static func typefaces(for family: Family) -> [Typeface] {
    guard let members = FixedFontManager.typefaces(forFontFamily: family.name) as? [[Any]] else {
      return []
    }
    return members.compactMap { member in
      guard member.indices.contains(1),
            let name = member[0] as? String,
            let localizedName = member[1] as? String else { return nil }
      return Typeface(name: name, localizedName: localizedName)
    }
  }
}

private struct FontPickerView: View {
  @ObservedObject var model: FontPickerModel
  let confirm: () -> Void
  let cancel: () -> Void

  @FocusState private var isSearchFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(FontPickerLocalizedString.chooseFont)

      TextField(FontPickerLocalizedString.searchPlaceholder, text: $model.searchText)
        .textFieldStyle(.roundedBorder)
        .focused($isSearchFocused)
        .accessibilityLabel(FontPickerLocalizedString.searchPlaceholder)

      HStack(spacing: 0) {
        fontList(title: FontPickerLocalizedString.family,
                 values: model.displayedFamilies,
                 selection: $model.selectedFamily,
                 confirmsOnDoubleClick: false) { family in
          family.localizedName
        }

        Divider()

        fontList(title: FontPickerLocalizedString.typeface,
                 values: model.typefaces,
                 selection: $model.selectedTypeface,
                 confirmsOnDoubleClick: true) { typeface in
          typeface.localizedName
        }
      }
      .frame(minHeight: 260)
      .background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .stroke(Color(nsColor: .separatorColor))
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(FontPickerLocalizedString.preview)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(FontPickerLocalizedString.previewText)
          .font(Font(model.previewFont))
          .lineLimit(1)
          .frame(maxWidth: .infinity, minHeight: 40)
          .background(Color(nsColor: .textBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 5))
          .overlay {
            RoundedRectangle(cornerRadius: 5)
              .stroke(Color(nsColor: .separatorColor))
          }
          .accessibilityLabel(FontPickerLocalizedString.preview)
          .accessibilityValue(FontPickerLocalizedString.previewText)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(FontPickerLocalizedString.manualEntry)
        TextField(Constants.String.mpvDefaultFont, text: $model.enteredFontName)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel(FontPickerLocalizedString.manualEntry)
          .onSubmit(confirm)
      }

      HStack(spacing: 8) {
        Spacer()
        Button(FontPickerLocalizedString.cancel, action: cancel)
          .keyboardShortcut(.cancelAction)
        Button(FontPickerLocalizedString.ok, action: confirm)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(12)
    .frame(minWidth: 458, minHeight: 496)
    .onAppear {
      isSearchFocused = true
    }
  }

  private func fontList<Value: Identifiable & Hashable>(
    title: String,
    values: [Value],
    selection: Binding<Value.ID?>,
    confirmsOnDoubleClick: Bool,
    label: @escaping (Value) -> String
  ) -> some View where Value.ID == String {
    VStack(alignment: .leading, spacing: 0) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)

      Divider()

      List(values, selection: selection) { value in
        Text(label(value))
          .lineLimit(1)
          .tag(value.id)
          .onTapGesture(count: 2) {
            if confirmsOnDoubleClick {
              confirm()
            }
          }
      }
      .listStyle(.plain)
      .accessibilityLabel(title)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

@MainActor
class FontPickerWindowController: NSWindowController {
  private let model = FontPickerModel()

  var finishedPicking: ((String) -> Void)?

  override init(window: NSWindow?) {
    super.init(window: window)
  }

  convenience init() {
    let window = CommonWindow(
      contentRect: NSRect(x: 0, y: 0, width: 458, height: 524),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = FontPickerLocalizedString.windowTitle
    window.isReleasedWhenClosed = false
    if !AppEnvironment.isCleanStart { window.setFrameAutosaveName("YINAFontPickerWindow") }

    self.init(window: window)
    window.contentViewController = NSHostingController(rootView: FontPickerView(
      model: model,
      confirm: { [weak self] in self?.finishPicking() },
      cancel: { [weak self] in self?.cancelPicking() }
    ))
    model.loadFonts()
    Logger.log("FontPickerWindow init done")
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func select(_ fontString: String) {
    Logger.log("FontPickerWindow selecting \(fontString.quoted)")
    model.select(fontString)
  }

  override func cancelOperation(_ sender: Any?) {
    cancelPicking()
  }

  private func finishPicking() {
    let callback = finishedPicking
    finishedPicking = nil
    dismissPicker()
    callback?(model.selectedFontName)
  }

  private func cancelPicking() {
    finishedPicking = nil
    dismissPicker()
  }

  private func dismissPicker() {
    guard let window else { return }
    if let sheetParent = window.sheetParent {
      sheetParent.endSheet(window)
    } else {
      close()
    }
  }
}
