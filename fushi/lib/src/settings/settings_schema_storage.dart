import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fushi_audio/fushi_audio.dart' show SrtBookRepository;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/pages/implementations/storage_usage_view.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart'
    show bookTagMapProvider, srtBookTagMapProvider;
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show buildDataStorageLocationSection;
import 'package:fushi/utils.dart';

/// 「存储」一级设置分类：数据存储位置（数据根在哪）+ 磁盘占用总览（每个类目
/// 都可展开明细，书/词典可单条删除）+ 随包组件展示。
///
/// 「数据存储位置」是本页唯一的 schema section（历史上挂过同步备份、后来挪到
/// 「系统」）：它回答「数据放哪」，与下面「占了多少」是同一个问题的两半，放在
/// 一起才成一页；item id 仍是 'sync.data_storage_location'，构建函数留在
/// sync_settings_schema（行 widget 是该库私有 part）。
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
    sections: <SettingsSection>[buildDataStorageLocationSection()],
    body: (SettingsContext c) => StorageUsageView(
      service: StorageUsageService(),
      booksProvider: () async {
        final List<EpubBookRow> rows =
            await c.appModel.database.getAllEpubBooks();
        // 有声书 persist 目录的真实键口径与删除侧一致（审查 H1）：EPUB 配音频
        // 用 bookKey（AudiobookRepository.delete），字幕书音频用关联 SrtBooks.uid
        //（SrtBookRepository）；EpubBooks.uid 是 v81 本机机器 id，从不入哈希。
        final List<SrtBookRow> srtRows =
            await c.appModel.database.getAllSrtBooks();
        // BUG-1893：音频的真相源是 DB 里记的路径（audioRoot / audioPathsJson）。
        // 互联同步拉来的有声书落的是明文目录 audiobooks/<safeDirName(key)>，哈希
        // 目录只是本地导入那一条路径的形态；两者都喂给扫描层，重叠部分由
        // resolveBookStoragePaths 去嵌套去重，不会重复计数。
        final List<AudiobookRow> audiobookRows =
            await c.appModel.database.getAllAudiobooks();
        final Map<String, List<String>> audioPathsByBookKey =
            <String, List<String>>{};
        for (final AudiobookRow ab in audiobookRows) {
          if (ab.bookKey.isEmpty) continue;
          (audioPathsByBookKey[ab.bookKey] ??= <String>[])
              .addAll(_audioPathsOf(ab.audioRoot, ab.audioPathsJson));
        }
        final Map<String, List<String>> srtUidsByBookKey =
            <String, List<String>>{};
        // standalone 字幕书（bookKey 恒空）没有 EpubBooks 行。旧实现直接 continue
        // 掉，于是这类书在存储页永远无行、也没有删除入口（BUG-1893 B 类）。
        final List<SrtBookRow> standaloneSrtRows = <SrtBookRow>[];
        for (final SrtBookRow srt in srtRows) {
          if (srt.bookKey.isEmpty) {
            standaloneSrtRows.add(srt);
            continue;
          }
          (srtUidsByBookKey[srt.bookKey] ??= <String>[]).add(srt.uid);
          (audioPathsByBookKey[srt.bookKey] ??= <String>[])
              .addAll(_audioPathsOf(srt.audioRoot, srt.audioPathsJson));
        }
        return <StorageBookRef>[
          for (final EpubBookRow row in rows)
            StorageBookRef(
              id: row.bookKey,
              title: row.title,
              extractDir: row.extractDir,
              persistKeys: <String>[
                row.bookKey,
                ...srtUidsByBookKey[row.bookKey] ?? const <String>[],
              ],
              audioPaths: audioPathsByBookKey[row.bookKey] ?? const <String>[],
            ),
          for (final SrtBookRow srt in standaloneSrtRows)
            StorageBookRef(
              id: srt.uid,
              title: srt.title,
              // 无 EPUB 正文载体：磁盘占用全在 persist 目录 / audioRoot 里。
              extractDir: '',
              persistKeys: <String>[srt.uid],
              audioPaths: _audioPathsOf(srt.audioRoot, srt.audioPathsJson),
              kind: StorageEntryKind.srtBook,
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
      // BUG-1893：standalone 字幕书没有 EpubBooks 行，deleteBook 按 bookKey 找行
      // 必然落空；它的删除原语是 SrtBookRepository.delete（连带持久目录 + cue）。
      // 与 deleteDictionary 同纪律：行本来就不在 = 目标状态已达成，按成功处理。
      deleteSrtBook: (String uid) async {
        await SrtBookRepository(c.appModel.database).delete(uid);
        c.ref.invalidate(fushiBooksProvider);
        c.ref.invalidate(srtBookTagMapProvider);
        return null;
      },
      // BUG-1870：主库快照残留的删除原语在 fushi_core（与扫描侧识别口径同源）。
      deleteDatabaseSnapshots: () async =>
          deleteDatabaseSnapshotFiles(await AppPaths.supportRootDirectory()),
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
        id: 'storage.shaders',
        title: t.storage_category_shaders,
        subtitle: '${t.storage_modules_anime4k_title} · '
            '${t.storage_shaders_delete_anime4k}',
      ),
      SettingsBodySearchEntry(
        id: 'storage.bundled',
        title: t.storage_bundled_section,
        subtitle: t.storage_bundled_hint,
      ),
    ],
  );
}

/// DB 里一行有声书/字幕书的音频真实路径：legacy 的 `audioRoot`（目录模式）加
/// `audioPathsJson`（文件列表模式）。两种模式历史上共存，同步导入更是两列都写
/// （`sync_asset_package_service.dart`），所以两列全取、重叠交给
/// `resolveBookStoragePaths` 去嵌套。坏 JSON 降级成空列表，不能炸整页扫描。
List<String> _audioPathsOf(
    final String? audioRoot, final String? audioPathsJson) {
  final List<String> out = <String>[
    if (audioRoot != null && audioRoot.isNotEmpty) audioRoot,
  ];
  if (audioPathsJson == null || audioPathsJson.isEmpty) return out;
  try {
    final Object? decoded = jsonDecode(audioPathsJson);
    if (decoded is List) {
      for (final Object? item in decoded) {
        if (item is String && item.isNotEmpty) out.add(item);
      }
    }
  } on FormatException {
    // 旧行/手改坏值：当作没有文件列表，仍保留 audioRoot。
  }
  return out;
}
