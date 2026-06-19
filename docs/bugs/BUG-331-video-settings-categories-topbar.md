## BUG-331 · video settings big categories shown in the left pane, not a top bar
- **Report**: 2026-06-19 (user: TODO-556)
- **Truth**: TRUE bug. The user asked for the video settings panel's big
  categories (playback / subtitle / decode / image-quality / danmaku /
  controls) to live in a TOP bar, but the wide-window layout actually rendered
  them in a LEFT master-detail pane (the source comment even claimed "top
  horizontal chip row" while the code had silently regressed to a left
  supporting pane). Book settings intentionally keep the left master-detail.
- **Root cause** `hibiki/lib/src/media/video/video_quick_settings_sheet.dart`:
  the wide branch of `build()` used
  `MaterialSupportingPaneLayout(supportingSide: SupportingPaneSide.start)` with
  `_buildWidePane()` rendering a vertical `HibikiListItem` category list on the
  LEFT and the detail on the RIGHT. That is a left master-detail, not a top bar.
- **[x] (1) Root-cause fix** - rebuilt the wide branch as a `Column`:
  a fixed top horizontal category chip bar (`_buildTopCategoryBar`, using
  `SingleChildScrollView(scrollDirection: Axis.horizontal)` + `Row` of
  `HibikiSelectableChip`) pinned above a `Divider`, with the detail in an
  `Expanded` full-width `SingleChildScrollView` that scrolls independently.
  Removed `MaterialSupportingPaneLayout` / `SupportingPaneSide.start` /
  `_buildWidePane` / the dead `_videoSettingsSupportingPaneWidth` width helpers.
  Narrow-window push and book settings (reader_quick_settings_sheet.dart) are
  untouched. Added an `allowLabelOverflow` flag to the shared
  `HibikiSelectableChip` so the top-bar category labels stay fully readable
  (Material ChoiceChip otherwise caps the label width and ellipsizes long
  English labels like "Image enhancement" at UI scale 2.0). Commit: <pending>.
- **[x] (2) Automated test** - updated/added widget + source guards in
  `hibiki/test/pages/video_quick_settings_sheet_test.dart` (category chips sit
  above the detail; top bar stays fixed while detail scrolls; labels not
  ellipsized at scale 2.0; new TODO-556 group asserting top-bar chips + no
  left master-detail) and rewrote the layout asserts in
  `hibiki/test/pages/video_player_settings_master_detail_guard_test.dart` to
  lock the top-bar invariant. Test files: as above.
- **Notes**: real-device verification (open a video, open the settings panel on
  a wide window, confirm categories are a top chip row with full-width detail
  below) still pending - headless widget tests + analyze pass.
