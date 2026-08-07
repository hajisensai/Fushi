enum ShortcutScope {
  reader,
  home,
  global,

  // 「返回上一级」这一件事的唯一归属地（用户拍板：Esc 一键从任何界面退一层，
  // 且退书 / 退漫画 / 退视频只能有**一个**配置项）。
  //
  // 为什么是独立 scope 而不是塞进 global：媒体页（reader/manga/video）都只解析
  // 自己那一组 co-active scope，若把「返回」留在 global 就得让它们连 home 组一起
  // 解析——那会把 home+global+reader+audiobook 串成一个巨大的 co-active 组，
  // reader 的 Ctrl+F（readerOpenNavigation）与 home 的 Ctrl+F（homeFocusSearch）
  // 这类**本就永不同时激活**的键会被冲突检测误判成撞键。universal 自成一组，由
  // 每个表面在**自己 scope 未命中之后**兜底解析，故：
  //   · 页面专属键永远优先（阅读器内手柄 B 仍是 audiobookPrevSentence 上一句，
  //     不被「返回」夺舍——这是 TODO-700 T1/T2 的既有约束，不得回归）；
  //   · 页面没占用的键才落到「返回上一级」。
  // ⚠️ 代价说明：正因为它是兜底，页面 scope 绑了同一个键就会**静默遮蔽**它，而
  // 冲突检测（只扫 co-active 组）看不见。守卫 `universal_back_test` 因此对着默认
  // 表核一遍「universal 的默认键不得被任何页面 scope 的默认键遮蔽」，B 在 reader
  // 组是唯一登记在案的有意例外。
  universal,

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
  // fushiFocusDictionaryEntryMove。它跨所有弹窗宿主（阅读器 / 视频 / 首页词典 /
  // 桌面全局查词窗）常驻，与任何页面 scope 都不竞争，故自成独立 co-active 组。
  dictionaryPopup;

  // Scopes that are resolved together on the same page. The reader page
  // resolves reader + audiobook bindings; the home page resolves home + global.
  // Because the page tries these scopes in sequence, a single physical key can
  // only ever trigger one of them, so a binding shared across a co-active group
  // is a real conflict (the later scope silently never fires). Conflict
  // detection must therefore scan the whole group, not just one scope. This is
  // the single source of truth both the pages and the registry rely on.
  /// ⚠️ [universal]（「返回上一级」）**刻意不进任何组**，它与页面 scope 的关系不是
  /// 「同时解析、谁先声明谁赢」，而是「页面全都没中才轮到」——单向遮蔽，且这个方向
  /// 上有一个**有意**的既存例外：书内手柄 B 归有声书「上一句」，返回键在阅读器被它
  /// 吃掉正是 TODO-700 约束2/4 要的效果。把 universal 并进各组会让默认表自带一条
  /// 需要开例外的「冲突」，反而侵蚀这套冲突检测的可信度。
  ///
  /// 代价（已知限制，不要以为它被覆盖了）：用户在设置页把 Esc 之类的返回键绑给某个
  /// 页面动作时，**不会**收到冲突提示，绑完那个页面就退不出去（改回来即可恢复）。
  /// 默认表这一侧由 `universal_back_test` 的静态守卫逐平台钉死：任何页面 scope 的
  /// 默认键盘绑定都不得与 globalBack 撞键，手柄侧只放行登记在案的 B。
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
      // universal（「返回上一级」）是独立 co-active 组：它由每个表面在自身 scope
      // 未命中后兜底解析，与任何页面 scope 都不在同一次解析里竞争，故冲突检测只
      // 扫自己。跨组遮蔽由 `universal_back_test` 的默认表守卫兜住（见枚举注释）。
      case universal:
        return const <ShortcutScope>[universal];
      // dictionaryPopup（查词弹窗内导航）同理是独立 co-active 组：它的绑定由弹窗
      // WebView 的 JS 消费，永不与任何页面 scope 的键位竞争，冲突检测只扫自己。
      case dictionaryPopup:
        return const <ShortcutScope>[dictionaryPopup];
    }
  }

  /// 本 scope 真正会被消费的输入通道。设置页的编辑对话框据此渲染章节——绑了不会
  /// 生效的通道根本不给入口，杜绝「设置里能配、按了没反应」的死项。
  ///
  /// ⚠️ 这里开一个通道，就等于对用户承诺该通道真的能用，因此**必须同时存在该通道
  /// 的解析入口**（`resolveKeyboard/resolveGamepad/resolveMouse(scope: 本 scope)`，
  /// 或按 action 取 `bindingsFor(...).<通道>Bindings`）。守卫
  /// `shortcut_channel_wiring_guard_test` 会对着源码核这件事：新开一个没有解析入口
  /// 的通道即红。它与 `shortcut_action_wiring_guard` 互补——后者只看「action 符号
  /// 有没有出现过」，抓不到「同一个 action 的键盘接了、手柄没接」这种半接线。
  ///
  /// 每个 scope 只列**真的存在解析入口**的通道，没有「多数 scope 三通道全通」这种
  /// 省事写法——那正是 7 条死通道的来源（见各 case 注释）。
  ///
  /// 尤其注意 **mouse 通道在本 app 的唯一运行时输入源是 WebView 的 DOM `mousedown`**
  /// （阅读器 `onPointerSeek` / 歌词 `onLyricsPointerSeek` → `resolveMouse`）。Flutter
  /// 侧至今没有任何「PointerDownEvent → MouseBinding → 派发」的管线，故非 WebView
  /// 宿主的 scope 一律不开 mouse。
  Set<ShortcutChannel> get channels {
    switch (this) {
      // 阅读器与有声书是 WebView 宿主：键盘/手柄走页面派发，鼠标侧键经 WebView 的
      // DOM mousedown → `resolveMouse`（webview.part.dart / pointer_seek.dart）。
      case reader:
      case audiobook:
        return const <ShortcutChannel>{
          ShortcutChannel.keyboard,
          ShortcutChannel.gamepad,
          ShortcutChannel.mouse,
        };
      // 首页 / 全局 / 视频页：键盘与手柄都有解析入口（home_page 的 resolveKeyboard、
      // global_navigation、video_player_shortcuts 的 keyboardBindings、各页
      // GamepadButtonIntent），但**鼠标没有**——这三个页面都是纯 Flutter 表面，没有
      // WebView 接管 mousedown，也没有任何 Flutter 侧鼠标绑定派发管线。曾经开着
      // mouse 通道纯属与 reader/audiobook 共用一个 case 分支的连带产物：设置页给出
      // 「添加鼠标按键」入口，绑上去永不触发。要重开必须先真的建一条
      // PointerDownEvent → MouseBinding → 派发的链路并验证。
      case home:
      case global:
      case video:
        return const <ShortcutChannel>{
          ShortcutChannel.keyboard,
          ShortcutChannel.gamepad,
        };
      // universal（「返回上一级」）：键盘与手柄都有解析入口——每个表面在自身 scope
      // 未命中后按 `resolveKeyboard/resolveGamepad(scope: universal)` 兜底
      // （reader caret.part / manga page / video page / global_navigation 四处）。
      // 鼠标不开：Flutter 侧至今没有 PointerDownEvent → MouseBinding 的派发管线，
      // 而弹窗桥那条鼠标路只在**词典弹窗表面**成立、不是全表面能力（开了就是
      // 「设置里能配、在正文上按了没反应」）。
      case universal:
        return const <ShortcutChannel>{
          ShortcutChannel.keyboard,
          ShortcutChannel.gamepad,
        };
      // dpad 四向：唯一消费者是 GamepadService._dispatchButton，按 `GamepadButton`
      // 做 `resolveGamepad(scope: gamepad)`，且结果只被映射成 TraversalDirection。
      // 键盘/鼠标绑定在这里**按构造不可读**（没有也不可能有 resolveKeyboard/
      // resolveMouse(scope: gamepad)）；默认表也刻意把键盘留空——方向焦点移动由箭头键
      // 与摇杆负责，见 shortcut_defaults 的 dpad* 注释。
      case gamepad:
        return const <ShortcutChannel>{ShortcutChannel.gamepad};
      // app 外全局查词热键：GlobalLookupController 只读 `.keyboardBindings` 注册到
      // OS 级 hotkey_manager，而 `HotKey.key` 的类型就是 Flutter 的 `KeyboardKey`，
      // 底层是 win32 `RegisterHotKey`（修饰键位掩码 + 虚拟键码）。手柄按钮无法表达，
      // 鼠标键则要装 WH_MOUSE_LL 全局钩子并全系统吞掉该键——两者都不是这条机制能
      // 提供的，故只开键盘。
      case globalExternal:
        return const <ShortcutChannel>{ShortcutChannel.keyboard};
      // 漫画页只有键盘解析入口：`_resolveMangaKeyAction` 走 `resolveKeyboard`，
      // 滚轮翻页是硬编码的 `wheelInputAction`（不查注册表），手柄则完全没接
      // （既无 `resolveGamepad`，也无 `GamepadButtonIntent` 的 Action）。开着手柄/
      // 鼠标通道 = 设置页给出能配却按了没反应的入口，比没有这个选项更糟。
      // 接上对应解析入口（照 reader `_handleGamepadButton`）并真机验证后再开。
      case manga:
        return const <ShortcutChannel>{ShortcutChannel.keyboard};
      // 查词弹窗：滚轮（上/下一个词条）+ 键盘（制卡）。两者都不经 resolveKeyboard —— 绑定
      // 由 popup_settings_injection 序列化后注入给 popup.js，命中判定在 JS 侧（弹窗内容是
      // WebView，输入事件先到它的 JS）。键盘通道的取用点同样是
      // `bindingsFor(popupMineEntry).keyboardBindings`。
      case dictionaryPopup:
        return const <ShortcutChannel>{
          ShortcutChannel.wheel,
          ShortcutChannel.keyboard,
        };
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
  // 「只关词典、绝不退出」的可选专用动作（**默认无键盘绑定**）。退出改由
  // universal 的 globalBack 一键阶梯承担（关词典 → 退书），故这里不再需要
  // 一个默认键；保留动作本身是因为它有独立价值：把它绑到鼠标侧键，就能在不退出
  // 的前提下关词典（BUG-1071 那条鼠标通道的唯一消费者）。
  readerDismissDict(ShortcutScope.reader, 'reader_dismiss_dict'),

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

  // Universal —— 全 app 唯一的「返回上一级 / 退出当前界面」。
  //
  // 一个配置项覆盖全部退出语义（用户拍板）：关词典弹窗、退出书籍、退出漫画、
  // 退出视频、退出设置等任意整页界面，全走它。默认键盘 Esc + Alt+←、手柄 B。
  // scope 从 global 挪到 universal（持久化 key `global_back` **保持不变**，老用户
  // 改过的键原样生效）；旧的 `reader_exit_book` / `video_escape` 两个 action 已删除，
  // 它们的自定义绑定由 schema v8 迁移并入本动作（见 shortcut_registry）。
  //
  // 「退出到哪一层」由各表面自己的阶梯执行体决定，本动作只表达「退一层」：
  //   · 阅读器：词典弹窗可见 → 关弹窗；否则 maybePop 退书（PopScope 闸门，BUG-782）
  //   · 漫画：  词典弹窗可见 → 关弹窗；否则 maybePop 退漫画
  //   · 视频：  控件编辑 → 字幕列表 → 剧集列表 → 侧栏 → 沉浸锁 → 全屏 → 浮层 → 退页
  //   · 其它页：maybePop（PopupRoute 让框架自己的 Esc 语义优先，见 global_navigation）
  globalBack(ShortcutScope.universal, 'global_back'),

  // Global
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
  // 播放控制 → 字幕/章节跳转 → 字幕显示 → 字幕对轴 → 音量 → 画面/杂项
  // 分簇排列，重要动作靠前；重排只影响展示，持久化走字符串 key、与声明序无关。
  // 「逐级退出」不在本组——它是全 app 共用的 [globalBack]（universal scope）。

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
  // 按住临时倍速（用户请求）：与手机长按画面同语义——按下时临时切到长按倍速
  // （asbplayer 配置 longPressSpeed），松开恢复原速、不落盘。键盘按住需要 keyup
  // 边沿，SingleActivator 表达不了，故它**不进** CallbackShortcuts activator 表，
  // 由视频页最外层 Focus.onKeyEvent 读本 action 的绑定自行判定按下/松开（见
  // video_hibiki_page 的 _handleHoldSpeedKey）；手柄通道退化成按一下开/再按恢复
  // 的翻转语义（videoActionCallbacks → toggleHoldSpeed）。
  videoHoldSpeed(ShortcutScope.video, 'video_hold_speed'),

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
  // 手柄/键盘字级选词查词（对齐阅读器 readerEnterCaret）：进入后光标停在当前字幕
  // 首个可见字符，D-pad/方向键逐字移动、A/Enter 对光标字符查词（浮层内继续用手柄
  // 翻词条/跳词典/制卡）、B/Esc 退出。激活期的方向/确认/退出键在页面侧**先于**注册
  // 表截获（reader caret 同款contextual 路由），见 video_hibiki/subtitle_caret.part.dart。
  videoEnterCaret(ShortcutScope.video, 'video_enter_caret'),

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
  // 「只关词典、绝不退出」的可选专用动作（**默认无键盘绑定**，与
  // [readerDismissDict] 同形）。漫画与阅读器的差异仍在：本页弹窗可见时左右键要
  // 「关弹窗并翻页」，那条语义在 [MangaReaderInputAction] 侧，与本动作无关。
  // 退出漫画走 universal 的 [globalBack] 阶梯（弹窗可见先关弹窗，否则退出）。
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
  // `window.__fushiEntryWheelBindings`，popup.js 的 wheel 监听命中即调
  // `fushiFocusDictionaryEntryMove('next'|'prev')`（TODO-1325 #5 part1 已有的能力，
  // 此前只有阅读器选字光标模式下的硬编码 `.` / `,` 能触发，既不可改键也不覆盖
  // 视频/首页/全局查词的弹窗）。
  popupNextEntry(ShortcutScope.dictionaryPopup, 'popup_next_entry'),
  popupPrevEntry(ShortcutScope.dictionaryPopup, 'popup_prev_entry'),

  // 制卡（用户请求：「点那个加号的动作」要有快捷键）。
  // 语义上这个动作属于**弹窗**而非某个页面——同一份 popup.js 同时是 app 内弹窗、app 外裸
  // WebView2 查词窗和浏览器扩展弹窗的实现，加号也只有那一个（`.mine-button`）。故它落在
  // dictionaryPopup scope，一个绑定覆盖三处，而不是给每个页面各开一个「制卡」动作。
  //
  // 执行分工（按**键盘焦点归属**切开，三条路径互斥、绝不双触发 = 绝不重复制卡）：
  //   · app 内（焦点在 Flutter 页）：Dart 侧派发。阅读器沿用既有的
  //     readerCreateCardFromPopup（Never break userspace，默认键与本动作一致）；视频页读
  //     本动作的键盘绑定（见 video_hibiki_page 的 _buildVideoShortcuts）。
  //   · app 外（焦点在裸 WebView2 表面）：绑定经 popup_settings_injection 注入成
  //     window.__fushiPopupKeyBindings，由 popup.js 自己判定。
  //   · 浏览器扩展：没有注入通道，吃 popup.js 里的同款内置默认值。
  // in-app 宿主会被显式注入 `null` 关掉 JS 侧判定——那里由 Dart 负责，两边都开就有在
  // 「WebView 键盘桥把同一次按键同时喂给 Flutter 和 JS」时制出两张卡的风险。
  //
  // ⚠️ app 外这一端**只有剪贴板面板真能用，且要用户先点过面板**：面板实例走
  // `SetActivatable(true)`（flutter_window.cpp）故能拿键盘焦点；而**瞬态查词覆盖窗**默认
  // `activatable_ = false`，带 `WS_EX_NOACTIVATE`（global_lookup_window.cpp:988）——它
  // 永不接收键盘焦点，runner 侧也没有任何键盘转发/钩子，所以本动作在那个表面上**物理上
  // 不可能触发**。galgame 场景焦点通常在游戏上，不先点面板就按不到。要覆盖瞬态窗只有两条
  // 路（去掉 NOACTIVATE = 抢游戏焦点、违背它的设计初衷；或上全局 RegisterHotKey），都是
  // 产品取舍，未做——别把这里的实现说成「app 内 / app 外 / 浏览器都能用」。
  popupMineEntry(ShortcutScope.dictionaryPopup, 'popup_mine_entry');

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
