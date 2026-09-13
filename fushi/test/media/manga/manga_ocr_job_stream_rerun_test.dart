import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_ocr_job_stream.dart';
import 'package:path/path.dart' as p;

/// 「识别本章」对已有结果的章 = 重新识别：`onlyMissing=false` 先丢掉本引擎
/// 签名下的逐页缓存目录。这里钉死丢缓存这一步只动自己那一个目录。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('manga_ocr_rerun_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('discardMangaOcrPageCache：只删指定签名目录，兄弟签名目录保留', () async {
    final Directory mine = Directory(p.join(tmp.path, '_pages', 'sig-a'))
      ..createSync(recursive: true);
    File(p.join(mine.path, '0.json')).writeAsStringSync('{}');
    final Directory other = Directory(p.join(tmp.path, '_pages', 'sig-b'))
      ..createSync(recursive: true);
    File(p.join(other.path, '0.json')).writeAsStringSync('{}');

    await discardMangaOcrPageCache(mine);

    expect(mine.existsSync(), isFalse);
    expect(File(p.join(other.path, '0.json')).existsSync(), isTrue);
  });

  test('discardMangaOcrPageCache：目录不存在时无事发生', () async {
    final Directory missing = Directory(p.join(tmp.path, 'nope'));
    await discardMangaOcrPageCache(missing);
    expect(missing.existsSync(), isFalse);
  });
}
