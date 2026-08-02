import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_subtitle_obscure_mode.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// BUG-1430：「切换字幕遮罩模式好卡」的三条成本守卫。
///
/// 遮蔽模式是播放中的高频快捷键（B / Shift+B / H / Shift+G / Shift+H），旧实现每按一次
/// 要付：① 两个 key 两次独立 sqlite 事务（Windows/WAL 实测中位 12.3ms vs 单事务 5.1ms）；
/// ② UI 更新排在整段落盘之后（纯白等——缓存在第一个 await 前就已是新值）；③ 一次全局
/// [AppModel] 广播，重建每个 watch `appProvider` 的 widget，含路由栈下方仍挂载的整棵
/// 首页/书架树。本测试把修复后的三条不变式钉死，防回潮。
HibikiDatabase _memDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

void main() {
  group('BUG-1430 ① 一个逻辑设置 = 一次事务、一次版本 bump', () {
    late HibikiDatabase db;

    setUp(() => db = _memDb());
    tearDown(() async => db.close());

    test('setPrefs 多键只 bump 一次版本（逐个 setPref 是每键一次）', () async {
      final int before =
          await db.getPref(HibikiDatabase.prefsVersionKey) == null
              ? 0
              : int.parse(
                  (await db.getPref(HibikiDatabase.prefsVersionKey))!
                      .replaceFirst('i:', ''),
                );

      await db.setPrefs(<String, String>{'k_a': 'b:true', 'k_b': 'b:false'});

      final int afterBatch = int.parse(
        (await db.getPref(HibikiDatabase.prefsVersionKey))!
            .replaceFirst('i:', ''),
      );
      expect(afterBatch, before + 1, reason: '两个 key 属同一个逻辑设置，版本是变更信号、不是每键计数');

      // 对照：逐个 setPref 写同样两个 key = 两次 bump（旧路径的成本）。
      await db.setPref('k_a', 'b:false');
      await db.setPref('k_b', 'b:true');
      final int afterSingles = int.parse(
        (await db.getPref(HibikiDatabase.prefsVersionKey))!
            .replaceFirst('i:', ''),
      );
      expect(afterSingles, afterBatch + 2);
    });

    test('setPrefs 两键都真落盘', () async {
      await db.setPrefs(<String, String>{'k_a': 'b:true', 'k_b': 'b:true'});
      expect(await db.getPref('k_a'), 'b:true');
      expect(await db.getPref('k_b'), 'b:true');
    });

    test('空 map 是 no-op，不 bump 版本', () async {
      await db.setPrefs(<String, String>{'seed': 'i:1'});
      final String? v1 = await db.getPref(HibikiDatabase.prefsVersionKey);
      await db.setPrefs(<String, String>{});
      expect(await db.getPref(HibikiDatabase.prefsVersionKey), v1);
    });
  });

  group('BUG-1430 ② UI 不等落盘：同步段就写穿内存缓存', () {
    late HibikiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _memDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });
    tearDown(() async => db.close());

    test('主字幕：落盘 Future 未 await，getter 已返回完整新三态', () async {
      final Future<void> pending =
          repo.setVideoSubtitleObscureMode(VideoSubtitleObscureMode.hide);

      // 关键不变式：视频页正是在这个时刻 setState 的。两个 key 必须**一起**已生效——
      // 若只写了 blur 键就让出执行权，这里会读成 blur，画面先闪一下模糊再变隐藏。
      expect(repo.videoSubtitleObscureMode, VideoSubtitleObscureMode.hide);

      await pending;
      expect(repo.videoSubtitleObscureMode, VideoSubtitleObscureMode.hide);
    });

    test('副字幕：同一不变式', () async {
      final Future<void> pending = repo
          .setVideoSecondarySubtitleObscureMode(VideoSubtitleObscureMode.hide);
      expect(repo.videoSecondarySubtitleObscureMode,
          VideoSubtitleObscureMode.hide);
      await pending;
    });

    test('三态往返仍跨 reload 持久化（落盘没被跳过）', () async {
      await repo.setVideoSubtitleObscureMode(VideoSubtitleObscureMode.hide);
      await repo
          .setVideoSecondarySubtitleObscureMode(VideoSubtitleObscureMode.blur);

      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.videoSubtitleObscureMode, VideoSubtitleObscureMode.hide);
      expect(reloaded.videoSecondarySubtitleObscureMode,
          VideoSubtitleObscureMode.blur);
    });
  });

  group('BUG-1430 ③ 高频快捷键不触发全局广播', () {
    late HibikiDatabase db;
    late PreferencesRepository repo;
    late int notifications;

    setUp(() async {
      db = _memDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
      notifications = 0;
      repo.addListener(() => notifications++);
    });
    tearDown(() async => db.close());

    test('主/副遮蔽 setter 都不广播（视频页 setState / 面板 refresh 自己刷新）', () async {
      for (final VideoSubtitleObscureMode mode
          in VideoSubtitleObscureMode.values) {
        await repo.setVideoSubtitleObscureMode(mode);
        await repo.setVideoSecondarySubtitleObscureMode(mode);
      }
      expect(notifications, 0,
          reason: 'AppModel 把本仓库的通知转成全局广播，会重建每个 watch appProvider 的 widget');
    });

    test('对照：普通偏好 setter 仍广播（没有把整类行为改掉）', () async {
      await repo.setVideoSubtitleBlur(true);
      expect(notifications, 1);
    });
  });

  group('BUG-1430 接线守卫（源码扫描）', () {
    String readSrc(String path) => File(path).readAsStringSync();

    test('视频页：先 setState 再 await 落盘（两个遮蔽入口都是）', () {
      final String src =
          readSrc('lib/src/pages/implementations/video_hibiki_page.dart');
      for (final String setter in <String>[
        'appModel.setVideoSubtitleObscureMode(mode)',
        'appModel.setVideoSecondarySubtitleObscureMode(mode)',
      ]) {
        // 换行/缩进不敏感（dart format 会按行宽重排，CRLF 检出也不能让守卫失真）。
        final RegExp bound = RegExp(
          'final Future<void> persisted =\\s*${RegExp.escape(setter)};',
        );
        expect(bound.hasMatch(src), isTrue,
            reason: '$setter 的落盘 Future 必须先接住、setState 之后再 await');
      }
      // 回潮判据：`await appModel.setVideoS...ObscureMode(` 直接跟在 await 后即为旧写法。
      expect(
          src, isNot(contains('await appModel.setVideoSubtitleObscureMode(')));
      expect(
          src,
          isNot(contains(
              'await appModel.setVideoSecondarySubtitleObscureMode(')));
    });

    test('全局设置页路径显式补广播（host 缺席时行为不回归）', () {
      final String src =
          readSrc('lib/src/media/video/video_settings_actions.dart');
      expect(src, contains('context.appModel.notifyPreferencesChanged();'));
    });
  });
}
