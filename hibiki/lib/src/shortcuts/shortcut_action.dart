enum ShortcutScope {
  reader,
  home,
  global,
  audiobook,
  video,
  // 漫画阅读器（mokuro 页图 + OCR 文本层）。与 reader 分开是因为动作集不同：漫画
  // 没有章节/振假名/有声书，翻页是整页跨页步进而非文字流分页，且左右键要按跨页
  // 方向（日漫默认 rtl）校正。
  manga,
  // TODO-700 T6：摇杆与 dpad 解耦后，dpad 四向成为「可绑触发键」，落在独立的
  // gamepad 作用域（自成 co-active 组，不与 reader/home 等任何组冲突）。摇杆固定
  // 做方向焦点移动、永不经注册表，故没有对应 action——只有 dpad 进这个 scope。
  gamepad,
  // TODO-1066：桌面「app 外全局查词」的系统级触发热键作用域。此 scope 的动作
  // **不经 resolveKeyboard / 页面派发**，而是由 GlobalLookupController 直接读其
  // 绑定注册到操作系统级 hotkey_manager（默认 Ctrl+Alt+D）。它跨页面常驻、不与
  // 任何应用内页面的键盘绑定竞争，故自成独立 co-active 组，冲突检测只扫自己，
  // 绝不与 global/home 等页面 scope 互相牵连。仅桌面（Windows）有意义。
  globalExternal,

  // 查词弹窗内部的导航动作（Yomitan 式「上/下一个词条」）。这些动作**不经
  // resolveKeyboard / 页面派发**：弹窗内容是 WebView，输入事件先到 WebView 的
  // JS，故绑定由 popup_settings_injection 注入给 popup.js，命中即调
  // hoshiFocusDictionaryEntryMove。它跨所有弹窗宿主（阅读器 / 视频 / 首页词典 /
  // 桌面全局查词窗）常驻，与任何页面 scope 都不竞争，故自成独立 co-active 组。
  dictionaryPopup;

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
      // 漫画阅读器同样是独立界面：只解析自己的绑定，故自成 co-active 组，
      // 冲突检测只扫 manga（与 video 同理）。
      case manga:
        return const <ShortcutScope>[manga];
      // gamepad（dpad 四向）是独立 co-active 组：dpad 绑定永不与 reader/home 的
      // 按钮跨组冲突，冲突检测只扫 gamepad 自身。
      case gamepad:
        return const <ShortcutScope>[gamepad];
      // globalExternal（系统级 app 外查词热键）是独立 co-active 组：它不经页面
      // 派发，只由 controller 注册到操作系统热键；冲突检测只扫自己，永不与任何
      // 应用内 scope 牵连。
      case globalExternal:
        return const <ShortcutScope>[globalExternal];
      // dictionaryPopup（查词弹窗内导航）同理是独立 co-active 组：它的绑定由弹窗
      // WebView 的 JS 消费，永不与任何页面 scope 的键位竞争，冲突检测只扫自己。
      case dictionaryPopup:
        return const <ShortcutScope>[dictionaryPopup];
    }
  }

  /// 本 scope 真正会被消费的输入通道。设置页的编辑对话框据此渲染章节——绑了不会
  /// 生效的通道根本不给入口，杜绝「设置里能配、按了没反应」的死项（同
  /// shortcut_action_wiring_guard 的不变式，只是发生在 UI 层）。
  ///
  /// 绝大多数 scope 走页面派发，键盘/手柄/鼠标三通道全通；[dictionaryPopup] 的
  /// 动作只由弹窗 WebView 的滚轮事件触发（见枚举注释），故只开滚轮。
  Set<ShortcutChannel> get channels {
    switch (this) {
      case reader:
      case audiobook:
      case home:
      case global:
      case video:
      case manga:
      case gamepad:
      case globalExternal:
        return const <ShortcutChannel>{
          ShortcutChannel.keyboard,
          ShortcutChannel.gamepad,
          ShortcutChannel.mouse,
        };
      case dictionaryPopup:
        return const <ShortcutChannel>{ShortcutChannel.wheel};
    }
  }
}

/// 一个 [ShortcutAction] 可能绑定的输入通道（与 [ShortcutBindingSet] 的四组绑定
/// 一一对应）。
enum ShortcutChannel { keyboard, gamepad, mouse, wheel }

enum ShortcutAction {
  // 声明顺序 = 设置页各组的展示顺序（actionsForScope 按 values 声明序过滤），各组
  // 按 关闭/返回 → 高频操作 → 界面/杂项 分簇排列，重要动作靠前。持久化走字符串
  // key，与声明序无关。⚠️ 唯一的顺序敏感点：resolveKeyboard / resolveGamepad 按
  // 声明序取首个命中——同 scope 内故意共享绑定的别名对（readerLookupAtCursor 与
  // readerEnterCaret 同绑 A/Enter），先声明者在 resolve 路径胜出；重排时必须保持
  // readerLookupAtCursor 在 readerEnterCaret 之前。

  // Reader
  // 关闭/返回（用户拍板拆分：关词典与退书是两个独立动作、各自键位，不再共用一键
  // 的阶梯语义）：readerDismissDict 只关词典弹窗（无弹窗时不消费、不退书）；
  // readerExitBook 直接退出书籍（走 maybePop → PopScope onWillPop 闸门，BUG-782）。
  readerDismissDict(ShortcutScope.reader, 'reader_dismiss_dict'),
  readerExitBook(ShortcutScope.reader, 'reader_exit_book'),

  // 翻页
  readerPageForward(ShortcutScope.reader, 'reader_page_forward'),
  readerPageBackward(ShortcutScope.reader, 'reader_page_backward'),

  // 查词/制卡
  readerLookupAtCursor(ShortcutScope.reader, 'reader_lookup_at_cursor'),
  readerShiftLookup(ShortcutScope.reader, 'reader_shift_lookup'),
  readerCreateCardFromPopup(
      ShortcutScope.reader, 'reader_create_card_from_popup'),
  // TODO-700 T7：「进入选字查词光标」可改键（默认手柄 A + 键盘 Enter）。这是
  // enter-trigger 的绑定真相源：reader 写死判 A/Enter 进光标的分支改读它的绑定
  // （见 reader_caret_router.isEnterTrigger*）。默认与旧硬编码一致，行为不变，只
  // 是变成可改键。注意它与 readerLookupAtCursor 默认同绑 A/Enter——这是有意的并行
  // 别名（一个管「进光标」、一个管「进光标后查词/激活」），enter-trigger 不经
  // resolveKeyboard 故无枚举顺序歧义，no-shadow 守卫显式排除它；resolve 路径按
  // 声明序先命中 readerLookupAtCursor（见枚举头部排序契约，勿排到它前面）。
  readerEnterCaret(ShortcutScope.reader, 'reader_enter_caret'),

  // 界面
  readerToggleFurigana(ShortcutScope.reader, 'reader_toggle_furigana'),
  readerToggleChrome(ShortcutScope.reader, 'reader_toggle_chrome'),
  // TODO-728：直接打开阅读器设置菜单（外观/进度/目录的快速设置面板，执行体
  // = _showAppearanceSheet）。与 readerToggleChrome 正交——后者只 show/hide 底栏，
  // 这个一键弹出设置面板，省去先开底栏再焦点移到齿轮按钮的来回。默认键盘 T。
  readerOpenMenu(ShortcutScope.reader, 'reader_open_menu'),
  // TODO-1309①：一键打开阅读器「导航」界面（书内搜索 / 字符跳转 / 目录 / 书签 /
  // 收藏，即快速设置面板的 location 分类）。与 readerOpenMenu 正交——后者落主菜单
  // （窄窗）/ 默认分类（宽窗），这个直达导航子页。默认键盘 Ctrl+F：reader+audiobook
  // co-active 组内 Ctrl+F 未被占用；home 组的 homeFocusSearch 也绑 Ctrl+F，但两组
  // 不同 co-active 组、绝不同时激活，不构成冲突（no-shadow 守卫只扫同组）。执行体
  // = _showAppearanceSheet(initialSubPage: 'location')。
  readerOpenNavigation(ShortcutScope.reader, 'reader_open_navigation'),

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
  // TODO-1093：窗口级/app 级「全屏切换」（区别于视频播放器内的
  // videoToggleFullscreen——那个只切视频表面）。执行体在 wrapWithGlobalNavigation
  // 里读本 action 的键盘绑定，命中时调 windowManager.setFullScreen(!当前)，当前态
  // 用 DesktopWindowPlacement.isFullScreen() 读取。global scope、桌面（Win/macOS/
  // Linux）生效、移动端 no-op（window_manager 无桌面窗）。默认键盘 F11。
  globalToggleFullscreen(ShortcutScope.global, 'global_toggle_fullscreen'),

  // Audiobook（上一句在前，与视频组「上/下一句字幕」顺序一致）
  audiobookPlayPause(ShortcutScope.audiobook, 'audiobook_play_pause'),
  audiobookPrevSentence(ShortcutScope.audiobook, 'audiobook_prev_sentence'),
  audiobookNextSentence(ShortcutScope.audiobook, 'audiobook_next_sentence'),
  // 鼠标中键点句 → 跳到该句并播放。位置型动作，运行时不走
  // _executeShortcutAction，而是 onPointerSeek 经 resolveMouse 判定后定位执行。
  audiobookSeekToClickedSentence(
      ShortcutScope.audiobook, 'audiobook_seek_clicked_sentence'),

  // Video player (TODO-134): migrated out of the hard-coded
  // buildVideoPlayerShortcuts map so they live in the remappable registry and
  // show up in the shortcut settings page alongside the other scopes. The
  // executed behaviour is unchanged; only the key lookup now goes through the
  // registry. Defaults match the previous asbplayer/mpv-style bindings.
  //
  // 声明顺序 = 设置页展示顺序（actionsForScope 按 values 声明序过滤）。视频组按
  // 关闭/返回 → 播放控制 → 字幕/章节跳转 → 字幕显示 → 字幕对轴 → 音量 → 画面/杂项
  // 分簇排列，重要动作靠前；重排只影响展示，持久化走字符串 key、与声明序无关。

  // 关闭/返回：逐级退出（控件编辑态→字幕列表→剧集列表→侧栏→沉浸锁→全屏→退出视频页）。
  videoEscape(ShortcutScope.video, 'video_escape'),

  // 播放控制
  videoTogglePlayPause(ShortcutScope.video, 'video_toggle_play_pause'),
  videoPlay(ShortcutScope.video, 'video_play'),
  videoPause(ShortcutScope.video, 'video_pause'),
  videoSeekBackward(ShortcutScope.video, 'video_seek_backward'),
  videoSeekForward(ShortcutScope.video, 'video_seek_forward'),
  videoPreviousFrame(ShortcutScope.video, 'video_previous_frame'),
  videoNextFrame(ShortcutScope.video, 'video_next_frame'),
  videoSpeedUp(ShortcutScope.video, 'video_speed_up'),
  videoSpeedDown(ShortcutScope.video, 'video_speed_down'),
  videoResetSpeed(ShortcutScope.video, 'video_reset_speed'),

  // 字幕/章节跳转
  videoPreviousSubtitle(ShortcutScope.video, 'video_previous_subtitle'),
  videoNextSubtitle(ShortcutScope.video, 'video_next_subtitle'),
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

  // 字幕显示
  videoToggleSubtitleList(ShortcutScope.video, 'video_toggle_subtitle_list'),
  videoToggleSubtitleBlur(ShortcutScope.video, 'video_toggle_subtitle_blur'),
  // TODO-840 Part B：字幕遮蔽模式（不遮蔽/模糊/隐藏，见 VideoSubtitleObscureMode）。
  // videoCycleSubtitleObscure 在三态间循环；videoToggleSubtitleHide 直接开/关「隐藏
  // 主字幕」。与历史的 videoToggleSubtitleBlur（B，开/关模糊）正交并存——后者保留
  // 不破坏旧绑定（Never break userspace）。三者执行体都在 video_player_shortcuts。
  videoCycleSubtitleObscure(
      ShortcutScope.video, 'video_cycle_subtitle_obscure'),
  videoToggleSubtitleHide(ShortcutScope.video, 'video_toggle_subtitle_hide'),
  // TODO-1382：**副字幕**遮蔽三态（镜像主字幕，独立开关）。videoCycleSecondarySubtitleObscure
  // 循环 不遮蔽→模糊→隐藏（默认 Shift+G）；videoToggleSecondarySubtitleHide 直接开/关
  // 「隐藏副字幕」（默认 Shift+H）。执行体在 video_player_shortcuts。
  videoCycleSecondarySubtitleObscure(
      ShortcutScope.video, 'video_cycle_secondary_subtitle_obscure'),
  videoToggleSecondarySubtitleHide(
      ShortcutScope.video, 'video_toggle_secondary_subtitle_hide'),

  // 字幕对轴/匹配快捷键（用户请求）：把埋在快速设置面板深处的「字幕调轴」直接搬到
  // 键盘。videoOpenSubtitleAlign 一键弹波形对轴放大视图（复用 SubtitleWaveformZoomView，
  // 与面板入口同一逻辑、零第二套状态）；videoSubtitleDelayIncrease/Decrease 像 mpv 的
  // z/x 一样按固定步进整体平移字幕延迟（走现有 _setDelayMs 写穿 delayMs 落盘）。三者都
  // 在 video 独立 co-active 组内，默认键与既有视频键无冲突。
  videoOpenSubtitleAlign(ShortcutScope.video, 'video_open_subtitle_align'),
  videoSubtitleDelayIncrease(
      ShortcutScope.video, 'video_subtitle_delay_increase'),
  videoSubtitleDelayDecrease(
      ShortcutScope.video, 'video_subtitle_delay_decrease'),
  // asbplayer 式「字幕偏移对齐」（用户请求，默认 Ctrl+Shift+←/→）：把上一句 / 下一句
  // 字幕的起点整体平移到当前播放时间点（按目标 cue 求**绝对**偏移，一键粗对齐整轨；与
  // z/x 的固定步进平移互补）。执行体走同一 _setDelayMs 写穿路径（clamp + 落盘 + OSD），
  // 决策集中在纯函数 VideoPlayerController.snapSubtitleDelayMs。video co-active 组内
  // Ctrl+Shift+箭头未被占用（裸箭头=time seek、Ctrl+箭头=跳句，均不冲突）。
  videoAlignSubtitleToPrev(ShortcutScope.video, 'video_align_subtitle_to_prev'),
  videoAlignSubtitleToNext(ShortcutScope.video, 'video_align_subtitle_to_next'),

  // 音量
  videoVolumeUp(ShortcutScope.video, 'video_volume_up'),
  videoVolumeDown(ShortcutScope.video, 'video_volume_down'),
  videoToggleMute(ShortcutScope.video, 'video_toggle_mute'),

  // 画面/杂项
  videoToggleFullscreen(ShortcutScope.video, 'video_toggle_fullscreen'),
  videoToggleImmersiveLock(ShortcutScope.video, 'video_toggle_immersive_lock'),
  videoScreenshot(ShortcutScope.video, 'video_screenshot'),
  videoToggleShaderCompare(ShortcutScope.video, 'video_toggle_shader_compare'),
  videoToggleFavoriteSentence(
      ShortcutScope.video, 'video_toggle_favorite_sentence'),

  // 漫画：翻页存的是**页序语义**（forward=下一页），左右方向键再按跨页方向
  // （日漫默认 rtl）校正——与 reader 的 resolveReaderArrowPageTurn 同构，见
  // resolveMangaArrowPageTurn。这样用户改键改的是「哪个键翻页」，方向仍由书自己
  // 的排版决定，不会出现「改了键之后 rtl 书翻反」。
  mangaPageForward(ShortcutScope.manga, 'manga_page_forward'),
  mangaPageBackward(ShortcutScope.manga, 'manga_page_backward'),
  // 关词典弹窗。漫画与阅读器的差异：本页弹窗可见时左右键仍要「关弹窗并翻页」，
  // 故没有独立的「退书」动作绑在 Esc 上（退书走系统返回 / PopScope）。
  mangaDismissDict(ShortcutScope.manga, 'manga_dismiss_dict'),

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
  globalExternalLookup(ShortcutScope.globalExternal, 'global_external_lookup'),

  // 查词弹窗「上/下一个词条」（用户请求，Yomitan 的 Next/Previous entry）：一次查询
  // 常返回多个词条（.entry），这两个动作把弹窗的词条级焦点（蓝三角 .entry-current）
  // 移到相邻词条并滚进视口。默认 Alt+滚轮下 / Alt+滚轮上，与 Yomitan 手感一致。
  //
  // 执行体不在 Dart 侧：弹窗内容是 WebView，滚轮事件先到 popup.js，故
  // popup_settings_injection 把这两个动作的滚轮绑定注入成
  // `window.__hoshiEntryWheelBindings`，popup.js 的 wheel 监听命中即调
  // `hoshiFocusDictionaryEntryMove('next'|'prev')`（TODO-1325 #5 part1 已有的能力，
  // 此前只有阅读器选字光标模式下的硬编码 `.` / `,` 能触发，既不可改键也不覆盖
  // 视频/首页/全局查词的弹窗）。
  popupNextEntry(ShortcutScope.dictionaryPopup, 'popup_next_entry'),
  popupPrevEntry(ShortcutScope.dictionaryPopup, 'popup_prev_entry');

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
