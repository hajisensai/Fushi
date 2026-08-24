import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/installer_data_root_bootstrap.dart';

/// Windows 安装向导「数据存储位置」页 → `{app}\data_root.bootstrap` → 首启消费成
/// `data_root` 偏好。这里断言消费函数的契约（一次性、只对全新安装生效、路径校验、
/// 默认位置归一化），安装器侧的写入由 `test/build/windows_installer_data_root_page_guard_test.dart`
/// 源码守卫。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory platformDocuments;
  late Directory platformSupport;
  late Directory appDir;
  late File bootstrap;
  late String exePath;

  String defaultUmbrella() => p.join(platformDocuments.path, 'Fushi');

  Future<void> writeBootstrap(String content) =>
      bootstrap.writeAsString(content, flush: true);

  Future<String?> storedDataRoot() async =>
      (await SharedPreferences.getInstance()).getString(
        AppPaths.dataRootPrefKey,
      );

  Future<void> consume() => consumeInstallerDataRootBootstrap(
    bootstrapFile: bootstrap,
    executablePath: exePath,
  );

  setUp(() {
    AppPaths.debugResetDocumentsLayoutCache();
    AppPaths.debugDataRootReader = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});

    tmp = Directory.systemTemp.createTempSync('fushi_installer_bootstrap_');
    platformDocuments = Directory(p.join(tmp.path, 'Documents'))
      ..createSync(recursive: true);
    platformSupport = Directory(p.join(tmp.path, 'AppData', 'Fushi', 'Fushi'))
      ..createSync(recursive: true);
    appDir = Directory(p.join(tmp.path, 'LocalAppData', 'Fushi'))
      ..createSync(recursive: true);
    exePath = p.join(appDir.path, 'fushi.exe');
    bootstrap = File(p.join(appDir.path, installerDataRootBootstrapFileName));

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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    AppPaths.debugResetDocumentsLayoutCache();
    tmp.deleteSync(recursive: true);
  });

  test('no bootstrap file → no-op', () async {
    await consume();
    expect(await storedDataRoot(), isNull);
  });

  test(
    'fresh install + custom dir → data_root written, dir created, file consumed',
    () async {
      final String picked = p.join(tmp.path, 'D_drive', 'FushiData');
      await writeBootstrap(picked);

      await consume();

      expect(await storedDataRoot(), picked);
      expect(Directory(picked).existsSync(), isTrue);
      expect(bootstrap.existsSync(), isFalse, reason: '引导文件是一次性的，读完必删');
    },
  );

  test('BOM + CRLF + surrounding whitespace are stripped', () async {
    final String picked = p.join(tmp.path, 'Data');
    final String bom = String.fromCharCode(0xFEFF);
    await writeBootstrap('$bom  $picked  \r\n');

    await consume();

    expect(await storedDataRoot(), picked);
  });

  test(
    'picking the default umbrella (<Documents>\\Fushi) writes no pref',
    () async {
      await writeBootstrap(defaultUmbrella());

      await consume();

      expect(
        await storedDataRoot(),
        isNull,
        reason: '默认位置 = 与全新安装同形，不得派生成 <Documents>/Fushi/{documents,support}',
      );
      expect(bootstrap.existsSync(), isFalse);
    },
  );

  test(
    'picking the default documents root (<Documents>\\Fushi\\data) writes no pref',
    () async {
      await writeBootstrap(p.join(defaultUmbrella(), 'data'));

      await consume();

      expect(await storedDataRoot(), isNull);
    },
  );

  test('existing data_root pref wins; file still consumed', () async {
    final String existing = p.join(tmp.path, 'Existing');
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppPaths.dataRootPrefKey: existing,
    });
    await writeBootstrap(p.join(tmp.path, 'FromInstaller'));

    await consume();

    expect(await storedDataRoot(), existing);
    expect(bootstrap.existsSync(), isFalse);
  });

  test(
    'existing database at platform support root → installer choice ignored',
    () async {
      File(
        p.join(platformSupport.path, 'fushi.db'),
      ).writeAsStringSync('presence is all that matters');
      await writeBootstrap(p.join(tmp.path, 'FromInstaller'));

      await consume();

      expect(
        await storedDataRoot(),
        isNull,
        reason: '卸载保留数据后重装：旧库必须继续被看见，绝不切到空根',
      );
      expect(bootstrap.existsSync(), isFalse);
    },
  );

  test('legacy hibiki.db also counts as an existing install', () async {
    File(p.join(platformSupport.path, 'hibiki.db')).writeAsStringSync('x');
    await writeBootstrap(p.join(tmp.path, 'FromInstaller'));

    await consume();

    expect(await storedDataRoot(), isNull);
  });

  test('path that contains the install dir is rejected', () async {
    await writeBootstrap(p.dirname(appDir.path));

    await consume();

    expect(await storedDataRoot(), isNull);
    expect(bootstrap.existsSync(), isFalse);
  });

  test('install dir itself is rejected', () async {
    await writeBootstrap(appDir.path);

    await consume();

    expect(await storedDataRoot(), isNull);
  });

  test('subdirectory of the install dir is rejected', () async {
    await writeBootstrap(p.join(appDir.path, 'data'));

    await consume();

    expect(
      await storedDataRoot(),
      isNull,
      reason: 'data under {app} is taken along by uninstall / update rollback',
    );
  });

  test(
    'target with a pre-existing non-empty documents/ subtree is rejected',
    () async {
      final String picked = p.join(tmp.path, 'Downloads');
      File(p.join(picked, 'documents', 'thesis.docx'))
        ..createSync(recursive: true)
        ..writeAsStringSync('mine');
      await writeBootstrap(picked);

      await consume();

      expect(
        await storedDataRoot(),
        isNull,
        reason:
            'the user\'s own documents/ must never become a Fushi-owned tree',
      );
      expect(bootstrap.existsSync(), isFalse);
    },
  );

  test(
    'target with a pre-existing non-empty support/ subtree is rejected',
    () async {
      final String picked = p.join(tmp.path, 'OldRoot');
      File(p.join(picked, 'support', 'fushi.db'))
        ..createSync(recursive: true)
        ..writeAsStringSync('old');
      await writeBootstrap(picked);

      await consume();

      expect(await storedDataRoot(), isNull);
    },
  );

  test('target with empty documents/ and support/ dirs is accepted', () async {
    final String picked = p.join(tmp.path, 'Empty');
    Directory(p.join(picked, 'documents')).createSync(recursive: true);
    Directory(p.join(picked, 'support')).createSync(recursive: true);
    await writeBootstrap(picked);

    await consume();

    expect(await storedDataRoot(), picked);
  });

  test('concurrent callers share one consumption', () async {
    final String picked = p.join(tmp.path, 'Once');
    await writeBootstrap(picked);

    final Future<void> first = consume();
    final Future<void> second = consume();
    expect(identical(first, second), isTrue);
    await Future.wait(<Future<void>>[first, second]);

    expect(await storedDataRoot(), picked);
    expect(bootstrap.existsSync(), isFalse);
  });

  test('relative path is rejected', () async {
    await writeBootstrap(p.join('relative', 'FushiData'));

    await consume();

    expect(await storedDataRoot(), isNull);
    expect(bootstrap.existsSync(), isFalse);
  });

  test('blank file is ignored and consumed', () async {
    await writeBootstrap('  \r\n\r\n');

    await consume();

    expect(await storedDataRoot(), isNull);
    expect(bootstrap.existsSync(), isFalse);
  });

  test(
    'adopted root is what AppPaths.resolve derives documents/support from',
    () async {
      final String picked = p.join(tmp.path, 'Adopted');
      await writeBootstrap(picked);
      await consume();

      final AppPaths paths = await AppPaths.resolve();

      expect(
        paths.documentsRoot.path,
        p.join(picked, AppPaths.dataRootDocumentsChild),
      );
      expect(
        paths.supportRoot.path,
        p.join(picked, AppPaths.dataRootSupportChild),
      );
    },
  );

  // 生产落点这条腿：上面所有用例都注入 bootstrapFile:，`_productionBootstrapFile()`
  // 一次都没被执行过。写错目录与写错文件名后果完全等价——安装器写了没人读，且全程
  // 无声；文件名由源码守卫钉，目录由这两条钉。
  group('bootstrapFileForExecutable', () {
    test('locates the file next to the exe on Windows', () {
      final String exe = p.join('C:', 'Program Files', 'Fushi', 'fushi.exe');

      final File? file = bootstrapFileForExecutable(exe, isWindows: true);

      expect(file, isNotNull);
      expect(
        file!.path,
        p.join(p.dirname(exe), installerDataRootBootstrapFileName),
      );
      expect(p.basename(file.path), installerDataRootBootstrapFileName);
      expect(p.dirname(file.path), p.dirname(exe));
    });

    test('is Windows-only (no such installer elsewhere)', () {
      expect(
        bootstrapFileForExecutable(
          '/Applications/Fushi.app/fushi',
          isWindows: false,
        ),
        isNull,
      );
    });
  });
}
