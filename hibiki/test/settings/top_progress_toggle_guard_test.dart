import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema_reading.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-727 守卫：书籍阅读器顶部「阅读进度」百分比指示的显隐开关。
///
/// 锁住四层契约（不依赖真机 WebView）：
/// 1. 偏好默认 true（保持现状=Never break userspace）+ toggle 写穿 Drift；
/// 2. ReaderHibikiSource 双路径（readerSettings 优先 / getPreference 回退）；
/// 3. schema 项落在 behavior（阅读操作）组、order≥12（不撞 TODO-725 的 0..11）；
/// 4. 源码：reader 页 `_showTopProgress` 与门并入 showTopProgressBar，
///    且顶栏构建仍以 `_showTopProgress` 为唯一门控（关后顶栏 'hoshi_progress' 不渲染）。

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

/// 收集 behavior（阅读操作）组的 schema 项（按 group 聚合，零 harness 依赖；
/// 收集路径上 builder 形参 context 从不被解引用，与运行时一致）。
List<SettingsItem> _behaviorItems() {
  final List<SettingsItem> result = <SettingsItem>[];
  for (final SettingsSection section in buildReadingDestination().sections) {
    for (final SettingsItem item in section.items) {
      if (item.reader?.group == ReaderGroup.behavior) {
        result.add(item);
      }
    }
  }
  return result;
}

void main() {
  late HibikiDatabase db;

  setUp(() {
    db = _testDb();
    MediaSource.setDatabase(db);
    ReaderHibikiSource.readerSettings = null;
  });

  tearDown(() async {
    ReaderHibikiSource.readerSettings = null;
    await db.close();
  });

  test('顶部进度开关默认 true（保持现状）', () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    expect(settings.showTopProgressBar, isTrue);
    expect(ReaderHibikiSource.instance.showTopProgressBar, isTrue);
  });

  test('toggle 经 ReaderSettings 写穿 Drift（往返 + DB key）', () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.toggleShowTopProgressBar();

    expect(settings.showTopProgressBar, isFalse);

    final ReaderSettings restored = ReaderSettings(db);
    await restored.refreshFromDb();
    expect(restored.showTopProgressBar, isFalse, reason: '关闭后必须落盘并跨实例可见');

    // ReaderSettings 路径用 value.toString() 落盘（无类型前缀），与
    // ReaderHibikiSource.setPreference 的 PrefCodec('b:false') 编码不同，但
    // 同一 DB key；decode 端两者皆兼容（heuristic 读 'false'）。
    final Map<String, String> prefs = await db.getAllPrefs();
    expect(prefs['src:reader_ttu:show_top_progress_bar'], 'false',
        reason: 'key 实际落 src:reader_ttu:show_top_progress_bar');
  });

  test('ReaderHibikiSource 回退路径（无 readerSettings 时经 getPreference）', () async {
    // readerSettings == null → 走 getPreference 路径。
    expect(ReaderHibikiSource.instance.showTopProgressBar, isTrue,
        reason: '回退路径默认 true');

    ReaderHibikiSource.instance.toggleShowTopProgressBar();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final Map<String, String> prefs = await db.getAllPrefs();
    expect(prefs['src:reader_ttu:show_top_progress_bar'], 'b:false',
        reason: '回退 toggle 也必须写穿同一 DB key');
    expect(ReaderHibikiSource.instance.showTopProgressBar, isFalse);
  });

  test('schema 项存在、落 behavior 组、order≥12（不撞 TODO-725 的 0..11）', () {
    final List<SettingsItem> items = _behaviorItems();
    final SettingsItem? item = items.cast<SettingsItem?>().firstWhere(
          (SettingsItem? i) =>
              i!.id == 'reading_controls.show_top_progress_bar',
          orElse: () => null,
        );
    expect(item, isNotNull,
        reason: 'behavior 组应含 reading_controls.show_top_progress_bar');

    final int order = item!.reader!.order;
    expect(order, greaterThanOrEqualTo(12),
        reason: 'order 必须 ≥12，落在 TODO-725 收敛的 0..11 之外，避免撞号');

    // 组内不与现有任何 order 撞号。
    final List<int> others = items
        .where((SettingsItem i) =>
            i.id != 'reading_controls.show_top_progress_bar')
        .map((SettingsItem i) => i.reader!.order)
        .toList();
    expect(others, isNot(contains(order)),
        reason: 'behavior 组 order 不得撞号：others=$others new=$order');
  });

  test('源码：_showTopProgress 与门并入 showTopProgressBar（关后顶栏隐藏）', () {
    final String page = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();

    // _showTopProgress getter 末尾必须并入开关，否则关后顶栏仍显（违反需求）。
    expect(
      page.contains('bool get _showTopProgress =>') &&
          page.contains('ReaderHibikiSource.instance.showTopProgressBar'),
      isTrue,
      reason:
          '_showTopProgress 必须并入 ReaderHibikiSource.instance.showTopProgressBar',
    );

    // 顶栏构建仍以 _showTopProgress 为唯一门控（单点收口）。
    final String chrome = File(
      'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
    ).readAsStringSync();
    expect(chrome.contains("ValueKey<String>('hoshi_progress')"), isTrue,
        reason: '顶栏文本 key 仍为 hoshi_progress');
    // TODO-975：顶栏门控收敛进 _topProgressShouldPaint（挤压恒随 _showTopProgress、
    // 悬浮再加 transient 旗），关进度仍隐藏（topProgressVisible 在 showTopProgress=false
    // 返 false）；不变式不退回。
    expect(chrome.contains('!_topProgressShouldPaint'), isTrue,
        reason:
            '_buildTopProgressBar 由 _topProgressShouldPaint 门控（含 _showTopProgress）');
    final String pageSrc = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();
    expect(
      pageSrc.contains('_topProgressShouldPaint => topProgressVisible(') &&
          pageSrc.contains('showTopProgress: _showTopProgress'),
      isTrue,
      reason: '_topProgressShouldPaint 必须以 _showTopProgress 为基（关进度即隐藏）',
    );
  });
}
