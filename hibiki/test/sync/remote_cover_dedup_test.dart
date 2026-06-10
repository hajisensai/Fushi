import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:path/path.dart' as p;

void main() {
  // ── #4 远端书籍封面解析（相对 href → 绝对路径）──────────────────────────
  group('resolveEpubCoverFilePath', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hibiki_cover_resolve');
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

    test('本端为空 → 全部保留', () {
      final List<RemoteBookInfo> remote = <RemoteBookInfo>[
        book('A'),
        book('B')
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
        book('B')
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
