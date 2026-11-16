import 'dart:io';

import 'package:test/test.dart';

/// BUG-4738 守卫：Android Mihon 宿主必须提供 extension-lib 约定的
/// `eu.kanade.tachiyomi.AppInfo`。
///
/// Mihon 的 extension-lib 1.3 起把 `AppInfo`（`getVersionCode` / `getVersionName`，
/// 1.5 加 `getSupportedImageMimeTypes`）列为宿主 API，扩展当 compileOnly 引用
/// （keiyoushi MangaDex 用它拼 User-Agent）。上游 Mihon 把它放在 **app 模块**而不在
/// `source-api`，所以 `prepareMihonSourceApi` 拉 source-api 时拉不到；桌面 sidecar
/// 的 `upstream_src` 自带一份，Android 宿主却漏了，于是 Android 上这类扩展一用就
/// `NoClassDefFoundError: Failed resolution of: Leu/kanade/tachiyomi/AppInfo;`。
///
/// JVM 形状（`INSTANCE` + 三个实例方法的描述符）由
/// `android/app/src/test/kotlin/eu/kanade/tachiyomi/AppInfoAbiTest.kt` 反射钉住；
/// 本守卫只在 Dart 测试层锁源码存在与声明形状，R8 keep 覆盖由
/// `mihon_host_abi_keep_guard_test.dart` 的清单负责。
void main() {
  const String appInfoPath =
      'android/app/src/main/kotlin/eu/kanade/tachiyomi/AppInfo.kt';

  test('Android 宿主以 Kotlin object 声明 eu.kanade.tachiyomi.AppInfo', () {
    final File file = File(appInfoPath);
    expect(
      file.existsSync(),
      isTrue,
      reason:
          'Android 宿主缺 $appInfoPath：调用 AppInfo 的扩展（如 MangaDex）会 '
          'NoClassDefFoundError',
    );
    final String code = file.readAsStringSync();
    expect(
      RegExp(
        r'^package eu\.kanade\.tachiyomi\s*$',
        multiLine: true,
      ).hasMatch(code),
      isTrue,
      reason: '包名必须是 eu.kanade.tachiyomi（扩展 dex 按全名解析）',
    );
    // object 而不是 class：扩展字节码是 getstatic AppInfo.INSTANCE。
    expect(
      RegExp(r'^object AppInfo\b', multiLine: true).hasMatch(code),
      isTrue,
    );
    for (final RegExp signature in <RegExp>[
      RegExp(r'fun getVersionCode\(\): Int\b'),
      RegExp(r'fun getVersionName\(\): String\b'),
      RegExp(r'fun getSupportedImageMimeTypes\(\): List<String>'),
    ]) {
      expect(
        signature.hasMatch(code),
        isTrue,
        reason: '$appInfoPath 缺 extension-lib 约定的 ${signature.pattern}',
      );
    }
  });
}
