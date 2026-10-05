//
//  FileSize.swift
//  yina
//
//  Created by lhc on 26/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Foundation

struct FloatingPointByteCountFormatter {

  enum PrefixFactor: Int, CustomStringConvertible {
    case none = 1
    
    case k = 1_000
    case m = 1_000_000
    case g = 1_000_000_000
    
    case ki = 0b1_0000000000
    case mi = 0b1_0000000000_0000000000
    case gi = 0b1_0000000000_0000000000_0000000000
    
    // Keep these in sorted order
    static let decimalPrefixes: [PrefixFactor] = [.none, .k, .m, .g]
    static let binaryPrefixes: [PrefixFactor] = [.none, .ki, .mi, .gi]

    var description: String {
      switch self {
      case .none: return ""
      case .k: return "K"
      case .m: return "M"
      case .g: return "G"
      case .ki: return "Ki"
      case .mi: return "Mi"
      case .gi: return "Gi"
      }
    }
  }
  
  enum CountStyle {
    case decimal
    case binary
    
    var prefixFactors: [PrefixFactor] {
      switch self {
      case .decimal:
        return PrefixFactor.decimalPrefixes
      case .binary:
        return PrefixFactor.binaryPrefixes
      }
    }
  }

  /// `NumberFormatter` initialisation builds locale data and is expensive relative to the rest of
  /// this function, which runs on the buffer indicator's update path. One formatter is cached per
  /// digit count instead of constructing one per call.
  private static let formatterLock = NSLock()
  private static let formatterCache: [Int: NumberFormatter] = (0...4).reduce(into: [:]) { result, digits in
    let formatter = NumberFormatter()
    formatter.maximumFractionDigits = digits
    result[digits] = formatter
  }

  private static func formatter(forDigits digits: Int) -> NumberFormatter {
    formatterLock.lock()
    defer { formatterLock.unlock() }
    return formatterCache[digits] ?? formatterCache[2]!
  }

  static func string(fromByteCount byteCount: Int, prefixedBy prefixFactor: PrefixFactor = .none, digits: Int = 2, countStyle: CountStyle = .decimal) -> String {
    let bytes = byteCount * prefixFactor.rawValue
    let formatter = formatter(forDigits: digits)

    if let prefixFactor = countStyle.prefixFactors.reversed().first(where: { bytes >= $0.rawValue }),
      let value = formatter.string(from: NSNumber(value: Double(bytes) / Double(prefixFactor.rawValue))) {
      return "\(value) \(prefixFactor)"
    } else {
      return "0 "
    }
  }

}
