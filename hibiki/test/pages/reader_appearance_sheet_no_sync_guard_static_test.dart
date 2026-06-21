import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

void main() {
  // BUG-021: 阅读器底栏「调整」面板打开慢半拍。
  //
  // 根因：阅读器页面的 _settings 与 ReaderHibikiSource.readerSettings 是同一个
  // 对象（initState 里 `_settings = ReaderHibikiSource.readerSettings`，二者再无
  // 其它赋值点）。旧 TTU「全局 prefs ↔ profile prefs」双存储时代的
  // _syncSettingsToHive / _syncSettingsFromHive 现在退化成「把对象的值写回它自
  // 己」的死桥。其中 _syncSettingsToHive 走 ReaderHibikiSource.setTtu*，每个
  // setter 还会 onSettingsChangedLive?.call() → _applyStylesLive（17 次 DB 读 +
  // CSS 重生成 + WebView evaluateJavascript 往返 + setState）。点「调整」到面板
  // 出现之间，先空跑 17× 的 DB/WebView 风暴 = 慢半拍。
  //
  // 修复：删掉这两个死桥及其全部调用点（面板控件经
  // ReaderHibikiSource.instance.ttu* 实时读写同一对象，无需任何同步）。
  // 本守卫防止它们被重新引入。reader/WebView 类无法 widget 测真实 InAppWebView，
  // 源码扫描守卫为最强可落地层。
  final String source = readReaderPageSource();
  final String stripped = _stripLineComments(source);

  test(
      'dead settings self-copy bridge is gone (no sheet-open DB/WebView storm)',
      () {
    expect(
      stripped.contains('_syncSettingsToHive'),
      isFalse,
      reason: '_syncSettingsToHive 是写回自身的死桥，会在开「调整」面板前触发 '
          '17× setTtu* → onSettingsChangedLive → _applyStylesLive 风暴；勿重新引入',
    );
    expect(
      stripped.contains('_syncSettingsFromHive'),
      isFalse,
      reason: '_syncSettingsFromHive 同为写回自身的死桥（_settings === '
          'ReaderHibikiSource.readerSettings）；勿重新引入',
    );
  });

  test('_showAppearanceSheet does not re-persist settings before showing sheet',
      () {
    final String sheet = _functionSource(
      stripped,
      '  Future<void> _showAppearanceSheet() async',
      '  Future<void> _addBookmarkAtCurrentPosition() async',
    );
    expect(
      sheet.contains('.setTtu'),
      isFalse,
      reason: '面板用 ReaderHibikiSource.instance.ttu* 实时读 _settings；开面板前'
          '不得再经 setTtu* 写回（会触发 onSettingsChangedLive 的 DB/WebView 风暴）',
    );
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

String _stripLineComments(String source) {
  return source.split('\n').map((String line) {
    final int i = line.indexOf('//');
    return i >= 0 ? line.substring(0, i) : line;
  }).join('\n');
}
