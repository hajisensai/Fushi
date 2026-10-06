import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS debug launcher builds, bundles, and verifies the Mihon bridge',
      () {
    final String script = File('../script/build_and_run.sh').readAsStringSync();

    expect(script, contains('tool/mihon/build_desktop_runtime.sh'));
    expect(
      script,
      contains(
        r'mihon_bundle="$app/Contents/Resources/mihon_bridge"',
      ),
    );
    expect(script, contains('tool/mihon/verify_desktop_runtime.sh'));
    expect(script, contains('m-extension-server.jar'));
    expect(script, contains(r'$mihon_host_runtime/bin/java'));
  });

  test('macOS Mihon JDK downloads are pinned and checksum verified', () {
    final String script =
        File('../tool/mihon/build_desktop_runtime.sh').readAsStringSync();

    expect(script, contains('corretto_version="21.0.12.8.1"'));
    expect(script, contains('corretto.aws/downloads/resources'));
    expect(script, contains('arm64_archive_sha256='));
    expect(
      script,
      contains('amazon-corretto-\$corretto_version-macosx-aarch64.tar.gz'),
    );
    // 按宿主选工具：macOS 14+ 的 /sbin/sha256sum 是 BSD 版、不认 GNU 的
    // --status，按「PATH 里有没有 sha256sum」探测会在 macOS 上全判失败。
    expect(script, contains('Darwin) sha256_tool=(shasum -a 256)'));
    expect(script, contains(r'"${sha256_tool[@]}" --check'));
    expect(script, isNot(contains('--check --status')));
    expect(script, contains('--continue-at -'));
  });

  test('macOS 只出 arm64 的 Mihon runtime（不再支持 Intel Mac）', () {
    final String script =
        File('../tool/mihon/build_desktop_runtime.sh').readAsStringSync();

    expect(script, contains('"runtime-macos-arm64"'));
    expect(
      script,
      isNot(contains('runtime-macos-x64')),
      reason: 'macOS 版只出 Apple Silicon，x64 JVM 镜像是死重。',
    );
    expect(
      script,
      isNot(contains('macosx-x64')),
      reason: 'macOS x64 JDK 归档不再下载、不再钉哈希。',
    );
    expect(script, isNot(contains('FUSHI_MIHON_ARCHS')));

    final String runtime = File(
      'lib/src/media/manga/mihon/desktop_mihon_runtime.dart',
    ).readAsStringSync();
    expect(runtime, contains("'runtime-macos-arm64'"));
    expect(runtime, isNot(contains('runtime-macos-x64')));
  });

  test('verify 脚本用 app 本体核对 JVM 镜像的架构覆盖', () {
    final String script =
        File('../tool/mihon/verify_desktop_runtime.sh').readAsStringSync();

    expect(
      script,
      contains(r'lipo -archs "$app_executable"'),
      reason: '脚本原本只按 uname -m 冒烟宿主架构的 java；按 app 本体的架构核对'
          '才能拦住「app 带了某架构、JVM 镜像却没有」的包。',
    );
    expect(
      script,
      contains('runtime-macos-arm64/bin/java'),
      reason: 'Dart 侧只认 runtime-macos-arm64，这道门必须核到它。',
    );
    expect(
      script,
      isNot(contains('runtime-macos-x64')),
      reason: 'app 意外带上 x86_64 切片时必须直接红，而不是去找不存在的 x64 镜像。',
    );
    expect(
      script,
      contains('EBADARCH'),
      reason: '架构不匹配时必须给出可诊断的失败原因，而不是一句泛泛的 verify failed。',
    );
  });

  test('两条 macOS job 都把 app 本体喂给 Mihon 的架构门', () {
    for (final String path in <String>[
      '../.github/workflows/release-desktop.yml',
      '../.github/workflows/build-multiplatform.yml',
    ]) {
      final String workflow = File(path).readAsStringSync();

      expect(
        workflow,
        contains(r'tool/mihon/verify_desktop_runtime.sh "$runtime_dir" '
            r'"$app_dir/Contents/MacOS/fushi"'),
        reason: '$path 不传 app 本体，verify 里的架构覆盖门就整段被跳过。',
      );
    }
  });
}
