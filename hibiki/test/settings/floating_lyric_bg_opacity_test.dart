import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_session.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-576: 悬浮歌词/字幕条「背景透明度」可调，且默认下调到 70（≈更不挡视野）。
///
/// 用户反馈：悬浮歌词条不透明度太高、挡视野。历史 TODO-370 只让「文字」与「按钮底色」
/// 可调，唯独没动条本身的背景（硬编码 `bg.withAlpha(230/220)` ≈ 90%/86% 不透明）。
/// 本任务新增 `floating_lyric_bg_opacity` 偏好（0..100%），缩放条背景 alpha，并把默认
/// 值定为 70，使「默认就更透」满足用户诉求，同时滑杆可继续微调。
HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  group('PreferencesRepository floatingLyricBgOpacity', () {
    late HibikiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('default is 70 (lowered so the bar blocks less of the view)', () {
      // 缺省必须 < 100：100 等于「保持历史观感（230/220 alpha）」=仍然挡视野，
      // 与用户诉求相悖。固定 70 防回退。
      expect(repo.floatingLyricBgOpacity, 70);
      expect(repo.floatingLyricBgOpacity, lessThan(100));
    });

    test('set/get round-trips and persists across reload', () async {
      await repo.setFloatingLyricBgOpacity(40);
      expect(repo.floatingLyricBgOpacity, 40);

      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.floatingLyricBgOpacity, 40);
    });

    test('clamps out-of-range to 0..100', () async {
      await repo.setFloatingLyricBgOpacity(250);
      expect(repo.floatingLyricBgOpacity, 100);
      await repo.setFloatingLyricBgOpacity(-30);
      expect(repo.floatingLyricBgOpacity, 0);
    });
  });

  group('scaleAlpha applied to the bar background', () {
    test('default 70% makes the bar background more transparent than before',
        () {
      // dark 基础背景 alpha = 230，light = 220（两处构造点一致）。70% 缩放后必须
      // 明显比原始更透（alpha 更小），证明「默认更不挡视野」。
      const int darkBase = 0xE6112233; // alpha 0xE6 = 230
      const int lightBase = 0xDC112233; // alpha 0xDC = 220
      final int darkScaled = FloatingLyricStyle.scaleAlpha(darkBase, 70);
      final int lightScaled = FloatingLyricStyle.scaleAlpha(lightBase, 70);

      int alphaOf(int argb) => (argb >> 24) & 0xFF;
      expect(alphaOf(darkScaled), lessThan(230));
      expect(alphaOf(lightScaled), lessThan(220));
      // 230 * 0.7 = 161 (0xA1); 220 * 0.7 = 154 (0x9A).
      expect(alphaOf(darkScaled), 161);
      expect(alphaOf(lightScaled), 154);
      // RGB 不变。
      expect(darkScaled & 0x00FFFFFF, 0x112233);
      expect(lightScaled & 0x00FFFFFF, 0x112233);
    });
  });

  group('source guards: bar background reads the bg-opacity preference', () {
    test('both floating-lyric style builders scale bgColor by bgOpacity', () {
      // app 级（无 reader）样式：app_model._appLevelFloatingLyricStyle。
      final String appModel =
          File('lib/src/models/app_model.dart').readAsStringSync();
      // reader 级样式：reader_hibiki_page._readerFloatingLyricStyle。
      final String reader =
          File('lib/src/pages/implementations/reader_hibiki_page.dart')
              .readAsStringSync();

      for (final String src in <String>[appModel, reader]) {
        // bgColor 不再裸用 `bg.withAlpha(...).value`，而是经 scaleAlpha 包一层
        // bgOpacity——否则背景透明度设置不生效（用户的根因缺口）。
        expect(
          RegExp(
            r'bgColor:\s*FloatingLyricStyle\.scaleAlpha\(\s*'
            r'bg\.withAlpha\(dark \? 230 : 220\)\.value,\s*'
            r'bgOpacity,',
          ).hasMatch(src),
          isTrue,
          reason: '悬浮条 bgColor 必须经 scaleAlpha(bgOpacity) 缩放，'
              '否则背景透明度设置不吃。',
        );
      }
    });

    test('settings schema exposes the bar background opacity stepper', () {
      final String schema =
          File('lib/src/settings/settings_schema.dart').readAsStringSync();
      expect(
        schema.contains("id: 'listening.floating_lyric_bg_opacity'"),
        isTrue,
      );
      expect(schema.contains('t.floating_lyric_bg_opacity'), isTrue);
      // 改值后立即重绘原生悬浮窗（与文字/按钮透明度一致）。
      expect(
        RegExp(
          r'setFloatingLyricBgOpacity\(value\.round\(\)\);[\s\S]*?'
          r'applyFloatingLyricStyle\(\)',
        ).hasMatch(schema),
        isTrue,
      );
    });
  });
}
