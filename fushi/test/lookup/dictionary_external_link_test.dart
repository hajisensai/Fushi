import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/dictionary_external_link.dart';
import 'package:url_launcher/url_launcher.dart';

/// BUG-2868 — 词典外链（Pixiv「pixivで読む」等）在 app 外查词窗 / galgame
/// 游戏内查词卡里点了没反应：popup.js 把 http(s) 链接交给 `openLink` 桥，
/// 只有 app 内弹窗注册了它，`GlobalLookupController._onJsMessage` 没有分支，
/// 消息被静默丢弃。
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  group('parseDictionaryExternalLink', () {
    test('Pixiv 文章链接（日文 / 空格路径）按 https 放行并百分号编码', () {
      final Uri? uri = parseDictionaryExternalLink(
        'https://dic.pixiv.net/a/ハニトー',
      );
      expect(uri, isNotNull);
      expect(uri!.host, 'dic.pixiv.net');
      expect(
        uri.toString(),
        'https://dic.pixiv.net/a/%E3%83%8F%E3%83%8B%E3%83%88%E3%83%BC',
      );
      expect(
        parseDictionaryExternalLink('https://dic.pixiv.net/a/ ルキア(QMA)'),
        isNotNull,
      );
      expect(
        parseDictionaryExternalLink('  HTTP://Example.com/x  '),
        isNotNull,
      );
    });

    test('非 http(s) / 无 host / 词典内部交叉引用一律拒绝', () {
      for (final String raw in <String>[
        'javascript:alert(1)',
        'file:///C:/Windows/System32/calc.exe',
        'ms-settings:privacy',
        '?query=ハニートースト',
        'entry://記念',
        'https://',
        '',
      ]) {
        expect(parseDictionaryExternalLink(raw), isNull, reason: raw);
      }
    });
  });

  group('openDictionaryExternalLink', () {
    test('合法外链以 externalApplication 交给系统浏览器', () async {
      final List<(Uri, LaunchMode)> calls = <(Uri, LaunchMode)>[];
      final bool ok = await openDictionaryExternalLink(
        'https://dic.pixiv.net/a/ハニトー',
        launcher: (Uri uri, {LaunchMode mode = LaunchMode.platformDefault}) {
          calls.add((uri, mode));
          return Future<bool>.value(true);
        },
      );
      expect(ok, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.$1.host, 'dic.pixiv.net');
      expect(calls.single.$2, LaunchMode.externalApplication);
    });

    test('被拒的链接不调用 launcher；launcher 抛异常时返回 false 不外漏', () async {
      int launches = 0;
      Future<bool> counting(
        Uri uri, {
        LaunchMode mode = LaunchMode.platformDefault,
      }) {
        launches++;
        return Future<bool>.value(true);
      }

      expect(
        await openDictionaryExternalLink(
          'javascript:alert(1)',
          launcher: counting,
        ),
        isFalse,
      );
      expect(launches, 0);

      expect(
        await openDictionaryExternalLink(
          'https://dic.pixiv.net/a/x',
          launcher: (Uri uri, {LaunchMode mode = LaunchMode.platformDefault}) =>
              Future<bool>.error(StateError('no handler')),
        ),
        isFalse,
      );
    });
  });

  group('openLink 桥在每个宿主都有实现（BUG-2868 守卫）', () {
    test('popup.js 仍经 openLink 打开外链', () {
      expect(
        read('assets/popup/popup.js'),
        contains("callHandler('openLink', url)"),
      );
    });

    test('app 外查词窗（全局查词 / galgame 卡）处理 openLink 并走共享实现', () {
      final String src = read('lib/src/lookup/global_lookup_controller.dart');
      final int branch = src.indexOf("if (handler == 'openLink')");
      expect(
        branch,
        greaterThanOrEqualTo(0),
        reason: '_onJsMessage 缺 openLink 分支 → 外链点击被静默丢弃',
      );
      expect(
        src.substring(branch, branch + 400),
        contains('openDictionaryExternalLink('),
      );
    });

    test('app 内弹窗同样走共享实现，不再自带放行任意 scheme 的副本', () {
      final String src = read(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      );
      expect(src, contains("handlerName: 'openLink'"));
      expect(src, contains('openDictionaryExternalLink('));
      expect(src, isNot(contains('launchUrl(')));
    });
  });
}
