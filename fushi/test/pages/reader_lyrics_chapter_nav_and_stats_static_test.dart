import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'reader_fushi_page_source_corpus.dart';

/// BUG-2596 / BUG-2597：歌词模式的「跳章」与「统计」两条接线守卫。
///
/// BUG-2596（用户报「歌词模式没有跳章节按钮」）：导航键此前和图集一起被
/// `!_lyricsMode` 藏掉；补回后，导航抽屉里的每个跳转入口在歌词模式都必须走
/// **音频定位**（歌词文档是全书 cue 的连续列表，没有 EPUB 章可换）——正文导航会把
/// 歌词页换成 EPUB 章而 `_lyricsMode` 仍为真，歌词直接消失。书内搜索 / 字数跳转
/// 在歌词里没有落点，直接不接线（面板按既有契约不渲染）。
///
/// 歌词模式统计（BUG-2597 → 2026-10-04 覆盖层 → 2026-11-10 独立模式）：歌词模式的
/// 阅读单元是「当前句」，换句即 arrive（与正文同一本账本、同一把全书学习单位尺），
/// 进歌词 `leave()` 正文页、出歌词 `leave()` 当前句；正文在歌词模式期间停着不参与。
///
/// 端到端那层在 `integration_test/reader_lyrics_settings_and_chapter_nav_itest.dart`。
void main() {
  final String src = readReaderPageSource();

  group('BUG-2596 歌词模式跳章', () {
    test('_jumpToChapterAnchor 在歌词模式先分流到 _jumpToChapterInLyricsMode', () {
      final String body = methodBody(
        src,
        '  Future<void> _jumpToChapterAnchor(',
      );
      final int gate = body.indexOf('if (_lyricsMode)');
      final int textNav = body.indexOf('_navigateToChapter(');
      expect(gate, greaterThan(0));
      expect(
        textNav,
        greaterThan(gate),
        reason: '歌词分流必须在任何正文导航之前——正文导航会把歌词文档换成 EPUB 章',
      );
      expect(
        containsIdentifierCall(body, '_jumpToChapterInLyricsMode'),
        isTrue,
      );
    });

    test('歌词模式跳章 = 音频定位到该章首句；没有 cue 的章才退回正文', () {
      final String body = methodBody(
        src,
        '  Future<void> _jumpToChapterInLyricsMode(',
      );
      expect(
        containsIdentifierCall(body, '_firstCueOfSection'),
        isTrue,
        reason: '该章在全书 cue 里的首句，三种 cue 家族各走精确反查',
      );
      expect(containsIdentifierCall(body, 'skipToCue'), isTrue);
      final String first = methodBody(
        src,
        '  AudioCue? _firstCueOfSection(int index)',
      );
      expect(
        containsIdentifierCall(first, 'sectionFirstCue'),
        isTrue,
        reason: 'fushi-cue:// 家族与有声书面板「章节」tab 同一口径',
      );
      expect(
        containsIdentifier(first, '_srtChapterRanges'),
        isTrue,
        reason: '独立 SRT 书按分桶首句序号',
      );
      expect(
        containsIdentifier(first, '_chapterIndexForText'),
        isFalse,
        reason: '不做文本模糊反查（每次解析全书章节 HTML，且定位错章比退回正文更糟）',
      );
      final int seek = body.indexOf('skipToCue(');
      final int leave = body.indexOf('_toggleLyricsMode(');
      expect(
        leave,
        greaterThan(seek),
        reason: '有 cue 就定位并 return；只有没 cue 的章才退出歌词模式再正文跳章',
      );
      expect(
        containsCodeLine(body, '_navigateToChapter(index, manual: true)'),
        isTrue,
      );
    });

    test('导航抽屉在歌词模式不接书内搜索；字数跳转照常接（落到音频）', () {
      final String sheet = methodBody(
        src,
        '  Widget _buildQuickSettingsSheet({',
      );
      expect(
        containsCodeLine(sheet, 'onJumpToCharOffset: _lyricsMode'),
        isFalse,
        reason: '反馈「歌词模式进度跳转看不到」：字数跳转不再按歌词模式摘掉',
      );
      expect(containsIdentifierCall(sheet, '_jumpToGlobalCharOffset'), isTrue);
      expect(
        containsCodeLine(
          sheet,
          'onSearchJump: _lyricsMode ? null : _jumpToSearchResult',
        ),
        isTrue,
      );
    });

    test('字数跳转在歌词模式先分流到音频定位，再碰任何正文导航', () {
      final String body = methodBody(
        src,
        '  Future<void> _jumpToGlobalCharOffset(',
      );
      final int gate = body.indexOf('if (_lyricsMode)');
      expect(gate, greaterThan(0));
      expect(
        containsIdentifierCall(body, '_jumpToGlobalCharOffsetInLyricsMode'),
        isTrue,
      );
      for (final String textNav in <String>[
        '_recordTextJumpDeparture(',
        '_navigateToChapterAndWait(',
        'restoreProgress(',
      ]) {
        expect(
          body.indexOf(textNav),
          greaterThan(gate),
          reason: '$textNav 必须在歌词分流之后——正文导航会把歌词文档换成 EPUB 章',
        );
      }
      final String lyrics = methodBody(
        src,
        '  Future<void> _jumpToGlobalCharOffsetInLyricsMode(',
      );
      expect(containsIdentifierCall(lyrics, '_audioCueNearCharOffset'), isTrue);
      expect(containsIdentifierCall(lyrics, '_firstCueOfSection'), isTrue);
      final int seek = lyrics.indexOf('skipToCue(');
      final int leave = lyrics.indexOf('_toggleLyricsMode(');
      expect(seek, greaterThan(0));
      expect(leave, greaterThan(seek), reason: '有 cue 就定位；整章没 cue 才退回正文');
      final String near = methodBody(
        src,
        '  AudioCue? _audioCueNearCharOffset(',
      );
      expect(
        near.contains('studyRangeOf: _studyRangeForAudioFragment'),
        isTrue,
        reason: '目标是学习单位偏移，cue 片段是音频 matchable 坐标，必须逐句换算再比',
      );
      expect(
        near.contains('normCharStart'),
        isFalse,
        reason: '不许拿学习偏移直接比 normCharStart/End（两套坐标越往章尾偏得越多）',
      );
    });

    test('歌词覆盖层接「进度跳转」与「跳转记录」，⋯ 不重复追加跳转记录', () {
      final String callbacks = methodBody(
        src,
        '  LyricsPlayerCallbacks _lyricsPlayerCallbacks(',
      );
      expect(
        containsIdentifierCall(callbacks, '_openLyricsPositionJump'),
        isTrue,
      );
      expect(
        containsIdentifierCall(callbacks, '_openJumpHistoryPanel'),
        isTrue,
      );
      final String open = methodBody(
        src,
        '  Future<void> _openLyricsPositionJump()',
      );
      expect(open, contains('_ReaderNavLanding.positionJump'));
      final String menu = methodBody(
        src,
        '  Future<void> _showLyricsMoreMenu(',
      );
      expect(
        containsIdentifierCall(menu, '_jumpHistoryMenuActions'),
        isFalse,
        reason: '跳转记录是布局里的歌词按钮（出厂在「更多」），再追加会出现两条',
      );
    });

    test('「跳到收藏」在歌词模式走音频定位到那句 cue', () {
      final String body = methodBody(
        src,
        '  Future<void> _jumpToFavoriteSentence(FavoriteSentence fav)',
      );
      final int gate = body.indexOf('if (_lyricsMode)');
      expect(gate, greaterThan(0));
      final String lyricsBranch = body.substring(
        gate,
        body.indexOf('}', body.indexOf('return;', gate)),
      );
      expect(containsIdentifierCall(lyricsBranch, '_favoriteAudioCue'), isTrue);
      expect(containsIdentifierCall(lyricsBranch, 'skipToCue'), isTrue);
      expect(body.indexOf('_navigateToChapterAndWait('), greaterThan(gate));
    });

    test('顶栏导航键挂了集成测试用的 key', () {
      final String header = methodBody(
        src,
        '  ReaderHeaderAction _readerControlAction(ReaderControlItem item)',
      );
      expect(header, contains("'fushi_reader_navigation_button'"));
    });
  });

  // 2026-11-10 所有者拍板：歌词模式是**独立模式**，有自己的一套统计，口径尽量贴近
  // 阅读器；不要「覆盖层 + 正文在下面替它跟随记账」的两 WebView 协作。这取代了
  // 10-04 的覆盖层口径（那一版把 BUG-2597 的「歌词单元入账」删了、让被盖住的正文
  // 强制跟随音频按页入账——字数一页一跳，读速慢慢掉再猛涨）。行为契约在
  // `test/stats/lyrics_read_unit_test.dart`（真账本）与
  // `test/media/audiobook/audiobook_reader_detached_test.dart`（真控制器）。
  group('歌词模式是独立模式：自己的位置与统计，正文停着', () {
    test('_onCueChanged 的歌词分支同步歌词层、按句落定后直接返回，不走正文跟随', () {
      final String body = methodBody(src, '  void _onCueChanged()');
      final int lyrics = body.indexOf('if (_lyricsMode) {');
      expect(lyrics, greaterThan(0));
      final String lyricsBranch = body.substring(
        lyrics,
        body.indexOf('\n    }\n', lyrics),
      );
      expect(
        containsIdentifierCall(lyricsBranch, '_syncLyricsOverlayCue'),
        isTrue,
      );
      expect(
        containsIdentifierCall(lyricsBranch, '_settleLyricsCue'),
        isTrue,
        reason: '当前句 = 歌词模式的阅读位置 / 阅读单元',
      );
      expect(
        containsCodeLine(lyricsBranch, 'return;'),
        isTrue,
        reason: '歌词分支不返回 = 被盖住的正文又开始替歌词翻页记账',
      );
      expect(
        containsIdentifierCall(lyricsBranch, 'consumeExplicitNavigationReveal'),
        isTrue,
        reason: '一次性 reveal 登记在歌词模式消费掉，不留到退出后迟到拽正文',
      );
      // 正文跟随路径（翻页 / 高亮）在歌词分支之后，歌词模式到不了。
      expect(body.indexOf('AudiobookBridge.highlight('), greaterThan(lyrics));
    });

    test('按句落定：账本经开始方式门 arrive、进度读数取句首、存档按当前句', () {
      final String settle = methodBody(src, '  void _settleLyricsCue(');
      expect(containsIdentifierCall(settle, '_lyricsReadingCue'), isTrue);
      expect(containsIdentifierCall(settle, '_studyUnitForLyricsCue'), isTrue);
      expect(containsIdentifierCall(settle, 'lyricsCueReadUnit'), isTrue);
      expect(
        containsIdentifierCall(settle, 'arriveReadUnitThroughStartGate'),
        isTrue,
        reason: '与正文翻页同一个「计时开始方式」门（先喂门、再 arrive，BUG-3100）',
      );
      expect(settle, contains('ledger: _readLedger,'));
      expect(
        settle,
        isNot(contains('isPlaying')),
        reason: '暂停着跳句 / 点行也是翻走上一句（正文按住翻页键扫过去同样计）',
      );
      expect(containsIdentifierCall(settle, '_traceArrive'), isTrue);
      expect(
        containsCodeLine(settle, '_progressCurrentChars = range.\$1;'),
        isTrue,
      );
      expect(
        containsIdentifierCall(settle, '_syncPositionFromCurrentCue'),
        isTrue,
      );
      final String unit = methodBody(
        src,
        '  ({int chapter, int offset, int length})? _studyUnitForLyricsCue(',
      );
      expect(
        containsIdentifierCall(unit, '_studyRangeForAudioFragment'),
        isTrue,
        reason: '音频 matchable 坐标必须先换成学习单位（BUG-2333）',
      );
      expect(containsIdentifierCall(unit, 'studyRangeForUniqueText'), isTrue);
      expect(
        containsIdentifier(unit, '_chapterIndexForText'),
        isFalse,
        reason: '逐句调用，不许每句解析全书章节 HTML',
      );
    });

    test('当前句与歌词层高亮同源', () {
      final String cue = methodBody(src, '  AudioCue? _lyricsReadingCue(');
      expect(containsIdentifier(cue, 'lyricsCueAllBookIdx'), isTrue);
      final String position = methodBody(
        src,
        '  _readingPositionFromCurrentCue() {',
      );
      expect(containsIdentifierCall(position, '_lyricsReadingCue'), isTrue);
    });

    test('进歌词：结算正文页、脱开正文面、当前句成为第一个单元', () {
      final String body = methodBody(src, '  Future<void> _toggleLyricsMode()');
      final int entering = body.indexOf(
        'if (entering) {',
        body.indexOf('try {'),
      );
      final int exiting = body.indexOf('} else {', entering);
      expect(entering, greaterThan(0));
      expect(exiting, greaterThan(entering));
      final String enter = body.substring(entering, exiting);
      final int leave = enter.indexOf('_readLedger.leave();');
      final int detach = enter.indexOf('setReaderDetached(true);');
      final int on = enter.indexOf('_rebuild(() => _lyricsMode = true);');
      final int settle = enter.indexOf('_settleLyricsCue(');
      expect(leave, greaterThan(0), reason: '离开正文页那一刻结算它');
      expect(detach, greaterThan(leave));
      expect(on, greaterThan(detach));
      expect(settle, greaterThan(on), reason: '位置归属翻转之后再落定当前句');
      expect(
        containsIdentifierCall(enter, '_useWholeBookCuesForLyrics'),
        isTrue,
        reason: '按章装 cue 的书：正文不再换章，控制器当前句改在整书 cue 上解析',
      );
    });

    test('出歌词：离开当前句、撤销脱开、把正文一次性对齐到当前句', () {
      final String exit = methodBody(src, '  Future<void> _exitLyricsMode()');
      final int leave = exit.indexOf('_readLedger.leave();');
      final int nav = exit.indexOf('_navigateToChapterAndWait(');
      final int reattachAfterNav = exit.indexOf(
        'ctrl.setReaderDetached(_lyricsMode && mounted);',
      );
      final int attach = exit.indexOf('ctrl.setReaderDetached(false);');
      final int reveal = exit.indexOf('AudiobookBridge.highlight(');
      expect(leave, greaterThan(0));
      expect(nav, greaterThan(leave), reason: '跨章：按学习单位锚落到那一句');
      expect(
        reattachAfterNav,
        greaterThan(nav),
        reason: '脱开保持到导航落定：先接回的话控制器下一个 tick 会再发一次同目标跨章',
      );
      expect(exit.indexOf('finally', nav), lessThan(reattachAfterNav));
      expect(attach, greaterThan(reattachAfterNav));
      expect(reveal, greaterThan(attach), reason: '同章：接回后把当前句 reveal 一次');
      expect(
        containsIdentifierCall(exit, '_primeAudioCuesForCurrentBook'),
        isTrue,
        reason: '同章退出要把按章装的 cue 还给控制器',
      );
    });

    test('正文在歌词模式期间不采样、不落库、不跨章', () {
      expect(
        containsCodeLine(
          methodBody(src, '  Future<void> _refreshProgress()'),
          'if (_controller == null || _restoreInFlight || _lyricsMode) return;',
        ),
        isTrue,
        reason: '10s 轮询不看歌词态；不挡住的话正文旧页与当前句轮流 arrive',
      );
      expect(
        containsCodeLine(
          methodBody(src, '  void _handleReaderScroll()'),
          'lyricsMode: _lyricsMode,',
        ),
        isTrue,
      );
      final String cross = methodBody(
        src,
        '  Future<void> _handleCueCrossChapter(int newSection)',
      );
      expect(cross.indexOf('if (_lyricsMode ||'), greaterThan(0));
      final String flush = methodBody(
        src,
        '  Future<void> _syncAndFlushPosition()',
      );
      final int gate = flush.indexOf('if (_lyricsMode) {');
      expect(gate, greaterThan(0));
      expect(
        flush.indexOf('_syncPositionFromCurrentCue();'),
        greaterThan(gate),
      );
      expect(
        flush.indexOf('_syncPositionFromWebViewProgress()'),
        greaterThan(flush.indexOf('return;', gate)),
        reason: '歌词模式的存档来自当前句，不拿正文停着的那页去盖',
      );
      final String owns = src.substring(
        src.indexOf('  bool get _cueOwnsReadingPosition =>'),
        src.indexOf(';', src.indexOf('  bool get _cueOwnsReadingPosition =>')),
      );
      expect(owns, contains('_lyricsMode ||'));
    });

    test('歌词页上的手动翻看喂空闲门（与正文滚动回传同律）', () {
      final String note = methodBody(src, '  void _noteLyricsUserActivity()');
      expect(containsCodeLine(note, '_studyClock?.touch();'), isTrue);
      expect(
        'if (browsing) _noteLyricsUserActivity();'.allMatches(src),
        hasLength(1),
      );
    });

    test('章名 / 本章进度跟阅读位置走，不读正文停着的章', () {
      final String label = methodBody(src, '  String _currentChapterLabel()');
      expect(containsIdentifier(label, '_readingChapter'), isTrue);
      expect(containsIdentifier(label, '_currentChapter'), isFalse);
      expect(
        containsCodeLine(
          src,
          'int? get _footerChapterTotalChars => '
          '_progress.chapterTotal(_readingChapter);',
        ),
        isTrue,
      );
    });

    test('歌词页盖在正文之上，正文 WebView 不卸载（实例复用，BUG-3913）', () {
      final int body = src.indexOf('Positioned.fill(child: _buildBody()),');
      final int overlay = src.indexOf('_buildLyricsOverlay(),');
      final int dictionary = src.indexOf('buildDictionary(),', overlay);
      expect(body, greaterThan(0));
      expect(overlay, greaterThan(body), reason: '歌词页必须叠在正文之上');
      expect(dictionary, greaterThan(overlay), reason: '查词弹窗仍要盖在歌词页之上');
      final String buildBody = methodBody(src, '  Widget _buildBody()');
      expect(
        containsIdentifier(buildBody, '_lyricsMode'),
        isFalse,
        reason: '正文 WebView 的挂载与视口不随进出歌词变化（卸载重建会漏显存）',
      );
      final String webCreated = src.substring(
        src.indexOf('  Widget _buildWebView() {'),
        src.indexOf(
          "handlerName: 'onTextSelected'",
          src.indexOf('  Widget _buildWebView() {'),
        ),
      );
      expect(
        containsIdentifierCall(webCreated, '_loadLyricsPage'),
        isFalse,
        reason: '正文 WebView 永远装载正文章，歌词有自己的 WebView',
      );
    });
  });
}
