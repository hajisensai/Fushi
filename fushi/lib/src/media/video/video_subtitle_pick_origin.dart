/// Where a primary subtitle-source pick on the video page came from. Decides
/// where the extraction progress of that pick shows; the progress state itself
/// stays single (the page's `_subtitleLoadingShown`, which also greys out the
/// page's subtitle rows and feeds the companion snapshot).
enum VideoSubtitlePickOrigin {
  /// The player itself: its settings sheet / subtitle list, shortcuts, the
  /// remote control (desktop / phone) and `fushi_cli`. Progress shows in the
  /// player's settings sheet, opened on the subtitle category when it is not
  /// already showing.
  player,

  /// The second-screen companion's video panel. Progress shows on the panel
  /// (video snapshot `subtitleLoading`); the player does not open its sheet.
  companion;

  /// Whether the player opens its settings sheet on the subtitle category to
  /// show this pick's extraction progress. [subtitlePanelOpen] = the sheet
  /// already shows the subtitle category.
  bool opensPlayerSettings({required bool subtitlePanelOpen}) =>
      this == VideoSubtitlePickOrigin.player && !subtitlePanelOpen;
}
