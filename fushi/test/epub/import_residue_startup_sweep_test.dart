// 导入残留的启动清扫挂点（BUG-4841，#3722 c07 遗留）。
//
// 清扫本身由 epub_import_dir_ownership_test 钉着；这里钉两件事：
//  - [EpubImporter.ensureImportResidueSwept] 不经任何导入就把上个进程的残留收掉，
//    活行目录不动；
//  - app 启动（`AppModel._initialiseOnce`）开库后真的调了它——以前只在下一次导入 /
//    孤儿书找回时才清，崩溃残留会一直留着。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('不经导入：上个进程的 .tmp-* 暂存被删、无主 bak 改回原名', () async {
    final Directory tempRoot = Directory.systemTemp.createTempSync(
      'import_residue_startup_',
    );
    EpubStorage.debugBaseDirectoryOverride = tempRoot.path;
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      await db.close();
      EpubStorage.debugBaseDirectoryOverride = null;
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });
    final String booksRoot = p.join(tempRoot.path, 'fushi_books');
    void writeFile(String rel) {
      final File f = File(p.join(booksRoot, rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('x');
    }

    writeFile(p.join('.tmp-1-0', 'half.xhtml'));
    // 进程死在「旧树改名 bak」与「新树就位」之间：bak 是那本书唯一的副本。
    writeFile(p.join('Book.bak-1700000000000', 'chapter.xhtml'));

    await EpubImporter.ensureImportResidueSwept(db);

    final List<String> names =
        Directory(booksRoot)
            .listSync(followLinks: false)
            .map((FileSystemEntity e) => p.basename(e.path))
            .toList()
          ..sort();
    expect(names, <String>['Book']);
    expect(
      File(p.join(booksRoot, 'Book', 'chapter.xhtml')).existsSync(),
      isTrue,
    );
  });

  test('AppModel 启动开库后调一次导入残留清扫', () {
    final String src = File(
      p.join('lib', 'src', 'models', 'app_model.dart'),
    ).readAsStringSync();
    final int start = src.indexOf('Future<void> _initialiseOnce() async {');
    expect(start, isNonNegative, reason: '找不到 _initialiseOnce');
    final int openDb = src.indexOf("label: 'main',", start);
    final int done = src.indexOf("debugPrint('[Fushi] init: DONE');", start);
    expect(openDb, greaterThan(start));
    expect(done, greaterThan(openDb));
    final String afterOpen = src.substring(openDb, done);
    expect(
      afterOpen,
      contains('EpubImporter.ensureImportResidueSwept(_database)'),
      reason: '残留清扫要挂在 app 启动开库之后，不能只等下一次导入',
    );
  });
}
