// xcrun swiftc -parse-as-library yina/SubtitleLanguagePairing.swift other/tests/subtitle-language-pairing-smoke.swift -o /tmp/yina-language-pairing-smoke
import Foundation

@main struct PairingSmoke {
  static func main() {
    typealias Candidate = SubtitleLanguagePairing.Candidate
    let tracks = [Candidate(id: 1, language: "eng", isDefault: true, isForced: false),
                  Candidate(id: 2, language: "rus", isDefault: false, isForced: false),
                  Candidate(id: 3, language: "ru", isDefault: true, isForced: true)]
    func select(_ audio: String?, _ pairs: [String: String] = [:]) -> Int? {
      SubtitleLanguagePairing.selection(audioLanguage: audio, overrides: pairs, candidates: tracks)
    }
    precondition(select("ru-RU") == 2, "Prefer full subtitles over a forced-only track")
    precondition(select("eng") == 1)
    precondition(select("rus", ["ru": "en"]) == 1, "Respect an explicit Russian audio / English subtitle pair")
    precondition(select("eng", ["ru": "en"]) == 1)
    precondition(select("rus", ["ru": "en"]) == 1, "Switching back restores the explicit pair")
    precondition(select("ru", ["ru": "off"]) == 0, "Remember an explicit None selection")
    precondition(select("ja") == nil, "Do not invent a fallback when matching subtitles are missing")
    precondition(select(nil) == nil)
    precondition(select("und") == nil)
    precondition(select("---") == nil)
    precondition(SubtitleLanguagePairing.language("fre") == "fr")
    precondition(SubtitleLanguagePairing.language("de_DE") == "de")
    print("PASS: language aliases, preferred tracks, explicit mixed-language pairs, None, and missing metadata")
  }
}
