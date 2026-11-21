import 'dart:io';

import 'package:test/test.dart';

/// 新 checkout / 新 worktree 里 `fushi/android` 下的 gradle 任务要能直接跑。
///
/// 起因（2026-11-20 统计本机 11-15～11-20 的 heavy 历史与会话记录）：61 次本机
/// gradle 有 57 次失败，其中 32 次不到 5 秒就退出却合计排了 310 分钟的队。能读到
/// 原因的两类最多：
///
/// 1. `.\gradlew.bat` 不存在——Flutter 模板的 `.gitignore` 把 `gradlew` /
///    `gradlew.bat` / `gradle-wrapper.jar` 排除在库外，只有跑过
///    `flutter build apk` 的 checkout 才有；新 worktree 一个都没有，文档里写的
///    `.\gradlew.bat :app:assembleRelease` / `:app:testDebugUnitTest` 必然找不到。
/// 2. `:app:checkFushi*Native` 挂在 `preBuild` 上——JVM 单测和纯编译任务也被
///    「缺 Android 预编译 .so」拦下，而开发机的 worktree 从不带这些 .so。
///
/// 所以 wrapper 入库，硬依赖检查只拦「把 .so 收进包」的任务（缺库仍出不了包，
/// 由四个 `fushi_*_hard_dependency_guard_test.dart` 钉住）。
void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  test('gradle wrapper 入库：新 worktree 不必先跑 flutter build 才有 gradlew', () {
    for (final String path in <String>[
      'android/gradlew',
      'android/gradlew.bat',
      'android/gradle/wrapper/gradle-wrapper.jar',
      'android/gradle/wrapper/gradle-wrapper.properties',
    ]) {
      expect(File(path).existsSync(), isTrue, reason: '$path 必须入库');
    }
    final List<String> ignored = read('android/.gitignore')
        .split('\n')
        .map((String l) => l.trim())
        .where((String l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
    for (final String rule in <String>[
      'gradlew',
      '/gradlew',
      'gradlew.bat',
      '/gradlew.bat',
      'gradle-wrapper.jar',
    ]) {
      expect(
        ignored,
        isNot(contains(rule)),
        reason: 'android/.gitignore 不得再排除 wrapper（$rule）',
      );
    }
  });

  test('原生库硬依赖检查不挂 preBuild：JVM 单测与纯编译不需要预编译 .so', () {
    final String gradle = read('android/app/build.gradle');
    expect(gradle, isNot(contains('task.name == "preBuild"')));
    final int hook = gradle.indexOf(
      'if (task.name.startsWith("merge") && '
      'task.name.endsWith("JniLibFolders")) {',
    );
    expect(hook, greaterThanOrEqualTo(0));
    final int end = gradle.indexOf('\n    }', hook);
    final String body = gradle.substring(hook, end);
    for (final String check in <String>[
      'checkFushiComputeNative',
      'checkFushiRwkvNative',
      'checkFushiMusicNative',
      'checkFushiCorpusNative',
    ]) {
      expect(body, contains('task.dependsOn($check)'));
    }
    // fushi_web_core 只拦 Release，且必须是任务（排在 ensureFushiAndroidNative 之后）：
    // 早先在 gradle.taskGraph.whenReady 里查，任何任务都还没跑，自动备库永远来不及。
    expect(
      body,
      contains(
        'if (task.name.contains("Release")) {\n'
        '            task.dependsOn(checkFushiWebCoreNative)',
      ),
    );
    final int ready = gradle.indexOf('gradle.taskGraph.whenReady');
    expect(ready, greaterThanOrEqualTo(0));
    final String readyBody = gradle.substring(
      ready,
      gradle.indexOf('\n}\n', ready),
    );
    expect(readyBody, isNot(contains('WebCore')));
  });

  test('缺库时 gradle 自己备库：五个 check 都先跑 ensureFushiAndroidNative', () {
    final String gradle = read('android/app/build.gradle');
    expect(gradle, contains('tasks.register("ensureFushiAndroidNative")'));
    expect(gradle, contains("file('../../../tool/native_libs.ps1')"));
    // 每次都交给 native_libs.ps1 按源码戳记判，不能「库在就不管」：check 只看文件在不在，
    // 源码变了的旧 .so 会被静默打进包（合 #3951 时 fushi_compute 就是这样）。
    final int ensure = gradle.indexOf(
      'tasks.register("ensureFushiAndroidNative")',
    );
    final String ensureBody = gradle.substring(
      ensure,
      gradle.indexOf('\n}\n', ensure),
    );
    expect(ensureBody, isNot(contains('.isFile()')));
    expect(ensureBody, isNot(contains('if (!missing)')));
    expect(gradle, contains("'-Android', '-Abis', abis.join(',')"));
    expect(
      gradle,
      contains(
        '[checkFushiComputeNative, checkFushiRwkvNative, '
        'checkFushiMusicNative, checkFushiCorpusNative,\n'
        ' checkFushiWebCoreNative].each { check ->\n'
        '    check.configure { dependsOn(ensureFushiAndroidNative) }',
      ),
    );
    // gradle 与脚本备的是同一组 crate。
    const String crates =
        "'fushi_compute', 'fushi_rwkv', 'fushi_music', 'fushi_corpus', "
        "'fushi_web_core'";
    expect(gradle, contains('def fushiAndroidNativeCrates = [$crates]'));
    final String script = read('../tool/native_libs.ps1');
    expect(script, contains('\$NativeAndroidCrates = @($crates)'));
    expect(script, contains('[switch]\$Android'));
  });
}
