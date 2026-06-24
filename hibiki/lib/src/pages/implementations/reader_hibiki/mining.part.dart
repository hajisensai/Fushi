// GENERATED-NOTE: extracted from reader_hibiki_page.dart (TODO-589 batch2).
part of '../reader_hibiki_page.dart';

/// mining (制卡/Anki card creation) domain helpers extracted via part-of
/// (TODO-589 batch2); shared private scope. Behaviour-preserving: bodies are
/// byte-for-byte verbatim — these helpers reference neither `setState` nor any
/// class static, so (unlike some other batches) no `setState(`→`_rebuild(`
/// rewrite nor static qualification was needed.
///
/// The `@override` thin shells `onMineFromPopup` / `onUpdateFromPopup` stay in
/// the main shell (Dart extensions cannot satisfy a superclass virtual
/// contract); they delegate into `_onMineFromPopupInner` / `_onUpdateFromPopupInner`
/// here via the shared `_miningQueue`.
extension _ReaderMining on _ReaderHibikiPageState {
  /// TODO-270 D：reader 制卡/覆盖共用的「构造制卡上下文」。返回构造好的
  /// [AnkiMiningContext] 与一个 `cleanup` 闭包（清理句子音频临时目录，调用方在 mine/
  /// update 完成后必须调用）。当句子音频导出失败（已弹 toast）时返回 `context: null`，
  /// 调用方据此直接放弃本次制卡/覆盖。把这段重逻辑抽出来，使制卡与覆盖走完全一致的
  /// 封面/句子音频/句子偏移/分类标签链路（避免两份漂移）。
  Future<({AnkiMiningContext? context, void Function() cleanup})>
      _prepareMiningContext() async {
    final String currentSentence =
        appModel.currentMediaSource?.currentSentence.text ?? '';
    // TODO-270 F/G「查词窗口多句合一制卡」(乙方案)：把已累积的草稿句 + 当前句合成一段
    // 写入卡片 sentence 字段；草稿为空时等价于原来的单句（joinMinedSentences 单句
    // 直接 trim 返回）。音频区间同理合并（跨章/跨音频文件退化为只合文本）。
    final String sentence = _miningDraft.composeText(currentSentence);

    String? coverPath;
    if (_book?.coverHref != null && _extractDir != null) {
      final File coverFile = File(p.join(_extractDir!, _book!.coverHref));
      if (coverFile.existsSync()) coverPath = coverFile.path;
    }

    // TODO-644 / BUG-357：在第一个 await（句子音频裁剪，可让出事件循环数百 ms）之前，
    // 把所有「制卡上下文要用」的共享可变成员快照成局部 final。否则在 await 悬挂期间，
    // 第二次查词（`_handleTextSelected` 在其首个 await 前同步改写 currentCueSentence /
    // _cachedSentenceOffset）会把这些成员改成第二个词的值，导致第一张卡的 cue 句 / 加粗
    // 偏移与第二个词错配（或第二次中途清空时丢失）。await 之后一律只读这些局部值，消除
    // 「await 后读可变成员」整类时序漏洞。
    final String snapshotCueSentence =
        appModel.currentMediaSource?.currentCueSentence.text ?? '';
    final int? snapshotSentenceOffset = _cachedSentenceOffset;

    String? sasayakiAudioPath;
    Directory? sasayakiTempDir;
    bool requestedSentenceAudioClip = false;
    String? sentenceAudioFailure;
    void cleanupSasayakiTempDir() {
      if (sasayakiTempDir != null && sasayakiTempDir.existsSync()) {
        try {
          sasayakiTempDir.deleteSync(recursive: true);
        } catch (e, stack) {
          ErrorLogService.instance
              .log('ReaderHibiki.mineEntry.cleanupAudio', e, stack);
        }
      }
    }

    final AudioCue? cue = _lookupCue;
    final List<File>? audioFiles = _audiobookController?.audioFiles;
    // BUG-172 / TODO-104a: do not gate on `cue != null`. Audiobook cue alignment
    // leaves gaps (titles, captions, alignment misses, chapter edges); a word can
    // land in covered-but-uncued text so `_lookupCue` is null, yet the sentence
    // is still spanned by surrounding cues. As long as audio files exist, resolve
    // the range by the sentence span (cue-by-range) instead of silently dropping
    // sentence audio. `miningSentenceAudioRange` returns null when nothing can be
    // derived (no cue and no usable sentence span), so the gate stays honest.
    //
    // TODO-270 F/G：把当前句区间与草稿累积的句子区间合并成「首句起→末句止」。
    // 跨章/跨音频文件时 MiningSentenceDraft.composeAudioRange 返回 null →退化为只
    // 合文本（不静默拼坏音频），并诚实记日志。
    if (audioFiles != null) {
      final AudioPlaybackRange? currentRange = _currentSentenceAudioRange();
      final AudioPlaybackRange? clip =
          _miningDraft.composeAudioRange(currentRange);
      if (clip != null &&
          clip.audioFileIndex >= 0 &&
          clip.audioFileIndex < audioFiles.length) {
        final File inputFile = audioFiles[clip.audioFileIndex];
        sasayakiTempDir =
            Directory.systemTemp.createTempSync('hibiki_mine_sentence_audio_');
        final String outputPath = p.join(sasayakiTempDir.path, 'sentence.aac');
        requestedSentenceAudioClip = true;
        // TODO-757 压缩开关：仅桌面 ffmpeg 回退路径吃压缩档（默认单声道 64k=现状；
        // 关闭压缩走立体声 128k）。Android 句子音频走原生无损 re-mux，extractAudioSegment
        // 的 _isSupported 分支忽略这俩参数，开关对它天然无效。
        final MiningMediaCompression mediaCompression =
            MiningMediaCompression.forCompressionEnabled(
          appModel.compressMiningMedia,
        );
        sasayakiAudioPath = await TtsChannel.instance.extractAudioSegment(
          inputPath: inputFile.path,
          startMs: clip.startMs,
          endMs: clip.endMs,
          outputPath: outputPath,
          audioChannels: mediaCompression.audioChannels,
          audioBitrate: mediaCompression.audioBitrate,
          onFailure: (String summary) {
            sentenceAudioFailure = summary;
          },
        );
      } else if (cue == null) {
        // TODO-811 visibility: audio files exist but neither a lookup cue /
        // sentence span nor a mergeable draft range resolved to a cue range (or
        // the draft spans multiple audio files → text-only). The card is still
        // created (sentence audio is optional), but the user must SEE that no
        // sentence audio was attached instead of silently getting an audio-less
        // card. Previously this was a debugPrint-only silent drop — the exact
        // symptom users reported for local audiobooks ("card has no sentence
        // audio"). Surface a toast like the export-failure path, then continue.
        debugPrint(
          '[ReaderHibiki] mine: audio present but no sentence-audio range '
          '(lookupCue=null, sentenceRange=${_cachedSentenceRange != null}, '
          'draftSentences=${_miningDraft.length}).',
        );
        HibikiToast.show(msg: t.card_mined_without_sentence_audio);
      }
    }

    if (requestedSentenceAudioClip && sasayakiAudioPath == null) {
      cleanupSasayakiTempDir();
      ErrorLogService.instance.log(
        'ReaderHibiki.mineEntry.sentenceAudio',
        sentenceAudioFailure == null
            ? 'sentence audio export failed'
            : 'sentence audio export failed: $sentenceAudioFailure',
        StackTrace.current,
      );
      HibikiToast.show(
        msg: t.card_export_failed_detail(
          reason: sentenceAudioFailure == null
              ? 'sentence audio export failed'
              : 'sentence audio export failed: $sentenceAudioFailure',
        ),
      );
      return (context: null, cleanup: cleanupSasayakiTempDir);
    }

    // TODO-644 / BUG-357：用 await 前的快照值构造上下文（cue 句 / 加粗偏移），不再
    // 读 currentCueSentence / _cachedSentenceOffset 这两个会被并发查词改写的可变成员。
    final AnkiMiningContext miningContext = AnkiMiningContext(
      sentence: sentence,
      cueSentence: snapshotCueSentence.isNotEmpty ? snapshotCueSentence : null,
      documentTitle: _book?.title,
      coverPath: coverPath,
      sasayakiAudioPath: sasayakiAudioPath,
      sentenceOffset: snapshotSentenceOffset,
      // TODO-115: 书籍来源 → 卡片追加 `book` 分类标签（reader 不走 DictionaryPageMixin）。
      source: AnkiMiningSource.book,
      // TODO-681 / BUG-393：「自动添加书名到标签」开启时追加书名标签。reader 弹窗制卡
      // 此前不走卡片创建器 TagsField，故标题没被加进 tag；与视频同走共享 buildNoteTags
      // 注入（经创建器再走 fields 已带同一标签时由 buildNoteTags 去重，不重复）。
      bookTitleTag: appModel.autoAddBookNameToTags
          ? BaseAnkiRepository.sanitizeTitleTag(_book?.title)
          : null,
    );

    return (context: miningContext, cleanup: cleanupSasayakiTempDir);
  }

  Future<MinePopupResult> _onMineFromPopupInner(
      Map<String, String> fields) async {
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final prepared = await _prepareMiningContext();
    final AnkiMiningContext? miningContext = prepared.context;
    if (miningContext == null) {
      prepared.cleanup();
      return const MinePopupResult();
    }

    final MineOutcome outcome;
    try {
      outcome = await repo.mineEntry(
        rawPayloadJson: jsonEncode(fields),
        context: miningContext,
      );
    } finally {
      prepared.cleanup();
    }

    // 牌组名仅 success 需要（避免给失败分支白白 loadSettings）。
    final String deckName = outcome.result == MineResult.success
        ? (await repo.loadSettings()).selectedDeckName ?? ''
        : '';
    final described = describeMineOutcome(outcome, deckName: deckName);
    // 制卡成功计入书籍统计（reader 走 BaseSourcePageState.onMineFromPopup，不
    // mixin DictionaryPageMixin，故直接 addMiningCount，来源固定 book）。失败吞掉记日志。
    if (described.record) unawaited(_recordMined());
    // TODO-633: success also lands one mined-sentence history row (sentence +
    // locator anchors to jump back), complementing the per-day count above.
    if (described.record) {
      unawaited(_recordMinedSentence(fields, miningContext, outcome.noteId));
    }
    HibikiToast.show(msg: described.message);
    if (described.success) {
      // TODO-270 F/G：合并卡已落地 → 清空多句草稿（popup.js 同事件把角标清零，
      // 两端在同一事件归零、不漂移）。下一次查词从空草稿重新累积。
      _miningDraft.clear();
      // TODO-270 D：AnkiConnect 成功制卡带回 note id（noteId 非空），让弹窗把这张
      // 标记为「最新可改」第三态；AnkiDroid 的 noteId 恒为 null（优雅降级，进不了
      // 第三态）。ankiConnect 沿用旧的「成功即可同步刷新 ✓」语义。
      return MinePopupResult(ankiConnect: true, noteId: outcome.noteId);
    }
    return const MinePopupResult();
  }

  Future<MinePopupResult> _onUpdateFromPopupInner(
    int noteId,
    Map<String, String> fields,
  ) async {
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final prepared = await _prepareMiningContext();
    final AnkiMiningContext? miningContext = prepared.context;
    if (miningContext == null) {
      prepared.cleanup();
      return const MinePopupResult();
    }

    final MineOutcome outcome;
    try {
      outcome = await repo.updateMinedNote(
        noteId: noteId,
        rawPayloadJson: jsonEncode(fields),
        context: miningContext,
      );
    } finally {
      prepared.cleanup();
    }

    // 覆盖路径走收口的单一真相（overwrite=true → card_overwritten + 不记账）。覆盖已有
    // 卡片不计入统计（不是新制一张），成功仍保留「最新可改」第三态、带回同一 noteId。
    final String deckName = outcome.result == MineResult.success
        ? (await repo.loadSettings()).selectedDeckName ?? ''
        : '';
    final described =
        describeMineOutcome(outcome, deckName: deckName, overwrite: true);
    HibikiToast.show(msg: described.message);
    if (described.success) {
      return MinePopupResult(ankiConnect: true, noteId: outcome.noteId);
    }
    return const MinePopupResult();
  }

  /// 把一次成功制卡计入书籍统计。reader 走 [BaseSourcePageState.onMineFromPopup]，
  /// 不 mixin [DictionaryPageMixin]，故自带本记账（来源固定 [kStatSourceBook]，与
  /// mixin 的 `recordMined` 同契约：[HibikiDatabase.addMiningCount]）。失败吞掉并记日志。
  Future<void> _recordMined() async {
    try {
      await appModel.database.addMiningCount(
        sourceType: kStatSourceBook,
        dateKey: statTodayKey(),
      );
    } catch (e, st) {
      debugPrint('[hibiki-stats] reader addMiningCount failed: $e\n$st');
    }
  }

  /// TODO-633: record mined sentence history (book source); locator anchors
  /// match favorite-sentence so collections page reuses _openBook to jump.
  Future<void> _recordMinedSentence(
    Map<String, String> fields,
    AnkiMiningContext context,
    int? noteId,
  ) async {
    try {
      final int section = _lookupSectionIndex;
      final sentenceRange = _cachedSentenceRange ??
          (_cachedSelectionRange != null
              ? (
                  offset: _cachedSelectionRange!.offset,
                  length: _cachedSelectionRange!.length
                )
              : null);
      await appModel.database.addMinedSentence(
        source: kStatSourceBook,
        dateKey: statTodayKey(),
        expression: fields['expression'] ?? '',
        reading: fields['reading'] ?? '',
        glossary: fields['glossary'] ?? '',
        sentence: context.sentence,
        documentTitle: context.documentTitle ?? _book?.title,
        chapterLabel: _currentChapterLabelFor(section),
        bookKey: widget.bookKey,
        sectionIndex: section,
        normCharOffset: sentenceRange?.offset,
        normCharLength: sentenceRange?.length,
        noteId: noteId,
      );
    } catch (e, st) {
      debugPrint('[hibiki-stats] reader addMinedSentence failed: $e\n$st');
    }
  }

  Future<String?> _prepareSasayakiCuesJson() async {
    _cachedAllCues = null;
    _cachedSasayaki = false;

    // BUG-395：逐句高亮策略判据归一到「cue 是否 sasayaki 编码」（与 playback 端
    // SasayakiMatchCodec.tryDecode 同一判据），不再用 _srtBookUid（音频格式=srt）
    // 当代理。旧代码在 _srtBookUid!=null 时**无条件 return null**：但「普通 EPUB +
    // SRT 音频」被 matcher 匹配进真 EPUB 后 cue 是 sasayaki://，playback 走 sasayaki
    // 高亮却取不到 range（setup 早退 → applySasayakiCues 永不调用 → cueRangesMap
    // 恒空）→ 每次 highlightSasayakiCue 都 RETURN_NULL_no_segments，正文无任何跟随
    // 高亮（章节级跟随仍正常，因其走 cue 解码的 sectionIndex，不依赖 DOM range）。
    // SRT 与普通有声书两源在 _loadHighlightCues 之后判据完全一致。
    final List<AudioCue>? allCues = await _loadHighlightCues();
    if (allCues == null) {
      debugPrint('[sasayaki-hl] prepareCues path=NONE '
          '(srtUid=null, audiobookKey=null) -> return null');
      return null;
    }
    _cachedAllCues = allCues;
    _cachedSasayaki = allCues.any(
      (c) => SasayakiMatchCodec.tryDecode(c.textFragmentId) != null,
    );

    final String pathTag = _srtBookUid != null ? 'SRT' : 'AUDIOBOOK';
    if (!_cachedSasayaki) {
      // 真正非 sasayaki 的书：纯 [data-cue-id] 字幕（合成书走 __hoshiHighlight 选择器）
      // 或 matcher 全失败（无锚点）。逐句高亮不走 sasayaki range，保持早退。
      debugPrint('[sasayaki-hl] prepareCues path=$pathTag '
          'srtUid=$_srtBookUid audiobookKey=$_audiobookBookKey '
          'allCues=${allCues.length} cachedSasayaki=false '
          '-> SKIPPED (no sasayaki cues)');
      return null;
    }

    // BUG-405：复用 AudiobookBridge.buildSasayakiPayload，与 playback 桥接路径共用
    // 同一份必含 cue 原文 text 的 payload 契约 —— JS collectSasayakiCueRanges 靠
    // cue.text 在实时 DOM 就近重定位高亮（BUG-060/300），缺 text 会落空。
    final List<Map<String, dynamic>> payload =
        AudiobookBridge.buildSasayakiPayload(allCues, _currentChapter);
    // BUG-366/TODO-630 诊断：sasayaki 书最终送进 WebView 的 payload 条数。
    // payloadLen=0 表示当前章无命中 cue（applySasayakiCues 不会被调用）。
    debugPrint('[sasayaki-hl] prepareCues path=$pathTag-SASAYAKI '
        'srtUid=$_srtBookUid chapter=$_currentChapter '
        'allCues=${allCues.length} payloadLen=${payload.length}');
    if (payload.isEmpty) return null;
    return jsonEncode(payload);
  }

  /// reader 逐句高亮的全书 cue 来源。SRT 字幕书走 [SrtBookRepository]、普通有声书走
  /// [AudiobookRepository]；两源加载后 sasayaki 判据完全一致（BUG-395），setup 不再
  /// 按书源分叉出不同的高亮策略。返回 null = 本书无任何音频 cue 源。
  Future<List<AudioCue>?> _loadHighlightCues() async {
    if (_srtBookUid != null) {
      return SrtBookRepository(appModel.database).cuesFor(_srtBookUid!);
    }
    if (_audiobookBookKey != null) {
      return AudiobookRepository(appModel.database)
          .cuesForBook(_audiobookBookKey!);
    }
    return null;
  }

  Future<void> _injectAudiobookBridge() async {
    if (_controller == null || _audiobookController == null) return;

    await AudiobookBridge.inject(_controller!,
        primaryColor: _themeSasayakiColor());

    final List<AudioCue>? allCues = _cachedAllCues;
    if (allCues == null) return;

    if (_srtBookUid != null) {
      _audiobookController!.setChapterCues(allCues);
      _audiobookController!.setAllBookCues(allCues);
      if (_srtCueChapterMap == null) {
        final (Map<int, int> m, List<(int, int)> r) =
            _buildSrtChapterMap(allCues);
        _srtCueChapterMap = m;
        _srtChapterRanges = r;
      }
    } else if (_audiobookBookKey != null) {
      if (_cachedSasayaki) {
        _audiobookController!.setChapterCues(allCues);
        _audiobookController!.setAllBookCues(allCues);
      } else {
        final String chapterHref = _book!.chapters[_currentChapter].href;
        final AudiobookRepository repo = AudiobookRepository(appModel.database);
        final List<AudioCue> cues = await repo.cuesForChapter(
          bookKey: _audiobookBookKey!,
          chapterHref: chapterHref,
        );
        _audiobookController!.setChapterCues(cues);
        _audiobookController!.setAllBookCues(allCues);
        if (cues.isEmpty) {
          await AudiobookBridge.annotate(
            _controller!,
            chapterHref: chapterHref,
          );
        }
      }
    }
    _onCueChanged();

    if (_lyricsMode && _audiobookController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadLyricsPage();
      });
    }
  }
}
