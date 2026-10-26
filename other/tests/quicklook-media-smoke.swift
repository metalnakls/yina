// Compile: xcrun swiftc -parse-as-library other/tests/quicklook-media-smoke.swift -o /tmp/yina-quicklook-smoke
// Run with synthetic media paths after installing yina and enabling its Media Extensions.
// This checks actual AVFoundation video/audio decoding, not just bundle signatures.
import AVFoundation
import Foundation
import MediaToolbox
import VideoToolbox

@main
struct QuickLookMediaSmoke {
  static func main() async {
    guard CommandLine.arguments.count > 1 else {
      print("Usage: quicklook-media-smoke <synthetic-video> [...]")
      exit(64)
    }
    MTRegisterProfessionalVideoWorkflowFormatReaders()
    VTRegisterProfessionalVideoWorkflowVideoDecoders()
    // A stuck extension must fail the check instead of hanging the test runner.
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.schedule(deadline: .now() + 60)
    watchdog.setEventHandler {
      print("FAIL: media decoding did not finish within 60 seconds")
      exit(1)
    }
    watchdog.resume()
    var failures = 0
    for path in CommandLine.arguments.dropFirst() {
      do {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else {
          throw NSError(domain: "Smoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "No positive duration"])
        }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first, let audioTrack = audioTracks.first else {
          throw NSError(domain: "Smoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing video or audio track"])
        }
        let reader = try AVAssetReader(asset: asset)
        let video = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        let audio = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        let videoProvider = reader.outputProvider(for: video)
        let audioProvider = reader.outputProvider(for: audio)
        try reader.start()
        var videoFrames = 0
        var audioSamples = 0
        var videoFinished = false
        var audioFinished = false
        while !videoFinished || !audioFinished {
          if !videoFinished {
            if let sample = try await videoProvider.next() {
              let validPixels = sample.withUnsafeSampleBuffer { buffer in
                guard let image = CMSampleBufferGetImageBuffer(buffer) else { return false }
                return CVPixelBufferGetWidth(image) > 0 && CVPixelBufferGetHeight(image) > 0
              }
              guard validPixels else {
                throw NSError(domain: "Smoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "No decoded pixels"])
              }
              videoFrames += 1
            } else { videoFinished = true }
          }
          if !audioFinished {
            if let sample = try await audioProvider.next() {
              audioSamples += sample.withUnsafeSampleBuffer { CMSampleBufferGetNumSamples($0) }
            } else { audioFinished = true }
          }
        }
        guard reader.status == .completed, videoFrames > 0, audioSamples > 0 else {
          throw reader.error ?? NSError(domain: "Smoke", code: 4, userInfo: [NSLocalizedDescriptionKey: "Incomplete decoding"])
        }
        let generator = AVAssetImageGenerator(asset: asset)
        let (image, _) = try await generator.image(at: CMTime(seconds: duration.seconds / 2, preferredTimescale: 600))
        guard image.width > 0, image.height > 0 else {
          throw NSError(domain: "Smoke", code: 5, userInfo: [NSLocalizedDescriptionKey: "No seek thumbnail"])
        }
        print("PASS: \(URL(fileURLWithPath: path).lastPathComponent): \(videoFrames) video frames, \(audioSamples) audio samples, seek image \(image.width)×\(image.height)")
      } catch {
        failures += 1
        print("FAIL: \(URL(fileURLWithPath: path).lastPathComponent): \(error)")
      }
    }
    watchdog.cancel()
    exit(failures == 0 ? 0 : 1)
  }
}
