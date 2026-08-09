import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

void main() {
  Future<FushiDatabase> openV77Db() async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (CommonDatabase rawDb) {
          rawDb.execute('PRAGMA foreign_keys = ON');
          rawDb.execute('PRAGMA user_version = 77');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  test('v77→v78 creates the five durable pipeline tables and indexes',
      () async {
    final FushiDatabase db = await openV77Db();
    final int version =
        (await db.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version');
    expect(version, 78);

    final Set<String> tables = (await db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'table'",
            )
            .get())
        .map((row) => row.read<String>('name'))
        .toSet();
    expect(
      tables,
      containsAll(<String>{
        'video_download_jobs',
        'video_download_job_files',
        'video_download_job_subtitles',
        'video_download_subscriptions',
        'video_download_subscription_items',
      }),
    );

    final Set<String> indexes = (await db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'index'",
            )
            .get())
        .map((row) => row.read<String>('name'))
        .toSet();
    expect(
      indexes,
      containsAll(<String>{
        'idx_video_download_jobs_claim',
        'idx_video_download_jobs_fingerprint_torrent',
        'idx_video_download_job_files_job_status',
        'idx_video_download_job_subtitles_job_status',
        'idx_video_download_subscriptions_claim',
        'idx_video_download_subscription_items_state',
      }),
    );
  });

  test('v78 job schema persists only magnet locator and text backend profile',
      () async {
    final FushiDatabase db = await openV77Db();
    final Set<String> columns =
        (await db.customSelect('PRAGMA table_info(video_download_jobs)').get())
            .map((row) => row.read<String>('name'))
            .toSet();
    expect(columns, contains('magnet_uri'));
    expect(columns, contains('backend_profile_id'));
    expect(columns, isNot(contains('resource_uri')),
        reason: 'Torznab 临时 HTTP/metainfo URL 不能落库');
    expect(columns, isNot(contains('profile_id')),
        reason: '下载配置档不是用户 Profiles，不能建错 FK');

    final List<Map<String, Object?>> jobForeignKeys = (await db
            .customSelect('PRAGMA foreign_key_list(video_download_jobs)')
            .get())
        .map((row) => row.data)
        .toList();
    expect(
      jobForeignKeys.any((fk) => fk['table'] == 'profiles'),
      isFalse,
    );
  });

  test('v78 child ownership uses cascade and optional job links use setNull',
      () async {
    final FushiDatabase db = await openV77Db();

    final List<Map<String, Object?>> fileForeignKeys = (await db
            .customSelect(
              'PRAGMA foreign_key_list(video_download_job_files)',
            )
            .get())
        .map((row) => row.data)
        .toList();
    expect(
      fileForeignKeys,
      contains(predicate<Map<String, Object?>>((fk) =>
          fk['table'] == 'video_download_jobs' &&
          fk['on_delete'] == 'CASCADE')),
    );

    final List<Map<String, Object?>> subtitleForeignKeys = (await db
            .customSelect(
              'PRAGMA foreign_key_list(video_download_job_subtitles)',
            )
            .get())
        .map((row) => row.data)
        .toList();
    expect(
      subtitleForeignKeys,
      contains(predicate<Map<String, Object?>>((fk) =>
          fk['table'] == 'video_download_jobs' &&
          fk['on_delete'] == 'CASCADE')),
    );
    expect(
      subtitleForeignKeys,
      contains(predicate<Map<String, Object?>>((fk) =>
          fk['table'] == 'video_download_job_files' &&
          fk['on_delete'] == 'SET NULL')),
    );

    final List<Map<String, Object?>> itemForeignKeys = (await db
            .customSelect(
              'PRAGMA foreign_key_list(video_download_subscription_items)',
            )
            .get())
        .map((row) => row.data)
        .toList();
    expect(
      itemForeignKeys,
      contains(predicate<Map<String, Object?>>((fk) =>
          fk['table'] == 'video_download_subscriptions' &&
          fk['on_delete'] == 'CASCADE')),
    );
    expect(
      itemForeignKeys,
      contains(predicate<Map<String, Object?>>((fk) =>
          fk['table'] == 'video_download_jobs' &&
          fk['on_delete'] == 'SET NULL')),
    );
  });
}
