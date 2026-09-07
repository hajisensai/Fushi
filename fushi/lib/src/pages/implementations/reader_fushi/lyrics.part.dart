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
      final int safeChapterIndex =
          _clampIndex(chapterIndex, chapterCues.length);
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
      _rebuild(() => _lyricsMode = entering);
      await ReaderFushiSource.instance.setLyricsMode(entering);

      if (entering) {
        // 文档即将被 LyricsModeHtml 整页替换（其中无 window.fushiCaret）。若此刻
        // reader caret 正激活，surface 会滞留 reader，之后方向键会对歌词文档调
        // window.fushiCaret.move() 报错、caret 卡死——进入前先丢掉旧 caret。
        _exitCaret();
        await _resolveAndApplyProfile(
          appModelNoUpdate.database,
          mediaTypeOverride: ProfileMediaKind.lyrics,
        );
        final List<AudioCue> allCues =
            _audiobookController!.allBookCuesSnapshot;
        if (allCues.isNotEmpty) {
          _audiobookController!.setChapterCues(allCues);
        }
        _lyricsEntryChapter = _currentChapter;
        // BUG-872：用 allBookCueIdxAtPosition（位置优先）而非 allBookCueIdx，
        // 重开书暂停态下 _currentCue 尚未被播放 tick 填充，allBookCueIdx==-1 会
        // 把入场高亮 clamp 回第一句；按已恢复的播放器位置取正确 cue。
        _lyricsEntryCueIndex =
            _audiobookController!.allBookCuesSnapshot.isNotEmpty
                ? _audiobookController!.allBookCueIdxAtPosition
                : _audiobookController!.currentCueIdx;
        // 首次进入提示改挂「歌词文档就绪」事件（webview.part.dart 的
        // _onChapterLoadComplete 歌词分支消费此旗），替代旧的裸 delay 100ms——
        // 那只是猜 loadData 何时渲染完，慢机上会把对话框弹在空白页上。
        _pendingLyricsHintOnReady = true;
        await _loadLyricsPage();
      } else {
        _lyricsDocumentLoadGeneration = null;
        await _resolveAndApplyProfile(appModelNoUpdate.database);
        await _exitLyricsMode();
        try {
          await _restoreCompleter?.future.timeout(
            const Duration(seconds: 8),
            onTimeout: () => false,
          );
        } catch (e, stack) {
          ErrorLogService.instance.log('ReaderFushi.lyricsRestore', e, stack);
        }
      }
    } finally {
      if (mounted) _rebuild(() => _lyricsModeTransition = false);
    }
  }

  Future<void> _loadLyricsPage() async {
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
      chapterIndex:
          ctrl.currentCueIdx >= 0 ? ctrl.currentCueIdx : _lyricsEntryCueIndex,
    );
    _lyricsCueList = cueWindow.cues;
    _lyricsCueIndexOffset = cueWindow.indexOffset;
    _lyricsCueWindowUsesAllBookCues = cueWindow.usesAllBookCues;
    if (_lyricsCueList.isEmpty) {
      await _exitLyricsMode();
      return;
    }

    final Color bg = _themeBackgroundColor();
    final Color fg = _lyricsTextColor();
    final Color accent = _readerLyricAccentColor();

    String colorToCss(Color c) => readerColorToCssRgba(c);

    // 歌词视图跟正文用同一份自定义字体（FontTarget.body）：它显示的就是这本书的
    // 文本，切个视图不该换字体。readerSettings 为 null（极早期调用）时退回空串，
    // 歌词页保持历史 Noto 链。
    final ({String fontFamily, String fontFaces})? bodyFont =
        ReaderFushiSource.readerSettings?.buildCustomFontCss();

    final String html = LyricsModeHtml.generate(
      cues: _lyricsCueList,
      currentIndex: cueWindow.currentIndex,
      loadGeneration: loadGeneration,
      backgroundColor: colorToCss(bg),
      textColor: colorToCss(fg),
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
    );

    // BUG-1280：歌词是第三个把文档交给 WebView 的地方（另两个是
    // `_loadChapterDirectly` 和 `_loadSpreadPage`）。不在这里复位，从双页页面切进
    // 歌词模式时 `_spreadDocumentLoaded` 会残留为真，`_onChapterLoadComplete` 的
    // spread 守卫把歌词分支一起挡掉 → 歌词永远不就绪。标记的含义是「WebView 里
    // 现在是不是 spread 文档」，所以每个装载点都必须写它。
    if (!mounted ||
        !_lyricsMode ||
        loadGeneration != _lyricsLoadGeneration ||
        _controller == null) {
      return;
    }
    _spreadDocumentLoaded = false;
    _lyricsDocumentLoadGeneration = loadGeneration;
    try {
      await _controller!.loadData(
        data: html,
        mimeType: 'text/html',
        encoding: 'utf-8',
        baseUrl: WebUri(
          Uri.parse('https://fushi.local/lyrics').replace(
            queryParameters: <String, String>{
              'generation': '$loadGeneration',
            },
          ).toString(),
        ),
      );
    } catch (_) {
      if (_lyricsDocumentLoadGeneration == loadGeneration) {
        _lyricsDocumentLoadGeneration = null;
      }
      rethrow;
    }
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
    if (!mounted || _controller == null || !_lyricsPageReady) return;
    final Color bg = _themeBackgroundColor();
    final Color fg = _lyricsTextColor();
    final Color accent = _readerLyricAccentColor();
    final double fontSize = ReaderFushiSource.instance.lyricsFontSize;

    String colorToCss(Color c) => readerColorToCssRgba(c);

    final String bgCss = colorToCss(bg);
    final String fgCss = colorToCss(fg);
    final String accentCss = colorToCss(accent);

    final ReaderFushiSource src = ReaderFushiSource.instance;
    final double mt = src.lyricsMarginTop;
    final double mb = src.lyricsMarginBottom;
    final double ml = src.lyricsMarginLeft;
    final double mr = src.lyricsMarginRight;
    final bool blur = src.lyricsBlur;
    try {
      await _controller!.evaluateJavascript(
        source: 'window.__lyricsUpdateStyle && window.__lyricsUpdateStyle('
            "'$bgCss','$fgCss','$accentCss',$fontSize,$mt,$mb,$ml,$mr);",
      );
      // TODO-908: 模糊态是独立维度，单独热更（不重建整页），与样式同一路下发。
      await _controller!.evaluateJavascript(
        source: 'window.__lyricsSetBlur && window.__lyricsSetBlur($blur);',
      );
    } catch (e, stack) {
      // 与 _applyStylesLive/_reloadWithCurrentSettings 对称：半销毁 WebView 上
      // eval 抛 PlatformException，安全 no-op（lyrics 路径也不再裸露孤儿 await）。
      ErrorLogService.instance
          .log('ReaderFushi.updateLyricsStyleLive.eval', e, stack);
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

  Future<void> _exitLyricsMode() async {
    ++_lyricsLoadGeneration;
    _lyricsReadyFinalizingGeneration = null;
    _lyricsDocumentLoadGeneration = null;
    // 离开歌词模式会重载 reader 章节，lyrics caret JS 随之消失；复位 surface，
    // 否则方向键/A 会被误路由到已不存在的 fushiLyricsCaret。
    if (_caretSurface == CaretSurface.lyrics) {
      _rebuild(() => _caretSurface = CaretSurface.none);
    }
    final AudiobookPlayerController ctrl = _audiobookController!;
    final AudioCue? cue = ctrl.currentCue;
    int targetChapter =
        _lastProgressSection >= 0 ? _lastProgressSection : _lyricsEntryChapter;
    double targetProgress = _lastProgressValue;

    if (cue != null) {
      final SubtitleRematchFragment? frag =
          SubtitleRematchCodec.tryDecode(cue.textFragmentId);
      if (frag != null) {
        targetChapter = frag.sectionIndex;
        if (targetChapter >= 0 &&
            targetChapter < _chapterCharCounts.length &&
            _chapterCharCounts[targetChapter] > 0) {
          targetProgress =
              frag.normCharStart / _chapterCharCounts[targetChapter];
          targetProgress = targetProgress.clamp(0.0, 1.0);
        }
      }
    }

    _lyricsPageReady = false;
    _pendingLyricsHintOnReady = false;
    _lyricsCueIndexOffset = 0;
    _lyricsCueWindowUsesAllBookCues = false;
    _lyricsCueList = const [];
    await _navigateToChapter(targetChapter, progress: targetProgress);
  }

  // ── Floating Lyric ─────────────────────────────────────────────────
  //
  // TODO-291 阶段2：悬浮窗 / 媒体通知的「拉起 + cue 同步 + 控制流订阅」已上移到进程级
  // [AudiobookSession]，让退出书籍后仍能后台听书 + 悬浮刷字。reader 这里只保留：
  // ① reader 主题样式 [_readerFloatingLyricStyle]（attach 期通过 session.installReaderSurfaces
  //    注入，使悬浮窗用 reader 当前书的深色/竖排主题）；
  // ② 桌面悬浮窗点词路由 [_lookupFromFloatingLyric]（attach 期注入，路由进 reader 弹窗）；
  // ③ 设置开关 [_toggleFloatingLyric] / [_toggleMediaNotification]（薄壳，委托 session）。

  /// reader 主题悬浮窗样式（attach 期注入 session）。
  FloatingLyricStyle _readerFloatingLyricStyle({double? fontSize}) {
    final Color bg = _themeBackgroundColor();
    final Color fg = _themeTextColor();
    final bool dark = _isReaderThemeDark;
    final Color accent = _readerLyricAccentColor();
    final int textOpacity = appModel.floatingLyricTextOpacity;
    final int buttonBgOpacity = appModel.floatingLyricButtonBgOpacity;
    final int bgOpacity = appModel.floatingLyricBgOpacity;
    return FloatingLyricStyle(
      fontSize: fontSize ?? appModel.floatingLyricFontSize,
      // TODO-370: 文字 / 按钮底色透明度按设置缩放 alpha（默认 100=保持原观感）。
      textColor: FloatingLyricStyle.scaleAlpha(fg.value, textOpacity),
      // TODO-576: 条背景透明度按设置缩放 alpha（默认 70=更不挡视野）。
      bgColor: FloatingLyricStyle.scaleAlpha(
        bg.withAlpha(dark ? 230 : 220).value,
        bgOpacity,
      ),
      buttonTextColor: fg.value,
      buttonBgColor: FloatingLyricStyle.scaleAlpha(
        (dark ? const Color(0x33FFFFFF) : const Color(0x1A000000)).value,
        buttonBgOpacity,
      ),
      highlightColor: accent.withAlpha(128).value,
      activeColor: accent.value,
      // TODO-708 P2: 圆角半径 / 窗宽（dp，0=平台原生默认观感）。
      cornerRadius: appModel.floatingLyricCornerRadius,
      windowWidth: appModel.floatingLyricWidth,
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
          SnackBar(
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
  /// On Android the overlay launches its own `PopupDictActivity`, so this
  /// handler is only exercised by the desktop back-end; on non-desktop hosts it
  /// is a no-op. It also no-ops when no usable word can be segmented.
  ///
  /// 排队 → 唤前台 → 请求首页切到查词 tab。切 tab 让 [HomeDictionaryPage] 挂载，
  /// 它在 initState 无条件消费已存在的 [DesktopLookupService.pendingText] 并展示——
  /// pending 必须在请求切 tab **之前**就位（这里顺序即如此），否则页面挂载时读不到。
  Future<void> _lookupFromFloatingLyric(
      String text, int index, Rect? wordRect) async {
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
}
