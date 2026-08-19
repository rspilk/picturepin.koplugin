# PicturePin — implementation plan

See `SPEC.md` in this directory for feature scope and rationale. This
file tracks the phased build-out; each phase is one commit with its own
manual test pass in the emulator.

## Dev environment

Native Windows isn't supported for building/running the KoReader
emulator. Dev happens in a dedicated WSL2 distro named `koreaderdev`
(kept separate from any other WSL distro on the machine). Once set up:

```
wsl -d koreaderdev
cd ~/koreader
./kodev run        # launch the emulator (WSLg forwards the window to Windows)
./kodev run -b      # same, but skip the build-freshness check for faster iteration
```

Editing any `.koplugin/*.lua` file needs no rebuild — plain Lua is
interpreted at load time. `./kodev wbuilder` (`tools/wbuilder.lua`) is a
lighter harness for testing a single widget in isolation.

## Phases 0-4: original plan, later reworked (see below)

Phases 0-4 were originally built reusing KoReader's `ImageViewer`
directly, which required three small patches to `frontend/ui/widget/
imageviewer.lua` (optional extra button, custom width/height, disabling
its internal full-screen centering) and one line in `frontend/apps/
reader/modules/readerhighlight.lua` (wiring a "Pin" button into the
existing hold-image preview). This worked and was fully tested, but
only installs on a custom-built KoReader with those patches applied —
not portable to a stock install without maintaining a fork or shipping
a separate `patches/` user-patch file.

Once portability became a stated goal, this was reworked (see "Phases
0-4, reworked" below) to need zero core-file changes: a custom
lightweight zoomable/pannable widget (`pannableimage.lua`) instead of a
forced-smaller `ImageViewer`, and the plugin's own `hold`-gesture touch
zone (falling through to `readerhighlight_hold` for non-image holds)
instead of patching `readerhighlight.lua`. `frontend/ui/widget/
imageviewer.lua` and `frontend/apps/reader/modules/readerhighlight.lua`
are back to byte-identical with upstream `master`.

**Phase 0 — Scaffold** (done)
- `_meta.lua`, minimal `main.lua` (menu entry only, no pin behavior),
  `SPEC.md`, `PLAN.md`.
- Commit: `picturepin: scaffold plugin skeleton + spec docs`

## Phases 0-4, reworked: fully patch-free

**Persistent icon** (done)
- `pinicon.lua` (`IconWidget` in a `LeftContainer`, top-left corner,
  fixed position — opposite the reading-progress dogear), painted via
  `ReaderView:registerViewModule()` (the documented plugin extension
  point for this — reserved direct-insertion, like `readerdogear.lua`
  uses, is for modules `readerview.lua` itself owns), gated on its own
  `visible` flag. Its own touch zone in `main.lua` (`picturepin_tap_icon`,
  overriding `readerhighlight_tap`/`tap_top_left_corner`/
  `readerfooter_tap`/`tap_forward`/`tap_backward`) reopens the pinned
  image on tap.

**Pin hookup, patch-free** (done)
- `main.lua` registers its own `hold`-gesture touch zone
  (`picturepin_hold`, overriding `readerhighlight_hold`, KoReader's own
  hold-to-select-text zone). If `document:getImageFromPosition` finds an
  image at that position, shows it in a stock, unmodified fullscreen
  `ImageViewer` — otherwise returns `false`, falling through to
  `readerhighlight_hold` exactly as without this plugin (normal
  text-selection-by-hold unaffected).
- Once that preview closes (however it's dismissed — Close button, tap
  outside, multiswipe), a `ConfirmBox` offers to pin the image just
  viewed. Confirming saves a re-fetchable reference (page/xpointer, not
  the raw bitmap) via `doc_settings`, per the `readerannotation.lua`
  pattern, and caches the already-decoded bitmap in memory for the rest
  of the session.
- Tapping the icon reuses that cached bitmap directly — no document
  navigation, so it can never disturb the reading position. Only on a
  cold start (cache empty after app/book reopen) does
  `_refetchPinnedImage()` briefly jump to the pinned xpointer,
  re-extract, and jump back, once, before showing anything.
- Test: hold an image → stock preview opens; close it any way → "Pin
  this image?" confirm box; confirm → toast, icon appears; turn pages →
  icon persists; tap icon → same image reopens, reading position
  unaffected; close/reopen book, tap icon again → still works (cold-start
  refetch path); pin a different image → replaces the first; holding on
  plain text still behaves exactly as before.
- Commits: `picturepin: rework to be fully patch-free and portable`
  (+ the revert commit restoring `imageviewer.lua`/`readerhighlight.lua`
  to pristine).

**Movable, zoomable panel** (done)
- New `pannableimage.lua`: a small purpose-built zoomable/pannable
  widget, adapting `ImageViewer`'s scale/pan math (`onSpread`/`onPinch`/
  `onPan`/`onPanRelease`/`_applyNewScaleFactor`) but written as a
  fixed-footprint widget from the start, instead of fighting
  `ImageViewer`'s fullscreen assumptions. Delegates actual rendering to
  `ImageWidget` (`ui/widget/imagewidget.lua`), a generic widget with no
  fullscreen assumptions, reused as-is. Its own `on_change` hook lets the
  owning panel force a correct repaint after a zoom-driven re-render —
  needed because `UIManager:setDirty(widget, ...)` only ever matches
  *top-level* window-stack entries (confirmed in `uimanager.lua`'s own
  code comment), so a widget nested several levels deep must repaint via
  whatever's actually on the stack, not itself. Panning doesn't need this:
  `ImageWidget:panBy()` already schedules its own repaint via the robust
  `setDirty("all", ...)` sentinel, which works regardless of nesting.
- `pinnedimagepanel.lua`: wraps `PannableImage` plus a small
  always-visible Close button (`OverlapGroup`, top-right corner) inside a
  `MovableContainer`, sized to the image's own aspect ratio within an
  80%x80% screen bounding box (not a fixed box regardless of shape, which
  left visible dead space around non-square images). Centered on open;
  hold + drag to reposition from there. No gesture tug-of-war to resolve
  here — neither `PannableImage` nor the Close button claim Hold/
  HoldRelease/Touch/MultiSwipe, so `MovableContainer`'s own claim on those
  (its drag gesture) goes uncontested.
- Test: tap icon → panel opens over the current page, fitted tightly to
  the image, reading position underneath untouched; hold + drag to
  reposition (applies on release, matching how `MovableContainer`/
  `ImageViewer` panning already works elsewhere in KoReader — not a live
  drag-follow); pinch/spread to zoom (unverified on the desktop emulator,
  no way to simulate two-finger input with a single mouse — but reuses
  the same `ImageWidget` rendering path already confirmed working via
  `ImageViewer`'s own Scale/Original-size toggle during earlier testing);
  tap the ✕ to close.
- Commits: `picturepin: rework to be fully patch-free and portable`,
  `picturepin: fit panel to image aspect ratio, eliminating dead space`.

**Phase 5 (stretch) — Resizable panel**
- `MovableContainer` assumes fixed content width/height, so implement
  resize as rebuild-inner-widget-at-new-size via a drag handle, not live
  resize-in-place. `PannableImage` (unlike `ImageViewer`) is our own
  widget, so this doesn't need any further external patching either.
- Not yet started.

**Phase 6 (polish, as time allows)**
- Explicit "unpin" action, verify behavior across screen rotation/resize.
- Not yet started.

## Git workflow

- Branch: `feature/picturepin`.
- One commit per phase/fix, each independently revertable.
- Everything lives in `plugins/picturepin.koplugin/` — no core-file
  changes, no separate `patches/` file. Install is just this directory,
  on a real device or the emulator.
