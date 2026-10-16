import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_style.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import '../pages/reader_fushi_page_source_corpus.dart';
import '../helpers/source_guard.dart';

/// TODO-576: 悬浮歌词/字幕条「背景透明度」可调，且默认下调到 70（≈更不挡视野）。
///
/// 用户反馈：悬浮歌词条不透明度太高、挡视野。历史 TODO-370 只让「文字」与「按钮底色」
/// 可调，唯独没动条本身的背景（硬编码 `bg.withAlpha(230/220)` ≈ 90%/86% 不透明）。
/// 本任务新增 `floating_lyric_bg_opacity` 偏好（0..100%），缩放条背景 alpha，并把默认
/// 值定为 70，使「默认就更透」满足用户诉求，同时滑杆可继续微调。
FushiDatabase _testDb() {
  return FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
}

void main() {
  group('PreferencesRepository floatingLyricBgOpacity', () {
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
    test(
      'default 70% makes the bar background more transparent than before',
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
      },
    );
  });

  group('source guards: bar background reads the bg-opacity preference', () {
    test(
      'both floating-lyric style builders go through buildFloatingLyricStyle',
      () {
        // app 级（无 reader）样式：app_model._appLevelFloatingLyricStyle。
        final String appModel = File(
          'lib/src/models/app_model.dart',
        ).readAsStringSync();
        // reader 级样式：reader_fushi_page._readerFloatingLyricStyle。
        final String reader = readReaderPageSource();

        // 两处都必须经同一个构造函数（它负责 scaleAlpha(bgOpacity)，见下面的行为
        // 测试）；任何一处另起炉灶自己拼 bgColor，背景透明度设置就会在那一处失效。
        for (final String src in <String>[appModel, reader]) {
          expect(src.contains('buildFloatingLyricStyle('), isTrue);
          expect(src.contains('floatingLyricStyleSettings('), isTrue);
        }
      },
    );

    test('buildFloatingLyricStyle scales the background by bgOpacity', () {
      final ColorScheme scheme = ColorScheme.fromSeed(seedColor: Colors.teal);
      FloatingLyricStyle build(int bgOpacity) => buildFloatingLyricStyle(
        theme: buildFushiThemeData(
          scheme: scheme,
          textTheme: const TextTheme(),
        ),
        settings: FloatingLyricStyleSettings(
          fontSize: 20,
          textOpacity: 100,
          buttonBgOpacity: 100,
          bgOpacity: bgOpacity,
          cornerRadius: 24,
          windowWidth: 0,
        ),
      );
      int alphaOf(int argb) => (argb >> 24) & 0xFF;
      expect(alphaOf(build(100).bgColor), 0xFF);
      expect(alphaOf(build(70).bgColor), (255 * 0.7).round());
      expect(alphaOf(build(0).bgColor), 0);
      // 跟随主题：底 = M3E surfaceContainerHigh。
      expect(
        build(100).bgColor & 0x00FFFFFF,
        scheme.surfaceContainerHigh.toARGB32() & 0x00FFFFFF,
      );
    });

    test('settings schema exposes the bar background opacity stepper', () {
      final String schema = File(
        'lib/src/settings/settings_schema_listening.dart',
      ).readAsStringSync();
      expect(
        schema.contains("id: 'listening.floating_lyric_bg_opacity'"),
        isTrue,
      );
      expect(schema.contains('t.floating_lyric_bg_opacity'), isTrue);
      // Scope the update contract to this setting; another opacity row must not
      // satisfy the native style refresh assertion by accident.
      final int start = schema.indexOf(
        "id: 'listening.floating_lyric_bg_opacity'",
      );
      final int end = schema.indexOf("id: '", start + 5);
      final String item = maskComments(schema.substring(start, end));
      // 改值后立即重绘原生悬浮窗（与文字/按钮透明度一致）：写偏好 → 经
      // _commitFloatingLyricStyle（内含 applyFloatingLyricStyle）。
      expect(item.contains('setFloatingLyricBgOpacity('), isTrue);
      String fnBody(String signature) {
        final int at = schema.indexOf(signature);
        expect(at, greaterThan(0), reason: '$signature must exist');
        // 顶层函数体收尾 = 行首 `}` 独占一行；只找 `\n}` 会停在命名参数表的
        // `\n}) {` 上，切出来的只有参数表。
        return schema.substring(at, schema.indexOf('\n}\n', at));
      }

      expect(
        fnBody(
          'Future<void> _commitFloatingLyricStyle(',
        ).contains('applyFloatingLyricStyle()'),
        isTrue,
      );
      expect(
        fnBody(
          'SettingsStepperItem _floatingLyricPercentItem(',
        ).contains('_commitFloatingLyricStyle('),
        isTrue,
      );
    });
  });
}
