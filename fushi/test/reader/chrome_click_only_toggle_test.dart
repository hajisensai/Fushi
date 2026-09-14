import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_chrome_controller.dart';

import '../pages/reader_fushi_page_source_corpus.dart';

/// 用户 2026-09-14：**悬浮控制栏只认点击**。
///
/// 三条同源的裁决，本文件把它们各钉一遍：
///  1. 鼠标移动不得让控制栏出现（EPUB 的两条 hover 腿、漫画的顶边热区全删，反向
///     守卫在 `reader_host_hover_lookup_test.dart` 与本文件的漫画组）；
///  2. 开与关都只由点击驱动——唤出后不再武装自动收起计时（VN 翻页是唯一例外，
///     那里「点空白」已被翻页占死，收起没有第二条手势通道）；
///  3. 移动端单击与桌面点击走同一台状态机（EPUB `_handleFloatingChromeReveal`
///     / 漫画 `_toggleFloatingChrome` 都是 toggle，不分平台）。
void main() {
  group('ReaderChromeController：点出来的栏不会自己消失', () {
    test('showTransient 不武装自动收起', () {
      final ReaderChromeController c = ReaderChromeController();
      addTearDown(c.dispose);
      c.showTransient();
      expect(c.transientVisible, isTrue);
      expect(
        c.autoHideArmed,
        isFalse,
        reason: '点一下唤出的栏必须留着，只有下一次点击能关掉它',
      );
    });

    test('showTransient 会停掉上一轮（VN 翻页）武装的计时', () {
      final ReaderChromeController c = ReaderChromeController();
      addTearDown(c.dispose);
      c.reveal(const Duration(seconds: 3));
      expect(c.autoHideArmed, isTrue);
      c.hideTransient();
      c.showTransient();
      expect(c.transientVisible, isTrue);
      expect(
        c.autoHideArmed,
        isFalse,
        reason: '旧计时不停掉，就会把刚点出来的栏收走',
      );
    });

    test('reveal 仍为 VN 路径保留自动收起', () {
      final ReaderChromeController c = ReaderChromeController();
      addTearDown(c.dispose);
      c.reveal(const Duration(seconds: 3));
      expect(c.transientVisible, isTrue);
      expect(c.autoHideArmed, isTrue);
    });
  });

  group('EPUB 阅读器源码守卫', () {
    late final String src = readReaderPageSource();

    test('_handleFloatingChromeReveal 是纯 toggle、不武装计时', () {
      final int start = src.indexOf('bool _handleFloatingChromeReveal() {');
      expect(start, isNot(-1));
      final String body = src.substring(
        start,
        src.indexOf('\n  }', start) + 4,
      );
      expect(
        body.contains('_armChromeAutoHide'),
        isFalse,
        reason: '点击唤出后不得再起计时——那是「非点击的关」',
      );
      expect(
        body.contains('_chromeTransientVisible = !_chromeTransientVisible'),
        isTrue,
        reason: '开与关是同一下点击的两个方向',
      );
    });

    test('自动收起只剩 VN 推进一个武装点', () {
      expect(
        '_armChromeAutoHide()'.allMatches(src).length,
        2,
        reason: '只该剩「方法自身的定义」+「VN 推进那一次调用」。VN 空白点被翻页'
            '占死，是唯一还需要计时收起的路径；多出来的武装点意味着某条路又能'
            '不点击就关栏',
      );
      final int start = src.indexOf('void _revealFloatingChromeForVnAdvance()');
      expect(start, isNot(-1));
      expect(
        src.substring(start, src.indexOf('\n  }', start)).contains(
              '_armChromeAutoHide()',
            ),
        isTrue,
      );
    });
  });

  group('漫画阅读器源码守卫', () {
    late final String page = File(
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    ).readAsStringSync();
    late final String chrome = File(
      'lib/src/media/manga/reader/manga_reader_chrome.dart',
    ).readAsStringSync();

    test('顶边悬停热区与 hover 回调都不在场', () {
      for (final String symbol in <String>[
        'manga_hover_reveal_strip',
        'kReaderHoverRevealStripHeight',
        'onHoverChanged',
        '_onChromeHover',
      ]) {
        expect(page.contains(symbol), isFalse, reason: '$symbol 是 hover 唤出残留');
      }
      expect(chrome.contains('onHoverChanged'), isFalse);
      expect(
        chrome.contains('MouseRegion'),
        isFalse,
        reason: '顶栏不再关心鼠标进出——它既不因此出现，也不因此续命',
      );
    });

    test('空白点击是 toggle，且唤出不带自动收起', () {
      expect(page.contains('kMangaChromeAutoHide'), isFalse);
      expect(chrome.contains('kMangaChromeAutoHide'), isFalse);
      final int start = page.indexOf('void _toggleFloatingChrome() {');
      expect(start, isNot(-1));
      final String body = page.substring(start, page.indexOf('\n  }', start));
      expect(body.contains('_chrome.showTransient()'), isTrue);
      expect(body.contains('_chrome.hideTransient()'), isTrue);
      expect(body.contains('armAutoHide'), isFalse);
    });
  });

  group('有声书底栏源码守卫', () {
    late final String bar = File(
      'lib/src/media/audiobook/audiobook_play_bar.dart',
    ).readAsStringSync();

    test('±10 秒跳秒键已删除', () {
      for (final String symbol in <String>[
        'replay_10_outlined',
        'forward_10_outlined',
        'audiobook_back10',
        'audiobook_fwd10',
        'showSeekButtons',
      ]) {
        expect(bar.contains(symbol), isFalse, reason: '$symbol 是 ±10s 键的残留');
      }
    });
  });
}
