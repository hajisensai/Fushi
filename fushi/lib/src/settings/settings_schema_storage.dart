import 'package:flutter/material.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/pages/implementations/storage_usage_view.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi/utils.dart';

/// 「存储」一级设置分类：磁盘占用总览（书/词典可展开单条删除）+ 可选模块
/// （OCR 模型 / Anime4K 着色器删除恢复）+ 随包组件展示。
///
/// 正文经 [SettingsDestination.body] 逃生口渲染 [StorageUsageView]；所有删除
/// 都在这里接到各域既有路径（书 `ReaderFushiSource.deleteBook`、词典
/// `AppModel.deleteDictionary`），widget 自身零裸磁盘删除。
SettingsDestination buildStorageDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.storage,
    title: t.settings_destination_storage,
    summary: t.settings_destination_storage_summary,
    icon: Icons.sd_storage_outlined,
    sections: const <SettingsSection>[],
    body: (SettingsContext c) => StorageUsageView(
      service: StorageUsageService(),
      ocrService: c.ref.read(mangaOcrServiceProvider),
      booksProvider: () async {
        final List<EpubBookRow> rows =
            await c.appModel.database.getAllEpubBooks();
        return <StorageBookRef>[
          for (final EpubBookRow row in rows)
            StorageBookRef(
              bookKey: row.bookKey,
              uid: row.uid,
              title: row.title,
              extractDir: row.extractDir,
            ),
        ];
      },
      dictionaryNamesProvider: () async => <String>[
        for (final Dictionary d in c.appModel.dictionaries) d.name,
      ],
      deleteBook: (String bookKey) async {
        final DeleteBookResult result =
            await ReaderFushiSource.instance.deleteBook(
          db: c.appModel.database,
          bookKey: bookKey,
          appModel: c.appModel,
        );
        return result.deleted ? null : result.failureReason;
      },
      deleteDictionary: (String name) async {
        for (final Dictionary d in c.appModel.dictionaries) {
          if (d.name == name) {
            await c.appModel.deleteDictionary(d);
            return;
          }
        }
      },
    ),
    bodySearchEntries: <SettingsBodySearchEntry>[
      SettingsBodySearchEntry(
        id: 'storage.overview',
        title: t.storage_overview_section,
        subtitle: t.storage_overview_total,
      ),
      SettingsBodySearchEntry(
        id: 'storage.modules',
        title: t.storage_modules_section,
        subtitle: '${t.storage_category_ocr_models} · '
            '${t.storage_modules_anime4k_title}',
      ),
      SettingsBodySearchEntry(
        id: 'storage.bundled',
        title: t.storage_bundled_section,
        subtitle: t.storage_bundled_hint,
      ),
    ],
  );
}
