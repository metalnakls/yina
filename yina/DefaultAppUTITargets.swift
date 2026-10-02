//
//  DefaultAppUTITargets.swift
//  yina
//
//  Pure UTI selection for “Set as default application”.
//

import Foundation

enum DefaultAppUTITargets {
  struct ImportedType: Equatable {
    let identifier: String
    let conformsTo: [String]
    let extensions: [String]
  }

  /// Prefer each imported identifier plus one preferred UTI per extension.
  /// Expanding every UTI that claims an extension causes a prompt flood.
  static func identifiers(
    importedTypes: [ImportedType],
    checkedCategories: [String: Bool],
    preferredIdentifierForExtension: (String) -> String?
  ) -> Set<String> {
    var result = Set<String>()

    for type in importedTypes {
      let matchesCheckedCategory = checkedCategories.contains { category, checked in
        checked && type.conformsTo.contains(category)
      }
      guard matchesCheckedCategory else { continue }

      result.insert(type.identifier)
      for fileExtension in type.extensions {
        if let preferred = preferredIdentifierForExtension(fileExtension) {
          result.insert(preferred)
        }
      }
    }

    return result
  }

  static func parseImportedTypes(_ raw: [[String: Any]]) -> [ImportedType]? {
    var parsed: [ImportedType] = []

    for importedType in raw {
      guard
        let identifier = importedType["UTTypeIdentifier"] as? String,
        let conformsTo = importedType["UTTypeConformsTo"] as? [String],
        let tagSpecification = importedType["UTTypeTagSpecification"] as? [String: Any]
      else {
        return nil
      }

      let extensions: [String]
      if let values = tagSpecification["public.filename-extension"] as? [String] {
        extensions = values
      } else if let value = tagSpecification["public.filename-extension"] as? String {
        extensions = [value]
      } else {
        return nil
      }

      parsed.append(ImportedType(identifier: identifier,
                                 conformsTo: conformsTo,
                                 extensions: extensions))
    }

    return parsed
  }
}
