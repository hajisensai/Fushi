import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

// TODO-708 P4: 悬浮字幕「上下文行数」偏好 + 端到端接线守卫。
//   1) 默认哨兵 0（= 只当前行 = 今天单行观感，never-break userspace）；
//   2) 读写往返 + 跨 reload 持久化 + 归一夹到 [0, 3]；
//   3) session/channel/app_model/settings 各层把 N 接对（源级守卫，原生渲染另需真机）。
HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  group('PreferencesRepository 上下文行数（对称单值，0=只当前行）', () {
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

    test('默认哨兵 = 0（不改动即单行观感）', () {
      expect(repo.floatingLyricContextLines, 0);
      expect(PreferencesRepository.floatingLyricContextLinesDefault, 0);
      expect(PreferencesRepository.floatingLyricContextLinesMax, 3);
    });

    test('set/get 往返并跨 reload 持久化', () async {
      await repo.setFloatingLyricContextLines(2);
      expect(repo.floatingLyricContextLines, 2);

      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.floatingLyricContextLines, 2);
    });

    test('夹到 [0, 3]', () async {
      await repo.setFloatingLyricContextLines(-1);
      expect(repo.floatingLyricContextLines, 0);
      await repo.setFloatingLyricContextLines(5);
      expect(repo.floatingLyricContextLines, 3);
    });

    test('归一纯函数：负->0，正常保留，超上界->3', () {
      expect(PreferencesRepository.normalizeFloatingLyricContextLines(-1), 0);
      expect(PreferencesRepository.normalizeFloatingLyricContextLines(0), 0);
      expect(PreferencesRepository.normalizeFloatingLyricContextLines(2), 2);
      expect(PreferencesRepository.normalizeFloatingLyricContextLines(5), 3);
    });
  });

  group('source guards: 上下文行数各层接线', () {
    test('app_model 委托 getter/setter + session 注入闭包', () {
      final String appModel =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(
        appModel.contains(
            'int get floatingLyricContextLines => prefsRepo.floatingLyricContextLines'),
        isTrue,
      );
      expect(
        appModel.contains(
            'floatingLyricContextLines: () => floatingLyricContextLines'),
        isTrue,
        reason: 'AudiobookSession 构造必须注入上下文行数闭包',
      );
    });

    test('session _syncFloatingLyric: N<=0 走单行原分支，N>0 组装块', () {
      final String session = File(
        'lib/src/media/audiobook/audiobook_session.dart',
      ).readAsStringSync();
      expect(session.contains('_floatingLyricContextLines()'), isTrue);
      expect(session.contains('buildFloatingLyricBlock('), isTrue);
      expect(session.contains('resyncFloatingLyricText'), isTrue);
      // N<=0 零变化分支：仍旧用裸 updateText(cue?.text ?? '')。
      expect(
        session.contains("updateText(cue?.text ?? '')"),
        isTrue,
        reason: 'N<=0 必须保留今天的单行 updateText 分支',
      );
    });

    test('settings schema 暴露上下文行数 stepper 且改值即时重推', () {
      final String schema =
          File('lib/src/settings/settings_schema_listening.dart')
              .readAsStringSync();
      expect(
        schema.contains("id: 'listening.floating_lyric_context_lines'"),
        isTrue,
      );
      expect(schema.contains('t.floating_lyric_context_lines'), isTrue);
      expect(
        RegExp(
          r'setFloatingLyricContextLines\([\s\S]*?resyncFloatingLyricText\(\)',
        ).hasMatch(schema),
        isTrue,
        reason: '改 N 后必须调 resyncFloatingLyricText 即时重推',
      );
    });
  });
}
