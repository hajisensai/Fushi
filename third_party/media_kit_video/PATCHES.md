# Hibiki patches

This package vendors `media_kit_video` 2.0.1 (unchanged from pub.dev except for
the patch below) so Hibiki can carry a fix for a use-after-dispose crash in the
desktop seek bar that is not yet fixed upstream.

## BUG-235: seek bar `onPointerUp` use-after-dispose crash

`lib/media_kit_video_controls/src/controls/material_desktop.dart`,
`MaterialDesktopSeekBarState`.

Upstream `onPointerUp()` (and `onPointerMove()`) unconditionally call
`controller(context).player.seek(...)`. `controller(context)` is
`VideoStateInheritedWidget.of(context)`, which dereferences `State.context`.

When the controls subtree is torn down while a seek-bar drag is in progress —
which Hibiki does on fullscreen enter/exit and on episode switch via
`VideoControlsFocusGate` (`hibiki/lib/.../video_hibiki_page.dart`) — the pointer
release lands on a disposed `State`, and `context` is null. The crash users hit:

```text
FlutterError: Null check operator used on a null value
  at MaterialDesktopSeekBarState.onPointerUp (material_desktop.dart:987)
```

The State already guards `setState` with `if (mounted)`, but the two pointer
handlers that dereference `controller(context)` had no such guard. The patch
adds `if (!mounted) return;` to the top of both `onPointerUp()` and
`onPointerMove()`, matching the existing `mounted` guard style. `onPointerDown()`
only calls `setState` (already guarded), so it is left unchanged.

Source-guard test: `hibiki/test/third_party/media_kit_video_seekbar_guard_test.dart`.
