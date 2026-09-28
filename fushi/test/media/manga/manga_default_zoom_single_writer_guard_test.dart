import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2754：「默认缩放」偏好（`manga_zoom_percent`）只能由设置项写。
///
/// 此前漫画页把捏合 / Ctrl+滚轮 / 双击 / 右键 ± 的会话缩放回写进这个偏好，
/// 笔记本触控板随手一捏就把 110% 钉成以后每本漫画的起始缩放，「适应屏幕」
/// 装不下整页（16:10 屏上下被裁）。守卫扫整棵 `lib/`：调用方只允许设置 schema。
void main() {
  test('setMangaZoomPercent 只由设置 schema 调用', () {
    final Directory lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: '须在 fushi/ 下运行');
    const Set<String> allowed = <String>{
      'lib/src/settings/settings_schema_manga.dart',
      // 定义与转发本身。
      'lib/src/models/app_model.dart',
      'lib/src/models/preferences_repository.dart',
    };
    final RegExp call = RegExp(r'setMangaZoomPercent\b');
    final List<String> offenders = <String>[];
    int scanned = 0;
    for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      scanned++;
      final String path = entity.path.replaceAll(r'\', '/');
      if (allowed.contains(path)) continue;
      if (call.hasMatch(entity.readAsStringSync())) offenders.add(path);
    }
    expect(scanned, greaterThan(100), reason: '扫描面不能是空的');
    expect(offenders, isEmpty);
  });

  test('漫画页的缩放回调不再持久化', () {
    final String page = File(
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    ).readAsStringSync();
    final int handler = page.indexOf("handlerName: 'onMangaZoomChanged'");
    expect(handler, greaterThan(0));
    final int next = page.indexOf('addJavaScriptHandler(', handler);
    final String body = page.substring(handler, next);
    expect(body, contains('_zoomPercent = normalized'));
    expect(body, isNot(contains('Persist')));
    expect(body, isNot(contains('setMangaZoomPercent')));
  });
}
