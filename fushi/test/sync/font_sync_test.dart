import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/font_catalog.dart';
import 'package:fushi/src/sync/font_sync.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:path/path.dart' as p;

/// 字体同步（`__fonts__` 命名空间）：上传按内容去重、超限不传、下载落地后合并配置。
void main() {
  late Directory tmp;
  late _MemoryStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('font_sync_test');
    store = _MemoryStore();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  _FakeLocal device(String name, FontCatalogState state) {
    final Directory root = Directory(p.join(tmp.path, name, 'custom_fonts'))
      ..createSync(recursive: true);
    return _FakeLocal(root.path, state);
  }

  File writeFont(_FakeLocal local, String file, List<int> bytes) =>
      File(p.join(local.fontsRoot, file))..writeAsBytesSync(bytes);

  FontCatalogState stateOf(
    List<FontCatalogEntry> fonts,
    Map<String, List<FontTargetFont>> targets,
  ) =>
      FontCatalogState(fonts: fonts, targets: targets);

  test('上传：同一份字体文件只传一次，清单带上各用途的选用', () async {
    final _FakeLocal a = device('a', FontCatalogState.empty());
    final File mincho = writeFont(a, 'mincho.ttf', <int>[1, 2, 3, 4]);
    // 同一内容换个文件名再导入一次：按内容寻址只存一份。
    final File copy = writeFont(a, 'mincho-copy.ttf', <int>[1, 2, 3, 4]);
    a.state = stateOf(
      <FontCatalogEntry>[
        FontCatalogEntry(id: 'font_1', name: 'Mincho', path: mincho.path),
        FontCatalogEntry(id: 'font_2', name: 'Mincho 2', path: copy.path),
        const FontCatalogEntry(id: 'font_3', name: 'Yu Gothic', path: null),
      ],
      <String, List<FontTargetFont>>{
        'custom_fonts': const <FontTargetFont>[
          FontTargetFont(fontId: 'font_1', enabled: true),
          FontTargetFont(fontId: 'font_3', enabled: false),
        ],
      },
    );

    final FontSyncReport first = await FontSyncService(
      store: store,
      local: a,
      tempDir: tmp,
    ).upload();
    expect(first.filesUploaded, 1);
    expect(first.configUploaded, isTrue);
    expect(
      store.namesIn(kSyncFontsNamespace),
      containsAll(<String>[
        kFontSyncManifestName,
        await fontAssetNameFor(mincho),
      ]),
    );

    // 再传一次：内容没变，零字节实传。
    final FontSyncReport second = await FontSyncService(
      store: store,
      local: a,
      tempDir: tmp,
    ).upload();
    expect(second.filesUploaded, 0);
  });

  test('上传：超过上限的字体不传，并从清单与用途里摘掉', () async {
    final _FakeLocal a = device('a', FontCatalogState.empty());
    final File small = writeFont(a, 'small.ttf', <int>[1, 2]);
    final File big = writeFont(a, 'big.ttf', List<int>.filled(64, 7));
    a.state = stateOf(
      <FontCatalogEntry>[
        FontCatalogEntry(id: 'font_1', name: 'Small', path: small.path),
        FontCatalogEntry(id: 'font_2', name: 'Big', path: big.path),
      ],
      <String, List<FontTargetFont>>{
        'custom_fonts': const <FontTargetFont>[
          FontTargetFont(fontId: 'font_2', enabled: true),
          FontTargetFont(fontId: 'font_1', enabled: true),
        ],
      },
    );
    final FontSyncReport report = await FontSyncService(
      store: store,
      local: a,
      tempDir: tmp,
      maxFileBytes: 16,
    ).upload();
    expect(report.skippedOversize, <String>['Big']);
    final Map<String, Object?> manifest = store.json(kFontSyncManifestName)!;
    expect(
      (manifest['fonts']! as List<Object?>)
          .map((Object? f) => (f! as Map<String, Object?>)['name']),
      <String>['Small'],
    );
    expect(
      ((manifest['targets']! as Map<String, Object?>)['custom_fonts']!
              as List<Object?>)
          .length,
      1,
    );
  });

  test('下载：字体落地本机字体目录、用途换成对端的，本机原有字体不删', () async {
    final _FakeLocal a = device('a', FontCatalogState.empty());
    final File mincho = writeFont(a, 'mincho.ttf', utf8.encode('MINCHO'));
    a.state = stateOf(
      <FontCatalogEntry>[
        FontCatalogEntry(id: 'font_1', name: 'Mincho', path: mincho.path),
      ],
      <String, List<FontTargetFont>>{
        'custom_fonts': const <FontTargetFont>[
          FontTargetFont(fontId: 'font_1', enabled: true),
        ],
        'app_ui_fonts': const <FontTargetFont>[
          FontTargetFont(fontId: 'font_1', enabled: false),
        ],
      },
    );
    await FontSyncService(store: store, local: a, tempDir: tmp).upload();

    final _FakeLocal b = device('b', FontCatalogState.empty());
    final File local = writeFont(b, 'gothic.ttf', utf8.encode('GOTHIC'));
    b.state = stateOf(
      <FontCatalogEntry>[
        FontCatalogEntry(id: 'font_1', name: 'Gothic', path: local.path),
      ],
      <String, List<FontTargetFont>>{
        'custom_fonts': const <FontTargetFont>[
          FontTargetFont(fontId: 'font_1', enabled: true),
        ],
        'dict_fonts': const <FontTargetFont>[
          FontTargetFont(fontId: 'font_1', enabled: true),
        ],
      },
    );

    final FontSyncReport report = await FontSyncService(
      store: store,
      local: b,
      tempDir: tmp,
    ).download();
    expect(report.filesDownloaded, 1);
    expect(report.configApplied, isTrue);

    final FontCatalogState applied = b.applied!;
    // 本机原有字体还在，对端字体追加进来（新 id，不撞本机的 font_1）。
    expect(applied.fonts.map((FontCatalogEntry f) => f.name),
        <String>['Gothic', 'Mincho']);
    final FontCatalogEntry pulled = applied.fonts.last;
    expect(pulled.id, isNot('font_1'));
    expect(p.isWithin(b.fontsRoot, pulled.path!), isTrue);
    expect(File(pulled.path!).readAsStringSync(), 'MINCHO');
    // 对端提到的用途换成对端的；没提到的（词典）保持本机原样。
    expect(applied.targets['custom_fonts']!.single.fontId, pulled.id);
    expect(applied.targets['app_ui_fonts']!.single.enabled, isFalse);
    expect(applied.targets['dict_fonts']!.single.fontId, 'font_1');

    // 再下载一次：本机已有同一份内容，不重复下载，也不重复追加条目。
    b.state = applied;
    final FontSyncReport again = await FontSyncService(
      store: store,
      local: b,
      tempDir: tmp,
    ).download();
    expect(again.filesDownloaded, 0);
    expect(b.applied!.fonts.length, 2);
  });

  test('下载：清单里的非法文件名（路径穿越）一律不落盘', () async {
    final _FakeLocal b = device('b', FontCatalogState.empty());
    final String ns = await store.ensureNamespace(kSyncFontsNamespace);
    await store.putJsonAsset(ns, kFontSyncManifestName, <String, Object?>{
      'version': kFontSyncManifestVersion,
      'fonts': <Object?>[
        <String, Object?>{'id': 'x', 'name': 'Evil', 'file': '../../evil.ttf'},
      ],
      'targets': <String, Object?>{
        'custom_fonts': <Object?>[
          <String, Object?>{'fontId': 'x', 'enabled': true},
        ],
      },
    });
    final FontSyncReport report = await FontSyncService(
      store: store,
      local: b,
      tempDir: tmp,
    ).download();
    expect(report.filesDownloaded, 0);
    expect(b.applied!.fonts, isEmpty);
    expect(b.applied!.targets['custom_fonts'], isEmpty);
  });

  test('对端从没上传过字体：下载什么都不动', () async {
    final _FakeLocal b = device('b', FontCatalogState.empty());
    final FontSyncReport report = await FontSyncService(
      store: store,
      local: b,
      tempDir: tmp,
    ).download();
    expect(report.configApplied, isFalse);
    expect(b.applied, isNull);
  });
}

class _FakeLocal implements FontSyncLocal {
  _FakeLocal(this.fontsRoot, this.state);

  @override
  final String fontsRoot;
  FontCatalogState state;
  FontCatalogState? applied;

  @override
  Future<FontCatalogState> readState() async => state;

  @override
  Future<void> applyState(FontCatalogState next) async => applied = next;
}

/// 内存版资产存储：命名空间 = 名字，资产 id = `<ns>/<name>`。
class _MemoryStore implements SyncAssetStore {
  final Map<String, Map<String, List<int>>> _files =
      <String, Map<String, List<int>>>{};

  List<String> namesIn(String ns) => _files[ns]!.keys.toList();

  Map<String, Object?>? json(String name) {
    final List<int>? bytes = _files[kSyncFontsNamespace]?[name];
    if (bytes == null) return null;
    return (jsonDecode(utf8.decode(bytes)) as Map<dynamic, dynamic>)
        .cast<String, Object?>();
  }

  ({String ns, String name}) _split(String id) {
    final int i = id.indexOf('/');
    return (ns: id.substring(0, i), name: id.substring(i + 1));
  }

  @override
  Future<String> ensureNamespace(String name) async {
    _files.putIfAbsent(name, () => <String, List<int>>{});
    return name;
  }

  @override
  Future<String> ensureFolder(String parentId, String name) =>
      ensureNamespace('$parentId/$name');

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async =>
      <AssetEntry>[
        for (final String name in _files[namespaceId]?.keys ?? <String>[])
          AssetEntry(id: '$namespaceId/$name', name: name),
      ];

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async =>
      _files[namespaceId]?.containsKey(name) ?? false
          ? AssetEntry(id: '$namespaceId/$name', name: name)
          : null;

  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    SyncTransferProgress? onProgress,
  }) async {
    _files[namespaceId]![name] = file.readAsBytesSync();
  }

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    SyncTransferProgress? onProgress,
  }) async {
    final ({String ns, String name}) id = _split(assetId);
    destination.writeAsBytesSync(_files[id.ns]![id.name]!);
  }

  @override
  Future<Object?> getJsonAsset(String assetId) async {
    final ({String ns, String name}) id = _split(assetId);
    final List<int>? bytes = _files[id.ns]?[id.name];
    return bytes == null ? null : jsonDecode(utf8.decode(bytes));
  }

  @override
  Future<void> putJsonAsset(
    String namespaceId,
    String name,
    Object? json,
  ) async {
    _files[namespaceId]![name] = utf8.encode(jsonEncode(json));
  }

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    final ({String ns, String name}) parts = _split(id);
    _files[parts.ns]?.remove(parts.name);
  }
}
