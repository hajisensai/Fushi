# Hibiki patches

This package vendors `media_kit_video` 2.0.1 (unchanged from pub.dev except for
the patches below) so Hibiki can carry fixes that are not yet upstream.

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

## TODO-364: publish real controls visibility (`visibilityNotifier`)

`lib/media_kit_video_controls/src/controls/material_desktop.dart` and
`lib/media_kit_video_controls/src/controls/material.dart`, both the theme data
classes (`MaterialDesktopVideoControlsThemeData` /
`MaterialVideoControlsThemeData`) and their control States.

Hibiki disables the built-in `SubtitleView` and renders its own subtitle overlay
that dodges the bottom controls bar. Upstream keeps the controls' `visible` state
(and its auto-hide `Timer`) private in the control State and exposes no callback,
notifier, or public API. Hibiki used to keep a *separate* mirror of visibility
with its own timer; the two timers drifted out of phase and the subtitle dodge
reversed direction under concurrent input (e.g. the bar animating up/down while
the user also taps / keys). Users reported "the subtitle goes up/down the wrong
way when I do something while the seek bar appears/disappears".

The patch adds an optional `final ValueNotifier<bool>? visibilityNotifier;` to
both theme data classes (wired through their constructors and `copyWith`), and a
`void _publishVisibility()` helper in each control State that pushes the State's
real `visible` into that notifier after **every** `visible` mutation
(onHover / onEnter / onExit / onTap / mount timer / seek-end timer). The initial
(mount) visibility is published via `addPostFrameCallback` to avoid re-entering a
host listener's `setState` during `didChangeDependencies`. When no notifier is
injected the behaviour is identical to pub.dev (no publishing).

Hibiki injects one notifier through both control themes and derives its subtitle
dodge from that single source of truth (`_mediaKitControlsVisible` →
`_applyControlsVisibilityFromMediaKit` in `video_hibiki_page.dart`), deleting its
old mirror + second timer.

Source-guard test: `hibiki/test/third_party/media_kit_video_visibility_notifier_guard_test.dart`.

## TODO-565: notify host on user seek-bar interaction (`onSeekStart`)

`lib/media_kit_video_controls/src/controls/material_desktop.dart` and
`lib/media_kit_video_controls/src/controls/material.dart`, both the theme data
classes (`MaterialDesktopVideoControlsThemeData` /
`MaterialVideoControlsThemeData`) and the seek-bar wiring in their control
States.

The subtitle list lets the user tap a row to jump to that cue
(`VideoPlayerController.skipToCue`). The jump seek lands a little before the cue
(BUG-259 pre-roll), so the controller keeps a short-lived "active jump target"
snapshot + in-flight grace window to snap the highlight to the tapped row until
the seek truly lands (TODO-565). Every Hibiki-initiated seek funnels through
`VideoPlayerController.seekMs`, which clears that snapshot first — *except* the
progress (seek) bar, which drives `controller(context).player.seek(...)` directly
inside media_kit and bypasses `seekMs`. If the user drags the bar to an earlier
cue *during* that grace window, the next tick reads the new (earlier) position,
the grace is not yet exhausted, and the stale target snaps the highlight back to
the originally tapped row for ~2s.

Upstream's seek bar exposes no host-level seek hook; its internal
`onSeekStart`/`onSeekEnd` are hard-wired to the controls' auto-hide timer and are
not surfaced through the theme. The patch adds an optional
`final void Function()? onSeekStart;` to both theme data classes (wired through
their constructors and `copyWith`), and merges `_theme(context).onSeekStart?.call()`
into the existing internal `onSeekStart` callback of each seek bar
(`MaterialSeekBar` / `MaterialDesktopSeekBar`). When no callback is injected the
behaviour is identical to pub.dev.

Hibiki injects `() => controller.clearSeekTargetSnap()` through both control
themes (`_desktopControlsTheme` / `_mobileControlsTheme` in
`video_hibiki_page.dart`), so starting a progress-bar drag invalidates the jump
snapshot just like every other seek entry point.

Source-guard test: `hibiki/test/third_party/media_kit_video_seekbar_guard_test.dart`.
