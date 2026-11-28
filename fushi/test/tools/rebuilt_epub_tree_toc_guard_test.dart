/// 守卫：EPUB 解压树换了（或 OPF 续了章）之后，目录必须和章节一起写回（UXtYShn4Yj）。
///
/// `EpubImporter.rebuildExtractedInPlace` / `reparseExtractedBook` /
/// `reindexExtractedBook` 都返回 `RebuiltEpubTree`（章节 + 目录 + 封面）。此前它们不带
/// 目录，五个调用方（就地恢复、来源扫描重建、字幕书换字幕、在线 / 网页小说重下与追章、
/// 漫画转回书）只写章节：目录 href 指向旧树里的文件，点目录跳到不存在的章。
///
/// 守什么：`lib/` 下（app 与引擎）每个调用这三个 API 的文件，非注释代码里必须出现
/// `.tocJson`（把结果的目录写回行）。定义它们的 `epub_importer.dart` 本身除外。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

const List<String> kRoots = <String>['lib', '../packages/fushi_engine/lib'];

const String kDefiningFile = 'epub/epub_importer.dart';

final RegExp kRebuildCall = RegExp(
  r'\b(rebuildExtractedInPlace|reparseExtractedBook|reindexExtractedBook)\b',
);

void main() {
  test('换了解压树的调用方都把目录写回行', () {
    final List<String> callers = <String>[];
    final List<String> missing = <String>[];
    for (final String root in kRoots) {
      for (final FileSystemEntity e in Directory(
        root,
      ).listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final String path = e.path.replaceAll('\\', '/');
        if (path.endsWith(kDefiningFile)) continue;
        final String code = maskComments(e.readAsStringSync());
        if (!kRebuildCall.hasMatch(code)) continue;
        callers.add(path);
        if (!code.contains('.tocJson')) missing.add(path);
      }
    }
    expect(callers, isNotEmpty, reason: '扫不到任何调用方：守卫的路径或 API 名失效了');
    expect(
      missing,
      isEmpty,
      reason: '这些文件换了解压树却没把 RebuiltEpubTree.tocJson 写回行',
    );
  });
}
