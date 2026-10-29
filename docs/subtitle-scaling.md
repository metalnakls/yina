# Subtitle scaling

The built-in **Scale subtitles with video size** setting maps to both mpv scaling
options. When enabled, plain-text subtitle size follows the displayed video
image instead of the full viewport, so changing letterboxing alone does not
change the font. When disabled, mpv uses its constant-size mode.

Explicit advanced `sub-scale-by-window` or `sub-scale-with-window` settings keep
their own behavior. User font, scale, and embedded subtitle styling remain
independent choices. The shared preference observer registers once even when
one preference updates both mpv options.

The older screenshots motivated this regression check; they are not evidence
of the current installed rendering. Fullscreen animation and actual styled
subtitle appearance still require runtime validation.

The generated-media pixel fixture (`other/tests/subtitle-scale-pixel-smoke.py`)
renders one 1280 × 720 black video with an SRT caption into 1280 × 720 and
1280 × 900 targets. Both targets show the same picture size; the taller target
only adds letterboxing. With `sub-scale-by-window=yes` and
`sub-scale-with-window=no`, measured glyph height stays at 35 pixel rows in
both targets. The reverse mapping also stays at 35 rows. The former combined
`yes/yes` mapping grows from 35 to 44 rows. This is a synthetic libmpv render
check with the matching rebuilt library bundle, not a measurement of the
installed app's fullscreen transition.
