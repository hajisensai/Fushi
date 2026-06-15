import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-013 演进（全平台自动更新 Phase 1）：更新分区不再仅 Android。
/// 不变量：分区按 platformSupportsUpdateCheck()（恒真）可见；自动安装开关按
/// platformSupportsInAppInstall()（本期 Android+Windows）网关；数据侧 UpdateChecker
/// 不再硬门控 Android，而是按 updater.supportsUpdateCheck。
void main() {
  test('update section gated by capability helper, not Platform.isAndroid', () {
    final String src =
        File('lib/src/settings/settings_schema.dart').readAsStringSync();
    final String systemDest = _functionSource(
      src,
      'SettingsDestination _systemDestination() {',
      'String _selectedUpdateChannel(',
    );
    expect(
        systemDest, contains('visible: (_) => platformSupportsUpdateCheck()'));
    expect(systemDest.contains('visible: (_) => Platform.isAndroid'), isFalse,
        reason: '更新分区不应再硬绑 Android（已扩展到全平台）');
    final int autoIdx = systemDest.indexOf("id: 'system.update_auto_install'");
    expect(autoIdx, isNonNegative);
    expect(
        systemDest, contains('visible: (_) => platformSupportsInAppInstall()'),
        reason: '自动安装开关必须按 platformSupportsInAppInstall 网关');
  });

  test('UpdateChecker no longer hard-returns on non-Android', () {
    final String src =
        File('lib/src/utils/misc/update_checker.dart').readAsStringSync();
    expect(src.contains('if (!Platform.isAndroid) return;'), isFalse,
        reason: '检查流程已按 updater.supportsUpdateCheck 门控');
    expect(src, contains('updaterForCurrentPlatform()'));
  });

  test('release workflow publishes platform-filtered debug Android channel',
      () {
    final String workflow =
        File('../.github/workflows/release.yml').readAsStringSync();
    expect(
      workflow,
      contains(
        r'TAG="${TAG:-v${VERSION}-debug.${RELEASE_SEQUENCE}+${SHORT_SHA}}"',
      ),
    );
    expect(
      workflow,
      contains(r'RELEASE_SEQUENCE=$(git rev-list --count HEAD)'),
    );
    expect(
      workflow,
      contains(
        r'ANDROID_BUILD_NUMBER=$RELEASE_SEQUENCE',
      ),
    );
    expect(workflow, contains('BUILD_DEBUG_CHANNEL_APK=true'));
    expect(workflow, contains('flutter --verbose build apk --release'));
    expect(
      workflow,
      contains(
        r'--build-name "${{ steps.channel.outputs.build_version_name }}"',
      ),
    );
    expect(
      workflow,
      contains(
        r'--build-number "${{ steps.channel.outputs.android_build_number }}"',
      ),
    );
    expect(
      workflow,
      contains(r'prerelease: ${{ steps.channel.outputs.prerelease }}'),
    );
    expect(
      workflow,
      contains(r'make_latest: ${{ steps.channel.outputs.make_latest }}'),
    );
  });

  test(
      'desktop release workflow publishes platform-filtered debug Windows installer',
      () {
    final String workflow =
        File('../.github/workflows/release-desktop.yml').readAsStringSync();
    expect(workflow, contains("push:\n    branches: ['main', 'develop']"));
    expect(workflow, contains('Release channel: debug, beta, or formal'));
    expect(workflow, contains('- debug'));
    expect(workflow, contains(r'case "$EVENT" in'));
    expect(workflow, contains('push)'));
    expect(
      workflow,
      contains(
        r'TAG="${TAG:-v${VERSION}-debug.${RELEASE_SEQUENCE}+${SHORT_SHA}}"',
      ),
    );
    expect(
      workflow,
      contains(r'RELEASE_SEQUENCE=$(git rev-list --count HEAD)'),
    );
    expect(workflow, contains('CHANNEL=debug'));
    expect(workflow, contains('PUBLISH_MANAGED_RELEASE=true'));
    expect(workflow, contains(r'BUILD_VERSION_NAME="${TAG#v}"'));
    expect(
        workflow, contains(r'BUILD_VERSION_NAME="${BUILD_VERSION_NAME%%+*}"'));
    expect(workflow, contains('flutter build windows --release'));
    expect(
      workflow,
      contains(
        r'--build-name "${{ steps.channel.outputs.build_version_name }}"',
      ),
      reason: 'installed Windows debug build must report the debug run version',
    );
    expect(
      workflow,
      contains(
        r'--build-number "${{ steps.channel.outputs.release_sequence }}"',
      ),
      reason: 'Windows version resource uses the shared release sequence',
    );
    expect(
      workflow,
      contains(
        r'"/DAppVersion=${{ steps.channel.outputs.build_version_name }}"',
      ),
    );
    expect(
      workflow,
      contains(
        r'hibiki-${{ steps.channel.outputs.build_version_name }}-windows-setup.exe',
      ),
    );
    expect(workflow, contains('Prepare Windows installer release asset'));
    expect(
      workflow,
      contains(r'*-debug.*-windows-setup.exe'),
      reason: 'debug channel installer asset must match WindowsUpdater',
    );
    expect(
      workflow,
      contains('hibiki/build/release-artifacts/hibiki-*-windows-setup.exe'),
    );
    expect(
      workflow,
      contains(r'prerelease: ${{ steps.channel.outputs.prerelease }}'),
    );
    expect(
      workflow,
      contains(r'make_latest: ${{ steps.channel.outputs.make_latest }}'),
    );
  });

  test('build docs describe platform-scoped debug run numbers', () {
    final String docs = File('../docs/agent/build.md').readAsStringSync();
    expect(
      docs,
      contains(r'v<version>-debug.<seq>+<short-sha>'),
    );
    expect(
      docs,
      contains('git rev-list --count HEAD'),
    );
    expect(
      docs,
      contains('github.run_number` / `GITHUB_RUN_NUMBER'),
    );
    expect(
      docs,
      contains('single GitHub Release'),
    );
    expect(
      docs,
      isNot(contains(r'debug-<short-sha>')),
    );
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
