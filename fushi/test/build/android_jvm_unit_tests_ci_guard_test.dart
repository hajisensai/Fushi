import 'dart:io';

import 'package:test/test.dart';

/// Android JVM 单测（`fushi/android/app/src/test`）必须有 CI 真跑，且红了判红。
/// 以前没有任何 workflow 执行它们（`flutter build apk` 不跑 JVM 单测），
/// CrossAppAudioRingTest / ScreenOcrLayoutTest 等 20 多个文件从未执行过。
void main() {
  late String yaml;

  setUpAll(() {
    yaml = File('../.github/workflows/main.yml').readAsStringSync();
  });

  /// 取 `name: <stepName>` 那一步的正文（到下一个同缩进的 `- ` 为止）。
  String stepBody(String stepName) {
    final int start = yaml.indexOf('- name: $stepName');
    expect(start, greaterThanOrEqualTo(0), reason: 'main.yml 缺少步骤 $stepName');
    final int next = yaml.indexOf('\n    - ', start + 1);
    return yaml.substring(start, next < 0 ? yaml.length : next);
  }

  test('main.yml 的 build job 跑 :app:testDebugUnitTest，失败即红', () {
    final String body = stepBody(
      'Android JVM unit tests (:app:testDebugUnitTest)',
    );
    expect(body, contains('./gradlew :app:testDebugUnitTest'));
    // app 的 checkFushi*Native 按 target-platform 查原生库，本 job 只编了 arm64。
    expect(body, contains('-Ptarget-platform=android-arm64'));
    // gradlew 需要 local.properties（flutter.sdk），由 --config-only 生成。
    expect(body, contains('flutter build apk --config-only'));
    expect(body, contains('set -euo pipefail'));
    expect(body, isNot(contains('continue-on-error')));
    expect(body, isNot(contains('|| true')));
  });

  test('JVM 单测挂在 R8 同一个路径门上，workflow_dispatch 照跑', () {
    final String body = stepBody(
      'Android JVM unit tests (:app:testDebugUnitTest)',
    );
    expect(
      body,
      contains(
        "if: github.event_name != 'pull_request' || "
        "steps.r8.outputs.needed == 'true'",
      ),
    );
    // 必须排在路径门判定之后，否则 steps.r8 还没有输出、PR 上永远被跳过。
    expect(
      yaml.indexOf('id: r8'),
      lessThan(yaml.indexOf('- name: Android JVM unit tests')),
    );
  });

  test('JVM 单测源码目录存在（守卫不是空转）', () {
    final Directory dir = Directory('android/app/src/test/kotlin');
    expect(dir.existsSync(), isTrue);
    expect(
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('Test.kt')),
      isNotEmpty,
    );
  });
}
