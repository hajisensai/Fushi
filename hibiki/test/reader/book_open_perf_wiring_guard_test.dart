import 'package:flutter_test/flutter_test.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-131 守卫：锁定「打开书籍白屏优化」的开书路径接线，防回归。
/// reader_hibiki_page.dart 太重（WebView + DB + profile providers）不便在 host
/// widget 测试里整页 mount，纯函数等价性由 book_open_char_counts_test.dart 覆盖；
/// 这里用源码扫描守住 _initBook 的关键时序/数据流不变量。
void main() {
  late String src;

  setUpAll(() {
    src = readReaderPageSource();
  });

  test('_initBook 并行起跑 profile/settings 链与书本定位/解析链', () {
    final int profileIdx = src.indexOf('_resolveProfileAndSettings(db)');
    final int locateIdx = src.indexOf('_locateBookOnDisk(db)');
    final int firstAwaitIdx = src.indexOf('await profileSettingsFuture;');
    expect(profileIdx, greaterThan(0));
    expect(locateIdx, greaterThan(0));
    expect(firstAwaitIdx, greaterThan(0));
    // 两条链的 Future 必须都在第一个 await 之前就被创建（并行起跑），否则退化成
    // 串行，白屏优化失效。
    expect(profileIdx, lessThan(firstAwaitIdx),
        reason: 'profile/settings Future 必须在 await 之前起跑');
    expect(locateIdx, lessThan(firstAwaitIdx),
        reason: 'book-locate Future 必须在 await 之前起跑（与 profile 链并行）');
  });

  test('开书优先复用 DB 已存的 per-chapter 字符数（跳过整本 html_parser 计数）', () {
    expect(src.contains('parseBookOnly'), isTrue,
        reason: '冷开首屏走 parseBookOnly（不在 isolate 里整本计数）');
    expect(src.contains('charCountsFromChaptersJson('), isTrue,
        reason: '必须从 chaptersJson 复用 DB 计数');
    // 整本「解析+计数」入口 parseAndCountChapters 不应再出现在开书路径
    // （只保留给等价性测试/旧路径），否则等于没省下计数。
    expect(src.contains('compute(parseAndCountChapters'), isFalse,
        reason: '_initBook 不应再 compute(parseAndCountChapters)——那会整本计数');
  });

  test('DB 计数缺失时后台补算并重置统计基准（避免 charDiff 幻象 spike）', () {
    expect(src.contains('_recomputeCharCountsInBackground'), isTrue);
    // 后台补算落定后必须重置统计水位 _sessionMaxAbsoluteChars（TODO-147 改名前
    // 为 _lastAbsoluteCount），否则零计数期间它停在 0，计数落定后首个进度回调会把
    // 整段前缀误当本次新读字数累进统计。
    final int recomputeIdx =
        src.indexOf('void _recomputeCharCountsInBackground()');
    expect(recomputeIdx, greaterThan(0));
    final int nextMethodIdx =
        src.indexOf('Future<EpubBook?> _buildBookFromDb(');
    final String body = src.substring(recomputeIdx, nextMethodIdx);
    expect(body.contains('_sessionMaxAbsoluteChars = _absoluteCharPosition('),
        isTrue,
        reason: '补算落定后必须把统计水位校到当前位置，杜绝统计 spike');
    expect(body.contains('identical(_book, book)'), isTrue,
        reason: '只在仍是同一本书时采用补算结果（防换书竞态）');
  });

  test('_applyCharCounts 重建累计前缀并刷新进度总字数', () {
    final int idx = src.indexOf('void _applyCharCounts(List<int> counts)');
    expect(idx, greaterThan(0));
    final int end = src.indexOf('void _recomputeCharCountsInBackground()');
    final String body = src.substring(idx, end);
    expect(body.contains('_chapterCumulativeChars'), isTrue);
    expect(body.contains('_progressTotalChars'), isTrue);
  });

  test('跨章收藏高亮复用书内缓存并按 section 过滤', () {
    expect(src, contains('_favoriteSentencesForBookCache'),
        reason: 'reader 应缓存当前书收藏，跨章只做内存过滤，避免每章全量 getAll/decode/sort');
    expect(src, contains('_favoriteSentencesForSection'));

    final int helperIdx = src.indexOf('_favoriteSentencesForSection');
    final int applyIdx = src.indexOf('Future<void> _applyChapterHighlights()');
    final int lyricsIdx = src.indexOf('Future<void> _applyLyricsFavorites()');
    final int refreshIdx =
        src.indexOf('Future<void> _refreshSectionHighlights(int section)');
    final int toggleIdx = src.indexOf('Future<void> _toggleFavoriteSentence()');
    expect(helperIdx, greaterThan(0));
    expect(applyIdx, greaterThan(0));
    expect(lyricsIdx, greaterThan(applyIdx));
    expect(refreshIdx, greaterThan(lyricsIdx));
    expect(toggleIdx, greaterThan(refreshIdx));

    final String helperBody = src.substring(helperIdx, applyIdx);
    expect(helperBody, contains('s.bookKey == widget.bookKey'));
    expect(helperBody, contains('s.sectionIndex == section'),
        reason: '章节高亮必须只取当前 section，不能把整本收藏都交给高亮桥');

    final String applyBody = src.substring(applyIdx, lyricsIdx);
    final String refreshBody = src.substring(refreshIdx, toggleIdx);
    expect(
        applyBody, contains('_favoriteSentencesForSection(_currentChapter)'));
    expect(refreshBody, contains('_favoriteSentencesForSection(section)'));
    expect(applyBody, isNot(contains('getAll()')),
        reason: '_applyChapterHighlights 跑在每章加载路径，不能每章全量解码收藏');
    expect(refreshBody, isNot(contains('getAll()')),
        reason: '_refreshSectionHighlights 也应复用缓存并只按 section 筛');
  });

  test('收藏新增删除会失效缓存再刷新高亮', () {
    expect(src, contains('void _invalidateFavoriteSentenceCache()'));

    final int settingsIdx = src.indexOf('Future<void> _showAppearanceSheet()');
    final int progressIdx = src.indexOf('Widget _buildTopProgressBar()');
    final int toggleIdx = src.indexOf('Future<void> _toggleFavoriteSentence()');
    expect(settingsIdx, greaterThan(0));
    expect(progressIdx, greaterThan(settingsIdx));
    expect(toggleIdx, greaterThan(progressIdx));
    // TODO-589 batch7: these methods moved into reader_hibiki/chrome.part.dart
    // (last in the merged corpus); `buildPopupAudioControls` is an @override that
    // stays in the shell (earlier in the corpus), so it is no longer a valid end
    // marker — `_toggleFavoriteSentence` is the final member, slice to EOF.
    final String settingsBody = src.substring(settingsIdx, progressIdx);
    final String toggleBody = src.substring(toggleIdx);
    expect(
        settingsBody,
        contains(
            'await favRepo.removeById(fav.id);\n          _invalidateFavoriteSentenceCache();'),
        reason: '设置面板删除收藏后，当前 reader 缓存必须失效');
    // BUG-494：取消收藏优先按缓存的精确条目 id removeById 删单条，无 id 时才回退内容键
    // removeByContent（包在 else 分支里，故内容键删单条这段多缩进一层，text: 现为 10 空格
    // 缩进）。守卫更新到当前缩进，不变量强度不变：内容键删除仍走 removeByContent 单条删。
    expect(toggleBody,
        contains('await repo.removeByContent(\n          text: sentence,'));
    expect(toggleBody, contains('_invalidateFavoriteSentenceCache();'));
    // 删除路径（内容键回退分支）删后必失效缓存。
    final int removeIdx = toggleBody.indexOf('await repo.removeByContent(');
    final int removeInvalidateIdx =
        toggleBody.indexOf('_invalidateFavoriteSentenceCache();', removeIdx);
    expect(removeInvalidateIdx, greaterThan(removeIdx),
        reason: '删除收藏（内容键回退）后当前 reader 缓存必须失效');
    // 新增收藏：repo.add(fav) 后必记住精确 id（BUG-494 removeById 用）并失效缓存再刷新
    // 高亮。BUG-494 在 add 与 invalidate 之间插入 _currentFavoriteId = fav.id;，故不再是
    // 紧邻两行——改为「add 之后、rebuild 之前必有 _currentFavoriteId 记账 + 缓存失效」，
    // 不变量强度不变（新增后缓存必失效）。
    final int addIdx = toggleBody.indexOf('await repo.add(fav);');
    expect(addIdx, greaterThan(0), reason: '新增收藏必须 repo.add(fav)');
    final int rebuildAfterAddIdx = toggleBody.indexOf(
        '_rebuild(() => _currentSentenceIsFavorited = true)', addIdx);
    expect(rebuildAfterAddIdx, greaterThan(addIdx),
        reason: '新增收藏后必须 rebuild 星标态');
    final String addBody = toggleBody.substring(addIdx, rebuildAfterAddIdx);
    expect(addBody, contains('_currentFavoriteId = fav.id;'),
        reason: 'BUG-494：新增后记住精确 id，供随后 removeById 精确删单条');
    expect(addBody, contains('_invalidateFavoriteSentenceCache();'),
        reason: '新增收藏后必须失效缓存重新拉取/过滤，保证高亮和星标状态准确');
  });
}
