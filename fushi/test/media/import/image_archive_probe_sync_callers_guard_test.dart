// 守卫：生产代码不再在调用方 isolate 上同步开包定性（BUG-4909 遗留，#3722 c39）。
//
// `MangaArchiveImporter.looksLikeImageArchive` 对 `.epub` 要整本解析 spine 才分得清
// 纯图 / 有正文：在 app 的 UI isolate 或服务端事件循环上同步跑，一本几百 MB 的文字
// EPUB 就让界面 / 所有请求停住；不给探测目录时还解进系统临时目录（崩溃残留 app 内
// 看不见也清不掉）。唯一入口是 `looksLikeImageArchiveInBackground(path, db:)`
// （后台 isolate + 书库根 `.tmp-*`），`MangaModule.probeImageArchive` 是它的 app 包装。
//
// 以前漏网的三处：书籍导入框（book_import_dialog.dart）、操作目录导入
// （ctl_library_import.dart）、服务端 `import auto` 路由（import_commands.dart）。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 去掉 `//` 注释后的代码行（文档注释里提到旧调用不算）。
Iterable<String> _codeLines(File f) sync* {
  for (final String line in f.readAsLinesSync()) {
    final int comment = line.indexOf('//');
    yield comment < 0 ? line : line.substring(0, comment);
  }
}

void main() {
  test('同步开包判据只在后台探测入口里被调用', () {
    final List<String> roots = <String>[
      'lib',
      p.join('..', 'packages', 'fushi_engine', 'lib'),
      p.join('..', 'packages', 'fushi_server', 'lib'),
    ];
    final String probeFile = p.normalize(
      p.join(
        '..',
        'packages',
        'fushi_engine',
        'lib',
        'media',
        'manga',
        'manga_archive_probe.dart',
      ),
    );
    final List<String> offenders = <String>[];
    for (final String root in roots) {
      for (final FileSystemEntity e in Directory(
        root,
      ).listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final String path = p.normalize(e.path);
        int n = 0;
        for (final String code in _codeLines(e)) {
          n++;
          final bool syncProbe =
              code.contains('MangaModule.isImageArchive') ||
              (code.contains('MangaArchiveImporter.looksLikeImageArchive(') &&
                  path != probeFile);
          if (syncProbe) offenders.add('$path:$n');
        }
      }
    }
    // MangaModule.isImageArchive 的定义本身是 `=> MangaArchiveImporter...`，不算调用。
    offenders.removeWhere(
      (String o) => o.startsWith(
        p.normalize(
          p.join('lib', 'src', 'media', 'manga', 'manga_module.dart'),
        ),
      ),
    );
    expect(
      offenders,
      isEmpty,
      reason: '改用 looksLikeImageArchiveInBackground(db:)',
    );
  });
}
