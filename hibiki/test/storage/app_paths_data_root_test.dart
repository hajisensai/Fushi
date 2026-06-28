import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/storage/app_paths.dart';

/// TODO-935 E1 块1 单测：[AppPaths] 的 dataRoot 覆盖来源。
///
/// 用 [AppPaths.debugDataRootReader] 注入「假 SharedPreferences 的 data_root 读取」，
/// 逐字节断言：
///  - 有 data_root（桌面） → documentsRoot/supportRoot 派生到 `<dataRoot>/documents` /
///    `<dataRoot>/support`；
///  - 无值 / 失效路径 → 回退默认（不派生到失效/覆盖路径，等价老用户）；
///  - [AppPaths.rootsForDataRoot] 纯派生与解析分支逐字节一致。
///
/// 注：`isDesktopPlatform` 在测试宿主（桌面 VM）下恒 true，故「桌面分支」可直接验证。
/// `_resolveTempRoot` 始终走 `getTemporaryDirectory()`（temp 不接管到 dataRoot），这里
/// mock 掉 path_provider 的 method channel 返回一个临时目录，让 `AppPaths.resolve()` 在
/// 纯单测里可跑通而不依赖真实平台通道。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory fakeTemp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hibiki_dataroot_');
    fakeTemp = Directory(p.join(tmp.path, 'systemp'))..createSync();
    // path_provider 的 getTemporaryDirectory 走 method channel；mock 它返回 fakeTemp，
    // 使 resolve() 里 _resolveTempRoot 不触碰真实平台通道。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        if (call.method == 'getTemporaryDirectory') return fakeTemp.path;
        if (call.method == 'getApplicationSupportDirectory') {
          return p.join(tmp.path, 'default_support');
        }
        if (call.method == 'getApplicationDocumentsDirectory') {
          return p.join(tmp.path, 'default_documents');
        }
        return null;
      },
    );
  });

  tearDown(() {
    AppPaths.debugDataRootReader = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('TODO-935 E1 块1：AppPaths dataRoot 覆盖', () {
    test('有 data_root（桌面）→ 三根派生到 dataRoot 子目录（逐字节）', () async {
      final Directory dataRoot = Directory(p.join(tmp.path, 'NewRoot'))
        ..createSync(recursive: true);
      AppPaths.debugDataRootReader = () async => dataRoot.path;

      final AppPaths paths = await AppPaths.resolve();

      expect(
          paths.documentsRoot.path, equals(p.join(dataRoot.path, 'documents')));
      expect(paths.supportRoot.path, equals(p.join(dataRoot.path, 'support')));
      // temp 永远走系统临时目录，不接管到 dataRoot 下。
      expect(paths.tempRoot.path, isNot(startsWith(dataRoot.path)));
      expect(paths.tempRoot.path, equals(fakeTemp.path));
    });

    test('data_root 指向不存在目录 → 回退默认（不派生到失效路径）', () async {
      final String missing = p.join(tmp.path, 'does_not_exist');
      AppPaths.debugDataRootReader = () async => missing;

      final AppPaths paths = await AppPaths.resolve();

      // 失效 dataRoot 被忽略 → 回退 path_provider 默认根。
      expect(paths.documentsRoot.path, isNot(startsWith(missing)));
      expect(paths.documentsRoot.path,
          equals(p.join(tmp.path, 'default_documents')));
    });

    test('空 data_root → 回退默认（无覆盖等价老用户）', () async {
      AppPaths.debugDataRootReader = () async => '';
      final AppPaths paths = await AppPaths.resolve();
      expect(paths.documentsRoot.path, isNot(contains('NewRoot')));
      expect(
          paths.supportRoot.path, equals(p.join(tmp.path, 'default_support')));
    });

    test('rootsForDataRoot 纯派生（子目录名固定）', () {
      final (Directory docs, Directory support) =
          AppPaths.rootsForDataRoot('/x/y/Z');
      expect(docs.path, equals(p.join('/x/y/Z', 'documents')));
      expect(support.path, equals(p.join('/x/y/Z', 'support')));
    });

    test('rootsForDataRoot 与解析分支子目录名逐字节一致', () async {
      final Directory dataRoot = Directory(p.join(tmp.path, 'R2'))
        ..createSync(recursive: true);
      AppPaths.debugDataRootReader = () async => dataRoot.path;
      final AppPaths paths = await AppPaths.resolve();
      final (Directory docs, Directory support) =
          AppPaths.rootsForDataRoot(dataRoot.path);
      expect(paths.documentsRoot.path, equals(docs.path));
      expect(paths.supportRoot.path, equals(support.path));
    });
  });
}
