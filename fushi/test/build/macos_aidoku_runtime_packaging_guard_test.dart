import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1922：macOS 发布包从来没装过 Aidoku runtime。
///
/// `tool/aidoku/build_macos_runtime.sh` 在全仓只被本地开发脚本
/// `script/build_and_run.sh` 调用过，两条 macOS CI job 一步都没有，于是每个从
/// release zip 装进 /Applications 的用户一碰 Aidoku 仓库（刷新 / 删掉再添加 /
/// 装扩展）就吃 `AidokuRuntimeException(RUNTIME_MISSING)`——而 CI 全绿，因为没有
/// 任何一处断言过「app bundle 里得有这个 helper」。
///
/// 这组守卫钉的就是那条不变式：**Dart 侧去哪里找 runtime，打包就得把它装到哪里，
/// 并且装完要证明它真能跑**。判据两侧来源不同（Dart 源码 vs workflow YAML），
/// 所以任何一侧单独漂移都会红。
void main() {
  String read(String relativeToFushi) {
    final File file = File(relativeToFushi);
    expect(file.existsSync(), isTrue,
        reason: 'expected file at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  /// 截出顶层 job（key 缩进 2 空格）的正文，避免把别的 job 的步骤算进来。
  ///
  /// 调用方一律先过 [maskHashComments]：本仓的步骤注释里就写着脚本路径和「必须
  /// 排在 Developer ID 签名之前」，不掩的话 indexOf 会先命中注释里的那份字面
  /// 量，存在性与顺序两类断言都恒绿。用等长掩码而不是删行，indexOf 的下标才
  /// 仍与原文对齐。
  String extractJob(String yaml, String job) {
    final int start = yaml.indexOf('\n  $job:\n');
    expect(start, isNot(-1), reason: 'job "$job" not found');
    final RegExp nextJob = RegExp(r'\n  [A-Za-z0-9_-]+:\n');
    final Match? next = nextJob.firstMatch(yaml.substring(start + 1));
    return next == null
        ? yaml.substring(start)
        : yaml.substring(start, start + 1 + next.start);
  }

  const String releaseWorkflow = '../.github/workflows/release-desktop.yml';
  const String multiWorkflow = '../.github/workflows/build-multiplatform.yml';

  test('Dart 侧仍在 app bundle 的固定路径上找 Aidoku runtime', () {
    final String runtime =
        read('lib/src/media/manga/aidoku/aidoku_runtime.dart');

    // 这三段是 DesktopAidokuRuntime._bundledExecutable() 拼出来的路径。守卫的
    // 另一半（下面的 workflow 断言）就钉在它们上；这里先证明它们没被改掉，否则
    // 下面的路径比对会变成拿 workflow 跟一个已经不存在的契约对账。
    expect(runtime, contains("'Resources',"));
    expect(runtime, contains("'aidoku_runtime',"));
    expect(runtime, contains("'fushi-aidoku-runtime',"));
    expect(runtime, contains("'RUNTIME_MISSING'"),
        reason: 'runtime 缺失时必须还是这个可诊断的错误码。');
  });

  test('两条 macOS job 都把 Aidoku runtime 装进 bundle 并验证', () {
    for (final String path in <String>[releaseWorkflow, multiWorkflow]) {
      final String job = extractJob(maskHashComments(read(path)), 'macos');

      expect(job, contains('tool/aidoku/build_macos_runtime.sh'),
          reason: '$path 的 macos job 不打 Aidoku runtime，发布包里就没有它。');
      expect(job, contains('tool/aidoku/verify_macos_runtime.sh'),
          reason: '$path 的 macos job 缺硬门：没跑 verify 就没人能发现 runtime '
              '没装进去。');
      expect(job, contains(r'Contents/Resources/aidoku_runtime'),
          reason: '$path 装错目录的话 Dart 侧照样找不到。');
    }
  });

  test('发布 job 在 Developer ID 签名之前装 Aidoku runtime', () {
    final String job =
        extractJob(maskHashComments(read(releaseWorkflow)), 'macos');

    final int bundled = job.indexOf('tool/aidoku/build_macos_runtime.sh');
    final int signed = job.indexOf('Sign macOS app with Developer ID');
    expect(bundled, isNot(-1));
    expect(signed, isNot(-1));
    expect(bundled, lessThan(signed),
        reason: 'Developer ID 那一步按 Mach-O 判定重签 bundle 里每个可执行体。'
            'runtime 排在它后面进 bundle 就是未签名负载，公证会被拒。');
  });

  test('发布 job 用 app 本体核对 runtime 的架构覆盖', () {
    final String job =
        extractJob(maskHashComments(read(releaseWorkflow)), 'macos');

    expect(
        job,
        contains(
            r'tool/aidoku/verify_macos_runtime.sh "$runtime_dir" "$app_dir/Contents/MacOS/fushi"'),
        reason: 'BUG-1668 同形：runner 是 Apple Silicon，arm64-only 的 helper '
            '在 CI 上一路全绿，到 Intel Mac 上被内核以 EBADARCH 拒掉。verify 必须'
            '拿到 app 本体才能做架构覆盖核对。');
  });

  test('发布 job 不得把 Aidoku runtime 降级成 host 架构', () {
    final String job =
        extractJob(maskHashComments(read(releaseWorkflow)), 'macos');

    expect(job, isNot(contains('FUSHI_AIDOKU_ARCHS')),
        reason: '发布包必须走脚本默认的 universal。降级成 host 最终会被同一步里的'
            '架构覆盖门拦下（app 本体是 universal，runtime 只有一个架构就盖不住），'
            '但那要先烧掉十几分钟的 macOS 构建才红；这条在 PR 单测阶段秒级就红。'
            'debug job 显式用 host 是有意的，见 build-multiplatform.yml 的注释。');
  });

  test('构建脚本默认出 universal，不是 runner 的 host 架构', () {
    final String script = read('../tool/aidoku/build_macos_runtime.sh');

    expect(script, contains(r'${FUSHI_AIDOKU_ARCHS:-universal}'),
        reason: '默认必须是 universal；host 只留给本地开发显式指定。');
    expect(script, contains('aarch64-apple-darwin'));
    expect(script, contains('x86_64-apple-darwin'));
    expect(script, contains(r'--target "$rust_target"'),
        reason: '裸 cargo build 只出 host 架构。');
    expect(script, contains('lipo -create'),
        reason: '多架构产物必须合成一个 fat 二进制。');
    expect(script, isNot(contains(r'/target/release/fushi-aidoku-runtime')),
        reason: '这是 host-only 构建的产物路径，回到它就意味着交叉编译被拿掉了。');
  });

  test('verify 脚本自己就是硬门：存在性 + 架构覆盖 + 真启动', () {
    final String script = read('../tool/aidoku/verify_macos_runtime.sh');

    expect(script, contains('fushi-aidoku-runtime'));
    expect(script, contains('lipo -archs'),
        reason: '架构覆盖核对是这道门的主要价值。');
    expect(script, contains('usage: fushi-aidoku-runtime'),
        reason: '冒烟判据：进程真起来了才会打出 usage。');
    expect(script, contains('exit 1'));
  });
}
