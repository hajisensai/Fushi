import 'dart:io';

import 'package:fushi/src/media/sources/book_cover_file_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 书架封面解析的异步版（UI isolate 上不同步列目录）必须与同步版逐字一致。
void main() {
  group('resolveBookCoverCaseInsensitiveAsync 与同步版同规则', () {
    final Map<String, List<String>> tree = <String, List<String>>{
      '/x/Book': <String>['/x/Book/OEBPS', '/x/Book/cover.jpg'],
      '/x/Book/OEBPS': <String>['/x/Book/OEBPS/Images'],
      '/x/Book/OEBPS/Images': <String>['/x/Book/OEBPS/Images/Cover.jpg'],
    };
    List<String> listDir(String d) => tree[d] ?? const <String>[];

    for (final List<String> rels in <List<String>>[
      <String>['oebps/images/cover.jpg'],
      <String>['oebps/images/cover.jpg', 'cover.jpg'],
      <String>['oebps/images/missing.jpg', 'cover.jpg'],
      <String>['nope/none.png'],
      <String>['/etc/passwd'],
      <String>['', './', 'COVER.JPG'],
    ]) {
      test('候选 $rels', () async {
        final String? sync = resolveBookCoverCaseInsensitive(
          extractDir: '/x/Book',
          relPaths: rels,
          listDir: listDir,
        );
        final String? async = await resolveBookCoverCaseInsensitiveAsync(
          extractDir: '/x/Book',
          relPaths: rels,
          listDir: (String d) async => listDir(d),
        );
        expect(async, sync);
      });
    }

    test('一次调用内同一目录只列一次', () async {
      final Map<String, int> calls = <String, int>{};
      final String? r = await resolveBookCoverCaseInsensitiveAsync(
        extractDir: '/x/Book',
        relPaths: <String>[
          'oebps/images/missing.jpg',
          'Cover.jpeg',
          'cover.png',
          'oebps/images/none.png',
        ],
        listDir: (String d) async {
          calls[d] = (calls[d] ?? 0) + 1;
          return listDir(d);
        },
      );
      expect(r, isNull);
      expect(calls, <String, int>{
        '/x/Book': 1,
        '/x/Book/OEBPS': 1,
        '/x/Book/OEBPS/Images': 1,
      });
    });
  });

  group('resolveBookCoverFilePathAsync 真实文件系统', () {
    late Directory tempDir;
    setUp(
      () => tempDir = Directory.systemTemp.createTempSync('fushi_cover_a_'),
    );
    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('大小写失配的声明封面解析到真实文件，与同步版一致', () async {
      final String extractDir = p.join(tempDir.path, 'CaseBook');
      File(p.join(extractDir, 'OEBPS', 'Images', 'Cover.jpg'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);
      final String? sync = resolveBookCoverFilePath(
        extractDir: extractDir,
        coverPath: 'oebps/images/cover.jpg',
      );
      final String? async = await resolveBookCoverFilePathAsync(
        extractDir: extractDir,
        coverPath: 'oebps/images/cover.jpg',
      );
      expect(sync, isNotNull);
      expect(async, sync);
    });

    test('无声明封面回落 cover.jpg；什么都没有 / 目录不存在返回 null', () async {
      final String extractDir = p.join(tempDir.path, 'Plain');
      Directory(extractDir).createSync();
      expect(
        await resolveBookCoverFilePathAsync(extractDir: extractDir),
        isNull,
      );
      File(p.join(extractDir, 'cover.jpg')).writeAsBytesSync(<int>[1]);
      expect(
        await resolveBookCoverFilePathAsync(extractDir: extractDir),
        resolveBookCoverFilePath(extractDir: extractDir),
      );
      expect(
        await resolveBookCoverFilePathAsync(
          extractDir: p.join(tempDir.path, 'missing'),
          coverPath: 'cover.jpg',
        ),
        isNull,
      );
    });
  });
}
