# PicturePin — feature spec

## What it does

In an EPUB, hold an inline image — this already opens KoReader's existing
fullscreen preview (zoom/pan), via `ReaderHighlight:onHold`. That preview
gains a "Pin" button alongside Scale/Rotate/Close. Pinning it makes a
small persistent icon appear in a fixed screen corner, staying visible
across page turns and app restarts (per book). Tapping the icon reopens
the pinned image, without disturbing the current reading position.

Motivating use case: reading a fantasy novel (e.g. Wheel of Time) with a
world map somewhere in the front matter — pin the map once, then glance
at it from any page without losing your place.

## Fully patch-free: no core-file changes at all

Earlier iterations of this plugin patched `frontend/ui/widget/
imageviewer.lua` (to add an extra button, accept a smaller custom size,
and disable its internal full-screen centering) and one line of
`frontend/apps/reader/modules/readerhighlight.lua` (to wire that button
into the existing hold-image preview). That worked, but only on a
custom-built KoReader with those patches applied — not portable to a
stock install (a real device or a fresh emulator) without either
maintaining a fork or shipping a `patches/` user-patch file alongside
the plugin.

The current design needs neither: `plugins/picturepin.koplugin/` is the
entire install, on any stock KoReader.

- **Detecting a hold on an image**: the plugin registers its own
  `hold`-gesture touch zone (overriding `readerhighlight_hold`, KoReader's
  own hold-to-select-text zone). If `document:getImageFromPosition` finds
  an image there, the plugin shows it in a **stock, unmodified**
  fullscreen `ImageViewer` and returns `true` (handled). If not, it
  returns `false`, and the gesture falls through to
  `readerhighlight_hold` exactly as it would without this plugin —
  normal text-selection-by-hold is untouched.
- **Offering to pin**: once that stock preview closes (Close button, tap
  outside, multiswipe — however the user dismisses it), the plugin shows
  a plain confirm box asking whether to pin the image just viewed.
- **The persistent icon**: new UI surface with no existing gesture route,
  so it's the one thing that needs its own touch zone regardless of
  design — see `pinicon.lua`.
- **The movable/zoomable panel** (opened by tapping the icon): instead of
  reusing `ImageViewer` (which assumes it's shown fullscreen and fights
  back at every turn when forced into a smaller floating size — see
  `pannableimage.lua`'s own comments for the specifics), this is a small
  purpose-built zoomable/pannable widget, adapting `ImageViewer`'s
  scale/pan math but built as a fixed-footprint widget from the start.
  It delegates actual image rendering to `ImageWidget`
  (`ui/widget/imagewidget.lua`), a generic widget with no fullscreen
  assumptions of its own, reused as-is.

Reopening the pinned image (tapping the icon) needs to work while the
reader is showing a *different* page than where the image was pinned --
that's the whole point. `document:getImageFromPosition` only hit-tests
against whatever page is currently rendered, so naively reusing the pin
position while on the wrong page would fail or return the wrong image.
To avoid that without risking the reading position, PicturePin caches
the already-decoded bitmap in memory at pin time (lifted straight off the
still-open preview widget) and reuses that cached bitmap for the rest of
the session -- no document navigation involved at all. Only after a cold
start (app or book just reopened, cache empty) does it fall back to
briefly jumping the document to the pinned xpointer, re-extracting the
image, and jumping straight back, once, before showing anything.

## MVP scope (v1)

- EPUB (`self.ui.rolling`) only — no PDF/DjVu. `getImageFromPosition` (the
  API the existing hold-preview already uses) only exists for CreDocument.
- Single pinned-image slot — pinning a new image replaces the old one.
- Pin icon is fixed-position (dogear-style corner icon), not draggable —
  avoids re-registering touch zones on every drag.
- Only the pinned image *reference* persists per-book (via
  `doc_settings`), not panel position/size — panel opens at a sensible
  default each time.

## Explicitly out of scope / rejected, not deferred

- Pinning an image reached indirectly via a text link/footnote (e.g. "see
  Fig. 3" linking to an image elsewhere in the book). There is no clean
  Lua API for resolving "does this link point at an image resource" —
  only a fragile HTML-scraping workaround via `getHTMLFromXPointer`. A
  robust version would need a small crengine C++ addition. Considered,
  rejected for this project.
- PDF/DjVu support.
- Multiple simultaneous pinned images / pin history.
- Draggable pin icon.
- Persisted panel size/position across sessions.
- Animated-image/SVG special-casing beyond whatever `ImageViewer` already
  does for free.

## Stretch (only if v1 feels too limited once used)

- Resizable panel.
- Draggable icon.
- Panel geometry persistence.

See `PLAN.md` in this directory for the phased implementation breakdown.
