import 'dart:io';

import 'package:fushi_audio/src/audiobook/audiobook_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `AudiobookStorage.adoptFile`：持久化步骤接管调用方的临时文件（同卷 rename），
/// 调用方不再自己删——删除失败不会盖掉已成功的导入结果。
void main() {
  late Directory tmp;
  late Directory persistDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_adopt_test_');
    persistDir = Directory(p.join(tmp.path, 'persist'))
      ..createSync(recursive: true);
  });
  tearDown(() => tmp.delete(recursive: true));

  test('把临时文件搬进持久目录：源文件不在原处，内容保留', () async {
    final File src = File(p.join(tmp.path, 'abs_item_Book.srt'))
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhi\n');
    final String dest = await AudiobookStorage.adoptFile(src, persistDir);
    expect(p.isWithin(persistDir.path, dest), isTrue);
    expect(p.basename(dest), 'abs_item_Book.srt');
    expect(src.existsSync(), isFalse);
    expect(File(dest).readAsStringSync(), contains('hi'));
  });

  test('同名冲突时与 persistFileWithProgress 同样加序号，不覆盖', () async {
    File(p.join(persistDir.path, 'a.srt')).writeAsStringSync('OLD');
    final File src = File(p.join(tmp.path, 'a.srt'))..writeAsStringSync('NEW');
    final String dest = await AudiobookStorage.adoptFile(src, persistDir);
    expect(p.basename(dest), 'a _1.srt');
    expect(File(p.join(persistDir.path, 'a.srt')).readAsStringSync(), 'OLD');
    expect(File(dest).readAsStringSync(), 'NEW');
  });

  test('源文件已在持久目录里：原样返回，不动它', () async {
    final File inside = File(p.join(persistDir.path, 'x.srt'))
      ..writeAsStringSync('X');
    expect(await AudiobookStorage.adoptFile(inside, persistDir), inside.path);
    expect(inside.existsSync(), isTrue);
  });
}
