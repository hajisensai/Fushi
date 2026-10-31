// GENERATED-NOTE: extracted from reader_fushi_page.dart (TODO-589 batch1).
part of '../reader_fushi_page.dart';

const int kLyricsModeMaxInitialCues = 600;

class LyricsCueWindow {
  const LyricsCueWindow({
    required this.cues,
    required this.currentIndex,
    required this.indexOffset,
    required this.usesAllBookCues,
  });

  final List<AudioCue> cues;
  final int currentIndex;
  final int indexOffset;
  final bool usesAllBookCues;

  static LyricsCueWindow select({
    required List<AudioCue> allBookCues,
    required List<AudioCue> chapterCues,
    required int allBookIndex,
    required int chapterIndex,
    int maxCues = kLyricsModeMaxInitialCues,
  }) {
    if (allBookCues.isEmpty) {
      final int safeChapterIndex = _clampIndex(
        chapterIndex,
        chapterCues.length,
      );
      return LyricsCueWindow(
        cues: chapterCues,
        currentIndex: safeChapterIndex,
        indexOffset: 0,
        usesAllBookCues: false,
      );
    }

    final int safeAllBookIndex = _clampIndex(allBookIndex, allBookCues.length);
    if (allBookCues.length <= maxCues) {
      return LyricsCueWindow(
        cues: allBookCues,
        currentIndex: safeAllBookIndex,
        indexOffset: 0,
        usesAllBookCues: true,
      );
    }

    final int half = maxCues ~/ 2;
    int start = safeAllBookIndex - half;
    if (start < 0) start = 0;
    int end = start + maxCues;
    if (end > allBookCues.length) {
      end = allBookCues.length;
      start = end - maxCues;
      if (start < 0) start = 0;
    }

    return LyricsCueWindow(
      cues: allBookCues.sublist(start, end),
      currentIndex: safeAllBookIndex - start,
      indexOffset: start,
      usesAllBookCues: true,
    );
  }

  static int _clampIndex(int index, int length) {
    if (length <= 0) return 0;
    if (index < 0) return 0;
    if (index >= length) return length - 1;
    return index;
  }
}

/// 歌词覆盖层 ⋯ 菜单里列出的阅读器操作（与顶栏同一套 [ReaderControlItem]）。
/// 不含：返回（出口是覆盖层的 ✕ / 回到阅读器）、模式切换（就是 ✕）、标题、插图
/// 画廊（覆盖层封面位自带插图入口，见 lyrics_illustration_view）、隐藏工具栏
/// （覆盖层没有工具栏）、三颗传输键（覆盖层自己有播放控件）。
const List<ReaderControlItem> kLyricsOverlayMenuItems = <ReaderControlItem>[
  ReaderControlItem.navigation,
  ReaderControlItem.audiobook,
  ReaderControlItem.audiobookFollow,
  ReaderControlItem.audiobookSeekBack,
  ReaderControlItem.audiobookSeekForward,
  ReaderControlItem.statistics,
  ReaderControlItem.studyTimer,
  ReaderControlItem.fullscreen,
  ReaderControlItem.settings,
];

/// 覆盖层读数的读口：**只读**阅读器现成的数据——StudyClock 的会话累计（时长 /
/// 字数）与正文进度（全书已读 / 总字数）。歌词层不产生、不写入任何统计，这些数
/// 全由下面照常跟随音频的正文产生。
class _ReaderLyricsClock implements LyricsPlayerClock {
  _ReaderLyricsClock(this._state);

  final _ReaderFushiPageState _state;

  @override
  Duration get position =>
      _state._audiobookController?.globalPosition ?? Duration.zero;

  @override
  Duration get duration =>
      _state._audiobookController?.totalDuration ?? Duration.zero;

  @override
  LyricsPlayerStats get stats {
    if (!_state.mounted) return LyricsPlayerStats.empty;
    final StudySessionTotals totals = _state._readingSessionTotals();
    return LyricsPlayerStats(
      sessionDurationMs: totals.durationMs,
      sessionChars: totals.chars,
      tracking: totals.active,
      currentChars: _state._progressCurrentChars,
      totalChars: _state._progressTotalChars,
    );
  }
}

/// lyrics + floating-lyric domain methods extracted via part-of (TODO-589
/// batch1); shared private scope. Behaviour-preserving: bodies are verbatim
/// except `setState(` forwarded through the main shell `_rebuild(` helper
/// (extensions cannot call the @protected State.setState directly).
extension _ReaderLyrics on _ReaderFushiPageState {
  // ── Lyrics Mode ──────────────────────────────────────────────────

  Future<void> _toggleLyricsMode() async {
    if (_lyricsModeTransition) return;
    if (_controller == null || _audiobookController == null) return;
    final bool entering = !_lyricsMode;

    if (entering) {
      final List<AudioCue> cues =
          _audiobookController!.allBookCuesSnapshot.isNotEmpty
          ? _audiobookController!.allBookCuesSnapshot
          : _audiobookController!.chapterCuesSnapshot;
      if (cues.isEmpty) return;
    }

    _rebuild(() => _lyricsModeTransition = true);
    try {
      await ReaderFushiSource.instance.setLyricsModeForBook(
        widget.bookKey,
        entering,
      );

      if (entering) {
        // 覆盖层架构：正文 WebView 不卸载、不换文档，只在它上面盖一层歌词。进入前
        // 只需收掉正文上的焦点环（键盘 / 手柄此后作用在歌词层）与正文查词弹窗。
        // 不再 `_readLedger.leave()`、不再把控制器的章 cue 换成整书 cue——正文照常
        // 按章跟随音频，阅读账本 / StudyClock 也照常由正文这条路记账（BUG-2597 的
        // 「歌词单元入账」随之删除：歌词层不写任何统计）。
        _exitCaret();
        if (isDictionaryShown) clearDictionaryResult();
        await _resolveAndApplyProfile(
          appModelNoUpdate.database,
          mediaTypeOverride: ProfileMediaKind.lyrics,
        );
        if (!mounted) return;
        // BUG-872：用 allBookCueIdxAtPosition（位置优先）而非 allBookCueIdx，
        // 重开书暂停态下 _currentCue 尚未被播放 tick 填充，allBookCueIdx==-1 会
        // 把入场高亮 clamp 回第一句；按已恢复的播放器位置取正确 cue。
        _lyricsEntryCueIndex =
            _audiobookController!.allBookCuesSnapshot.isNotEmpty
            ? _audiobookController!.allBookCueIdxAtPosition
            : _audiobookController!.currentCueIdx;
        // 首次进入提示改挂「歌词文档就绪」事件（_onLyricsDocumentReady 消费此旗）。
        _pendingLyricsHintOnReady = true;
        // 覆盖层期间正文看不见，必须跟着音频走才能替用户记字数——即便用户关了
        // 「跟随音频」（那个开关在歌词模式只管歌词列表自己滚不滚）。
        _audiobookController!.setReaderFollowOverride(true);
        // 挂上覆盖层。第一次进入：歌词 WebView 在 onWebViewCreated 里装载歌词文档；
        // 之后（BUG-3913）同一个实例从屏外停放位搬回覆盖层，这里直接重装文档。
        // 就绪前透明（_lyricsPageReady），上一轮的旧文档不会露出来。两个字段随下面
        // 这次 _rebuild 一起生效。
        _lyricsWebViewRetained = true;
        _lyricsPageReady = false;
        _rebuild(() => _lyricsMode = true);
        // 查词弹窗换成歌词页主题：Apple 深色档当场生效（app 已是深色时宿主主题
        // 不变、不会发布通知）；MD3 封面取色到达后经宿主通知再换一次。
        _syncDictionaryTheme();
        if (_lyricsWebViewController != null) unawaited(_loadLyricsPage());
        // 书中插图：后台探测尺寸、筛掉外字 / 装饰小图，装好后封面位才开始换图。
        unawaited(_prepareLyricsIllustrations());
      } else {
        // 停放前量下歌词 WebView 的尺寸（BUG-3913）：停在屏外时按同一尺寸摆。
        final RenderObject? lyricsBox = _lyricsWebViewKey.currentContext
            ?.findRenderObject();
        if (lyricsBox is RenderBox && lyricsBox.hasSize) {
          _lyricsWebViewParkedSize = lyricsBox.size;
        }
        _rebuild(() => _lyricsMode = false);
        // 查词弹窗立即回到阅读器主题（不等覆盖层卸载后宿主再发布）。
        _syncDictionaryTheme();
        await _exitLyricsMode();
        await _resolveAndApplyProfile(appModelNoUpdate.database);
      }
    } finally {
      if (mounted) _rebuild(() => _lyricsModeTransition = false);
    }
  }

  Future<void> _loadLyricsPage() async {
    final InAppWebViewController? lyricsController = _lyricsController;
    if (lyricsController == null || _audiobookController == null) return;
    final int loadGeneration = ++_lyricsLoadGeneration;
    _lyricsPageReady = false;
    final AudiobookPlayerController ctrl = _audiobookController!;
    final LyricsCueWindow cueWindow = LyricsCueWindow.select(
      allBookCues: ctrl.allBookCuesSnapshot,
      chapterCues: ctrl.chapterCuesSnapshot,
      // BUG-872：allBookCueIdxAtPosition 在 _currentCue 未填充时按播放器位置回退，
      // 重开书恢复歌词页时窗口锚到已恢复的当前句而非第一句。
      allBookIndex: ctrl.allBookCueIdxAtPosition >= 0
          ? ctrl.allBookCueIdxAtPosition
          : _lyricsEntryCueIndex,
      chapterIndex: ctrl.currentCueIdx >= 0
          ? ctrl.currentCueIdx
          : _lyricsEntryCueIndex,
    );
    _lyricsCueList = cueWindow.cues;
    _lyricsCueIndexOffset = cueWindow.indexOffset;
    _lyricsCueWindowUsesAllBookCues = cueWindow.usesAllBookCues;
    if (_lyricsCueList.isEmpty) {
      await _toggleLyricsMode();
      return;
    }

    final Color accent = _readerLyricAccentColor();

    String colorToCss(Color c) => readerColorToCssRgba(c);

    // 歌词视图跟正文用同一份自定义字体（FontTarget.body）：它显示的就是这本书的
    // 文本，切个视图不该换字体。readerSettings 为 null（极早期调用）时退回空串，
    // 歌词页保持历史 Noto 链。
    final ({String fontFamily, String fontFaces})? bodyFont = ReaderFushiSource
        .readerSettings
        ?.buildCustomFontCss();

    final String html = LyricsModeHtml.generate(
      cues: _lyricsCueList,
      book: _book,
      currentIndex: cueWindow.currentIndex,
      loadGeneration: loadGeneration,
      // 覆盖层：歌词 WebView 透明底，背景由设计系统（模糊封面 / 动态取色）画。
      backgroundColor: 'transparent',
      textColor: colorToCss(_lyricsTextColor()),
      accentColor: colorToCss(accent),
      fontSize: ReaderFushiSource.instance.lyricsFontSize,
      marginTop: ReaderFushiSource.instance.lyricsMarginTop,
      marginBottom: ReaderFushiSource.instance.lyricsMarginBottom,
      marginLeft: ReaderFushiSource.instance.lyricsMarginLeft,
      marginRight: ReaderFushiSource.instance.lyricsMarginRight,
      vertical: ReaderFushiSource.instance.lyricsVerticalWriting,
      blur: ReaderFushiSource.instance.lyricsBlur,
      fontFamilyCss: bodyFont?.fontFamily ?? '',
      fontFaceCss: bodyFont?.fontFaces ?? '',
      theme: _lyricsHtmlTheme,
      textColorOverride: _lyricsCustomTextColor(),
      currentColorOverride: _lyricsCustomHighlightColor(),
      sweep: ReaderFushiSource.instance.lyricsSweep,
      showSkippedText: ReaderFushiSource.instance.lyricsShowSkippedText,
      followLabel: t.audiobook_follow_audio,
      // 标点字形 / 竖排朝向与正文同源（BUG-3281）：同一份内容语言字体链、同一个
      // 竖排字形朝向设置。
      contentLanguage: _contentLanguage,
      verticalTextOrientation:
          ReaderFushiSource.readerSettings?.verticalTextOrientation ?? 'mixed',
    );

    if (!mounted ||
        !_lyricsMode ||
        loadGeneration != _lyricsLoadGeneration ||
        !identical(lyricsController, _lyricsController)) {
      return;
    }
    _lyricsDocumentLoadGeneration = loadGeneration;
    try {
      await lyricsController.loadData(
        data: html,
        mimeType: 'text/html',
        encoding: 'utf-8',
        baseUrl: WebUri(
          Uri.parse('https://fushi.local/lyrics')
              .replace(
                queryParameters: <String, String>{
                  'generation': '$loadGeneration',
                },
              )
              .toString(),
        ),
      );
    } catch (_) {
      if (_lyricsDocumentLoadGeneration == loadGeneration) {
        _lyricsDocumentLoadGeneration = null;
      }
      rethrow;
    }
  }

  /// 用户自定义的歌词文字色（设置「歌词文字色」，哨兵 0 = 未设 → null）。覆盖层主题下
  /// 它覆盖非当前行颜色；未设时跟随设计系统（Apple 白 / MD3 onSurfaceVariant）。
  Color? _lyricsCustomTextColor() {
    final int custom = ReaderFushiSource.instance.lyricsTextColor;
    return custom != 0 ? Color(custom) : null;
  }

  /// 用户自定义的歌词当前行高亮色（设置「当前行高亮色」，哨兵 0 = 未设 → null，
  /// 跟随播放器设计系统）。覆盖层主题下当前行色只认 `--ly-current`，所以每个
  /// 生成 / 热更歌词主题的调用点都必须带上它（源码守卫
  /// lyrics_highlight_color_test.dart）。
  Color? _lyricsCustomHighlightColor() {
    final int custom = ReaderFushiSource.instance.lyricsHighlightColor;
    return custom != 0 ? Color(custom) : null;
  }

  /// TODO-368: 歌词字幕文字色——用户设过自定义色（[ReaderFushiSource.lyricsTextColor]
  /// 非哨兵 0）则用它，否则回退主题文字色 [_themeTextColor]（向后兼容默认跟随主题）。
  Color _lyricsTextColor() {
    final int custom = ReaderFushiSource.instance.lyricsTextColor;
    if (custom != 0) return Color(custom);
    return _themeTextColor();
  }

  /// 歌词 / 悬浮窗高亮强调色：当前明暗下的主题 primary（深色纸底以前硬编码高亮黄，
  /// 用户改主题色它不动；现在两档都跟主题色，深色下的可读性由主题色自己负责——
  /// 编辑页有低对比提示）。
  ///
  /// TODO-953: 必须 context-free。本 getter 经 [AudiobookSession.installReaderSurfaces]
  /// 注入到进程级 session，悬浮窗样式可能在 reader 页 dispose / 未 mounted 之后被求值
  /// （退出书籍后台听书）。原实现浅色支取 reader 页 State.context 上的 ColorScheme
  /// primary，求值时 `State.context`（`_element!`）为 null 抛
  /// "Null check operator used on a null value" → 有声书加载崩溃。改用
  /// [AppModel.buildColorScheme]（themeNotifier 同源，与 `_buildThemeData` 喂给
  /// ThemeData 的 ColorScheme 完全一致，颜色不变），明暗按 [_isReaderThemeDark] 派生，
  /// 彻底去掉对 reader State.context 的脆弱依赖。
  Color _readerLyricAccentColor() {
    return appModel
        .buildColorScheme(
          _isReaderThemeDark ? Brightness.dark : Brightness.light,
        )
        .primary;
  }

  Future<void> _updateLyricsStyleLive() async {
    final InAppWebViewController? lyricsController = _lyricsController;
    if (!mounted || lyricsController == null || !_lyricsPageReady) return;
    final Color fg = _lyricsTextColor();
    final Color accent = _readerLyricAccentColor();
    final double fontSize = ReaderFushiSource.instance.lyricsFontSize;

    String colorToCss(Color c) => readerColorToCssRgba(c);

    final String fgCss = colorToCss(fg);
    final String accentCss = colorToCss(accent);

    final ReaderFushiSource src = ReaderFushiSource.instance;
    final double mt = src.lyricsMarginTop;
    final double mb = src.lyricsMarginBottom;
    final double ml = src.lyricsMarginLeft;
    final double mr = src.lyricsMarginRight;
    final bool blur = src.lyricsBlur;
    try {
      // 背景恒透明（覆盖层的背景由设计系统画）；主题色走 CSS 变量，这里只热更
      // 字号 / 边距（JS 侧在主题态下跳过字面色改写）。
      await lyricsController.evaluateJavascript(
        source:
            'window.__lyricsUpdateStyle && window.__lyricsUpdateStyle('
            "'transparent','$fgCss','$accentCss',$fontSize,$mt,$mb,$ml,$mr);",
      );
      // TODO-908: 模糊态是独立维度，单独热更（不重建整页），与样式同一路下发。
      await lyricsController.evaluateJavascript(
        source: 'window.__lyricsSetBlur && window.__lyricsSetBlur($blur);',
      );
      // 跳读灰显开关同为 live 维度（只换 body class）。
      await lyricsController.evaluateJavascript(
        source:
            'window.__lyricsSetShowSkipped && '
            'window.__lyricsSetShowSkipped(${src.lyricsShowSkippedText});',
      );
      final LyricsHtmlTheme? theme = _lyricsHtmlTheme;
      if (theme != null) {
        await lyricsController.evaluateJavascript(
          source: LyricsModeHtml.applyThemeInvocation(
            theme,
            textColorOverride: _lyricsCustomTextColor(),
            currentColorOverride: _lyricsCustomHighlightColor(),
            sweep: src.lyricsSweep,
          ),
        );
      }
    } catch (e, stack) {
      // 与 _applyStylesLive/_reloadWithCurrentSettings 对称：半销毁 WebView 上
      // eval 抛 PlatformException，安全 no-op（lyrics 路径也不再裸露孤儿 await）。
      ErrorLogService.instance.log(
        'ReaderFushi.updateLyricsStyleLive.eval',
        e,
        stack,
      );
      return;
    }
    // cue 文本随字号/边距重排，激活中的焦点环坐标会过期——重测一次跟上新布局。
    if (_caretOnLyrics) await _caretRefresh();
    if (mounted) _rebuild(() {});
  }

  void _showLyricsModeHintIfNeeded() {
    final ReaderFushiSource src = ReaderFushiSource.instance;
    final bool shown = src.getPreference<bool>(
      key: 'lyrics_mode_hint_shown',
      defaultValue: false,
    );
    if (shown || !mounted) return;
    src.setPreference<bool>(key: 'lyrics_mode_hint_shown', value: true);
    unawaited(
      _withStudyClockPaused(
        () => showAppDialog<void>(
          context: context,
          builder: (BuildContext ctx) => ReaderLyricsModeHintDialog(
            onClose: () => Navigator.of(ctx).pop(),
          ),
        ),
      ),
    );
  }

  /// 退出歌词覆盖层。正文一直在下面跟随音频，通常已经站在当前句上，这里只做
  /// 两件收尾：撤销覆盖层期间的正文强制跟随，并在正文确实落后于音频时（暂停中点行
  /// 跳转 / 拖进度条后还没播放，正文没有被 cue 推进带过去）把它对齐到当前句——与
  /// Niratan `exitLyricsMode` 的 `syncBookmarkToCurrentLyricsCue` 同义。
  Future<void> _exitLyricsMode() async {
    ++_lyricsLoadGeneration;
    ++_lyricsIllustrationGeneration;
    _endLyricsIllustrationStay();
    _lyricsIllustrations = null;
    _lyricsReadyFinalizingGeneration = null;
    _lyricsDocumentLoadGeneration = null;
    // 歌词 WebView 停到屏外（BUG-3913：实例复用，不卸载），[_lyricsController] 随
    // `_lyricsMode` 置 null；复位 surface，否则方向键/A 会被误路由到停放中的
    // fushiLyricsCaret。下次进入重装文档，caret 随文档重新注入。
    if (_caretSurface == CaretSurface.lyrics) {
      _rebuild(() => _caretSurface = CaretSurface.none);
    }
    if (isDictionaryShown) clearDictionaryResult();
    _lyricsPageReady = false;
    _pendingLyricsHintOnReady = false;
    _lyricsCueIndexOffset = 0;
    _lyricsCueWindowUsesAllBookCues = false;
    _lyricsCueList = const [];
    final AudiobookPlayerController? ctrl = _audiobookController;
    if (ctrl == null) return;
    ctrl.setReaderFollowOverride(false);
    final AudioCue? cue = ctrl.currentCue;
    if (cue == null) return;
    final SubtitleRematchFragment? frag = SubtitleRematchCodec.tryDecode(
      cue.textFragmentId,
    );
    if (frag == null || frag.sectionIndex < 0) return;
    if (frag.sectionIndex != _currentChapter) {
      // 正文不在音频所在章（暂停中跨章跳句）：按学习单位锚落到那一句。
      final int? studyOffset = _studyRangeForAudioFragment(frag)?.offset;
      await _navigateToChapter(frag.sectionIndex, charOffset: studyOffset);
      return;
    }
    // 同章：把当前句显式 reveal 一次（滚到那一页），与跟随推进同一条桥。
    final InAppWebViewController? controller = _controller;
    if (controller == null || !_readerContentReady) return;
    _reanchorClearedAt = DateTime.now();
    AudiobookBridge.highlight(controller, cue: cue, reveal: true);
    _scheduleReanchorSettleProgressRefresh();
  }

  // ── 歌词覆盖层：歌词 WebView / 外观 / 操作 ─────────────────────────────
  //
  // 架构（2026-10-04，对齐 Niratan）：歌词模式是盖在阅读器上的一层。正文 WebView
  // 在下面照常存活、照常跟随音频翻页 / 高亮、照常由它的 `_refreshProgress` 给阅读
  // 账本与 StudyClock 记字数和时长。本节只负责「显示」：歌词 WebView（透明底）、
  // 设计系统外观（Apple Music / MD3 播放页）与按钮回调；**不写任何统计**——覆盖层
  // 上的读数是读阅读器现成的数据（[_ReaderLyricsClock]）。

  /// 覆盖层。不在歌词模式时：歌词 WebView 挂上过就停在屏外（BUG-3913，实例复用），
  /// 否则是一个零尺寸占位——两者都占主 Stack 同一个孩子位，保持孩子数恒定。
  Widget _buildLyricsOverlay() {
    final AudiobookPlayerController? ctrl = _audiobookController;
    if (!_lyricsMode || ctrl == null) {
      if (!_lyricsWebViewRetained) return const SizedBox.shrink();
      // 同一个 [_lyricsWebViewKey]：进出覆盖层时 Flutter 把整棵 WebView 子树（含
      // 原生实例）搬过去，不销毁重建。
      return ParkedWebViewSlot(
        size: _lyricsWebViewParkedSize,
        child: _buildLyricsWebView(),
      );
    }
    return Positioned.fill(
      // BUG-1692 同款：排在正文 WebView 之后绘制的层自带 RepaintBoundary。
      child: RepaintBoundary(
        child: FocusTraversalGroup(
          child: ListenableBuilder(
            // 计时键的状态（手动暂停旗）与按钮布局随页面 _rebuild 重建，这里只
            // 额外跟播放控制器。
            listenable: ctrl,
            builder: (BuildContext context, Widget? _) {
              return ReaderLyricsPlayerOverlay(
                key: const ValueKey<String>('fushi_lyrics_overlay'),
                lyricsView: _buildLyricsWebView(),
                data: _lyricsPlayerData(ctrl),
                callbacks: _lyricsPlayerCallbacks(ctrl),
                onHtmlThemeChanged: _applyLyricsHtmlTheme,
                // 跳转回退胶囊：覆盖层常驻 chrome，有历史就显示；坐在底栏上方
                // 让出的带子里，从下往上滑入（反馈 0AwuVqrNFn）。
                navigationAccessory: _jumpHistory.isEmpty
                    ? null
                    : _jumpHistoryPill(visible: true, from: AxisDirection.down),
              );
            },
          ),
        ),
      ),
    );
  }

  LyricsPlayerData _lyricsPlayerData(AudiobookPlayerController ctrl) {
    ImageProvider? cover;
    final String? extractDir = _extractDir;
    if (extractDir != null) {
      final String? path = ReaderFushiSource.resolveCoverFilePath(
        extractDir: extractDir,
        coverPath: _book?.coverHref,
      );
      if (path != null) cover = FileImage(File(path));
    }
    return LyricsPlayerData(
      title: _book?.title ?? '',
      cover: cover,
      isPlaying: ctrl.isPlaying,
      speed: ctrl.speed,
      lyricsMasked: ReaderFushiSource.instance.lyricsBlur,
      clock: _ReaderLyricsClock(this),
      // 覆盖层期间正文强制跟随音频，_currentChapter 就是音频所在章。
      chapterLabel: _book == null ? null : _currentChapterLabel(),
      statsTimerPaused: _studyClockManualPause,
      illustrations: _lyricsIllustrations
        // 提示方式随设置面板实时生效（只影响之后的自动弹出，不通知监听者）。
        ?..autoOpenCard =
            ReaderFushiSource.instance.lyricsIllustrationCue ==
            LyricsIllustrationCue.popup,
      sidesMirrored: ReaderFushiSource.instance.lyricsPanelMirrored,
      controlsStyle: ReaderFushiSource.instance.lyricsControlsStyle,
      compactControlsExpanded:
          ReaderFushiSource.instance.lyricsControlsExpanded,
      wideControls: ReaderFushiSource.instance.lyricsControlLayoutFor(
        compact: false,
      ),
      compactControls: ReaderFushiSource.instance.lyricsControlLayoutFor(
        compact: true,
      ),
    );
  }

  LyricsPlayerCallbacks _lyricsPlayerCallbacks(AudiobookPlayerController ctrl) {
    return LyricsPlayerCallbacks(
      onClose: () => unawaited(_toggleLyricsMode()),
      // × 直接退书回书架：走显式退书漏斗（PopScope flush / closeMedia 照常），
      // 且不先关歌词层——这本书记住的歌词模式保持为真，重开仍是歌词模式
      // （BUG-785；反馈 QvYpZODImz）。
      onExitBook: () => unawaited(_exitReaderBook()),
      onPlayPause: () => unawaited(ctrl.togglePlayPause()),
      // 上一句 / 下一句走 skipToCue 漏斗：正文账本按「显式跳句」结算（BUG-1107），
      // 与底栏 / 快捷键同一语义——歌词层自己不碰统计。
      onPreviousCue: () => unawaited(ctrl.skipToPrevCue()),
      onNextCue: () => unawaited(ctrl.skipToNextCue()),
      // 重播当前句同样经 skipToCue 漏斗（playCueAndContinue），统计口径一致。
      onReplayCue: () => unawaited(ctrl.replayCurrentCue()),
      onSeek: (Duration target) =>
          unawaited(ctrl.seekGlobalMs(target.inMilliseconds)),
      onToggleMask: () => unawaited(_toggleLyricsMask()),
      onOpenStatistics: _openReadingStatistics,
      onSpeedChanged: (double speed) => unawaited(ctrl.setSpeed(speed)),
      onMore: (LyricsMenuAnchor anchor) =>
          unawaited(_showLyricsMoreMenu(anchor)),
      onTypography: (LyricsMenuAnchor anchor) =>
          unawaited(_showLyricsTypographyPanel(anchor)),
      // ±10 秒与有声书侧栏同一条 seekRelative 漏斗。
      onSeekRelative: (int seconds) => unawaited(ctrl.seekRelative(seconds)),
      // 计时键：阅读器手动暂停旗（与顶栏计时键、快捷键 P 同一入口）。
      onToggleStatsTimer: _toggleStudyClockManualPause,
      onSpeedPanel: (LyricsMenuAnchor anchor) =>
          unawaited(_showLyricsSpeedPanel(ctrl, anchor)),
      onOpenIllustration: (int index, {required bool returnToCover}) =>
          unawaited(
            _openLyricsIllustrationViewer(index, returnToCover: returnToCover),
          ),
      onSwapSides: () => unawaited(_toggleLyricsSides()),
      onCompactControlsExpandedChanged: (bool expanded) =>
          unawaited(_setLyricsControlsExpanded(expanded)),
      onTapBackground: () {
        if (isDictionaryShown) clearDictionaryResult();
        _focusOwnership.reclaim(FocusReclaimCause.gesture);
      },
    );
  }

  /// Aa：歌词文字快捷面板（2026-10，用户：「歌词模式字体调节感觉还需要个入口」）。
  /// 字号写 `lyrics_font_size` 后走热更样式通道（[_updateLyricsStyleLive]，不重载
  /// 歌词页）；竖排写 `lyrics_vertical_writing` 后整页重建（[_loadLyricsPage]，排版
  /// 方向变了热更不够）；「更多歌词设置」打开阅读设置（歌词模式下首页即「歌词
  /// 模式」页）。面板从按钮自己的 context 弹，跟随歌词模式主题。
  ///
  /// 面板压着歌词页期间停表（BUG-2208，与阅读器的面板同一口径）。
  Future<void> _showLyricsTypographyPanel(LyricsMenuAnchor anchor) async {
    final ReaderFushiSource src = ReaderFushiSource.instance;
    await _withStudyClockPaused(
      () => showLyricsTypographyPanel(
        anchorContext: anchor.context,
        fontSize: src.lyricsFontSize,
        vertical: src.lyricsVerticalWriting,
        onFontSizeChanged: (double v) => unawaited(
          applyLyricsFontSize(
            value: v,
            write: src.setLyricsFontSize,
            applyLive: _updateLyricsStyleLive,
          ),
        ),
        onVerticalChanged: (bool v) => unawaited(
          applyLyricsVertical(
            value: v,
            write: src.setLyricsVerticalWriting,
            reload: _loadLyricsPage,
          ),
        ),
        onOpenMore: () =>
            unawaited(_showAppearanceSheet(initialSettingsTab: 'lyrics')),
      ),
    );
  }

  /// 倍速面板：页面弹（不是按钮自己弹），面板压着歌词页期间停表（BUG-2208，
  /// 与阅读器的面板同一口径）。面板从按钮 context 弹，跟随歌词模式主题。
  Future<void> _showLyricsSpeedPanel(
    AudiobookPlayerController ctrl,
    LyricsMenuAnchor anchor,
  ) async {
    if (!mounted || !anchor.context.mounted) return;
    await _withStudyClockPaused(
      () => showLyricsSpeedPanel(
        anchorContext: anchor.context,
        speed: ctrl.speed,
        onChanged: (double speed) => unawaited(ctrl.setSpeed(speed)),
      ),
    );
  }

  /// 按钮布局编辑器（阅读设置「歌词模式」页的「按钮布局」入口）。写偏好后整页
  /// 重建，覆盖层按新布局重排，改动实时可见。
  Future<void> _showLyricsControlLayoutEditor() async {
    if (!mounted) return;
    final ReaderFushiSource src = ReaderFushiSource.instance;
    await _withStudyClockPaused(
      () => showLyricsControlLayoutEditorSheet(
        context: context,
        read: (bool compact) => src.lyricsControlLayoutFor(compact: compact),
        write: (bool compact, LyricsControlLayout layout) async {
          await src.setLyricsControlLayoutFor(compact: compact, layout: layout);
          if (mounted) _rebuild(() {});
        },
      ),
    );
  }

  /// 布局「更多」区里的歌词按钮在 ⋯ 菜单里的那一项。需要锚点的面板（倍速 / Aa）
  /// 锚在 ⋯ 键上。当前形态下不渲染的按钮（窄屏的左右互换、没有退书回调时的
  /// 书籍模式）返回 null，与覆盖层上的判据一致。
  ReaderHeaderAction? _lyricsControlMenuAction(
    LyricsControlItem item,
    AudiobookPlayerController ctrl,
    LyricsMenuAnchor anchor, {
    required bool wide,
  }) {
    final IconData icon = lyricsControlItemIcon(item);
    final String label = lyricsControlItemLabel(item);
    switch (item) {
      case LyricsControlItem.speed:
        return ReaderHeaderAction(
          icon: icon,
          label: label,
          onPressed: () => unawaited(_showLyricsSpeedPanel(ctrl, anchor)),
        );
      case LyricsControlItem.studyTimer:
        final bool paused = _studyClockManualPause;
        return ReaderHeaderAction(
          icon: paused ? FushiIcons.timerOff : FushiIcons.timer,
          label: paused
              ? t.reader_stats_clock_resume
              : t.reader_stats_clock_pause,
          onPressed: _toggleStudyClockManualPause,
        );
      case LyricsControlItem.replayCue:
        return ReaderHeaderAction(
          icon: icon,
          label: label,
          onPressed: () => unawaited(ctrl.replayCurrentCue()),
        );
      case LyricsControlItem.mask:
        return ReaderHeaderAction(
          icon: icon,
          label: label,
          onPressed: () => unawaited(_toggleLyricsMask()),
        );
      case LyricsControlItem.typography:
        return ReaderHeaderAction(
          icon: icon,
          label: label,
          onPressed: () => unawaited(_showLyricsTypographyPanel(anchor)),
        );
      case LyricsControlItem.statistics:
        return ReaderHeaderAction(
          icon: icon,
          label: label,
          onPressed: _openReadingStatistics,
        );
      case LyricsControlItem.bookMode:
        return ReaderHeaderAction(
          icon: icon,
          label: label,
          onPressed: () => unawaited(_toggleLyricsMode()),
        );
      case LyricsControlItem.swapSides:
        if (!wide) return null;
        return ReaderHeaderAction(
          icon: icon,
          label: label,
          onPressed: () => unawaited(_toggleLyricsSides()),
        );
    }
  }

  /// 歌词模式按钮的快捷键执行体（[ShortcutAction.audiobookReplaySentence] 等，
  /// 由 `_executeShortcutAction` 派发）。与覆盖层按钮同一漏斗：重播 / ±10 秒 /
  /// 倍速经播放控制器，遮罩写同一个偏好；倍速按面板同一档（0.05×）步进 0.1×。
  void _runLyricsShortcut(
    ShortcutAction action,
    AudiobookPlayerController ctrl,
  ) {
    switch (action) {
      case ShortcutAction.audiobookReplaySentence:
        unawaited(ctrl.replayCurrentCue());
      case ShortcutAction.audiobookSeekBackward:
        unawaited(ctrl.seekRelative(-10));
      case ShortcutAction.audiobookSeekForward:
        unawaited(ctrl.seekRelative(10));
      case ShortcutAction.audiobookSpeedUp:
        unawaited(ctrl.setSpeed(AudiobookSpeedSlider.snap(ctrl.speed + 0.1)));
      case ShortcutAction.audiobookSpeedDown:
        unawaited(ctrl.setSpeed(AudiobookSpeedSlider.snap(ctrl.speed - 0.1)));
      case ShortcutAction.audiobookToggleLyricsMode:
        unawaited(_toggleLyricsMode());
      case ShortcutAction.audiobookToggleLyricsMask:
        unawaited(_toggleLyricsMask());
      default:
        break;
    }
  }

  /// 宽屏左右整块互换（偏好 `lyrics_panel_mirrored`）。只换覆盖层布局：歌词
  /// WebView 在 Stack 里的位置不变、只换矩形，不重建平台视图、不重载歌词页。
  Future<void> _toggleLyricsSides() async {
    final ReaderFushiSource src = ReaderFushiSource.instance;
    await src.setLyricsPanelMirrored(!src.lyricsPanelMirrored);
    if (mounted) _rebuild(() {});
  }

  /// 新版窄屏播放卡展开 / 收起（偏好 `lyrics_controls_expanded`，记住上次状态）。
  /// 只换覆盖层布局：歌词 WebView 仍是同一个孩子、只换矩形。
  Future<void> _setLyricsControlsExpanded(bool expanded) async {
    final ReaderFushiSource src = ReaderFushiSource.instance;
    if (src.lyricsControlsExpanded == expanded) return;
    await src.setLyricsControlsExpanded(expanded);
    if (mounted) _rebuild(() {});
  }

  /// 👁：歌词遮罩（听力沉浸模糊，设置项 `lyrics_blur`）。与设置面板同一个偏好。
  Future<void> _toggleLyricsMask() async {
    final ReaderFushiSource src = ReaderFushiSource.instance;
    await src.setLyricsBlur(!src.lyricsBlur);
    if (!mounted) return;
    await _updateLyricsStyleLive();
    if (mounted) _rebuild(() {});
  }

  /// ⋯：阅读器顶栏 / 底栏的完整操作（目录、设置、有声书面板、统计、跟随、全屏…）。
  /// 覆盖层自己只放播放控件，其余能力一律复用 [_readerControlAction]——与顶栏
  /// 按钮同一个真相源，歌词模式不丢任何入口。
  ///
  /// 菜单从按钮自己的 context 弹（[LyricsMenuAnchor.context]）：歌词模式整棵
  /// 子树换了封面取色主题，页面 context 在它之外，从页面弹会是全局表面色。
  Future<void> _showLyricsMoreMenu(LyricsMenuAnchor menuAnchor) async {
    final Rect anchor = menuAnchor.rect;
    final BuildContext menuContext = menuAnchor.context;
    // 布局「更多」区的歌词按钮排在前面，其后是阅读器的完整操作。
    final AudiobookPlayerController? ctrl = _audiobookController;
    final bool wide = lyricsPlayerIsWide(MediaQuery.sizeOf(menuContext));
    final List<ReaderHeaderAction> actions = <ReaderHeaderAction>[
      // 新版宽屏右岛放不下、收进 ⋯ 的按钮排最前（顺序 = 岛上的显示顺序）。
      if (ctrl != null)
        for (final LyricsControlItem item in menuAnchor.collapsedItems)
          ?_lyricsControlMenuAction(item, ctrl, menuAnchor, wide: wide),
      if (ctrl != null)
        for (final LyricsControlItem item
            in ReaderFushiSource.instance
                .lyricsControlLayoutFor(compact: !wide)
                .itemsIn(LyricsControlSlot.overflow))
          ?_lyricsControlMenuAction(item, ctrl, menuAnchor, wide: wide),
      for (final ReaderControlItem item in kLyricsOverlayMenuItems)
        if (_shouldRenderReaderControl(item)) _readerControlAction(item),
    ];
    if (actions.isEmpty || !mounted || !menuContext.mounted) return;
    final RenderBox overlay =
        Overlay.of(menuContext).context.findRenderObject()! as RenderBox;
    final Rect local = Rect.fromPoints(
      overlay.globalToLocal(anchor.topLeft),
      overlay.globalToLocal(anchor.bottomRight),
    );
    final ReaderHeaderAction? choice = await showFushiMenu<ReaderHeaderAction>(
      context: menuContext,
      position: RelativeRect.fromRect(local, Offset.zero & overlay.size),
      items: <PopupMenuEntry<ReaderHeaderAction>>[
        for (final ReaderHeaderAction action in actions)
          PopupMenuItem<ReaderHeaderAction>(
            value: action,
            enabled: action.onPressed != null,
            child: Row(
              children: <Widget>[
                FushiIcon(action.icon, size: 20),
                const SizedBox(width: 12),
                Flexible(child: Text(action.label)),
              ],
            ),
          ),
      ],
    );
    choice?.onPressed?.call();
  }

  /// 覆盖层外观给出的歌词 HTML 主题（设计系统切换 / 封面取色到达）。
  void _applyLyricsHtmlTheme(LyricsHtmlTheme theme) {
    if (theme == _lyricsHtmlTheme) return;
    _lyricsHtmlTheme = theme;
    final InAppWebViewController? lyrics = _lyricsController;
    if (lyrics == null || !_lyricsPageReady) return;
    _evalLyrics(
      lyrics,
      LyricsModeHtml.applyThemeInvocation(
        theme,
        textColorOverride: _lyricsCustomTextColor(),
        currentColorOverride: _lyricsCustomHighlightColor(),
        sweep: ReaderFushiSource.instance.lyricsSweep,
      ),
      'applyTheme',
    );
  }

  /// 歌词 WebView 上的 fire-and-forget 求值：半销毁 WebView 抛的异常就地记录，
  /// 不逃出当前 zone（与 `_selectTextAt` 同款兜底）。
  void _evalLyrics(InAppWebViewController lyrics, String source, String tag) {
    unawaited(
      lyrics.evaluateJavascript(source: source).catchError((
        Object e,
        StackTrace s,
      ) {
        ErrorLogService.instance.log('ReaderFushi.lyrics.$tag', e, s);
        return null;
      }),
    );
  }

  /// cue 推进 / 播放态翻转 / seek 时同步歌词层：当前行高亮、（跟随开着时）滚动、
  /// 逐字扫过进度。只碰歌词 WebView，不碰正文、不碰统计。
  void _syncLyricsOverlayCue(
    AudiobookPlayerController controller, {
    required bool forceReveal,
  }) {
    final InAppWebViewController? lyrics = _lyricsController;
    if (lyrics == null || !_lyricsPageReady) return;
    // 正文按章跟随，控制器的 currentCue 是章内 cue；整书下标先按身份映射，映射
    // 不到（跨章过渡的瞬间）再按播放位置在整书 cue 里解析——歌词列表是整书的。
    // 没有整书 cue 的书，歌词列表就是装载时那一章的 cue；正文跨章后控制器换了章
    // cue 列表，歌词跟着重开（否则下标指向的是另一章的句子）。
    if (!_lyricsCueWindowUsesAllBookCues &&
        controller.chapterCuesSnapshot.isNotEmpty &&
        !identical(controller.chapterCuesSnapshot, _lyricsCueList)) {
      unawaited(_loadLyricsPage());
      return;
    }
    int sourceIdx;
    if (_lyricsCueWindowUsesAllBookCues) {
      // BUG-3777 R1：播放所在句——跨章过渡期间（后台正文 WebView 被节流、跨章迟迟
      // 完不成）正文跟随句冻结，歌词层照样跟着声音走。
      sourceIdx = controller.lyricsCueAllBookIdx;
    } else {
      sourceIdx = controller.currentCueIdx;
    }
    // BUG-767: sourceIdx < 0 = 当前 cue 暂不可解析（cue 间隙 / 尚未匹配）。此时保位
    // 不跳、绝不重载（旧码在此重开歌词页 → 无限重载、高亮恒回第一句）。
    if (sourceIdx < 0) return;
    final int idx = sourceIdx - _lyricsCueIndexOffset;
    if (idx < 0 || idx >= _lyricsCueList.length) {
      // cue 真的移出已载窗口 → 重开窗口居中当前 cue（唯一合法的重载）。
      if (_lyricsCueWindowUsesAllBookCues) unawaited(_loadLyricsPage());
      return;
    }
    // followAudio OFF → scroll=false：只换当前行高亮、不自动滚（用户可自由滚动
    // 歌词）。forceReveal（切「跟随音频」ON 触发的 snap 回中）也放行滚动。
    final bool scroll = controller.followAudio.value || forceReveal;
    final bool playing = controller.isPlaying;
    final AudioCue cue = _lyricsCueList[idx];
    _observeLyricsIllustrations(cue, controller.globalPosition);
    final int rawDurMs = cue.endMs - cue.startMs;
    final int durMs = rawDurMs > 0 ? rawDurMs : 1;
    final int posMs =
        controller.globalPosition.inMilliseconds -
        controller.delayMs.value -
        controller.globalMsOfCue(cue);
    final double fraction = (posMs / durMs).clamp(0.0, 1.0);
    final double ratePerSec = playing ? controller.speed * 1000 / durMs : 0;
    _evalLyrics(
      lyrics,
      'if(window.__lyricsSetCue)'
          'window.__lyricsSetCue($idx, $scroll);'
          // BUG-757: snap 那一刻 cue 往往没变，__lyricsSetCue 的
          // `index===_currentIdx` 早退会吞掉这次回中 → 打开跟随画面不动。
          // forceReveal 下再显式 __lyricsScrollToCue 强制把当前句居中，绕过早退。
          '${forceReveal ? 'if(window.__lyricsScrollToCue)'
                    'window.__lyricsScrollToCue($idx);' : ''}'
          'if(window.__lyricsSetPlaying)window.__lyricsSetPlaying($playing);'
          // BUG-3777 R2：带上算出 fraction 的墙钟时刻，JS 执行晚了按速率自己补上延迟。
          'if(window.__lyricsSetProgress)'
          'window.__lyricsSetProgress($idx,${fraction.toStringAsFixed(4)},'
          '${ratePerSec.toStringAsFixed(5)},'
          '${DateTime.now().millisecondsSinceEpoch});',
      'setCue',
    );
  }

  /// BUG-3777 R2：回前台 / 歌词文档重新可见时按当前播放位置无条件重推歌词层快照
  /// （当前行 / 播放态 / 扫过进度）。不走正文的 reveal / 跨章门控——那些挡住的是
  /// 正文视口，歌词层是整书列表；滚不滚仍由 [_syncLyricsOverlayCue] 看跟随开关、
  /// JS 看浏览态。
  void _resyncLyricsOverlayToAudio() {
    if (!_lyricsMode) return;
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null) return;
    _syncLyricsOverlayCue(controller, forceReveal: false);
  }

  // ── 歌词模式插图（2026-10-07）─────────────────────────────────────────
  //
  // 播放走过书中插图时，覆盖层封面位换成插图（横屏左栏 / 竖屏小封面）。判据见
  // lyrics_illustrations.dart：插图位置是 `EpubImageRef` 的（章, 章内学习单位
  // 偏移），播放位置是当前 cue 的 `fushi-cue://` 片段经 [_studyRangeForAudioFragment]
  // 映射出的同一把尺——与「退出歌词模式时把正文对齐到当前句」同一条映射。

  /// 进歌词模式时探测本书插图：解析每张图的磁盘文件、在 isolate 里读文件头拿像素
  /// 尺寸，经 [classifyLyricsIllustration] 筛掉封面、外字、章节装饰等小图，再按
  /// 当前播放位置定好「已听到」的基线（基线之前的插图不弹出）。
  Future<void> _prepareLyricsIllustrations() async {
    final int generation = ++_lyricsIllustrationGeneration;
    _endLyricsIllustrationStay();
    _lyricsIllustrations = null;
    final EpubBook? book = _book;
    final String? extractDir = _extractDir;
    if (book == null || extractDir == null) return;
    final List<EpubImageRef> refs = await _loadBookImagesOffUiIsolate(
      book,
      extractDir,
    );
    if (!mounted ||
        !_lyricsMode ||
        generation != _lyricsIllustrationGeneration) {
      return;
    }
    final Map<String, String> pathByKey = <String, String>{};
    for (final EpubImageRef ref in refs) {
      final File? file = _readerImageFileForUrl(
        ReaderFushiSource.epubUrl(ref.src),
      );
      if (file != null) pathByKey[ref.revealKey] = file.path;
    }
    final String? coverPath = ReaderFushiSource.resolveCoverFilePath(
      extractDir: extractDir,
      coverPath: book.coverHref,
    );
    final Map<String, LyricsIllustrationFileProbe> probes = await compute(
      probeLyricsIllustrationFiles,
      <String>{...pathByKey.values, if (coverPath != null) coverPath}.toList(),
    );
    if (!mounted ||
        !_lyricsMode ||
        generation != _lyricsIllustrationGeneration) {
      return;
    }
    final List<LyricsIllustration> items = selectLyricsIllustrations(
      refs: refs,
      pathByKey: pathByKey,
      probes: probes,
      coverPath: coverPath,
    ).items;
    if (items.isEmpty) return;
    final AudiobookPlayerController? ctrl = _audiobookController;
    final AudioCue? cue = ctrl == null ? null : _lyricsCurrentAudioCue(ctrl);
    final ReaderFushiSource src = ReaderFushiSource.instance;
    final LyricsIllustrationController illustrations =
        LyricsIllustrationController()
          // 竖排从右往左的书：插图翻页方向镜像（反馈 KhrrCkFteH）。
          ..rightToLeft = _isRtlReading
          ..autoOpenCard =
              src.lyricsIllustrationCue == LyricsIllustrationCue.popup
          ..load(
            items,
            position: cue == null ? null : _lyricsBookPositionOfCue(cue),
            audioPosition: ctrl?.globalPosition,
          );
    _rebuild(() => _lyricsIllustrations = illustrations);
  }

  /// 播放器当前所在的 cue（整书 cue 优先，按播放位置解析；暂停重开时
  /// `currentCue` 可能还没被 tick 填充）。
  AudioCue? _lyricsCurrentAudioCue(AudiobookPlayerController ctrl) {
    final List<AudioCue> all = ctrl.allBookCuesSnapshot;
    final int index = ctrl.allBookCueIdxAtPosition;
    if (index >= 0 && index < all.length) return all[index];
    return ctrl.currentCue;
  }

  /// cue 在书中的位置（章 + 章内学习单位偏移）。有 `fushi-cue://` 片段的 cue 走
  /// 精确映射；只有章 href 的 cue 退到章首（只认得章首插图）；都没有为 null。
  /// 片段坐标映射不出来（失效坐标）也为 null——不能退到章首：那会把「已听到」
  /// 往回拽、收回正在显示的插图，下一句映射正常时又当成「刚走过」重新弹出。
  LyricsBookPosition? _lyricsBookPositionOfCue(AudioCue cue) {
    final SubtitleRematchFragment? frag = SubtitleRematchCodec.tryDecode(
      cue.textFragmentId,
    );
    if (frag != null && frag.sectionIndex >= 0) {
      final int? offset = _studyRangeForAudioFragment(frag)?.offset;
      if (offset == null) return null;
      return LyricsBookPosition(frag.sectionIndex, offset);
    }
    final int chapter = _chapterIndexForCue(cue);
    return chapter >= 0 ? LyricsBookPosition(chapter, 0) : null;
  }

  /// cue 推进时喂插图状态机（换图 / 收回都在状态机里判）。
  ///
  /// 「弹出停留」（偏好 `lyrics_illustration_cue` = popup，默认）：顺着播放新走过
  /// 插图时状态机已把插图卡弹出，这里再按「图片暂停」秒数（`imagePauseSec`，与正文
  /// 同一个设置、同一条 [AudiobookPlayerController.triggerImagePause] 原语）停留。
  /// 暂停态、拖进度 / ±10 秒、显式跳句经过插图都不停：只认「正在播、且两次观测
  /// 之间控制器没有登记过跳转（[AudiobookPlayerController.playbackJumpSerial]）」的
  /// 连续播放。同一张插图一次经过只停一次（状态机
  /// 只在新走过时报一次）。
  void _observeLyricsIllustrations(AudioCue cue, Duration audioPosition) {
    final LyricsIllustrationController? illustrations = _lyricsIllustrations;
    if (illustrations == null) return;
    final LyricsBookPosition? position = _lyricsBookPositionOfCue(cue);
    if (position == null) return;
    final AudiobookPlayerController? ctrl = _audiobookController;
    final ({int jumpSerial, int audioMs})? last =
        _lyricsIllustrationLastObservation;
    _lyricsIllustrationLastObservation = ctrl == null
        ? null
        : (
            jumpSerial: ctrl.playbackJumpSerial,
            audioMs: audioPosition.inMilliseconds,
          );
    final bool revealed = illustrations.observe(
      position,
      audioPosition: audioPosition,
    );
    if (!revealed || ctrl == null) return;
    if (ReaderFushiSource.instance.lyricsIllustrationCue !=
        LyricsIllustrationCue.popup) {
      return;
    }
    final bool continuous =
        last != null &&
        isContinuousLyricsPlayback(
          playing: ctrl.isPlaying,
          previousJumpSerial: last.jumpSerial,
          currentJumpSerial: ctrl.playbackJumpSerial,
          audioDeltaMs: audioPosition.inMilliseconds - last.audioMs,
        );
    if (!continuous) return;
    _beginLyricsIllustrationStay(ctrl, illustrations);
  }

  void _beginLyricsIllustrationStay(
    AudiobookPlayerController ctrl,
    LyricsIllustrationController illustrations,
  ) {
    _endLyricsIllustrationStay();
    ctrl.triggerImagePause();
    // 「图片暂停」关着（0 秒）/ 阅读器不可见时控制器不停：卡照样弹出，不停留。
    if (!ctrl.isImagePaused) return;
    _lyricsIllustrationStay = (ctrl: ctrl, ill: illustrations);
    ctrl.addListener(_onLyricsIllustrationStayChanged);
    illustrations.addListener(_onLyricsIllustrationStayChanged);
  }

  void _onLyricsIllustrationStayChanged() {
    final ({AudiobookPlayerController ctrl, LyricsIllustrationController ill})?
    stay = _lyricsIllustrationStay;
    if (stay == null) return;
    if (!stay.ctrl.isImagePaused) {
      // 停留结束（到点自动续播 / 用户按了播放或暂停）：收起插图卡，插图位留着
      // 缩略图 + 红点，还能点开看。
      _endLyricsIllustrationStay();
      stay.ill.closeCard();
      return;
    }
    if (!stay.ill.cardVisible) {
      // 用户手动关了卡：立刻结束停留、继续播放（play 会成对作废停留计时器）。
      _endLyricsIllustrationStay();
      unawaited(stay.ctrl.play());
    }
  }

  void _endLyricsIllustrationStay() {
    final ({AudiobookPlayerController ctrl, LyricsIllustrationController ill})?
    stay = _lyricsIllustrationStay;
    if (stay == null) return;
    _lyricsIllustrationStay = null;
    stay.ctrl.removeListener(_onLyricsIllustrationStayChanged);
    stay.ill.removeListener(_onLyricsIllustrationStayChanged);
  }

  /// 插图大图浏览（可缩放，看清印在插图上的文字）。音频照常播放；阅读计时与正文
  /// 态看大图一致（2026-10-25 用户：歌词模式计时要与阅读器行为一致）——大图是整页
  /// 路由，盖住阅读器期间经 [RouteAware.didPushNext] 停表，关掉续表。
  Future<void> _openLyricsIllustrationViewer(
    int index, {
    required bool returnToCover,
  }) async {
    final LyricsIllustrationController? illustrations = _lyricsIllustrations;
    if (illustrations == null || !mounted) return;
    await showLyricsIllustrationViewer(
      context,
      controller: illustrations,
      index: index,
      returnToCover: returnToCover,
    );
  }

  /// 歌词文档就绪（`onLyricsReady` 桥 / onLoadStop 二选一，幂等 finalize 之后）。
  /// 原先是 `_onChapterLoadComplete` 的歌词分支；覆盖层架构下正文与歌词是两个
  /// WebView，歌词就绪与正文就绪互不相干——这里**不**碰 `_readerContentReady`、
  /// 不建 / 起 StudyClock（统计归正文）。
  Future<void> _onLyricsDocumentReady(
    InAppWebViewController controller, {
    required int generation,
  }) async {
    bool currentLyricsLoad() =>
        mounted &&
        _lyricsMode &&
        generation == _lyricsLoadGeneration &&
        identical(controller, _lyricsController);
    if (!currentLyricsLoad()) return;
    _rebuild(() => _lyricsPageReady = true);
    // 首次进入歌词模式的提示对话框：挂在歌词文档真正就绪的这一刻消费一次性旗。
    if (_pendingLyricsHintOnReady) {
      _pendingLyricsHintOnReady = false;
      _showLyricsModeHintIfNeeded();
    }
    // 动画开关（系统「减少动态效果」/ 墨水屏）：弹簧滚动改为直接落位。
    final bool reduceMotion =
        MediaQuery.disableAnimationsOf(context) || appModel.einkMode;
    final LyricsHtmlTheme? theme = _lyricsHtmlTheme;
    await controller.evaluateJavascript(
      source:
          'window.__lyricsReduceMotion = $reduceMotion;'
          "document.body.classList.toggle('ly-reduce', $reduceMotion);"
          '${theme == null ? '' : LyricsModeHtml.applyThemeInvocation(theme, textColorOverride: _lyricsCustomTextColor(), currentColorOverride: _lyricsCustomHighlightColor(), sweep: ReaderFushiSource.instance.lyricsSweep)}',
    );
    if (!currentLyricsLoad()) return;
    // 注入歌词专用行级 caret（键盘/手柄逐词查词），镜像 reader 的 fushiCaret 注入。
    // 文档刚加载，caret inactive；surface 在 _enterCaret 成功时才置 lyrics。
    await controller.evaluateJavascript(
      source: ReaderLyricsCaretScripts.source(),
    );
    if (!currentLyricsLoad()) return;
    await controller.evaluateJavascript(
      source: ReaderLyricsCaretScripts.initInvocation(
        color: _caretRingColorCss(),
        insetTop: 0,
        insetBottom: 0,
      ),
    );
    if (!currentLyricsLoad()) return;
    final AudiobookPlayerController? ctrl = _audiobookController;
    if (ctrl != null) _syncLyricsOverlayCue(ctrl, forceReveal: false);
    await _applyLyricsFavorites();
    if (!currentLyricsLoad()) return;
    // BUG-844: 歌词是独立文档，纯悬停查词开关要在就绪时同步进新文档。
    await _applyHoverAutoLookupLive();
  }

  /// 歌词 WebView（透明底，盖在设计系统画的背景上）。JS 桥只挂歌词文档用得到的：
  /// 选词查词 / 拖选菜单 / 悬停查词 / 点空白 / 中键与点行跳句 / 就绪。
  Widget _buildLyricsWebView() {
    final Widget webView = InAppWebView(
      key: const ValueKey<String>('fushi_lyrics_webview'),
      contextMenu: ContextMenu(
        settings: ContextMenuSettings(hideDefaultSystemContextMenuItems: true),
        menuItems: const <ContextMenuItem>[],
      ),
      initialUserScripts: UnmodifiableListView<UserScript>(<UserScript>[
        UserScript(
          source:
              'window.onerror=function(m,s,l,c,e){console.error("__FUSHI_JS_ERROR__ "+m+" at "+s+":"+l+":"+c);return false;};',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      initialSettings: InAppWebViewSettings(
        // 透明底：Apple 的模糊封面 / MD3 的动态取色渐变从歌词后面透出来。
        transparentBackground: true,
        disableContextMenu: isWindowsPlatform,
        // BUG-2607 同款：iOS 关原生文本交互，app 自绘选区不受影响。
        isTextInteractionEnabled: !isIOSPlatform,
        // BUG-3356 同款：WKWebView 边缘横滑默认是 WebView 历史前进 / 后退，歌词文档
        // 每次重载都 loadData，侧滑会退回旧文档。
        allowsBackForwardNavigationGestures: false,
        verticalScrollBarEnabled: false,
        horizontalScrollBarEnabled: false,
        overScrollMode: OverScrollMode.NEVER,
        disallowOverScroll: true,
        databaseEnabled: false,
        domStorageEnabled: false,
        // 歌词文档用正文同一份自定义字体（fushi.local 资源），拦截通道与正文一致。
        resourceCustomSchemes: webViewUsesCustomSchemeTransport
            ? <String>[ReaderFushiSource.kResourceScheme]
            : const <String>[],
        useShouldInterceptRequest: !webViewUsesCustomSchemeTransport,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
        useShouldOverrideUrlLoading: true,
      ),
      onWebViewCreated: (InAppWebViewController controller) {
        // 停放中创建完成（进入后立刻退出 / 停放时 renderer 死亡换代）也记下：实例
        // 复用（BUG-3913），下次进入由 _toggleLyricsMode 装载文档。
        _lyricsWebViewController = controller;
        controller.addJavaScriptHandler(
          handlerName: 'onTextSelected',
          callback: (List<dynamic> args) async {
            if (args.isEmpty || !_lyricsMode) return;
            try {
              final Map<String, dynamic> payload =
                  jsonDecode(args[0] as String) as Map<String, dynamic>;
              await _handleTextSelected(ReaderSelectionData.fromJson(payload));
            } catch (e, stack) {
              ErrorLogService.instance.log(
                'ReaderFushi.lyrics.onTextSelected',
                e,
                stack,
              );
            }
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'onSelectionMenu',
          callback: (List<dynamic> args) async {
            if (args.isEmpty || !_lyricsMode) return;
            try {
              final Map<String, dynamic> payload =
                  jsonDecode(args[0] as String) as Map<String, dynamic>;
              await _handleSelectionMenu(ReaderSelectionData.fromJson(payload));
            } catch (e, stack) {
              ErrorLogService.instance.log(
                'ReaderFushi.lyrics.onSelectionMenu',
                e,
                stack,
              );
            }
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'onShiftHover',
          callback: (List<dynamic> args) {
            if (args.length < 2 || !_lyricsMode) return;
            final double x = _ReaderFushiPageState._toDouble(args[0]) ?? 0;
            final double y = _ReaderFushiPageState._toDouble(args[1]) ?? 0;
            _selectTextAt(x, y, fromHover: true);
          },
        );
        // 歌词里点到空白（选词脚本命中空白回 onTapEmpty，歌词页自身命中容器外回
        // onLyricsTapEmpty）：有查词弹窗就关栈；否则只清残留选区。覆盖层自带播放
        // 控件，不再像旧歌词页那样靠点空白唤出底栏。收尾 reclaim 阅读焦点：本次
        // pointer 手势把 OS 焦点交给了 WebView，不夺回就收不到 ESC（BUG-136/756）。
        // 返回 true = 这一下已被就地消费（关抽屉 / 关查词弹窗），不再 reclaim——
        // 那两种情况各自的收尾会归还焦点。
        bool lyricsTapEmptyConsumed() {
          if (!_lyricsMode) return true;
          if (_closeSideSheetForWebViewPointer()) return true;
          if (isDictionaryShown) {
            clearDictionaryResult();
            return true;
          }
          unawaited(_clearReaderAppSelection());
          return false;
        }

        controller.addJavaScriptHandler(
          handlerName: 'onTapEmpty',
          callback: (List<dynamic> _) {
            if (lyricsTapEmptyConsumed()) return;
            _focusOwnership.reclaim(FocusReclaimCause.gesture);
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'onLyricsTapEmpty',
          callback: (List<dynamic> _) {
            if (lyricsTapEmptyConsumed()) return;
            _focusOwnership.reclaim(FocusReclaimCause.gesture);
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'onLyricsPointerSeek',
          callback: (List<dynamic> args) {
            if (args.length < 2 || _audiobookController == null) return;
            final int button = (args[0] as num?)?.toInt() ?? -1;
            final int idx = (args[1] as num?)?.toInt() ?? -1;
            final AudioCue? cue = cueForLyricsPointer(
              appModel.shortcutRegistry,
              button,
              idx,
              _lyricsCueList,
            );
            if (cue != null) _audiobookController!.playCueAndContinue(cue);
          },
        );
        // 点在行的字形之外 = 跳到这一句播放（Apple Music / Niratan 点行跳转）。
        controller.addJavaScriptHandler(
          handlerName: 'onLyricsCueTap',
          callback: (List<dynamic> args) {
            if (args.isEmpty || _audiobookController == null) return;
            final int idx = (args[0] as num?)?.toInt() ?? -1;
            if (idx < 0 || idx >= _lyricsCueList.length) return;
            // BUG-2276：抽屉压着歌词时，这一下是「点遮罩关抽屉」，不是跳播。
            if (_closeSideSheetForWebViewPointer()) return;
            if (isDictionaryShown) clearDictionaryResult();
            unawaited(
              _audiobookController!.playCueAndContinue(_lyricsCueList[idx]),
            );
            _focusOwnership.reclaim(FocusReclaimCause.gesture);
          },
        );
        // BUG-1809：iOS WKWebView 的 loadData() 可返回却不发 onLoadStop。
        // LyricsModeHtml 在 DOM API 全部就绪后主动回传；与 onLoadStop 共用幂等
        // finalize，谁先到谁完成，另一条只读到 ready 后早返回。
        controller.addJavaScriptHandler(
          handlerName: 'onLyricsReady',
          callback: (List<dynamic> args) {
            final dynamic raw = args.isEmpty ? null : args.first;
            final int? generation = raw is num
                ? raw.toInt()
                : int.tryParse(raw?.toString() ?? '');
            if (generation == null) return false;
            return _finalizeLyricsDocumentIfReady(
              controller,
              generation: generation,
            );
          },
        );
        // BUG-3777 R2：歌词文档变回可见（visibilitychange）→ 重推快照。
        controller.addJavaScriptHandler(
          handlerName: 'onLyricsVisible',
          callback: (_) {
            if (identical(controller, _lyricsController)) {
              _resyncLyricsOverlayToAudio();
            }
          },
        );
        // 反馈 0rvPl6s6tR：歌词「手动滚动脱离跟随」的判据诊断（JS 侧每类 30 秒最多一次）。
        // user-scroll = 有用户输入的 scroll 让歌词进了浏览态；ignored-scroll = 没有用户输入的
        // scroll（迟到的程序化滚动 / 重排钳位），已不再打断跟随。随反馈日志上传，下次能看出跟随
        // 中断时到底有没有用户输入、同时 app 在做什么（同步等在错误日志里有各自的记录）。
        controller.addJavaScriptHandler(
          handlerName: 'onLyricsBrowseDiag',
          callback: (List<dynamic> args) {
            ErrorLogService.instance.logDiagnostic(
              'ReaderFushi.lyrics.browse',
              lyricsBrowseDiagLine(
                args,
                regularSyncRunning: syncInProgress.value,
                srsSyncRunning: srsSyncProgress.value != null,
              ),
            );
          },
        );
        unawaited(_loadLyricsPage());
      },
      shouldInterceptRequest:
          (InAppWebViewController controller, WebResourceRequest request) =>
              _interceptRequest(request.url),
      onLoadResourceWithCustomScheme:
          (InAppWebViewController controller, WebResourceRequest request) =>
              _loadResourceWithCustomScheme(request),
      shouldOverrideUrlLoading:
          (InAppWebViewController controller, NavigationAction action) async {
            final String url = action.request.url?.toString() ?? '';
            return _isCurrentLyricsDocumentUrl(url)
                ? NavigationActionPolicy.ALLOW
                : NavigationActionPolicy.CANCEL;
          },
      onLoadStop: (InAppWebViewController controller, WebUri? url) async {
        await _finalizeLyricsDocumentIfReady(
          controller,
          generation: _lyricsLoadGeneration,
        );
      },
      onReceivedError:
          (
            InAppWebViewController controller,
            WebResourceRequest request,
            WebResourceError error,
          ) {
            if (!(request.isForMainFrame ?? false)) return;
            final int? failedLyricsGeneration =
                _lyricsDocumentGenerationFromUrl(request.url.toString());
            if (failedLyricsGeneration != null &&
                failedLyricsGeneration == _lyricsDocumentLoadGeneration &&
                failedLyricsGeneration == _lyricsLoadGeneration) {
              _lyricsDocumentLoadGeneration = null;
            }
          },
      onConsoleMessage:
          (InAppWebViewController controller, ConsoleMessage msg) =>
              debugPrint('[LyricsWebView] ${msg.message}'),
      // 非 null 本身就是救命动作（Android renderer 被回收时不传 = 连坐杀 app；
      // WKWebView 内容进程被 jetsam 不接 = 永久白屏）。处置见
      // [_lyricsWebViewDeathGuard]：歌词文档无状态，换代重建后由
      // onWebViewCreated 重新装载。
      onWebContentProcessDidTerminate: (InAppWebViewController _) =>
          unawaited(_lyricsWebViewDeathGuard.handleWebContentTerminated()),
      onRenderProcessGone:
          (InAppWebViewController _, RenderProcessGoneDetail detail) =>
              unawaited(
                _lyricsWebViewDeathGuard.handleDeath(
                  didCrash: detail.didCrash,
                  rendererPriorityAtExit: detail.rendererPriorityAtExit,
                ),
              ),
    );
    // 文档就绪前保持透明（WebView 首帧是白底，Windows fork 不完全尊重
    // transparentBackground），就绪后淡入。
    final Widget faded = AnimatedOpacity(
      opacity: _lyricsPageReady ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      // renderer 死亡后换代重建（[_lyricsWebViewDeathGuard.rebuildKey]），挂在
      // WebView 之上，不动 `fushi_lyrics_webview` 这个 finder 锚点。
      child: KeyedSubtree(
        key: _lyricsWebViewDeathGuard.rebuildKey,
        child: webView,
      ),
    );
    // 与正文同款：宿主腿悬停查词平台（macOS）紧包 MouseRegion。
    final Widget keyed = KeyedSubtree(
      key: _lyricsWebViewKey,
      child: hostOwnsWebViewHoverLookup
          ? MouseRegion(
              opaque: false,
              onHover: _handleWebViewHostHover,
              onExit: _handleWebViewHostHoverExit,
              child: faded,
            )
          : faded,
    );
    // Windows 文字选区右键（查词 / 复制 / 收藏 / 导出片段）：与正文同一个菜单，
    // 选区读 [_surfaceController]。
    if (!isWindowsPlatform) return keyed;
    return ContextMenuTrigger(
      onInvoke: (Offset position) => _showReaderTextContextMenu(position),
      ladder: kReaderMouseLadder,
      child: keyed,
    );
  }

  // ── Floating Lyric ─────────────────────────────────────────────────
  //
  // TODO-291 阶段2：悬浮窗 / 媒体通知的「拉起 + cue 同步 + 控制流订阅」已上移到进程级
  // [AudiobookSession]，让退出书籍后仍能后台听书 + 悬浮刷字。reader 这里只保留：
  // ① reader 主题样式 [_readerFloatingLyricStyle]（attach 期通过 session.installReaderSurfaces
  //    注入，使悬浮窗用 reader 当前书的深色/竖排主题）；
  // ② 桌面悬浮窗点词路由 [_lookupFromFloatingLyric]（attach 期注入，路由进 reader 弹窗）；
  // ③ 设置开关 [_toggleFloatingLyric] / [_toggleMediaNotification]（薄壳，委托 session）。

  /// reader 主题悬浮窗样式（attach 期注入 session）。M3E 配色取阅读器当前明暗下的
  /// app 主题（context-free：`appModel.theme` / `darkTheme`，不碰 State.context），
  /// 设置快照与 app 级构造点共用同一份（[buildFloatingLyricStyle]）。
  FloatingLyricStyle _readerFloatingLyricStyle({double? fontSize}) {
    return buildFloatingLyricStyle(
      theme: _isReaderThemeDark ? appModel.darkTheme : appModel.theme,
      settings: appModel.floatingLyricStyleSettings(fontSize: fontSize),
    );
  }

  /// 设置 / 通知 custom action 翻转悬浮窗。委托 [AppModel.toggleFloatingLyricFromControls]
  /// （session 拉起/隐藏 + 偏好读写），失败时按平台显示提示。
  Future<bool> _toggleFloatingLyric() async {
    final bool wasOn = appModel.showFloatingLyric;
    final bool ok = await appModel.toggleFloatingLyricFromControls();
    if (!ok) {
      // Android needs the OS "draw over other apps" permission, so its
      // failure is a permission prompt; ColorOS OEMs (OPPO / realme /
      // OnePlus) may refuse to grant it outright, so they get workaround
      // guidance instead (TODO-1227). The desktop strip is a runner-owned
      // window with no such permission, so a failure there means window
      // creation failed — show the generic hint instead of a false
      // permission message.
      final String? maker = Platform.isAndroid
          ? await appModel.platformServices.deviceInfo.manufacturer
          : null;
      if (mounted) {
        final String hint = floatingLyricFailureHint(
          isAndroid: Platform.isAndroid,
          manufacturer: maker,
        );
        ScaffoldMessenger.of(context).showSnackBar(
          FushiSnackBar(
            content: Text(hint),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return false;
    }
    if (mounted) _rebuild(() {});
    // 刚开启：让悬浮窗用 reader 主题样式（session 默认已是 app 级；attach 期 install 过
    // reader 样式，但若 toggle 在 attach 之前发生则补一次）。
    if (!wasOn) {
      await appModel.audiobookSession.applyFloatingLyricStyle();
    }
    return true;
  }

  /// Routes a tap on the desktop floating-lyric strip. TODO-872：Windows 上
  /// **优先**弹 867 app 外全局查词覆盖窗（[tryFloatingLyricGlobalLookup] →
  /// [GlobalLookupController.lookupText]，与全局热键同款 NOACTIVATE、跟光标的
  /// 卡片）——主窗被最小化/遮挡着听书时结果也看得见。覆盖窗不可用（控制器未
  /// start / 非 Windows 桌面）才回落下方原 **clipboard lookup pipeline**
  /// (TODO-376). The strip is a separate native always-on-top
  /// window with no DOM selection, so we segment the tapped word
  /// ([floatingLyricSearchTerm] via [Language.wordFromIndex], the same extractor
  /// the Android popup uses) and hand it to [DesktopLookupService.triggerLookup]
  /// — the exact same outlet the desktop clipboard-watch / global-hotkey lookup
  /// uses. Per the user's decision ("复用剪贴板查词那套逻辑"), the result is shown
  /// in the main window's dictionary tab instead of an in-app popup rendered at
  /// the reader's screen centre, and [bringPendingLookupToFront] surfaces the
  /// main window (it is a no-op when already focused — TODO-341).
  ///
  /// On Android the overlay launches `PopupDictFlutterActivity` itself, so this
  /// handler is only exercised by the desktop back-end; on non-desktop hosts it
  /// is a no-op. It also no-ops when no usable word can be segmented.
  ///
  /// 排队 → 唤前台 → 请求首页切到查词 tab。切 tab 让 [HomeDictionaryPage] 挂载，
  /// 它在 initState 无条件消费已存在的 [DesktopLookupService.pendingText] 并展示——
  /// pending 必须在请求切 tab **之前**就位（这里顺序即如此），否则页面挂载时读不到。
  Future<void> _lookupFromFloatingLyric(
    String text,
    int index,
    Rect? wordRect,
  ) async {
    if (!mounted) return;
    // TODO-872 — 覆盖窗接手即返回；false 时继续原「切主窗词典 tab」回落路由。
    if (await tryFloatingLyricGlobalLookup(
      appModel: appModel,
      text: text,
      index: index,
      wordRect: wordRect,
    )) {
      return;
    }
    if (!mounted) return;
    final String searchTerm = floatingLyricSearchTerm(
      text: text,
      index: index,
      word: JapaneseLanguage.instance.wordFromIndex(text: text, index: index),
    );
    if (searchTerm.isEmpty) return;
    if (!DesktopLookupService.isDesktop) return;
    DesktopLookupService.instance.triggerLookup(searchTerm);
    await DesktopLookupService.instance.bringPendingLookupToFront();
    if (!mounted) return;
    // 显式请求主窗切到查词 tab（与被动剪贴板正交）：HomeDictionaryPage 挂载后消费
    // pendingText 展示结果。不在阅读器内弹 in-app 中心浮层（用户决策）。
    appModel.requestHomeDictionaryTab();
  }

  /// 歌词模式的「上 N 句 / 下 N 句」制卡上下文（BUG-3434）。
  ///
  /// 歌词视图一行就是一条 cue，查词锚点是 [_lookupCue]（歌词查词时取自
  /// `__lyricsCueContext.cueIndex`，见 lookup.part.dart）。上下文直接取它在
  /// [_lyricsCueList] 里的相邻 cue——与视频字幕同一个切法 [cueContextNeighbors]，
  /// 不再去正文 WebView 按 DOM 选区切句（歌词模式下正文没有选区，恒为空）。
  /// 每句的音频区间取**该 cue 自己**的起止与音频文件（[cueContextDraftSentences]
  /// → [miningCueAudioRange]），不走 [_sentenceAudioRangeFor]：后者按查词句的章节号
  /// （[_lookupSectionIndex]）换算句子位置，相邻句跨章时会被换算进查词句所在章、
  /// 合并成整章区间；无位置的普通字幕还会按文本回落到更早的同文句。
  /// 锚点不在歌词列表里时清空上下文，不拿错位的句子凑数。
  int _setLyricsSentenceContextToDraft(int prevCount, int nextCount) {
    final AudioCue? anchor = _lookupCue;
    final int anchorIndex = anchor == null
        ? -1
        : _lyricsCueList.indexOf(anchor);
    final AudiobookPlayerController? audioController = _audiobookController;
    final EpubBook? book = _book;
    final ({List<MiningDraftSentence> prev, List<MiningDraftSentence> next})
    context = cueContextDraftSentences(
      cues: _lyricsCueList,
      anchorIndex: anchorIndex,
      prevCount: prevCount,
      nextCount: nextCount,
      audioFileCount: audioController?.audioFiles.length ?? 0,
      // 与当前句（_syncCueSentence）同源：歌词行展示的是正文文本。
      textOf: book == null ? null : _lyricsCueTextResolverFor(book).textForCue,
      delayMs: audioController?.delayMs.value ?? 0,
      headPadMs: appModel.miningAudioHeadPadMs,
      tailPadMs: appModel.miningAudioTailPadMs,
    );
    _miningDraft.setContext(prev: context.prev, next: context.next);
    return _miningDraft.length;
  }
}
