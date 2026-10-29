# Native UI guide

Use these steps for AppKit and SwiftUI interface changes.

## Implementation steps

1. **Record the current behavior.** Identify the system controls, window chrome,
   layout constraints, and user-visible states the change touches. Preserve
   native controls, titlebar, traffic lights, toolbar, proxy icon, materials,
   keyboard behavior, and accessibility unless the request says otherwise.
   **Done when** the existing behavior and the requested difference are clear.

2. **Choose a documented native API.** Use AppKit or SwiftUI controls, layout
   guides, constraints, and materials that provide the requested behavior. For
   content under a titlebar, use the documented full-size content layout guides.
   If a native implementation is unavailable or uncertain, ask the user before
   writing custom code. **Done when** the chosen API and its expected behavior
   are documented, or the user has answered the question about custom code.

3. **Keep metrics local and sourced.** Preserve existing app-specific metrics
   when they still fit. Group values with their owning surface and reuse a value
   only when it represents the same design decision. Use system sizing and
   spacing behavior where available. Get user approval before adding invented
   spacing or sizing values; never present yina-specific values as Apple
   standards. **Done when** every changed metric has an identified source and
   no unapproved value was added.

   Current OSC reference: `OSCDesignMetrics.dockedHorizontalInset` is
   `LayoutValue(16, 12)` and is shared by both docked horizontal edges;
   `floatingHorizontalInset` is 8 points between items. Floating outer horizontal
   padding follows AppKit’s `layoutMarginsGuide`. Docked vertical padding remains
   `LayoutValue(12, 8)`, floating vertical padding remains 8 points, and the
   docked slider uses `DockedOSCLayout.playSliderInset` at 6 points on top and
   bottom. These preserve existing yina design values.

4. **Implement and check the requested states.** Keep content aligned with
   constraints and layout guides. Check minimum, typical, and maximum supported
   sizes, appearance changes, keyboard navigation, VoiceOver order, resizing,
   and full-screen transitions when relevant. **Done when** each relevant state
   has been checked and the changed controls remain usable and aligned.

5. **Respect runtime limits and report evidence.** Follow any task restriction
   on launching yina or accessing personal media. When runtime validation is
   allowed, use fixtures only. A build or structural check does not prove live
   appearance or interaction. **Done when** the report names the checks run and
   explicitly marks unverified runtime, appearance, or accessibility behavior.

## Settled behavior and exception

- The welcome List's native scroll geometry may resize the bottom of its window.
  Keep its top anchored, retain the four-row minimum, and subtract scroll offset
  from the full measured scroll content, including its content insets, before
  applying the maximum window height. Preserve offset on data refresh.
  Resize and preserve the window top with one `setFrame` call, without forcing
  synchronous layout between a resize and a move. Use the native top scroll
  anchor for size changes so resizing does not reposition visible content.
  Native List scrolling, momentum and rubberbanding remain the sole scroll path.
  This approved window sizing is not permission for custom scrolling or blur.

- Playback overlays must yield to the native window size. Use AppKit's
  `dragThatCannotResizeWindow` for the OSC's preferred size and saved position;
  `defaultHigh` can enlarge the window and break portrait video sizing. Retain
  required viewport bounds. Verify with a real resizable `NSWindow`, because a
  fixed-parent view test cannot catch this interaction. See
  [portrait window sizing](portrait-window-sizing.md) for the reproduction and
  Apple references.
- Empty titlebar blur accessories must not request the window's initial width.
  Use the documented `.bottom` placement, leave the initial width at zero, and
  update only height when metrics change. AppKit owns the remaining dimension.
  Verify native blur and actual portrait playback together.

- The floating OSC uses the native button tint, adaptive primary time-label
  colors, and the native slider-thumb appearance without separate HDR tints.
  Watched progress remains white by explicit user preference. Docked HDR
  controls may tint the native thumb silhouette without replacing its shape.

## References

- [Apple HIG: Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [Apple HIG: Layout](https://developer.apple.com/design/human-interface-guidelines/layout/)
- [AppKit `NSWindow` style masks](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct)
- [AppKit `NSWindow.titlebarAppearsTransparent`](https://developer.apple.com/documentation/appkit/nswindow/titlebarappearstransparent)
