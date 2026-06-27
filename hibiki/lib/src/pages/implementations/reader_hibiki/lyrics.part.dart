// GENERATED-NOTE: extracted from reader_hibiki_page.dart (TODO-589 batch1).
part of '../reader_hibiki_page.dart';

/// lyrics + floating-lyric domain methods extracted via part-of (TODO-589
/// batch1); shared private scope. Behaviour-preserving: bodies are verbatim
/// except `setState(` forwarded through the main shell `_rebuild(` helper
/// (extensions cannot call the @protected State.setState directly).
extension _ReaderLyrics on _ReaderHibikiPageState {
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
      await ReaderHibikiSource.instance.setLyricsMode(entering);

      if (entering) {
        // 文档即将被 LyricsModeHtml 整页替换（其中无 window.hoshiCaret）。若此刻
        // reader caret 正激活，surface 会滞留 reader，之后方向键会对歌词文档调
        // window.hoshiCaret.move() 报错、caret 卡死——进入前先丢掉旧 caret。
        _exitCaret();
        await _resolveAndApplyProfile(
          appModelNoUpdate.database,
          mediaTypeOverride: 'lyrics',
        );
        final List<AudioCue> allCues =
            _audiobookController!.allBookCuesSnapshot;
        if (allCues.isNotEmpty) {
          _audiobookController!.setChapterCues(allCues);
        }
        _lyricsEntryChapter = _currentChapter;
        _lyricsEntryCueIndex =
            _audiobookController!.allBookCuesSnapshot.isNotEmpty
                ? _audiobookController!.allBookCueIdx
                : _audiobookController!.currentCueIdx;
        await _loadLyricsPage();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        _showLyricsModeHintIfNeeded();
      } else {
        await _resolveAndApplyProfile(appModelNoUpdate.database);
        await _exitLyricsMode();
        try {
          await _restoreCompleter?.future.timeout(
            const Duration(seconds: 8),
            onTimeout: () => false,
          );
        } catch (e, stack) {
          ErrorLogService.instance.log('ReaderHibiki.lyricsRestore', e, stack);
        }
      }
    } finally {
      if (mounted) _rebuild(() => _lyricsModeTransition = false);
    }
  }

  Future<void> _loadLyricsPage() async {
    _lyricsPageReady = false;
    final AudiobookPlayerController ctrl = _audiobookController!;
    _lyricsCueList = ctrl.allBookCuesSnapshot.isNotEmpty
        ? ctrl.allBookCuesSnapshot
        : ctrl.chapterCuesSnapshot;
    if (_lyricsCueList.isEmpty) {
      await _exitLyricsMode();
      return;
    }

    final int currentIdx = ctrl.allBookCuesSnapshot.isNotEmpty
        ? ctrl.allBookCueIdx
        : ctrl.currentCueIdx;
    final int safeCurrentIdx =
        currentIdx >= 0 ? currentIdx : _lyricsEntryCueIndex;

    final Color bg = _themeBackgroundColor();
    final Color fg = _lyricsTextColor();
    final Color accent = _isReaderThemeDark
        ? HibikiColor.defaultHighlightYellow
        : Theme.of(context).colorScheme.primary;

    String colorToCss(Color c) => readerColorToCssRgba(c);

    final String html = LyricsModeHtml.generate(
      cues: _lyricsCueList,
      currentIndex: safeCurrentIdx.clamp(0, _lyricsCueList.length - 1),
      backgroundColor: colorToCss(bg),
      textColor: colorToCss(fg),
      accentColor: colorToCss(accent),
      fontSize: ReaderHibikiSource.instance.lyricsFontSize,
      marginTop: ReaderHibikiSource.instance.lyricsMarginTop,
      marginBottom: ReaderHibikiSource.instance.lyricsMarginBottom,
      marginLeft: ReaderHibikiSource.instance.lyricsMarginLeft,
      marginRight: ReaderHibikiSource.instance.lyricsMarginRight,
      vertical: ReaderHibikiSource.instance.lyricsVerticalWriting,
      blur: ReaderHibikiSource.instance.lyricsBlur,
    );

    await _controller!.loadData(
      data: html,
      mimeType: 'text/html',
      encoding: 'utf-8',
      baseUrl: WebUri('https://hoshi.local/lyrics'),
    );
  }

  /// TODO-368: 歌词字幕文字色——用户设过自定义色（[ReaderHibikiSource.lyricsTextColor]
  /// 非哨兵 0）则用它，否则回退主题文字色 [_themeTextColor]（向后兼容默认跟随主题）。
  Color _lyricsTextColor() {
    final int custom = ReaderHibikiSource.instance.lyricsTextColor;
    if (custom != 0) return Color(custom);
    return _themeTextColor();
  }

  Future<void> _updateLyricsStyleLive() async {
    if (!mounted || _controller == null || !_lyricsPageReady) return;
    final Color bg = _themeBackgroundColor();
    final Color fg = _lyricsTextColor();
    final Color accent = _isReaderThemeDark
        ? HibikiColor.defaultHighlightYellow
        : Theme.of(context).colorScheme.primary;
    final double fontSize = ReaderHibikiSource.instance.lyricsFontSize;

    String colorToCss(Color c) => readerColorToCssRgba(c);

    final String bgCss = colorToCss(bg);
    final String fgCss = colorToCss(fg);
    final String accentCss = colorToCss(accent);

    final ReaderHibikiSource src = ReaderHibikiSource.instance;
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
          .log('ReaderHibiki.updateLyricsStyleLive.eval', e, stack);
      return;
    }
    // cue 文本随字号/边距重排，激活中的焦点环坐标会过期——重测一次跟上新布局。
    if (_caretOnLyrics) await _caretRefresh();
    if (mounted) _rebuild(() {});
  }

  void _showLyricsModeHintIfNeeded() {
    final ReaderHibikiSource src = ReaderHibikiSource.instance;
    final bool shown = src.getPreference<bool>(
      key: 'lyrics_mode_hint_shown',
      defaultValue: false,
    );
    if (shown || !mounted) return;
    src.setPreference<bool>(key: 'lyrics_mode_hint_shown', value: true);
    showAppDialog<void>(
      context: context,
      builder: (BuildContext ctx) => ReaderLyricsModeHintDialog(
        onClose: () => Navigator.of(ctx).pop(),
      ),
    );
  }

  Future<void> _exitLyricsMode() async {
    // 离开歌词模式会重载 reader 章节，lyrics caret JS 随之消失；复位 surface，
    // 否则方向键/A 会被误路由到已不存在的 hoshiLyricsCaret。
    if (_caretSurface == CaretSurface.lyrics) {
      _rebuild(() => _caretSurface = CaretSurface.none);
    }
    final AudiobookPlayerController ctrl = _audiobookController!;
    final AudioCue? cue = ctrl.currentCue;
    int targetChapter =
        _lastProgressSection >= 0 ? _lastProgressSection : _lyricsEntryChapter;
    double targetProgress = _lastProgressValue;

    if (cue != null) {
      final SasayakiFragment? frag =
          SasayakiMatchCodec.tryDecode(cue.textFragmentId);
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
    final Color accent = dark
        ? HibikiColor.defaultHighlightYellow
        : Theme.of(context).colorScheme.primary;
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
    );
  }

  /// 设置 / 通知 custom action 翻转悬浮窗。委托 [AppModel.toggleFloatingLyricFromControls]
  /// （session 拉起/隐藏 + 偏好读写），失败时按平台显示提示。
  Future<bool> _toggleFloatingLyric() async {
    final bool wasOn = appModel.showFloatingLyric;
    final bool ok = await appModel.toggleFloatingLyricFromControls();
    if (!ok) {
      if (mounted) {
        // Android needs the OS "draw over other apps" permission, so its
        // failure is a permission prompt. The desktop strip is a runner-owned
        // window with no such permission, so a failure there means window
        // creation failed — show the generic hint instead of a false
        // permission message.
        final String hint = Platform.isAndroid
            ? t.floating_lyric_permission_hint
            : t.floating_lyric_unavailable_hint;
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

  /// Routes a tap on the desktop floating-lyric strip through the **clipboard
  /// lookup pipeline** (TODO-376). The strip is a separate native always-on-top
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
  Future<void> _lookupFromFloatingLyric(String text, int index) async {
    if (!mounted) return;
    final String searchTerm = floatingLyricSearchTerm(
      text: text,
      index: index,
      word: appModel.targetLanguage.wordFromIndex(text: text, index: index),
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
