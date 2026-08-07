import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/storage/app_paths.dart';

/// BUG-1115 单测：**默认**（未配置自定义数据根）documents 根的布局判定。
///
/// 历史行为是 documents 根 = 平台 `Documents` **本身**，于是
/// [AppPaths.hibikiOwnedDocumentsEntries] 那 16 个目录全摊在用户文档根下。现在：
///  - 全新安装 → `<Documents>/Hibiki/data`（Hibiki 专属容器）；
///  - 老安装（support 根下已有 `hibiki.db`）→ 仍是扁平的平台 `Documents`，零迁移；
///  - 判定结果**一次性固化**进 SharedPreferences，之后不再探测——布局在同一台机器上
///    绝不能随「此刻磁盘上有没有某个文件」漂移（漂一次就是整个书库凭空消失）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory platformDocuments;
  late Directory platformSupport;

  String nested() => p.joinAll(<String>[
        platformDocuments.path,
        ...AppPaths.defaultDocumentsChildSegments,
      ]);

  /// 制造「这台机器上已经有一个跑过的安装」的痕迹：support 根下有主库文件。
  void writeExistingDatabase() {
    File(p.join(platformSupport.path, 'hibiki.db'))
        .writeAsStringSync('not a real sqlite file, only its presence matters');
  }

  setUp(() {
    AppPaths.debugResetDocumentsLayoutCache();
    // 无自定义数据根：走默认分支（本文件的被测对象）。
    AppPaths.debugDataRootReader = () async => '';
    SharedPreferences.setMockInitialValues(<String, Object>{});

    tmp = Directory.systemTemp.createTempSync('hibiki_docs_layout_');
    platformDocuments = Directory(p.join(tmp.path, 'Documents'))
      ..createSync(recursive: true);
    platformSupport = Directory(p.join(tmp.path, 'AppData', 'hibiki'))
      ..createSync(recursive: true);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        switch (call.method) {
          case 'getApplicationDocumentsDirectory':
            return platformDocuments.path;
          case 'getApplicationSupportDirectory':
            return platformSupport.path;
          case 'getTemporaryDirectory':
            return p.join(tmp.path, 'systemp');
        }
        return null;
      },
    );
  });

  tearDown(() {
    AppPaths.debugDataRootReader = null;
    AppPaths.debugResetDocumentsLayoutCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('BUG-1115 默认 documents 布局判定', () {
    test('全新安装 → <Documents>/Hibiki/data，用户文档根下不再摊开', () async {
      // 布局判定只在启动期的 resolve() 里做一次（解析路径本身不许碰文件系统）。
      final Directory root = (await AppPaths.resolve()).documentsRoot;

      expect(root.path, equals(nested()));
      // 核心断言：16 个目录的父不再是用户文档根本身。
      expect((await AppPaths.audiobooksDirectory()).path,
          equals(p.join(nested(), 'audiobooks')));
      expect((await AppPaths.epubBooksDirectory()).path,
          isNot(equals(p.join(platformDocuments.path, 'hoshi_books'))));
    });

    test('老安装（support 下有 hibiki.db）→ 保持扁平布局，一个字节都不搬', () async {
      writeExistingDatabase();

      final Directory root = (await AppPaths.resolve()).documentsRoot;

      expect(root.path, equals(platformDocuments.path));
      // 老用户的每个派生点都必须与升级前逐字节一致。
      expect((await AppPaths.audiobooksDirectory()).path,
          equals(p.join(platformDocuments.path, 'audiobooks')));
      expect((await AppPaths.epubBooksDirectory()).path,
          equals(p.join(platformDocuments.path, 'hoshi_books')));
    });

    test('判定结果固化进 prefs（新装写 nested）', () async {
      await AppPaths.resolve();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(
          prefs.getString(AppPaths.documentsLayoutPrefKey), equals('nested'));
    });

    test('判定结果固化进 prefs（老装写 flat）', () async {
      writeExistingDatabase();

      await AppPaths.resolve();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppPaths.documentsLayoutPrefKey), equals('flat'));
    });

    test('未跑过 resolve 且无 prefs 锚点 → 兜底扁平老布局（绝不擅自切走）', () async {
      // 生产上 resolve() 恒在启动最早期跑完；真正走到这个兜底的是没跑 resolve 的测试
      // 夹具。兜底必须等于 BUG-1115 之前的行为，否则一批 widget 测试与老用户会被静默
      // 切到一个空的新根。
      final Directory root = await AppPaths.documentsRootDirectory();

      expect(root.path, equals(platformDocuments.path));
    });

    test('已锚定 flat → 即使主库文件消失也不会翻成新布局（锚点不漂移）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AppPaths.documentsLayoutPrefKey: 'flat',
      });
      // 刻意不建 hibiki.db：模拟用户把库搬走 / 清了 AppData 后再次启动。
      final Directory root = await AppPaths.documentsRootDirectory();

      expect(root.path, equals(platformDocuments.path));
    });

    test('已锚定 nested → 即使 support 下出现主库也不会退回扁平布局', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AppPaths.documentsLayoutPrefKey: 'nested',
      });
      writeExistingDatabase();

      final Directory root = await AppPaths.documentsRootDirectory();

      expect(root.path, equals(nested()));
    });

    test('自定义数据根优先于布局判定（dataRoot 分支不受影响）', () async {
      final Directory dataRoot = Directory(p.join(tmp.path, 'D_Root'))
        ..createSync(recursive: true);
      AppPaths.debugDataRootReader = () async => dataRoot.path;

      final Directory root = await AppPaths.documentsRootDirectory();

      expect(root.path, equals(p.join(dataRoot.path, 'documents')));
    });

    test('一次运行内布局恒定：并发解析拿到同一个根', () async {
      await AppPaths.resolve();
      final List<Directory> roots = await Future.wait(<Future<Directory>>[
        AppPaths.documentsRootDirectory(),
        AppPaths.documentsRootDirectory(),
        AppPaths.documentsRootDirectory(),
      ]);

      expect(roots.map((Directory d) => d.path).toSet(), hasLength(1));
      expect(roots.first.path, equals(nested()));
    });
  });

  group('BUG-1115 共享 documents 根下的嵌套迁移目标', () {
    test('非白名单子目录（Documents\\Hibiki）是安全目标', () {
      expect(
        AppPaths.isSafeNestedTargetInSharedDocuments(
          sharedDocumentsRoot: platformDocuments.path,
          newDataRoot: p.join(platformDocuments.path, 'Hibiki'),
        ),
        isTrue,
      );
    });

    test('白名单顶层项本身不是安全目标（会被搬走 → 目标边搬边消失）', () {
      for (final String owned in AppPaths.hibikiOwnedDocumentsEntries) {
        expect(
          AppPaths.isSafeNestedTargetInSharedDocuments(
            sharedDocumentsRoot: platformDocuments.path,
            newDataRoot: p.join(platformDocuments.path, owned),
          ),
          isFalse,
          reason: '白名单项 $owned 会被选择性搬移搬走，不能同时当迁移目标',
        );
        // 白名单项的子目录同样不安全：父被整个搬走，子跟着一起飞。
        expect(
          AppPaths.isSafeNestedTargetInSharedDocuments(
            sharedDocumentsRoot: platformDocuments.path,
            newDataRoot: p.join(platformDocuments.path, owned, 'sub'),
          ),
          isFalse,
          reason: '$owned/sub 的父目录会被搬走',
        );
      }
    });

    test('白名单顶层项比较大小写不敏感（Windows canonicalize 会转小写）', () {
      expect(
        AppPaths.isSafeNestedTargetInSharedDocuments(
          sharedDocumentsRoot: platformDocuments.path,
          newDataRoot: p.join(platformDocuments.path, 'HIBIKIEXPORT'),
        ),
        isFalse,
        reason: 'hibikiExport 是白名单项，大小写变体同样不能当目标',
      );
    });

    test('根本身 / 根外的目录都不算「嵌套安全目标」', () {
      expect(
        AppPaths.isSafeNestedTargetInSharedDocuments(
          sharedDocumentsRoot: platformDocuments.path,
          newDataRoot: platformDocuments.path,
        ),
        isFalse,
      );
      expect(
        AppPaths.isSafeNestedTargetInSharedDocuments(
          sharedDocumentsRoot: platformDocuments.path,
          newDataRoot: p.join(tmp.path, 'Elsewhere'),
        ),
        isFalse,
      );
    });

    test('传入的白名单是判定依据（引擎传自己的那份，不吃全局常量）', () {
      // 引擎用 DataRootMigrationRequest.documentsTopLevelIncludeNames 判定；这里证明
      // 判定确实跟着传入集合走，而不是永远查 AppPaths 的全集。
      expect(
        AppPaths.isSafeNestedTargetInSharedDocuments(
          sharedDocumentsRoot: platformDocuments.path,
          newDataRoot: p.join(platformDocuments.path, 'audiobooks'),
          ownedEntries: const <String>{'hoshi_books'},
        ),
        isTrue,
      );
      expect(
        AppPaths.isSafeNestedTargetInSharedDocuments(
          sharedDocumentsRoot: platformDocuments.path,
          newDataRoot: p.join(platformDocuments.path, 'Hibiki'),
          ownedEntries: const <String>{'Hibiki'},
        ),
        isFalse,
      );
    });
  });
}
