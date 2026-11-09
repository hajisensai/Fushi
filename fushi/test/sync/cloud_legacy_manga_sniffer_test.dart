import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/cloud_book_content_names.dart';
import 'package:fushi/src/sync/cloud_legacy_manga_sniffer.dart';
import 'package:fushi/src/sync/sync_asset_range_reader.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_obfuscator.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';

Uint8List _zip(Map<String, List<int>> files) {
  final Archive a = Archive();
  for (final MapEntry<String, List<int>> e in files.entries) {
    a.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(a)!);
}

List<int> _noise(int length) {
  final List<int> out = List<int>.filled(length, 0);
  int x = 7;
  for (int i = 0; i < length; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    out[i] = x >> 16 & 0xff;
  }
  return out;
}

/// 一份 1 MiB 级的旧名漫画包（根有 manga.json）与一份 EPUB。
final Uint8List _mangaZip = _zip(<String, List<int>>{
  'manga.json': utf8.encode('{"title":"t"}'),
  for (int i = 0; i < 5; i++) 'p00$i.jpg': _noise(200 * 1024),
});
final Uint8List _epubZip = _zip(<String, List<int>>{
  'mimetype': utf8.encode('application/epub+zip'),
  'META-INF/container.xml': utf8.encode('<container/>'),
  'OEBPS/ch1.xhtml': _noise(300 * 1024),
});

/// 云端原样字节的区间读（记录每次请求与读出的字节数）。
class _MemoryRangeReader implements SyncAssetRangeReader {
  _MemoryRangeReader(this.assets);

  final Map<String, Uint8List> assets;
  final List<(String, int, int?)> requests = <(String, int, int?)>[];
  int bytesServed = 0;
  Exception? failWith;

  @override
  Future<SyncAssetRange> openAssetRange(
    String assetId, {
    required int start,
    int? end,
  }) async {
    requests.add((assetId, start, end));
    final Exception? failure = failWith;
    if (failure != null) throw failure;
    final Uint8List bytes = assets[assetId]!;
    if (start >= bytes.length) throw SyncAssetRangeNotSatisfiable(bytes.length);
    final int last = end == null || end >= bytes.length
        ? bytes.length - 1
        : end;
    final Uint8List slice = Uint8List.sublistView(bytes, start, last + 1);
    bytesServed += slice.length;
    return SyncAssetRange(
      start: start,
      end: last,
      totalBytes: bytes.length,
      bytes: Stream<List<int>>.value(slice),
    );
  }
}

class _MemoryCacheStore implements CloudContentSniffCacheStore {
  Map<String, Object?> saved = <String, Object?>{};
  int saves = 0;

  @override
  Future<Map<String, Object?>> load() async =>
      jsonDecode(jsonEncode(saved)) as Map<String, Object?>;

  @override
  Future<void> save(Map<String, Object?> entries) async {
    saved = jsonDecode(jsonEncode(entries)) as Map<String, Object?>;
    saves += 1;
  }
}

AssetEntry _asset(String id, Uint8List bytes, {String? revision = 'rev1'}) =>
    AssetEntry(
      id: id,
      name: 'Book.epub',
      sizeBytes: bytes.length,
      revision: revision,
    );

Future<CloudLegacyMangaSniffer> _sniffer(
  SyncAssetRangeReader reader,
  CloudContentSniffCacheStore store,
) async {
  final CloudLegacyMangaSniffer sniffer = CloudLegacyMangaSniffer(
    reader: reader,
    store: store,
  );
  await sniffer.load();
  return sniffer;
}

void main() {
  test('a legacy .epub that is a manga package is recognised from its tail '
      'only (ecNgkRQcTk)', () async {
    final _MemoryRangeReader reader = _MemoryRangeReader(<String, Uint8List>{
      'm': _mangaZip,
      'e': _epubZip,
    });
    final CloudLegacyMangaSniffer sniffer = await _sniffer(
      reader,
      _MemoryCacheStore(),
    );

    expect(
      await sniffer.kindOf(folderId: 'fm', content: _asset('m', _mangaZip)),
      CloudBookContentKind.manga,
    );
    expect(
      await sniffer.kindOf(folderId: 'fe', content: _asset('e', _epubZip)),
      CloudBookContentKind.epub,
    );
    // 每本一次区间读（文件尾 16 KiB 含整份中央目录），两本加起来远小于包本身。
    expect(reader.requests, hasLength(2));
    expect(reader.bytesServed, lessThanOrEqualTo(2 * 16 * 1024));
    expect(_mangaZip.length, greaterThan(1000 * 1024));
  });

  test(
    'the result is cached by asset id + revision and not sniffed again',
    () async {
      final _MemoryRangeReader reader = _MemoryRangeReader(<String, Uint8List>{
        'm': _mangaZip,
      });
      final _MemoryCacheStore store = _MemoryCacheStore();
      final CloudLegacyMangaSniffer first = await _sniffer(reader, store);
      await first.kindOf(folderId: 'fm', content: _asset('m', _mangaZip));
      await first.persist(<String>{'fm'});
      expect(store.saves, 1);
      reader.requests.clear();

      final CloudLegacyMangaSniffer second = await _sniffer(reader, store);
      expect(
        await second.kindOf(folderId: 'fm', content: _asset('m', _mangaZip)),
        CloudBookContentKind.manga,
      );
      expect(reader.requests, isEmpty, reason: '缓存命中不再读云端');
      await second.persist(<String>{'fm'});
      expect(store.saves, 1, reason: '没有变化不写回');

      // 内容变了（后端内容版本标记变了）→ 缓存失效，重新嗅探。
      reader.assets['m'] = _epubZip;
      expect(
        await second.kindOf(
          folderId: 'fm',
          content: _asset('m', _epubZip, revision: 'rev2'),
        ),
        CloudBookContentKind.epub,
      );
      expect(reader.requests, isNotEmpty);
    },
  );

  test(
    'assets without a backend revision are not sniffed (cannot be cached)',
    () async {
      final _MemoryRangeReader reader = _MemoryRangeReader(<String, Uint8List>{
        'm': _mangaZip,
      });
      final CloudLegacyMangaSniffer sniffer = await _sniffer(
        reader,
        _MemoryCacheStore(),
      );

      expect(
        await sniffer.kindOf(
          folderId: 'fm',
          content: _asset('m', _mangaZip, revision: null),
        ),
        isNull,
      );
      expect(reader.requests, isEmpty);
    },
  );

  test('a transport failure yields null and is not cached', () async {
    final _MemoryRangeReader reader = _MemoryRangeReader(<String, Uint8List>{
      'm': _mangaZip,
    })..failWith = SyncBackendError('cloud asset range read failed: HTTP 503');
    final _MemoryCacheStore store = _MemoryCacheStore();
    final CloudLegacyMangaSniffer sniffer = await _sniffer(reader, store);

    expect(
      await sniffer.kindOf(folderId: 'fm', content: _asset('m', _mangaZip)),
      isNull,
    );
    await sniffer.persist(<String>{'fm'});
    expect(store.saved, isEmpty);

    reader.failWith = null;
    expect(
      await sniffer.kindOf(folderId: 'fm', content: _asset('m', _mangaZip)),
      CloudBookContentKind.manga,
      reason: '下次列举照常重试',
    );
  });

  test('bytes that are not a zip are a definite EPUB verdict', () async {
    final Uint8List junk = Uint8List.fromList(_noise(4096));
    final _MemoryRangeReader reader = _MemoryRangeReader(<String, Uint8List>{
      'j': junk,
    });
    final _MemoryCacheStore store = _MemoryCacheStore();
    final CloudLegacyMangaSniffer sniffer = await _sniffer(reader, store);

    expect(
      await sniffer.kindOf(folderId: 'fj', content: _asset('j', junk)),
      CloudBookContentKind.epub,
    );
    await sniffer.persist(<String>{'fj'});
    expect((store.saved['j']! as Map<String, Object?>)['kind'], 'epub');
  });

  test('obfuscated uploads are read through the de-obfuscating view', () async {
    final Uint8List raw = SyncObfuscator.obfuscateBytes(_mangaZip);
    final _MemoryRangeReader rawReader = _MemoryRangeReader(<String, Uint8List>{
      'm': raw,
    });
    final CloudLegacyMangaSniffer sniffer = await _sniffer(
      DeobfuscatingAssetRangeReader(rawReader),
      _MemoryCacheStore(),
    );

    // 列举给的是云端原样大小（含 8 字节魔数）。
    expect(
      await sniffer.kindOf(folderId: 'fm', content: _asset('m', raw)),
      CloudBookContentKind.manga,
    );
    expect(rawReader.bytesServed, lessThan(20 * 1024));
  });

  test(
    'a listed size larger than the asset falls back to probing the length',
    () async {
      final _MemoryRangeReader reader = _MemoryRangeReader(<String, Uint8List>{
        'm': _mangaZip,
      });
      final CloudLegacyMangaSniffer sniffer = await _sniffer(
        reader,
        _MemoryCacheStore(),
      );

      expect(
        await sniffer.kindOf(
          folderId: 'fm',
          content: AssetEntry(
            id: 'm',
            name: 'Book.epub',
            sizeBytes: _mangaZip.length * 2,
            revision: 'rev1',
          ),
        ),
        CloudBookContentKind.manga,
      );
    },
  );

  test(
    'persist drops entries of folders that are gone from the remote',
    () async {
      final _MemoryRangeReader reader = _MemoryRangeReader(<String, Uint8List>{
        'm': _mangaZip,
        'e': _epubZip,
      });
      final _MemoryCacheStore store = _MemoryCacheStore();
      final CloudLegacyMangaSniffer sniffer = await _sniffer(reader, store);
      await sniffer.kindOf(folderId: 'fm', content: _asset('m', _mangaZip));
      await sniffer.kindOf(folderId: 'fe', content: _asset('e', _epubZip));

      await sniffer.persist(<String>{'fm'});

      expect(store.saved.keys, <String>['m']);
    },
  );
}
