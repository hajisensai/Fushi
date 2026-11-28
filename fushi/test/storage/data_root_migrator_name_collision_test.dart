import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/data_root_migrator.dart';
import 'package:fushi/src/storage/sandbox_relocation.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show dataRootMigrationFailureHint, dataRootMigrationFailureMessage;

/// Android 书库搬到外部（`Android/data/<包名>/files/data`）走逐文件复制。内部存储区分
/// 大小写，外部（`/data/media` casefold）不区分：在模拟器上实测 `echo one > Img.png;
/// echo twotwo > img.png` 之后外部只剩一个 `Img.png`、内容是 `twotwo`。旧实现照常复制，
/// 后写的文件冲掉先写的，逐文件字节数校验比的是后写那份、照样通过，提交后删源 —— 先写的
/// 那个文件永久丢失。这里钉住：复制前就拒绝、旧根原样、目标清干净、不提交。
void main() {
  late Directory tmp;
  late Directory oldDocs;
  late Directory support;
  late Directory newDocs;

  /// 当前临时目录所在文件系统是否区分大小写（Windows / macOS 默认不区分，造不出只差
  /// 大小写的两个源文件，相关用例跳过；CI 的 Linux 上照跑）。
  bool tempIsCaseSensitive() {
    final Directory probe = Directory.systemTemp.createTempSync('fushi_case_');
    try {
      File(p.join(probe.path, 'A')).writeAsStringSync('x');
      return !File(p.join(probe.path, 'a')).existsSync();
    } finally {
      probe.deleteSync(recursive: true);
    }
  }

  final bool caseSensitive = tempIsCaseSensitive();
  final String? needsCaseSensitive = caseSensitive
      ? null
      : '临时目录不区分大小写，造不出只差大小写的源文件';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_name_collision_');
    oldDocs = Directory(p.join(tmp.path, 'internal', 'app_flutter', 'Fushi'))
      ..createSync(recursive: true);
    support = Directory(p.join(tmp.path, 'internal', 'files'))
      ..createSync(recursive: true);
    newDocs = Directory(p.join(tmp.path, 'external', 'files', 'data'));
    DataRootMigrator.debugForceCopyFallback = true;
  });

  tearDown(() {
    DataRootMigrator.debugForceCopyFallback = false;
    DataRootMigrator.debugTargetFoldsCaseOverride = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  DataRootMigrationRequest request({
    required void Function(DataRootMigrationTarget) onCommit,
    Future<void> Function(String)? onDiagnostic,
  }) => DataRootMigrationRequest(
    oldDocumentsRoot: oldDocs,
    oldSupportRoot: support,
    target: DataRootMigrationTarget.androidDocuments(
      documentsRoot: newDocs.path,
      supportRoot: support.path,
      location: AppPaths.androidDocumentsLocationExternal,
    ),
    closeResources: () async {},
    commitLocation: (DataRootMigrationTarget t) async => onCommit(t),
    documentsTopLevelIncludeNames: null,
    onDiagnostic: onDiagnostic,
  );

  Future<void> openDb() async {
    // 迁移改写库内路径时要有主库；空库即可。
    final FushiDatabase db = FushiDatabase(support.path);
    await db.getAllEpubBooks();
    await db.close();
  }

  group('复制前预检（源区分大小写、目标不区分）', () {
    test('只差大小写的两个文件 → 拒绝迁移，一个字节都不复制，旧根两份原样，不提交', () async {
      final File upper =
          File(p.join(oldDocs.path, 'fushi_books', 'B', 'Img.png'))
            ..createSync(recursive: true)
            ..writeAsStringSync('upper');
      final File lower = File(
        p.join(oldDocs.path, 'fushi_books', 'B', 'img.png'),
      )..writeAsStringSync('lower-lower');
      await openDb();
      DataRootMigrator.debugTargetFoldsCaseOverride = true;
      bool committed = false;

      await expectLater(
        const DataRootMigrator().migrate(
          request(onCommit: (_) => committed = true),
        ),
        throwsA(
          isA<DataRootNameCollisionException>().having(
            (DataRootNameCollisionException e) => <String>{
              p.basename(e.relativePath),
              p.basename(e.collidesWith),
            },
            'colliding names',
            <String>{'Img.png', 'img.png'},
          ),
        ),
      );
      expect(committed, isFalse);
      expect(upper.readAsStringSync(), 'upper');
      expect(lower.readAsStringSync(), 'lower-lower');
      expect(newDocs.existsSync(), isFalse, reason: '回滚清掉本次新建的目标子树');
    }, skip: needsCaseSensitive);

    test('只差大小写的两个目录同样拒绝（并成一个目录会让同名文件互相覆盖）', () async {
      File(p.join(oldDocs.path, 'dictionaryResources', 'JMdict', 'a.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('1');
      File(p.join(oldDocs.path, 'dictionaryResources', 'jmdict', 'a.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('2');
      await openDb();
      DataRootMigrator.debugTargetFoldsCaseOverride = true;

      await expectLater(
        const DataRootMigrator().migrate(request(onCommit: (_) {})),
        throwsA(isA<DataRootNameCollisionException>()),
      );
      expect(
        File(
          p.join(oldDocs.path, 'dictionaryResources', 'JMdict', 'a.json'),
        ).readAsStringSync(),
        '1',
      );
      expect(
        File(
          p.join(oldDocs.path, 'dictionaryResources', 'jmdict', 'a.json'),
        ).readAsStringSync(),
        '2',
      );
    }, skip: needsCaseSensitive);

    test('目标区分大小写时只差大小写的两个文件照常搬过去', () async {
      File(p.join(oldDocs.path, 'fushi_books', 'B', 'Img.png'))
        ..createSync(recursive: true)
        ..writeAsStringSync('upper');
      File(
        p.join(oldDocs.path, 'fushi_books', 'B', 'img.png'),
      ).writeAsStringSync('lower');
      await openDb();
      DataRootMigrator.debugTargetFoldsCaseOverride = false;

      await const DataRootMigrator().migrate(request(onCommit: (_) {}));
      expect(
        File(
          p.join(newDocs.path, 'fushi_books', 'B', 'Img.png'),
        ).readAsStringSync(),
        'upper',
      );
      expect(
        File(
          p.join(newDocs.path, 'fushi_books', 'B', 'img.png'),
        ).readAsStringSync(),
        'lower',
      );
    }, skip: needsCaseSensitive);

    test('比对键：分隔符归一 + 小写', () {
      expect(
        DataRootMigrator.foldedRelativePathForCollision(r'Books\Img.PNG'),
        DataRootMigrator.foldedRelativePathForCollision('books/img.png'),
      );
      expect(
        DataRootMigrator.foldedRelativePathForCollision('a/b.png'),
        isNot(DataRootMigrator.foldedRelativePathForCollision('a/c.png')),
      );
    });
  });

  group('复制循环兜底（预检漏掉的归一化撞名）', () {
    // 预检只按小写比对；目标文件系统的 Unicode 归一（如 NFC / NFD 两种写法的同一个假名）
    // 等漏网情形，表现都是「写之前目标上已经有这个名字」。这里直接在目标里预先放好同名
    // 项来模拟，任何文件系统上都能跑。
    late Directory src;
    late Directory dst;

    setUp(() {
      src = Directory(p.join(tmp.path, 'src'))..createSync();
      dst = Directory(p.join(tmp.path, 'dst'))..createSync();
      DataRootMigrator.debugTargetFoldsCaseOverride = false;
    });

    test('文件：目标上已有同名文件 → 拒绝，不覆盖', () async {
      File(p.join(src.path, 'b', 'x.bin'))
        ..createSync(recursive: true)
        ..writeAsStringSync('from-source');
      final File occupied = File(p.join(dst.path, 'b', 'x.bin'))
        ..createSync(recursive: true)
        ..writeAsStringSync('first-copy');

      await expectLater(
        const DataRootMigrator().copyTreeWithProgressForTesting(
          src,
          dst,
          (int _, int _) {},
        ),
        throwsA(isA<DataRootNameCollisionException>()),
      );
      expect(occupied.readAsStringSync(), 'first-copy');
    });

    test('目录：目标上已有同名目录 → 拒绝，不合并', () async {
      File(p.join(src.path, 'dict', 'a.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('1');
      Directory(p.join(dst.path, 'dict')).createSync();

      await expectLater(
        const DataRootMigrator().copyTreeWithProgressForTesting(
          src,
          dst,
          (int _, int _) {},
        ),
        throwsA(isA<DataRootNameCollisionException>()),
      );
      expect(File(p.join(dst.path, 'dict', 'a.json')).existsSync(), isFalse);
    });
  });

  test('成功迁移：回报取证摘要、沙箱台账同步记成新根', () async {
    File(p.join(oldDocs.path, 'fushi_books', 'B', 'a.html'))
      ..createSync(recursive: true)
      ..writeAsStringSync('hello');
    File(p.join(oldDocs.path, 'dictionaryResources', 'D', 'index.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    final FushiDatabase seed = FushiDatabase(support.path);
    await seed.setPref(
      SandboxRelocation.lastDocumentsRootPrefKey,
      oldDocs.path,
    );
    await seed.setPref(SandboxRelocation.lastSupportRootPrefKey, support.path);
    await seed.close();
    DataRootMigrator.debugTargetFoldsCaseOverride = false;
    final List<String> diagnostics = <String>[];

    await const DataRootMigrator().migrate(
      request(
        onCommit: (_) {},
        onDiagnostic: (String s) async => diagnostics.add(s),
      ),
    );

    expect(diagnostics, hasLength(1));
    expect(diagnostics.single, contains('copy + verify, source deleted'));
    expect(diagnostics.single, contains('copied 2 files'));
    expect(diagnostics.single, contains('support root unchanged'));
    final FushiDatabase db = FushiDatabase(support.path);
    try {
      expect(
        await db.getPref(SandboxRelocation.lastDocumentsRootPrefKey),
        newDocs.path,
        reason: '台账与库内路径同生共死：不跟着改，下次启动会按旧台账再重基一遍',
      );
      expect(
        await db.getPref(SandboxRelocation.lastSupportRootPrefKey),
        support.path,
      );
    } finally {
      await db.close();
    }
  });

  test('失败提示讲清是哪两个文件', () {
    final String collision = dataRootMigrationFailureMessage(
      DataRootNameCollisionException(
        relativePath: 'fushi_books/B/img.png',
        collidesWith: 'fushi_books/B/Img.png',
      ),
    );
    expect(collision, contains('fushi_books/B/img.png'));
    expect(collision, contains('fushi_books/B/Img.png'));
    expect(
      dataRootMigrationFailureMessage(const DataRootMigrationException('boom')),
      contains('boom'),
    );
  });

  test('失败建议只给用户自己挑了文件夹、且原因没说清怎么改的失败', () {
    final DataRootMigrationTarget android =
        DataRootMigrationTarget.androidDocuments(
          documentsRoot: '/ext/files/data',
          supportRoot: '/data/user/0/pkg/files',
          location: AppPaths.androidDocumentsLocationExternal,
        );
    final DataRootMigrationTarget custom = DataRootMigrationTarget.customRoot(
      '/picked/root',
    );
    final DataRootNameCollisionException collision =
        DataRootNameCollisionException(relativePath: 'a', collidesWith: 'A');
    const DataRootMigrationException generic = DataRootMigrationException('x');

    expect(dataRootMigrationFailureHint(collision, custom), isNull);
    expect(dataRootMigrationFailureHint(generic, android), isNull);
    expect(
      dataRootMigrationFailureHint(generic, custom),
      t.data_storage_migrate_failed_suggestions,
    );
  });
}
