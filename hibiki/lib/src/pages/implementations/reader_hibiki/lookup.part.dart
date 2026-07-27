// GENERATED-NOTE: extracted from reader_hibiki_page.dart (TODO-589 batch3).
part of '../reader_hibiki_page.dart';

/// lookup (查词 / text-selection → dictionary) domain helpers extracted via
/// part-of (TODO-589 batch3); shared private scope. Behaviour-preserving:
/// bodies are byte-for-byte verbatim except the two `setState(` calls in
/// `_checkFavoriteStatus` forwarded through the main shell `_rebuild(` helper
/// (extensions cannot call the @protected State.setState directly); no class
/// static is referenced, so no static qualification was needed.
///
/// Two members stay in the main shell, lifted out of this method group:
/// the `@override onAllPopupsDismissed` (Dart extensions cannot satisfy a
/// superclass virtual contract) and `_runLookupAndHighlight` (it calls the
/// `@protected` `BaseSourcePageState.prunePopupStack`, which the analyzer
/// rejects from an extension body — `invalid_use_of_protected_member`). Both
/// remain reachable from here via the shared private class scope.
extension _ReaderLookup on _ReaderHibikiPageState {
  // ── Text Selection → Dictionary ───────────────────────────────────

  /// [fromHover]（默认 false）透传给 [ReaderSelectionScripts.selectInvocation]：
  /// true 表示悬停查词路径（onShiftHover / onDismissBarrierHover），命中空白不再
  /// fire `onTapEmpty`（TODO-851，消操作栏闪烁）；false 是真点击路径，行为不变。
  Future<void> _selectTextAt(
    double cssX,
    double cssY, {
    bool fromHover = false,
  }) async {
    if (_controller == null) return;
    const int maxLength = 400;
    try {
      await _controller!.evaluateJavascript(
        source: ReaderSelectionScripts.selectInvocation(
          cssX,
          cssY,
          maxLength,
          fromHover: fromHover,
        ),
      );
    } catch (e, stack) {
      // TODO-678（BUG-005 同根因）：onTap / onShiftHover / onDismissBarrierHover
      // 都 fire-and-forget 调本方法（不 await、不 catch），半销毁 WebView 上
      // evaluateJavascript 抛 MissingPluginException 会无主逃当前 zone。`_controller
      // != null` 防不了通道已废，必须就地兜底；选词失败 no-op，不影响后续手势。
      ErrorLogService.instance.log('ReaderHibiki.selectTextAt.eval', e, stack);
    }
  }

  /// BUG-712 ①：把点词门控（chrome 可见性 / highlightOnTap）只读镜像同步进阅读器
  /// JS 的 `window.__hoshiTapGate`。Dart 是唯一写者：初始值随 setup 脚本注入，
  /// 之后 chrome 翻转（[_toggleChrome]）与设置热更新
  /// （onSettingsChangedLive）各刷一次。JS 侧据此在 tap 命中时直接 selectText
  /// （砍掉 onTap→Dart→eval 来回）；镜像缺失时 JS 回落旧 onTap 链，行为安全。
  /// fire-and-forget：半销毁 WebView 的 eval 异常就地吞掉（同 [_selectTextAt] 成例）。
  void _syncTapGateJs() {
    final InAppWebViewController? controller = _controller;
    if (controller == null) return;
    final bool lookup = ReaderHibikiSource.instance.highlightOnTap;
    try {
      controller
          .evaluateJavascript(
              source: 'window.__hoshiTapGate = '
                  '{ chrome: $_showChrome, lookup: $lookup, maxLen: 400 };')
          .catchError((Object e, StackTrace s) {
        ErrorLogService.instance.log('ReaderHibiki.syncTapGate', e, s);
        return null;
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki.syncTapGate', e, stack);
    }
  }

  void _clearLookupState() {
    if (_pausedForLookup) {
      _pausedForLookup = false;
      _audiobookController?.play();
    }
    // TODO-678（BUG-005 同根因）：本方法被 onAllPopupsDismissed fire-and-forget
    // 调用（不 await），半销毁 WebView 上 evaluateJavascript 抛 MissingPluginException
    // 会逃当前 zone。把 eval 收进 _clearSelectionJs() 的 try/catch，对齐
    // onSettingsChangedLive / onLayoutReloadLive 成例（清选区失败 no-op）。
    unawaited(_clearSelectionJs());
  }

  /// 清除 WebView 内的选区高亮（[ReaderSelectionScripts.clearInvocation]）。
  /// 半销毁 WebView 上 evaluateJavascript 抛 MissingPluginException，就地吞掉并
  /// 记日志：调用方 [_clearLookupState] 是 fire-and-forget，异常否则会逃 zone。
  Future<void> _clearSelectionJs() async {
    try {
      await _controller?.evaluateJavascript(
        source: ReaderSelectionScripts.clearInvocation(),
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibiki.clearLookupState.eval', e, stack);
    }
  }

  Future<void> _highlightAndShowPopup(
    int highlightCount,
    Rect fallbackRect,
  ) async {
    // BUG-717 ②：把「显示弹窗」与「正文高亮 eval」解耦。旧实现先 `await` 高亮 eval（打在
    // 正在渲染 EPUB 的大 reader WebView 上，其忙于分页/滚动/渲染时每次 JS 往返 stall 到
    // 数十 ms），`finally` 才 `showDeferredPopup` —— 弹窗显示 + 弹窗 WebView 内容注入被
    // 死死串在繁忙大 WebView 之后，是 app 内查词比 app 外覆盖窗慢数倍的主乘数。
    //
    // 现改为：先用原始选区 rect **立即显示**（弹窗 WebView 注入与下面的高亮 eval 分属两个
    // WebView、并行不争用），高亮 eval 异步回来拿到精修后的词 bbox 再经 [reanchorTopPopup]
    // 重锚（多字去屈折时高亮比选区宽，重锚保证弹窗不覆盖被查词 BUG-767；代次守卫防迟到
    // 回调错位到新查词弹窗）。高亮副作用（正文里高亮被查词）随之从「弹窗前」变「弹窗后
    // ~一跳」，与 app 外一致（app 外根本不在正文高亮）。
    final int generation = activeLookupGeneration;
    showDeferredPopup(selectionRect: fallbackRect);
    if (highlightCount <= 0 || _controller == null) return;
    try {
      final raw = await _controller!.evaluateJavascript(
        source: ReaderSelectionScripts.highlightInvocation(highlightCount),
      );
      if (!mounted) return;
      final rect = ReaderSelectionScripts.highlightRectFromResult(
        raw,
        topOffset: 0,
      );
      if (rect != null) reanchorTopPopup(rect, generation);
    } catch (e, stack) {
      // BUG-005 同根因（TODO-678）：WebView 半销毁（页面 teardown / 设置 reload 重建
      // 瞬态）时其 per-instance method channel 的 setMethodCallHandler(null) 已摘除，
      // evaluateJavascript 抛 MissingPluginException。`_controller != null` 守卫只防
      // null，防不了通道已废 —— 必须 try/catch 兜底。弹窗已显示，重锚失败仅停在选区
      // rect（查词弹窗不中断）。
      ErrorLogService.instance
          .log('ReaderHibiki.highlightAndShowPopup.eval', e, stack);
    }
  }

  Future<void> _handleTextSelected(ReaderSelectionData data) async {
    if (data.text.isEmpty) {
      return;
    }
    // TODO-393 / BUG-缓存串味：每次新查词（换词 / 换句）都从「只制当前句」起步，丢弃
    // 上一个词的「上 N 句 / 下 N 句」上下文选择。热槽 WebView 复用使弹窗 DOM 不重载，
    // 草稿若不在此清空，上一个词攒的上下文会带到下一个词的卡（用户报「弹窗会缓存」）。
    _miningDraft.clear();

    final bool shouldPause = ReaderHibikiSource.instance.pauseOnLookup;
    final AudiobookPlayerController? abc = _audiobookController;
    if (shouldPause && abc != null && abc.isPlaying) {
      abc.pause();
      _pausedForLookup = true;
    }

    final Map<String, double>? rect = data.rect;
    final Rect selectionRect = rect != null
        ? Rect.fromLTWH(
            rect['x'] ?? 0,
            rect['y'] ?? 0,
            rect['width'] ?? 0,
            rect['height'] ?? 0,
          )
        : Rect.fromCenter(
            center: Offset(
              MediaQuery.of(context).size.width / 2,
              MediaQuery.of(context).size.height / 2,
            ),
            width: 1,
            height: 1,
          );

    // TODO-956：契约——选中可见词 ⇒ currentSentence 必非空。data.sentence 在歌词 /
    // 合成有声书 / 竖排空段 DOM 等模式可能回空（即便 JS 已有块级 textContent 兜底），
    // 而 data.text 由本方法开头 `if (data.text.isEmpty) return;` 守卫保证非空。空 sentence
    // 时退回选中的词，杜绝收藏读点（chrome.part.dart）误报「未选择句子」。
    final String sentenceText =
        ReaderSelectionScripts.resolveCurrentSentenceText(
      data.sentence,
      data.text,
    );
    appModel.currentMediaSource?.setCurrentSentence(
      selection: HibikiTextSelection(text: sentenceText),
    );
    _cachedSentenceOffset = data.sentenceOffset;

    if (_lyricsMode) {
      _lookupCue = null;
      try {
        // TODO-678（BUG-005 同根因）：把歌词 cue context 的 evaluateJavascript 纳入
        // try —— 半销毁 WebView 上它抛 MissingPluginException，此前 eval 在 try 之外
        // 会让整个歌词查词分支（含 _runLookupAndHighlight）被打断、弹窗不显示。纳入后
        // 失败则 _lookupCue 退回 currentCue fallback，查词照常继续。
        final Object? ctxRaw = await _controller?.evaluateJavascript(
          source: 'JSON.stringify(window.__lyricsCueContext || null)',
        );
        if (ctxRaw is String && ctxRaw != 'null') {
          final Map<String, dynamic> ctx =
              jsonDecode(ctxRaw) as Map<String, dynamic>;
          final String? fragId = ctx['textFragmentId'] as String?;
          final int? cueIdx = (ctx['cueIndex'] as num?)?.toInt();
          if (fragId != null && fragId.isNotEmpty) {
            final SasayakiFragment? frag = SasayakiMatchCodec.tryDecode(fragId);
            if (frag != null) {
              _cachedSelectionRange = (
                offset: frag.normCharStart,
                length: frag.normCharEnd - frag.normCharStart,
                text: data.text,
              );
              _cachedSentenceRange = (
                offset: frag.normCharStart,
                length: frag.normCharEnd - frag.normCharStart,
              );
              // BUG-492：歌词 cue 选区所属章号取自 fragment（与 _lookupSectionIndex 同源）。
              _cachedSelectionSectionIndex = frag.sectionIndex;
            }
          }
          if (cueIdx != null && cueIdx >= 0 && cueIdx < _lyricsCueList.length) {
            _lookupCue = _lyricsCueList[cueIdx];
          }
        }
      } catch (e, stack) {
        ErrorLogService.instance.log('ReaderHibiki.lyricsCueContext', e, stack);
      }
      _lookupCue ??= _audiobookController?.currentCue;
      _syncCueSentence();
      await _runLookupAndHighlight(data.text, selectionRect);
      _checkFavoriteStatus();
      return;
    }

    _lookupCue = data.normalizedOffset != null
        ? _findCueForOffset(data.normalizedOffset!)
        : null;
    if (_lookupCue == null && _srtBookUid != null) {
      _lookupCue = _findCueForSentence(data.sentence);
    }
    _syncCueSentence();

    await _runLookupAndHighlight(data.text, selectionRect);
    if (data.normalizedOffset != null && data.normalizedLength != null) {
      _cachedSelectionRange = (
        offset: data.normalizedOffset!,
        length: data.normalizedLength!,
        text: data.text,
      );
    } else {
      _cachedSelectionRange = null;
    }
    if (data.sentenceNormalizedOffset != null &&
        data.sentenceNormalizedLength != null) {
      _cachedSentenceRange = (
        offset: data.sentenceNormalizedOffset!,
        length: data.sentenceNormalizedLength!,
      );
    } else {
      _cachedSentenceRange = null;
    }
    // BUG-492：选区时刻锁定所属章号，供收藏 / 制卡写入用（详见 _cachedSelectionSectionIndex）。
    _cachedSelectionSectionIndex = _lookupSectionIndex;
    _checkFavoriteStatus();
  }

  Future<void> _checkFavoriteStatus() async {
    final String sentence =
        appModel.currentMediaSource?.currentSentence.text ?? '';
    if (sentence.isEmpty) {
      _currentFavoriteId = null;
      if (_currentSentenceIsFavorited) {
        _rebuild(() => _currentSentenceIsFavorited = false);
      }
      return;
    }
    final sentenceRange = _cachedSentenceRange ??
        (_cachedSelectionRange != null
            ? (
                offset: _cachedSelectionRange!.offset,
                length: _cachedSelectionRange!.length
              )
            : null);
    // BUG-494：拿匹配条目的精确 id（未收藏 → null），供 toggle 用 removeById 精确删单条。
    final String? matchedId =
        await FavoriteSentenceRepository(appModel.database).matchedFavoriteId(
      text: sentence,
      bookKey: widget.bookKey,
      sectionIndex: _favoriteSectionIndex,
      normCharOffset: sentenceRange?.offset,
    );
    _currentFavoriteId = matchedId;
    final bool favorited = matchedId != null;
    if (mounted && favorited != _currentSentenceIsFavorited) {
      _rebuild(() => _currentSentenceIsFavorited = favorited);
    }
  }
}
