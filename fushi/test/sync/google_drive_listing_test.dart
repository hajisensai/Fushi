import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/google_drive_listing.dart';
import 'package:fushi/src/sync/sync_remote_listing.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';

/// 一棵假 Drive：按 `q` 里的 `'<id>' in parents` 返回直接子项，按 [pageSize] 分页。
class _FakeDrive {
  _FakeDrive(this.files);

  final List<DriveListedFile> files;

  /// 故意很小，逼出多页分页。
  static const int pageSize = 2;
  final List<String> queries = <String>[];

  /// 被问过「直接子项」的父 id（不论哪条查询）。
  final Set<String> askedParents = <String>{};

  static final RegExp _parent = RegExp(r"'((?:[^'\\]|\\.)*)' in parents");

  Future<({List<DriveListedFile> files, String? nextPageToken})> listPage(
    String query,
    String? pageToken,
  ) async {
    queries.add(query);
    expect(query, contains('trashed=false'));
    final Set<String> parents = _parent
        .allMatches(query)
        .map((RegExpMatch m) => m.group(1)!.replaceAll(r"\'", "'"))
        .toSet();
    expect(parents, isNotEmpty, reason: '每条查询都必须以父目录为界: $query');
    askedParents.addAll(parents);
    final List<DriveListedFile> matched = files
        .where((DriveListedFile f) => f.parents.any(parents.contains))
        .toList();
    final int start = pageToken == null ? 0 : int.parse(pageToken);
    final int end = (start + pageSize).clamp(0, matched.length);
    return (
      files: matched.sublist(start, end),
      nextPageToken: end < matched.length ? '$end' : null,
    );
  }
}

DriveListedFile _folder(String id, String name, String parent) =>
    (id: id, name: name, parents: <String>[parent], isFolder: true);

DriveListedFile _file(String id, String name, List<String> parents) =>
    (id: id, name: name, parents: parents, isFolder: false);

Map<String, List<String>> _shape(RemoteListingSnapshot s) =>
    <String, List<String>>{
      for (final MapEntry<String, List<AssetEntry>> e in s.folders.entries)
        e.key: (e.value.map((AssetEntry a) => '${a.name}#${a.id}').toList()
          ..sort()),
    };

void main() {
  test('只列同步根下深度 1 + 2：复习同步 v2 的深层分段一个都不拉', () async {
    final List<DriveListedFile> files = <DriveListedFile>[
      _folder('b1', 'Book One', 'root'),
      _folder('b2', "Book 'Two'", 'root'),
      _folder('empty', 'Empty Book', 'root'),
      _file('stray', 'progress_spill.json', <String>['root']),
      _file('p1', 'progress_1_2.json', <String>['b1']),
      _file('s1', 'statistics_1.json', <String>['b1']),
      _file('p2', 'progress_3_4.json', <String>['b2']),
      // 同时挂在两本书下的条目：每个落在根下的父各记一次（与旧实现一致）。
      _file('shared', 'cover.jpg', <String>['b1', 'b2']),
      _folder('srs', 'fushi-srs', 'root'),
      _folder('uid', 'profile-uid', 'srs'),
      _folder('v2', 'v2', 'uid'),
      _folder('devices', 'devices', 'v2'),
      for (int i = 0; i < 200; i++)
        _file('seg$i', 'seg-$i.bin', <String>['devices']),
      // 根外的东西（共享模式下的可见 My Drive）不得进入快照。
      _folder('other', 'Unrelated', 'elsewhere'),
      _file('o1', 'x.txt', <String>['other']),
    ];
    final _FakeDrive drive = _FakeDrive(files);

    final RemoteListingSnapshot snapshot = await listDriveSyncRoot(
      rootFolder: 'root',
      listPage: drive.listPage,
      parentBatch: 2,
    );

    expect(_shape(snapshot), <String, List<String>>{
      'Book One': <String>[
        'cover.jpg#shared',
        'progress_1_2.json#p1',
        'statistics_1.json#s1',
      ],
      "Book 'Two'": <String>['cover.jpg#shared', 'progress_3_4.json#p2'],
      'Empty Book': <String>[],
      'fushi-srs': <String>['profile-uid#uid'],
    });
    expect(snapshot.hasFolder('Empty Book'), isTrue);
    expect(snapshot.hasFolder('Unrelated'), isFalse);

    // 只问过根与根的直接子文件夹；v2 / devices 这些深层目录从没被列举。
    expect(drive.askedParents, <String>{'root', 'b1', 'b2', 'empty', 'srs'});
    // 请求数与深层文件数（200 个分段）无关：根 2 页 + 4 个子文件夹按 2 个一组 = 2 组，
    // 每组再按 2 条一页分页。
    expect(drive.queries.length, lessThan(10));
  });

  test('父目录 id 里的单引号与反斜杠会被转义', () {
    expect(escapeDriveQuery(r"a'b\c"), r"a\'b\\c");
  });
}
