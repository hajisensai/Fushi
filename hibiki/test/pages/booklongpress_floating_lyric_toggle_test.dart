import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫（TODO-160子d / BUG-227）：书架长按 EPUB 书籍菜单的 extraActions 含悬浮
/// 字幕开关入口，且切换调 setShowFloatingLyric 偏好（套设置页 no-reader 范式：
/// 书架无 reader/无 audiobook controller/无书内样式，只切偏好不启停 native
/// service）。host 跑不到 dialog 渲染与 Platform 分支，故源码扫描钉接线。
void main() {
  late String src;
  setUpAll(() {
    src = File(
      'lib/src/pages/implementations/reader_hibiki_history_page.dart',
    ).readAsStringSync();
  });

  test('extraActions 含悬浮字幕开关 label', () {
    expect(
      src.contains('floating_lyric_toggle_action'),
      isTrue,
      reason: '长按书籍菜单必须有悬浮字幕开关入口。',
    );
  });

  test('书架入口切换调 setShowFloatingLyric 偏好', () {
    expect(
      src.contains('_toggleFloatingLyricFromShelf'),
      isTrue,
      reason: '书架入口走专用切换方法。',
    );
    expect(
      src.contains('setShowFloatingLyric'),
      isTrue,
      reason: '书架入口套设置页范式：只切偏好。',
    );
  });

  test('入口门控 Android/Windows（与 isSupported 一致，不删现有入口）', () {
    expect(
      src.contains('Platform.isAndroid || Platform.isWindows'),
      isTrue,
      reason: '悬浮字幕仅 Android/Windows 支持。',
    );
  });
}
