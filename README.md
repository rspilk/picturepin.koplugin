# PicturePin

A [KoReader](https://github.com/koreader/koreader) plugin: pin an image
from the book you're reading (e.g. a map) to a small persistent icon
that reopens it — movable, zoomable, resizable — without losing your
reading position.

Hold an inline image to preview it, choose to pin it, and an icon stays
on screen (across page turns and app restarts) to bring it back up
whenever you need it.

Fully patch-free: install is just this folder, on a real device or the
emulator, no core KoReader changes required.

## Install

Copy this whole folder (`picturepin.koplugin/`) into KoReader's
`plugins/` directory, then restart KoReader.

## Docs

- [`SPEC.md`](SPEC.md) — feature scope, design decisions, what's
  explicitly out of scope.
- [`PLAN.md`](PLAN.md) — phased implementation history.
