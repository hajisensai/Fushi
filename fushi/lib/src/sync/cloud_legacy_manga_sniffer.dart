import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/sync/cloud_book_content_names.dart';
import 'package:fushi/src/sync/sync_asset_range_reader.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/sync/manga_sync_package.dart'
    show isMangaPackageMarkerEntry;
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_engine/sync/sync_channel_scope.dart';
import 'package:fushi_engine/utils/archive/zip_central_directory.dart';

/// 内容判型缓存的持久化端（一条云盘通道一份）。
abstract interface class CloudContentSniffCacheStore {
  /// 读出整份缓存（资产 id → 条目 JSON）；没有返回空表。
  Future<Map<String, Object?>> load();

  /// 整份覆盖写回。
  Future<void> save(Map<String, Object?> entries);
}

/// [CloudContentSniffCacheStore] 落在本机库 preferences 表、按通道分槽
/// （[SyncRepository.getContentSniffCache]）。
class SyncRepositoryContentSniffCacheStore
    implements CloudContentSniffCacheStore {
  SyncRepositoryContentSniffCacheStore(this._repo, this._scope);

  final SyncRepository _repo;
  final SyncChannelScope _scope;

  @override
  Future<Map<String, Object?>> load() => _repo.getContentSniffCache(_scope);

  @override
  Future<void> save(Map<String, Object?> entries) =>
      _repo.setContentSniffCache(_scope, entries);
}

/// 云盘旧名 `<title>.epub` 内容资产的内容判型（反馈 ecNgkRQcTk，PR #3028 遗留）。
///
/// 旧版本把漫画包也上传成 `<title>.epub`。#3028 让**本地还持有这本漫画**的设备补写
/// 格式标记 `manga_content.json`；没有任何设备持有的旧包没人补，单看文件名只能归书籍。
/// 本类按字节区间读这份 zip 的**中央目录**（[readZipCentralDirectory]：文件尾 16 KiB，
/// 目录不在尾巴里再读一次目录本身），看根上有没有 `manga.json`（与下载后整包嗅探
/// `isMangaPackage` 同一判据 [isMangaPackageMarkerEntry]），不下载条目数据。
///
/// - 只在后端能做区间读时启用（[plainAssetRangeReaderOf] 非 null：Google Drive /
///   OneDrive / Dropbox）。WebDAV / FTP / SFTP 只能整包下载，不在列举时嗅探。
/// - 只嗅探一次：结果按「资产 id + 后端内容版本标记 [AssetEntry.revision] + 大小」
///   缓存在本机（[CloudContentSniffCacheStore]），资产内容变了标记必变，缓存自然失效。
///   后端给不出 [AssetEntry.revision]（「可能变了」）的资产不嗅探——缓存不住就会每次
///   列举都重读。
/// - 列举是只读查询：本类**不往云端写**格式标记（标记仍只由持有这本漫画的同步写入，
///   见 `SyncManager._exportContentIfMissing`）。
/// - 判型失败（网络 / 鉴权）返回 null、不入缓存，调用方保持按文件名的判定，下次列举
///   再试；不是 zip / 目录损坏是**确定**的结论，按书籍入缓存（下载导入同样会按 EPUB
///   处理并诚实报错）。
class CloudLegacyMangaSniffer {
  CloudLegacyMangaSniffer({
    required SyncAssetRangeReader reader,
    required CloudContentSniffCacheStore store,
    this.tailBytes = 16 * 1024,
  }) : _reader = reader,
       _store = store;

  final SyncAssetRangeReader _reader;
  final CloudContentSniffCacheStore _store;

  /// 首次区间读取的文件尾长度。
  final int tailBytes;

  Map<String, Object?>? _entries;
  bool _dirty = false;

  /// 读入缓存；[kindOf] 之前调用一次。
  Future<void> load() async {
    _entries = Map<String, Object?>.of(await _store.load());
  }

  /// 文件夹 [folderId] 里的旧名内容资产 [content] 的内容格式；判不出（后端没给内容
  /// 版本标记 / 读失败）返回 null。
  Future<CloudBookContentKind?> kindOf({
    required String folderId,
    required AssetEntry content,
  }) async {
    final Map<String, Object?> entries = _entries ??= <String, Object?>{};
    final String? revision = content.revision;
    if (revision == null) return null;
    final Object? cached = entries[content.id];
    if (cached is Map) {
      final CloudBookContentKind? hit = _cachedKind(cached, content);
      if (hit != null) {
        if (cached['folder'] != folderId) {
          entries[content.id] = _entry(folderId, content, hit);
          _dirty = true;
        }
        return hit;
      }
    }
    final CloudBookContentKind? kind = await _sniff(content);
    if (kind == null) return null;
    entries[content.id] = _entry(folderId, content, kind);
    _dirty = true;
    return kind;
  }

  /// 有变化时写回缓存，并丢掉不在 [liveFolderIds] 里的文件夹的条目（书已从云端删掉，
  /// 条目不再有用）。
  Future<void> persist(Set<String> liveFolderIds) async {
    final Map<String, Object?>? entries = _entries;
    if (entries == null) return;
    final int before = entries.length;
    entries.removeWhere(
      (String _, Object? value) =>
          value is! Map || !liveFolderIds.contains(value['folder']),
    );
    if (!_dirty && entries.length == before) return;
    await _store.save(entries);
    _dirty = false;
  }

  static CloudBookContentKind? _cachedKind(
    Map<Object?, Object?> cached,
    AssetEntry content,
  ) {
    if (cached['revision'] != content.revision ||
        cached['size'] != content.sizeBytes) {
      return null;
    }
    return switch (cached['kind']) {
      'manga' => CloudBookContentKind.manga,
      'epub' => CloudBookContentKind.epub,
      _ => null,
    };
  }

  static Map<String, Object?> _entry(
    String folderId,
    AssetEntry content,
    CloudBookContentKind kind,
  ) => <String, Object?>{
    'folder': folderId,
    'revision': content.revision,
    'size': content.sizeBytes,
    'kind': kind.name,
  };

  Future<CloudBookContentKind?> _sniff(AssetEntry content) async {
    try {
      final List<ZipCentralDirectoryEntry> entries = await _centralDirectory(
        content,
      );
      return entries.any(
            (ZipCentralDirectoryEntry e) => isMangaPackageMarkerEntry(e.name),
          )
          ? CloudBookContentKind.manga
          : CloudBookContentKind.epub;
    } on ZipCentralDirectoryException {
      return CloudBookContentKind.epub; // 不是 zip / 目录损坏：确定不是漫画包。
    } on SyncAssetRangeNotSatisfiable {
      return CloudBookContentKind.epub; // 空文件。
    } catch (e) {
      debugPrint(
        '[CloudLegacyMangaSniffer] sniff failed for ${content.name}: $e',
      );
      return null;
    }
  }

  /// 读 [content] 的中央目录。第一次区间读直接从文件尾附近开始（后端列举给了大小
  /// 时），一次拿到总长和尾巴；没给大小才先读 1 字节拿总长。
  Future<List<ZipCentralDirectoryEntry>> _centralDirectory(
    AssetEntry content,
  ) async {
    final int? rawSize = content.sizeBytes;
    final int tailStart = rawSize == null || rawSize <= tailBytes
        ? 0
        : rawSize - tailBytes;
    SyncAssetRange first;
    try {
      first = await _reader.openAssetRange(
        content.id,
        start: tailStart,
        end: rawSize == null ? 0 : null,
      );
    } on SyncAssetRangeNotSatisfiable {
      // 列举报的大小比实际大（列举后内容被换过）：不按它下结论，退回先读 1 字节拿
      // 真实总长。从 0 起仍越界才是真的空文件。
      if (tailStart == 0) rethrow;
      first = await _reader.openAssetRange(content.id, start: 0, end: 0);
    }
    final int length = first.totalBytes;
    final int prefetchedStart = first.start;
    final Uint8List prefetched = await _collect(first, first.length);

    Future<Uint8List> read(int offset, int count) async {
      if (offset >= prefetchedStart &&
          offset + count <= prefetchedStart + prefetched.length) {
        return Uint8List.sublistView(
          prefetched,
          offset - prefetchedStart,
          offset - prefetchedStart + count,
        );
      }
      final SyncAssetRange range = await _reader.openAssetRange(
        content.id,
        start: offset,
        end: offset + count - 1,
      );
      if (range.start != offset) {
        unawaited(range.bytes.listen(null).cancel());
        throw StateError('range read started at ${range.start}, not $offset');
      }
      return _collect(range, count);
    }

    return readZipCentralDirectory(
      length: length,
      read: read,
      // 第一次读已经到文件尾时，尾巴就是它；只读了 1 字节拿总长时按默认尾长再读。
      initialTailBytes: prefetchedStart + prefetched.length == length
          ? length - prefetchedStart
          : tailBytes,
    );
  }

  /// 收齐 [range] 的 [expected] 字节；少了抛错（不把截断的字节当目录解析）。
  static Future<Uint8List> _collect(SyncAssetRange range, int expected) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in range.bytes) {
      builder.add(chunk);
    }
    if (builder.length != expected) {
      throw StateError(
        'range read returned ${builder.length} / $expected bytes',
      );
    }
    return builder.takeBytes();
  }
}
