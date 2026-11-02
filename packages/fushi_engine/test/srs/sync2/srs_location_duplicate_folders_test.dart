// 云盘位置的同名文件夹（PR #2768 审查）：Google Drive 允许同名文件夹、`ensureFolder` 是「先查后建」不原子。
// - 同一后端上不同的位置实例（一轮同步 / 发段前的媒体上传 / 完整媒体对账 / 后台旧根迁移各建一个）并发往同一个新目录写：
//   每级文件夹只建一次（按后端身份进程内单飞，包装每次新建一层时按里层认）；
// - 已经建重了的（别的设备 / 旧版本）：列目录取并集、读 / 查 / 删 / 覆盖写在每一个里找，对象不会因为落进第二个同名
//   文件夹就对所有读者不可见。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:test/test.dart';

void main() {
  late _DriveLikeStore drive;

  setUp(() => drive = _DriveLikeStore());

  SrsAssetLocationStore location(SyncAssetStore store, {Object? identity}) =>
      SrsAssetLocationStore(
        store: store,
        profileUid: 'p',
        backendIdentity: identity,
      );

  Uint8List bytes(int v) => Uint8List.fromList(<int>[v]);

  group('并发建目录：同一后端上每级文件夹只建一次', () {
    test('不同实例并发写进同一个新前缀目录', () async {
      final List<SrsAssetLocationStore> locs = <SrsAssetLocationStore>[
        for (int i = 0; i < 4; i++) location(drive),
      ];
      await Future.wait(<Future<void>>[
        for (int i = 0; i < 4; i++) locs[i].putNew('media/ab/ab$i', bytes(i)),
      ]);
      expect(drive.foldersNamed('v3'), 1);
      expect(drive.foldersNamed('media'), 1);
      expect(drive.foldersNamed('ab'), 1);
      expect(
        (await location(
          drive,
        ).list('media/ab')).map((SrsLocationEntry e) => e.name),
        unorderedEquals(<String>['ab0', 'ab1', 'ab2', 'ab3']),
      );
    });

    test('每次新包一层的后端（防扫盘混淆）：按传入的后端身份（里层）单飞', () async {
      await Future.wait(<Future<void>>[
        for (int i = 0; i < 3; i++)
          location(
            _Wrapper(drive),
            identity: drive,
          ).putNew('media/cd/cd$i', bytes(i)),
      ]);
      expect(drive.foldersNamed('media'), 1);
      expect(drive.foldersNamed('cd'), 1);
    });
  });

  group('已经建重了的同名文件夹：读写都看全部', () {
    late String first;
    late String second;

    setUp(() async {
      // 别的设备 / 旧版本留下两个 `media/ab/`：各有一个对象，`z` 两边都有一份旧的。
      final String ns = drive.rawFolder(_DriveLikeStore.rootId, 'fushi-srs');
      final String profile = drive.rawFolder(ns, 'p');
      final String v3 = drive.rawFolder(profile, 'v3');
      final String media = drive.rawFolder(v3, 'media');
      first = drive.rawFolder(media, 'ab');
      second = drive.rawFolder(media, 'ab');
      drive.rawFile(first, 'x', <int>[1]);
      drive.rawFile(second, 'y', <int>[2]);
      drive.rawFile(first, 'z', <int>[3]);
      drive.rawFile(second, 'z', <int>[4]);
    });

    test('列目录取并集；同名子文件夹只列一次', () async {
      expect(
        (await location(
          drive,
        ).list('media/ab')).map((SrsLocationEntry e) => e.name),
        unorderedEquals(<String>['x', 'y', 'z']),
      );
      final List<SrsLocationEntry> prefixes = await location(
        drive,
      ).list('media');
      expect(prefixes.map((SrsLocationEntry e) => e.name), <String>['ab']);
    });

    test('第二个文件夹里的对象读得到、查得到', () async {
      expect(await location(drive).get('media/ab/y'), <int>[2]);
      expect(await location(drive).exists('media/ab/y'), isTrue);
      final File dst = File(
        '${Directory.systemTemp.path}/srs_dup_${DateTime.now().microsecondsSinceEpoch}',
      );
      addTearDown(() {
        if (dst.existsSync()) dst.deleteSync();
      });
      expect(await location(drive).getFile('media/ab/y', dst), isTrue);
      expect(dst.readAsBytesSync(), <int>[2]);
    });

    test('putNew 在任一同名文件夹里已有就不再写', () async {
      await location(drive).putNew('media/ab/y', bytes(9));
      expect(drive.filesNamed('y'), 1);
    });

    test('删：每个同名文件夹里的那份都删掉（列过 / 没列过都一样）', () async {
      await location(drive).delete('media/ab/z');
      expect(drive.filesNamed('z'), 0);
      drive.rawFile(first, 'z', <int>[3]);
      drive.rawFile(second, 'z', <int>[4]);
      final SrsAssetLocationStore listed = location(drive);
      await listed.list('media/ab');
      await listed.delete('media/ab/z');
      expect(drive.filesNamed('z'), 0);
    });

    test('覆盖写：别的同名文件夹里的旧份也删，读回新内容', () async {
      await location(drive).put('media/ab/z', bytes(7));
      expect(drive.filesNamed('z'), 1);
      expect(await location(drive).get('media/ab/z'), <int>[7]);
    });
  });

  group('集合根这两级（<profileUid> / <folder>）建重了：同样看全部', () {
    late String ns;
    late String profileA;
    late String profileB;

    setUp(() {
      // 两台设备首次同步并发：各建了一个 `p/`，其中一个下面又并发建了两个 `v3/`。
      ns = drive.rawFolder(_DriveLikeStore.rootId, 'fushi-srs');
      profileA = drive.rawFolder(ns, 'p');
      profileB = drive.rawFolder(ns, 'p');
      final String v3a = drive.rawFolder(profileA, 'v3');
      final String v3b1 = drive.rawFolder(profileB, 'v3');
      final String v3b2 = drive.rawFolder(profileB, 'v3');
      drive.rawFile(v3a, 'head-a', <int>[1]);
      drive.rawFile(v3b1, 'head-b', <int>[2]);
      final String segs = drive.rawFolder(v3b2, 'segs');
      drive.rawFile(segs, 's1', <int>[3]);
    });

    test('列集合根取三个根的并集；每个根里的对象读得到', () async {
      expect(
        (await location(drive).list('')).map((SrsLocationEntry e) => e.name),
        unorderedEquals(<String>['head-a', 'head-b', 'segs']),
      );
      expect(await location(drive).get('head-a'), <int>[1]);
      expect(await location(drive).get('head-b'), <int>[2]);
      expect(await location(drive).get('segs/s1'), <int>[3]);
      expect(await location(drive).exists('segs/s1'), isTrue);
    });

    test('不再建新的根；删在每个根里找', () async {
      await location(drive).put('head-c', bytes(4));
      expect(drive.foldersNamed('p'), 2);
      expect(drive.foldersNamed('v3'), 3);
      expect(await location(drive).get('head-c'), <int>[4]);
      await location(drive).delete('head-b');
      expect(drive.filesNamed('head-b'), 0);
    });

    test('写目标与后端列目录的顺序无关：不同顺序的读者写进同一个根', () async {
      await location(drive).put('w1', bytes(5));
      drive.reverseListings = true;
      await location(drive).put('w2', bytes(6));
      String parentOf(String name) => drive.nodes.values
          .singleWhere((_Node n) => !n.isFolder && n.name == name)
          .parent;
      expect(parentOf('w1'), parentOf('w2'));
    });
  });
}

class _Node {
  _Node(this.parent, this.name, {this.isFolder = false, this.bytes});

  final String parent;
  final String name;
  final bool isFolder;
  final List<int>? bytes;
}

/// Google Drive 的语义：同名文件夹 / 同名文件可以并存；`ensureFolder` 先查后建（中间有一次网络往返），不原子。
class _DriveLikeStore implements SyncAssetStore {
  static const String rootId = 'root';
  final Map<String, _Node> nodes = <String, _Node>{};
  int _next = 0;

  /// 列目录 / 按名找文件夹倒序返回（Drive `files.list` 不带 orderBy 时顺序不确定）。
  bool reverseListings = false;

  String _add(_Node n) {
    final String id = 'n${_next++}';
    nodes[id] = n;
    return id;
  }

  String rawFolder(String parent, String name) =>
      _add(_Node(parent, name, isFolder: true));

  String rawFile(String parent, String name, List<int> content) =>
      _add(_Node(parent, name, bytes: content));

  int foldersNamed(String name) =>
      nodes.values.where((_Node n) => n.isFolder && n.name == name).length;

  int filesNamed(String name) =>
      nodes.values.where((_Node n) => !n.isFolder && n.name == name).length;

  @override
  Future<String> ensureNamespace(String name) => ensureFolder(rootId, name);

  @override
  Future<String> ensureFolder(String parentId, String name) async {
    final List<String> found = <String>[
      for (final MapEntry<String, _Node> e in nodes.entries)
        if (e.value.parent == parentId &&
            e.value.isFolder &&
            e.value.name == name)
          e.key,
    ];
    if (found.isNotEmpty) {
      return reverseListings ? found.last : found.first;
    }
    // 查完到建之间的网络往返：并发的调用都看到「没有」，各建一个。
    await Future<void>.delayed(const Duration(milliseconds: 2));
    return rawFolder(parentId, name);
  }

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    final List<AssetEntry> out = <AssetEntry>[
      for (final MapEntry<String, _Node> e in nodes.entries)
        if (e.value.parent == namespaceId)
          AssetEntry(
            id: e.key,
            name: e.value.name,
            isFolder: e.value.isFolder,
            sizeBytes: e.value.bytes?.length,
          ),
    ];
    return reverseListings ? out.reversed.toList() : out;
  }

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async {
    for (final MapEntry<String, _Node> e in nodes.entries) {
      if (e.value.parent == namespaceId &&
          !e.value.isFolder &&
          e.value.name == name) {
        return AssetEntry(
          id: e.key,
          name: name,
          sizeBytes: e.value.bytes?.length,
        );
      }
    }
    return null;
  }

  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    SyncTransferProgress? onProgress,
  }) async {
    rawFile(namespaceId, name, await file.readAsBytes());
  }

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    SyncTransferProgress? onProgress,
  }) async {
    final _Node? n = nodes[assetId];
    if (n == null || n.isFolder) throw StateError('no asset $assetId');
    await destination.writeAsBytes(n.bytes!, flush: true);
  }

  @override
  Future<Object?> getJsonAsset(String assetId) =>
      throw UnimplementedError('getJsonAsset');

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      throw UnimplementedError('putJsonAsset');

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    nodes.remove(id);
  }
}

/// 每次新建的一层包装（同防扫盘混淆：`ensureFolder` 原样透传）。
class _Wrapper implements SyncAssetStore {
  _Wrapper(this.inner);

  final SyncAssetStore inner;

  @override
  Future<String> ensureNamespace(String name) => inner.ensureNamespace(name);
  @override
  Future<String> ensureFolder(String parentId, String name) =>
      inner.ensureFolder(parentId, name);
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      inner.listChildren(namespaceId);
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) =>
      inner.findAsset(namespaceId, name);
  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    SyncTransferProgress? onProgress,
  }) => inner.putAsset(namespaceId, name, file, onProgress: onProgress);
  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    SyncTransferProgress? onProgress,
  }) => inner.getAsset(assetId, destination, onProgress: onProgress);
  @override
  Future<Object?> getJsonAsset(String assetId) => inner.getJsonAsset(assetId);
  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      inner.putJsonAsset(namespaceId, name, json);
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) =>
      inner.deleteAsset(id, isFolder: isFolder);
}
