import 'dart:io';

import 'package:test/test.dart';

/// 源码守卫：五端都打开 Flutter GPU（package:flutter_gpu），全屏歌词「镜台」才能用真 3D
/// 渲染器（lib/src/media/music/lyrics/visualizer/modes/diorama/diorama_gpu.dart）。
///
/// 任何一端掉了开关都不会报错——镜台会在那一端静默退回 Canvas 后备实现，只在诊断日志里留一条
/// 「Flutter GPU unavailable」。所以开关本身由这里咬住；同时确认 pubspec 登记了 hook 编出的
/// 着色器包，hook 本身也在。
void main() {
  // 测试的工作目录是 fushi/。
  String read(String path) {
    final File f = File(path);
    expect(f.existsSync(), isTrue, reason: '$path should exist');
    return f.readAsStringSync();
  }

  test('Windows runner 打开 Flutter GPU', () {
    expect(
      read('windows/runner/main.cpp'),
      contains('project.set_enable_flutter_gpu(true);'),
    );
  });

  test('Linux runner 打开 Flutter GPU', () {
    expect(
      read('linux/runner/my_application.cc'),
      contains('fl_dart_project_set_enable_flutter_gpu(project, TRUE);'),
    );
  });

  test('Android manifest 打开 Flutter GPU', () {
    final String manifest = read('android/app/src/main/AndroidManifest.xml');
    expect(
      RegExp(
        r'android:name="io\.flutter\.embedding\.android\.EnableFlutterGPU"\s+'
        r'android:value="true"',
      ).hasMatch(manifest),
      isTrue,
    );
  });

  for (final String plist in <String>[
    'ios/Runner/Info.plist',
    'macos/Runner/Info.plist',
  ]) {
    test('$plist 打开 Flutter GPU', () {
      expect(
        RegExp(
          r'<key>FLTEnableFlutterGPU</key>\s*<true/>',
        ).hasMatch(read(plist)),
        isTrue,
      );
    });
  }

  test('着色器包由构建钩子编出并登记为资源', () {
    expect(
      read('hook/build.dart'),
      contains('shaders/diorama.shaderbundle.json'),
    );
    expect(
      read('pubspec.yaml'),
      contains('- build/shaderbundles/diorama.shaderbundle'),
    );
    expect(
      read('shaders/diorama.shaderbundle.json'),
      contains('DioramaPlaneVertex'),
    );
  });
}
