# Reader And Video Settings Pane Layout

## Goal

Improve the wide reader settings layout shown in the reported screenshot and
keep the video settings menu visually consistent with it.

The approved direction is option B:

- narrow the supporting pane;
- keep the detail pane inset equally from the center divider and the dialog's
  right edge;
- preserve the existing colors, typography, controls, categories, and
  interaction behavior.

## Scope

Apply the layout to both wide in-media settings surfaces:

- `ReaderQuickSettingsSheet`;
- `VideoQuickSettingsSheet`.

The video supporting pane must continue to expose all four existing categories:

- playback;
- shaders;
- mpv;
- subtitles.

No settings are added, removed, or moved between categories.

## Layout

Wide layouts continue to use `MaterialSupportingPaneLayout`, but these modal
surfaces use a narrower supporting-pane width than the full-page Settings
screen. The modal-specific width should be explicit and shared by reader and
video sheets rather than changing the global supporting-pane sizing behavior.

Each pane owns its horizontal padding:

- the supporting pane keeps appropriate outer and divider-side breathing room;
- the primary pane uses equal start and end insets;
- the center divider remains fixed between the panes.

This removes the current structure where one outer padding wraps both panes and
the reader appearance card can touch the divider while retaining space at the
right edge.

## Responsive Behavior

The existing `640` wide-layout breakpoint remains unchanged.

At or above the breakpoint:

- the supporting pane remains fixed while the primary pane scrolls;
- the reader categories and video categories remain visible;
- switching categories replaces only the keyed primary subtree.

Below the breakpoint:

- the existing single-column navigation and pushed detail page remain
  unchanged;
- no modal width or padding change should affect mobile behavior.

## Testing

Add or update focused widget/static tests to verify:

- the modal sheets use the approved narrower supporting-pane width;
- the primary pane receives symmetric horizontal insets;
- reader and video wide layouts keep their supporting menus visible;
- the video menu still contains playback, shaders, mpv, and subtitles;
- the supporting pane stays fixed while the detail pane scrolls;
- narrow layouts still push detail pages.

Run the focused reader/video settings tests and the shared platform layout
tests. Formatting and `git diff --check` are required before the implementation
commit.
