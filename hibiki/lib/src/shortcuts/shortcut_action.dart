enum ShortcutScope {
  reader,
  home,
  global,
  audiobook,
  video,
  // TODO-700 T6：摇杆与 dpad 解耦后，dpad 四向成为「可绑触发键」，落在独立的
  // gamepad 作用域（自成 co-active 组，不与 reader/home 等任何组冲突）。摇杆固定
  // 做方向焦点移动、永不经注册表，故没有对应 action——只有 dpad 进这个 scope。
  gamepad,
  // TODO-1066：桌面「app 外全局查词」的系统级触发热键作用域。此 scope 的动作
  // **不经 resolveKeyboard / 页面派发**，而是由 GlobalLookupController 直接读其
  // 绑定注册到操作系统级 hotkey_manager（默认 Ctrl+Alt+D）。它跨页面常驻、不与
  // 任何应用内页面的键盘绑定竞争，故自成独立 co-active 组，冲突检测只扫自己，
  // 绝不与 global/home 等页面 scope 互相牵连。仅桌面（Windows）有意义。
  globalExternal;

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
      // gamepad（dpad 四向）是独立 co-active 组：dpad 绑定永不与 reader/home 的
      // 按钮跨组冲突，冲突检测只扫 gamepad 自身。
      case gamepad:
        return const <ShortcutScope>[gamepad];
      // globalExternal（系统级 app 外查词热键）是独立 co-active 组：它不经页面
      // 派发，只由 controller 注册到操作系统热键；冲突检测只扫自己，永不与任何
      // 应用内 scope 牵连。
      case globalExternal:
        return const <ShortcutScope>[globalExternal];
    }
  }
}

enum ShortcutAction {
  // Reader
  readerPageForward(ShortcutScope.reader, 'reader_page_forward'),
  readerPageBackward(ShortcutScope.reader, 'reader_page_backward'),
  readerToggleChrome(ShortcutScope.reader, 'reader_toggle_chrome'),
  // TODO-728：直接打开阅读器设置菜单（外观/进度/目录的快速设置面板，执行体
  // = _showAppearanceSheet）。与 readerToggleChrome 正交——后者只 show/hide 底栏，
  // 这个一键弹出设置面板，省去先开底栏再焦点移到齿轮按钮的来回。默认键盘 T。
  readerOpenMenu(ShortcutScope.reader, 'reader_open_menu'),
  readerDismissDict(ShortcutScope.reader, 'reader_dismiss_dict'),
  readerToggleBookmark(ShortcutScope.reader, 'reader_toggle_bookmark'),
  readerToggleFurigana(ShortcutScope.reader, 'reader_toggle_furigana'),
  readerLookupAtCursor(ShortcutScope.reader, 'reader_lookup_at_cursor'),
  readerShiftLookup(ShortcutScope.reader, 'reader_shift_lookup'),
  readerCreateCardFromPopup(
      ShortcutScope.reader, 'reader_create_card_from_popup'),
  // TODO-700 T7：「进入选字查词光标」可改键（默认手柄 A + 键盘 Enter）。这是
  // enter-trigger 的绑定真相源：reader 写死判 A/Enter 进光标的分支改读它的绑定
  // （见 reader_caret_router.isEnterTrigger*）。默认与旧硬编码一致，行为不变，只
  // 是变成可改键。注意它与 readerLookupAtCursor 默认同绑 A/Enter——这是有意的并行
  // 别名（一个管「进光标」、一个管「进光标后查词/激活」），enter-trigger 不经
  // resolveKeyboard 故无枚举顺序歧义，no-shadow 守卫显式排除它。
  readerEnterCaret(ShortcutScope.reader, 'reader_enter_caret'),

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
  // 内封章节上/下一章（TODO-424，默认 PageUp / PageDown）：seek 到相邻章起点，无章节
  // 时 no-op。与「上/下一句字幕」(Ctrl+←/→) 正交——后者按字幕 cue，这里按容器章节。
  videoPreviousChapter(ShortcutScope.video, 'video_previous_chapter'),
  videoNextChapter(ShortcutScope.video, 'video_next_chapter'),
  videoEscape(ShortcutScope.video, 'video_escape'),
  // TODO-840 Part B：字幕遮蔽模式（不遮蔽/模糊/隐藏，见 VideoSubtitleObscureMode）。
  // videoCycleSubtitleObscure 在三态间循环；videoToggleSubtitleHide 直接开/关「隐藏
  // 主字幕」。与历史的 videoToggleSubtitleBlur（B，开/关模糊）正交并存——后者保留
  // 不破坏旧绑定（Never break userspace）。三者执行体都在 video_player_shortcuts。
  videoCycleSubtitleObscure(
      ShortcutScope.video, 'video_cycle_subtitle_obscure'),
  videoToggleSubtitleHide(ShortcutScope.video, 'video_toggle_subtitle_hide'),

  // Gamepad（TODO-700 T6）：dpad 四向作为可绑触发键。默认各绑对应 dpad 键，执行体
  // = 通用方向焦点移动（与摇杆同效果，但摇杆固定走 onStickMove 通道、不经注册表，
  // 故只有 dpad 进注册表）。用户可把 dpad 方向键改绑别的功能，或把别的键绑成方向
  // 焦点移动。
  dpadUp(ShortcutScope.gamepad, 'dpad_up'),
  dpadDown(ShortcutScope.gamepad, 'dpad_down'),
  dpadLeft(ShortcutScope.gamepad, 'dpad_left'),
  dpadRight(ShortcutScope.gamepad, 'dpad_right'),

  // Global external lookup (TODO-1066)：桌面「app 外全局查词」的系统级触发热键。
  // 执行体是 GlobalLookupController（读本 action 的键盘绑定注册到 hotkey_manager，
  // 默认 Ctrl+Alt+D），而非页面/媒体 _executeShortcutAction 派发——它是唯一一个
  // 走操作系统热键、不经 resolveKeyboard 的 action。设置页据此渲染出可改键行，
  // 修复「app 外查词快捷键没办法设置」。
  globalExternalLookup(ShortcutScope.globalExternal, 'global_external_lookup');

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
