//
//  HardwareDecodeCapabilities.swift
//  yina
//
//  Created by low-batt on 5/23/24.
//  Copyright © 2024 lhc. All rights reserved.
//

import Foundation
import VideoToolbox

/// Cache containing information about the hardware decoding capabilities of this Mac.
///
/// It is desirable to cache this information because the [Video Toolbox](https://developer.apple.com/documentation/videotoolbox)
/// method  [VTIsHardwareDecodeSupported](https://developer.apple.com/documentation/videotoolbox/vtishardwaredecodesupported(_:))
/// is long running and should not be called on the main thread. Instead another thread is used and the information is cached for when
/// code that is running on the main thread needs it.
class HardwareDecodeCapabilities {
  /// The `HardwareDecodeCapabilities` singleton object.
  static let shared = HardwareDecodeCapabilities()

  /// The hardware decoding capabilities of this Mac will be checked for the codecs in this list.
  private let codecs = [
    kCMVideoCodecType_AppleProRes422,
    kCMVideoCodecType_AppleProRes422HQ,
    kCMVideoCodecType_AppleProRes422LT,
    kCMVideoCodecType_AppleProRes422Proxy,
    kCMVideoCodecType_AppleProRes4444,
    kCMVideoCodecType_AppleProRes4444XQ,
    kCMVideoCodecType_AppleProResRAW,
    kCMVideoCodecType_AppleProResRAWHQ,
    kCMVideoCodecType_AV1,
    kCMVideoCodecType_VP9]

  private let lock = NSLock()
  private var initializationStarted = false

  /// Cache containing a map from video codec to whether hardware decoding is supported.
  private var supported: [CMVideoCodecType: Bool] = [:]

  /// Check the hardware decoding capabilities of this Mac and cache the results.
  ///
  /// As checking the capabilities takes a long time it is performed asynchronously. See `isHardwareDecodeSupported` for details.
  /// - Important: This method **must** be called before `isSupported` is called and only be called **once**.
  func checkCapabilities() {
    lock.lock()
    guard !initializationStarted else {
      lock.unlock()
      // Internal error. This method must only be called once.
      Logger.fatal("HardwareDecodeCapabilities is already initialized")
    }
    initializationStarted = true
    lock.unlock()
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      for codec in codecs {
        let result = isHardwareDecodeSupported(codec)
        lock.lock()
        supported[codec] = result
        lock.unlock()
      }
    }
  }

  /// Whether this Mac supports hardware decoding for the given video codec.
  /// - Parameter codecType: The video codec as a
  ///     [CMVideoCodecType](https://developer.apple.com/documentation/coremedia/cmvideocodectype).
  /// - Returns: The cached result, or `true` while the asynchronous probe is
  ///   pending so mpv can use its normal software fallback without delaying startup.
  func isSupported(_ codecType: CMVideoCodecType) -> Bool {
    guard codecs.contains(codecType) else {
      // Internal error. This codec must not be in the list of codecs above.
      Logger.fatal("HardwareDecodeCapabilities is missing support for codec \(codecType)")
    }
    lock.lock()
    let started = initializationStarted
    let result = supported[codecType]
    lock.unlock()
    guard started else {
      Logger.fatal("HardwareDecodeCapabilities.checkCapabilities has not been called")
    }
    // While probing, keep the codec on mpv's hardware whitelist. FFmpeg can
    // fall back to software; a later player uses the completed cached answer.
    return result ?? true
  }

  /// Whether this Mac supports hardware decoding for the given video codec.
  /// - Parameter codecType: The video codec as a
  ///     [CMVideoCodecType](https://developer.apple.com/documentation/coremedia/cmvideocodectype).
  /// - Returns: true` if hardware decoding is supported; `false` otherwise.
  /// - Important: This method calls
  ///     [VTIsHardwareDecodeSupported](https://developer.apple.com/documentation/videotoolbox/vtishardwaredecodesupported(_:)),
  ///     which if called on the main thread will cause Xcode to report: "This method should not be called on the main thread as it may
  ///     lead to UI unresponsiveness". Use a different thread to call this method. Do not call `isHardwareDecodeSupported`
  ///     from the main thread.
  private func isHardwareDecodeSupported(_ codecType: CMVideoCodecType) -> Bool {
    VTRegisterSupplementalVideoDecoderIfAvailable(codecType)
    return VTIsHardwareDecodeSupported(codecType)
  }

  private init() {}
}
