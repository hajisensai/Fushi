import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/app_model_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// host-apply 测试（BUG-471）：互联有声书进度 live 端点必须真读写 host 自己的
/// `audiobook_pos_<bookKey>` + `audiobook_pos_at_<bookKey>` prefs（修复根因：互联
/// 角色非对称，host 从不回灌自己的有声书位置 pref）。与视频 position host-apply 对称。
AppModelLibraryHostService _svc(HibikiDatabase db) =>
    AppModelLibraryHostService(
      db: db,
      dictionaryResourceRoot: Directory.systemTemp,
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );

/// host 库需先有该 bookKey 的 Audiobooks 行，putAudiobookPosition 的存在性闸门才
/// 放行（真实互联场景：syncContent / 有声书包同步先把它推成 host 有声书）。
Future<void> _seedHostAudiobook(HibikiDatabase db, String bookKey) =>
    db.upsertAudiobook(AudiobooksCompanion.insert(
      bookKey: bookKey,
      alignmentFormat: 'srt',
      alignmentPath: '/tmp/$bookKey.srt',
    ));

void main() {
  late HibikiDatabase db;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('resolveAudiobookPositionSync 纯函数', () {
    test('remote 时间戳更新 → 取 remote', () {
      final ({int positionMs, int updatedAtMs}) w =
          resolveAudiobookPositionSync(
        localPositionMs: 1000,
        localUpdatedAtMs: 10,
        remotePositionMs: 5000,
        remoteUpdatedAtMs: 20,
      );
      expect(w.positionMs, 5000);
      expect(w.updatedAtMs, 20);
    });

    test('local 时间戳更新 → 取 local', () {
      final ({int positionMs, int updatedAtMs}) w =
          resolveAudiobookPositionSync(
        localPositionMs: 9000,
        localUpdatedAtMs: 99,
        remotePositionMs: 1,
        remoteUpdatedAtMs: 1,
      );
      expect(w.positionMs, 9000);
      expect(w.updatedAtMs, 99);
    });

    test('时间戳相等 → 取较大位置（听得更远者胜）', () {
      final ({int positionMs, int updatedAtMs}) w =
          resolveAudiobookPositionSync(
        localPositionMs: 200,
        localUpdatedAtMs: 7,
        remotePositionMs: 800,
        remoteUpdatedAtMs: 7,
      );
      expect(w.positionMs, 800);
      expect(w.updatedAtMs, 7);
    });

    test('两侧都无时间戳（0）→ 取较大位置（旧数据降级）', () {
      final ({int positionMs, int updatedAtMs}) w =
          resolveAudiobookPositionSync(
        localPositionMs: 300,
        localUpdatedAtMs: 0,
        remotePositionMs: 0,
        remoteUpdatedAtMs: 0,
      );
      expect(w.positionMs, 300);
      expect(w.updatedAtMs, 0);
    });
  });

  group('getAudiobookPosition', () {
    test('host 无记录 → (0, 0)', () async {
      final AppModelLibraryHostService svc = _svc(db);
      final ({int positionMs, int updatedAtMs}) p =
          await svc.getAudiobookPosition('book/x');
      expect(p.positionMs, 0);
      expect(p.updatedAtMs, 0);
    });

    test('host 有 prefs → 返回真实位置 + 时间戳', () async {
      await db.setPrefTyped<int>(audiobookPositionPrefKey('book/a'), 42000);
      await db.setPrefTyped<int>(audiobookPositionAtPrefKey('book/a'), 9999);
      final AppModelLibraryHostService svc = _svc(db);
      final ({int positionMs, int updatedAtMs}) p =
          await svc.getAudiobookPosition('book/a');
      expect(p.positionMs, 42000);
      expect(p.updatedAtMs, 9999);
    });

    test('旧数据只有位置无时间戳 → 时间戳记 0（降级）', () async {
      await db.setPrefTyped<int>(audiobookPositionPrefKey('book/old'), 12345);
      final AppModelLibraryHostService svc = _svc(db);
      final ({int positionMs, int updatedAtMs}) p =
          await svc.getAudiobookPosition('book/old');
      expect(p.positionMs, 12345);
      expect(p.updatedAtMs, 0);
    });
  });

  group('putAudiobookPosition（host-apply：真写 prefs）', () {
    test('PUT 新进度 → host prefs 真更新（GET 拉回一致）', () async {
      await _seedHostAudiobook(db, 'book/b');
      final AppModelLibraryHostService svc = _svc(db);
      await svc.putAudiobookPosition('book/b', 55000, 3000);

      // 直查 prefs：真写（这正是旧路径缺失的——host 从不回灌有声书位置 pref）。
      expect(await db.getPrefTyped<int>(audiobookPositionPrefKey('book/b'), 0),
          55000);
      expect(
          await db.getPrefTyped<int>(audiobookPositionAtPrefKey('book/b'), 0),
          3000);

      final ({int positionMs, int updatedAtMs}) got =
          await svc.getAudiobookPosition('book/b');
      expect(got.positionMs, 55000);
      expect(got.updatedAtMs, 3000);
    });

    test('上报旧时间戳 → 不覆盖 host 已存新进度（取较新）', () async {
      await _seedHostAudiobook(db, 'book/c');
      await db.setPrefTyped<int>(audiobookPositionPrefKey('book/c'), 90000);
      await db.setPrefTyped<int>(audiobookPositionAtPrefKey('book/c'), 5000);
      final AppModelLibraryHostService svc = _svc(db);

      await svc.putAudiobookPosition('book/c', 100, 1000); // 更旧

      expect(await db.getPrefTyped<int>(audiobookPositionPrefKey('book/c'), 0),
          90000);
      expect(
          await db.getPrefTyped<int>(audiobookPositionAtPrefKey('book/c'), 0),
          5000);
    });

    test('上报新时间戳 → 覆盖 host 旧进度', () async {
      await _seedHostAudiobook(db, 'book/d');
      await db.setPrefTyped<int>(audiobookPositionPrefKey('book/d'), 100);
      await db.setPrefTyped<int>(audiobookPositionAtPrefKey('book/d'), 1000);
      final AppModelLibraryHostService svc = _svc(db);

      await svc.putAudiobookPosition('book/d', 66000, 8000); // 更新

      expect(await db.getPrefTyped<int>(audiobookPositionPrefKey('book/d'), 0),
          66000);
      expect(
          await db.getPrefTyped<int>(audiobookPositionAtPrefKey('book/d'), 0),
          8000);
    });

    test('负位置 clamp 到 0', () async {
      await _seedHostAudiobook(db, 'book/e');
      final AppModelLibraryHostService svc = _svc(db);
      await svc.putAudiobookPosition('book/e', -50, 1234);
      expect(await db.getPrefTyped<int>(audiobookPositionPrefKey('book/e'), -1),
          0);
    });

    test('host 库无该有声书 → PUT 被闸门挡掉（不写孤儿 pref）', () async {
      final AppModelLibraryHostService svc = _svc(db);
      await svc.putAudiobookPosition('book/orphan', 77000, 9000);

      // 闸门 no-op：未 seed Audiobooks 行 → 不写 pref（默认 0 表示未写）。
      expect(
          await db.getPrefTyped<int>(
              audiobookPositionPrefKey('book/orphan'), 0),
          0);
      expect(
          await db.getPrefTyped<int>(
              audiobookPositionAtPrefKey('book/orphan'), 0),
          0);

      final ({int positionMs, int updatedAtMs}) got =
          await svc.getAudiobookPosition('book/orphan');
      expect(got.positionMs, 0);
    });
  });

  group('audiobookKeyFromPositionPrefKey 反解', () {
    test('位置键反解出 bookKey', () {
      expect(audiobookKeyFromPositionPrefKey('audiobook_pos_book/x'), 'book/x');
    });
    test('时间戳键不被误当成 bookKey', () {
      expect(
          audiobookKeyFromPositionPrefKey('audiobook_pos_at_book/x'), isNull);
    });
    test('无关键返回 null', () {
      expect(
          audiobookKeyFromPositionPrefKey('video_remote_position_v'), isNull);
    });
  });
}
