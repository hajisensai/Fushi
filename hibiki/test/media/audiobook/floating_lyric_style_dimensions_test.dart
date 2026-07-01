import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_session.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';
import '../../pages/reader_hibiki_page_source_corpus.dart';

// TODO-708 P2: 悬浮字幕「圆角半径」+「宽度」自定义，镜像现成透明度偏好链路。守卫：
//   1) FloatingLyricStyle 新增字段默认 0 = 平台原生观感（never-break userspace）；
//   2) 偏好读写往返 + 默认哨兵 0（不改动即零观感变化）+ 归一夹紧；
//   3) 两个样式构造点都把偏好读进 cornerRadius / windowWidth，设置页两条 stepper
//      + 改值即时 applyFloatingLyricStyle（与透明度那条一致）。
// 原生 applyStyle(GradientDrawable 圆角) / createLayoutParams(窗宽) / Windows Render
// 无法 bg 单测，靠这里守住值语义正确端到端传递（原生实机观感另需真机点验）。
HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  group('FloatingLyricStyle 新增尺寸字段默认 = 平台原生观感', () {
    test('cornerRadius / windowWidth 缺省构造默认 0（0=平台默认，零观感变化）', () {
      const FloatingLyricStyle style = FloatingLyricStyle(
        fontSize: 16,
        textColor: 0xFFFFFFFF,
        bgColor: 0xCC000000,
        buttonTextColor: 0xFFFFFFFF,
        buttonBgColor: 0x33000000,
        highlightColor: 0x80FFD54F,
        activeColor: 0xFFFFD54F,
      );
      expect(style.cornerRadius, 0,
          reason: '默认圆角 0 = Android 直角 / Windows 14dp 各自原生观感');
      expect(style.windowWidth, 0,
          reason: '默认宽 0 = Android MATCH_PARENT / Windows 720dip 各自默认');
    });

    test('显式尺寸如实保留，供 channel payload 透传给原生', () {
      const FloatingLyricStyle style = FloatingLyricStyle(
        fontSize: 16,
        textColor: 0xFFFFFFFF,
        bgColor: 0xCC000000,
        buttonTextColor: 0xFFFFFFFF,
        buttonBgColor: 0x33000000,
        highlightColor: 0x80FFD54F,
        activeColor: 0xFFFFD54F,
        cornerRadius: 20,
        windowWidth: 640,
      );
      expect(style.cornerRadius, 20);
      expect(style.windowWidth, 640);
    });
  });

  group('PreferencesRepository 圆角半径', () {
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

    test('默认哨兵 = 0（不改动即零观感变化）', () {
      expect(repo.floatingLyricCornerRadius, 0);
      expect(PreferencesRepository.floatingLyricCornerRadiusDefault, 0);
    });

    test('set/get 往返并跨 reload 持久化', () async {
      await repo.setFloatingLyricCornerRadius(20);
      expect(repo.floatingLyricCornerRadius, 20);

      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.floatingLyricCornerRadius, 20);
    });

    test('夹到 [0, 48]', () async {
      await repo.setFloatingLyricCornerRadius(-5);
      expect(repo.floatingLyricCornerRadius, 0);
      await repo.setFloatingLyricCornerRadius(100);
      expect(repo.floatingLyricCornerRadius, 48);
    });

    test('归一纯函数：负->0，正常保留，超上界->48', () {
      expect(PreferencesRepository.normalizeFloatingLyricCornerRadius(-5), 0);
      expect(PreferencesRepository.normalizeFloatingLyricCornerRadius(20), 20);
      expect(PreferencesRepository.normalizeFloatingLyricCornerRadius(100), 48);
    });
  });

  group('PreferencesRepository 宽度（0=自动哨兵）', () {
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

    test('默认哨兵 = 0（不改动即 MATCH_PARENT / 720dip 默认宽）', () {
      expect(repo.floatingLyricWidth, 0);
      expect(PreferencesRepository.floatingLyricWidthDefault, 0);
    });

    test('set/get 往返并跨 reload 持久化', () async {
      await repo.setFloatingLyricWidth(640);
      expect(repo.floatingLyricWidth, 640);

      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.floatingLyricWidth, 640);
    });

    test('0 与负数保持自动语义 0；正数夹到 [200, 1200]', () async {
      await repo.setFloatingLyricWidth(0);
      expect(repo.floatingLyricWidth, 0);
      await repo.setFloatingLyricWidth(-10);
      expect(repo.floatingLyricWidth, 0);
      await repo.setFloatingLyricWidth(50);
      expect(repo.floatingLyricWidth, 200);
      await repo.setFloatingLyricWidth(5000);
      expect(repo.floatingLyricWidth, 1200);
    });

    test('归一纯函数：0/负=0，1..199 上夹 200，超上界 1200', () {
      expect(PreferencesRepository.normalizeFloatingLyricWidth(0), 0);
      expect(PreferencesRepository.normalizeFloatingLyricWidth(-10), 0);
      expect(PreferencesRepository.normalizeFloatingLyricWidth(50), 200);
      expect(PreferencesRepository.normalizeFloatingLyricWidth(640), 640);
      expect(PreferencesRepository.normalizeFloatingLyricWidth(5000), 1200);
    });
  });

  group('source guards: 两个样式构造点都喂入圆角/宽度偏好', () {
    test('app 级 + reader 级样式都读圆角/宽度偏好', () {
      final String appModel =
          File('lib/src/models/app_model.dart').readAsStringSync();
      final String reader = readReaderPageSource();

      expect(
          appModel.contains('cornerRadius: floatingLyricCornerRadius'), isTrue,
          reason: 'app 级样式必须把圆角偏好喂进 FloatingLyricStyle.cornerRadius');
      expect(appModel.contains('windowWidth: floatingLyricWidth'), isTrue,
          reason: 'app 级样式必须把宽度偏好喂进 FloatingLyricStyle.windowWidth');
      expect(
          reader.contains('cornerRadius: appModel.floatingLyricCornerRadius'),
          isTrue,
          reason: 'reader 级样式必须把圆角偏好喂进 FloatingLyricStyle.cornerRadius');
      expect(
          reader.contains('windowWidth: appModel.floatingLyricWidth'), isTrue,
          reason: 'reader 级样式必须把宽度偏好喂进 FloatingLyricStyle.windowWidth');
    });

    test('channel show/updateStyle payload 带 cornerRadius / windowWidth', () {
      final String channel = File(
        'lib/src/media/audiobook/floating_lyric_channel.dart',
      ).readAsStringSync();
      expect("'cornerRadius': cornerRadius".allMatches(channel).length, 2);
      expect("'windowWidth': windowWidth".allMatches(channel).length, 2);
    });

    test('settings schema 暴露圆角 + 宽度两条 stepper 且改值即时重绘', () {
      final String schema =
          File('lib/src/settings/settings_schema_listening.dart')
              .readAsStringSync();
      expect(
        schema.contains("id: 'listening.floating_lyric_corner_radius'"),
        isTrue,
      );
      expect(
        schema.contains("id: 'listening.floating_lyric_width'"),
        isTrue,
      );
      expect(schema.contains('t.floating_lyric_corner_radius'), isTrue);
      expect(schema.contains('t.floating_lyric_width'), isTrue);
      expect(
        RegExp(
          r'setFloatingLyricCornerRadius\([\s\S]*?applyFloatingLyricStyle\(\)',
        ).hasMatch(schema),
        isTrue,
      );
      expect(
        RegExp(
          r'setFloatingLyricWidth\([\s\S]*?applyFloatingLyricStyle\(\)',
        ).hasMatch(schema),
        isTrue,
      );
    });
  });
}
