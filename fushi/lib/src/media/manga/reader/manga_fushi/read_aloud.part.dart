part of '../manga_fushi_page.dart';

/// 漫画朗读在阅读器侧的接线：编排全在 [MangaReadAloudController]，这里只实现
/// [MangaReadAloudHost]（页文字 / 高亮 / 翻页 / 学习时钟）并管理入口与生命周期。
///
/// 页文字的等待者按页登记（[_waiters]），由 OCR 的各个出口落定：
/// - 热替换 / 整卷逐页 / 整卷完成 → [_pageTextArrived]（Ready）；
/// - 无引擎 / Lens 被拒 / 失败 / 取消 / 换章 → [_failWaiters]（Unavailable）；
/// - 既没有识别器、也没有在启动 / 排队的任务 → [_settleOrphanWaiters]（failed）。
/// 不设超时：本地模型一页几十秒是常态，等待者只由真实出口落定。
class _MangaReadAloudSupport implements MangaReadAloudHost {
  _MangaReadAloudSupport(this._s, {required VoidCallback rebuild})
    : _rebuild = rebuild;

  final _MangaFushiPageState _s;

  /// 页面重建（工具栏按钮激活态 / 播放条挂载跟着会话起止变）。
  final VoidCallback _rebuild;

  /// 本章里 OCR 已落定的页（含识别结果为空的页）。
  final Set<int> _ocrSettledPages = <int>{};

  /// 正在等文字的页（直读识别器起来后要逐一 request）。
  Iterable<int> get waitingPages => _waiters.keys;
  final Map<int, Completer<MangaPageTextResult>> _waiters =
      <int, Completer<MangaPageTextResult>>{};

  MangaReadAloudController? controller;

  /// 正在高亮的句子（文字层重建后由 [_replaceSpreadOcr] 重新挂上）。
  (int, int)? _speaking;
  bool _starting = false;

  bool get active => controller?.isActive ?? false;

  // ── MangaReadAloudHost ────────────────────────────────────────────────

  @override
  int get pageCount => _s._payload?.images.length ?? 0;

  @override
  bool get rightToLeft => _s._spreadDirection == 'rtl';

  @override
  int get visiblePage => _s._currentPage;

  @override
  bool isSameSpread(int a, int b) =>
      MangaFushiPage.spreadIndexForPage(_s._spreads, a) ==
      MangaFushiPage.spreadIndexForPage(_s._spreads, b);

  bool _pageHasText(MokuroPayload payload, int pageIndex) =>
      _s._volumeOcrSettled ||
      _ocrSettledPages.contains(pageIndex) ||
      payload.images[pageIndex].blocks.isNotEmpty;

  @override
  Future<MangaPageTextResult> ensurePageText(int pageIndex) async {
    final MokuroPayload? payload = _s._payload;
    if (!_s.mounted ||
        payload == null ||
        pageIndex < 0 ||
        pageIndex >= payload.images.length) {
      return const MangaPageTextUnavailable(
        MangaPageTextUnavailableReason.cancelled,
      );
    }
    if (_pageHasText(payload, pageIndex)) {
      return MangaPageTextReady(payload.images[pageIndex]);
    }
    if (_s._chapterNotDownloaded) {
      return const MangaPageTextUnavailable(
        MangaPageTextUnavailableReason.chapterOcrDisabled,
      );
    }
    final Completer<MangaPageTextResult> waiter = _waiters.putIfAbsent(
      pageIndex,
      Completer<MangaPageTextResult>.new,
    );
    if (_s._streamingChapter) {
      // 手动触发模式下也要起页级识别（朗读是用户主动发起的）。识别器还在启动时
      // 这里拿不到它，由启动完成处把在等的页逐一 request（_maybeStartStreamingOcr）。
      await _s._maybeStartStreamingOcr(userInitiated: true);
      // 按需识别而不是 focus：focus 是读者翻页语义（挪识别窗口、同一页原地不重试），
      // 预取下一页会把读者眼前的窗口挪走，失败过的页再要时也不会重跑。request 保证
      // 这一页一定有结局（_pageTextArrived / _pageTextFailed）。
      _s._streamOcr?.request(pageIndex);
    } else {
      await _s._maybeStartVolumeOcr(userInitiated: true);
      _s._observedOcrJob?.focusPage(pageIndex);
    }
    _settleOrphanWaiters();
    return waiter.future;
  }

  @override
  Future<void> show(int pageIndex, int group) async {
    _speaking = (pageIndex, group);
    if (!_s.mounted) return;
    if (!isSameSpread(pageIndex, _s._currentPage)) {
      await _s._jumpToPage(pageIndex + 1);
    }
    await _s._controller?.evaluateJavascript(source: _speakingJs());
  }

  @override
  Future<void> clearHighlight() async {
    _speaking = null;
    if (!_s.mounted) return;
    await _s._controller?.evaluateJavascript(source: _speakingJs());
  }

  @override
  void markStudyActivity() => _s._studyClock?.touch();

  // ── OCR 出口 ──────────────────────────────────────────────────────────

  /// 一页的 OCR 落定（热替换 / 整卷逐页）。
  void _pageTextArrived(int pageIndex, MokuroImage page) {
    _ocrSettledPages.add(pageIndex);
    final Completer<MangaPageTextResult>? waiter = _waiters.remove(pageIndex);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(MangaPageTextReady(page));
    }
  }

  /// 整卷完成：所有等待者按落盘结果落定。
  void _volumeSettled(MokuroPayload payload) {
    for (final int pageIndex in _waiters.keys.toList()) {
      if (pageIndex >= 0 && pageIndex < payload.images.length) {
        _pageTextArrived(pageIndex, payload.images[pageIndex]);
      }
    }
    _failWaiters(MangaPageTextUnavailableReason.cancelled);
  }

  void _pageTextFailed(int pageIndex) {
    final Completer<MangaPageTextResult>? waiter = _waiters.remove(pageIndex);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(
        const MangaPageTextUnavailable(MangaPageTextUnavailableReason.failed),
      );
    }
  }

  void _failWaiters(MangaPageTextUnavailableReason reason) {
    if (_waiters.isEmpty) return;
    final List<Completer<MangaPageTextResult>> waiters = _waiters.values
        .toList();
    _waiters.clear();
    for (final Completer<MangaPageTextResult> waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete(MangaPageTextUnavailable(reason));
      }
    }
  }

  /// 没有任何东西会再交出页文字（识别器没起来、任务没在跑也没在排队 / 启动）：
  /// 剩下的等待者以「失败」落定，而不是永远挂着。
  void _settleOrphanWaiters() {
    if (_waiters.isEmpty) return;
    final bool sourcePending = _s._streamingChapter
        ? _s._streamOcr != null || _s._streamOcrStarting
        : _s._observedOcrJob != null ||
              _s._volumeOcrQueued ||
              _s._volumeOcrStarting;
    if (!sourcePending) _failWaiters(MangaPageTextUnavailableReason.failed);
  }

  /// 换章 / 重载正文：页号只对旧章有效。
  void _onChapterReset() {
    controller?.stop();
    _speaking = null;
    _ocrSettledPages.clear();
    _failWaiters(MangaPageTextUnavailableReason.cancelled);
  }

  // ── 高亮 JS ──────────────────────────────────────────────────────────

  String _speakingJs() {
    final (int, int)? speaking = _speaking;
    return 'window.__mangaSetSpeaking && window.__mangaSetSpeaking('
        '${speaking?.$1 ?? -1}, ${speaking?.$2 ?? -1});';
  }

  /// 文字层重建（窗口重载 / 懒挂 OCR 框）之后重新挂高亮；没在朗读时为空。
  String get reapplyJs => _speaking == null ? '' : _speakingJs();

  // ── 入口与生命周期 ────────────────────────────────────────────────────

  TtsServices get _tts => TtsServices.of(_s.appModel.prefsRepo);

  /// 工具栏「朗读」：没在读就从当前页开始，在读就停。
  Future<void> toggle() async {
    if (active) {
      stop();
      return;
    }
    await start();
  }

  Future<void> start() async {
    if (_starting || !_s.mounted || _s._payload == null) return;
    _starting = true;
    try {
      final _MangaReadAloudServicesRig rig;
      try {
        rig = await _MangaReadAloudServicesRig.create(_tts);
      } on _MangaReadAloudVoiceMissing catch (missing) {
        FushiToast.show(
          msg: missing.incomplete
              ? t.audiobook_tts_voice_incomplete
              : t.audiobook_tts_no_voice,
          severity: ToastSeverity.warning,
        );
        return;
      }
      if (!_s.mounted) {
        await rig.dispose();
        return;
      }
      MangaReadAloudController? c = controller;
      if (c == null) {
        c = MangaReadAloudController(
          host: this,
          rig: rig,
          pronunciation: _tts.pronunciation.load(),
          playToEnd: (String path, double speed) =>
              DesktopAudioPlayback.playFileToEnd(path, speed: speed),
          stopPlayback: DesktopAudioPlayback.stop,
          readSpeed: () => _tts.store.speed,
          writeSpeed: _tts.store.setSpeed,
        );
        c.addListener(_onControllerChanged);
        controller = c;
      } else {
        await c.replaceRig(rig);
      }
      c.start(fromPage: _s._currentPage);
      _rebuild();
    } catch (error, stack) {
      ErrorLogService.instance.log('MangaFushiPage.readAloud', error, stack);
      FushiToast.show(
        msg: t.audiobook_tts_start_failed,
        severity: ToastSeverity.error,
      );
    } finally {
      _starting = false;
    }
  }

  MangaReadAloudState? _lastState;

  void _onControllerChanged() {
    final MangaReadAloudController? c = controller;
    if (c == null || !_s.mounted) return;
    final MangaReadAloudState state = c.state;
    if (state != _lastState && state == MangaReadAloudState.finished) {
      // 读到章末不自动进下一章：停下并提示。
      FushiToast.show(
        msg: c.finish == MangaReadAloudFinish.noText
            ? t.manga_read_aloud_no_text
            : t.manga_read_aloud_chapter_end,
      );
    }
    final bool rebuild =
        (state == MangaReadAloudState.idle) !=
        (_lastState == MangaReadAloudState.idle);
    _lastState = state;
    // 工具栏按钮的激活态跟着会话起止变。
    if (rebuild) _rebuild();
  }

  void stop() => controller?.stop();

  void pause() => controller?.pause();

  /// 朗读不做后台播放：阅读器看不见（hidden / paused / detached）才暂停，回来从
  /// 当前句开头续。与有声书同一判据（[readerVisibleForLifecycleState]）：inactive
  /// 时画面仍在（下拉通知栏 / 控制中心 / 系统弹窗、桌面窗口失焦），不打断。
  void onAppLifecycleChanged(AppLifecycleState state) =>
      controller?.onAppLifecycleChanged(state);

  void onPageChanged(int page) => controller?.onPageChanged(page);

  /// 朗读中快速切换声音：选中即设为使用中，用新声音从当前句重读。
  Future<void> switchVoice() async {
    final TtsServices tts = _tts;
    final TtsVoiceQuickSwitchChoice? choice = await showTtsVoiceQuickSwitch(
      _s.context,
      tts,
    );
    if (choice == null || !_s.mounted) return;
    final String? presetId = choice.presetId;
    if (presetId == null) {
      controller?.pause();
      await openTtsVoiceSettingsPage(_s.context, tts);
      return;
    }
    await tts.store.setActivePresetId(presetId);
    final MangaReadAloudController? c = controller;
    if (c == null) return;
    try {
      await c.replaceRig(await _MangaReadAloudServicesRig.create(tts));
    } on _MangaReadAloudVoiceMissing catch (missing) {
      FushiToast.show(
        msg: missing.incomplete
            ? t.audiobook_tts_voice_incomplete
            : t.audiobook_tts_no_voice,
        severity: ToastSeverity.warning,
      );
    }
  }

  void dispose() {
    final MangaReadAloudController? c = controller;
    controller = null;
    _failWaiters(MangaPageTextUnavailableReason.cancelled);
    if (c == null) return;
    c.removeListener(_onControllerChanged);
    c.dispose();
  }
}

/// 没有可用的朗读声音（[incomplete] = 有但参数不全）。
class _MangaReadAloudVoiceMissing implements Exception {
  const _MangaReadAloudVoiceMissing({required this.incomplete});
  final bool incomplete;
}

/// 生产声音：当前朗读声音 + 全应用共用的 [TtsAudioCache]（同句同音色只合一次，
/// 与小说朗读 / 制作台共用）。
class _MangaReadAloudServicesRig implements MangaReadAloudVoiceRig {
  _MangaReadAloudServicesRig._({
    required TtsProvider provider,
    required TtsAudioCache cache,
    required Map<String, Object?> audioIdentity,
    required this.maxInputLength,
  }) : _provider = provider,
       _cache = cache,
       _audioIdentity = audioIdentity;

  static Future<_MangaReadAloudServicesRig> create(TtsServices tts) async {
    // 从没配过声音时与「朗读声音」页同一份开箱默认（微软 Edge）。
    await tts.seedBuiltinVoiceIfUnset();
    final ({TtsVoicePreset preset, TtsProviderDescriptor descriptor})? voice =
        tts.activeVoice();
    if (voice == null) {
      throw const _MangaReadAloudVoiceMissing(incomplete: false);
    }
    if (voice.descriptor.validate(voice.preset).isNotEmpty) {
      throw const _MangaReadAloudVoiceMissing(incomplete: true);
    }
    return _MangaReadAloudServicesRig._(
      provider: voice.descriptor.create(voice.preset, tts.host),
      cache: await tts.cache(),
      audioIdentity: voice.descriptor.audioIdentity(voice.preset),
      maxInputLength: voice.descriptor.capabilities.maxInputLength,
    );
  }

  final TtsProvider _provider;
  final TtsAudioCache _cache;
  final Map<String, Object?> _audioIdentity;

  @override
  final int maxInputLength;

  @override
  TtsSynthesisScheduler createScheduler(List<String> texts) =>
      TtsSynthesisScheduler(
        provider: _provider,
        cache: _cache,
        texts: texts,
        audioIdentity: _audioIdentity,
      );

  @override
  Future<void> dispose() => _provider.dispose();
}
