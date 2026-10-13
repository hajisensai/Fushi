import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：反馈「修复 → 发布」追踪的 CI 接线。
///
/// * `.github/workflows/feedback-link.yml` 只挂 push，处理外部可控的 commit message
///   与 PR 描述，又拿着 secret。钉死：不用 `pull_request_target`（取 main 上的定义、
///   有 secret 的上下文里处理外部 PR）、不内联 `${{ github.event.* }}` 进 run、
///   权限最小、只稀疏检出脚本。
/// * 两条发布 workflow 的回填步骤：挂在清单发布之后、`publish_manifest` 门控、
///   `continue-on-error`，且平台与产物对得上——回填失败绝不能让发布变红，回填错平台
///   会让反馈人看到「已在 x 版修复」却装不到。
void main() {
  final File link = File('../.github/workflows/feedback-link.yml');
  final File release = File('../.github/workflows/release.yml');
  final File desktop = File('../.github/workflows/release-desktop.yml');

  test('前置：三条 workflow 都在', () {
    for (final File f in <File>[link, release, desktop]) {
      expect(f.existsSync(), isTrue, reason: '缺 ${f.absolute.path}');
    }
  });

  group('feedback-link.yml', () {
    final String yaml = link.existsSync() ? link.readAsStringSync() : '';
    final List<String> codeLines = yaml
        .split('\n')
        .where((String l) => !l.trimLeft().startsWith('#'))
        .toList();
    final String code = codeLines.join('\n');

    test('触发：只有 push develop/main，不用 pull_request_target', () {
      expect(code, isNot(contains('pull_request_target')));
      expect(code, isNot(contains('pull_request:')));
      expect(code, contains('\n  push:'));
      expect(code, contains("branches: ['develop', 'main']"));
    });

    test('外部可控文本不经 \${{ }} 进 run（防注入）', () {
      expect(
        code,
        isNot(contains('github.event.pull_request.body')),
        reason: 'PR 描述只能经 \$GITHUB_EVENT_PATH 由脚本读取',
      );
      expect(code, isNot(contains('github.event.pull_request.title')));
      expect(
        code,
        isNot(contains('github.event.commits')),
        reason: 'commit message 只能经 \$GITHUB_EVENT_PATH 由脚本读取',
      );
      expect(code, isNot(contains('github.event.head_commit')));
      expect(code, isNot(contains('github.head_ref')));
      // run 里出现的 `${{ }}` 一个都不许有：外部字段只能经 env / 事件文件 / API 进脚本。
      final List<String> runLines = codeLines
          .where((String l) => l.trimLeft().startsWith('run:'))
          .toList();
      expect(runLines, isNotEmpty);
      for (final String l in runLines) {
        expect(l, isNot(contains(r'${{')), reason: l);
      }
      // env 里只许出现这三项表达式，不许出现任何 github.event.*。
      final List<String> exprs = RegExp(
        r'\$\{\{[^}]*\}\}',
      ).allMatches(code).map((RegExpMatch m) => m.group(0)!).toList();
      expect(exprs.toSet(), <String>{
        r'${{ github.token }}',
        r'${{ secrets.FEEDBACK_CI_TOKEN }}',
        r'${{ vars.FEEDBACK_API_BASE }}',
      });
    });

    test('checkout 不给 ref，只稀疏检出脚本，不留凭据', () {
      expect(
        code,
        isNot(contains('ref:')),
        reason: '只检出触发分支上的脚本，不给 checkout 指别的 ref',
      );
      expect(code, contains('sparse-checkout: tool/feedback_link.mjs'));
      expect(code, contains('sparse-checkout-cone-mode: false'));
      expect(code, contains('persist-credentials: false'));
      expect(code, contains('run: node tool/feedback_link.mjs'));
      expect(File('../tool/feedback_link.mjs').existsSync(), isTrue);
    });

    test('权限最小：contents: read + pull-requests: read', () {
      final RegExp perm = RegExp(
        r'^\s*([a-z-]+):\s*(read|write|none)\s*$',
        multiLine: true,
      );
      final List<String> grants = perm
          .allMatches(code)
          .map((RegExpMatch m) => '${m.group(1)}: ${m.group(2)}')
          .toList();
      expect(grants, <String>['contents: read', 'pull-requests: read']);
    });

    test('secret、接口根与 GITHUB_TOKEN 经 env 传入', () {
      expect(code, contains(r'GITHUB_TOKEN: ${{ github.token }}'));
      expect(
        code,
        contains(r'FEEDBACK_CI_TOKEN: ${{ secrets.FEEDBACK_CI_TOKEN }}'),
      );
      expect(
        code,
        contains(r'FEEDBACK_API_BASE: ${{ vars.FEEDBACK_API_BASE }}'),
      );
    });
  });

  /// 取出名为 [name] 的步骤正文（到下一个同级 `- ` 为止）。
  String step(String yaml, String name) {
    final List<String> lines = yaml.split('\n');
    final int start = lines.indexWhere(
      (String l) => l.trim() == '- name: $name',
    );
    expect(start, isNot(-1), reason: '找不到步骤「$name」');
    final int indent = lines[start].indexOf('-');
    final StringBuffer out = StringBuffer(lines[start]);
    for (int i = start + 1; i < lines.length; i++) {
      final String l = lines[i];
      if (l.trim().isNotEmpty && l.length - l.trimLeft().length <= indent) {
        break;
      }
      out.write('\n$l');
    }
    return out.toString();
  }

  void expectBackfill(String body, String platform) {
    expect(
      body,
      contains("if: steps.channel.outputs.publish_manifest == 'true'"),
    );
    expect(body, contains('continue-on-error: true'));
    expect(
      body,
      contains(r'FEEDBACK_CI_TOKEN: ${{ secrets.FEEDBACK_CI_TOKEN }}'),
    );
    expect(body, contains(r'FEEDBACK_API_BASE: ${{ vars.FEEDBACK_API_BASE }}'));
    expect(
      body,
      contains(r'CHANNEL: ${{ steps.channel.outputs.manifest_channel }}'),
    );
    expect(
      body,
      contains(r'VERSION: ${{ steps.channel.outputs.build_version_name }}'),
    );
    expect(body, contains(r'HEAD_SHA: ${{ github.sha }}'));
    expect(body, contains('PLATFORM: $platform'));
    expect(body, contains('bash tool/feedback_mark_released.sh'));
  }

  test('release.yml：Android 清单之后回填 android', () {
    final String yaml = release.readAsStringSync();
    final int manifest = yaml.indexOf(
      '- name: Publish mirror update manifest (Android assets)',
    );
    final int backfill = yaml.indexOf(
      '- name: Backfill feedback fix releases (Android)',
    );
    expect(manifest, isNot(-1));
    expect(backfill, greaterThan(manifest), reason: '回填必须排在清单发布之后');
    expectBackfill(
      step(yaml, 'Backfill feedback fix releases (Android)'),
      'android',
    );
  });

  test('release-desktop.yml：两个清单步骤之后按产物逐平台回填', () {
    final String yaml = desktop.readAsStringSync();
    final int apple = yaml.indexOf(
      '- name: Publish mirror update manifest (Apple assets)',
    );
    expect(apple, isNot(-1));
    const Map<String, List<String>> platforms = <String, List<String>>{
      'Windows': <String>['windows', 'fushi-*-windows-setup.exe'],
      'macOS': <String>['macos', 'fushi-*-macos-arm64.zip'],
      'iOS': <String>['ios', 'fushi-*-ios.ipa'],
    };
    for (final MapEntry<String, List<String>> e in platforms.entries) {
      final String name = 'Backfill feedback fix releases (${e.key})';
      expect(
        yaml.indexOf('- name: $name'),
        greaterThan(apple),
        reason: '$name 必须排在两个清单步骤之后',
      );
      final String body = step(yaml, name);
      expectBackfill(body, e.value[0]);
      expect(
        body,
        contains("compgen -G 'fushi/build/release-artifacts/${e.value[1]}'"),
        reason: '$name 必须按本次发布真实存在的产物判定平台',
      );
    }
    expect(
      step(yaml, 'Backfill feedback fix releases (macOS)'),
      contains('fushi-*-macos-arm64.dmg'),
    );
  });
}
