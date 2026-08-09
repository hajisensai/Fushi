import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/android/android_permission_service.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';

import '../helpers/fake_platform_services.dart';

/// 忠实复刻 `permission_handler_android` 10.2.1 的原生语义（`PermissionManager.java`）：
///
/// - `MANAGE_EXTERNAL_STORAGE` 在 `SDK_INT < VERSION_CODES.R`(30) 时，
///   `checkPermissionStatus` 与 `requestPermissions` 都返回 `RESTRICTED`
///   （见 PermissionManager.java 的 `SDK_INT < R -> PERMISSION_STATUS_RESTRICTED`）。
/// - 其余权限按 [granted] 集合返回 granted / denied。
///
/// 这里建模的是**平台插件的行为**，不是被测谓词的副本——被测对象仍是真实的
/// [AndroidPermissionService]。
class _FakePermissionHandlerPlatform extends PermissionHandlerPlatform {
  _FakePermissionHandlerPlatform({required this.sdkInt});

  int sdkInt;
  final Set<Permission> granted = <Permission>{};
  final List<Permission> checked = <Permission>[];
  final List<Permission> requested = <Permission>[];

  PermissionStatus _statusOf(Permission permission) {
    if (permission == Permission.manageExternalStorage && sdkInt < 30) {
      return PermissionStatus.restricted;
    }
    return granted.contains(permission)
        ? PermissionStatus.granted
        : PermissionStatus.denied;
  }

  @override
  Future<PermissionStatus> checkPermissionStatus(Permission permission) async {
    checked.add(permission);
    return _statusOf(permission);
  }

  @override
  Future<Map<Permission, PermissionStatus>> requestPermissions(
    List<Permission> permissions,
  ) async {
    requested.addAll(permissions);
    return <Permission, PermissionStatus>{
      for (final Permission permission in permissions)
        permission: _statusOf(permission),
    };
  }
}

void main() {
  late PermissionHandlerPlatform originalPlatform;
  late _FakePermissionHandlerPlatform platform;

  AndroidPermissionService serviceFor(int? sdk) {
    final FakeDeviceInfoService deviceInfo = FakeDeviceInfoService()..sdk = sdk;
    return AndroidPermissionService(deviceInfo);
  }

  setUp(() {
    originalPlatform = PermissionHandlerPlatform.instance;
    platform = _FakePermissionHandlerPlatform(sdkInt: 30);
    PermissionHandlerPlatform.instance = platform;
  });

  tearDown(() {
    PermissionHandlerPlatform.instance = originalPlatform;
  });

  group('BUG-1213 旧安卓（API 24~29）查询侧', () {
    // 这是修复前恒假的那条路径：MANAGE_EXTERNAL_STORAGE 在 API < 30 恒 restricted，
    // 于是选文件夹恒走「需要授权」分支返回 null，用户根本加不了扫描根。
    for (final int sdk in <int>[24, 26, 28, 29]) {
      test('API $sdk 上已授予 storage → 查询侧返回已授权', () async {
        platform.sdkInt = sdk;
        platform.granted.add(Permission.storage);

        expect(await serviceFor(sdk).hasExternalStoragePermission(), isTrue);
        expect(
          platform.checked,
          contains(Permission.storage),
          reason: 'API < 30 必须查 storage，而不是恒 restricted 的 '
              'manageExternalStorage',
        );
        expect(platform.checked,
            isNot(contains(Permission.manageExternalStorage)));
      });

      test('API $sdk 上未授予 storage → 查询侧返回未授权', () async {
        platform.sdkInt = sdk;

        expect(await serviceFor(sdk).hasExternalStoragePermission(), isFalse);
      });
    }

    test(
        'API 29（分区存储中间态）仍以 storage 为准：manageExternalStorage 在 29 上'
        '无法被授予，storage 是该系统唯一可得的外部存储权限', () async {
      platform.sdkInt = 29;
      // 即便平台把 manageExternalStorage 标进 granted 集合，真实设备上 29 也
      // 拿不到它（下面的 restricted 语义会覆盖），查询结论只能来自 storage。
      platform.granted.add(Permission.manageExternalStorage);

      expect(await serviceFor(29).hasExternalStoragePermission(), isFalse);

      platform.granted.add(Permission.storage);
      expect(await serviceFor(29).hasExternalStoragePermission(), isTrue);
    });
  });

  group('BUG-1213 新安卓（API >= 30）行为不变', () {
    for (final int sdk in <int>[30, 33, 35]) {
      test('API $sdk 上已授予 manageExternalStorage → 查询侧返回已授权', () async {
        platform.sdkInt = sdk;
        platform.granted.add(Permission.manageExternalStorage);

        expect(await serviceFor(sdk).hasExternalStoragePermission(), isTrue);
        expect(platform.checked, contains(Permission.manageExternalStorage));
        expect(platform.checked, isNot(contains(Permission.storage)));
      });
    }

    test('API 30 上只有基础 storage 不算全文件访问', () async {
      platform.sdkInt = 30;
      platform.granted.add(Permission.storage);

      expect(await serviceFor(30).hasExternalStoragePermission(), isFalse);
    });

    test('sdkVersion 拿不到时按新系统处理（查 manageExternalStorage）', () async {
      platform.sdkInt = 30;
      platform.granted.add(Permission.manageExternalStorage);

      expect(await serviceFor(null).hasExternalStoragePermission(), isTrue);
      expect(platform.checked, contains(Permission.manageExternalStorage));
    });
  });

  group('BUG-1213 查询侧与申请侧对称', () {
    test('API 24~29 申请侧直接申请 storage', () async {
      platform.sdkInt = 26;
      platform.granted.add(Permission.storage);

      expect(await serviceFor(26).requestExternalStoragePermission(), isTrue);
      expect(platform.requested, contains(Permission.storage));
      expect(
        platform.requested,
        isNot(contains(Permission.manageExternalStorage)),
        reason: 'API < 30 申请 manageExternalStorage 只会拿到 restricted，是空转',
      );
    });

    test('API >= 30 申请侧仍先要 manageExternalStorage，被拒后回退 storage', () async {
      platform.sdkInt = 33;

      expect(await serviceFor(33).requestExternalStoragePermission(), isFalse);
      expect(
          platform.requested,
          containsAllInOrder(<Permission>[
            Permission.manageExternalStorage,
            Permission.storage,
          ]));
    });

    // 根因形状是「两侧对同一件事给出不同答案」。这条把整张 SDK × 授权矩阵
    // 都跑一遍，锁死两侧同源。
    for (final int sdk in <int>[24, 28, 29, 30, 33]) {
      for (final Set<Permission> preGranted in <Set<Permission>>{
        <Permission>{},
        <Permission>{Permission.storage},
        <Permission>{Permission.manageExternalStorage},
        <Permission>{Permission.storage, Permission.manageExternalStorage},
      }) {
        test(
            'API $sdk / 已授 ${preGranted.map((Permission p) => p.value).toList()}'
            ' → 申请侧返回值与查询侧一致', () async {
          platform.sdkInt = sdk;
          platform.granted.addAll(preGranted);
          final AndroidPermissionService service = serviceFor(sdk);

          final bool requestAnswer =
              await service.requestExternalStoragePermission();
          final bool queryAnswer = await service.hasExternalStoragePermission();

          expect(requestAnswer, queryAnswer);
        });
      }
    }
  });
}
