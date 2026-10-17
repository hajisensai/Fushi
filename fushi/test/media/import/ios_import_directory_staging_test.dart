/// BUG-2786：iOS 上导入目录必须「在安全作用域访问窗口内整卷拷进 app 容器」。
///
/// file_picker 的 `getDirectoryPath()` 在 iOS 返回沙盒外路径、从不
/// `startAccessingSecurityScopedResource()`，`dart:io` 列目录直接被拒；`pickFiles()`
/// 用 import 模式，只把被选中的一个文件挪进 `NSTemporaryDirectory()`，`.mokuro` 的
/// 同级页图文件夹不会跟过来。这里经真实 codec / channel 边界钉住 Dart 半边的契约：
/// iOS 调原生 `pickAndCopyDirectory`、用它返回的路径、取消静默、失败可见，其它平台
/// 完全不碰这条 channel。Swift 半边本机编不了，只能用源码守卫钉住接线。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:path/path.dart' as p;

import '../../helpers/source_guard.dart';
import '../../helpers/test_platform_services.dart';

/// 桌面腿的假 file_picker：只记录 `getDirectoryPath` 是否被调。
class _DirectoryFilePicker extends FilePicker {
  _DirectoryFilePicker(this.result);

  final String? result;
  int calls = 0;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    calls++;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel pathProvider = MethodChannel(
    'plugins.flutter.io/path_provider',
  );

  /// 在 [platform] 下拿一个真 [BuildContext] 跑 [body]；[onSaf] 应答 saf channel。
  /// 平台覆写必须在测试体结束前归位（`debugAssertAllFoundationVarsUnset`）。
  Future<T> onPlatform<T>(
    WidgetTester tester,
    TargetPlatform platform,
    Future<Object?> Function(MethodCall call) onSaf,
    Future<T> Function(BuildContext context, AppModel model) body,
  ) async {
    final AppModel model = AppModel(testPlatformServices());
    final Directory tmp = Directory.systemTemp.createTempSync('fushi_ios_stg');
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(FushiChannels.saf, onSaf);
    messenger.setMockMethodCallHandler(
      pathProvider,
      (MethodCall call) async => tmp.path,
    );
    debugDefaultTargetPlatformOverride = platform;
    try {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext value) {
              context = value;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return await body(context, model);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(FushiChannels.saf, null);
      messenger.setMockMethodCallHandler(pathProvider, null);
      model.dispose();
      tmp.deleteSync(recursive: true);
    }
  }

  testWidgets('iOS：调 pickAndCopyDirectory，destPath 在 import_staging/<name> 下，'
      '返回原生交回的路径与暂存根', (WidgetTester tester) async {
    final List<MethodCall> calls = <MethodCall>[];
    final PickedImportDirectory? picked = await onPlatform(
      tester,
      TargetPlatform.iOS,
      (MethodCall call) async {
        calls.add(call);
        final String dest =
            (call.arguments as Map<Object?, Object?>)['destPath']! as String;
        // 原生契约：返回拷贝后树的根（iOS 保留文件夹名一层）。
        return p.join(dest, 'Vol 01');
      },
      (BuildContext context, AppModel model) => pickImportDirectory(
        context: context,
        appModel: model,
        stagingName: 'manga',
      ),
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'pickAndCopyDirectory');
    final String dest =
        (calls.single.arguments as Map<Object?, Object?>)['destPath']!
            as String;
    expect(dest, endsWith(p.join(kImportStagingDirName, 'manga')));
    expect(picked, isNotNull);
    // 调用方必须用原生返回的路径，不许自己拼 destPath。
    expect(picked!.path, p.join(dest, 'Vol 01'));
    expect(picked.stagingRoot?.path, dest);
  });

  testWidgets('iOS：原生返回 null = 用户取消，静默返回 null', (WidgetTester tester) async {
    final PickedImportDirectory? picked = await onPlatform(
      tester,
      TargetPlatform.iOS,
      (MethodCall call) async => null,
      (BuildContext context, AppModel model) => pickImportDirectory(
        context: context,
        appModel: model,
        stagingName: 'manga',
      ),
    );
    expect(picked, isNull);
  });

  for (final String code in <String>['COPY_FAILED', 'BUSY']) {
    testWidgets('iOS：原生报 $code 是失败不是取消（抛 DirectoryImportCopyException）', (
      WidgetTester tester,
    ) async {
      await onPlatform(
        tester,
        TargetPlatform.iOS,
        (MethodCall call) async =>
            throw PlatformException(code: code, message: 'boom'),
        (BuildContext context, AppModel model) async {
          await expectLater(
            pickImportDirectory(
              context: context,
              appModel: model,
              stagingName: 'manga',
            ),
            throwsA(
              isA<DirectoryImportCopyException>().having(
                (DirectoryImportCopyException e) => e.message,
                'message',
                contains(code),
              ),
            ),
          );
        },
      );
    });
  }

  testWidgets('安卓：走 pickRealDirectory（原位真实路径），从不调 pickAndCopyDirectory', (
    WidgetTester tester,
  ) async {
    final List<String> methods = <String>[];
    final PickedImportDirectory? picked = await onPlatform(
      tester,
      TargetPlatform.android,
      (MethodCall call) async {
        methods.add(call.method);
        return '/storage/emulated/0/manga/vol1';
      },
      (BuildContext context, AppModel model) => pickImportDirectory(
        context: context,
        appModel: model,
        stagingName: 'manga',
      ),
    );
    expect(methods, <String>['pickRealDirectory']);
    expect(picked?.path, '/storage/emulated/0/manga/vol1');
    expect(picked?.stagingRoot, isNull, reason: '原位路径绝不能被当暂存删掉');
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets('${platform.name}：走 getDirectoryPath，不碰 saf channel', (
      WidgetTester tester,
    ) async {
      final _DirectoryFilePicker fake = _DirectoryFilePicker(r'D:\manga\vol1');
      FilePicker.platform = fake;
      final List<String> methods = <String>[];
      final PickedImportDirectory? picked = await onPlatform(
        tester,
        platform,
        (MethodCall call) async {
          methods.add(call.method);
          return null;
        },
        (BuildContext context, AppModel model) => pickImportDirectory(
          context: context,
          appModel: model,
          stagingName: 'manga',
        ),
      );
      expect(methods, isEmpty);
      expect(fake.calls, 1);
      expect(picked?.path, r'D:\manga\vol1');
      expect(picked?.stagingRoot, isNull);
    });
  }

  test('discardStaging 删暂存根；原位目录什么都不做', () async {
    final Directory root = Directory.systemTemp.createTempSync('fushi_stg_rm');
    final Directory staging = Directory(p.join(root.path, 'import_staging'))
      ..createSync();
    File(p.join(staging.path, 'Vol 01', 'a.jpg')).createSync(recursive: true);

    await PickedImportDirectory(
      path: p.join(staging.path, 'Vol 01'),
      stagingRoot: staging,
    ).discardStaging();
    expect(staging.existsSync(), isFalse);

    final Directory inPlace = Directory(p.join(root.path, 'user_dir'))
      ..createSync();
    await PickedImportDirectory(path: inPlace.path).discardStaging();
    expect(inPlace.existsSync(), isTrue);
    root.deleteSync(recursive: true);
  });

  group('接线守卫（Swift 半边本机编不了）', () {
    test('漫画框选文件夹走 pickImportDirectory，不再裸调 pickRealDirectoryPath', () {
      final String src = maskComments(
        File('lib/src/media/manga/manga_import_dialog.dart').readAsStringSync(),
      );
      final int start = src.indexOf('Future<void> _pickFolder()');
      expect(start, isNonNegative);
      final int end = src.indexOf('void _clearSelection()', start);
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);
      expect(body, contains('pickImportDirectory('));
      expect(body, isNot(contains('pickRealDirectoryPath(')));
      expect(body, contains('on DirectoryImportCopyException'));
    });

    test('iOS AppDelegate 注册了 FushiDirectoryImport 且强引用持有', () {
      final String delegate = maskComments(
        File('ios/Runner/AppDelegate.swift').readAsStringSync(),
      );
      expect(
        delegate,
        contains('private var directoryImport: FushiDirectoryImport?'),
      );
      expect(delegate, contains('directoryImport = FushiDirectoryImport('));
    });

    test('Swift：channel 名 / 方法名 / 错误码与 Dart、Android 一致', () {
      final String swift = maskComments(
        File('ios/Runner/FushiDirectoryImport.swift').readAsStringSync(),
      );
      expect(swift, contains('"app.fushi.reader/saf"'));
      expect(swift, contains('"pickAndCopyDirectory"'));
      expect(swift, contains('"destPath"'));
      expect(swift, contains('code: "COPY_FAILED"'));
      expect(swift, contains('code: "BUSY"'));
      expect(swift, contains('startAccessingSecurityScopedResource()'));
      expect(swift, contains('stopAccessingSecurityScopedResource()'));
      expect(
        swift,
        contains('forOpeningContentTypes: [.folder], asCopy: false'),
      );
      expect(swift, contains('FlutterMethodNotImplemented'));
      final String dart = File(
        'lib/src/utils/misc/channel_constants.dart',
      ).readAsStringSync();
      expect(dart, contains("MethodChannel('\$_prefix/saf')"));
    });

    test('Xcode 工程四处登记齐全', () {
      final String pbx = File(
        'ios/Runner.xcodeproj/project.pbxproj',
      ).readAsStringSync();
      expect(
        pbx,
        contains('path = FushiDirectoryImport.swift; sourceTree = "<group>";'),
      );
      expect(
        pbx,
        contains(
          '/* FushiDirectoryImport.swift in Sources */ = {isa = PBXBuildFile;',
        ),
      );
      expect('/* FushiDirectoryImport.swift */,'.allMatches(pbx).length, 1);
      expect(
        '/* FushiDirectoryImport.swift in Sources */,'.allMatches(pbx).length,
        1,
      );
    });
  });
}
