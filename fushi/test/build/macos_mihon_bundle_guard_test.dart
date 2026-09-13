import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS debug launcher builds, bundles, and verifies the Mihon bridge',
      () {
    final String script = File('../script/build_and_run.sh').readAsStringSync();

    expect(script, contains('FUSHI_MIHON_ARCHS=host bash'));
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
    expect(script, contains('x64_archive_sha256='));
    expect(script, contains('arm64_archive_sha256='));
    expect(script, contains('shasum -a 256 --check'));
    expect(script, contains('--continue-at -'));
  });

  test('Mihon runtime 默认出全架构，不是 runner 的 host 架构', () {
    final String script =
        File('../tool/mihon/build_desktop_runtime.sh').readAsStringSync();

    expect(
      script,
      contains(r'${FUSHI_MIHON_ARCHS:-all}'),
      reason: '发布包必须两个架构都出。降级成 host 会让 Intel Mac 上整条 Mihon 链'
          '直接没有 JVM 镜像可用。',
    );
  });

  test('verify 脚本用 app 本体核对 JVM 镜像的架构覆盖', () {
    final String script =
        File('../tool/mihon/verify_desktop_runtime.sh').readAsStringSync();

    expect(
      script,
      contains(r'lipo -archs "$app_executable"'),
      reason: '脚本原本只按 uname -m 冒烟宿主架构的 java，而 runner 恒是 Apple '
          'Silicon——交叉 jlink 出来的 x64 镜像一次都没被核对过。',
    );
    expect(
      script,
      contains('runtime-macos-x64/bin/java'),
      reason: 'Dart 侧按 Abi.current() 选目录，两个目录都要能被这道门核到。',
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
