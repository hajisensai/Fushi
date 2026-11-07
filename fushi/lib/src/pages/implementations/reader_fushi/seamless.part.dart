part of '../reader_fushi_page.dart';

/// 连续模式章节无缝衔接的 Dart 侧（反馈 R7k887yaJI ③，设计见
/// `docs/specs/2026-11-07-continuous-seamless-chapters-design.md`）。
///
/// JS 模块（`reader_seamless_chapters_script.dart`）在同一文档里挂前后章；用户滚过章界
/// 时它把邻章「晋升」为活动章（DOM 搬家 + 引擎重建索引，一个任务内同步完成），再回调
/// `onSeamlessChapterActivated(to, from, seq)`。这里把阅读器状态换到新章：章号、导航
/// 代际、阅读账本、有声书、按章下发的 cue / 高亮，最后 `ack` 解除 JS 的进度闸。
extension _ReaderSeamlessChapters on _ReaderFushiPageState {
  /// 本次文档的无缝衔接配置（[ReaderEngineConfig] 的三个字段）。开关关、非连续模式、
  /// 双页图片文档时恒为「关」，JS 模块整段不装。
  ({bool active, int index, List<ReaderSeamlessChapterEntry> order})
  _seamlessEngineConfig({required bool continuousMode}) {
    final ReaderSettings s = _settings!;
    final EpubBook? book = _book;
    final bool active =
        book != null &&
        readerSeamlessChaptersActive(
          continuousMode: continuousMode,
          settingEnabled: s.continuousSeamlessChapters,
          spreadDocument: _spreadDocumentLoaded,
        );
    if (!active) {
      return (
        active: false,
        index: -1,
        order: const <ReaderSeamlessChapterEntry>[],
      );
    }
    final EpubSpreadMap? map = _spreadMap;
    return (
      active: true,
      index: _currentChapter,
      order: readerSeamlessChapterOrder(
        chapterCount: book.chapters.length,
        urlOf: _chapterUrl,
        isAbsorbed: map?.isAbsorbedImageChapter,
      ),
    );
  }

  /// `onSeamlessChapterActivated` 的入口。args = [to, from, seq]。
  void _handleSeamlessChapterActivated(List<dynamic> args) {
    final int? to = args.isNotEmpty ? (args[0] as num?)?.toInt() : null;
    final int? from = args.length > 1 ? (args[1] as num?)?.toInt() : null;
    final int? seq = args.length > 2 ? (args[2] as num?)?.toInt() : null;
    if (to == null || from == null || seq == null) {
      ErrorLogService.instance.log(
        'ReaderFushi.seamlessActivated',
        StateError('invalid args: $args'),
        StackTrace.current,
      );
      return;
    }
    unawaited(_onSeamlessChapterActivated(to: to, from: from, seq: seq));
  }

  Future<void> _onSeamlessChapterActivated({
    required int to,
    required int from,
    required int seq,
  }) async {
    final EpubBook? book = _book;
    final InAppWebViewController? controller = _controller;
    if (!mounted || book == null || controller == null) return;
    final bool valid =
        to >= 0 &&
        to < book.chapters.length &&
        from == _currentChapter &&
        _settings?.isContinuousMode == true &&
        _settings?.continuousSeamlessChapters == true &&
        !_restoreInFlight &&
        _readerContentReady;
    if (!valid) {
      // 两边对不上（JS 换章时 Dart 正在导航 / 刚切了模式或开关）：不在不一致的状态上
      // 继续，整章重载到 JS 认为的活动章，由现有恢复链收敛。
      debugPrint(
        '[ReaderFushi] seamless activation rejected: to=$to from=$from '
        'current=$_currentChapter restoreInFlight=$_restoreInFlight '
        'ready=$_readerContentReady',
      );
      if (to >= 0 && to < book.chapters.length && !_restoreInFlight) {
        await _navigateToChapter(to, manual: true);
      }
      return;
    }

    // ── 同步部分：第一个 await 之前完成换章，之后到达的任何 JS 回调都看到新章号 ──
    studyDiag('reader', 'seamless → chapter=$to (leave current unit)');
    _progressPollTimer?.cancel();
    unawaited(_flushReadingStats());
    // 与 [_beginNavigation] 同一个采样点：离开那章的当前单元在离开这一刻结算。
    _readLedger.leave();
    _audiobookController?.noteManualReaderNavigation();
    final int generation = _advanceNavigationGeneration();
    _chapterAdvanceDirection = to > from ? 1 : -1;
    if (_jumpTargetSpan?.chapter != to) _jumpTargetSpan = null;
    _preciseLocateQueue.clear();
    _pageTurnQueue.clear();
    _currentChapter = to;
    _initialProgress = 0.0;
    _initialCharOffset = -1;
    _initialCharOffsetEnd = -1;
    _initialFragment = null;
    _lastProgressSection = to;
    _lastProgressValue = 0.0;
    _lastProgressCharOffset = -1;
    _rebuild(() {});

    bool stale() =>
        !mounted ||
        _navigateGeneration != generation ||
        !identical(controller, _controller);

    try {
      await controller.evaluateJavascript(
        source:
            'window.__fushiSeamless ? window.__fushiSeamless.ack($seq, $generation) : false',
      );
      if (stale()) return;

      // ── 按章重新下发章内数据（与 [_onChapterLoadComplete] 的章内部分同一套）──
      if (_audiobookController != null) {
        final String? cuesJson = await _prepareSentenceAudioCuesJson();
        if (stale()) return;
        if (cuesJson != null) {
          await controller.evaluateJavascript(
            source:
                'window.fushiReader && window.fushiReader.applySentenceAudioCues($cuesJson)',
          );
          if (stale()) return;
        }
        await _injectAudiobookBridge();
        if (stale()) return;
      }
      await _applyChapterHighlights();
      if (stale()) return;
      await _applyJumpTargetMark();
      if (stale()) return;
      await AudiobookBridge.resetImagePauseAnchor(controller);
      if (stale()) return;
      if (_caretOnReader) {
        await _caretReanchor(
          to > from
              ? ReaderNavigationDirection.forward
              : ReaderNavigationDirection.backward,
        );
        if (stale()) return;
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderFushi.seamlessActivated', e, stack);
      return;
    }

    _audiobookController?.notifySectionRestoreCompleted(
      currentReaderSection: to,
      success: true,
    );
    _ensureStudyClock();
    unawaited(_refreshProgress());
    _startProgressPoll();
    _prefetchAdjacentChapter(to + _chapterAdvanceDirection);
    _prefetchAdjacentChapterImages(to + _chapterAdvanceDirection);
  }
}
