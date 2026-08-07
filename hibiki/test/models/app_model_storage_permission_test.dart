import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_platform_services.dart';

/// BUG-1209：选文件夹 / 选文件 / 改下载目录时不得申请相机权限。
///
/// `AppModel.requestExternalStoragePermissions()` 曾顺带 `requestCameraPermission()`，
/// 而它的调用点全在 `media/import/real_path_directory_picker.dart`（选扫描根 / 选文件 /
/// 改目录），只需要读盘。用户在选文件夹时被问相机会拒绝，同一串权限流程里的拒绝很可能
/// 连本该给的存储权限一起否掉。
///
/// 这里是行为测试：用记录型 `PlatformPermissionService` 记下**真实生产代码**对权限层的
/// 每一次调用，断言相机相关调用为零。
/// 注意：单测只能证明「代码不再向权限层请求相机」，**证明不了真机上系统弹框长什么样**
/// ——授权弹框行为必须真机复测。
class _RecordingPermissionService extends FakePermissionService {
  /// 生产代码对权限层的调用序列，形如 `has:storage` / `request:camera`。
  final List<String> calls = <String>[];

  List<String> get cameraCalls =>
      calls.where((String call) => call.endsWith(':camera')).toList();

  @override
  Future<bool> hasExternalStoragePermission() {
    calls.add('has:storage');
    return super.hasExternalStoragePermission();
  }

  @override
  Future<bool> requestExternalStoragePermission() {
    calls.add('request:storage');
    return super.requestExternalStoragePermission();
  }

  @override
  Future<bool> hasCameraPermission() {
    calls.add('has:camera');
    return super.hasCameraPermission();
  }

  @override
  Future<bool> requestCameraPermission() {
    calls.add('request:camera');
    return super.requestCameraPermission();
  }
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_path_provider_perm');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  late HibikiDatabase db;
  late PreferencesRepository prefs;
  late Directory storeDir;
  late _RecordingPermissionService permission;
  late AppModel appModel;

  setUp(() async {
    db = HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_app_model_perm');
    permission = _RecordingPermissionService();
    appModel = AppModel(fakePlatformServices(permission: permission))
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  group('BUG-1209 storage permission never drags the camera along', () {
    test('storage not granted: requests storage only, never the camera',
        () async {
      permission.hasExternalStorage = false;
      permission.hasCamera = false;

      await appModel.requestExternalStoragePermissions();

      expect(
        permission.calls,
        <String>['has:storage', 'request:storage'],
        reason: '选文件夹只需要读盘权限；相机是另一件事，不得混进同一串权限流程',
      );
      expect(permission.cameraCalls, isEmpty);
    });

    test('storage already granted: short-circuits without asking anything',
        () async {
      // 相机未授权也必须早退：旧版早退门是 storage && camera，安卓上 camera 恒为
      // false（CAMERA 未在 manifest 声明），导致存储已授权也永远走不进早退分支。
      permission.hasExternalStorage = true;
      permission.hasCamera = false;

      await appModel.requestExternalStoragePermissions();

      expect(
        permission.calls,
        <String>['has:storage'],
        reason: '存储已授权时不该再向权限层要任何东西',
      );
    });

    testWidgets(
        'android folder picker entry point asks for storage, not the camera',
        (WidgetTester tester) async {
      // 真实用户入口：选扫描根 / 改下载目录都走 pickRealDirectoryPath。
      permission.hasExternalStorage = true;
      permission.hasCamera = false;

      final List<String> safCalls = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        HibikiChannels.saf,
        (MethodCall call) async {
          safCalls.add(call.method);
          return '/storage/emulated/0/Books';
        },
      );
      addTearDown(() {
        binding.defaultBinaryMessenger
            .setMockMethodCallHandler(HibikiChannels.saf, null);
      });

      late BuildContext capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              capturedContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      // 覆写必须在 test body 内还原：flutter_test 在 body 结束时就校验 foundation
      // debug 变量已复位，addTearDown 太晚。
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final String? picked;
      try {
        picked = await pickRealDirectoryPath(
          context: capturedContext,
          appModel: appModel,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }

      expect(picked, '/storage/emulated/0/Books');
      expect(safCalls, <String>['pickRealDirectory'],
          reason: '安卓目录选择必须落到原生 SAF 选择器');
      expect(
        permission.cameraCalls,
        isEmpty,
        reason: '选文件夹的整条路径上不得出现任何相机权限查询或申请',
      );
    });
  });
}
