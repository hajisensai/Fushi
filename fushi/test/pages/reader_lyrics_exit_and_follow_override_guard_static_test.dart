import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 歌词覆盖层的两条生命周期不变式（源码守卫；阅读器整页依赖 WebView / DB，
/// pumpWidget 过重，沿用本目录 `reader_lyrics_*_static_test` 的源码切片范式）。
///
/// ① 退出不被歌词层截胡：阅读器 PopScope 在歌词层在场时把 pop 转成「关歌词层」，
///    这一级只该拦用户的系统返回手势。面板「退出」（chrome.part.dart 的
///    `onExitReader`）与重导入后正文作废（audiobook.part.dart 的 `bodyRebuilt`
///    分支）是**显式退书**：之前它们裸 `maybePop()`，歌词层在场时被截成关歌词层，
///    前者书不退出、后者留在解析树已作废的阅读器里。修法是两处都走
///    `_exitReaderBook()`，在 maybePop 在途期间挂 `_exitBookRequested`，PopScope
///    的歌词分支以 `!_exitBookRequested` 为门。
///
/// ② 强制跟随随歌词层一起撤：进歌词层时给（会话级、可能比页面活得久的）有声书
///    控制器挂 `setReaderFollowOverride(true)`。关歌词层撤了，但页面 dispose 没撤；
///    开后台播放时再开书，用户的「跟随音频=关」会被残留覆盖成强制跟随。
void main() {
  const String pagePath =
      'lib/src/pages/implementations/reader_fushi_page.dart';
  const String chromePath =
      'lib/src/pages/implementations/reader_fushi/chrome.part.dart';
  const String audiobookPath =
      'lib/src/pages/implementations/reader_fushi/audiobook.part.dart';
  const String lyricsPath =
      'lib/src/pages/implementations/reader_fushi/lyrics.part.dart';

  String read(String path) => File(path).readAsStringSync();

  /// 从 [startMarker] 起切到 [endMarker]（不含），任一锚不到就 fail。
  String slice(String source, String startMarker, String endMarker) {
    final int start = source.indexOf(startMarker);
    expect(start, greaterThanOrEqualTo(0), reason: '锚不到 `$startMarker`');
    final int end = source.indexOf(endMarker, start + startMarker.length);
    expect(end, greaterThan(start), reason: '锚不到终点 `$endMarker`');
    return source.substring(start, end);
  }

  group('① 显式退书绕过 PopScope 的歌词层拦截', () {
    test('PopScope 的歌词分支以 !_exitBookRequested 为门', () {
      final String popScope = slice(
        read(pagePath),
        'onPopInvokedWithResult:',
        'exitAfterPersist(',
      );
      expect(
        popScope.contains('if (_lyricsMode && !_exitBookRequested)'),
        isTrue,
        reason: '歌词层拦截不带退书旗标的门，面板「退出」等显式退书会被截成关歌词层',
      );
      expect(
        RegExp(r'if \(_lyricsMode\)\s*\{').hasMatch(popScope),
        isFalse,
        reason: '不许残留无门的 `if (_lyricsMode) {` 拦截',
      );
    });

    test('_exitReaderBook 挂旗 → maybePop → finally 撤旗', () {
      final String body = slice(
        read(chromePath),
        'Future<void> _exitReaderBook()',
        '\n  }\n',
      );
      final int raise = body.indexOf('_exitBookRequested = true');
      final int pop = body.indexOf('maybePop(');
      final int fin = body.indexOf('finally');
      final int lower = body.indexOf('_exitBookRequested = false');
      expect(raise, greaterThanOrEqualTo(0));
      expect(pop, greaterThan(raise), reason: '旗标必须在 maybePop 之前挂上');
      expect(fin, greaterThan(pop));
      expect(
        lower,
        greaterThan(fin),
        reason: '旗标必须在 finally 里撤，否则残留后系统返回会直接退书',
      );
    });

    test('面板「退出」走 _exitReaderBook', () {
      final String exit = slice(
        read(chromePath),
        'onExitReader:',
        'webViewController:',
      );
      expect(exit.contains('_exitReaderBook('), isTrue);
    });

    test('重导入正文作废分支走 _exitReaderBook', () {
      final String branch = slice(
        read(audiobookPath),
        'if (outcome.bodyRebuilt) {',
        'return;',
      );
      expect(branch.contains('_exitReaderBook('), isTrue);
      expect(
        branch.contains('maybePop('),
        isFalse,
        reason: '裸 maybePop 在歌词模式下会被 PopScope 截成关歌词层',
      );
    });
  });

  group('② 强制跟随随歌词层与页面一起撤', () {
    test('关歌词层撤 override', () {
      final String exitLyrics = slice(
        read(lyricsPath),
        'Future<void> _exitLyricsMode() async {',
        '\n  }\n',
      );
      expect(exitLyrics.contains('setReaderFollowOverride(false)'), isTrue);
    });

    test('dispose 在解绑控制器之前撤 override', () {
      final String dispose = slice(
        read(pagePath),
        'void dispose() {',
        '_syncChromePlaybackListener();',
      );
      final int revert = dispose.indexOf('setReaderFollowOverride(false)');
      final int unbind = dispose.indexOf('_audiobookController = null;');
      expect(revert, greaterThanOrEqualTo(0), reason: 'dispose 必须撤 override');
      expect(
        unbind,
        greaterThan(revert),
        reason: '撤 override 必须发生在 `_audiobookController = null` 之前',
      );
    });

    test('换接控制器时旧控制器撤、新控制器补挂', () {
      final String source = read(audiobookPath);
      expect(
        source.contains('if (_lyricsMode) old.setReaderFollowOverride(false);'),
        isTrue,
      );
      expect(
        '_reapplyLyricsFollowOverride();'.allMatches(source).length,
        greaterThanOrEqualTo(2),
        reason: '复用会话与起新会话两条 attach 路径都要补挂',
      );
    });
  });
}
