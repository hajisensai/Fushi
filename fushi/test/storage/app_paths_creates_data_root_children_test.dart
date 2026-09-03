import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// BUG-1899：安装向导选了非默认「数据安装位置」后，启动即「Database damaged」
/// （用户 2026-08-28 报，`D:\support\fushi.db` + `SqliteException(14) unable to open
/// database file`）。
///
/// 根因是**两条分支的契约不一致**：默认分支 `getApplicationSupportDirectory()` 内部
/// `create(recursive: true)`，返回的根一定存在；而 dataRoot 分支只做纯路径拼接
/// （`rootsForDataRoot`），安装向导的首启引导也只 `create` 了 dataRoot 本身
/// （`installer_data_root_bootstrap.dart`），`<dataRoot>/support` 从来没人建。
/// sqlite 打开该目录下的 db 拿到 SQLITE_CANTOPEN(14)，被恢复阶梯当成损坏，
/// 用户被引导去「恢复备份或清空数据」——而磁盘上什么都没坏。
///
/// 这里守的是 `AppPaths.resolve()` 的契约：**它返回的两个根必须真实存在**，
/// 无论走的是默认分支还是 dataRoot 分支。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory fakeTemp;

  setUp(() {
    AppPaths.debugResetDocumentsLayoutCache();
    tmp = Directory.systemTemp.createTempSync('hibiki_dataroot_mkdir_');
    fakeTemp = Directory(p.join(tmp.path, 'systemp'))..createSync();
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
    AppPaths.debugResetDocumentsLayoutCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test(
      'dataRoot 只有自己存在（安装向导刚建完）→ resolve() 必须把 documents / support '
      '两个子目录建出来（BUG-1899）', () async {
    // 复刻安装向导首启后的磁盘状态：dataRoot 在，两个子目录都不在。
    final Directory dataRoot = Directory(p.join(tmp.path, 'PickedRoot'))
      ..createSync(recursive: true);
    AppPaths.debugDataRootReader = () async => dataRoot.path;

    expect(Directory(p.join(dataRoot.path, 'support')).existsSync(), isFalse,
        reason: '前置条件：修复前正是这个空目录缺失导致 SQLITE_CANTOPEN(14)');

    final AppPaths paths = await AppPaths.resolve();

    expect(paths.supportRoot.path, equals(p.join(dataRoot.path, 'support')));
    expect(paths.supportRoot.existsSync(), isTrue,
        reason: 'DB 就开在这个目录下，它不存在 sqlite 连文件都建不出来');
    expect(
        paths.documentsRoot.path, equals(p.join(dataRoot.path, 'documents')));
    expect(paths.documentsRoot.existsSync(), isTrue,
        reason: '书库/词典/封面都落在这里，同样必须存在');
  });

  test('已存在的 dataRoot 子目录不被改动（幂等，不清空已有数据）', () async {
    final Directory dataRoot = Directory(p.join(tmp.path, 'ExistingRoot'))
      ..createSync(recursive: true);
    final Directory support = Directory(p.join(dataRoot.path, 'support'))
      ..createSync(recursive: true);
    final File marker = File(p.join(support.path, 'fushi.db'))
      ..writeAsStringSync('existing-db-bytes');
    AppPaths.debugDataRootReader = () async => dataRoot.path;

    final AppPaths paths = await AppPaths.resolve();

    expect(paths.supportRoot.existsSync(), isTrue);
    expect(marker.existsSync(), isTrue, reason: '绝不能碰已有文件');
    expect(marker.readAsStringSync(), equals('existing-db-bytes'));
  });

  test('默认分支同样保证根存在（两条分支契约一致）', () async {
    AppPaths.debugDataRootReader = () async => null;

    final AppPaths paths = await AppPaths.resolve();

    expect(paths.supportRoot.existsSync(), isTrue);
    expect(paths.documentsRoot.existsSync(), isTrue);
  });
}
