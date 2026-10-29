# Track controls

Audio, video, and subtitle pickers contain real tracks. Explicit enable controls
turn each stream on or off; selecting an already selected row keeps that track.
Primary and secondary subtitle pickers disable the track selected in the other
picker, and secondary subtitles start off for new preferences. Missing or
conflicting secondary tracks are cleared when the track list changes.

Subtitle visibility and language pairing keep the existing app-wide preferences.
Audio and video track selection keep the existing per-file mpv behavior. This
change does not introduce folder-specific persistence.

The subtitle-language-pairing fixture covers availability and conflict rules.
The native Playback Settings fixture checks the resulting view and layout.
