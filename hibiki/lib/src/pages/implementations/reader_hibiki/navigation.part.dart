// GENERATED-NOTE: extracted from reader_hibiki_page.dart (TODO-589 batch4).
part of '../reader_hibiki_page.dart';

/// navigation (chapter navigation / internal links / spread paging / page-turn
/// limits) + position restore / progress refresh / scroll-callback domain
/// helpers extracted via part-of (TODO-589 batch4); shared private scope.
/// Behaviour-preserving: bodies are byte-for-byte verbatim except the five
/// `setState(` calls (in `_startContentReadyTimeout`, `_onRestoreComplete`,
/// `_beginNavigation`, `_runEdgeAnalysis`, `_refreshProgress`) forwarded
/// through the main shell `_rebuild(` helper (extensions cannot call the
/// @protected State.setState directly). No class static is referenced, so no
/// static qualification was needed.
///
/// No member of this group is an `@override` or calls a `@protected`
/// `BaseSourcePageState` member, so nothing had to stay behind in the shell on
/// those grounds. The `@override onAllPopupsDismissed` / `_runLookupAndHighlight`
/// (lookup, batch3) and the audiobook-cue wiring that physically interleaved
/// these blocks remain in the shell, reachable via the shared private class
/// scope.
extension _ReaderNavigation on _ReaderHibikiPageState {
  void _startContentReadyTimeout() {
    _contentReadyTimer?.cancel();
    _contentReadyTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || _readerContentReady) return;
      debugPrint(
          '[ReaderHibiki] content ready timeout — forcing overlay removal');
      _rebuild(() {
        _readerContentReady = true;
        _hasEverLoaded = true;
      });
      // TODO-700 T3：兜底超时路径也确定性落焦（门控见 helper）。
      _settleFocusOnContentReady();
      HibikiToast.show(msg: t.reader_content_timeout);
    });
  }

  void _onRestoreComplete() {
    _contentReadyTimer?.cancel();
    if (!mounted) {
      return;
    }
    if (_restoreExpectedGeneration != _navigateGeneration) {
      debugPrint(
        '[ReaderHibiki] stale onRestoreComplete: '
        'expected=$_restoreExpectedGeneration current=$_navigateGeneration',
      );
      return;
    }
    _restoreInFlight = false;
    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete(true);
    }
    _restoreCompleter = null;

    if (!_readerContentReady) {
      // BUG-111: 基线必须是「JS 实际分页用的宽高」(_paginatedWidth/Height)，
      // 不能用 content-ready 这一刻的当前 MediaQuery——否则下面 postFrame 的
      // _syncPageSize 比对的是同一个值，width/height 差永远为 0、初始重排校验恒
      // no-op。改用 _paginatedWidth 后：若界面缩放(scale!=1.0)未 settle 致初始
      // 分页偏窄，settle 后的真实视口宽与基线不等 → _syncPageSize 重新分页铺满。
      _lastSyncedWidth = _paginatedWidth;
      _lastSyncedHeight = _paginatedHeight;
      _rebuild(() {
        _readerContentReady = true;
        _hasEverLoaded = true;
      });
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      // TODO-700 T3：内容就绪确定性落焦到正文（门控见 helper）。
      _settleFocusOnContentReady();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncPageSize();
      });
    }

    // 收藏高亮：在恢复完成（章节分页布局已稳定、恢复滚动已结束）时重新应用。
    // _onChapterLoadComplete 里的早期 apply 跑在 onLoadStop 同步返回之后，
    // 而 hoshiReader.initialize 把 buildNodeOffsets / 恢复滚动塞进图片
    // Promise.all().then() 里异步执行——早期 apply 抢在列布局存在之前注册
    // CSS Custom Highlight range，重进章节时高亮不绘制（立即收藏时布局已稳定
    // 所以能显示）。在这里（与立即收藏相同的稳定状态）再应用一次即可对齐。
    // 重复应用是幂等的：__hibikiApplyHighlights 会先清空再重建 range map。
    if (!_lyricsMode) {
      _applyChapterHighlights();
    }

    _audiobookController?.notifySectionRestoreCompleted(
      currentReaderSection: _currentChapter,
      success: true,
    );

    _readingTimeTracker ??= ReadingTimeTracker(appModel.database);
    _readingTimeTracker!.start();
    _sessionStartTime = DateTime.now();
    _sessionMaxAbsoluteChars = _absoluteCharPosition(_initialProgress);

    // TODO-718: 连续模式恢复完成后，进入 WebView 的 settle reflow 会把裸 window.scrollY
    // 瞬时归 0（无分页 snap/lock 保护），归零 scroll 经 _handleReaderScroll 落库 progress≈0
    // → 退出再进恒章首。在此（_restoreInFlight 刚置 false、恢复滚动已落定、归零尚未发生）
    // 采锚 + 置旗：webview.part.dart 的 _reanchorPending 守卫随即挡住归零 scroll 不回传，
    // settle 后再把锚滚回。必须在下面 _refreshProgress() 之前——置旗后归零不会污染落库。
    // 门控/序列见 [_reanchorContinuousAfterRestore]；分页/歌词/控制器释放等由门控抑制。
    _reanchorContinuousAfterRestore();

    // TODO-724：跳章 / 位置恢复完成后重置有声书图片暂停的 cue 推进锚点
    // (__hoshiPrevHighlight)。否则恢复到章节中段后，首次 cue 推进时 prev 仍指向很早
    // 的元素，__hoshiImageBetween 会跨越中间所有插图、误把视口 reveal 到一张远处的图
    // （BUG-007 的 reveal 滚图被恢复 + 大跨度 cue 放大）。本路径同时覆盖初次开书与
    // 有声书跨章推进（_handleCueCrossChapter→_navigateToChapter 完成后均回到这里）。
    // 与 718 的 _reanchorContinuousAfterRestore（连续模式重锚）零共享状态，正交独立。
    if (!_lyricsMode && _controller != null) {
      AudiobookBridge.resetImagePauseAnchor(_controller!);
    }

    _refreshProgress();
    _startProgressPoll();
  }

  void _startProgressPoll() {
    _progressPollTimer?.cancel();
    _progressPollTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _refreshProgress(),
    );
  }

  /// BUG-213：setup 脚本的 scroll reporter 在章内原生滚动时（BUG-380 后改为 rAF 节流
  /// 边滑边回传 + 尾沿补一发）回传到此。门控通过则重算章内进度（high-water-mark 计字
  /// 不重复累计、`_debouncedSavePosition` 自带 500ms 去抖，不改字数累加路径）。恢复期/
  /// 歌词/未就绪由纯函数统一抑制。
  ///
  /// BUG-380：rAF 节流后回传可能高频到来，走 [_refreshProgressFromScroll] 的「在飞 +
  /// 待重跑」coalesce 守卫，避免较重的 hoshiProgressDetails 调用堆积。
  void _handleReaderScroll() {
    // TODO-736 B-3：样式重锚 commit 清旗后的 settle 尾沿去抖。改字号/字体/主题 reflow 在
    // commit（_reanchorClearedAt 打点）之后还会有几帧 settle，其间 WebView 自发的瞬态归零
    // scroll 经此回传——250ms 内的尾沿 scroll 直接 return 不落库（治翻页多次改字号跳章首的
    // 时序尾沿）。与 B-4（突降无输入）判据正交：B-3 管「时间窗内一律抑制」，B-4 管「突降到
    // 章首且无用户输入才抑制」，各自独立、禁互兜底。
    if (readerScrollWithinReanchorSettle(
      reanchorClearedAt: _reanchorClearedAt,
      now: DateTime.now(),
    )) {
      return;
    }
    final bool allowed = readerScrollProgressRefreshAllowed(
      readerContentReady: _readerContentReady,
      restoreInFlight: _restoreInFlight,
      lyricsMode: _lyricsMode,
      controllerAvailable: _controller != null,
    );
    // TODO-151/164 / BUG-225 诊断（默认 off，DebugLogService.instance.enabled 门控）：
    // 记四个门控条件各自真值 + 是否实际调 _refreshProgress，便于真机定位「滚动回传到了
    // 但进度不刷新」是被哪个门控挡掉的（恢复期/歌词/未就绪/控制器释放）。不改 151 逻辑。
    if (DebugLogService.instance.enabled) {
      debugPrint('[ReaderDiag] _handleReaderScroll'
          ' readerContentReady=$_readerContentReady'
          ' restoreInFlight=$_restoreInFlight'
          ' lyricsMode=$_lyricsMode'
          ' controllerAvailable=${_controller != null}'
          ' allowed=$allowed → refresh=${allowed ? 'yes' : 'no'}');
    }
    if (!allowed) {
      return;
    }
    _refreshProgressFromScroll();
  }

  /// BUG-380：滚动触发的进度刷新走「在飞 + 待重跑」coalesce 守卫。一次刷新在途时，
  /// 再来的滚动回传只置 [_scrollProgressPending]，待当前 [_refreshProgress] 完成后补跑
  /// 一次，确保最终静止位置一定被刷到，又不让 evaluateJavascript 堆积。轮询/恢复路径
  /// 仍直接调 [_refreshProgress]，不受此守卫影响。
  void _refreshProgressFromScroll() {
    if (_scrollProgressInFlight) {
      _scrollProgressPending = true;
      return;
    }
    // 卡死修复：时间节流（对齐 hoshi 安卓 CONTINUOUS_PROGRESS_THROTTLE_MS=50ms）。距上次刷新
    // 不足节流窗口时，只安排一个尾沿刷新合并高频滚动回传，不背靠背全文重算 calculateProgress
    // （遍历整章 15 万字 DOM）。尾沿保证停止后的最终位置一定被刷到。
    const int throttleMs = 50;
    final DateTime now = DateTime.now();
    final DateTime? last = _lastScrollProgressAt;
    if (last != null) {
      final int sinceMs = now.difference(last).inMilliseconds;
      if (sinceMs < throttleMs) {
        _scrollProgressThrottleTimer ??= Timer(
          Duration(milliseconds: throttleMs - sinceMs),
          () {
            _scrollProgressThrottleTimer = null;
            if (mounted) _refreshProgressFromScroll();
          },
        );
        return;
      }
    }
    _scrollProgressThrottleTimer?.cancel();
    _scrollProgressThrottleTimer = null;
    _lastScrollProgressAt = now;
    _scrollProgressInFlight = true;
    // TODO-798 续修边界：标记本次 _refreshProgress 是「用户原生滚动驱动」——是解武装因果门
    // 的唯一候选来源（轮询/恢复/chrome 路径不置此旗，故不会误把锚位轮询当用户滚动解武装）。
    _progressRefreshFromScroll = true;
    _refreshProgress().whenComplete(() {
      _progressRefreshFromScroll = false;
      _scrollProgressInFlight = false;
      if (_scrollProgressPending && mounted) {
        _scrollProgressPending = false;
        _refreshProgressFromScroll();
      }
    });
  }

  // ── Chapter Navigation ────────────────────────────────────────────

  /// 一次导航的共用主体：递增代际 token + 完成/新建 restore completer + 置初始锚点
  /// 字段 + 设 fragment + 标 restoreInFlight + setState 清 ready + 启动超时。
  /// _navigateToChapter / _navigateToSpread / _navigateToChapterWithFragment 此前各复制
  /// 这 14 行（任一改动要三处同步，否则导航/恢复代际状态机漂移）。各方法自己的前导
  /// （进度轮询取消 / manual 标记 / cancelChapterTransition / flush 统计）保留在各自方法。
  ///
  /// 注意：[_navigateToChapter] 额外把 charOffset 镜像进 `_lastProgressCharOffset`，
  /// 另两者不设 → 该字段不在此 helper 内（保各自原行为）。
  void _beginNavigation({
    required int chapter,
    required double progress,
    required int charOffset,
    String? fragment,
  }) {
    _restoreExpectedGeneration = ++_navigateGeneration;
    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete(false);
    }
    _restoreCompleter = Completer<bool>();
    _currentChapter = chapter;
    _initialProgress = progress;
    _initialCharOffset = charOffset;
    _lastProgressSection = chapter;
    _lastProgressValue = progress;
    // HBK-AUDIT-037: 清/设 fragment——上次内链导航的残留 fragment 不得漏进本次 setup
    // 脚本（旧的 post-await 复位在 lyrics/spread/early-return/throw 路径会被跳过）。
    _initialFragment = fragment;
    _restoreInFlight = true;
    // TODO-798 续修边界：每次导航开启一段新的自发 settle 期——武装非自愿 reflow 归零
    // 因果门。恢复落定后到用户首次真实滚动前的归零都属自发 reflow（命中复位）；用户首
    // 次真滚即解武装（_refreshProgressFromScroll 路径），此后归零必是用户拖到章首（放行）。
    _continuousSettleGuardArmed = true;
    _rebuild(() {
      _readerContentReady = false;
    });
    _startContentReadyTimeout();
  }

  /// 导航装载失败的共用收尾：清 restoreInFlight、完成并清空 restore completer。
  void _failNavigation() {
    _restoreInFlight = false;
    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete(false);
    }
    _restoreCompleter = null;
  }

  Future<void> _navigateToChapter(
    int index, {
    double progress = 0.0,
    int? charOffset,
    bool manual = false,
  }) async {
    if (_book == null || index < 0 || index >= _book!.chapters.length) {
      return;
    }
    if (_controller == null) {
      return;
    }

    if (manual) {
      _audiobookController?.noteManualReaderNavigation();
    }
    _progressPollTimer?.cancel();
    _flushReadingStats();

    // BUG-162: 普通翻章去新位置，无该章精确锚 → -1 走分数；同章程序化重分页可显式
    // 传 charOffset 保不动点。
    _beginNavigation(
      chapter: index,
      progress: progress,
      charOffset: charOffset ?? -1,
    );
    _lastProgressCharOffset = _initialCharOffset;

    try {
      await _loadChapterDirectly(index);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki._navigateToChapter', e, stack);
      debugPrint('[ReaderHibiki] _navigateToChapter loadUrl failed: $e');
      _failNavigation();
    }
  }

  Future<bool> _navigateToChapterAndWait(
    int index, {
    bool manual = false,
  }) async {
    await _navigateToChapter(index, manual: manual);
    final bool success = await _restoreCompleter?.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            debugPrint('[ReaderHibiki] _navigateToChapterAndWait timed out');
            _isNavigatingToChapter = false;
            _restoreCompleter = null;
            _restoreInFlight = false;
            return false;
          },
        ) ??
        false;
    return success && _currentChapter == index;
  }

  // BUG-117: shared internal-link handler. Called both from the JS click
  // interceptor (onInternalLink — the primary path, fires on every platform)
  // and from shouldOverrideUrlLoading (fallback for non-click navigations).
  // [url] is the browser-resolved absolute URL of the clicked <a> (or the
  // navigation target). Internal book links jump within the reader; genuine
  // external schemes go to the OS handler; an unresolved hoshi.local link stays
  // put (never pops a blank OS browser — see _openExternalUrl / BUG-097).
  Future<void> _handleInternalLinkUrl(String url) async {
    if (url.isEmpty) return;
    final ({int chapterIndex, String? fragment})? link =
        _book?.resolveInternalLink(url);
    if (link != null) {
      // HBK-AUDIT-038: a same-document anchor (e.g. href="#note1") resolves to
      // the current chapter's path plus a fragment. Jump in place instead of
      // reloading the whole chapter (avoids a visible flash + lost scroll).
      if (link.chapterIndex == _currentChapter && link.fragment != null) {
        await _jumpToFragmentInPlace(link.fragment!);
      } else {
        await _navigateToChapterWithFragment(
          link.chapterIndex,
          link.fragment,
          manual: true,
        );
      }
      return;
    }
    // HBK-AUDIT-038: route genuine external schemes (http/https/mailto/tel on a
    // foreign host) to the OS; _openExternalUrl no-ops for our own virtual host.
    await _openExternalUrl(url);
  }

  Future<void> _navigateToChapterWithFragment(int index, String? fragment,
      {bool manual = false}) async {
    if (_book == null || index < 0 || index >= _book!.chapters.length) return;
    if (_controller == null) return;

    _progressPollTimer?.cancel();
    if (manual) {
      _audiobookController?.noteManualReaderNavigation();
    } else {
      _audiobookController?.cancelChapterTransition();
    }
    _flushReadingStats();

    // BUG-162: 新章/fragment 跳转走分数/fragment，非 char 锚 → -1。
    _beginNavigation(
      chapter: index,
      progress: 0.0,
      charOffset: -1,
      fragment: fragment,
    );

    try {
      await _loadChapterDirectly(index);
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibiki._navigateToChapterWithFragment', e, stack);
      debugPrint(
          '[ReaderHibiki] _navigateToChapterWithFragment loadUrl failed: $e');
      _failNavigation();
    }
  }

  // HBK-AUDIT-038: scroll to an in-page anchor without reloading the chapter.
  // Used when an internal link resolves to the chapter already on screen.
  Future<void> _jumpToFragmentInPlace(String fragment) async {
    if (_controller == null || !_readerContentReady) return;
    // jsonEncode produces a valid, escaped JS string literal for the fragment.
    final String literal = jsonEncode(fragment);
    try {
      await _controller!.evaluateJavascript(
        source: 'window.hoshiReader && '
            'window.hoshiReader.jumpToFragment($literal);',
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibiki._jumpToFragmentInPlace', e, stack);
      debugPrint('[ReaderHibiki] _jumpToFragmentInPlace failed: $e');
    }
  }

  // HBK-AUDIT-038: open a genuinely external link (http/https/mailto/tel) in the
  // OS handler instead of silently cancelling it. Non-external schemes are
  // ignored so we never hand the OS an internal hoshi.local URL.
  Future<void> _openExternalUrl(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return;
    // BUG-097: an unresolved internal link (host == kHost) must stay in the
    // reader — never pop a blank OS browser for our virtual hoshi.local host.
    if (!ReaderHibikiSource.isExternalUrl(url)) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki._openExternalUrl', e, stack);
      debugPrint('[ReaderHibiki] _openExternalUrl failed for $url: $e');
    }
  }

  void _rebuildSpreadMap() {
    if (_book == null || _settings == null) return;
    _spreadMap = EpubSpreadMap.build(
      book: _book!,
      spreadMode: _settings!.spreadMode,
      spreadDirection: _settings!.spreadDirection,
      edgeMatchResults: _edgeMatchResults,
    );
  }

  Future<void> _initSpreadMap(HibikiDatabase db) async {
    if (_book == null || _settings == null) return;
    final String bookKey = widget.bookKey;
    if (_settings!.spreadMode == 'auto') {
      _edgeMatchResults = await EpubSpreadAnalyzer.loadCached(db, bookKey);
    }
    _rebuildSpreadMap();

    if (_settings!.spreadMode == 'auto' && _edgeMatchResults == null) {
      _runEdgeAnalysis(db, bookKey);
    }
  }

  Future<void> _runEdgeAnalysis(HibikiDatabase db, String bookKey) async {
    if (_book == null) return;
    try {
      final Map<int, bool> results = await EpubSpreadAnalyzer.analyze(_book!);
      await EpubSpreadAnalyzer.saveCache(db, bookKey, results);
      _edgeMatchResults = results;
      _rebuildSpreadMap();
      if (mounted) _rebuild(() {});
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki._runEdgeAnalysis', e, stack);
    }
  }

  Future<void> _navigateToVirtualPage(
    int virtualIndex, {
    double progress = 0.0,
  }) async {
    if (_spreadMap == null) return;
    if (virtualIndex < 0 || virtualIndex >= _spreadMap!.length) return;
    final SpreadEntry entry = _spreadMap!.entryAt(virtualIndex);
    if (entry.isSpread) {
      await _navigateToSpread(entry);
    } else {
      await _navigateToChapter(entry.chapterIndex, progress: progress);
    }
  }

  Future<void> _navigateToSpread(SpreadEntry entry) async {
    if (_book == null || _controller == null || !entry.isSpread) return;

    _progressPollTimer?.cancel();
    _flushReadingStats();

    // BUG-162: spread 导航去章首，无 char 锚 → -1；不要 fragment 跳转（fragment=null）。
    _beginNavigation(
      chapter: entry.chapterIndex,
      progress: 0.0,
      charOffset: -1,
    );

    try {
      await _loadSpreadPage(entry);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki._navigateToSpread', e, stack);
      debugPrint('[ReaderHibiki] _navigateToSpread failed: $e');
      _failNavigation();
    }
  }

  Future<void> _loadSpreadPage(SpreadEntry entry) async {
    if (_book == null || !entry.isSpread) return;

    final String? srcA = _book!.chapterImageSrc(entry.chapterIndex);
    final String? srcB = _book!.chapterImageSrc(entry.secondChapterIndex!);
    if (srcA == null || srcB == null) {
      await _loadChapterDirectly(entry.chapterIndex);
      return;
    }

    final String urlA = _resolveSpreadImageUrl(
      _book!.chapters[entry.chapterIndex].href,
      srcA,
    );
    final String urlB = _resolveSpreadImageUrl(
      _book!.chapters[entry.secondChapterIndex!].href,
      srcB,
    );

    final bool rtl = _settings?.spreadDirection != 'ltr';
    final String leftUrl = rtl ? urlB : urlA;
    final String rightUrl = rtl ? urlA : urlB;

    final String html = '''
<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no">
<style>
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:100vw;height:100vh;overflow:hidden;background:#000}
.spread{display:flex;width:100vw;height:100vh}
.spread-half{flex:1;display:flex;justify-content:center;align-items:center;overflow:hidden}
.spread-half img{max-width:100%;max-height:100vh;object-fit:contain;cursor:pointer}
</style>
</head><body>
<div class="spread">
<div class="spread-half"><img src="$leftUrl" class="block-img"/></div>
<div class="spread-half"><img src="$rightUrl" class="block-img"/></div>
</div>
<script>
document.querySelectorAll('img').forEach(function(img){
  img.addEventListener('click',function(){
    window.flutter_inappwebview.callHandler('onImageTap',img.src);
  });
});
window.flutter_inappwebview.callHandler('spreadReady');
</script>
</body></html>
''';

    _isNavigatingToChapter = true;
    try {
      await _controller!.loadData(
        data: html,
        mimeType: 'text/html',
        encoding: 'utf-8',
        baseUrl: WebUri(
          ReaderHibikiSource.epubUrl(_book!.chapters[entry.chapterIndex].href),
        ),
      );
    } catch (e) {
      _isNavigatingToChapter = false;
      rethrow;
    }
  }

  String _resolveSpreadImageUrl(String chapterHref, String imgSrc) {
    final String chapterDir = p.posix.dirname(chapterHref);
    final String resolved = p.posix.normalize(p.posix.join(chapterDir, imgSrc));
    return ReaderHibikiSource.epubUrl(resolved);
  }

  void _handlePageTurnLimit(String direction) {
    if (_book == null) {
      return;
    }
    // BUG-369/TODO-656 诊断：跨章真正落子前记录方向与当前章号，便于对照「跳早了」。
    debugPrint('[xchapter] handlePageTurnLimit dir=$direction '
        'chapter=$_currentChapter spread=${_spreadMap != null}');
    _audiobookController?.noteManualReaderNavigation();

    if (_spreadMap != null && _settings?.spreadMode != 'off') {
      final int currentVirtual =
          _spreadMap!.virtualPageForChapter(_currentChapter);
      if (direction == 'forward') {
        if (currentVirtual + 1 < _spreadMap!.length) {
          _navigateToVirtualPage(currentVirtual + 1);
        }
      } else {
        if (currentVirtual > 0) {
          _navigateToVirtualPage(currentVirtual - 1, progress: 0.99);
        }
      }
      return;
    }

    if (direction == 'forward') {
      if (_currentChapter < _book!.chapters.length - 1) {
        _navigateToChapter(_currentChapter + 1, manual: true);
      }
    } else {
      if (_currentChapter > 0) {
        _navigateToChapter(
          _currentChapter - 1,
          progress: 0.99,
          manual: true,
        );
      }
    }
  }

  // ── Progress Save/Restore ─────────────────────────────────────────

  Future<void> _refreshProgress() async {
    if (_controller == null || _lyricsMode) return;
    final dynamic result = await _controller!.evaluateJavascript(
      source: ReaderPaginationScripts.stableProgressInvocation(),
    );
    if (result == null || !mounted) return;
    final ReaderStableProgressDetails? snapshot =
        parseReaderStableProgressDetails(result);
    if (snapshot == null) {
      // TODO-796：封面/插图等纯图片页全章无文本 → JS 返空串 → snapshot==null。这是
      // 合法状态，不是「未 settle」，旧逻辑一律早退会让顶部百分比沿用上一章旧值。
      // 用该图片页的章首累计字数 / 全书总字数给进度 UI 兜底（封面≈全书 0%），让百分比
      // 立即落到正确值；不写 DB、不累计 session（那条路确实需要真实快照）。
      _applyImagePageProgressFallback();
      return;
    }

    final int total = snapshot.total;
    final int charOffset = snapshot.charOffset;
    final double progress = snapshot.progress;

    // TODO-798：连续模式非自愿 reflow 归零拦截（位置不连续判据，真因修复）。
    // 退出再进恢复落定后，WebView 自发 reflow 把裸 window.scrollY 瞬时归 0，归零 scroll
    // 经 onReaderScroll → 这里读到 progress≈0。既有 JS _reanchorPending 旗 / Dart B-3
    // 250ms 窗都是时间边界的，大章+图片首开 reflow 远超 250ms 时晚到的归零穿过两墙落库
    // 章首（795/797 没修到的真因）。改用「上一发实质性非零 → 这一发单步塌缩到章首」判
    // 非自愿（与输入时序无关，不误伤惯性甩动）：命中则根因式**复位到已提交字符锚**（把
    // 视口滚回，不止跳过落库）并 return——保留 _lastProgress* 不被归零覆盖，不污染落库/统计。
    final double priorProgress = _lastProgressValue;
    final int committedAnchor = _lastProgressCharOffset >= 0
        ? _lastProgressCharOffset
        : _initialCharOffset;
    final bool fromUserScroll = _progressRefreshFromScroll;
    if (readerContinuousProgressSnapIsInvoluntary(
      continuousMode: _settings?.isContinuousMode == true,
      priorProgress: priorProgress,
      newProgress: progress,
      hasCommittedAnchor: committedAnchor >= 0,
      settleGuardArmed: _continuousSettleGuardArmed,
    )) {
      if (DebugLogService.instance.enabled) {
        debugPrint('[ReaderDiag] _refreshProgress involuntary reflow-zero snap'
            ' prior=${priorProgress.toStringAsFixed(4)}'
            ' new=${progress.toStringAsFixed(4)}'
            ' armed=$_continuousSettleGuardArmed fromScroll=$fromUserScroll'
            ' → re-anchor to committed charOffset=$committedAnchor (no save)');
      }
      // 复位到已提交锚（webview.part.dart 的 _reanchorPending 守卫挡住复位滚动自身回传）。
      if (_controller != null) {
        _controller!.evaluateJavascript(
          source: ReaderPaginationScripts.scrollToCharOffsetInvocation(
            committedAnchor,
          ),
        );
      }
      return;
    }
    // TODO-798 续修边界：因果门解武装。本次是用户原生滚动驱动且**未**判非自愿（落得一个
    // 真实的非塌缩进度，含「用户拖滚动条途中」与「用户拖到章首那一发但 prior 已≈0」）→
    // 用户已真滚过，此后任何归零都该归用户（拖到章首），永久解武装本章载入的因果门。
    // 不在「判非自愿」分支解武装（那是 reflow 归零，复位后仍在 settle 期）；不在轮询/恢复
    // 路径解武装（fromUserScroll=false，否则恢复后首发轮询会误解武装致 reflow 归零裸奔）。
    if (fromUserScroll && _continuousSettleGuardArmed) {
      _continuousSettleGuardArmed = false;
      if (DebugLogService.instance.enabled) {
        debugPrint('[ReaderDiag] _refreshProgress first real user scroll'
            ' → disarm continuous settle guard (progress='
            '${progress.toStringAsFixed(4)})');
      }
    }

    _lastProgressSection = _currentChapter;
    _lastProgressValue = progress;
    _lastProgressCharOffset = charOffset;
    final int absoluteChars = _absoluteCharPosition(progress);
    // TODO-147 / BUG-211：按 high-water mark 增量计数，避免往返翻页重复累计。
    final ReadProgressResult delta = accumulateSessionChars(
      absoluteChars: absoluteChars,
      highWaterMark: _sessionMaxAbsoluteChars,
    );
    _sessionCharsRead += delta.charsAdded;
    _sessionMaxAbsoluteChars = delta.highWaterMark;
    // TODO-736（复核 b）：进度刷新无条件落库。曾经的 B-4 突降伪归零守卫已删——它想防的
    // reflow 自发归零已被两墙完整覆盖（begin 换 CSS 触发的归零落在 _reanchorPending 期，由
    // JS stableProgressInvocation 返 null 拦在落库前；commit 清旗后的 settle 尾沿由 B-3 的
    // 250ms 窗在 _handleReaderScroll 拦掉）。B-4「无近期输入=伪」反而误伤惯性甩动到真章首
    // （momentum 期无新输入 → sinceUserInputMs 超窗 → 误判伪 → 丢位置），故移除。500ms 去抖落库。
    _debouncedSavePosition(progress, charOffset);

    if (mounted) {
      final int newTotal = _chapterCumulativeChars.isNotEmpty
          ? _chapterCumulativeChars.last + _chapterCharCounts.last
          : total;
      if (_progressCurrentChars != absoluteChars ||
          _progressTotalChars != newTotal) {
        _rebuild(() {
          _progressCurrentChars = absoluteChars;
          _progressTotalChars = newTotal;
        });
      }
      // TODO-151/164 / BUG-225 诊断（默认 off，DebugLogService.instance.enabled 门控）：
      // 记重算后章内进度 UI 字段最终值，便于真机确认滚动后进度数确实推进/未推进。
      if (DebugLogService.instance.enabled) {
        debugPrint('[ReaderDiag] _refreshProgress'
            ' progressCurrentChars=$_progressCurrentChars'
            ' progressTotalChars=$_progressTotalChars'
            ' (progress=${progress.toStringAsFixed(4)} section=$_currentChapter)');
      }
    }
  }

  /// TODO-796：当前章是纯图片/封面页（全章无文本 → JS 无进度快照）时，把顶部进度 UI
  /// 拉到该章在全书中的章首位置（封面≈全书 0%），而不是沿用上一章旧百分比。只动进度
  /// 显示字段，不碰 DB 落库 / session 字数累计（图片页无章内文本进度可言）。
  void _applyImagePageProgressFallback() {
    if (!mounted || _book == null) return;
    if (!_book!.isImageOnlyChapter(_currentChapter)) return;
    final ({int currentChars, int totalChars})? anchor =
        imagePageProgressAnchor(
      chapterIndex: _currentChapter,
      cumulativeChars: _chapterCumulativeChars,
      charCounts: _chapterCharCounts,
    );
    if (anchor == null) return;
    if (_progressCurrentChars == anchor.currentChars &&
        _progressTotalChars == anchor.totalChars) {
      return;
    }
    _rebuild(() {
      _progressCurrentChars = anchor.currentChars;
      _progressTotalChars = anchor.totalChars;
    });
  }

  Future<void> _syncPositionFromWebViewProgress() async {
    if (_controller == null ||
        _lyricsMode ||
        !_readerContentReady ||
        _restoreInFlight) {
      return;
    }

    final dynamic result;
    try {
      result = await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.stableProgressInvocation(),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'ReaderHibiki.syncPositionFromWebViewProgress.eval',
        e,
        stack,
      );
      debugPrint('[ReaderHibiki] syncPositionFromWebViewProgress failed: $e');
      return;
    }
    if (!mounted) return;

    final ReaderStableProgressDetails? snapshot =
        parseReaderStableProgressDetails(result);
    if (snapshot == null) {
      return;
    }

    _lastProgressSection = _currentChapter;
    _lastProgressValue = snapshot.progress;
    _lastProgressCharOffset = snapshot.charOffset;
  }

  void _debouncedSavePosition(double progress, int charOffset) {
    _debouncedSaveReaderPosition(_currentChapter, progress, charOffset);
  }

  void _debouncedSaveReaderPosition(
      int section, double progress, int charOffset) {
    if (_restoreInFlight) {
      return;
    }
    if (section == _lastSavedSection &&
        (progress - _lastSavedProgress).abs() < 0.001) {
      return;
    }

    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      _persistPosition(section, progress, charOffset);
    });
  }

  Future<void> _persistPosition(
      int section, double progress, int charOffset) async {
    _lastSavedSection = section;
    _lastSavedProgress = progress;

    final int normOffset = (progress * 10000).round();
    debugPrint('[ReaderHibiki] save position: bookKey=${widget.bookKey} '
        'section=$section normOffset=$normOffset charOffset=$charOffset');
    final ReaderPositionRepository repo =
        ReaderPositionRepository(appModel.database);
    await repo.save(
      bookKey: widget.bookKey,
      sectionIndex: section,
      normCharOffset: normOffset,
      // BUG-162: >=0 写精确锚（char_offset 列）。<0（WebView 当帧算不出精确偏移）
      // 传 null → ReaderPositionRepository.save 在同 section 保留既有精确锚、仅跨
      // section 失效。BUG-285 回归：TODO-265 误改成直接传 -1，使 _refreshProgress /
      // _syncPositionFromWebViewProgress 在重排或竖排边缘拿到 -1 时把同 section 的
      // 精确锚覆盖成 -1 → 恢复/有声书跨章重锚退化成「章首分数」（章节粒度），不再
      // 逐句跟随。还原 null 守卫，把同/跨 section 的取舍交回 repo.save。
      charOffset: charOffset >= 0 ? charOffset : null,
    );
  }

  void _syncPositionFromCurrentCue() {
    final AudioCue? cue = _audiobookController?.currentCue;
    if (cue == null) return;
    final SasayakiFragment? frag =
        SasayakiMatchCodec.tryDecode(cue.textFragmentId);
    if (frag != null) {
      _lastProgressSection = frag.sectionIndex;
      if (frag.sectionIndex >= 0 &&
          frag.sectionIndex < _chapterCharCounts.length &&
          _chapterCharCounts[frag.sectionIndex] > 0) {
        _lastProgressValue =
            frag.normCharStart / _chapterCharCounts[frag.sectionIndex];
        _lastProgressValue = _lastProgressValue.clamp(0.0, 1.0);
        // BUG-162: cue 派生位置无 WebView 精确偏移 → -1（恢复走 cue 的 normChar 分数），
        // 并清陈旧锚，避免后续 flush 把别 section 的偏移误写进来。
        _lastProgressCharOffset = -1;
        _debouncedSaveReaderPosition(
            _lastProgressSection, _lastProgressValue, -1);
      }
      return;
    }
    if (_srtCueChapterMap != null && _srtChapterRanges != null) {
      final int? chapter = _srtCueChapterMap![cue.sentenceIndex];
      if (chapter != null &&
          chapter >= 0 &&
          chapter < _srtChapterRanges!.length) {
        _lastProgressSection = chapter;
        final (int first, int last) = _srtChapterRanges![chapter];
        final int span = last - first;
        _lastProgressValue = span > 0
            ? ((cue.sentenceIndex - first) / span).clamp(0.0, 1.0)
            : 0.0;
        _lastProgressCharOffset = -1;
        _debouncedSaveReaderPosition(
            _lastProgressSection, _lastProgressValue, -1);
      }
    }
  }

  // HBK-AUDIT-122: in lyrics mode the persisted position must be derived from
  // the current audio cue before flushing, otherwise a stale reader-scroll
  // position is saved. dispose did this but didChangeAppLifecycleState did not,
  // so backgrounding while in lyrics mode lost playback progress. Both paths
  // now share this helper.
  //
  // BUG-032: backgrounding must ALSO durably flush the audiobook playback
  // position. dispose() force-saves it via the controller, but on a hard
  // process kill dispose never runs; the periodic save is fire-and-forget (may
  // not commit before the OS reclaims the process) and stops once background
  // Dart timers suspend. In lyrics mode the audio position is the only visible
  // progress (entry cue = allBookCueIdx), so losing it reads as "归零". Await
  // the controller flush inside the still-alive onPause window so the position
  // at background time is written through — mirroring the reader-pos flush.
  Future<void> _syncAndFlushPosition() async {
    if (_lyricsMode) {
      _syncPositionFromCurrentCue();
    } else {
      await _syncPositionFromWebViewProgress();
    }
    await _flushPosition();
    await _audiobookController?.flushPosition();
  }

  /// 进程退出统一 flush（TODO-086/BUG-191）。**不**调用
  /// [_syncPositionFromWebViewProgress]——退出期 WebView2 正在拆除，对它
  /// `evaluateJavascript` 会挂死整个退出。改用 debounce 已算好缓存的
  /// `_lastProgress*` 字段直接落库（[_flushPosition]），并把阅读统计 + 有声书
  /// 播放位置写穿。await 完成后退出路径才会 exit(0)。
  Future<void> _flushAllForProcessExit() async {
    if (_lyricsMode) {
      // 歌词模式可见进度只有音频 cue 位置，先从当前 cue 派生位置再落库
      // （纯内存计算，不碰 WebView）。
      _syncPositionFromCurrentCue();
    }
    await _flushPosition();
    await _flushReadingStats();
    await _audiobookController?.flushPosition();
  }

  Future<void> _flushPosition() async {
    _saveDebounce?.cancel();
    if (!_hasEverLoaded || _lastProgressSection < 0) {
      return;
    }
    await _persistPosition(
        _lastProgressSection, _lastProgressValue, _lastProgressCharOffset);
  }

  int _absoluteCharPosition(double progress) {
    if (_chapterCumulativeChars.isEmpty ||
        _currentChapter >= _chapterCumulativeChars.length) {
      return 0;
    }
    return _chapterCumulativeChars[_currentChapter] +
        (progress * _chapterCharCounts[_currentChapter]).round();
  }

  Future<void> _jumpToGlobalCharOffset(int globalOffset) async {
    if (_chapterCumulativeChars.isEmpty || _controller == null) return;

    final ChapterProgressTarget target = resolveChapterProgressForGlobalOffset(
      _chapterCumulativeChars,
      _chapterCharCounts,
      globalOffset,
    );

    if (target.chapter != _currentChapter) {
      _navigateToChapter(
        target.chapter,
        progress: target.progress,
        manual: true,
      );
    } else {
      await _controller!.evaluateJavascript(
        source:
            'window.hoshiReader && window.hoshiReader.restoreProgress(${target.progress});',
      );
    }
  }

  /// 把本 session 累积的字数 + 阅读时长落库。返回的 Future 在 DB 写完成后才完成，
  /// 供进程退出路径 await（TODO-086/BUG-191）；其余生命周期调用点 fire-and-forget
  /// （不 await 返回的 Future，行为同旧版）。计数器在发起写之前清零，保证同一段
  /// 时长/字数不会被重复累加。
  Future<void> _flushReadingStats() async {
    if (_sessionCharsRead <= 0 || _book == null) return;
    final DateTime now = DateTime.now();
    final int elapsedMs = now.difference(_sessionStartTime).inMilliseconds;
    final String dateKey =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final int charsRead = _sessionCharsRead;
    final String title = _book!.title;
    _sessionCharsRead = 0;
    _sessionStartTime = DateTime.now();
    try {
      await appModel.database.addReadingStatistic(
        title: title,
        dateKey: dateKey,
        charsRead: charsRead,
        timeMs: elapsedMs,
      );
    } catch (e) {
      debugPrint('[ReaderHibiki] stats flush error: $e');
    }
  }
}
