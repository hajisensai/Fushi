// 守卫：仅跑 Android 模拟器的总集成编排必须只构建 x86_64 APK。
//
// 模拟器固定使用 x86_64 AVD。若 `flutter build apk --debug` 不指定目标
// 架构，Flutter 会同时构建 arm、arm64 与 x64；sqlite3 3.x 的 native-assets
// hook 随后会为三个 ABI 分别下载动态库。无关的 ARM 下载一旦超时，模拟器测试
// 会在安装前失败。限定 android-x64 既与设备 ABI 一致，也与独立 AnkiDroid
// 模拟器编排保持一致。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/ci/integration-test.sh').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    '找不到含 ci/integration-test.sh 的仓库根'
    '（从 ${Directory.current.path} 向上）',
  );
}

void main() {
  test('模拟器总编排只构建 android-x64 APK', () {
    final script = File('${_repoRoot().path}/ci/integration-test.sh');
    expect(script.existsSync(), isTrue, reason: '缺 ${script.path}');

    final content = script.readAsStringSync();
    expect(
      content,
      contains(r'$FLUTTER" build apk --debug --target-platform android-x64'),
      reason: 'ci/integration-test.sh 只操作 x86_64 AVD，却构建了默认三 ABI APK。'
          '这会触发无关 ARM/ARM64 native-assets 下载，任一下载超时都会在安装前'
          '杀掉模拟器测试（BUG-817）。',
    );
  });
}
