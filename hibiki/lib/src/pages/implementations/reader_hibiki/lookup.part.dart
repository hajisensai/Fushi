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

  Future<void> _selectTextAt(double cssX, double cssY) async {
    if (_controller == null) return;
    const int maxLength = 400;
    await _controller!.evaluateJavascript(
      source: ReaderSelectionScripts.selectInvocation(cssX, cssY, maxLength),
    );
  }

  /// Reclaim Flutter keyboard focus for the reading content after a reader
  /// WebView pointer gesture (swipe / wheel page-turn, boundary chapter turn,
  /// tap-to-toggle-chrome). The native WebView grabs the OS focus when the user
  /// touches it, dropping [_focusNode] so ESC / shortcuts no longer reach
  /// [_handleKeyEvent] (BUG-136). Mirrors the popup-dismiss reclaim in
  /// [onAllPopupsDismissed]; the predicate skips it when a popup or the chrome
  /// bar legitimately owns focus, and it is a harmless no-op for keyboard /
  /// gamepad turns (those never route through the JS gesture handlers).
  void _reclaimReaderFocusAfterGesture() {
    if (!mounted) return;
    if (!shouldReclaimReaderFocusAfterGesture(
      popupVisible: isDictionaryShown,
      chromeHasFocus: _chromeFocusScope.hasFocus,
    )) {
      return;
    }
    _focusNode.requestFocus();
  }

  void _clearLookupState() {
    if (_pausedForLookup) {
      _pausedForLookup = false;
      _audiobookController?.play();
    }
    _controller?.evaluateJavascript(
      source: ReaderSelectionScripts.clearInvocation(),
    );
  }

  Future<void> _highlightAndShowPopup(
    int highlightCount,
    Rect fallbackRect,
  ) async {
    Rect finalRect = fallbackRect;
    try {
      if (highlightCount > 0 && _controller != null) {
        final raw = await _controller!.evaluateJavascript(
          source: ReaderSelectionScripts.highlightInvocation(highlightCount),
        );
        if (mounted) {
          final rect = ReaderSelectionScripts.highlightRectFromResult(
            raw,
            topOffset: 0,
          );
          if (rect != null) finalRect = rect;
        }
      }
    } finally {
      showDeferredPopup(selectionRect: finalRect);
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

    appModel.currentMediaSource?.setCurrentSentence(
      selection: HibikiTextSelection(text: data.sentence),
    );
    _cachedSentenceOffset = data.sentenceOffset;

    if (_lyricsMode) {
      _lookupCue = null;
      final Object? ctxRaw = await _controller?.evaluateJavascript(
        source: 'JSON.stringify(window.__lyricsCueContext || null)',
      );
      if (ctxRaw is String && ctxRaw != 'null') {
        try {
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
            }
          }
          if (cueIdx != null && cueIdx >= 0 && cueIdx < _lyricsCueList.length) {
            _lookupCue = _lyricsCueList[cueIdx];
          }
        } catch (e, stack) {
          ErrorLogService.instance
              .log('ReaderHibiki.lyricsCueContext', e, stack);
        }
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
    _checkFavoriteStatus();
  }

  Future<void> _checkFavoriteStatus() async {
    final String sentence =
        appModel.currentMediaSource?.currentSentence.text ?? '';
    if (sentence.isEmpty) {
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
    final bool favorited =
        await FavoriteSentenceRepository(appModel.database).isFavorited(
      text: sentence,
      bookKey: widget.bookKey,
      sectionIndex: _lookupSectionIndex,
      normCharOffset: sentenceRange?.offset,
    );
    if (mounted && favorited != _currentSentenceIsFavorited) {
      _rebuild(() => _currentSentenceIsFavorited = favorited);
    }
  }
}
