import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/app_storage_areas.dart';
import 'package:fushi/src/storage/export_directory.dart'
    show kLegacyExportDirectoryName;

/// D1：受管存储区域登记表替掉了 `AppPaths.fushiOwnedDocumentsEntries` /
/// `libraryEvidenceIgnoredEntries` / 存储页 `kStorageCategoryDocumentsChildren` 三份手写
/// 清单。磁盘目录名是冻结的持久化名（改名 = 老用户的数据留在旧位置），这里把切换前那三份
/// 清单的内容原样钉住：登记表派生出来的东西必须与它们逐项一致，改动磁盘布局必须同时改这里
/// 并带搬迁。
void main() {
  test('登记表在 app 进程里构造得出来（唯一性 / 可删性约束全过）', () {
    expect(kAppStorageAreas.areas, isNotEmpty);
  });

  test('数据根迁移白名单与切换前的手写清单逐项一致', () {
    expect(AppPaths.fushiOwnedDocumentsEntries, <String>{
      'audiobooks',
      'fushi_books',
      kLegacyBooksDirectoryName,
      'video_covers',
      'game_covers',
      'music_covers',
      'video_subtitles',
      'mpv_shaders',
      'mpv_scripts',
      'remote_videos',
      'videos',
      'anime_downloads',
      'custom_fonts',
      'fushiExport',
      kLegacyExportDirectoryName,
      'browser',
      'thumbnails',
      'dictionaryResources',
      'dictionaryImportWorkingDirectory',
      'webArchive',
      'recommended_pack',
      'onboarding_tutorial',
      'manual_torrents',
      'card_source_drafts',
      'srs_profile_backups',
      'audio_cd',
      'music_downloads',
      'srs_backups',
      'inbox_imports',
    });
  });

  test('刻意不随数据根走的导出物（video_clips）登记在用户导出根下', () {
    expect(AppStorageArea.videoClips.root, StorageRootId.userExports);
    expect(AppStorageArea.videoClips.migratesWithDataRoot, isFalse);
    expect(AppPaths.fushiOwnedDocumentsEntries, isNot(contains('video_clips')));
  });

  test('书库证据豁免与切换前一致', () {
    expect(AppPaths.libraryEvidenceIgnoredEntries, <String>{
      'fushiExport',
      kLegacyExportDirectoryName,
      'dictionaryImportWorkingDirectory',
      'recommended_pack',
      'onboarding_tutorial',
    });
    expect(
      AppPaths.fushiOwnedDocumentsEntries.containsAll(
        AppPaths.libraryEvidenceIgnoredEntries,
      ),
      isTrue,
    );
  });

  test('documents 根下的存储类目归属与切换前一致', () {
    final Map<StorageCategoryId, Set<String>> byCategory =
        <StorageCategoryId, Set<String>>{
          for (final StorageCategoryId id in StorageCategoryId.values)
            id: <String>{
              for (final StorageArea a in kAppStorageAreas.inCategory(
                id,
                StorageRootId.documents,
              ))
                ...a.topLevelNames,
            },
        }..removeWhere((StorageCategoryId _, Set<String> v) => v.isEmpty);
    expect(byCategory, <StorageCategoryId, Set<String>>{
      StorageCategoryId.books: <String>{
        'fushi_books',
        kLegacyBooksDirectoryName,
        'audiobooks',
      },
      StorageCategoryId.dictionaries: <String>{
        'dictionaryResources',
        'dictionaryImportWorkingDirectory',
        'recommended_pack',
      },
      StorageCategoryId.videoDownloads: <String>{
        'remote_videos',
        'anime_downloads',
        'videos',
        'manual_torrents',
        'audio_cd',
        'music_downloads',
        'inbox_imports',
      },
      StorageCategoryId.covers: <String>{
        'video_covers',
        'game_covers',
        'music_covers',
        'thumbnails',
      },
      StorageCategoryId.subtitles: <String>{'video_subtitles'},
      StorageCategoryId.shaders: <String>{'mpv_shaders', 'mpv_scripts'},
      StorageCategoryId.customFonts: <String>{'custom_fonts'},
      StorageCategoryId.web: <String>{'webArchive', 'browser'},
      StorageCategoryId.exports: <String>{
        'fushiExport',
        kLegacyExportDirectoryName,
        'card_source_drafts',
      },
      StorageCategoryId.database: <String>{
        'onboarding_tutorial',
        'srs_backups',
        'srs_profile_backups',
      },
    });
  });

  test('support 根下单列类目的区域（OCR 模型、字幕任务）与扫描器的拆分一致', () {
    expect(
      <String, StorageCategoryId>{
        for (final StorageArea a in kAppStorageAreas.under(
          StorageRootId.support,
        ))
          a.relativePath: a.category,
      },
      <String, StorageCategoryId>{
        'imported_videos': StorageCategoryId.database,
        'asr_jobs': StorageCategoryId.subtitleJobs,
        'ocr_models': StorageCategoryId.ocrModels,
        'sync-data': StorageCategoryId.database,
      },
    );
  });

  test('区域级可删性：只有 web / 导出 / OCR 模型 / 字幕任务的明细逐条可删', () {
    final Set<String> deletable = <String>{
      for (final StorageArea a in kAppStorageAreas.areas)
        if (a.entryDeletability != StorageEntryDeletability.no) a.relativePath,
    };
    expect(deletable, <String>{
      'browser',
      'webArchive',
      'fushiExport',
      'card_source_drafts',
      'ocr_models',
      'asr_jobs',
    });
  });
}
