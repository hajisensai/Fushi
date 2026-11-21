import 'dart:io';

import 'package:test/test.dart';

/// BUG-4945：阅读器侧板（导航 / 设置 / 有声书 / 统计）的构建路径不得依赖正文
/// WebView 的 `_controller`。
///
/// renderer 被系统杀掉时 `WebViewDeathGuard.flushBeforeRebuild` 会把 `_controller`
/// 置 null（reader_fushi_page.dart），已经打开的侧板随后经 ValueListenableBuilder
/// 重建；旧代码在 `_buildQuickSettingsSheet` 里写 `webViewController: _controller!`，
/// 直接抛 `Null check operator used on a null value`。该参数在小说阅读器里从未被
/// 使用（唯一消费者是一个空实现的 TTU 桥接调用），已整体删掉；本守卫防止侧板构建
/// 路径重新读回 controller。
void main() {
  final RegExp controllerRef = RegExp(
    r'(?<![A-Za-z0-9_])_controller(?![A-Za-z0-9_])',
  );

  test(
    'reader side-panel build path never reads the body WebView controller',
    () {
      final String source = File(
        'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
      ).readAsStringSync();

      final Map<String, String> regions = <String, String>{
        '_openReaderPanel builder': _region(
          source,
          'builder: (_) => ValueListenableBuilder<String>(',
          '_syncDictionaryTheme();',
        ),
        '_buildReaderPanelContent': _region(
          source,
          '  Widget _buildReaderPanelContent(',
          '  Future<void> _presentSideSheet({',
        ),
        '_buildQuickSettingsSheet': _region(
          source,
          '  Widget _buildQuickSettingsSheet({',
          '  ReaderLyricsCueSearch? _lyricsCueSearch()',
        ),
      };

      for (final MapEntry<String, String> e in regions.entries) {
        expect(
          controllerRef.hasMatch(e.value),
          isFalse,
          reason:
              '${e.key} must not read _controller: the renderer-death flush nulls '
              'it while the panel stays open and rebuilds (BUG-4945)',
        );
      }
    },
  );

  test('ReaderQuickSettingsSheet takes no InAppWebViewController', () {
    final String source = File(
      'lib/src/media/audiobook/reader_quick_settings_sheet.dart',
    ).readAsStringSync();
    expect(source, isNot(contains('InAppWebViewController')));
    expect(source, isNot(contains('webViewController')));
  });
}

String _region(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
