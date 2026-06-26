// TODO-817 M1a SourceFileSystem 测试：
//  ① LocalSourceFileSystem 在临时目录建 epub/mp4/srt → listFiles 返回正确 entries
//     （isDirectory 正确 + recursive 行为）
//  ② listSiblingNames 找同目录同名 sidecar 候选
//  ③ readText 读回内容
//  ④ NetworkSourceFileSystem 每个方法抛 UnimplementedError（占位守卫）
//  ⑤ 命名守卫：SourceFileSystem 不与既有 abstract class MediaSource 撞名

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/source/source_file_system.dart';
import 'package:path/path.dart' as p;

void main() {
  group('LocalSourceFileSystem', () {
    late Directory tmp;
    const LocalSourceFileSystem fs = LocalSourceFileSystem();

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('m1a_local_fs_');
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('isLocal 恒 true', () {
      expect(fs.isLocal, isTrue);
    });

    test('listFiles 返回文件 + 子目录条目（非递归），isDirectory 正确', () async {
      await File(p.join(tmp.path, 'book.epub')).writeAsString('epub-bytes');
      await File(p.join(tmp.path, 'book.mp4')).writeAsString('mp4-bytes');
      await File(p.join(tmp.path, 'book.srt')).writeAsString('srt-bytes');
      final Directory sub = Directory(p.join(tmp.path, 'season1'));
      await sub.create();
      await File(p.join(sub.path, 'ep1.mp4')).writeAsString('ep1-bytes');

      final List<SourceFileEntry> entries = await fs.listFiles(tmp.path);

      final Map<String, SourceFileEntry> byName = <String, SourceFileEntry>{
        for (final SourceFileEntry e in entries) e.name: e,
      };

      // 非递归：直接子项 = 3 文件 + 1 目录，不含 sub 内的 ep1.mp4。
      expect(byName.keys.toSet(),
          <String>{'book.epub', 'book.mp4', 'book.srt', 'season1'});
      expect(byName['book.epub']!.isDirectory, isFalse);
      expect(byName['book.mp4']!.isDirectory, isFalse);
      expect(byName['book.srt']!.isDirectory, isFalse);
      expect(byName['season1']!.isDirectory, isTrue);

      // 文件条目带 sizeBytes，目录条目 sizeBytes 为 null。
      expect(byName['book.epub']!.sizeBytes, equals('epub-bytes'.length));
      expect(byName['season1']!.sizeBytes, isNull);

      // path 是完整绝对路径。
      expect(byName['book.epub']!.path, equals(p.join(tmp.path, 'book.epub')));
    });

    test('listFiles recursive=true 深度遍历只回文件', () async {
      await File(p.join(tmp.path, 'top.epub')).writeAsString('x');
      final Directory sub = Directory(p.join(tmp.path, 'season1'));
      await sub.create();
      await File(p.join(sub.path, 'ep1.mp4')).writeAsString('y');

      final List<SourceFileEntry> entries =
          await fs.listFiles(tmp.path, recursive: true);
      final Set<String> names =
          entries.map((SourceFileEntry e) => e.name).toSet();

      // 递归模式只回文件（含后代），不单列目录条目。
      expect(names, <String>{'top.epub', 'ep1.mp4'});
      expect(entries.every((SourceFileEntry e) => !e.isDirectory), isTrue);
    });

    test('listFiles 不存在的目录返回空列表（不抛）', () async {
      final List<SourceFileEntry> entries =
          await fs.listFiles(p.join(tmp.path, 'nope'));
      expect(entries, isEmpty);
    });

    test('listSiblingNames 返回同目录所有文件 basename（含自身，供 sidecar 匹配）', () async {
      final String main = p.join(tmp.path, 'book.epub');
      await File(main).writeAsString('x');
      await File(p.join(tmp.path, 'book.srt')).writeAsString('x');
      await File(p.join(tmp.path, 'book 01.mp3')).writeAsString('x');
      await File(p.join(tmp.path, 'other.txt')).writeAsString('x');

      final List<String> names = await fs.listSiblingNames(main);
      expect(names.toSet(),
          <String>{'book.epub', 'book.srt', 'book 01.mp3', 'other.txt'});
    });

    test('listSiblingNames 目录不可读返回空列表（不抛）', () async {
      final List<String> names =
          await fs.listSiblingNames(p.join(tmp.path, 'gone', 'book.epub'));
      expect(names, isEmpty);
    });

    test('readText 读回写入的内容', () async {
      final String path = p.join(tmp.path, 'sub.srt');
      const String content = '1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n';
      await File(path).writeAsString(content);

      expect(await fs.readText(path), equals(content));
    });

    test('copyToLocal 本地传输原样返回原路径（不复制）', () async {
      final String path = p.join(tmp.path, 'book.epub');
      await File(path).writeAsString('x');
      expect(await fs.copyToLocal(path, tmp.path), equals(path));
    });
  });

  group('NetworkSourceFileSystem 占位守卫', () {
    const NetworkSourceFileSystem fs = NetworkSourceFileSystem();

    test('isLocal 恒 false', () {
      expect(fs.isLocal, isFalse);
    });

    test('listFiles 抛 UnimplementedError', () {
      expect(() => fs.listFiles('/remote/dir'),
          throwsA(isA<UnimplementedError>()));
    });

    test('listSiblingNames 抛 UnimplementedError', () {
      expect(() => fs.listSiblingNames('/remote/book.epub'),
          throwsA(isA<UnimplementedError>()));
    });

    test('readText 抛 UnimplementedError', () {
      expect(() => fs.readText('/remote/book.srt'),
          throwsA(isA<UnimplementedError>()));
    });

    test('copyToLocal 抛 UnimplementedError', () {
      expect(() => fs.copyToLocal('/remote/book.epub', '/tmp'),
          throwsA(isA<UnimplementedError>()));
    });
  });

  group('命名守卫', () {
    test('LocalSourceFileSystem / NetworkSourceFileSystem 都是 SourceFileSystem',
        () {
      const SourceFileSystem local = LocalSourceFileSystem();
      const SourceFileSystem network = NetworkSourceFileSystem();
      expect(local, isA<SourceFileSystem>());
      expect(network, isA<SourceFileSystem>());
    });

    test('源文件用 SourceFileSystem 命名，不与既有 MediaSource 撞名', () {
      final File src = File(p.join(
        Directory.current.path,
        'lib',
        'src',
        'media',
        'source',
        'source_file_system.dart',
      ));
      final String text = src.readAsStringSync();
      expect(text.contains('abstract class SourceFileSystem'), isTrue,
          reason: '接口必须命名为 SourceFileSystem');
      // 守 MediaSource 撞名：匹配「行首的类声明」（多行模式），用单词边界排除
      // MediaSourceRow / 注释里的引用（注释行以 // 开头，不会命中行首 class）。
      final RegExp mediaSourceDecl =
          RegExp(r'^(abstract )?class MediaSource', multiLine: true);
      expect(mediaSourceDecl.hasMatch(text), isFalse,
          reason: '不得在本文件声明 MediaSource 类（已存在于 media_source.dart）');
    });
  });
}
