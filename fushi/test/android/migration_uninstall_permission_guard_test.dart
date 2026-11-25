import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-4506 source-scan guard：首页「卸载 Hibiki」按钮走
/// `MigrationChannelHandler.requestUninstall` 发 `Intent.ACTION_DELETE`。
///
/// Android 9（API 28）起 ACTION_DELETE 的调用方必须持有
/// `REQUEST_DELETE_PACKAGES`，没有时系统卸载器（UninstallerActivity）记一行日志
/// 就 finish——不弹确认框、不抛异常，按钮看起来什么都没做。系统 intent 解析在
/// flutter test / JVM 单测里都跑不到，故这里钉「发了 ACTION_DELETE 就必须声明权限」。
void main() {
  // Tests run with CWD = `fushi/`.
  const String handlerPath =
      'android/app/src/main/java/app/fushi/reader/MigrationChannelHandler.java';
  const String manifestPath = 'android/app/src/main/AndroidManifest.xml';

  test('ACTION_DELETE caller declares REQUEST_DELETE_PACKAGES', () {
    final String handler = maskComments(File(handlerPath).readAsStringSync());
    expect(
      handler,
      contains('Intent.ACTION_DELETE'),
      reason: 'requestUninstall no longer uses ACTION_DELETE; update guard',
    );
    final String manifest = maskHtmlComments(
      File(manifestPath).readAsStringSync(),
    );
    expect(
      manifest,
      contains(
        '<uses-permission '
        'android:name="android.permission.REQUEST_DELETE_PACKAGES"',
      ),
    );
  });
}
