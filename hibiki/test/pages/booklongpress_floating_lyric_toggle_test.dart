import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫（TODO-160子d / BUG-227 / TODO-291 阶段2）：书架长按 EPUB 书籍菜单的 extraActions
/// 含悬浮字幕入口。TODO-291 阶段2 把该入口从「只切 setShowFloatingLyric 偏好」升级为
/// 「启动该书的后台听书会话」（无正在播用该书启动 + 拉悬浮窗；该书已是活动会话则停止），
/// 走 AppModel.startBackgroundListening / stopBackgroundListening。host 跑不到 dialog
/// 渲染与 Platform 分支，故源码扫描钉接线。
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

  test('书架入口启动/停止后台听书会话（TODO-291 阶段2）', () {
    expect(
      src.contains('_toggleFloatingLyricFromShelf'),
      isTrue,
      reason: '书架入口走专用切换方法。',
    );
    expect(
      src.contains('startBackgroundListening'),
      isTrue,
      reason: '书架入口必须启动该书的后台听书会话（不再只切偏好）。',
    );
    expect(
      src.contains('stopBackgroundListening'),
      isTrue,
      reason: '该书已是活动会话时入口必须能停止后台听书。',
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
