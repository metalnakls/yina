// xcrun swiftc iina/OSCExtendedDynamicRange.swift other/tests/osc-edr-smoke.swift -o /tmp/iina-osc-edr-smoke
// /tmp/iina-osc-edr-smoke
import Foundation

@main struct OSCEDRSmoke {
  static func main() throws {
    precondition(OSCExtendedDynamicRange.headroom(hdrEnabled: false,
                                                  currentDisplayHeadroom: 4,
                                                  potentialDisplayHeadroom: 8,
                                                  renderedContentHeadroom: 6) == 1)
    precondition(OSCExtendedDynamicRange.headroom(hdrEnabled: true,
                                                  currentDisplayHeadroom: 4,
                                                  potentialDisplayHeadroom: 8,
                                                  renderedContentHeadroom: 6) == 4)
    precondition(OSCExtendedDynamicRange.headroom(hdrEnabled: true,
                                                  currentDisplayHeadroom: 1,
                                                  potentialDisplayHeadroom: 8,
                                                  renderedContentHeadroom: 6) == 6)
    precondition(OSCExtendedDynamicRange.headroom(hdrEnabled: true,
                                                  currentDisplayHeadroom: 1,
                                                  potentialDisplayHeadroom: 4,
                                                  renderedContentHeadroom: 6) == 4)
    precondition(OSCExtendedDynamicRange.headroom(hdrEnabled: true,
                                                  currentDisplayHeadroom: 1,
                                                  potentialDisplayHeadroom: 8,
                                                  renderedContentHeadroom: 0) == 2)
    precondition(OSCExtendedDynamicRange.headroom(hdrEnabled: true,
                                                  currentDisplayHeadroom: 1,
                                                  potentialDisplayHeadroom: 1,
                                                  renderedContentHeadroom: 6) == 1)
    precondition(OSCExtendedDynamicRange.luminance(intensity: 0, headroom: 4) == 1)
    precondition(OSCExtendedDynamicRange.luminance(intensity: 0.5, headroom: 4) == 2.5)
    precondition(OSCExtendedDynamicRange.luminance(intensity: 1, headroom: 4) == 4)

    let translucent = try String(contentsOfFile: "iina/TranslucentView.swift", encoding: .utf8)
    precondition(translucent.contains("case aboveMaterial"))
    precondition(translucent.contains("if contentPlacement == .insideMaterial"))
    precondition(translucent.contains("addSubview(wrapper, positioned: .above, relativeTo: container)"))
    precondition(translucent.contains("container?.setOwnExtendedDynamicRange(enabled, headroom: headroom)"))

    let floatingOSC = try String(contentsOfFile: "iina/OSCFloatingView.swift", encoding: .utf8)
    precondition(floatingOSC.contains("contentPlacement: .aboveMaterial"))
    precondition(floatingOSC.contains("guard isDissolveFilterEnabled else { return }"))
    precondition(floatingOSC.contains("extendedDynamicRangeHeadroom > 1"))
    precondition(floatingOSC.contains("drawExtendedDynamicRangeImage"))
    precondition(floatingOSC.contains("imageRect.fill(using: .sourceAtop)"))

    let playSlider = try String(contentsOfFile: "iina/PlaySlider.swift", encoding: .utf8)
    precondition(playSlider.contains("FloatingPlaySliderCell"))
    precondition(playSlider.contains("floatingCell.extendedDynamicRangeHeadroom = newValue"))

    let mainWindow = try String(contentsOfFile: "iina/MainWindowController.swift", encoding: .utf8)
    precondition(mainWindow.contains("let enabled = player.info.hdrEnabled"))
    precondition(!mainWindow.contains("player.info.hdrAvailable && player.info.hdrEnabled"))
    precondition(mainWindow.contains("setContentExtendedDynamicRange(enabled, headroom: headroom)"))
    precondition(mainWindow.contains("setDissolveFilterEnabled(!enabled)"))

    print("PASS: floating OSC controls use a separate adaptive EDR plane above AppKit material.")
  }
}
