# In-Book Reader Settings Design

## Goal

Rewrite the in-book reader settings panel around the way a user reads, not
around historical implementation buckets. The panel should keep Hoshi reader
state compatible, expose high-frequency reading comfort controls immediately,
and move deeper controls into clear groups.

## Current Problem

The current in-book panel mixes three different jobs:

- Reader settings: typography, layout, reader behavior.
- Book navigation: table of contents, search, bookmarks, favorites, jumps.
- Session actions: add bookmark, switch lyrics mode, exit reader.

That is a bad data structure. The user sees a menu shaped by old TTU and
audiobook implementation history instead of a small model of what they are
trying to do while reading.

## Home Layout

The first screen is not a full settings list. It has four parts:

1. Status
   - Current chapter progress.
   - Current page progress when available.
   - Current audio cue or follow state when an audiobook is active.

2. Quick controls
   - Font size.
   - Line height.
   - Theme.
   - Paginated or continuous mode.

3. Destinations
   - Appearance.
   - Layout.
   - Reading controls.
   - Location.
   - Audiobook, only when audio is available; otherwise show only the existing
     audio import or bind entry point where appropriate.

4. Fixed actions
   - Add bookmark.
   - Switch lyrics/book mode when audiobook lyrics mode is available.
   - Exit reader.

Quick controls must stay tiny. They are not a duplicate settings system. A
control belongs there only when it is high-frequency, immediately visible, and
safe to adjust back.

## Destination Structure

### Appearance

- Theme.
- Font size.
- Line height.
- Text indentation.
- Page margins.
- Custom fonts entry.
- Custom theme entry.
- Per-book CSS entry when an extracted book directory is available.

### Layout

- Horizontal or vertical writing.
- Paginated or continuous mode.
- Spread mode: off, on, auto.
- Spread direction: RTL or LTR.
- Columns per page.
- Furigana mode: show, hide, partial, toggle.
- Vertical text orientation.
- Text justification.
- Vertical kerning.
- Font VPAL.
- Prioritize reader styles.

### Reading Controls

- Highlight on tap.
- Tap empty area to hide chrome.
- Volume button page turning.
- Volume key sentence navigation.
- Invert volume buttons.
- Invert swipe direction.
- Dismiss swipe sensitivity.
- Volume button page turning speed.
- Auto-read on lookup.
- Pause audio on lookup.
- Keep screen awake.

### Location

This is deliberately not named "Settings". It contains navigation tools:

- Table of contents.
- Bookmarks.
- Favorite sentences.
- Full-book search.
- Character-position jump.

### Audiobook

Shown as a full destination only when an audiobook controller exists.

- Playback volume.
- Playback speed.
- A/V sync.
- Pause on image.
- Media notification.
- Lyrics mode display controls.
- Lyrics font size and margins.
- Floating lyric overlay.
- Floating lyric font size.
- Replace or import audio when supported.

## Compatibility Rules

- Do not rename persisted reader preference keys.
- Do not change profile snapshot semantics.
- Current EPUB rendering work stays in the Hoshi reader path.
- Legacy `reader_ttu` or `Ttu*` names are compatibility boundaries, not a
  reason to route current-reader work into old TTU assets.
- The quick controls and deep settings must write the same underlying
  `ReaderSettings` state.
- A setting that changes layout may reload the current chapter, but style-only
  settings should live-update when the current reader path supports it.
- Navigation tools may stay in the same panel, but they must live under
  `Location`, not under reader settings.

## Review Checklist

- The first screen contains only status, four quick controls, destinations, and
  fixed actions.
- Font size, line height, theme, and paginated/continuous mode are the only
  quick controls.
- Location tools are not mixed into Appearance, Layout, or Reading Controls.
- Audiobook-only controls do not appear as empty rows for text-only books.
- No existing preference key or reader position behavior is broken.
- The implementation keeps function signatures typed and avoids page-local
  duplicate state where shared `ReaderSettings` state already exists.
