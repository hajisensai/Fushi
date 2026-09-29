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

  group('BUG-2597 歌词模式统计', () {
    test('_onCueChanged 歌词分支把当前句交给账本（_arriveLyricsCueUnit）', () {
      final String body = methodBody(src, '  void _onCueChanged()');
      final int lyrics = body.indexOf('if (_lyricsMode)');
      expect(lyrics, greaterThan(0));
      final String lyricsBranch = body.substring(
        lyrics,
        body.indexOf('return;', lyrics),
      );
      expect(
          containsIdentifierCall(lyricsBranch, '_arriveLyricsCueUnit'), isTrue,
          reason: '歌词模式没有滚动回传，cue 推进是它唯一的「翻走」信号');
    });

    test('_arriveLyricsCueUnit：只在播放态、按学习单位范围 arrive，映射不出不计', () {
      final String body = methodBody(
        src,
        '  void _arriveLyricsCueUnit(AudiobookPlayerController controller)',
      );
      expect(
          containsCodeLine(body, 'if (!controller.isPlaying) return;'), isTrue,
          reason: '暂停后重开 / 手动跳句的被动高亮不是「读到」');
      expect(containsIdentifierCall(body, '_studyUnitForLyricsCue'), isTrue);
      final String unit = methodBody(
        src,
        '  ({int chapter, int offset, int length})? _studyUnitForLyricsCue(',
      );
      expect(
          containsIdentifierCall(unit, '_studyRangeForAudioFragment'), isTrue,
          reason: '音频 UTF-16 坐标不能直接当学习单位用（BUG-2333）');
      expect(containsIdentifierCall(unit, 'studyRangeForUniqueText'), isTrue,
          reason: '独立 SRT / SMIL 的 cue 没有持久化坐标，按句文本唯一命中');
      expect(containsIdentifierCall(body, 'absoluteCharOffsetOf'), isTrue,
          reason: '账本坐标是全书绝对偏移');
      expect(containsCodeLine(body, '_readLedger.arrive(start, end)'), isTrue);
      expect(body.indexOf('_traceArrive('),
          lessThan(body.indexOf('_readLedger.arrive(')),
          reason: '与正文 arrive 同律：先记诊断流水再入账本');
    });

    test('进歌词模式 leave() 正文当前页（与 _beginNavigation 对称）', () {
      final String body = methodBody(src, '  Future<void> _toggleLyricsMode()');
      final int entering =
          body.indexOf('if (entering) {', body.indexOf('try {'));
      final int exiting = body.indexOf('} else {', entering);
      expect(entering, greaterThan(0));
      expect(exiting, greaterThan(entering));
      expect(
        containsCodeLine(
            body.substring(entering, exiting), '_readLedger.leave();'),
        isTrue,
      );
    });

    test('歌词文档就绪时建/起阅读时钟（自动恢复歌词时 _onRestoreComplete 不会来）', () {
      final String body = methodBody(
        src,
        '  Future<void> _onChapterLoadComplete(',
      );
      final int ready = body.indexOf('_lyricsPageReady = true;');
      expect(ready, greaterThan(0));
      final String after =
          body.substring(ready, body.indexOf('return;', ready));
      expect(containsIdentifierCall(after, '_ensureStudyClock'), isTrue);
    });
  });
}
