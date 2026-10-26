import Foundation

/// Language matching is independent of track IDs, which change between files.
enum SubtitleLanguagePairing {
  struct Candidate {
    let id: Int
    let language: String?
    let isDefault: Bool
    let isForced: Bool
  }

  static func language(_ value: String?) -> String? {
    guard var value = value?.lowercased().replacingOccurrences(of: "_", with: "-"),
          !value.isEmpty, value != "und" else { return nil }
    let bibliographic = ["fre": "fra", "ger": "deu", "dut": "nld", "chi": "zho",
                         "cze": "ces", "gre": "ell", "rum": "ron", "slo": "slk", "wel": "cym"]
    guard let first = value.split(separator: "-").first else { return nil }
    let base = String(first)
    if let replacement = bibliographic[base] { value = replacement }
    return Locale.Language(identifier: value).languageCode?.identifier(.alpha2) ?? base
  }

  static func selection(audioLanguage: String?, overrides: [String: String],
                        candidates: [Candidate]) -> Int? {
    guard let audio = language(audioLanguage) else { return nil }
    if overrides[audio] == "off" { return 0 }
    let desired = language(overrides[audio]) ?? audio
    return candidates.filter { language($0.language) == desired }.sorted {
      if $0.isForced != $1.isForced { return !$0.isForced }
      if $0.isDefault != $1.isDefault { return $0.isDefault }
      return $0.id < $1.id
    }.first?.id
  }
}
