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
/// BUG-2597（用户报「歌词模式统计有问题」）：`_readLedger.arrive` 的唯一调用点
/// `_refreshProgress` 在歌词模式三处早返回，整段听书账本零推进，退出时结算的还是
/// 进歌词前那一页——听一小时字数 0。修复把「当前句」当阅读单元：播放态 cue 推进即
/// arrive，进歌词 `leave()` 正文页，歌词就绪补建时钟（自动恢复歌词时
/// `_onRestoreComplete` 可能永远不来）。
///
/// 端到端那层在 `integration_test/reader_lyrics_settings_and_chapter_nav_itest.dart`。
void main() {
  final String src = readReaderPageSource();

  group('BUG-2596 歌词模式跳章', () {
    test('_jumpToChapterAnchor 在歌词模式先分流到 _jumpToChapterInLyricsMode', () {
      final String body = methodBody(
        src,
        '  Future<void> _jumpToChapterAnchor(int index, String? fragment)',
      );
      final int gate = body.indexOf('if (_lyricsMode)');
      final int textNav = body.indexOf('_navigateToChapter(');
      expect(gate, greaterThan(0));
      expect(textNav, greaterThan(gate),
          reason: '歌词分流必须在任何正文导航之前——正文导航会把歌词文档换成 EPUB 章');
      expect(
          containsIdentifierCall(body, '_jumpToChapterInLyricsMode'), isTrue);
    });

    test('歌词模式跳章 = 音频定位到该章首句；没有 cue 的章才退回正文', () {
      final String body = methodBody(
        src,
        '  Future<void> _jumpToChapterInLyricsMode(int index)',
      );
      expect(containsIdentifierCall(body, '_firstCueOfSection'), isTrue,
          reason: '该章在全书 cue 里的首句，三种 cue 家族各走精确反查');
      expect(containsIdentifierCall(body, 'skipToCue'), isTrue);
      final String first = methodBody(
        src,
        '  AudioCue? _firstCueOfSection(int index)',
      );
      expect(containsIdentifierCall(first, 'sectionFirstCue'), isTrue,
          reason: 'fushi-cue:// 家族与有声书面板「章节」tab 同一口径');
      expect(containsIdentifier(first, '_srtChapterRanges'), isTrue,
          reason: '独立 SRT 书按分桶首句序号');
      expect(containsIdentifier(first, '_chapterIndexForText'), isFalse,
          reason: '不做文本模糊反查（每次解析全书章节 HTML，且定位错章比退回正文更糟）');
      final int seek = body.indexOf('skipToCue(');
      final int leave = body.indexOf('_toggleLyricsMode(');
      expect(leave, greaterThan(seek),
          reason: '有 cue 就定位并 return；只有没 cue 的章才退出歌词模式再正文跳章');
      expect(containsCodeLine(body, '_navigateToChapter(index, manual: true)'),
          isTrue);
    });

    test('导航抽屉在歌词模式不接书内搜索 / 字数跳转（歌词里没有落点）', () {
      final String sheet = methodBody(
        src,
        '  Widget _buildQuickSettingsSheet({',
      );
      expect(
          containsCodeLine(sheet, 'onJumpToCharOffset: _lyricsMode'), isTrue);
      expect(
        containsCodeLine(
            sheet, 'onSearchJump: _lyricsMode ? null : _jumpToSearchResult'),
        isTrue,
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
          gate, body.indexOf('}', body.indexOf('return;', gate)));
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

  // 2026-10-04 用户拍板（对齐 Niratan）：歌词模式是盖在阅读器上的**覆盖层**，
  // 阅读器在下面照常跟随音频翻页 / 高亮，统计（阅读账本字数、StudyClock 时长）由
  // 下面的阅读器承担，歌词层**不参与统计**。这取代了 BUG-2597 的「歌词单元入账」
  // （`_arriveLyricsCueUnit` / 进歌词 `leave()` / 歌词就绪建表），那三条守卫随之改写
  // 成下面的反向守卫。
  group('歌词覆盖层：统计由下面的阅读器承担', () {
    test('_onCueChanged 的歌词分支只同步歌词层，不 return、不碰账本', () {
      final String body = methodBody(src, '  void _onCueChanged()');
      final int lyrics = body.indexOf('if (_lyricsMode) {');
      expect(lyrics, greaterThan(0));
      final String lyricsBranch =
          body.substring(lyrics, body.indexOf('\n    }\n', lyrics));
      expect(containsIdentifierCall(lyricsBranch, '_syncLyricsOverlayCue'),
          isTrue);
      expect(lyricsBranch, isNot(contains('return;')),
          reason: '歌词分支早返回 = 正文停止跟随 = 统计归零');
      expect(lyricsBranch, isNot(contains('_readLedger')));
      // 正文跟随路径（翻页 / 高亮）在歌词分支之后照常执行。
      expect(body.indexOf('AudiobookBridge.highlight('), greaterThan(lyrics));
      final String code = maskComments(src);
      expect(code, isNot(contains('_arriveLyricsCueUnit')));
      expect(code, isNot(contains('_studyUnitForLyricsCue')));
    });

    test('歌词层同步与歌词文档就绪不写任何统计', () {
      for (final String sig in <String>[
        '  void _syncLyricsOverlayCue(',
        '  Future<void> _onLyricsDocumentReady(',
        '  Widget _buildLyricsOverlay()',
        '  Future<void> _exitLyricsMode()',
      ]) {
        final String body = methodBody(src, sig);
        for (final String banned in <String>[
          '_readLedger',
          '_ensureStudyClock',
          '_studyClock',
          '_flushReadingStats',
          '_traceArrive',
        ]) {
          expect(containsIdentifier(body, banned), isFalse,
              reason: '$sig 不得碰统计（$banned）——统计归正文');
        }
      }
      final String ready =
          methodBody(src, '  Future<void> _onLyricsDocumentReady(');
      expect(containsIdentifier(ready, '_readerContentReady'), isFalse,
          reason: '歌词就绪与正文就绪是两个 WebView 的事，互不相干');
    });

    test('进歌词不结算正文页、不换控制器 cue；正文在覆盖期间强制跟随', () {
      final String body = methodBody(src, '  Future<void> _toggleLyricsMode()');
      final int entering =
          body.indexOf('if (entering) {', body.indexOf('try {'));
      final int exiting = body.indexOf('} else {', entering);
      expect(entering, greaterThan(0));
      expect(exiting, greaterThan(entering));
      final String enter = body.substring(entering, exiting);
      expect(containsIdentifier(enter, '_readLedger'), isFalse);
      expect(containsIdentifierCall(enter, 'setChapterCues'), isFalse,
          reason: '正文仍按章跟随，控制器的章 cue 不能被整书 cue 顶掉');
      expect(containsCodeLine(enter, 'setReaderFollowOverride(true);'), isTrue,
          reason: '用户关了「跟随音频」时被盖住的正文也必须跟着走，否则字数为 0');
      final String exit = methodBody(src, '  Future<void> _exitLyricsMode()');
      expect(containsCodeLine(exit, 'ctrl.setReaderFollowOverride(false);'),
          isTrue);
    });

    test('正文进度采样 / 位置落库 / 跨章跟随不再按歌词态早返回', () {
      for (final String sig in <String>[
        '  Future<void> _refreshProgress()',
        '  Future<void> _syncPositionFromWebViewProgress()',
        '  Future<void> _handleCueCrossChapter(int newSection)',
        '  Future<void> _applyChromeInsets()',
      ]) {
        expect(containsIdentifier(methodBody(src, sig), '_lyricsMode'), isFalse,
            reason: '$sig 是正文自己的事，覆盖层在不在都要照常做');
      }
    });

    test('覆盖层盖在正文之上，正文 WebView 不卸载', () {
      final int body = src.indexOf('Positioned.fill(child: _buildBody()),');
      final int overlay = src.indexOf('_buildLyricsOverlay(),');
      final int dictionary = src.indexOf('buildDictionary(),', overlay);
      expect(body, greaterThan(0));
      expect(overlay, greaterThan(body), reason: '覆盖层必须叠在正文之上');
      expect(dictionary, greaterThan(overlay), reason: '查词弹窗仍要盖在歌词层之上');
      final String buildBody = methodBody(src, '  Widget _buildBody()');
      expect(containsIdentifier(buildBody, '_lyricsMode'), isFalse,
          reason: '正文 WebView 的挂载与视口不随进出歌词变化');
      final String webCreated = src.substring(
        src.indexOf('  Widget _buildWebView() {'),
        src.indexOf("handlerName: 'onTextSelected'",
            src.indexOf('  Widget _buildWebView() {')),
      );
      expect(containsIdentifierCall(webCreated, '_loadLyricsPage'), isFalse,
          reason: '正文 WebView 永远装载正文章，歌词有自己的 WebView');
    });
  });
}
