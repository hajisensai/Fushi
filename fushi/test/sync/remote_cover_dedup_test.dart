import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:path/path.dart' as p;

void main() {
  // ── #4 远端书籍封面解析（相对 href → 绝对路径）──────────────────────────
  group('resolveEpubCoverFilePath', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi_cover_resolve');
    });

    tearDown(() {
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('相对 href 拼 extractDir 后命中（这正是 EPUB 书的封面存储形式）', () {
      final String extractDir = p.join(tmp.path, 'book');
      final String coverRel = p.join('OEBPS', 'images', 'cover.jpg');
      final File cover = File(p.join(extractDir, coverRel))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1, 2, 3]);

      final String? resolved = resolveEpubCoverFilePath(
        extractDir: extractDir,
        coverPath: coverRel,
      );

      expect(resolved, cover.path);
    });

    test('相对 href 带前导 / 也能正确拼接', () {
      final String extractDir = p.join(tmp.path, 'book2');
      final File cover = File(p.join(extractDir, 'cover-img.png'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[9]);

      final String? resolved = resolveEpubCoverFilePath(
        extractDir: extractDir,
        coverPath: '/cover-img.png',
      );

      expect(resolved, cover.path);
    });

    test('无声明封面但有约定名 cover.jpg → 回退命中', () {
      final String extractDir = p.join(tmp.path, 'book3');
      final File cover = File(p.join(extractDir, 'cover.jpg'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[7]);

      final String? resolved = resolveEpubCoverFilePath(
        extractDir: extractDir,
        coverPath: null,
      );

      expect(resolved, cover.path);
    });

    test('coverPath 已是存在的绝对路径（视频侧）→ 原样返回', () {
      final File cover = File(p.join(tmp.path, 'abs-cover.png'))
        ..writeAsBytesSync(<int>[5]);

      final String? resolved = resolveEpubCoverFilePath(
        extractDir: p.join(tmp.path, 'unrelated'),
        coverPath: cover.path,
      );

      expect(resolved, cover.path);
    });

    test('磁盘上没有任何封面文件 → null（不谎报有封面）', () {
      final String extractDir = p.join(tmp.path, 'empty');
      Directory(extractDir).createSync(recursive: true);

      final String? resolved = resolveEpubCoverFilePath(
        extractDir: extractDir,
        coverPath: p.join('OEBPS', 'cover.jpg'),
      );

      expect(resolved, isNull);
    });
  });

  // ── 本端「从所有设备删除」过的书不以远端占位卡复活 ────────────────────────
  group('filterOutLocallyDeletedRemoteBooks', () {
    const String title = 'Do Androids Dream of Electric Sheep?';
    final String titleKey = sanitizeTtuFilename(title);

    List<String> titles(List<RemoteBookInfo> books) =>
        books.map((RemoteBookInfo b) => b.title).toList();

    test('墓碑命中标题键：被删的那份剔除，其它书不动', () {
      final List<RemoteBookInfo> kept = filterOutLocallyDeletedRemoteBooks(
        remote: const <RemoteBookInfo>[
          RemoteBookInfo(title: title, hasContent: true, importedAt: 100),
          RemoteBookInfo(title: '别的书', hasContent: true, importedAt: 100),
        ],
        deletedKeys: <String>{titleKey},
        keyOf: sanitizeTtuFilename,
      );
      expect(titles(kept), <String>['别的书']);
    });

    test('墓碑写的是对端键（别名表）：按 host bookKey 命中', () {
      final List<RemoteBookInfo> kept = filterOutLocallyDeletedRemoteBooks(
        remote: const <RemoteBookInfo>[
          RemoteBookInfo(title: title, bookKey: 'host-key', hasContent: true),
        ],
        deletedKeys: <String>{'host-key'},
        keyOf: sanitizeTtuFilename,
      );
      expect(kept, isEmpty);
    });

    test('判据不看 host importedAt：host 时钟超前（importedAt 远晚于墓碑）照样藏', () {
      // 旧判据 importedAt > deletedAt 视为新书，host 时钟快几分钟就让刚删的书复活。
      final List<RemoteBookInfo> kept = filterOutLocallyDeletedRemoteBooks(
        remote: const <RemoteBookInfo>[
          RemoteBookInfo(title: title, hasContent: true, importedAt: 1 << 50),
        ],
        deletedKeys: <String>{titleKey},
        keyOf: sanitizeTtuFilename,
      );
      expect(kept, isEmpty);
    });

    test('没有有效墓碑时原样返回', () {
      const List<RemoteBookInfo> remote = <RemoteBookInfo>[
        RemoteBookInfo(title: title, hasContent: true),
      ];
      expect(
        filterOutLocallyDeletedRemoteBooks(
          remote: remote,
          deletedKeys: const <String>{},
          keyOf: sanitizeTtuFilename,
        ),
        same(remote),
      );
    });
  });

  group('pendingRemoteDeletionKeys（只比本端时钟）', () {
    const Map<String, int> tombstones = <String, int>{'a': 1000, 'b': 3000};

    test('互联 host：只有还没送达（deletedAt > 推送基线）的墓碑算数', () {
      expect(
        pendingRemoteDeletionKeys(
          deletedAtByKey: tombstones,
          sourceAppliesDeletions: true,
          deliveredThroughMs: 2000,
        ),
        <String>{'b'},
        reason: 'a 已送达 host 并被真删：之后清单里再有 a 就是 host 重新导入的新书',
      );
      expect(
        pendingRemoteDeletionKeys(
          deletedAtByKey: tombstones,
          sourceAppliesDeletions: true,
          deliveredThroughMs: 0,
        ),
        <String>{'a', 'b'},
        reason: '一条都没推出去：清单里那份必然是被删的那本',
      );
      expect(
        pendingRemoteDeletionKeys(
          deletedAtByKey: tombstones,
          sourceAppliesDeletions: true,
          deliveredThroughMs: 3000,
        ),
        isEmpty,
      );
    });

    test('云盘 / 媒体服务器从不执行墓碑：墓碑在就一直算数', () {
      expect(
        pendingRemoteDeletionKeys(
          deletedAtByKey: tombstones,
          sourceAppliesDeletions: false,
          deliveredThroughMs: 1 << 50,
        ),
        <String>{'a', 'b'},
      );
    });
  });

  group('filterOutLocallyDeletedRemoteVideos', () {
    RemoteVideoInfo video(String id) => RemoteVideoInfo(id: id, title: id);

    test('按 bookUid（RemoteVideoInfo.id）剔除，其它不动', () {
      final List<RemoteVideoInfo> kept = filterOutLocallyDeletedRemoteVideos(
        remote: <RemoteVideoInfo>[video('v1'), video('v2')],
        deletedKeys: <String>{'v1'},
      );
      expect(kept.map((RemoteVideoInfo v) => v.id), <String>['v2']);
    });

    test('没有有效墓碑时原样返回', () {
      final List<RemoteVideoInfo> remote = <RemoteVideoInfo>[video('v1')];
      expect(
        filterOutLocallyDeletedRemoteVideos(
          remote: remote,
          deletedKeys: const <String>{},
        ),
        same(remote),
      );
    });
  });

  // ── #6 远端/本地去重（同一本书/视频不在两区重复）──────────────────────────
  group('dedupeRemoteBooks', () {
    RemoteBookInfo book(String title) =>
        RemoteBookInfo(title: title, hasContent: true);

    test('本端已有同 key 的远端书被剔除', () {
      final List<RemoteBookInfo> remote = <RemoteBookInfo>[
        book('共有的书'),
        book('只在远端的书'),
      ];
      final Set<String> localKeys = <String>{sanitizeTtuFilename('共有的书')};

      final List<RemoteBookInfo> kept = dedupeRemoteBooks(
        remote: remote,
        localBookKeys: localKeys,
        keyOf: sanitizeTtuFilename,
      );

      expect(kept.map((RemoteBookInfo b) => b.title), <String>['只在远端的书']);
    });

    test('BUG-2274：标题含冒号，本端同书按 sanitize 键剔除；给文件夹名则剔不掉', () {
      const String title = 'Love, Death and Robots: The Official Anthology';
      final Set<String> localKeys = <String>{sanitizeTtuFilename(title)};
      expect(
        dedupeRemoteBooks(
          remote: <RemoteBookInfo>[book(title)],
          localBookKeys: localKeys,
          keyOf: sanitizeTtuFilename,
        ),
        isEmpty,
      );
      // 反例钉住形状：远端 title 若是 sanitize 过的文件夹名，二次 sanitize 成 %253A。
      expect(
        dedupeRemoteBooks(
          remote: <RemoteBookInfo>[book(sanitizeTtuFilename(title))],
          localBookKeys: localKeys,
          keyOf: sanitizeTtuFilename,
        ),
        hasLength(1),
      );
    });

    test('本端为空 → 全部保留', () {
      final List<RemoteBookInfo> remote = <RemoteBookInfo>[
        book('A'),
        book('B'),
      ];
      final List<RemoteBookInfo> kept = dedupeRemoteBooks(
        remote: remote,
        localBookKeys: const <String>{},
        keyOf: sanitizeTtuFilename,
      );
      expect(kept, hasLength(2));
    });

    test('本端含全部远端书 → 全部剔除', () {
      final List<RemoteBookInfo> remote = <RemoteBookInfo>[
        book('A'),
        book('B'),
      ];
      final Set<String> localKeys = <String>{
        sanitizeTtuFilename('A'),
        sanitizeTtuFilename('B'),
      };
      final List<RemoteBookInfo> kept = dedupeRemoteBooks(
        remote: remote,
        localBookKeys: localKeys,
        keyOf: sanitizeTtuFilename,
      );
      expect(kept, isEmpty);
    });
  });

  group('dedupeRemoteVideos', () {
    RemoteVideoInfo video(String id, String title) =>
        RemoteVideoInfo(id: id, title: title);

    test('本端已有同 bookUid 的远端视频被剔除', () {
      final List<RemoteVideoInfo> remote = <RemoteVideoInfo>[
        video('video/E01', 'E01'),
        video('video/E02', 'E02'),
      ];
      final Set<String> localUids = <String>{'video/E01'};

      final List<RemoteVideoInfo> kept = dedupeRemoteVideos(
        remote: remote,
        localBookUids: localUids,
      );

      expect(kept.map((RemoteVideoInfo v) => v.id), <String>['video/E02']);
    });

    test('本端为空 → 全部保留', () {
      final List<RemoteVideoInfo> remote = <RemoteVideoInfo>[
        video('video/x', 'x'),
      ];
      final List<RemoteVideoInfo> kept = dedupeRemoteVideos(
        remote: remote,
        localBookUids: const <String>{},
      );
      expect(kept, hasLength(1));
    });
  });
}
