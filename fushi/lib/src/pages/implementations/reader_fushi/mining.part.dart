// GENERATED-NOTE: extracted from reader_fushi_page.dart (TODO-589 batch2).
part of '../reader_fushi_page.dart';

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
extension _ReaderMining on _ReaderFushiPageState {
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

    // TODO-1388 / BUG-703：制卡封面解析必须与书架网格 (_resolveCoverUrl) 对称。
    // 旧逻辑只有裸 File(p.join(_extractDir!, coverHref)).existsSync()，对大小写不
    // 敏感。coverHref 在大小写不敏感宿主 (Windows/macOS) 导入时被 p.canonicalize
    // 小写化 (epub_parser _itemRelHref)，解压文件却保留真实大小写 (TODO-739)；书到
    // Android/Linux (大小写敏感 FS) 后裸探测按小写落空 → coverPath=null → 制出的卡
    // 无封面（书架却因 case-insensitive 兜底正常显示）。复用书架同一个兜底
    // (ReaderFushiSource.resolveCoverFilePath) 命中真实文件，让制卡与显示一致。
    String? coverPath;
    if (_extractDir != null) {
      coverPath = ReaderFushiSource.resolveCoverFilePath(
        extractDir: _extractDir!,
        coverPath: _book?.coverHref,
      );
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

    String? sentenceAudioPath;
    Directory? sentenceAudioTempDir;
    bool requestedSentenceAudioClip = false;
    String? sentenceAudioFailure;
    void cleanupSentenceAudioTempDir() {
      if (sentenceAudioTempDir != null && sentenceAudioTempDir.existsSync()) {
        try {
          sentenceAudioTempDir.deleteSync(recursive: true);
        } catch (e, stack) {
          ErrorLogService.instance
              .log('ReaderFushi.mineEntry.cleanupAudio', e, stack);
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
        sentenceAudioTempDir =
            Directory.systemTemp.createTempSync('hibiki_mine_sentence_audio_');
        // 句子音频容器与视频制卡保持同一平台规则：iOS 用 `.m4a`，让 AnkiMobile
        // 把 localhost URL 当作可下载音频；桌面/Android 继续用 `.aac`（adts），避免
        // 桌面 ffmpeg-min 缺 mp4/ipod/m4a muxer 时 exit -22（BUG-460 / BUG-644）。
        final String outputPath = p.join(
          sentenceAudioTempDir.path,
          'sentence.${immersionMiningAudioExtension()}',
        );
        requestedSentenceAudioClip = true;
        // TODO-1650 音频质量档：默认档 0（单声道 64k=现状），更高档立体声 128k/192k。
        // TODO-970：句子音频已全平台统一走 ffmpeg（extractAudioSegment 不再有 Android
        // 原生 Transformer + AacAdtsCueAudioRewriter 特例），两端都吃这个档。
        final MiningMediaCompression mediaCompression =
            MiningMediaCompression.resolve(
          imageTier: appModel.miningImageQuality,
          audioTier: appModel.miningAudioQuality,
        );
        sentenceAudioPath = await TtsChannel.instance.extractAudioSegment(
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
          '[ReaderFushi] mine: audio present but no sentence-audio range '
          '(lookupCue=null, sentenceRange=${_cachedSentenceRange != null}, '
          'draftSentences=${_miningDraft.length}).',
        );
        FushiToast.show(
            msg: t.card_mined_without_sentence_audio,
            severity: ToastSeverity.warning);
      }
    }

    if (requestedSentenceAudioClip && sentenceAudioPath == null) {
      cleanupSentenceAudioTempDir();
      ErrorLogService.instance.log(
        'ReaderFushi.mineEntry.sentenceAudio',
        sentenceAudioFailure == null
            ? 'sentence audio export failed'
            : 'sentence audio export failed: $sentenceAudioFailure',
        StackTrace.current,
      );
      FushiToast.show(
        msg: t.card_export_failed_detail(
          reason: sentenceAudioFailure == null
              ? 'sentence audio export failed'
              : 'sentence audio export failed: $sentenceAudioFailure',
        ),
        severity: ToastSeverity.error,
      );
      return (context: null, cleanup: cleanupSentenceAudioTempDir);
    }

    // 合集名标签（同「自动添加书名到标签」开关）：反查当前书/有声书所属合集名，作独立 tag。
    // 开关关闭或不属任何合集时 null 不追加。DB 反查放此处（_prepareMiningContext 本就 async）。
    final String? collectionTag = appModel.autoAddBookNameToTags
        ? BaseAnkiRepository.sanitizeTitleTag(await _resolveCollectionName())
        : null;

    // TODO-644 / BUG-357：用 await 前的快照值构造上下文（cue 句 / 加粗偏移），不再
    // 读 currentCueSentence / _cachedSentenceOffset 这两个会被并发查词改写的可变成员。
    //
    // P4 身份/显示二分：[AnkiMiningContext.documentTitle] 只喂 `{document-title}`
    // 卡片字段（经 base_anki_repository 的 renderMediaPayload → buildMinedFields，
    // 含互联转发端），是**写到卡片上给人看的显示语境**——过 display-title 门面；
    // Anki 查重身份用 expression，不经此值。统计聚合键（[_recordMined] 的
    // addMineCountPerBook.title）与制卡历史快照（[_recordMinedSentence] 的
    // documentTitle 落库列）是身份语境，**各自直取 raw `_book?.title`**，刻意不
    // 复用本变量——两个用途两个变量，见下方两处注释。
    final String? displayDocumentTitle = _book == null
        ? null
        : displayTitleForBook(bookKey: widget.bookKey, rawTitle: _book!.title);
    final AnkiMiningContext miningContext = AnkiMiningContext(
      sentence: sentence,
      cueSentence: snapshotCueSentence.isNotEmpty ? snapshotCueSentence : null,
      documentTitle: displayDocumentTitle,
      coverPath: coverPath,
      sentenceAudioPath: sentenceAudioPath,
      sentenceOffset: snapshotSentenceOffset,
      // TODO-115: 书籍来源 → 卡片追加 `book` 分类标签（reader 不走 DictionaryPageMixin）。
      source: AnkiMiningSource.book,
      // TODO-681 / BUG-393：「自动添加书名到标签」开启时追加书名标签。reader 弹窗制卡
      // 此前不走卡片创建器 TagsField，故标题没被加进 tag；与视频同走共享 buildNoteTags
      // 注入（经创建器再走 fields 已带同一标签时由 buildNoteTags 去重，不重复）。
      // P4 判断：Anki 标签是卡片上的组织性显示标注（与 {document-title} 同为
      // 给人看），与 documentTitle 同源过门面——两者不同名会破坏 buildNoteTags
      // 与创建器 TagsField 的去重口径。
      bookTitleTag: appModel.autoAddBookNameToTags
          ? BaseAnkiRepository.sanitizeTitleTag(displayDocumentTitle)
          : null,
      collectionTag: collectionTag,
    );

    return (context: miningContext, cleanup: cleanupSentenceAudioTempDir);
  }

  /// 反查当前书/有声书所属合集名（供制卡「合集名标签」用）。折叠归属跟随
  /// [FushiDatabase.getPrimaryCollectionIdByEntry] 的「最小 collectionId」语义，与书架
  /// 折叠归行一致。键构造（见 collection_grouping / shelf_ordering）：
  /// - EPUB / 普通 EPUB-有声书 → `'epub|<uid>'`（v83：成员表 epub entryKey =
  ///   `epub_books.uid`；页面手里的 [bookKey] 经 resolveEpubBookUid 换算，换算
  ///   不上——书行已删的边缘竞态——沿用 bookKey，与旧行为同样查不中即 null）。
  /// - 纯 SRT 有声书（[_srtBookUid] 非空）→ `'srt|<uid>'`；srt-backed 有声书两身份都试
  ///   （BUG-812：可能存成 `srt|uid`，先 epub 键 miss 再回退，与 host service 同策略）。
  /// 不属任何合集 / 合集已删（孤儿）→ `null`，[buildNoteTags] 不追加。
  Future<String?> _resolveCollectionName() async {
    final FushiDatabase db = appModel.database;
    final Map<String, int> primaryByEntry =
        await db.getPrimaryCollectionIdByEntry();
    if (primaryByEntry.isEmpty) return null;
    final String epubEntryKey =
        await db.resolveEpubBookUid(widget.bookKey) ?? widget.bookKey;
    final String? srtUid = _srtBookUid;
    final int? collectionId = srtUid != null
        ? (primaryByEntry[MediaKind.srt.compositeKey(srtUid)] ??
            primaryByEntry[MediaKind.epub.compositeKey(epubEntryKey)])
        : primaryByEntry[MediaKind.epub.compositeKey(epubEntryKey)];
    if (collectionId == null) return null;
    return (await db.getMediaCollectionById(collectionId))?.name;
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

    // TODO-948/952 诊断可见性：制卡链路自身字节稳定，但用户报「卡片没有句子/句子
    // 音频」。真因是运行时二选一——句子真空（抽句回空）或 Anki 卡片模板没有字段
    // 映射到 {sentence}/{sentence-audio}（字段恒空）。这里在制卡前把『为什么会空』
    // 摊到用户面前（toast + 日志），不改任何制卡行为（卡照常创建）。
    await _emitSentenceDiagnostics(repo, miningContext);

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
    // mixin DictionaryPageMixin，故自调 recordMiningEvent，来源固定 book）。失败吞掉记日志。
    if (described.record) unawaited(_recordMined());
    // TODO-633: success also lands one mined-sentence history row (sentence +
    // locator anchors to jump back), complementing the per-day count above.
    if (described.record) {
      unawaited(_recordMinedSentence(fields, miningContext, outcome.noteId));
    }
    FushiToast.show(
        msg: described.message, severity: mineToastSeverity(described.status));
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
    FushiToast.show(
        msg: described.message, severity: mineToastSeverity(described.status));
    if (described.success) {
      return MinePopupResult(ankiConnect: true, noteId: outcome.noteId);
    }
    return const MinePopupResult();
  }

  /// TODO-948/952：制卡『句子为空 / 字段未映射』诊断（加性、零行为改动）。
  ///
  /// 制卡链路（getSentenceContext → setCurrentSentence → currentSentence → 卡片
  /// {sentence} 字段）自字节稳定，但用户报「卡片没有句子和句子音频」。空的来源只有
  /// 两条运行时路径，这里把它们摊给用户而**不改任何捕获/制卡逻辑**：
  ///
  /// - [context].sentence 为空 → 运行时根本没捕获到句子（无标点/无 <p> 等内容让
  ///   JS 抽句回空，或没选词）。
  /// - 句子非空、但当前 Anki note-type 的 fieldMappings **没有任何字段消费**
  ///   `{sentence}`/`{cue-sentence}`（句子）或 `{sentence-audio}`（句子音频）→ 字段
  ///   渲染恒空，卡片上自然「没有句子」。判据复用 hibiki_anki 的纯函数
  ///   [AnkiHandlebarOptions.anyFieldConsumesSentence] / [anyFieldConsumesToken]，
  ///   与 [AnkiHandlebarRenderer] 同一套 token 语义，不自己重造解析。
  ///
  /// 两条提示互斥（空句子优先），都是 toast + 日志，不阻断、不改变制卡结果。
  Future<void> _emitSentenceDiagnostics(
    BaseAnkiRepository repo,
    AnkiMiningContext context,
  ) async {
    if (context.sentence.trim().isEmpty) {
      debugPrint('[mine-diag] empty sentence: no sentence captured for this '
          'selection (JS sentence extraction returned empty or no selection).');
      FushiToast.show(
          msg: t.card_mined_no_sentence_captured,
          severity: ToastSeverity.warning);
      return;
    }

    // 句子非空 → 检查卡片模板是否有字段接它。loadSettings 拿到的是用户持久化的
    // fieldMappings（与 mineEntry 渲染同一来源）。读不到设置（未配置 Anki 等）时
    // 静默跳过——制卡本会在 mineEntry 走 notConfigured 分支提示，这里不重复报噪。
    final Map<String, String> fieldMappings;
    try {
      fieldMappings = (await repo.loadSettings()).fieldMappings;
    } catch (e, st) {
      debugPrint('[mine-diag] loadSettings failed, skip mapping check: '
          '$e | $st');
      return;
    }
    if (fieldMappings.isEmpty) return;

    if (!AnkiHandlebarOptions.anyFieldConsumesSentence(fieldMappings)) {
      debugPrint('[mine-diag] sentence non-empty but no field maps {sentence}/'
          '{cue-sentence}; card will have an empty sentence field.');
      FushiToast.show(
          msg: t.card_mined_unmapped_sentence_field,
          severity: ToastSeverity.warning);
      return;
    }

    final bool hasSentenceAudio = (context.sentenceAudioPath ?? '').isNotEmpty;
    if (hasSentenceAudio &&
        !AnkiHandlebarOptions.anyFieldConsumesSentenceAudio(fieldMappings)) {
      debugPrint('[mine-diag] sentence audio attached but no field maps '
          '{sentence-audio}; the audio will not land on the card.');
      FushiToast.show(
          msg: t.card_mined_unmapped_sentence_audio_field,
          severity: ToastSeverity.warning);
    }
  }

  /// 把一次成功制卡计入书籍统计。reader 走 [BaseSourcePageState.onMineFromPopup]，
  /// 不 mixin [DictionaryPageMixin]，故自带本记账（来源固定 [kStatSourceBook]，与
  /// mixin 的 `recordMined` 同契约：[FushiDatabase.recordMiningEvent]）。失败吞掉并记日志。
  Future<void> _recordMined() async {
    // P4 写侧收敛：全局汇总 + per-book 计数走 DB 复合入口
    // [FushiDatabase.recordMiningEvent]（同事务，dateKey 由 DB 层从 at 派生）。
    // P4 身份红线：这里的 title 是统计聚合键，**恒 raw**（`_book?.title`）——
    // 过 override 门面会让改名前后的计数分叉成两个桶。
    try {
      await appModel.database.recordMiningEvent(
        bookKey: widget.bookKey,
        title: _book?.title ?? '',
        sourceType: kStatSourceBook,
        at: DateTime.now(),
      );
    } catch (e, st) {
      debugPrint('[fushi-stats] reader recordMiningEvent failed: $e\n$st');
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
      final int section = _favoriteSectionIndex;
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
        // P4 身份红线：`mined_sentences.document_title` 是落库快照（与收藏句
        // chrome.part.dart 的 `bookTitle: _book!.title` 同款 raw 身份快照）——
        // context.documentTitle 已过显示门面，这里**必须直取 raw**；收藏页
        // 渲染端按 bookKey 再过门面显示新名。
        documentTitle: _book?.title,
        chapterLabel: _currentChapterLabelFor(section),
        bookKey: widget.bookKey,
        sectionIndex: section,
        normCharOffset: sentenceRange?.offset,
        normCharLength: sentenceRange?.length,
        noteId: noteId,
      );
    } catch (e, st) {
      debugPrint('[fushi-stats] reader addMinedSentence failed: $e\n$st');
    }
  }

  Future<String?> _prepareSentenceAudioCuesJson() async {
    // BUG-395：逐句高亮策略判据归一到「cue 是否 sasayaki 编码」（与 playback 端
    // SasayakiMatchCodec.tryDecode 同一判据），不再用 _srtBookUid（音频格式=srt）
    // 当代理。旧代码在 _srtBookUid!=null 时**无条件 return null**：但「普通 EPUB +
    // SRT 音频」被 matcher 匹配进真 EPUB 后 cue 是 sasayaki://，playback 走 sasayaki
    // 高亮却取不到 range（setup 早退 → applySasayakiCues 永不调用 → cueRangesMap
    // 恒空）→ 每次 highlightSasayakiCue 都 RETURN_NULL_no_segments，正文无任何跟随
    // 高亮（章节级跟随仍正常，因其走 cue 解码的 sectionIndex，不依赖 DOM range）。
    // SRT 与普通有声书两源在 _loadHighlightCues 之后判据完全一致。
    //
    // 性能（首帧路径）：全书 cue 在 _resolveAudioSlot → _primeAudioCuesForCurrentBook
    // 已查过并缓存进 _cachedAllCues；本方法此前每次章节加载都先清缓存再重查一遍
    // 全书 cue（纯重复 DB 往返，串行挡在引擎注入之前），且清缓存后若加载失败会让
    // _injectAudiobookBridge 静默拿到 null 跳过 cue 装载。缓存生命周期 = 音频槽绑定
    // （_resolveAudioSlot 的 detach 块清、prime 重灌），这里直接复用，仅缓存缺失时
    // 兜底加载。
    List<AudioCue>? allCues = _cachedAllCues;
    if (allCues == null) {
      allCues = await _loadHighlightCues();
      if (allCues == null) {
        debugPrint('[sentence-audio-hl] prepareCues path=NONE '
            '(srtUid=null, audiobookKey=null) -> return null');
        return null;
      }
      _cachedAllCues = allCues;
      _cachedSentenceAudio = allCues.any(
        (c) => SubtitleRematchCodec.tryDecode(c.textFragmentId) != null,
      );
    }

    final String pathTag = _srtBookUid != null ? 'SRT' : 'AUDIOBOOK';
    if (!_cachedSentenceAudio) {
      // 真正非 sasayaki 的书：纯 [data-cue-id] 字幕（合成书走 __fushiHighlight 选择器）
      // 或 matcher 全失败（无锚点）。逐句高亮不走 sasayaki range，保持早退。
      debugPrint('[sentence-audio-hl] prepareCues path=$pathTag '
          'srtUid=$_srtBookUid audiobookKey=$_audiobookBookKey '
          'allCues=${allCues.length} cachedSentenceAudio=false '
          '-> SKIPPED (no sentenceAudioHighlight cues)');
      return null;
    }

    // BUG-405：复用 AudiobookBridge.buildSasayakiPayload，与 playback 桥接路径共用
    // 同一份必含 cue 原文 text 的 payload 契约 —— JS collectSasayakiCueRanges 靠
    // cue.text 在实时 DOM 就近重定位高亮（BUG-060/300），缺 text 会落空。
    final List<Map<String, dynamic>> payload =
        AudiobookBridge.buildSentenceAudioPayload(allCues, _currentChapter);
    // BUG-366/TODO-630 诊断：sasayaki 书最终送进 WebView 的 payload 条数。
    // payloadLen=0 表示当前章无命中 cue（applySasayakiCues 不会被调用）。
    debugPrint('[sentence-audio-hl] prepareCues path=$pathTag-SENTENCE-AUDIO '
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
        primaryColor: _themeSentenceAudioHighlightColor());

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
      if (_cachedSentenceAudio ||
          audiobookCuesUseWholeBookForChapter(allCues)) {
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
