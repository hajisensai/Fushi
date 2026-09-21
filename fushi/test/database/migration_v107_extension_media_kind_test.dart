import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v107（视频在线源扩展）：`manga_extension_stores` / `manga_extensions` /
/// `manga_online_sources` 三表加 `media_kind`（`'manga'` | `'anime'`，默认漫画），
/// Aniyomi 视频扩展与 Mihon 漫画扩展共用三张表按它分片。存量行全是漫画，升级后
/// 默认值即历史事实；分片读只看本生态。
void main() {
  test(
    'v106 → v107 adds media_kind to the three extension tables with manga as default',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'extkind107',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = '${directory.path}/test.db';
      final FushiDatabase original = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(await original.getMangaExtensionStores(), isEmpty);
      await original.close();

      // 把三张表退回 v106 形态（没有 media_kind 列）并塞一行存量漫画数据。
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      for (final String table in <String>[
        'manga_extension_stores',
        'manga_extensions',
        'manga_online_sources',
      ]) {
        raw.execute('ALTER TABLE $table DROP COLUMN media_kind');
      }
      raw.execute(
        'INSERT INTO manga_extension_stores (index_url, name, format) '
        "VALUES ('https://repo.example/index.pb', 'Legacy', 'currentProtobuf')",
      );
      raw.execute(
        'INSERT INTO manga_extensions (package_name, name, version_code, '
        'version_name, lib_version, language, apk_path, apk_sha256, '
        "signer_sha256, installed_at) VALUES ('eu.kanade.tachiyomi.extension.ja.x', "
        "'X', 1, '1.4.1', '1.4', 'ja', 'extensions/x.apk', 'aa', 'bb', 1)",
      );
      raw.execute(
        'INSERT INTO manga_online_sources (extension_package, source_id, name, '
        "language) VALUES ('eu.kanade.tachiyomi.extension.ja.x', '1', 'X', 'ja')",
      );
      raw.execute('PRAGMA user_version = 106');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      addTearDown(migrated.close);
      expect(migrated.schemaVersion, 112);

      // 存量行默认成漫画，分片读按生态各取各的。
      final List<MangaExtensionStoreRow> mangaStores = await migrated
          .getMangaExtensionStores(mediaKind: 'manga');
      expect(mangaStores.single.mediaKind, 'manga');
      expect(
        await migrated.getMangaExtensionStores(mediaKind: 'anime'),
        isEmpty,
      );
      expect(
        (await migrated.getMangaExtensions(
          mediaKind: 'manga',
        )).single.mediaKind,
        'manga',
      );
      expect(
        (await migrated.getMangaOnlineSources(
          mediaKind: 'manga',
        )).single.mediaKind,
        'manga',
      );

      // 新生态的行写得进、读得出，并且不会漏进漫画那边。
      await migrated.upsertMangaExtension(
        MangaExtensionsCompanion.insert(
          packageName: 'eu.kanade.tachiyomi.animeextension.all.y',
          name: 'Y',
          versionCode: 9,
          versionName: '14.9',
          libVersion: '14',
          language: 'all',
          apkPath: 'extensions/y.apk',
          apkSha256: 'cc',
          signerSha256: 'dd',
          installedAt: 2,
          mediaKind: const Value('anime'),
        ),
      );
      expect(
        (await migrated.getMangaExtensions(
          mediaKind: 'anime',
        )).single.packageName,
        'eu.kanade.tachiyomi.animeextension.all.y',
      );
      expect((await migrated.getMangaExtensions(mediaKind: 'manga')).length, 1);
      expect((await migrated.getMangaExtensions()).length, 2);
    },
  );

  test(
    'a fresh database creates the columns and shards by media_kind',
    () async {
      final FushiDatabase fresh = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(fresh.close);
      await fresh.upsertMangaExtensionStore(
        MangaExtensionStoresCompanion.insert(
          indexUrl: 'https://anime.example/index.min.json',
          name: 'Anime',
          format: 'legacy',
          mediaKind: const Value('anime'),
        ),
      );
      expect(
        (await fresh.getMangaExtensionStores(mediaKind: 'anime')).single.name,
        'Anime',
      );
      expect(await fresh.getMangaExtensionStores(mediaKind: 'manga'), isEmpty);
    },
  );
}
