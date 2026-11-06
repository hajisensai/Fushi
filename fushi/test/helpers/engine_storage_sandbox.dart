import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:path/path.dart' as p;

/// 给当前 group 的每个用例装一套独立的引擎存储沙盒：[enginePaths] 换成固定根、
/// EPUB 书目录指进同一个临时根，用例结束还原并删掉临时根。
///
/// 收下独立字幕书包会按 cue 生成正文 EPUB（BUG-4197），要临时目录与书目录；单测
/// 里 app 装配的路径走 path_provider，跑不起来。在 `group` 体里调用。
void useEngineStorageSandbox() {
  late Directory root;
  late EnginePaths previous;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-engine-sandbox-');
    final Directory temp = Directory(p.join(root.path, 'tmp'))
      ..createSync(recursive: true);
    previous = enginePaths;
    enginePaths = FixedEnginePaths(documents: root, support: root, temp: temp);
    EpubStorage.debugBaseDirectoryOverride = p.join(root.path, 'books');
  });

  tearDown(() async {
    enginePaths = previous;
    EpubStorage.debugBaseDirectoryOverride = null;
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Windows 上偶有句柄未放：临时根留给系统清理，不让收尾失败盖掉用例结果。
    }
  });
}
