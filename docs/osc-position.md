# Floating control position

The floating OSC stores its vertical position relative to the displayed video
image. Changing the surrounding letterbox area no longer changes that position
when the image stays at the same screen coordinates and size. Rotation uses the
same cached display aspect ratio as the player window.

Existing saved positions migrate when video geometry first becomes available.
The controls remain draggable, including deliberate placement in a letterbox
area, and remain constrained to the available viewport.

`python3 other/tests/osc-geometry-smoke.py` exercises the production geometry,
including equal image rectangles in different viewports, migration, portrait
rotation, and small windows. Live fullscreen transition animation remains a
separate runtime check; the supplied screenshots were historical references.
