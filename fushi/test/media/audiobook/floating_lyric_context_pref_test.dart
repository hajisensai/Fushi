import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart'
    show FloatingLyricStyle;
import 'package:fushi/src/media/audiobook/floating_lyric_context.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_style.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/models/theme_notifier.dart';

// 悬浮字幕「同时显示句数」偏好 + 端到端接线守卫（取代 TODO-708 P4 的对称上下文 N）。
//   1) 两键都没写过默认 3 句；新键没写过、旧 N 写过（含 0）时按 2N+1 换算
//      （0 → 1 句，老用户观感不变）；
//   2) 读写往返 + 跨 reload 持久化 + 归一夹到 [0, 15]（0 = 按窗口高度自动）；
//   3) 句数 → 前后句分布（当前句居中、偶数下文多一句；自动档按平台）；
//   4) session/app_model/settings 各层把句数接对（源级守卫，原生渲染另需真机）。
FushiDatabase _testDb() {
  return FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
}

void main() {
  group('PreferencesRepository 同时显示句数', () {
    late FushiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('两个键都没写过：默认 3 句', () {
      expect(repo.floatingLyricVisibleLines, 3);
      expect(PreferencesRepository.floatingLyricVisibleLinesDefault, 3);
    });

    test('只写过旧上下文 N：按 2N+1 换算，老用户观感不变', () async {
      await repo.setFloatingLyricContextLines(2);
      expect(repo.floatingLyricVisibleLines, 5);
    });

    test('旧 N=0（旧默认 / 显式单行）按 2N+1 换成 1 句，不落新默认 3', () async {
      await repo.setFloatingLyricContextLines(0);
      expect(repo.floatingLyricVisibleLines, 1);

      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.floatingLyricVisibleLines, 1);
    });

    test('旧 N=1 / 3 分别换算成 3 / 7 句', () async {
      await repo.setFloatingLyricContextLines(1);
      expect(repo.floatingLyricVisibleLines, 3);
      await repo.setFloatingLyricContextLines(3);
      expect(repo.floatingLyricVisibleLines, 7);
    });

    test('新键优先于旧 N，并跨 reload 持久化', () async {
      await repo.setFloatingLyricContextLines(3);
      await repo.setFloatingLyricVisibleLines(1);
      expect(repo.floatingLyricVisibleLines, 1);

      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.floatingLyricVisibleLines, 1);
    });

    test('夹到 [0, 15]，0 = 自动', () async {
      await repo.setFloatingLyricVisibleLines(-1);
      expect(repo.floatingLyricVisibleLines, 0);
      await repo.setFloatingLyricVisibleLines(99);
      expect(repo.floatingLyricVisibleLines, 15);
      await repo.setFloatingLyricVisibleLines(
        PreferencesRepository.floatingLyricVisibleLinesAuto,
      );
      expect(repo.floatingLyricVisibleLines, 0);
    });
  });

  group('PreferencesRepository 悬浮字幕颜色 / 粗体', () {
    late FushiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('没写过颜色 = 跟随主题哨兵，且哨兵不在合法 ARGB 区间内', () {
      for (final FloatingLyricColorRole role in FloatingLyricColorRole.values) {
        expect(
          repo.floatingLyricColor(role),
          PreferencesRepository.floatingLyricColorFollowTheme,
        );
      }
      expect(PreferencesRepository.floatingLyricColorFollowTheme, isNegative);
    });

    test('完全透明黑（ARGB 0）是自选色，不被当成跟随主题', () async {
      await repo.setFloatingLyricColor(FloatingLyricColorRole.outline, 0);
      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.floatingLyricColor(FloatingLyricColorRole.outline), 0);

      final FloatingLyricStyleSettings settings =
          FloatingLyricStyleSettings.fromPreferences(reloaded);
      expect(settings.customColor(FloatingLyricColorRole.outline), 0);
      expect(settings.customColor(FloatingLyricColorRole.text), isNull);

      final FloatingLyricStyle style = buildFloatingLyricStyle(
        theme: buildFushiThemeData(
          scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
          textTheme: const TextTheme(),
        ),
        settings: settings,
      );
      expect(style.outlineColor, 0);
    });

    test('写回跟随主题哨兵 = 回到主题配对色', () async {
      await repo.setFloatingLyricColor(FloatingLyricColorRole.text, 0xFF123456);
      await repo.setFloatingLyricColor(
        FloatingLyricColorRole.text,
        PreferencesRepository.floatingLyricColorFollowTheme,
      );
      final FloatingLyricStyleSettings settings =
          FloatingLyricStyleSettings.fromPreferences(repo);
      expect(settings.customColor(FloatingLyricColorRole.text), isNull);
    });

    test('粗体：没写过默认 true，类型不符回退 true，写 false 生效', () async {
      expect(repo.floatingLyricBold, isTrue);
      await repo.setPref('floating_lyric_bold', 'garbage');
      expect(repo.floatingLyricBold, isTrue);
      await repo.setFloatingLyricBold(false);
      expect(repo.floatingLyricBold, isFalse);
    });
  });

  group('floatingLyricVisibleSpan：句数 → 前后句', () {
    test('1 句 = 只当前句（走单行 payload）', () {
      expect(floatingLyricVisibleSpan(1, autoFillsWindow: true), (
        before: 0,
        after: 0,
      ));
    });

    test('奇数句当前句居中', () {
      expect(floatingLyricVisibleSpan(5, autoFillsWindow: true), (
        before: 2,
        after: 2,
      ));
    });

    test('偶数句下文多一句（往下读的方向）', () {
      expect(floatingLyricVisibleSpan(4, autoFillsWindow: true), (
        before: 1,
        after: 2,
      ));
    });

    test('自动：Windows 前后各送 autoRadius 句，交给原生按窗高裁', () {
      expect(
        floatingLyricVisibleSpan(0, autoFillsWindow: true, autoRadius: 12),
        (before: 12, after: 12),
      );
    });

    test('自动：没有可裁视口的平台（Android）退回 3 句', () {
      expect(floatingLyricVisibleSpan(0, autoFillsWindow: false), (
        before: 1,
        after: 1,
      ));
    });
  });

  group('source guards: 句数各层接线', () {
    test('app_model 委托 getter/setter + session 注入闭包', () {
      final String appModel = File(
        'lib/src/models/app_model.dart',
      ).readAsStringSync();
      expect(
        appModel.contains(
          'int get floatingLyricVisibleLines => prefsRepo.floatingLyricVisibleLines',
        ),
        isTrue,
      );
      expect(
        appModel.contains(
          'floatingLyricVisibleLines: () => floatingLyricVisibleLines',
        ),
        isTrue,
        reason: 'AudiobookSession 构造必须注入句数闭包',
      );
    });

    test('session _syncFloatingLyric：单句走原单行分支，多句组装块', () {
      final String session = File(
        'lib/src/media/audiobook/audiobook_session.dart',
      ).readAsStringSync();
      expect(session.contains('_floatingLyricVisibleLines()'), isTrue);
      expect(session.contains('floatingLyricVisibleSpan('), isTrue);
      expect(session.contains('buildFloatingLyricBlockRange('), isTrue);
      expect(session.contains('resyncFloatingLyricText'), isTrue);
      expect(
        session.contains("updateText(cue?.text ?? '')"),
        isTrue,
        reason: '单句必须保留无行标记的单行 updateText 分支',
      );
    });

    test('settings schema 暴露句数 stepper 且改值即时重推', () {
      final String schema = File(
        'lib/src/settings/settings_schema_listening.dart',
      ).readAsStringSync();
      expect(
        schema.contains("id: 'listening.floating_lyric_visible_lines'"),
        isTrue,
      );
      expect(schema.contains('t.floating_lyric_visible_lines'), isTrue);
      expect(
        RegExp(
          r'setFloatingLyricVisibleLines\([\s\S]*?resyncFloatingLyricText\(\)',
        ).hasMatch(schema),
        isTrue,
        reason: '改句数后必须调 resyncFloatingLyricText 即时重推',
      );
    });
  });
}
