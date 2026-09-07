// GENERATED-NOTE: extracted from reader_fushi_page.dart (TODO-589 batch4).
part of '../reader_fushi_page.dart';

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
extension _ReaderNavigation on _ReaderFushiPageState {
  /// BUG-438 / TODO-889：内容就绪兜底超时，改 wall-clock 绝对 deadline。
  ///
  /// 旧实现每次 cancel 旧 8s timer 再起新 8s（相对 deadline）：手柄连/断 inset 抖动
  /// 在 <8s 内反复 `_beginNavigation` → 反复重武装 → 兜底永远被推迟、永挂 loading
  /// （无限 loading）。改用 [contentReadyTimeoutDeadline] 计算绝对截止时刻——一次
  /// content-not-ready 周期里只在第一次（或上次 deadline 已过）武装时开 `now+8s` 窗口，
  /// 之后抖动重复武装保留旧 deadline 不外推，timer 按 `deadline-now` 续命到原截止点。
  /// content 真正就绪 / dispose 由 [_clearContentReadyTimeout] 清空 deadline，下次真实
  /// 导航重新拿到新窗口。
  void _startContentReadyTimeout() {
    final DateTime now = DateTime.now();
    final DateTime deadline = contentReadyTimeoutDeadline(
      now: now,
      existingDeadline: _contentReadyDeadline,
    );
    _contentReadyDeadline = deadline;
    final Duration remaining = deadline.difference(now);
    _contentReadyTimer?.cancel();
    _contentReadyTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        _contentReadyDeadline = null;
        if (!mounted || _readerContentReady) return;
        debugPrint(
          '[ReaderFushi] content ready timeout — forcing overlay removal',
        );
        _rebuild(() {
          _readerContentReady = true;
          _hasEverLoaded = true;
        });
        // BUG-868：兜底超时是「JS 侧 fushiReader 迟迟不回 onRestoreComplete」时的最终解锁，
        // 光翻 _readerContentReady 不够——_restoreInFlight / _isNavigatingToChapter /
        // _restoreCompleter 仍悬空，_paginationInFlight（chrome.part.dart）恒真：遮罩摘掉、
        // 书看似打开，但翻页永久被守卫吞掉、进度不再保存。这里连同解开导航态：三份中止
        // 变体已收敛进 _failNavigation（清 _isNavigatingToChapter + _restoreInFlight 并
        // complete(false)+清空 completer，让等待方立即返回而非各等各的 10s 超时）。
        _failNavigation();
        // TODO-1229 第三次复诉：兜底超时也算内容就绪，消费 pending 并 stamp 冷却窗，
        // 避免惯性跨章后旗子悬空到下一次真实导航才被清（那会造成一次假冷却）。
        _noteChapterTurnSettledIfPending();
        // BUG-467：兜底超时路径同样补下 chrome insets（_hasEverLoaded 刚翻 true）。
        _reapplyChromeInsetsAfterFirstLoad();
        // TODO-700 T3：兜底超时路径也确定性落焦（门控见 helper）。
        _focusOwnership.reclaim(FocusReclaimCause.contentReady);
        // BUG-1052：兜底超时也要起阅读计时。计时器原本只在 [_onRestoreComplete]
        // 里建/启，而这条路径正是「JS 迟迟不回 onRestoreComplete」——遮罩已摘、书能
        // 读，却一秒都不记时长（字数照常累计 ⇒ 速度又爆表）。
        _ensureStudyClock();
        FushiToast.show(
          msg: t.reader_content_timeout,
          severity: ToastSeverity.warning,
        );
      },
    );
  }

  /// BUG-438 / TODO-889：内容真正就绪（或不再需要兜底）时清掉超时 timer + 绝对 deadline，
  /// 让下一次真实导航重新拿到一个完整的 8s 兜底窗口（而不是续上一周期残留的旧 deadline）。
  void _clearContentReadyTimeout() {
    _contentReadyTimer?.cancel();
    _contentReadyTimer = null;
    _contentReadyDeadline = null;
  }

  void _acceptRestoreComplete({
    required int reportedGeneration,
    Object? perfSnapshot,
  }) {
    if (!mounted ||
        !isCurrentReaderRestoreCompletion(
          reportedGeneration: reportedGeneration,
          currentGeneration: _navigateGeneration,
          expectedGeneration: _restoreExpectedGeneration,
        )) {
      debugPrint(
        '[ReaderFushi] stale onRestoreComplete: '
        'reported=$reportedGeneration expected=$_restoreExpectedGeneration '
        'current=$_navigateGeneration',
      );
      return;
    }
    ReaderChapterPerfTrace.noteJs(perfSnapshot);
    _onRestoreComplete();
  }

  void _onRestoreComplete() {
    ReaderChapterPerfTrace.mark('jsInitRestore');
    // BUG-438 / TODO-889：恢复完成=内容真正就绪，清掉兜底 deadline，下次导航拿新窗口。
    _clearContentReadyTimeout();
    // TODO-1229 第三次复诉：惯性跨章落地的新章一就绪，就把跨章冷却窗 stamp 到当下，
    // 挡住随后的残余滚轮/惯性在新章边界二次跨章（滚轮离散事件在长加载期间不续窗的真因）。
    _noteChapterTurnSettledIfPending();
    if (!mounted) {
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
      _openTrace.mark('firstRestore');
      _openTrace.report();
      // BUG-467：_hasEverLoaded 刚翻 true，底栏预留 _bottomChromeReserve 此刻才非 0。
      // 初始 WebView HTML 是在 _hasEverLoaded 尚为 false 时求值的（漏底栏高），这里补下一次
      // chrome insets，让正文列底沿避开底栏（竖排尤为明显，见辅助方法长注释）。
      _reapplyChromeInsetsAfterFirstLoad();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      // TODO-700 T3：内容就绪确定性落焦到正文（门控见 helper）。
      _focusOwnership.reclaim(FocusReclaimCause.contentReady);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // 跨章计时的真正终点：用户感知的跨章 = 遮罩（!_readerContentReady 时盖住整页的
        // ColoredBox）从屏上消失、新章可见那一刻。上面的 _rebuild 只是把状态翻真，遮罩
        // 到这一帧才真正撤掉，所以 overlayGone 才是「跨章结束」，total 也算到这里。
        ReaderChapterPerfTrace.mark('overlayGone');
        ReaderChapterPerfTrace.end();
        if (mounted) _syncPageSize();
      });
    } else {
      // 已就绪（同章重恢复等）时没有遮罩要撤，恢复完成即终点。
      ReaderChapterPerfTrace.end();
    }

    _audiobookController?.notifySectionRestoreCompleted(
      currentReaderSection: _currentChapter,
      success: true,
    );

    // BUG-1052：这里**不再**重锚任何会话时钟。本方法（恢复完成）每次重排版/重恢复
    // 都会跑，旧代码在此重置 `_sessionStartTime`，把上一段还没落库的前台阅读时长整段
    // 抹掉。[_ensureStudyClock] 的 start() 对已在跑的时钟是 no-op，重排版
    // 不打断计时。
    _ensureStudyClock();
    // 字数账本（ReadUnitLedger）在恢复完成时**不碰**：不播种（旧标量水位要在这里
    // 播种，漏一处就是幻象字数，BUG-1107 / 2168），也不再判「原位恢复」——离开当前
    // 单元的结算已经在**离开那一刻**做掉（[_beginNavigation] 与同章跳转入口统一
    // `leave()`，BUG-2225 / 2189）；这里之后的首个 arrive 只是让落点页成为当前单元。
    // 旧判据 `restoreIsInPlace` 拿「恢复锚 vs 上次实时采样」比对：同章跳转
    // （进度条 / 收藏句 / 脚注内链 / VN）不经 `_beginNavigation`、恢复锚就是上次采样，
    // 恒判原位 → 跳走前那页被 rebase 掉不结算（BUG-2225）。重排 / 宽变 / 模式切换
    // 同页换坐标提前结算不改总额（并集去重，同页新边界只补多露出的部分）。

    // TODO-718: 连续模式恢复完成后，进入 WebView 的 settle reflow 会把裸 window.scrollY
    // 瞬时归 0（无分页 snap/lock 保护），归零 scroll 经 _handleReaderScroll 落库 progress≈0
    // → 退出再进恒章首。在此（_restoreInFlight 刚置 false、恢复滚动已落定、归零尚未发生）
    // 采锚 + 置旗：webview.part.dart 的 _reanchorPending 守卫随即挡住归零 scroll 不回传，
    // settle 后再把锚滚回。必须在下面 _refreshProgress() 之前——置旗后归零不会污染落库。
    // 门控/序列见 [_reanchorContinuousAfterRestore]；分页/歌词/控制器释放等由门控抑制。
    _reanchorContinuousAfterRestore();

    // TODO-1309：跨章「文本搜索跳转」的章内精确定位在恢复落定且 settle 之后应用（见
    // [_applyPendingPreciseLocate]）。连续模式经上面 reanchor 的 onAfterCommit 在 commit
    // 清旗 + 打 B-3 窗之后应用（settle 已定，尾沿 reflow 不能落库覆盖）；分页/VN 无
    // reanchor settle 钩子，章节在 restore 完成即已分页 snap，直接应用（无 reflow 归零）。
    // 分派互斥：onAfterCommit 只在连续模式跑，这里只在非连续模式跑，故 pending 恰被消费一次。
    if (_settings?.isContinuousMode != true) {
      unawaited(_applyPendingPreciseLocate());
    }

    // TODO-perf（跨章·遮罩）：下面全是「新章已经可以看了」之后的收尾——收藏高亮
    // （一次 DB 查询 + 两次 evaluateJavascript）、有声书图片锚点复位、进度刷新与
    // 轮询、诊断探针。它们既不决定落点也不决定可见性，但每一项都要 await 一次 DB
    // 或 JS 往返；留在这里就跟遮罩撤除挤在同一轮事件循环里，把那一帧的绘制往后推。
    // 挪到本帧渲染之后执行——遮罩按时撤、用户先看到新章，收尾照旧全部执行。
    // 语义变化仅「晚一帧」：高亮晚一帧绘出、图片暂停锚点晚一帧复位（跨章落地那一帧
    // 恰好有 cue 推进才有影响，且下一次推进即自愈）、进度晚一帧刷新，均无用户可感后果。
    //
    // 代际守卫：收尾从「与 _onRestoreComplete 同步」改成「晚一帧」后，这一帧里可能已经
    // 起了新导航（_beginNavigation 会递增 _navigateGeneration）。此时旧章的收藏高亮 /
    // 图片锚点复位 / 进度刷新会落到新章状态上（尤其 _refreshProgress 会把旧章位置写库）。
    // 与本文件既有约定一致（_onRestoreComplete 头部、_applyPendingPreciseLocate），入口快照代际、
    // 回调里比对；被顶掉就整体丢弃——收尾本就属于「已被取代的那次导航」。
    final int settleGeneration = _navigateGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_navigateGeneration != settleGeneration) {
        debugPrint(
          '[ReaderFushi] stale restore settle: '
          'expected=$settleGeneration current=$_navigateGeneration',
        );
        return;
      }
      // 收藏高亮：恢复完成（分页布局稳定、恢复滚动结束）后重新应用。
      // _onChapterLoadComplete 里的早期 apply 跑在 onLoadStop 同步返回之后，
      // 而 fushiReader.initialize 把 buildNodeOffsets / 恢复滚动塞进图片
      // Promise.all().then() 里异步执行——早期 apply 抢在列布局存在之前注册
      // CSS Custom Highlight range，重进章节时高亮不绘制（立即收藏时布局已稳定
      // 所以能显示）。在这里（与立即收藏相同的稳定状态）再应用一次即可对齐。
      // 重复应用是幂等的：__fushiApplyHighlights 会先清空再重建 range map。
      if (!_lyricsMode) {
        _applyChapterHighlights();
      }
      // TODO-724：跳章 / 位置恢复完成后重置有声书图片暂停的 cue 推进锚点
      // (__fushiPrevHighlight)。否则恢复到章节中段后，首次 cue 推进时 prev 仍指向很早
      // 的元素，__fushiImageBetween 会跨越中间所有插图、误把视口 reveal 到一张远处的图
      // （BUG-007 的 reveal 滚图被恢复 + 大跨度 cue 放大）。本路径同时覆盖初次开书与
      // 有声书跨章推进（_handleCueCrossChapter→_navigateToChapter 完成后均回到这里）。
      // 与 718 的 _reanchorContinuousAfterRestore（连续模式重锚）零共享状态，正交独立。
      if (!_lyricsMode && _controller != null) {
        AudiobookBridge.resetImagePauseAnchor(_controller!);
      }
      _refreshProgress();
      _startProgressPoll();
      _diag718ProbeViewportDrift();
      // TODO-perf（跨章·图片）：预热**阅读方向上**下一章的插图进 WebView 缓存。必须放在
      // 这里（遮罩已撤、新章已可见）而不是 _onChapterLoadComplete —— 它要 parse 整章 HTML
      // 找图片引用，放在恢复完成之前就等于把成本加回跨章热路径。HTML 预取省的是磁盘读+
      // 净化，这里省的是读盘+解码，后者在带插图的章里大一个数量级（见
      // _prefetchAdjacentChapterImages 的实测注释与配额）。方向来自 _beginNavigation 的
      // 采样：倒着读时预热上一章，而不是刚离开的那一章。
      _prefetchAdjacentChapterImages(
        _currentChapter + _chapterAdvanceDirection,
      );
    });
  }

  /// TODO-718 诊断（默认 off·DebugLogService 门控·只读不改行为）：恢复完成后多次读**真实**
  /// WebView progress（区别于 onLoadStop 打印的恢复目标 _initialProgress），定位连续模式
  /// 视口从恢复位「漂回章首」发生在哪一刻——是恢复滚动根本没生效（从头到尾≈0），还是恢复
  /// 成功后被晚到 reflow（cue 注入 / settle）静默冲回 0。每发打印 target/actual 对照。
  void _diag718ProbeViewportDrift() {
    if (!DebugLogService.instance.enabled) return;
    final double target = _initialProgress;
    Future<void> probe(String tag) async {
      if (!mounted || _controller == null) return;
      final dynamic result = await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.stableProgressInvocation(),
      );
      final ReaderStableProgressDetails? snap =
          parseReaderStableProgressDetails(result);
      debugPrint(
        '[ReaderDiag] 718-drift $tag target=${target.toStringAsFixed(4)}'
        ' actual=${snap == null ? "null" : snap.progress.toStringAsFixed(4)}'
        ' lastVal=${_lastProgressValue.toStringAsFixed(4)}'
        ' lastChar=$_lastProgressCharOffset restoreInFlight=$_restoreInFlight',
      );
    }

    probe('t+0');
    Future<void>.delayed(
      const Duration(milliseconds: 400),
      () => probe('t+400'),
    );
    Future<void>.delayed(
      const Duration(milliseconds: 1000),
      () => probe('t+1000'),
    );
    Future<void>.delayed(
      const Duration(milliseconds: 1800),
      () => probe('t+1800'),
    );
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
  /// 待重跑」coalesce 守卫，避免较重的 fushiProgressDetails 调用堆积。
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
      // BUG-2227：窗内丢掉的可能不只是瞬态归零，也可能是用户紧接着的真实滚动 /
      // 翻页落点。丢弃本身不变（治 reflow 归零落库），但按同一个窗常量排一次窗关后的
      // 补刷，让落点页及时成为账本当前单元——否则只能等 10s 轮询，期间关书 / 跳转
      // 结算的是上一次采样的旧页，最后一屏漏计。与听书 reveal 共用同一个单 Timer。
      _scheduleReanchorSettleProgressRefresh();
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
      debugPrint(
        '[ReaderDiag] _handleReaderScroll'
        ' readerContentReady=$_readerContentReady'
        ' restoreInFlight=$_restoreInFlight'
        ' lyricsMode=$_lyricsMode'
        ' controllerAvailable=${_controller != null}'
        ' allowed=$allowed → refresh=${allowed ? 'yes' : 'no'}',
      );
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
    // v92 阅读空闲门：滚动 / 翻页回传 = 用户输入（听书自动翻页也经此），喂时钟。
    // 10s 进度轮询走 [_refreshProgress] 不经这里，不会把挂机伪装成输入。
    _studyClock?.touch();
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
    // TODO-937：连续模式手动滚动后，在进度刷新落地的同一 50ms 节流相位补一次
    // _caretRefresh()，让字符级焦点环重锚到首个可见字符（详见
    // readerScrollCaretFollowAllowed 门控真值表 + _caretRefresh 文档）。
    if (readerScrollCaretFollowAllowed(
      continuousMode: _settings?.isContinuousMode == true,
      caretActive: _caretActive,
      caretOnReader: _caretOnReader,
    )) {
      _caretRefresh();
    }
    _refreshProgress().whenComplete(() {
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
    int charOffsetEnd = -1,
    String? fragment,
    String? preciseLocateJs,
  }) {
    _restoreExpectedGeneration = ++_navigateGeneration;
    // BUG-2225 / BUG-2226：所有导航都经过这里，所以这也是「离开当前单元」的唯一
    // 采样点——翻走即计：此刻把用户正读的那页结算进账本，跳过的区间从未成为当前
    // 单元、不计。放在 loadUrl 之前：装载失败 / 兜底超时走 [_failNavigation] 的
    // `discard()` 时当前单元已是空的，不会再把真读过的上一页整页丢掉（BUG-2226）。
    // 同章重恢复（宽变 / 分页↔连续 / 竖横排）也会提前结算同一页——并集去重，之后
    // 同页新边界只补多露出的部分，总额不变。
    _readLedger.leave();
    // BUG-1231 / TODO-1309：新导航先作废上一代的章内精确定位，再把本次定位绑定到
    // 已递增的导航代际。绑定必须与导航状态初始化同处、且发生在 loadUrl 之前：
    // InAppWebViewController.loadUrl 的 Future 在部分平台会等到页面生命周期已推进后才返回，
    // 若调用方 await loadUrl 后才写 pending，onRestoreComplete 可能已经消费过空值，最终只
    // 落到目标章章首且没有搜索高亮。用户在恢复途中翻页/再跳时，新一次 _beginNavigation
    // 仍会从源头顶掉旧 pending；代际守卫继续兜底。
    _preciseLocateQueue.clear();
    if (preciseLocateJs != null) {
      _preciseLocateQueue.replace(
        generation: _navigateGeneration,
        js: preciseLocateJs,
      );
    }
    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete(false);
    }
    _restoreCompleter = Completer<bool>();
    // TODO-perf（跨章·图片）：所有导航都经过这里，故这是「阅读方向」的唯一采样点。
    // 同章重恢复（换字号/重排版/保不动点）不改方向——方向属于「读到哪儿去了」，
    // 不属于重排版。方向只喂给插图预热（见 _prefetchAdjacentChapterImages）。
    if (chapter != _currentChapter) {
      _chapterAdvanceDirection = chapter > _currentChapter ? 1 : -1;
    }
    _currentChapter = chapter;
    _initialProgress = progress;
    _initialCharOffset = charOffset;
    // TODO-1308 问题②：句尾锚归本方法拥有并每次导航复位——否则冷启动收藏跳转设过的
    // _initialCharOffsetEnd 会泄漏进后续任意带 charOffset 的导航（如换样式重分页的
    // 保不动点），把无关恢复当成收藏整句对齐多滚一段。只有显式带句尾锚的调用
    // （书内收藏面板跳转）才传非 -1。
    _initialCharOffsetEnd = charOffsetEnd;
    _lastProgressSection = chapter;
    _lastProgressValue = progress;
    // HBK-AUDIT-037: 清/设 fragment——上次内链导航的残留 fragment 不得漏进本次 setup
    // 脚本（旧的 post-await 复位在 lyrics/spread/early-return/throw 路径会被跳过）。
    _initialFragment = fragment;
    _restoreInFlight = true;
    // TODO-718 重设计：删除 _continuousSettleGuardArmed 武装——非自愿 reflow 归零判据已改无状态
    // （直接看 fromUserScroll），不再需要「导航武装/用户滚动解武装」状态机。
    _rebuild(() {
      _readerContentReady = false;
    });
    _startContentReadyTimeout();
  }

  /// 导航中止的统一收尾（三份变体收敛单点）：清导航在飞旗 `_isNavigatingToChapter`、
  /// 清恢复在飞旗 `_restoreInFlight`、complete(false) 并清空 restore completer，让等待方
  /// 立即返回。装载失败 catch（三入口）、[_navigateToChapterAndWait] 等待超时、
  /// content-ready 兜底超时（BUG-868）共用此一份——行为对齐到最完整变体（旧超时分支
  /// 弃置 completer 不 complete、旧装载失败分支不清导航旗，各自分叉）。对已复位的字段
  /// 幂等（装载失败路径 `_isNavigatingToChapter` 已在 rethrow 前清过，再清无副作用）。
  void _failNavigation() {
    ReaderChapterPerfTrace.abort();
    // 导航中止 / 内容就绪兜底超时：WebView 里现在是什么不可知，当前单元丢弃不结算
    // （宁可不计）。跳走前那页已在 [_beginNavigation] `leave()` 结算（BUG-2226：此前
    // 这里 discard 掉的正是用户真读过的上一页），dispose 也在调本方法之前 `leave()`；
    // 所以这里通常是 no-op，只兜「导航发起后新页曾短暂 arrive」的情形。
    _readLedger.discard();
    _isNavigatingToChapter = false;
    _restoreInFlight = false;
    _preciseLocateQueue.clear();
    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete(false);
    }
    _restoreCompleter = null;
  }

  /// TODO-1128：把一个导航目标章号解析成真正拥有虚拟页的章号。开启「图片合并」
  /// (`mergeImagePages`) 后，被吸收进后续文本章的单图片章（[EpubSpreadMap.isAbsorbedImageChapter]）
  /// 没有自己的页——它的 `<img>` 直接内联注入到宿主文本章正文顶部（见
  /// `webview.part.dart _injectMergedChapterImages`）。若裸导航直接落到被吸收章，会
  /// 加载它自己的独立单图页（第 1 份）+ 宿主正文顶部又注入同图（第 2 份）=**图片重复**。
  /// 本 helper 把这类目标重定向到其宿主文本章（该章虚拟页拥有那张内联图）；其余章号原样
  /// 返回（幂等——宿主本身绝不会被吸收）。spread map 未就绪或合并关闭时 no-op。
  int _resolveNavChapter(int index) {
    final EpubSpreadMap? map = _spreadMap;
    if (map == null) return index;
    if (!map.isAbsorbedImageChapter(index)) return index;
    final int virtual = map.virtualPageForChapter(index);
    return map.entryAt(virtual).chapterIndex;
  }

  Future<void> _navigateToChapter(
    int index, {
    double progress = 0.0,
    int? charOffset,
    int charOffsetEnd = -1,
    bool manual = false,
    String? preciseLocateJs,
  }) async {
    if (!mounted ||
        _book == null ||
        index < 0 ||
        index >= _book!.chapters.length) {
      return;
    }
    if (_controller == null) {
      return;
    }
    // TODO-1128：目标是被吸收的单图片章时，重定向到其宿主文本章的章首——被吸收图片只在
    // 宿主正文顶部内联注入那一份，绝不再加载独立单图页（消除重复）。charOffset 归零锚
    // （宿主顶部即那张图），progress 强制 0.0（内联图在最开头）。宿主本身不会被吸收，故幂等。
    final int resolvedChapter = _resolveNavChapter(index);
    if (resolvedChapter != index) {
      index = resolvedChapter;
      progress = 0.0;
      charOffset = null;
      charOffsetEnd = -1;
    }
    // TODO-807（纵深防御）：被动（有声书跟随）导航绝不落到 EPUB 目录/nav 页——
    // 否则跨章会把用户甩到目录。manual=true 是用户显式跳章（TOC 点击 / 翻章
    // 按钮），保留其自由不拦。被动命中 nav 页直接保位（不加载、不归零）。
    if (!manual && _book!.isChapterNav(index)) {
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
      charOffsetEnd: charOffsetEnd,
      preciseLocateJs: preciseLocateJs,
    );
    _lastProgressCharOffset = _initialCharOffset;

    ReaderChapterPerfTrace.begin('chapter=$index');
    try {
      await _loadChapterDirectly(index);
      ReaderChapterPerfTrace.mark('loadUrl');
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderFushi._navigateToChapter', e, stack);
      debugPrint('[ReaderFushi] _navigateToChapter loadUrl failed: $e');
      _failNavigation();
    }
  }

  Future<bool> _navigateToChapterAndWait(
    int index, {
    bool manual = false,
    double progress = 0.0,
    int? charOffset,
    int charOffsetEnd = -1,
    String? preciseLocateJs,
  }) async {
    // TODO-1128：被吸收图片章会被 _navigateToChapter 重定向到宿主文本章，落地后
    // _currentChapter == 宿主 ≠ 传入的 index。成功判定必须对齐**重定向后的目标**，
    // 否则有声书跨章遇被吸收图片章会误判 loaded=false → 跳过 imagePauseSec 停留
    // （图片等待对合并书彻底失效）。非吸收章 resolved==index，行为不变。
    final int resolvedChapter = _resolveNavChapter(index);
    // TODO-1309：跨章精确跳转收敛为一次原子恢复链。[progress] 把目标章内分数烘进导航
    // （书签/收藏/字符跳转）——单次 restore 直接落点、连续重锚采样保住，不再「先落章首
    // 再抢发 restoreProgress」被 settle-reflow 冲回章首（双跳）。[preciseLocateJs]（文本
    // 搜索跳转，分数无法表达）排进 _pendingPreciseLocate，由 _onRestoreComplete 在恢复
    // 落定且 settle 之后应用（见 _applyPendingPreciseLocate）。
    // TODO-1308 问题②：[charOffset]（章内绝对可匹配字符索引，getNormalizedOffset 口径）
    // 把收藏句的精确字符锚烘进同一条原子恢复链（_beginNavigation → shell
    // restoreToCharOffset），与冷启动 charAnchor 跳转（BUG-459）同构；[charOffsetEnd]
    // 句尾锚透传做整句对齐（BUG-461）。分数与字符锚二选一：charOffset 非空时优先。
    await _navigateToChapter(
      index,
      progress: progress,
      charOffset: charOffset,
      charOffsetEnd: charOffsetEnd,
      manual: manual,
      preciseLocateJs: preciseLocateJs,
    );
    final bool success =
        await _restoreCompleter?.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            debugPrint('[ReaderFushi] _navigateToChapterAndWait timed out');
            // 与装载失败 / content-ready 兜底超时共用同一份导航中止收尾。旧写法只弃置
            // completer 不 complete（行为分叉）；_failNavigation 额外 complete(false)——
            // 本 future 已超时返回，completer 再 complete 无副作用，且让其它等待方也
            // 立即放行，不再各等各的超时。
            _failNavigation();
            return false;
          },
        ) ??
        false;
    return success && _currentChapter == resolvedChapter;
  }

  /// TODO-1309：消费并应用排队的「章内精确定位」（当前仅跨章文本搜索跳转的
  /// `scrollToSearchMatch`——分数无法表达文本命中，无法烘进 shell 恢复脚本，故走本队列）。
  ///
  /// 必须在恢复落定且 settle 之后调用（连续模式 = `_reanchorContinuousAfterRestore` 的
  /// `onAfterCommit`：commit 已清 `_reanchorPending` 并打 B-3 settle 窗，落点不会被尾沿
  /// reflow 归零冲回章首；分页/VN = restore 完成即已分页 snap，无 reflow 归零，直接应用）。
  /// 这一步等价于「同章已 settle 时直接 restore」那条本就正常的路径，只是把跨章场景推迟到
  /// 同样 settle 的时刻，从根上消除双跳（首跳只到章节）。
  ///
  /// 代际守卫：`pending.generation != _navigateGeneration` = 被更晚的导航顶掉 → 丢弃，
  /// 绝不把搜索命中定位应用到错误章节。消费一次即清空（无论应用与否）。
  Future<void> _applyPendingPreciseLocate() async {
    final String? js = _preciseLocateQueue.consume(
      generation: _navigateGeneration,
      canApply: mounted && _controller != null,
    );
    if (js == null) return;
    try {
      await _controller!.evaluateJavascript(source: js);
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'ReaderFushi._applyPendingPreciseLocate',
        e,
        stack,
      );
      debugPrint('[ReaderFushi] _applyPendingPreciseLocate failed: $e');
    }
  }

  // BUG-117: shared internal-link handler. Called both from the JS click
  // interceptor (onInternalLink — the primary path, fires on every platform)
  // and from shouldOverrideUrlLoading (fallback for non-click navigations).
  // [url] is the browser-resolved absolute URL of the clicked <a> (or the
  // navigation target). Internal book links jump within the reader; genuine
  // external schemes go to the OS handler; an unresolved fushi.local link stays
  // put (never pops a blank OS browser — see _openExternalUrl / BUG-097).
  Future<void> _handleInternalLinkUrl(String url) async {
    if (url.isEmpty) return;
    final ({int chapterIndex, String? fragment})? link = _book
        ?.resolveInternalLink(url);
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

  Future<void> _navigateToChapterWithFragment(
    int index,
    String? fragment, {
    bool manual = false,
  }) async {
    if (_book == null || index < 0 || index >= _book!.chapters.length) return;
    if (_controller == null) return;

    // TODO-1128：EPUB 内链目标是被吸收单图片章时重定向到宿主文本章章首（消除重复）。
    // 被吸收章的正文已被再注入到宿主顶部（只有 <img>，原文档 id 不保留），fragment 锚
    // 无法在合并后解析 → 丢弃 fragment，落宿主顶部那张内联图。非吸收章行为不变。
    final int resolvedChapter = _resolveNavChapter(index);
    if (resolvedChapter != index) {
      index = resolvedChapter;
      fragment = null;
    }

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
      ErrorLogService.instance.log(
        'ReaderFushi._navigateToChapterWithFragment',
        e,
        stack,
      );
      debugPrint(
        '[ReaderFushi] _navigateToChapterWithFragment loadUrl failed: $e',
      );
      _failNavigation();
    }
  }

  // HBK-AUDIT-038: scroll to an in-page anchor without reloading the chapter.
  // Used when an internal link resolves to the chapter already on screen.
  Future<void> _jumpToFragmentInPlace(String fragment) async {
    if (_controller == null || !_readerContentReady) return;
    // BUG-2225：同章内链跳转不经 _beginNavigation，离开当前页在此结算。
    _readLedger.leave();
    // jsonEncode produces a valid, escaped JS string literal for the fragment.
    final String literal = jsonEncode(fragment);
    try {
      await _controller!.evaluateJavascript(
        source:
            'window.fushiReader && '
            'window.fushiReader.jumpToFragment($literal);',
      );
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'ReaderFushi._jumpToFragmentInPlace',
        e,
        stack,
      );
      debugPrint('[ReaderFushi] _jumpToFragmentInPlace failed: $e');
    }
  }

  // HBK-AUDIT-038: open a genuinely external link (http/https/mailto/tel) in the
  // OS handler instead of silently cancelling it. Non-external schemes are
  // ignored so we never hand the OS an internal fushi.local URL.
  Future<void> _openExternalUrl(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return;
    // BUG-097: an unresolved internal link (host == kHost) must stay in the
    // reader — never pop a blank OS browser for our virtual fushi.local host.
    if (!ReaderFushiSource.isExternalUrl(url)) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderFushi._openExternalUrl', e, stack);
      debugPrint('[ReaderFushi] _openExternalUrl failed for $url: $e');
    }
  }

  void _rebuildSpreadMap() {
    if (_book == null || _settings == null) return;
    _spreadMap = EpubSpreadMap.build(
      book: _book!,
      spreadMode: _settings!.spreadMode,
      spreadDirection: _settings!.spreadDirection,
      edgeMatchResults: _edgeMatchResults,
      mergeImagePages: _settings!.mergeImagePages,
    );
  }

  Future<void> _initSpreadMap(FushiDatabase db) async {
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

  Future<void> _runEdgeAnalysis(FushiDatabase db, String bookKey) async {
    if (_book == null) return;
    try {
      final Map<int, bool> results = await EpubSpreadAnalyzer.analyze(_book!);
      await EpubSpreadAnalyzer.saveCache(db, bookKey, results);
      _edgeMatchResults = results;
      _rebuildSpreadMap();
      if (mounted) _rebuild(() {});
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderFushi._runEdgeAnalysis', e, stack);
    }
  }

  Future<void> _navigateToVirtualPage(
    int virtualIndex, {
    double progress = 0.0,
    bool manual = false,
  }) async {
    if (_spreadMap == null) return;
    if (virtualIndex < 0 || virtualIndex >= _spreadMap!.length) return;
    final SpreadEntry entry = _spreadMap!.entryAt(virtualIndex);
    if (entry.isSpread) {
      await _navigateToSpread(entry);
    } else {
      await _navigateToChapter(
        entry.chapterIndex,
        progress: progress,
        manual: manual,
      );
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
      ErrorLogService.instance.log('ReaderFushi._navigateToSpread', e, stack);
      debugPrint('[ReaderFushi] _navigateToSpread failed: $e');
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

    // BUG-1426：spread 独立文档自带翻页输入。阈值取与正文引擎**同一个**真值来源
    // （`ReaderSettings.swipePageTurnDistThresholds`，随灵敏度设置缩放），不在
    // spread 侧另立一套默认值——否则调灵敏度只对正文生效，双页页面手感恒定。
    final ({int dist, int fastDist}) swipeThresholds =
        ReaderSettings.swipePageTurnDistThresholds(
          _settings?.swipePageTurnSensitivity ??
              ReaderSettings.defaultSwipePageTurnSensitivity,
        );
    // 键桥：按注册表当前绑定导出（改键即时跟随），外加与正文逐字同款的裸 Space 桥
    // （`onSpaceKey`，经 resolveReaderSpaceOverride 分流有声书播放/暂停 vs 翻页）。
    // 两座桥各自裹 IIFE + 幂等安装守卫，同一 document 共存互不覆盖。
    final String keyBridgeScript =
        '${webViewKeyBridgeScript(handlerName: 'onSpreadKey', keys: spreadKeyBridgeTokens(appModel.shortcutRegistry))}\n${webViewKeyBridgeScript(handlerName: 'onSpaceKey', keys: const <String>[' '])}';

    final String html = buildSpreadPageHtml(
      leftUrl: leftUrl,
      rightUrl: rightUrl,
      swipeDistThreshold: swipeThresholds.dist,
      swipeFastDistThreshold: swipeThresholds.fastDist,
      keyBridgeScript: keyBridgeScript,
    );

    // BUG-1280：置位必须在 loadData 之前——`onLoadStop` 可能在 await 返回前就
    // 派发，晚置位等于守卫对这一次加载失效。
    if (!_spreadDocumentLoaded) {
      _rebuild(() {
        _spreadDocumentLoaded = true;
      });
    }
    _isNavigatingToChapter = true;
    try {
      await _controller!.loadData(
        data: html,
        mimeType: 'text/html',
        encoding: 'utf-8',
        baseUrl: WebUri(
          ReaderFushiSource.epubUrl(_book!.chapters[entry.chapterIndex].href),
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
    return ReaderFushiSource.epubUrl(resolved);
  }

  bool _hasChapterTurnTarget(String direction) {
    final EpubBook? book = _book;
    if (book == null) return false;
    final EpubSpreadMap? spreadMap = _spreadMap;
    if (spreadMap != null) {
      final int currentVirtual = spreadMap.virtualPageForChapter(
        _currentChapter,
      );
      if (direction == 'forward') return currentVirtual + 1 < spreadMap.length;
      if (direction == 'backward') return currentVirtual > 0;
      return false;
    }
    if (direction == 'forward') {
      return _currentChapter < book.chapters.length - 1;
    }
    if (direction == 'backward') return _currentChapter > 0;
    return false;
  }

  /// BUG-2015：单文档阅读器仍要 load 下一章，但不再把加载过程直接暴露成整页黑屏。
  /// 截图和解码都发生在旧 WebView 仍可见时；成功后才让导航开始。截图属于可选视觉
  /// 增强，平台不支持或超过交互预算时正常导航，不能让跨章本身卡住。
  Future<bool> _prepareContinuousChapterTransition() async {
    if (_settings?.isContinuousMode != true ||
        !_readerContentReady ||
        _controller == null) {
      return true;
    }
    if (_chapterTransitionCaptureInFlight) return false;
    _chapterTransitionCaptureInFlight = true;
    final InAppWebViewController controller = _controller!;
    try {
      final bytes = await controller.takeScreenshot().timeout(
        const Duration(milliseconds: 450),
        onTimeout: () => null,
      );
      if (bytes == null || bytes.isEmpty) return true;
      if (!mounted) return false;
      final MemoryImage snapshot = MemoryImage(bytes);
      await precacheImage(snapshot, context);
      if (!mounted ||
          !identical(_controller, controller) ||
          !_readerContentReady) {
        unawaited(snapshot.evict());
        return false;
      }
      final MemoryImage? previous = _chapterTransitionSnapshot;
      _rebuild(() => _chapterTransitionSnapshot = snapshot);
      if (previous != null) unawaited(previous.evict());
      return true;
    } catch (error) {
      debugPrint(
        '[ReaderFushi] chapter transition snapshot unavailable: $error',
      );
      return true;
    } finally {
      _chapterTransitionCaptureInFlight = false;
    }
  }

  /// BUG-2015 收口：跨章快照只在**导航真的开始**（`_beginNavigation` 已把
  /// `_readerContentReady` 置 false）时才有意义。拿到快照却没进导航的路径
  /// （分页在飞 / 目标章不存在 / `_handlePageTurnLimit` 内部命中 spread 边界或
  /// nav 页守卫）必须当场丢弃：否则这帧旧视口会一直挂在遮罩里，被**下一次**
  /// `_readerContentReady` 归 false（换字号重排、歌词模式切换）当成「上一章画面」
  /// 淡出——那正是 reader_fushi_lyrics_transition_static_test 要防的整屏遮罩。
  void _discardIdleChapterTransitionSnapshot() {
    if (!_readerContentReady) return;
    final MemoryImage? snapshot = _chapterTransitionSnapshot;
    if (snapshot == null) return;
    _rebuild(() => _chapterTransitionSnapshot = null);
    unawaited(snapshot.evict());
  }

  void _handlePageTurnLimit(String direction, {bool inertia = false}) {
    if (_book == null) {
      return;
    }
    // BUG-369/TODO-656 诊断：跨章真正落子前记录方向与当前章号，便于对照「跳早了」。
    debugPrint(
      '[xchapter] handlePageTurnLimit dir=$direction '
      'chapter=$_currentChapter spread=${_spreadMap != null}',
    );
    _audiobookController?.noteManualReaderNavigation();

    // TODO-1128：翻页统一走虚拟页 map（含 spreadMode=='off'）。off 模式无合并时 map 是
    // identity（每章一页，与旧裸翻章逐章等价）；开启图片合并后被吸收单图片章没有自己的
    // 虚拟页，虚拟页翻页天然跳过它（前进落宿主正文顶部内联图，后退越过整段被吸收 run 到
    // 前一页），从源头消除「被吸收章被当独立页翻到 → 重复」。off 模式保留 manual=true 语义
    // （与旧裸 _navigateToChapter(manual:true) 一致）；spread 模式沿用 manual=false。
    if (_spreadMap != null) {
      final int currentVirtual = _spreadMap!.virtualPageForChapter(
        _currentChapter,
      );
      final bool manual = _settings?.spreadMode == 'off';
      if (direction == 'forward') {
        if (currentVirtual + 1 < _spreadMap!.length) {
          if (inertia) _markInertiaChapterTurnPending();
          _navigateToVirtualPage(currentVirtual + 1, manual: manual);
        }
      } else {
        if (currentVirtual > 0) {
          if (inertia) _markInertiaChapterTurnPending();
          _navigateToVirtualPage(
            currentVirtual - 1,
            progress: 0.99,
            manual: manual,
          );
        }
      }
      return;
    }

    // 兜底：spread map 尚未构建（book/settings 未就绪，翻页前罕见）时退回裸翻章。
    if (direction == 'forward') {
      if (_currentChapter < _book!.chapters.length - 1) {
        if (inertia) _markInertiaChapterTurnPending();
        _navigateToChapter(_currentChapter + 1, manual: true);
      }
    } else {
      if (_currentChapter > 0) {
        if (inertia) _markInertiaChapterTurnPending();
        _navigateToChapter(_currentChapter - 1, progress: 0.99, manual: true);
      }
    }
  }

  // ── Progress Save/Restore ─────────────────────────────────────────

  /// 恢复锚的当前值，聚成 [ReaderRestoreAnchor] 读。四个字段仍是 State 的存储
  /// （既有守卫按字段名钉住导航侧写入形态），这里只给它们一个有语义的读视图。
  ReaderRestoreAnchor get _restoreAnchor => ReaderRestoreAnchor(
    progress: _initialProgress,
    charOffset: _initialCharOffset,
    charOffsetEnd: _initialCharOffsetEnd,
    fragment: _initialFragment,
  );

  /// TODO-2603：恢复锚生命周期**阶段 ②** 的唯一写入口——恢复落定之后，实时进度采样
  /// 接管恢复锚。
  ///
  /// 没有这一步，恢复锚就永远停在 `_beginNavigation` 写下的进章快照（跨章翻页恒
  /// `0.0 / -1`）；此后任何一次 WebView 重建（renderer 被 OOM 回收后换 key 重建）都会
  /// restore 回章首，再由本文件的 `_debouncedSavePosition` 把这个回退位置落库，覆盖掉
  /// 用户更靠后的真实进度。判据（在飞 = 保留目标 / 已落定 = 跟随实时进度）在纯函数
  /// [restoreAnchorOnLiveProgress] 里，有真行为测；此处只做接线。
  void _adoptLiveProgressAsRestoreAnchor(double progress, int charOffset) {
    final ReaderRestoreAnchor next = restoreAnchorOnLiveProgress(
      current: _restoreAnchor,
      restoreInFlight: _restoreInFlight,
      liveProgress: progress,
      liveCharOffset: charOffset,
    );
    _initialProgress = next.progress;
    _initialCharOffset = next.charOffset;
    _initialCharOffsetEnd = next.charOffsetEnd;
    _initialFragment = next.fragment;
  }

  Future<void> _refreshProgress() async {
    // BUG-2207：恢复在飞（含 _reloadWithCurrentSettings 的整章重载）期间不采样——
    // 10s 轮询不受 readerScrollProgressRefreshAllowed 门控，重载中 JS 的瞬态 atEnd /
    // 章末 progress 会把「旧位置 → 章末」整段计成本次读到的新字数。恢复完成
    // （_onRestoreComplete）与失败（_failNavigation / reload catch）都清旗，之后的
    // 首发刷新、onReanchorSettled 补刷都在清旗之后到达，不受这条门影响。
    if (_controller == null || _lyricsMode || _restoreInFlight) return;
    final dynamic result;
    try {
      result = await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.stableProgressInvocation(),
      );
    } catch (e, stack) {
      // TODO-2603：renderer 死亡 / WebView 半销毁后 evaluateJavascript 抛
      // PlatformException（或在报废 controller 上永不完成）。本方法由 10s 轮询、
      // scroll 回传与恢复完成三条路驱动，裸 await 会把异常抛成**未捕获异步错误**
      // （换 key 重建那一瞬每条在飞路径各一次）。此处尚未改任何进度状态，安全
      // no-op 返回；与 reloadWithCurrentSettings / _syncPositionFromWebViewProgress
      // 同一 fail-open 范式：不吞成静默，补 ErrorLogService.log。
      ErrorLogService.instance.log(
        'ReaderFushi._refreshProgress.eval',
        e,
        stack,
      );
      return;
    }
    if (result == null) {
      // BUG-493：null = JS stableProgressInvocation 早退（重锚在飞 _reanchorPending / 尚未
      // settle）。这是**瞬态**：JS 侧清旗已单点化（_sharedJs 的 _setReanchorPending），
      // true→false 转换时经 onReanchorSettled 事件（webview.part.dart 注册）通知 Dart 补刷
      // 一次进度——事件驱动替代旧的 120ms×8 轮询重试，覆盖所有清旗路径。此处直接早退等
      // 事件即可；图片/封面章的 null 走空串→snapshot==null 分支由
      // _applyImagePageProgressFallback 兜底显示。
      return;
    }
    if (!mounted) return;
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

    // TODO-718（回退式根治·2026-06-25）：原 TODO-798「位置不连续启发式拦截器」+ userDriven
    // 路由已整套删除——它依赖的 userDriven 信号真机恒真致拦截器形同虚设、且与原始 reanchor
    // 机制并存打架（横排误触发跳章）。抗自发 reflow 归零回到干净的源头屏蔽机制：恢复完成
    // 的 [_reanchorContinuousAfterRestore] 两阶段 begin→commit 期间，webview.part.dart 的
    // `_reanchorPending` 旗在 scroll 上报源头直接 return，归零 scroll 根本不回传、永不落库，
    // settle 后把锚滚回；commit 清旗那一刻起 B-3 250ms 窗在 _handleReaderScroll 兜尾沿。
    // 晚到 reflow（cue 注入 / 大章 settle）由事件驱动重锚覆盖（见 _reanchorContinuousAfterRestore
    // 的再触发点）。这里不再做任何启发式判据，读到什么就如实落库。

    _lastProgressSection = _currentChapter;
    _lastProgressValue = progress;
    _lastProgressCharOffset = charOffset;
    // TODO-2603：实时进度既是「落库位置」也是「新建 WebView 的恢复目标」，两者必须
    // 同源。放在 _lastProgress* 之后、落库之前，顺序即契约。
    _adoptLiveProgressAsRestoreAnchor(progress, charOffset);
    // 分数口径的绝对位置只给进度 UI（_progressCurrentChars）；统计不再用它。
    final int absoluteChars = _absoluteCharPosition(progress);
    // 「读过」判据：当前可见区间 `[start, end)`（全书绝对学习单位偏移）交给账本，
    // 翻走即计 + 会话并集去重（ReadUnitLedger，裁定见 docs/plans/2026-09-06）。起 / 止
    // 任一拿不到（旧 shell 三段协议 / caret 探测失败 / 章计数未就绪）或 end <= start
    // 都不 arrive——宁可不计。同一单元重复采样在账本里是 no-op。
    final int unitStart = absoluteCharOffsetOf(
      chapterCumulativeChars: _chapterCumulativeChars,
      chapterCharCounts: _chapterCharCounts,
      chapter: _currentChapter,
      charOffset: charOffset,
    );
    final int unitEnd = absoluteCharOffsetOf(
      chapterCumulativeChars: _chapterCumulativeChars,
      chapterCharCounts: _chapterCharCounts,
      chapter: _currentChapter,
      charOffset: snapshot.charOffsetEnd,
    );
    if (unitStart >= 0 && unitEnd > unitStart) {
      _readLedger.arrive(unitStart, unitEnd);
    }
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
      // BUG-470（TODO-975 回归修复）：顶部进度预留 [_topProgressReserve] 经 [_showTopProgress]
      // 门控，而后者要求 _progressCurrentChars / _progressTotalChars 非空且 > 0——这两个字段
      // 恰在本方法（_refreshProgress）才首次置值，**晚于**首载注入 setup 脚本的 `--chrome-top-inset`
      // （webview.part.dart 用 _readerTopOffset，此刻 _showTopProgress 仍 false → 顶部 inset 漏掉
      // 18px 进度条预留）。首载后再无任何路径在「进度由空→正」的跃迁上重推 inset，于是正文首行
      // 被顶部进度条压住，直到下次样式变更/切主题/toggle 底栏/旋屏触发 inset 重推才自愈。
      //
      // 修复：捕获 rebuild 前后的 [_showTopProgress]（顶部预留的唯一门控真相源），仅在它由
      // false→true 的**上升沿**补一次 inset 重推；用 [_applyChromeInsetsAndReanchor] 走 begin→commit
      // 重锚，先下发含 18px 顶部预留的新 inset、再把阅读位置滚回（连续模式裸改 inset 会 reflow 归零
      // 弹回章首，分页模式 JS 侧整体 no-op）。只在上升沿补推，避免每次进度刷新都重推 inset 抖动。
      final bool topProgressWasShown = _showTopProgress;
      if (_progressCurrentChars != absoluteChars ||
          _progressTotalChars != newTotal) {
        _rebuild(() {
          _progressCurrentChars = absoluteChars;
          _progressTotalChars = newTotal;
        });
      }
      if (!topProgressWasShown && _showTopProgress) {
        unawaited(
          _applyChromeInsetsAndReanchor().catchError((Object e, StackTrace s) {
            ErrorLogService.instance.log(
              'ReaderFushi.refreshProgress.topInsetRepush',
              e,
              s,
            );
          }),
        );
      }
      // TODO-151/164 / BUG-225 诊断（默认 off，DebugLogService.instance.enabled 门控）：
      // 记重算后章内进度 UI 字段最终值，便于真机确认滚动后进度数确实推进/未推进。
      if (DebugLogService.instance.enabled) {
        debugPrint(
          '[ReaderDiag] _refreshProgress'
          ' progressCurrentChars=$_progressCurrentChars'
          ' progressTotalChars=$_progressTotalChars'
          ' (progress=${progress.toStringAsFixed(4)} section=$_currentChapter)',
        );
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
        'ReaderFushi.syncPositionFromWebViewProgress.eval',
        e,
        stack,
      );
      debugPrint('[ReaderFushi] syncPositionFromWebViewProgress failed: $e');
      return;
    }
    if (!mounted) return;

    final ReaderStableProgressDetails? snapshot =
        parseReaderStableProgressDetails(result);
    if (snapshot == null) {
      return;
    }

    // TODO-718：退出 / lifecycle flush 的这次**实时读**可能撞上自发 reflow 归零（cue 注入 /
    // settle 把 scrollY 瞬时归 0，stableProgress 返回**有效的 0**）。简单不变量（非启发式·无
    // userDriven·无时间窗·无重锚动作）：退出读不得用瞬时 ≈0 覆盖一个已知非章首的缓存位置。
    // 连续模式下，若读到章首(≤epsilon)而缓存位置明显非章首、且非有声书播放 → 判瞬时归零，
    // 丢弃本次读、保留缓存（_flushPosition 落缓存的真实位置）。用户真滚到章首时 _lastProgressValue
    // 已被 _refreshProgress 实时写≈0，prior 不再>epsilon → 不拦，如实落 0。
    const double chapterStartEpsilon = 0.01;
    final bool transientZero =
        _settings?.isContinuousMode == true &&
        snapshot.progress <= chapterStartEpsilon &&
        _lastProgressValue > chapterStartEpsilon &&
        _audiobookController?.isPlaying != true;
    if (transientZero) {
      if (DebugLogService.instance.enabled) {
        debugPrint(
          '[ReaderFushi] syncPosition skip transient reflow-zero: '
          'prior=${_lastProgressValue.toStringAsFixed(4)} '
          'read=${snapshot.progress.toStringAsFixed(4)} → keep cached anchor',
        );
      }
      return;
    }

    _lastProgressSection = _currentChapter;
    _lastProgressValue = snapshot.progress;
    _lastProgressCharOffset = snapshot.charOffset;
    // TODO-2603：本方法是实时进度的第二个所有者（退出 / lifecycle flush 的实时读），
    // 恢复锚同样跟随，规则与 _refreshProgress 逐字相同。
    _adoptLiveProgressAsRestoreAnchor(snapshot.progress, snapshot.charOffset);
  }

  void _debouncedSavePosition(double progress, int charOffset) {
    _debouncedSaveReaderPosition(_currentChapter, progress, charOffset);
  }

  void _debouncedSaveReaderPosition(
    int section,
    double progress,
    int charOffset,
  ) {
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
    int section,
    double progress,
    int charOffset,
  ) async {
    // BUG-459: 临时浏览跳转（收藏句 / 制卡历史跳回原文）整页生命周期内不落盘——保住
    // 用户真实阅读进度，不被跳转锚覆盖。debounce 保存与退出 flush 都汇聚此处，单点拦截。
    if (_suppressPositionPersist) {
      return;
    }
    // v82：位置键 = EpubBooks.uid（[_bookUid]，开书定位时解析）。uid 缺失（书行
    // 不在库——正常路径 init 早已 pop，此处仅防御）时跳过写入，不拿 bookKey 兜底
    // 造永远 JOIN 不上的孤儿行。
    final String? bookUid = _bookUid;
    if (bookUid == null) {
      return;
    }
    _lastSavedSection = section;
    _lastSavedProgress = progress;

    // BUG-162/BUG-285：量化 + 精确锚取舍已凿进纯函数 readerPositionSaveArgs
    // （有真行为测），此处只做接线。
    final ({int normCharOffset, int? charOffset}) saveArgs =
        readerPositionSaveArgs(progress: progress, charOffset: charOffset);
    debugPrint(
      '[ReaderFushi] save position: bookKey=${widget.bookKey} '
      'section=$section normOffset=${saveArgs.normCharOffset} '
      'charOffset=$charOffset',
    );
    final ReaderPositionRepository repo = ReaderPositionRepository(
      appModel.database,
    );
    try {
      await repo.save(
        bookUid: bookUid,
        sectionIndex: section,
        normCharOffset: saveArgs.normCharOffset,
        // BUG-162: >=0 写精确锚（char_offset 列）。<0（WebView 当帧算不出精确偏移）
        // 传 null → ReaderPositionRepository.save 在同 section 保留既有精确锚、仅跨
        // section 失效。BUG-285 回归：TODO-265 误改成直接传 -1，使 _refreshProgress /
        // _syncPositionFromWebViewProgress 在重排或竖排边缘拿到 -1 时把同 section 的
        // 精确锚覆盖成 -1 → 恢复/有声书跨章重锚退化成「章首分数」（章节粒度），不再
        // 逐句跟随。取舍语义在 readerPositionSaveArgs 纯函数里（-1 → null），把
        // 同/跨 section 的保留/失效决策交回 repo.save。
        charOffset: saveArgs.charOffset,
      );
    } catch (e, stack) {
      // fail-open：本次位置未落盘（后续 debounce/flush 会重试），补日志便于诊断。
      ErrorLogService.instance.log('ReaderFushi._persistPosition', e, stack);
    }

    // 读到全书末尾（最后一章 + 章内进度到末尾）→ 自动写「已读完」时间戳。
    // markEpubBookCompletedIfUnset 幂等（仅 completed_at IS NULL 时写），不刷新时间戳、
    // 绝不覆盖用户手动标记/取消的状态。手动翻页与有声书自动推进到末章末句都汇聚
    // _persistPosition，故两条路径统一由此接线；临时跳转已被上方 _suppressPositionPersist
    // 提前返回，不会误触发。widget.bookKey 即当前书（有声书会话为其配对 EpubBooks 行）。
    final EpubBook? book = _book;
    final bool completed =
        book != null &&
        book.chapters.isNotEmpty &&
        section >= book.chapters.length - 1 &&
        progress >= 0.999;
    if (completed) {
      await appModel.database.markEpubBookCompletedIfUnset(
        widget.bookKey,
        DateTime.now(),
      );
    }
    if (!kMediaTrackingEnabled) return;
    await appModel.mediaTrackingService.recordBookProgress(
      bookKey: widget.bookKey,
      completedChapterCount: section + (progress >= 0.999 ? 1 : 0),
      completed: completed,
    );
  }

  void _syncPositionFromCurrentCue() {
    final AudioCue? cue = _audiobookController?.currentCue;
    if (cue == null) return;
    final SubtitleRematchFragment? frag = SubtitleRematchCodec.tryDecode(
      cue.textFragmentId,
    );
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
          _lastProgressSection,
          _lastProgressValue,
          -1,
        );
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
          _lastProgressSection,
          _lastProgressValue,
          -1,
        );
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
  ///
  /// TODO-2495：这条链的两段性质不同，交给 [flushWithBoundedProbe] 分开对待——
  /// 实时探针（WebView `evaluateJavascript`，唯一没有延迟上界的一段）限时
  /// [kReaderExitProbeBudget]，落库（Drift 写）不限时且**永不跳过**。
  ///
  /// 根因不是「某一段慢」，而是「一段没有延迟上界的 await 被压在无 UI 反馈的单飞门
  /// 底下」：本方法被 `onSourcePagePop` → `onWillPop` → `PopScope` 逐层 await，
  /// `_popInProgress` 在整条链跑完前一直顶着，且只在 `onWillPop()` 返回时才复位——
  /// 探针挂死就等于返回键永久失效（比 BUG-1273 更糟，那个至少能自愈）。降级口径与
  /// [_flushAllForProcessExit] 一致：探针超时/抛错就落 debounce 已算好的缓存锚。
  /// 完整论证见 [flushWithBoundedProbe] 的文档注释。
  Future<void> _syncAndFlushPosition() async {
    await flushWithBoundedProbe(
      probe: () async {
        if (_lyricsMode) {
          _syncPositionFromCurrentCue();
        } else {
          await _syncPositionFromWebViewProgress();
        }
      },
      persist: () async {
        await _flushPosition();
        await _audiobookController?.flushPosition();
      },
      probeBudget: kReaderExitProbeBudget,
      onProbeFailure: (Object error, StackTrace stack) {
        ErrorLogService.instance.log(
          'ReaderFushi.syncAndFlushPosition.probe',
          error,
          stack,
        );
      },
    );
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
    _readLedger.leave();
    await _flushReadingStats();
    await _audiobookController?.flushPosition();
  }

  Future<void> _flushPosition() async {
    _saveDebounce?.cancel();
    if (!_hasEverLoaded || _lastProgressSection < 0) {
      return;
    }
    await _persistPosition(
      _lastProgressSection,
      _lastProgressValue,
      _lastProgressCharOffset,
    );
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

    // 进度条拖动是跳转不是阅读：不播种（旧标量水位要在此播种）。跨章走
    // [_beginNavigation] 的 `leave()`；同章 `restoreProgress` 不经导航，得在这里自己
    // `leave()`——否则 JS `notifyRestoreComplete` 抢在 scroll 回传之前时，跳走前那页
    // 会被当成「原位恢复」不结算（BUG-2225；VN 无 scroll 事件，必现）。
    final ChapterProgressTarget target = resolveChapterProgressForGlobalOffset(
      _chapterCumulativeChars,
      _chapterCharCounts,
      globalOffset,
    );

    if (target.chapter != _currentChapter) {
      // TODO-1309：跨章字符跳转把章内分数烘进导航（progress）单次原子恢复直接落点、连续
      // 重锚采样保住——与书签/收藏统一走 navigate-with-baked-progress 原子链，await 到恢复
      // 落定，不再裸 fire-and-forget 只依赖 initialProgress（被后续 settle-reflow 冲掉）。
      await _navigateToChapterAndWait(
        target.chapter,
        manual: true,
        progress: target.progress,
      );
    } else {
      _readLedger.leave();
      await _controller!.evaluateJavascript(
        source:
            'window.fushiReader && window.fushiReader.restoreProgress(${target.progress});',
      );
    }
  }

  /// 把本 session 累积的字数 + 阅读时长落库。返回的 Future 在 DB 写完成后才完成，
  /// 供进程退出路径 await（TODO-086/BUG-191）；其余生命周期调用点 fire-and-forget
  /// （不 await 返回的 Future，行为同旧版）。计数器在发起写之前清零，保证同一段
  /// 时长/字数不会被重复累加。
  /// v92：建好并启动本页唯一的阅读时钟（幂等；对已在跑的时钟 start() 是 no-op，
  /// 重排版 / 重恢复不打断计时、不重锚任何账）。
  ///
  /// 时长与字数记到**同一段**（`study_segments` 同 uid 一行）：不存在第二本账可被
  /// 重锚吃掉（BUG-1052），也不存在「有时长没字数被拒写」的口径分叉（BUG-1107）。
  /// 空闲门（[kDefaultReadingIdleTimeout]）+ 生命周期 stop/start 的前台门只对阅读
  /// 面生效（用户拍板：视频以播放态为准）。
  StudyClock _ensureStudyClock() {
    final StudyClock clock = _studyClock ??= StudyClock(
      database: appModel.database,
      mediaKind: kActivityMediaBook,
      mediaKey: widget.bookKey,
      title: _book?.title ?? widget.bookKey,
      format: BookFormat.epub.dbValue,
      onWriteError: (Object e, StackTrace st) =>
          ErrorLogService.instance.log('StudyClock.write(epub)', e, st),
    );
    // BUG-2213：空闲门分钟数每次都从设置刷（字段本就可变）——旧实现只在建时钟时
    // 快照一次，阅读中改设置要退出重开书才生效。
    clock.idleTimeout = appModel.readingIdleTimeout;
    // 手动暂停 / 切后台 / 面板打开时不自动起表（章导航 / 进度刷新都会经这里）：
    // 统一判据，见 [studyClockMayRun]（BUG-2209：旧实现只看手动暂停旗，后台听书
    // 跟随每次翻章都把生命周期已停掉的时钟重新起表）。
    if (_studyClockMayRun) clock.start();
    return clock;
  }

  /// 时钟此刻可跑（[studyClockMayRun]）。
  bool get _studyClockMayRun => studyClockMayRun(
    manualPause: _studyClockManualPause,
    lifecycleStopped: _studyClockLifecycleStopped,
    modalDepth: _studyClockModalDepth,
  );

  /// 把时钟运行态对齐到判据：可跑 → `start()`（对已在跑的是 no-op），不可跑 →
  /// `stop()`（结算部分窗口 + 封段落库；对已停的是 no-op）。三枚旗任一翻转后调用。
  void _syncStudyClockRunState() {
    final StudyClock? clock = _studyClock;
    if (clock == null) return;
    if (_studyClockMayRun) {
      clock.start();
    } else {
      unawaited(clock.stop());
    }
  }

  /// 在面板 / 弹层 / 全页路由压住正文期间停表（BUG-2208，对齐 Hoshi Android 的
  /// `modalPaused`）：进入时 `stop()` 结算到此刻并封段落库，退出后按判据续表
  /// （手动暂停 / 后台仍不续）。查词浮窗与 Anki 制卡对话框**不**经这里——那是阅读的
  /// 一部分。计数而非 bool：面板里再开对话框（有声书面板 → 导入）嵌套时不会提前续表。
  Future<T> _withStudyClockPaused<T>(Future<T> Function() body) async {
    _studyClockModalDepth++;
    _syncStudyClockRunState();
    try {
      return await body();
    } finally {
      _studyClockModalDepth--;
      if (mounted) _syncStudyClockRunState();
    }
  }

  /// 把「上一次 tick 到现在」的部分窗口结算并落库（不停表）。章导航 / 退出 /
  /// 生命周期节点调用，让最后一段不因随后的 dispose 而丢。写库失败由时钟 fail-open
  /// 并在下个 tick 用绝对值重写，这里没有任何计数器可清、也没有任何东西能重复累加。
  Future<void> _flushReadingStats() async {
    await _studyClock?.flushNow();
  }
}
