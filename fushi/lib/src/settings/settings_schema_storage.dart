import 'package:flutter/material.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/pages/implementations/storage_usage_view.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart'
    show bookTagMapProvider, srtBookTagMapProvider;
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
        // 有声书 persist 目录的真实键口径与删除侧一致（审查 H1）：EPUB 配音频
        // 用 bookKey（AudiobookRepository.delete），字幕书音频用关联 SrtBooks.uid
        //（SrtBookRepository）；EpubBooks.uid 是 v81 本机机器 id，从不入哈希。
        final List<SrtBookRow> srtRows =
            await c.appModel.database.getAllSrtBooks();
        final Map<String, List<String>> srtUidsByBookKey =
            <String, List<String>>{};
        for (final SrtBookRow srt in srtRows) {
          if (srt.bookKey.isEmpty) continue;
          (srtUidsByBookKey[srt.bookKey] ??= <String>[]).add(srt.uid);
        }
        return <StorageBookRef>[
          for (final EpubBookRow row in rows)
            StorageBookRef(
              bookKey: row.bookKey,
              title: row.title,
              extractDir: row.extractDir,
              persistKeys: <String>[
                row.bookKey,
                ...srtUidsByBookKey[row.bookKey] ?? const <String>[],
              ],
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
        if (result.deleted) {
          // 与书架删除路径同款缓存失效（books.part.dart），否则书架/首页里
          // 这本书要等那些页自己刷新才消失（审查 M3）。invalidate 整个
          // family，不假设学习语言。
          c.ref.invalidate(fushiBooksProvider);
          c.ref.invalidate(bookTagMapProvider);
          c.ref.invalidate(srtBookTagMapProvider);
        }
        return result.deleted ? null : result.failureReason;
      },
      deleteDictionary: (String name) async {
        // AppModel.deleteDictionary 内部 catch-all 不上抛（自弹失败 toast），
        // 「无异常」不等于成功——以「删除后该名是否仍在词典表」为准回报
        // （审查 M1）。找不到该名 = 目标状态已达成，按成功处理。
        for (final Dictionary d in c.appModel.dictionaries) {
          if (d.name == name) {
            await c.appModel.deleteDictionary(d);
            final bool stillPresent =
                c.appModel.dictionaries.any((Dictionary x) => x.name == name);
            return stillPresent ? t.storage_dictionary_delete_incomplete : null;
          }
        }
        return null;
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
