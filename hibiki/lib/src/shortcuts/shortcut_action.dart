enum ShortcutScope {
  reader,
  home,
  global,
  audiobook,
  video;

  // Scopes that are resolved together on the same page. The reader page
  // resolves reader + audiobook bindings; the home page resolves home + global.
  // Because the page tries these scopes in sequence, a single physical key can
  // only ever trigger one of them, so a binding shared across a co-active group
  // is a real conflict (the later scope silently never fires). Conflict
  // detection must therefore scan the whole group, not just one scope. This is
  // the single source of truth both the pages and the registry rely on.
  List<ShortcutScope> get coactiveScopes {
    switch (this) {
      case reader:
      case audiobook:
        return const <ShortcutScope>[reader, audiobook];
      case home:
      case global:
        return const <ShortcutScope>[home, global];
      // The video player page is a standalone surface: it resolves only its own
      // bindings, so the video scope is its own co-active group. Conflict
      // detection therefore scans just video.
      case video:
        return const <ShortcutScope>[video];
    }
  }
}

enum ShortcutAction {
  // Reader
  readerPageForward(ShortcutScope.reader, 'reader_page_forward'),
  readerPageBackward(ShortcutScope.reader, 'reader_page_backward'),
  readerToggleChrome(ShortcutScope.reader, 'reader_toggle_chrome'),
  readerDismissDict(ShortcutScope.reader, 'reader_dismiss_dict'),
  readerToggleBookmark(ShortcutScope.reader, 'reader_toggle_bookmark'),
  readerToggleFurigana(ShortcutScope.reader, 'reader_toggle_furigana'),
  readerLookupAtCursor(ShortcutScope.reader, 'reader_lookup_at_cursor'),
  readerShiftLookup(ShortcutScope.reader, 'reader_shift_lookup'),
  readerCreateCardFromPopup(
      ShortcutScope.reader, 'reader_create_card_from_popup'),

  // Home
  homeTabBooks(ShortcutScope.home, 'home_tab_books'),
  homeTabDict(ShortcutScope.home, 'home_tab_dict'),
  homeTabSettings(ShortcutScope.home, 'home_tab_settings'),
  homeTabPrev(ShortcutScope.home, 'home_tab_prev'),
  homeTabNext(ShortcutScope.home, 'home_tab_next'),
  homeFocusSearch(ShortcutScope.home, 'home_focus_search'),

  // Global
  globalBack(ShortcutScope.global, 'global_back'),
  globalScrollPageDown(ShortcutScope.global, 'global_scroll_page_down'),
  globalScrollPageUp(ShortcutScope.global, 'global_scroll_page_up'),

  // Audiobook
  audiobookPlayPause(ShortcutScope.audiobook, 'audiobook_play_pause'),
  audiobookNextSentence(ShortcutScope.audiobook, 'audiobook_next_sentence'),
  audiobookPrevSentence(ShortcutScope.audiobook, 'audiobook_prev_sentence'),
  // 鼠标中键点句 → 跳到该句并播放。位置型动作，运行时不走
  // _executeShortcutAction，而是 onPointerSeek 经 resolveMouse 判定后定位执行。
  audiobookSeekToClickedSentence(
      ShortcutScope.audiobook, 'audiobook_seek_clicked_sentence'),

  // Video player (TODO-134): migrated out of the hard-coded
  // buildVideoPlayerShortcuts map so they live in the remappable registry and
  // show up in the shortcut settings page alongside the other scopes. The
  // executed behaviour is unchanged; only the key lookup now goes through the
  // registry. Defaults match the previous asbplayer/mpv-style bindings.
  videoTogglePlayPause(ShortcutScope.video, 'video_toggle_play_pause'),
  videoPlay(ShortcutScope.video, 'video_play'),
  videoPause(ShortcutScope.video, 'video_pause'),
  videoPreviousSubtitle(ShortcutScope.video, 'video_previous_subtitle'),
  videoNextSubtitle(ShortcutScope.video, 'video_next_subtitle'),
  videoSeekBackward(ShortcutScope.video, 'video_seek_backward'),
  videoSeekForward(ShortcutScope.video, 'video_seek_forward'),
  videoToggleShaderCompare(ShortcutScope.video, 'video_toggle_shader_compare'),
  videoVolumeUp(ShortcutScope.video, 'video_volume_up'),
  videoVolumeDown(ShortcutScope.video, 'video_volume_down'),
  videoToggleMute(ShortcutScope.video, 'video_toggle_mute'),
  videoSpeedUp(ShortcutScope.video, 'video_speed_up'),
  videoSpeedDown(ShortcutScope.video, 'video_speed_down'),
  videoResetSpeed(ShortcutScope.video, 'video_reset_speed'),
  videoPreviousFrame(ShortcutScope.video, 'video_previous_frame'),
  videoNextFrame(ShortcutScope.video, 'video_next_frame'),
  videoScreenshot(ShortcutScope.video, 'video_screenshot'),
  videoToggleFullscreen(ShortcutScope.video, 'video_toggle_fullscreen'),
  videoToggleSubtitleList(ShortcutScope.video, 'video_toggle_subtitle_list'),
  videoToggleImmersiveLock(ShortcutScope.video, 'video_toggle_immersive_lock'),
  videoToggleSubtitleBlur(ShortcutScope.video, 'video_toggle_subtitle_blur'),
  videoToggleFavoriteSentence(
      ShortcutScope.video, 'video_toggle_favorite_sentence'),
  videoReplayCurrentSubtitle(
      ShortcutScope.video, 'video_replay_current_subtitle'),
  // 重播上一句（TODO-378，BUG-287）：纯句子跳转到上一条 cue 起点并播放，**不**退化成
  // 回退几秒。与 videoPreviousSubtitle（Ctrl+←，gap 太远时退化时间 seek，BUG-185/TODO-085）
  // 语义不同，是两个独立功能；TODO-328 误当重复删掉，此处恢复。
  videoReplayPreviousSubtitle(
      ShortcutScope.video, 'video_replay_previous_subtitle'),
  videoShowFavoriteSentences(
      ShortcutScope.video, 'video_show_favorite_sentences'),
  // 内封章节上/下一章（TODO-424，默认 PageUp / PageDown）：seek 到相邻章起点，无章节
  // 时 no-op。与「上/下一句字幕」(Ctrl+←/→) 正交——后者按字幕 cue，这里按容器章节。
  videoPreviousChapter(ShortcutScope.video, 'video_previous_chapter'),
  videoNextChapter(ShortcutScope.video, 'video_next_chapter'),
  videoEscape(ShortcutScope.video, 'video_escape');

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
