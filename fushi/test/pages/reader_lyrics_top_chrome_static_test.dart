import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'reader_fushi_page_source_corpus.dart';

/// 歌词模式顶栏缺席回归的守卫。
///
/// 症状（用户报）：进歌词模式后顶栏整条不见，而且**没有任何回到阅读模式的入口**。
/// 根因：`_desktopChromeEnabled` 与底部状态行共用同一个 `!lyricsMode` 判据，歌词模式
/// 把「顶部工具栏 + 右侧抽屉」整套 chrome 一起关掉；而「切回阅读模式」的开关正住在
/// 这套 chrome 的设置抽屉里 —— 关掉顶栏等于把歌词模式关成一间没有门的房间。
///
/// 修复的三件事各有一条钉子：
///  * 顶栏在歌词模式在场（本文件第一组）；
///  * 顶栏挂着一颗回正文的模式键，且在歌词模式强制 pinned（第二组）；
///  * 歌词文档给顶栏让位（第三组接线 + `reader_lyrics_progress_bottom_reserve_static_test`
///    里 `independentDocumentInsets` 的顶部留白行为断言）。
///
/// 端到端那一层在 `integration_test/reader_lyrics_mode_entry_itest.dart`：真 app 进歌词
/// 模式 → 唤出 chrome → 顶栏与模式键在场 → 按下去真能切回正文。
void main() {
  final String src = readReaderPageSource();

  /// 取 `bool get <name> =>` 到语句末尾 `;` 的初始化表达式。
  String getterExpression(String name) {
    final int start = src.indexOf('bool get $name =>');
    expect(start, greaterThanOrEqualTo(0), reason: '$name 必须仍是页面的 getter');
    final int end = maskComments(src).indexOf(';', start);
    expect(end, greaterThan(start));
    return src.substring(start, end);
  }

  group('顶栏在歌词模式在场', () {
    test('_desktopChromeEnabled 不再随 _lyricsMode 翻转', () {
      expect(
        getterExpression('_desktopChromeEnabled'),
        isNot(contains('_lyricsMode')),
        reason: '顶栏一旦跟着歌词模式关掉，歌词模式就没有返回 / 设置面，也没有回正文的入口',
      );
    });

    test('底部状态行仍留在歌词模式之外（进度在歌词模式不刷新，画出来是冻住的旧数）', () {
      expect(getterExpression('_statusFooterEnabled'), contains('_lyricsMode'));
    });

    test('并进播放条右端的状态文字跟状态行同真值，不跟整套 chrome', () {
      // 否则顶栏在歌词模式恢复在场会顺手把那批冻住的进度数字搬进播放条。
      expect(
        getterExpression('_playbackStatusInline'),
        contains('_statusFooterEnabled'),
      );
      expect(
        getterExpression('_separatePlaybackStatus'),
        contains('_statusFooterEnabled'),
      );
    });
  });

  group('顶栏上的模式键', () {
    // 顶栏按钮的动作真相源在 _readerControlAction（顶栏本体只按布局槽位取）。
    final String header = methodBody(
      src,
      '  ReaderHeaderAction _readerControlAction(ReaderControlItem item)',
    );
    final String render = methodBody(
      src,
      '  bool _shouldRenderReaderControl(ReaderControlItem item)',
    );

    test('歌词模式下顶栏有一颗回正文的键，且强制 pinned（窄窗不许折进溢出菜单）', () {
      expect(
        containsIdentifierCall(header, '_toggleLyricsMode'),
        isTrue,
        reason: '顶栏必须能切模式，这是歌词模式里唯一看得见的回正文入口',
      );
      expect(header, contains('pinned: lyrics'),
          reason: '折进 ⋮ 溢出菜单的入口对「顶栏上找不到回去的路」这个症状等于不存在');
      expect(header, contains("'fushi_reader_lyrics_mode_button'"),
          reason: '集成测试按 key 找这颗键');
    });

    test('导航 / 插图只在正文模式挂（歌词页翻章会把歌词文档换成 EPUB 章节）', () {
      final String navGroup = render.substring(
        render.indexOf('case ReaderControlItem.navigation:'),
        render.indexOf('case ReaderControlItem.audiobook:'),
      );
      expect(navGroup, contains('case ReaderControlItem.gallery:'));
      expect(navGroup, contains('return !_lyricsMode;'));
    });
  });

  group('歌词文档给顶栏让位', () {
    test('_buildBody 的顶部留白来自 _lyricsTopReserve', () {
      final String body = methodBody(src, '  Widget _buildBody()');
      expect(body, contains('topReserve: _lyricsTopReserve'));
    });

    test('_lyricsTopReserve 不含顶部进度预留（歌词模式不画那颗 pill）', () {
      final int start = src.indexOf('double get _lyricsTopReserve =>');
      expect(start, greaterThanOrEqualTo(0));
      final String expr =
          src.substring(start, maskComments(src).indexOf(';', start));
      expect(expr, contains('_stableTopInset'));
      expect(expr, contains('_desktopHeaderReserve'));
      expect(expr, isNot(contains('_topProgressReserve')),
          reason: '算进来就是在歌词首行上方留一条谁也不占的空带');
    });
  });
}
