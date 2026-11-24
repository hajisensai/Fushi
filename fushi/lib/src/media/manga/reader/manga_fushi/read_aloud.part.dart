part of '../manga_fushi_page.dart';

/// 漫画朗读在阅读器侧的接线：编排全在 [MangaReadAloudController]，这里只实现
/// [MangaReadAloudHost]（页文字 / 高亮 / 翻页 / 学习时钟）并管理入口与生命周期。
///
/// 两种音源：这卷登记过漫画有声成品（`manga_audio_library.dart`）时「朗读」播成品
/// （[MangaAudioPlaybackDriver]，会话级、后台可继续播，本页只当宿主），否则现场合成。
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

  /// 成品音频的句序驱动（会话持有，本页只 attach / detach）。
  MangaAudioPlaybackDriver? audio;

  /// 本页向有声书会话登记的阅读器视图：只为让会话知道「阅读器在场」，后台那只学习
  /// 时钟让位给本页的时钟（同一段时间不记两遍）。漫画没有章节跨越 / 文字领读。
  final _MangaAudioReaderView _audioView = _MangaAudioReaderView();

  /// 正在高亮的句子（页, 块下标）（文字层重建后由 [_replaceSpreadOcr] 重新挂上）。
  (int, List<int>)? _speaking;
  bool _starting = false;

  /// 本页已进入退出流程（返回路径 / 拆栈，见 [stopAudioUnlessBackground]）。此后
  /// 不再起新的成品会话，起到一半的那份也不接管（HBK-AUDIT-215）。返回路径先于
  /// `dispose` 走，这段时间 `mounted` 还是 true，所以不能只看 `mounted`。
  bool _leaving = false;

  /// 起成品音频这件事还归不归本页：页面还在、也没开始退出。
  bool get _wantsAudioStart => _s.mounted && !_leaving;

  bool get active => (controller?.isActive ?? false) || audio != null;

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
      _s._focusVolumeOcrOn(pageIndex);
    }
    _settleOrphanWaiters();
    return waiter.future;
  }

  @override
  Future<void> show(int pageIndex, List<int> blocks) async {
    _speaking = blocks.isEmpty ? null : (pageIndex, blocks);
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
    _recheckAudioAgainstOcr();
    final Completer<MangaPageTextResult>? waiter = _waiters.remove(pageIndex);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(MangaPageTextReady(page));
    }
  }

  /// 整卷完成：所有等待者按落盘结果落定。
  void _volumeSettled(MokuroPayload payload) {
    _recheckAudioAgainstOcr();
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
    // 成品音频的会话不跟章走（后台照常播），只是本页不再当它的宿主；正文装好后由
    // [attachActiveAudio] 接回。
    _detachAudio();
    _speaking = null;
    _ocrSettledPages.clear();
    _failWaiters(MangaPageTextUnavailableReason.cancelled);
  }

  // ── 高亮 JS ──────────────────────────────────────────────────────────

  String _speakingJs() {
    final (int, List<int>)? speaking = _speaking;
    return 'window.__mangaSetSpeaking && window.__mangaSetSpeaking('
        '${speaking?.$1 ?? -1}, ${jsonEncode(speaking?.$2 ?? const <int>[])});';
  }

  /// 文字层重建（窗口重载 / 懒挂 OCR 框）之后重新挂高亮；没在朗读时为空。
  String get reapplyJs => _speaking == null ? '' : _speakingJs();

  // ── 入口与生命周期 ────────────────────────────────────────────────────

  TtsServices get _tts => TtsServices.of(_s.appModel.prefsRepo);

  /// 这部漫画朗读的作品身份（书键 + 系列 + 语言），声音按它记（[TtsMediaVoices]）。
  Future<TtsMediaVoiceScope> _voiceScope() async {
    final String bookKey = _s.widget.bookKey;
    return resolveTtsMediaVoiceScope(
      _s.appModel,
      bookKey,
      language: await ttsMediaContentLanguage(
        _s.appModel.database,
        bookKey,
        globalDefault: _s.appModel.prefsRepo.defaultContentLanguage,
      ),
    );
  }

  /// 工具栏「朗读」：没在读就从当前页开始，在读就停。登记过成品音频的卷播成品，
  /// 否则现场合成。
  Future<void> toggle() async {
    if (audio != null) {
      stopAudio();
      return;
    }
    if (active) {
      stop();
      return;
    }
    if (await _startAudioIfRegistered()) return;
    await start();
  }

  // ── 成品音频 ────────────────────────────────────────────────────────

  /// 不走 `appModel`（它在页面挂着时是 `ref.watch`）：[dispose] / 退出路径也要取会话。
  AudiobookSession get _session => _s.appModelNoUpdate.audiobookSession;

  /// 会话里正在播的、属于本卷的成品音频驱动。
  MangaAudioPlaybackDriver? _activeDriver() {
    final AudiobookSessionCompanion? companion = _session.companion;
    return companion is MangaAudioPlaybackDriver &&
            !companion.isDisposed &&
            companion.bookKey == _s.widget.bookKey
        ? companion
        : null;
  }

  /// 成品音频只配本地卷：在线直读章的页与登记的清单不是一回事。
  bool get _audioEligible => !_s._streamingChapter && _s._payload != null;

  /// 成品与本页眼前这份 OCR 对不对得上：页数不符 / OCR 签名不符（OCR 重跑过，块
  /// 下标变了）都对不上。判据与导入同一个（[mangaManifestVolumeMismatch]），签名取
  /// 本页正在显示的 payload——高亮用的就是它的块下标。
  MangaAudioImportResult? _audioMismatch(MangaRenderManifest manifest) {
    final MokuroPayload? payload = _s._payload;
    if (payload == null) return MangaAudioImportResult.pageMismatch;
    return mangaManifestVolumeMismatch(manifest, payload);
  }

  void _toastAudioMismatch(MangaAudioImportResult mismatch) {
    FushiToast.show(
      msg: mismatch == MangaAudioImportResult.ocrMismatch
          ? t.manga_audio_playback_ocr_stale
          : t.manga_audio_import_page_mismatch,
      severity: ToastSeverity.warning,
    );
  }

  /// 对不上的成品不在阅读器里播：不按错位的块下标高亮，也不在读者眼前静默播一份
  /// 和画面对不上的音频——停掉会话并提示需重新标注 / 生成（与导入时拒收一致）。
  void _rejectStaleAudio(MangaAudioImportResult mismatch) {
    _detachAudio();
    unawaited(_session.stop());
    if (!_s.mounted) return;
    unawaited(clearHighlight());
    _toastAudioMismatch(mismatch);
    _rebuild();
  }

  /// 正文装好后：本卷的成品音频正在会话里播（退出阅读器后台听、再回来）就接回；
  /// 这期间 OCR 重跑过（与成品对不上）则停掉它而不是接回错位的高亮。
  void attachActiveAudio() {
    if (!_audioEligible) return;
    final MangaAudioPlaybackDriver? driver = _activeDriver();
    if (driver == null) return;
    final MangaAudioImportResult? mismatch = _audioMismatch(driver.manifest);
    if (mismatch != null) {
      _rejectStaleAudio(mismatch);
      return;
    }
    _attachAudio(driver);
  }

  /// 播放中本页的 OCR 变了（热替换 / 整卷重跑逐页落定 / 整卷完成）：成品与新 OCR
  /// 对不上就停，不带着错位的块下标继续高亮。没在播成品时什么都不做。
  void _recheckAudioAgainstOcr() {
    final MangaAudioPlaybackDriver? driver = audio;
    if (driver == null || driver.isDisposed) return;
    final MangaAudioImportResult? mismatch = _audioMismatch(driver.manifest);
    if (mismatch != null) _rejectStaleAudio(mismatch);
  }

  /// 本卷登记过成品音频就播它并返回 true（含页数 / OCR 签名对不上时提示后不再落到
  /// 现场合成）；没登记返回 false。
  Future<bool> _startAudioIfRegistered() async {
    if (!_audioEligible || _starting) return false;
    final FushiDatabase db = _s.appModel.database;
    final MangaAudioRegistration? registration = await loadMangaAudio(
      db,
      _s.widget.bookKey,
    );
    if (registration == null || !_wantsAudioStart) return false;
    final MangaAudioImportResult? mismatch = _audioMismatch(
      registration.manifest,
    );
    if (mismatch != null) {
      // 会话里可能还在播这份旧成品（后台起的）：一并停掉。
      if (_activeDriver() != null) {
        _rejectStaleAudio(mismatch);
      } else {
        _toastAudioMismatch(mismatch);
      }
      return true;
    }
    _starting = true;
    try {
      MangaAudioPlaybackDriver? driver = _activeDriver();
      if (driver == null) {
        await _s.appModel.initialiseAudioHandler();
        final AudiobookSessionStartRequest req =
            await resolveMangaAudioSessionRequest(
              db,
              registration: registration,
              overrideTitleOf:
                  ReaderFushiSource.instance.overrideTitleForBookKey,
            );
        // 会话归属绑在本页去留上：起到一半本页退出了，就不起 / 停掉这次装上的那份，
        // 不留没人接管的暂停会话（HBK-AUDIT-215）。
        final AudiobookSessionCompanion? created =
            await startMangaAudioSessionOwned(
              _session,
              req,
              wanted: () => _wantsAudioStart,
            );
        if (!_wantsAudioStart) return true;
        driver = _activeDriver();
        if (driver == null) return true;
        // 续播点不在读者眼前这一屏：从眼前这页的页段起点开始（与现场朗读「从当前页
        // 开始」一致）；就在这一屏则接着上次听到的地方。
        if (!isSameSpread(driver.currentPage, visiblePage)) {
          await driver.seekTo(driver.plan.pageStartMs(visiblePage));
        }
        // seek 期间本页退出：这次装上的会话还没被接管，同样不留。
        if (!_wantsAudioStart) {
          if (created != null && identical(_session.companion, created)) {
            unawaited(_session.stop());
          }
          return true;
        }
      }
      _attachAudio(driver);
      await driver.play();
    } catch (error, stack) {
      ErrorLogService.instance.log('MangaFushiPage.mangaAudio', error, stack);
      if (!_wantsAudioStart) return true;
      FushiToast.show(
        msg: t.manga_audio_start_failed,
        severity: ToastSeverity.error,
      );
    } finally {
      _starting = false;
    }
    return true;
  }

  void _attachAudio(MangaAudioPlaybackDriver driver) {
    if (identical(audio, driver)) return;
    _detachAudio();
    controller?.stop();
    audio = driver;
    driver.attachHost(
      this,
      visible: readerVisibleForLifecycleState(
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed,
      ),
    );
    _session.attachReader(_audioView);
    _session.addListener(_onSessionChanged);
    _rebuild();
  }

  void _detachAudio() {
    final MangaAudioPlaybackDriver? driver = audio;
    if (driver == null) return;
    audio = null;
    _lookupPause.drop();
    _session.removeListener(_onSessionChanged);
    _session.detachReader(_audioView);
    if (!driver.isDisposed) driver.detachHost(this);
    _speaking = null;
  }

  /// 会话停了 / 换了书（伴随对象随之释放）：本页不再有成品音频。
  void _onSessionChanged() {
    final MangaAudioPlaybackDriver? driver = audio;
    if (driver == null) return;
    if (!identical(_session.companion, driver) || driver.isDisposed) {
      _detachAudio();
      if (_s.mounted) {
        unawaited(clearHighlight());
        _rebuild();
      }
    }
  }

  // ── 导出片段视频（反馈 pZhONQTAap）────────────────────────────────────

  /// 正在导出（播放条上的按钮转圈、再点只提示进行中）。
  bool clipExporting = false;

  /// 把阅读器此刻框着的那句（[MangaAudioPlaybackDriver.displayedLineIndex]）导出成
  /// 片段视频：画面 = 那句所在的漫画页，音频 = 那句的成品音频（留白同制卡）。合成走
  /// 与小说有声书同一条管线（[synthMangaAudioClipVideo]），交付走
  /// [deliverAudiobookClipVideo]。任何一步失败都提示并记日志，绝不抛。
  Future<void> exportClip() async {
    if (clipExporting) {
      FushiToast.show(
        msg: t.audiobook_export_clip_in_progress,
        severity: ToastSeverity.info,
      );
      return;
    }
    final MangaAudioPlaybackDriver? driver = audio;
    final MangaReaderSession? session = _s._pageSession;
    if (driver == null || session == null) return;
    final int? lineIndex = driver.displayedLineIndex;
    if (lineIndex == null || driver.manifest.lines[lineIndex].placeholder) {
      FushiToast.show(
        msg: t.manga_audio_export_clip_no_line,
        severity: ToastSeverity.warning,
      );
      return;
    }
    final String lineId = driver.manifest.lines[lineIndex].lineId;
    final bool isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    final String bookKey = _s.widget.bookKey;
    clipExporting = true;
    _rebuild();
    Directory? workDir;
    bool keepWorkDir = false;
    try {
      FushiToast.show(
        msg: t.audiobook_export_clip_in_progress,
        severity: ToastSeverity.info,
      );
      final MangaMiningAudioClip? clip = resolveMangaLineAudioClip(
        registration: await loadMangaAudio(_s.appModel.database, bookKey),
        lineIndex: lineIndex,
        lineId: lineId,
        headPadMs: _s.appModel.miningAudioHeadPadMs,
        tailPadMs: _s.appModel.miningAudioTailPadMs,
      );
      if (clip == null || !await File(clip.inputPath).exists()) {
        ErrorLogService.instance.log(
          'MangaReadAloud.exportClip',
          'no rendered audio for line $lineId (index=$lineIndex, '
              'resolved=${clip != null})',
          StackTrace.current,
        );
        if (_s.mounted) {
          FushiToast.show(
            msg: t.audiobook_export_clip_failed,
            severity: ToastSeverity.error,
          );
        }
        return;
      }
      final Uint8List? pageBytes = await _s._loadMiningPageBytes(
        session,
        clip.line.page,
      );
      workDir = await Directory.systemTemp.createTemp('fushi_manga_clip_');
      final MangaAudioClipExportResult result = pageBytes == null
          ? const MangaAudioClipExportResult.failure(
              MangaAudioClipExportFailure.pageImage,
            )
          : await synthMangaAudioClipVideo(
              pageBytes: pageBytes,
              clip: clip,
              workDir: workDir,
            );
      final String? videoPath = result.videoPath;
      if (videoPath == null) {
        if (_s.mounted) {
          FushiToast.show(
            msg: t.audiobook_export_clip_failed,
            severity: ToastSeverity.error,
          );
        }
        return;
      }
      // 移动端系统分享异步读原文件：成品留在工作目录里，不删。
      keepWorkDir = !isDesktop;
      final AudiobookClipDeliveryOutcome delivered =
          await deliverAudiobookClipVideo(
            videoPath: videoPath,
            fileName: 'manga_clip_${DateTime.now().millisecondsSinceEpoch}.mp4',
            subject: clip.line.text,
            isDesktop: isDesktop,
          );
      if (_s.mounted) toastAudiobookClipDelivery(delivered);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaReadAloud.exportClip', error, stack);
      if (_s.mounted) {
        FushiToast.show(
          msg: t.audiobook_export_clip_failed,
          severity: ToastSeverity.error,
        );
      }
    } finally {
      clipExporting = false;
      final Directory? dir = workDir;
      if (dir != null && !keepWorkDir) unawaited(_s._deleteTempDir(dir));
      if (_s.mounted) _rebuild();
    }
  }

  // ── 查词暂停 ────────────────────────────────────────────────────────

  /// 查词按住播放的标记（BUG-4907 / 4908 / 4909，见 [MangaLookupPause]）。
  final MangaLookupPause _lookupPause = MangaLookupPause();

  /// 眼前在用的音源：成品音频优先（两者不会同时在），否则现场合成。
  MangaLookupPausable? get _lookupPlayback {
    final MangaAudioPlaybackDriver? driver = audio;
    if (driver != null) return _DriverLookupPausable(driver);
    final MangaReadAloudController? c = controller;
    return c == null ? null : _ControllerLookupPausable(c);
  }

  /// 主屏点 OCR 字要查词了：记下被查的句子（查后从句首重播用）。
  void noteLookupSentence(MangaLookupSentence? sentence) =>
      _lookupPause.noteSentence(sentence);

  /// [source] 的查词出现（每层弹窗 / 每个新查词都会来，幂等）。
  void lookupOpened(MangaLookupSource source) => _lookupPause.lookupOpened(
    source,
    _lookupPlayback,
    enabled: ReaderFushiSource.instance.pauseOnLookup,
  );

  /// [source] 的查词关闭（[resume]：用户关的）。另一来源还开着就继续按住。
  void lookupClosed(MangaLookupSource source, {required bool resume}) =>
      _lookupPause.lookupClosed(
        source,
        _lookupPlayback,
        resume: resume,
        restartSentence: ReaderFushiSource.instance.restartSentenceAfterLookup,
      );

  /// 停掉成品音频的会话（不是暂停：播放条的「停止」与工具栏再点一次）。
  void stopAudio() {
    _lookupPause.drop();
    _detachAudio();
    unawaited(_session.stop());
    unawaited(clearHighlight());
    _rebuild();
  }

  /// 快捷键（[ShortcutScope.manga] 的播放暂停 / 上一句 / 下一句，只开键盘）。
  void onShortcut(MangaReaderInputAction action) {
    final MangaAudioPlaybackDriver? driver = audio;
    final MangaReadAloudController? c = controller;
    switch (action) {
      case MangaReaderInputAction.readAloudPlayPause:
        if (driver != null) {
          unawaited(driver.togglePlayPause());
        } else if (c != null && c.isActive) {
          if (c.state == MangaReadAloudState.paused ||
              c.state == MangaReadAloudState.failed) {
            c.resume();
          } else {
            c.pause();
          }
        } else {
          unawaited(toggle());
        }
      case MangaReaderInputAction.readAloudPrevious:
        if (driver != null) {
          unawaited(driver.previous());
        } else {
          c?.previous();
        }
      case MangaReaderInputAction.readAloudNext:
        if (driver != null) {
          unawaited(driver.next());
        } else {
          c?.next();
        }
      default:
        break;
    }
  }

  // ── 从此句播放 ──────────────────────────────────────────────────────

  /// 「从此句播放」能不能接到 [sentence]（右键菜单 / 长按面板据此列不列这一项）：
  /// 成品音频在播时要这句在清单里（与制卡取句子音频同一判据
  /// [mangaMiningAudioLineIndex]）；现场合成朗读进行中时任何 OCR 句都能读。都没在
  /// 播时为 false——与小说有声书一样，没有音频会话就没有「跳到这句」。
  bool canPlayFromSentence(MangaLookupSentence sentence) {
    final MangaAudioPlaybackDriver? driver = audio;
    if (driver != null && !driver.isDisposed) {
      return _driverLineOf(driver, sentence) != null;
    }
    return controller?.isActive ?? false;
  }

  /// 从 [sentence] 句首接着播（小说有声书「从本句播放」/ 中键「跳到点击句」的漫画
  /// 版）。返回是否真的跳了：成品清单里没有这句时提示「这句没有对应的音频」，不静默
  /// 无反应；没有任何音源在播时返回 false。
  bool playFromSentence(MangaLookupSentence sentence) {
    final MangaAudioPlaybackDriver? driver = audio;
    if (driver != null && !driver.isDisposed) {
      final int? line = _driverLineOf(driver, sentence);
      if (line == null) {
        FushiToast.show(
          msg: t.audiobook_play_from_selection_no_cue,
          severity: ToastSeverity.error,
        );
        return false;
      }
      // 查词按住的标记作废：用户已经明确要从这句播。
      _lookupPause.drop();
      unawaited(driver.playFromLine(line));
      return true;
    }
    final MangaReadAloudController? c = controller;
    if (c == null || !c.isActive) return false;
    _lookupPause.drop();
    c.playFromSentence(sentence.pageIndex, sentence.blocks);
    return true;
  }

  int? _driverLineOf(
    MangaAudioPlaybackDriver driver,
    MangaLookupSentence sentence,
  ) => mangaMiningAudioLineIndex(
    driver.manifest,
    pageIndex: sentence.pageIndex,
    blocks: sentence.blocks,
  );

  Future<void> start() async {
    if (_starting || !_s.mounted || _s._payload == null) return;
    _starting = true;
    try {
      final _MangaReadAloudServicesRig rig;
      try {
        rig = await _MangaReadAloudServicesRig.create(
          _tts,
          await _voiceScope(),
        );
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
          pronunciation: _tts.textRules.load(TtsTextRuleKind.pronunciation),
          preSynthesis: _tts.textRules.load(TtsTextRuleKind.preSynthesis),
          playToEnd: (String path, double speed) =>
              DesktopAudioPlayback.playFileToEnd(path, speed: speed),
          stopPlayback: DesktopAudioPlayback.stop,
          readSpeed: () => _tts.store.speed,
          writeSpeed: _tts.store.setSpeed,
        );
        _watch = MangaReadAloudSessionWatch(
          c,
          onActiveChanged: _rebuild,
          onFinished: _onFinished,
        );
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

  /// 会话起止 → 重建（播放条 / 工具栏切换、按钮激活态），章末 → 提示。
  MangaReadAloudSessionWatch? _watch;

  void _onFinished(MangaReadAloudFinish? finish) {
    if (!_s.mounted) return;
    // 读到章末不自动进下一章：停下并提示。
    FushiToast.show(
      msg: finish == MangaReadAloudFinish.noText
          ? t.manga_read_aloud_no_text
          : t.manga_read_aloud_chapter_end,
    );
  }

  void stop() {
    _lookupPause.drop();
    controller?.stop();
  }

  void pause() => controller?.pause();

  /// 朗读不做后台播放：阅读器看不见（hidden / paused / detached）才暂停，回来从
  /// 当前句开头续。与有声书同一判据（[readerVisibleForLifecycleState]）：inactive
  /// 时画面仍在（下拉通知栏 / 控制中心 / 系统弹窗、桌面窗口失焦），不打断。
  ///
  /// 成品音频不暂停（它本来就能后台播），只切播放形态：看不见时转纯听（跳过页停留 /
  /// `lead`），回来恢复边看边听。
  void onAppLifecycleChanged(AppLifecycleState state) {
    controller?.onAppLifecycleChanged(state);
    audio?.setReaderVisible(readerVisibleForLifecycleState(state));
  }

  void onPageChanged(int page) {
    controller?.onPageChanged(page);
    audio?.onPageChanged(page);
  }

  /// 朗读中快速切换声音：选中的声音记到这部漫画（有系列记到「系列 + 语言」），
  /// 「使用默认声音」清掉它；用新声音从当前句重读。
  Future<void> switchVoice() async {
    final TtsServices tts = _tts;
    final TtsMediaVoiceScope scope = await _voiceScope();
    if (!_s.mounted) return;
    final TtsVoiceQuickSwitchChoice? choice = await showTtsVoiceQuickSwitch(
      _s.context,
      tts,
      scope: scope,
    );
    if (choice == null || !_s.mounted) return;
    if (choice.isManage) {
      controller?.pause();
      await openTtsVoiceSettingsPage(_s.context, tts);
      return;
    }
    await applyTtsVoiceQuickSwitchChoice(tts, choice, scope: scope);
    final MangaReadAloudController? c = controller;
    if (c == null) return;
    try {
      await c.replaceRig(await _MangaReadAloudServicesRig.create(tts, scope));
    } on _MangaReadAloudVoiceMissing catch (missing) {
      FushiToast.show(
        msg: missing.incomplete
            ? t.audiobook_tts_voice_incomplete
            : t.audiobook_tts_no_voice,
        severity: ToastSeverity.warning,
      );
    }
  }

  /// 退出阅读器时成品音频的去留，与小说 / PDF 阅读器同一开关同一判据（TODO-702）：
  /// 没开「退出后续播」（[AppModel.audiobookBackgroundPlay]，默认关）就停掉本页接管
  /// 的会话真正止声；开着则只解宿主（[dispose]），会话在后台接着播。
  ///
  /// 返回路径（[_MangaFushiPageState.onSourcePagePop]）先调一次，让书架迷你条从首帧
  /// 就见空会话；[dispose] 再调一次兜异常拆栈。fire-and-forget：stop 的同步首段已
  /// 清空会话，等 native 释放只会把返回挂住（BUG-1273）。
  ///
  /// 这也是本页「开始退出」的标记：此后起到一半的成品会话不再归本页（[_leaving]）。
  void stopAudioUnlessBackground(String logTag) {
    _leaving = true;
    final MangaAudioPlaybackDriver? driver = audio;
    if (driver == null || _s.appModelNoUpdate.audiobookBackgroundPlay) return;
    if (!identical(_session.companion, driver)) return;
    _detachAudio();
    unawaited(
      _session.stop().catchError((Object e, StackTrace stack) {
        ErrorLogService.instance.log(logTag, e, stack);
      }),
    );
  }

  void dispose() {
    stopAudioUnlessBackground('MangaFushiPage.disposeStopAudio');
    // 开着「退出后续播」：会话比本页活得久，只解宿主。
    _detachAudio();
    final MangaReadAloudController? c = controller;
    controller = null;
    _failWaiters(MangaPageTextUnavailableReason.cancelled);
    _watch?.dispose();
    _watch = null;
    if (c == null) return;
    c.dispose();
  }
}

/// 成品音频驱动的查词按住适配。从句首重播时被查那句按页 + 块在清单里找
/// （与制卡取句子音频同一判据 [mangaMiningAudioLineIndex]）。
class _DriverLookupPausable implements MangaLookupPausable {
  _DriverLookupPausable(this._d);

  final MangaAudioPlaybackDriver _d;

  @override
  bool get isRunning => !_d.isDisposed && _d.isPlaying;

  @override
  void pause() => unawaited(_d.pause());

  @override
  void resume({required bool restartSentence, MangaLookupSentence? sentence}) {
    if (_d.isDisposed || _d.isPlaying) return;
    if (!restartSentence) {
      unawaited(_d.play());
      return;
    }
    final int? line = sentence == null
        ? null
        : mangaMiningAudioLineIndex(
            _d.manifest,
            pageIndex: sentence.pageIndex,
            blocks: sentence.blocks,
          );
    unawaited(_d.playFromLine(line));
  }
}

/// 现场合成控制器的查词按住适配：等页文字 / 合成中也算在播。它的继续本来就从当前句
/// 开头重读，所以「从句首重播」只在有被查句时换成那一句。
class _ControllerLookupPausable implements MangaLookupPausable {
  _ControllerLookupPausable(this._c);

  final MangaReadAloudController _c;

  @override
  bool get isRunning =>
      _c.isActive &&
      switch (_c.state) {
        MangaReadAloudState.preparingText ||
        MangaReadAloudState.synthesizing ||
        MangaReadAloudState.playing => true,
        _ => false,
      };

  @override
  void pause() => _c.pause();

  @override
  void resume({required bool restartSentence, MangaLookupSentence? sentence}) {
    if (_c.state != MangaReadAloudState.paused) return;
    if (restartSentence && sentence != null) {
      _c.resumeFromSentence(sentence.pageIndex, sentence.blocks);
    } else {
      _c.resume();
    }
  }
}

/// 没有可用的朗读声音（[incomplete] = 有但参数不全）。
class _MangaReadAloudVoiceMissing implements Exception {
  const _MangaReadAloudVoiceMissing({required this.incomplete});
  final bool incomplete;
}

/// 生产声音：这部漫画该用的朗读声音（本书 → 系列 + 语言 → 全局使用中）+ 全应用
/// 共用的 [TtsAudioCache]（同句同音色只合一次，与小说朗读 / 制作台共用）。
class _MangaReadAloudServicesRig implements MangaReadAloudVoiceRig {
  _MangaReadAloudServicesRig._({
    required TtsProvider provider,
    required TtsAudioCache cache,
    required Map<String, Object?> audioIdentity,
    required this.maxInputLength,
  }) : _provider = provider,
       _cache = cache,
       _audioIdentity = audioIdentity;

  static Future<_MangaReadAloudServicesRig> create(
    TtsServices tts,
    TtsMediaVoiceScope scope,
  ) async {
    // 从没配过声音时与「朗读声音」页同一份开箱默认（微软 Edge）。
    await tts.seedBuiltinVoiceIfUnset();
    final TtsMediaVoice? voice = tts.voiceForMedia(scope);
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

/// 本页登记给有声书会话的阅读器视图（见 [_MangaReadAloudSupport._audioView]）。漫画
/// 有声的页跟随由 [MangaAudioPlaybackDriver] 自己做，这里的回调都不需要动作；
/// [getCurrentReaderSection] 返回 -1 让控制器的跨章守卫不动作。
class _MangaAudioReaderView implements ReaderAudiobookView {
  @override
  int getCurrentReaderSection() => -1;

  @override
  Future<void> onCueCrossChapter(int sectionIndex) async {}

  @override
  Future<void> onBoundarySkip(int delta) async {}

  @override
  void onExplicitCueJump(AudioCue cue) {}

  @override
  void onBeforeAudioJump(int fromGlobalMs, JumpSource source) {}

  @override
  void onReaderCueChanged() {}
}
