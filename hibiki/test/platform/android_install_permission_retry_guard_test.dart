import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-427/TODO-852: Android 安装权限授予后无法续接/重试安装。
///
/// 根因：`MainActivity` 的 installApk 权限门用 `startActivity(settings)` +
/// `FLAG_ACTIVITY_NEW_TASK` fire-and-forget，且立即 `result.error
/// (INSTALL_PERMISSION_REQUIRED)` —— 新任务脱离回调链，`onActivityResult`
/// 永不触发，用户授权返回后没有任何代码续接安装，会话/apk 已被 Dart 销毁，必须重下。
///
/// 修复：权限门改 `startActivityForResult(settings, INSTALL_PERMISSION_REQUEST)`
/// 并暂存 `pendingInstallResult` / `pendingInstallApkPath`；`onActivityResult` /
/// `onResume` 复查 `canRequestPackageInstalls` 后用暂存路径 `new File(apkPath)`
/// 续接 `launchApkInstaller`（复用已下载已校验的 cache-dir apk，不重下）。
/// host 无法注入真实 Android Activity 结果，故用源码守卫锁住 native 契约；撤修复即红。
void main() {
  late String src;

  setUpAll(() {
    src = File(
      'android/app/src/main/java/app/hibiki/reader/MainActivity.java',
    ).readAsStringSync();
  });

  String installApkHandlerBody() {
    final int idx = src.indexOf('if ("installApk".equals(call.method))');
    expect(idx, greaterThan(0), reason: 'installApk handler 必须存在。');
    // 取到 else { result.notImplemented(); } 之前为 handler 主体。
    final int end = src.indexOf('} else {', idx);
    expect(end, greaterThan(idx));
    return src.substring(idx, end);
  }

  test('安装权限门用 startActivityForResult，而非裸 startActivity(settings)', () {
    final String body = installApkHandlerBody();
    expect(
      body,
      contains('startActivityForResult('),
      reason: '权限门必须用 startActivityForResult 才能在 onActivityResult 续接。',
    );
    expect(
      body,
      contains('INSTALL_PERMISSION_REQUEST'),
      reason: '权限门必须用专属请求码登记结果回调。',
    );
    // handler 内不得对设置 intent 用 fire-and-forget 的 context.startActivity(settings)。
    expect(
      body.contains('startActivity(settings)'),
      isFalse,
      reason: '设置 intent 不能用 fire-and-forget 的 startActivity；必须走 forResult。',
    );
  });

  test('INSTALL_PERMISSION_REQUEST=1002 且与 SAF 请求码不同', () {
    expect(
      src,
      contains('INSTALL_PERMISSION_REQUEST = 1002'),
      reason: '安装权限请求码固定为 1002。',
    );
    expect(
      src,
      contains('SAF_PICK_DIR_REQUEST = 1001'),
      reason: 'SAF 请求码仍为 1001（向后兼容，不串扰）。',
    );
  });

  test('设置 intent 段不带 FLAG_ACTIVITY_NEW_TASK（否则回调链断）', () {
    final String body = installApkHandlerBody();
    // 精确限定到设置段：从 ACTION_MANAGE_UNKNOWN_APP_SOURCES 到该段的 return。
    final int settingsIdx = body.indexOf('ACTION_MANAGE_UNKNOWN_APP_SOURCES');
    expect(settingsIdx, greaterThan(0));
    final int settingsEnd = body.indexOf('return;', settingsIdx);
    expect(settingsEnd, greaterThan(settingsIdx));
    final String settingsSegment = body.substring(settingsIdx, settingsEnd);
    expect(
      settingsSegment.contains('FLAG_ACTIVITY_NEW_TASK'),
      isFalse,
      reason: '设置 intent 加 NEW_TASK 会脱离 result 回调链，onActivityResult 不触发。',
    );
  });

  test('onActivityResult 新增 INSTALL_PERMISSION_REQUEST 分支并续接安装', () {
    final int idx =
        src.indexOf('protected void onActivityResult(int requestCode');
    expect(idx, greaterThan(0));
    final String oar = src.substring(idx);
    expect(
      oar,
      contains('if (requestCode == INSTALL_PERMISSION_REQUEST)'),
      reason: 'onActivityResult 必须区分安装权限请求码分支。',
    );
    // 续接逻辑（复查权限 + new File(apkPath) + launchApkInstaller）落在
    // resumePendingInstall 里，由该分支调用。
    expect(src, contains('private void resumePendingInstall()'));
    expect(src, contains('canRequestPackageInstalls()'));
    expect(
      src,
      contains('launchApkInstaller(new File(apkPath)'),
      reason: '续接必须用暂存路径 new File(apkPath) 复用已下载 apk，不重下。',
    );
  });

  test('SAF 分支仍存在且独立（向后兼容）', () {
    final int idx =
        src.indexOf('protected void onActivityResult(int requestCode');
    final String oar = src.substring(idx);
    expect(oar, contains('if (requestCode == SAF_PICK_DIR_REQUEST)'),
        reason: 'SAF 续接分支必须保留。');
    expect(oar, contains('pendingSafResult'));
  });

  test('暂存字段 pendingInstallResult / pendingInstallApkPath 存在', () {
    expect(src, contains('MethodChannel.Result pendingInstallResult'));
    expect(src, contains('String pendingInstallApkPath'));
  });

  test('FileProvider.getUriForFile 只出现一次（抽 helper 无复制漂移）', () {
    final int count = 'FileProvider.getUriForFile('.allMatches(src).length;
    expect(
      count,
      1,
      reason: '安装 intent 构造应只在 launchApkInstaller 里出现一次，两路径共用。',
    );
  });

  test('onResume 兜底续接悬挂 pending（OEM 不回调 onActivityResult）', () {
    expect(
      src,
      contains('protected void onResume()'),
      reason: '某些 OEM 不回调 onActivityResult，需 onResume 兜底续接。',
    );
    final int idx = src.indexOf('protected void onResume()');
    final int end = src.indexOf('\n    }', idx);
    final String body = src.substring(idx, end);
    expect(body, contains('pendingInstallResult != null'));
    expect(body, contains('resumePendingInstall()'));
  });
}
