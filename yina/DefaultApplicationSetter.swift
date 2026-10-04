//
//  DefaultApplicationSetter.swift
//  yina
//
//  Sets YINA as the default handler for selected media UTIs.
//

import AppKit
import UniformTypeIdentifiers

enum DefaultApplicationSetter {
  /// Collect UTI identifiers for the checked media categories using preferred types only.
  static func targetIdentifiers(
    utiImportedTypes: [[String: Any]],
    checkedCategories: [String: Bool]
  ) -> Set<String>? {
    guard let importedTypes = DefaultAppUTITargets.parseImportedTypes(utiImportedTypes) else {
      return nil
    }

    return DefaultAppUTITargets.identifiers(
      importedTypes: importedTypes,
      checkedCategories: checkedCategories,
      preferredIdentifierForExtension: { fileExtension in
        UTType(filenameExtension: fileExtension)?.identifier
      }
    )
  }

  /// Apply default-app registration and call back only after consent requests finish.
  static func setAsDefault(
    identifiers: Set<String>,
    completion: @escaping (_ successCount: Int, _ failedCount: Int) -> Void
  ) {
    let sortedIdentifiers = identifiers.sorted()
    guard !sortedIdentifiers.isEmpty else {
      completion(0, 0)
      return
    }

    let appURL = Bundle.main.bundleURL
    let group = DispatchGroup()
    let lock = NSLock()
    var successCount = 0
    var failedCount = 0

    for identifier in sortedIdentifiers {
      guard let contentType = UTType(identifier) else {
        Logger.log("Unknown UTI: \(identifier.quoted)", level: .error)
        lock.lock()
        failedCount += 1
        lock.unlock()
        continue
      }

      Logger.log("Setting default for UTI: \(identifier.quoted)", level: .verbose)
      group.enter()
      NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: contentType) { error in
        lock.lock()
        if let error {
          Logger.log("Failed for \(identifier.quoted): \(error.localizedDescription)", level: .error)
          failedCount += 1
        } else {
          successCount += 1
        }
        lock.unlock()
        group.leave()
      }
    }

    group.notify(queue: .main) {
      completion(successCount, failedCount)
    }
  }
}
