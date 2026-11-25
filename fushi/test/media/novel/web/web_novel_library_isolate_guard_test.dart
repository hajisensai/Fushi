// 守卫：网页小说书的新建 / 就地重建不在 UI isolate 上读盘、打 ZIP（#3722 c40 遗留）。
//
// 以前 `WebNovelLibrary.save` / `ensureTrailingPlaceholder` 在调用方 isolate 上逐章
// 同步读旧解压树（`readLnReaderLoadedChapter`）、再同步 `LnReaderEpubAssembler.build`
// 打包，长连载追一章界面就停一下。现在两者都经 `buildWebNovelEpubInBackground`
// （一次性后台 isolate）；组装结果的正确性由 web_novel_library_test 走真实入口钉着。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final String src = File(
    p.join('lib', 'src', 'media', 'novel', 'web', 'web_novel_library.dart'),
  ).readAsStringSync();
  final int classStart = src.indexOf('class WebNovelLibrary {');
  final int classEnd = src.indexOf('\n}\n', classStart);
  final String cls = src.substring(classStart, classEnd);

  test('WebNovelLibrary 里没有同步读旧章 / 同步打包', () {
    expect(classStart, isNonNegative);
    expect(cls, isNot(contains('readLnReaderLoadedChapter(')));
    expect(cls, isNot(contains('LnReaderEpubAssembler.build(')));
  });

  test('新建 / 并章 / 补占位都走后台组装', () {
    expect(
      'await buildWebNovelEpubInBackground('.allMatches(cls).length,
      3,
      reason: 'save 的并进已有书 / 新建书与 ensureTrailingPlaceholder 各一处',
    );
    expect(src, contains('Isolate.run<Uint8List>('));
  });
}
