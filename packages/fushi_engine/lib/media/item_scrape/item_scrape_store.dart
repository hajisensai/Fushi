import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/cover_file_writer.dart';
import 'package:fushi_engine/media/metadata/image_download.dart';
import 'package:fushi_engine/media/video/video_storage.dart';

/// 单本书 / 漫画 / 字幕书 / 游戏的刮削资料与附加图（schema v161 的
/// `item_scrape_meta` / `item_images`）的唯一写入口。
///
/// 书籍刮削门面（Bangumi / DLsite，以及之后的 AniList / openBD / NDL / 楽天）、
/// 游戏元数据刮削、控制通道的 `library scrape-meta set` 都只经这里写：
/// - [writeMeta]：整行写入 / 覆盖文字资料；
/// - [setImageFromFile] / [setImageFromUrl]：附加图（backdrop / logo）原子落盘到
///   `video_covers/items/` 并登记；换图时旧文件随即回收；
/// - [applyScrape]：上面两步的组合（刮削源一次响应 = 资料 + 可选横版图）。
///
/// 删除宿主时 DB 行在删书 / 删字幕书 / 删游戏的事务里清掉（fushi_core 的
/// `deleteEpubBook` / `deleteSrtBookByUid` / `deleteGalgame`），文件由删除路径
/// 之后调 [reclaimUnreferencedFiles] 回收——目录只归 item_images 所有，扫「不被
/// 任何行引用」即可，任何删除入口（含同步删除传播）漏调也只是晚回收，不会误删。
class ItemScrapeStore {
  ItemScrapeStore(
    this._db, {
    Directory? imagesDirectory,
    Future<File> Function(String url)? downloadImage,
    DateTime Function() now = DateTime.now,
  }) : _imagesDirectory = imagesDirectory,
       _download = downloadImage ?? downloadImageToTempFile,
       _now = now;

  final FushiDatabase _db;
  final Directory? _imagesDirectory;
  final Future<File> Function(String url) _download;
  final DateTime Function() _now;

  /// 手动 / 脚本写入的 [ItemScrapeDetails.source]。
  static const String manualSource = 'manual';

  Future<Directory> _dir() async =>
      _imagesDirectory ?? await VideoStorage.itemImagesDir();

  /// 写入 / 整行覆盖 [key] 的文字资料。
  Future<void> writeMeta(ItemScrapeKey key, ItemScrapeDetails details) =>
      _db.upsertItemScrapeMeta(details.toCompanion(key, _now()));

  /// 合并写：[patch] 里非 null 的字段覆盖已有行，其余保留（脚本「只改简介」用）。
  Future<void> mergeMeta(ItemScrapeKey key, ItemScrapeDetails patch) async {
    final ItemScrapeMetaRow? old = await _db.getItemScrapeMeta(
      key.mediaType,
      key.entryKey,
    );
    await writeMeta(
      key,
      old == null ? patch : ItemScrapeDetails.fromRow(old).overlay(patch),
    );
  }

  /// 刮削源一次响应落库：文字资料 + 可选横版背景（[backdropUrl] 下载，或已在
  /// 本地的 [backdropFile]）。背景下载失败不回滚资料（资料本身已可用），失败
  /// 原样抛给调用方决定是否提示。
  Future<void> applyScrape(
    ItemScrapeKey key,
    ItemScrapeDetails details, {
    String? backdropUrl,
    File? backdropFile,
  }) async {
    await writeMeta(key, details);
    if (backdropFile != null) {
      await setImageFromFile(
        key,
        MediaImageKind.backdrop,
        backdropFile,
        sourceUrl: backdropUrl,
      );
    } else if (backdropUrl != null && backdropUrl.trim().isNotEmpty) {
      await setImageFromUrl(key, MediaImageKind.backdrop, backdropUrl.trim());
    }
  }

  /// 把本地图片 [source] 设为 [key] 的 [kind] 图（position 0，替换旧图）。返回
  /// 落盘路径。源不是完整可解码图片时抛 [CoverImageInvalidException]，旧图不动。
  Future<String> setImageFromFile(
    ItemScrapeKey key,
    MediaImageKind kind,
    File source, {
    String? sourceUrl,
  }) async {
    final Directory dir = await _dir();
    await dir.create(recursive: true);
    final String dest = p.join(dir.path, itemImageFileName(key, kind, source));
    await copyCoverFileAtomically(source: source, destPath: dest);
    final List<String> dropped = await _db.replaceItemImagesOfKind(
      mediaType: key.mediaType,
      entryKey: key.entryKey,
      kind: kind,
      images: <({String path, String? sourceUrl})>[
        (path: dest, sourceUrl: sourceUrl),
      ],
    );
    await _deleteOwned(dropped);
    return dest;
  }

  /// 下载 [url] 后同 [setImageFromFile]（下载失败抛 [ImageDownloadException]）。
  Future<String> setImageFromUrl(
    ItemScrapeKey key,
    MediaImageKind kind,
    String url,
  ) async {
    final File tmp = await _download(url);
    try {
      return await setImageFromFile(key, kind, tmp, sourceUrl: url);
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // 临时文件，删不掉由系统清理。
      }
    }
  }

  /// 清掉 [key] 的 [kind] 图（行 + 文件）。
  Future<void> clearImage(ItemScrapeKey key, MediaImageKind kind) async {
    final List<String> dropped = await _db.replaceItemImagesOfKind(
      mediaType: key.mediaType,
      entryKey: key.entryKey,
      kind: kind,
      images: const <({String path, String? sourceUrl})>[],
    );
    await _deleteOwned(dropped);
  }

  /// 回收附加图目录里不再被任何 item_images 行引用的文件（宿主删除后调用）。
  /// 返回实删数；目录不存在为 0。失败只记日志，不抛断删除流程。
  Future<int> reclaimUnreferencedFiles() async {
    try {
      final Directory dir = await _dir();
      if (!await dir.exists()) return 0;
      final List<String> candidates = <String>[
        await for (final FileSystemEntity e in dir.list())
          if (e is File && !p.basename(e.path).contains('.tmp.')) e.path,
      ];
      if (candidates.isEmpty) return 0;
      return await VideoStorage.deleteOwnedImageFiles(
        deletedPaths: candidates,
        stillReferencedPaths: <String>[
          for (final ItemImageRow row in await _db.getAllItemImages()) row.path,
        ],
        ownedDir: dir,
      );
    } catch (e, stack) {
      engineLog.log('itemScrape.reclaim', e, stack);
      return 0;
    }
  }

  Future<void> _deleteOwned(List<String> paths) async {
    if (paths.isEmpty) return;
    await VideoStorage.deleteOwnedImageFiles(
      deletedPaths: paths,
      stillReferencedPaths: <String>[
        for (final ItemImageRow row in await _db.getAllItemImages()) row.path,
      ],
      ownedDir: await _dir(),
    );
  }
}

/// item_scrape_meta / item_images 的宿主身份（同合集成员的 (mediaType, entryKey)：
/// epub=EpubBooks.uid / srt=SrtBooks.uid / game=Galgames.id）。
class ItemScrapeKey {
  ItemScrapeKey(this.mediaType, this.entryKey) {
    if (!kItemScrapeMediaKinds.contains(mediaType)) {
      throw ArgumentError.value(mediaType, 'mediaType');
    }
    if (entryKey.isEmpty) throw ArgumentError.value(entryKey, 'entryKey');
  }

  final MediaKind mediaType;
  final String entryKey;

  @override
  bool operator ==(Object other) =>
      other is ItemScrapeKey &&
      other.mediaType == mediaType &&
      other.entryKey == entryKey;

  @override
  int get hashCode => Object.hash(mediaType, entryKey);

  @override
  String toString() => '${mediaType.dbValue}:$entryKey';
}

/// 一次刮削 / 手动写入的文字资料（与媒体、来源无关的形状；各源各自折进来）。
class ItemScrapeDetails {
  const ItemScrapeDetails({
    required this.source,
    this.subjectId,
    this.title,
    this.originalTitle,
    this.summary,
    this.airDate,
    this.rating,
    this.ratingCount,
    this.tags = const <String>[],
    this.detailUrl,
  });

  factory ItemScrapeDetails.fromRow(ItemScrapeMetaRow row) => ItemScrapeDetails(
    source: row.source,
    subjectId: row.subjectId,
    title: row.title,
    originalTitle: row.originalTitle,
    summary: row.summary,
    airDate: row.airDate,
    rating: row.rating,
    ratingCount: row.ratingCount,
    tags: decodeItemScrapeTags(row.tagsJson),
    detailUrl: row.detailUrl,
  );

  /// 来源（书籍刮削源名 / 游戏元数据源 key / [ItemScrapeStore.manualSource]）。
  final String source;
  final String? subjectId;
  final String? title;
  final String? originalTitle;
  final String? summary;

  /// `YYYY-MM-DD` / `YYYY-MM` / `YYYY`。
  final String? airDate;

  /// 0~10。
  final double? rating;
  final int? ratingCount;

  /// 类型 / 标签名（按热度降序）。
  final List<String> tags;
  final String? detailUrl;

  /// [patch] 非 null / 非空的字段盖在本对象上（来源取 [patch] 的）。
  ItemScrapeDetails overlay(ItemScrapeDetails patch) => ItemScrapeDetails(
    source: patch.source,
    subjectId: patch.subjectId ?? subjectId,
    title: patch.title ?? title,
    originalTitle: patch.originalTitle ?? originalTitle,
    summary: patch.summary ?? summary,
    airDate: patch.airDate ?? airDate,
    rating: patch.rating ?? rating,
    ratingCount: patch.ratingCount ?? ratingCount,
    tags: patch.tags.isNotEmpty ? patch.tags : tags,
    detailUrl: patch.detailUrl ?? detailUrl,
  );

  ItemScrapeMetaCompanion toCompanion(ItemScrapeKey key, DateTime now) =>
      ItemScrapeMetaCompanion.insert(
        mediaType: key.mediaType.dbValue,
        entryKey: key.entryKey,
        source: source,
        subjectId: Value<String?>(_blankToNull(subjectId)),
        title: Value<String?>(_blankToNull(title)),
        originalTitle: Value<String?>(_blankToNull(originalTitle)),
        summary: Value<String?>(_blankToNull(summary)),
        airDate: Value<String?>(_blankToNull(airDate)),
        rating: Value<double?>(rating),
        ratingCount: Value<int?>(ratingCount),
        tagsJson: Value<String?>(encodeItemScrapeTags(tags)),
        detailUrl: Value<String?>(_blankToNull(detailUrl)),
        scrapedAt: now.millisecondsSinceEpoch,
      );
}

String? _blankToNull(String? s) =>
    (s == null || s.trim().isEmpty) ? null : s.trim();

/// 标签名列表 → 与 `CollectionScrapeMeta.tagsJson` 同形的 JSON（无热度时 count
/// 省略）；空为 null。
String? encodeItemScrapeTags(List<String> tags) {
  final List<String> names = <String>[
    for (final String t in tags)
      if (t.trim().isNotEmpty) t.trim(),
  ];
  if (names.isEmpty) return null;
  return jsonEncode(<Map<String, Object?>>[
    for (final String n in names) <String, Object?>{'name': n},
  ]);
}

/// [encodeItemScrapeTags] 的逆；解析失败为空表。
List<String> decodeItemScrapeTags(String? json) {
  if (json == null || json.isEmpty) return const <String>[];
  try {
    final Object? decoded = jsonDecode(json);
    if (decoded is! List<Object?>) return const <String>[];
    return <String>[
      for (final Object? tag in decoded)
        if (tag is Map<String, Object?> && tag['name'] is String)
          tag['name']! as String,
    ];
  } on FormatException {
    return const <String>[];
  }
}

/// 附加图文件名：`<mediaType>_<entryKey 摘要>_<kind>.<ext>`。entryKey 取 sha1 前
/// 16 位（游戏 id / uid 里可能有任意字符），扩展名跟源文件（没有按 jpg）。
String itemImageFileName(ItemScrapeKey key, MediaImageKind kind, File source) {
  final String digest = sha1
      .convert(utf8.encode(key.entryKey))
      .toString()
      .substring(0, 16);
  String ext = p.extension(source.path).toLowerCase();
  if (!const <String>{'.jpg', '.jpeg', '.png', '.webp', '.gif'}.contains(ext)) {
    ext = '.jpg';
  }
  return '${key.mediaType.dbValue}_${digest}_${kind.dbValue}$ext';
}
