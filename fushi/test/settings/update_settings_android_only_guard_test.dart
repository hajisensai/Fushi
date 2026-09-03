import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-013 演进（全平台自动更新 Phase 1）：更新分区不再仅 Android。
/// 不变量：分区按 platformSupportsUpdateCheck()（恒真）可见；自动安装开关按
/// platformSupportsInAppInstall()（本期 Android+Windows）网关；数据侧 UpdateChecker
/// 不再硬门控 Android，而是按 updater.supportsUpdateCheck。
void main() {
  test('update section gated by capability helper, not Platform.isAndroid', () {
    final String src =
        File('lib/src/settings/settings_schema_system.dart').readAsStringSync();
    final String systemDest = _functionSource(
      src,
      'SettingsDestination buildSystemDestination() {',
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
    final String src = File('lib/src/utils/misc/update_checker_release.dart')
        .readAsStringSync();
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
      contains(r'RELEASE_SEQUENCE=$(bash tool/release_sequence.sh)'),
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
    // 2026-08-07 过渡期曾暂停 push 自动发布（当时守卫钉注释形态）；
    // 2026-08-13 用户指示恢复。守卫钉「恢复是有意的」：push 触发块处于激活形态，
    // 且分支范围不漂移（防止有人悄悄再停用或改动触发分支）。
    //
    // 2026-09-03 用户指示：**develop push 只保留 release.yml**（本仓唯一带 app 全量
    // 单测门的 workflow）。此前每次合并同时点燃三条长 workflow，runner 排队到互相
    // cancel，本 workflow 在 develop 上实测排队 30+ 分钟没跑上、且它一条 app 测试
    // 都不跑、只产发布物。于是 push 收到只剩 `['main']`。
    // **这不是「悄悄改窄」**——`release`（手动发 GitHub Release）与 `workflow_dispatch`
    // 两个触发器一个字没动，手动发测试版/正式版照常出桌面/Apple 产物。
    // 判据跟着改成新基线，继续钉「不漂移」，而不是把这条断言删掉。
    expect(workflow, contains('\n  push:\n'),
        reason: 'push 自动发布已恢复（2026-08-13 用户指示），触发块必须处于激活形态');

    // 按触发器切段再判：整文件 contains 分不清是哪个触发器的 branches，
    // push 改窄而 release/dispatch 被误删时它照样绿。
    final List<String> wLines = const LineSplitter().convert(workflow);
    final int pushAt = wLines.indexOf('  push:');
    expect(pushAt, greaterThan(-1), reason: 'push 触发器不见了');
    int pushEnd = wLines.length;
    for (int i = pushAt + 1; i < wLines.length; i++) {
      final String l = wLines[i];
      if (l.startsWith('  ') && !l.startsWith('   ') && l.trim().isNotEmpty) {
        pushEnd = i;
        break;
      }
    }
    final List<String> pushLines = wLines.sublist(pushAt, pushEnd);
    // 自校验：切出来的确实是 push 段，否则下面的断言在错窗口上恒真/恒假。
    expect(pushLines.any((String l) => l.trim() == 'paths:'), isTrue,
        reason: 'push 段切歪了（pushAt=$pushAt pushEnd=$pushEnd），判据已失效');
    // 判据钉在 branches **那一行本身**，不是整段：段里有解释性注释，
    // 对整段做 `isNot(contains('develop'))` 会被注释里的字面量触发（实测踩到）。
    final String branchesLine = pushLines
        .firstWhere((String l) => l.trim().startsWith('branches:'),
            orElse: () => '')
        .trim();
    expect(branchesLine, "branches: ['main']",
        reason: 'push 触发分支范围不得漂移（2026-09-03 起 main-only，'
            'develop push 只留 release.yml）');
    // 手动通道必须还在——这两条才是「桌面/Apple 产物随时发得出来」的保证。
    expect(workflow, contains('\n  workflow_dispatch:\n'),
        reason: '手动发布通道不得连带被删');
    expect(workflow, contains('\n  release:\n'),
        reason: '手动发 GitHub Release 的触发器不得连带被删');
    expect(workflow, isNot(contains(r'#   branches:')),
        reason: '不得残留注释形态的 push 块（避免双份 branches 清单漂开）');
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
      contains(r'RELEASE_SEQUENCE=$(bash tool/release_sequence.sh)'),
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
        r'fushi-${{ steps.channel.outputs.build_version_name }}-windows-setup.exe',
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
      contains('fushi/build/release-artifacts/fushi-*-windows-setup.exe'),
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
