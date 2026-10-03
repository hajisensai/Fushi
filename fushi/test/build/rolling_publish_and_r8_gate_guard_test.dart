import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫两条 2026-09-30 的 CI 修正，松了都是静默的：
///
/// 1. rolling debug 发布的 `target_commitish` 必须是默认分支，不能是
///    `github.sha`。GitHub 拒绝用 GITHUB_TOKEN 更新「解析出的目标提交相对默认分支
///    改了 `.github/workflows/`」的 release（REST 文档 Update a release；token 拿
///    不到 workflows 权限）。develop 与 main 的 workflows 一分叉，rolling 发布就间歇
///    报 `Resource not accessible by integration`（27 次里失败 10 次，Android 包卡了
///    约 3 小时）。beta / 正式版仍用 `github.sha`。
/// 2. PR 上的 R8 / release APK 校验构建只在改到 Android / 原生 / 插件 / pubspec 时跑
///    （09-20..30 执行 48 次、失败 0 次，每次约 14 分钟）；判定步骤 diff 失败时
///    必须默认跑（fail safe），且五个相关步骤都挂在它上面。
void main() {
  group('rolling debug 发布的 target_commitish 用默认分支', () {
    for (final String name in <String>['release.yml', 'release-desktop.yml']) {
      test(name, () {
        final String yaml = File(
          '../.github/workflows/$name',
        ).readAsStringSync();
        expect(
          yaml,
          contains(
            "target_commitish: \${{ steps.channel.outputs.rolling_debug == 'true' "
            '&& github.event.repository.default_branch || github.sha }}',
          ),
        );
        expect(yaml, isNot(contains(r'target_commitish: ${{ github.sha }}')));
      });
    }
  });

  test('main.yml 的 R8 校验按改动路径门控，且算不出 diff 时默认跑', () {
    final String yaml = File(
      '../.github/workflows/main.yml',
    ).readAsStringSync();
    expect(
      yaml,
      contains(
        'name: Decide whether the Android release verify build is needed',
      ),
    );
    expect(yaml, contains('id: r8'));
    // fail safe：diff 失败 => needed=true。
    final int decide = yaml.indexOf('id: r8');
    final String body = yaml.substring(decide, decide + 1500);
    expect(
      body,
      contains(
        r'if ! changed="$(git diff --name-only "$BASE_SHA"...HEAD)"; then',
      ),
    );
    expect(body, contains('echo "needed=true"'));
    expect(
      body.indexOf('echo "needed=true"'),
      lessThan(body.indexOf('exit 0')),
    );
    for (final String dir in <String>[
      'fushi/android/',
      'native/',
      'third_party/',
      r'pubspec\.lock$',
    ]) {
      expect(body, contains(dir), reason: '触发路径缺 $dir');
    }
    // 五个 R8 相关步骤全部挂在判定上。
    expect(
      RegExp(
        r"if: github\.event_name == 'pull_request' && steps\.r8\.outputs\.needed == 'true' && env\.HAS_KEYSTORE [!=]= 'true'",
      ).allMatches(yaml).length,
      5,
    );
    expect(
      yaml,
      isNot(
        contains("if: github.event_name == 'pull_request' && env.HAS_KEYSTORE"),
      ),
    );
  });
}
