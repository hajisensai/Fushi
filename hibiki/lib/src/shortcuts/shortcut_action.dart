enum ShortcutScope {
  reader,
  home,
  global,
  audiobook,
}

enum ShortcutAction {
  // Reader
  readerPageForward(ShortcutScope.reader, 'reader_page_forward'),
  readerPageBackward(ShortcutScope.reader, 'reader_page_backward'),
  readerToggleChrome(ShortcutScope.reader, 'reader_toggle_chrome'),
  readerDismissDict(ShortcutScope.reader, 'reader_dismiss_dict'),
  readerToggleBookmark(ShortcutScope.reader, 'reader_toggle_bookmark'),

  // Home
  homeTabBooks(ShortcutScope.home, 'home_tab_books'),
  homeTabDict(ShortcutScope.home, 'home_tab_dict'),
  homeTabSettings(ShortcutScope.home, 'home_tab_settings'),
  homeFocusSearch(ShortcutScope.home, 'home_focus_search'),

  // Global
  globalBack(ShortcutScope.global, 'global_back'),

  // Audiobook
  audiobookPlayPause(ShortcutScope.audiobook, 'audiobook_play_pause'),
  audiobookNextSentence(ShortcutScope.audiobook, 'audiobook_next_sentence'),
  audiobookPrevSentence(ShortcutScope.audiobook, 'audiobook_prev_sentence');

  const ShortcutAction(this.scope, this.key);

  final ShortcutScope scope;
  final String key;

  static ShortcutAction? fromKey(String key) {
    for (final action in values) {
      if (action.key == key) return action;
    }
    return null;
  }

  static List<ShortcutAction> actionsForScope(ShortcutScope scope) {
    return values.where((a) => a.scope == scope).toList(growable: false);
  }
}
