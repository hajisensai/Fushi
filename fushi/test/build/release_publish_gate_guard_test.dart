// 正式版云端预构建 + 审批发布门（2026-10-17 用户要求：正式版必须提前在云端构建好，
// 说「发版」时秒发、不重新构建）。
//
// 结构：两条发布 workflow 都拆成「构建 job（只构建 / 签名 / 上传 run artifact）」+
// 「发布 job（所有对外动作）」。发布 job 挂环境：workflow_dispatch 的 formal / beta 走
// `release-publish`（必需审批人 hajisensai），其余（push 滚动 debug、`release` 事件、
// testflight_only 补传）走无保护规则的 `release-auto`。
//
// 这条边界失效是静默的：把一个上传步骤塞回构建 job，CI 照样全绿，只是下次正式版
// dispatch 不再等审批就直接发出去了。所以这里钉三件事：
//   1. 对外动作（GitHub Release、更新清单、反馈回填、main 同步、TestFlight、打 tag）
//      只能出现在挂了审批门的 job 里；
//   2. 发布 job 的环境表达式逐字相同（两条 workflow 同 tag 都停在门口，批两次 = 一次完整发版）；
//   3. 发布 job 取包的 artifact 保留期盖住 30 天审批窗口。
// 流程文档：docs/agent/build.md「正式版预构建与审批发布」。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _gate =
    "github.event_name == 'workflow_dispatch' && "
    "(github.event.inputs.channel == 'formal' || "
    "github.event.inputs.channel == 'beta')";

const String _environmentLine =
    "    environment: \${{ ($_gate) && 'release-publish' || 'release-auto' }}";

/// 对外动作的特征串：出现在哪个 job，哪个 job 就必须挂审批门。
final Map<String, RegExp> _outwardActions = <String, RegExp>{
  'GitHub Release 上传 / 创建': RegExp(r'softprops/action-gh-release'),
  'gh release 改写': RegExp(
    r'\bgh release (delete|delete-asset|create|upload|edit)\b',
  ),
  '更新清单': RegExp(r'publish_update_manifest\.sh'),
  '反馈回填': RegExp(r'feedback_mark_released\.sh'),
  'git push': RegExp(r'\bgit\b[^\n]*\bpush\b'),
  'git tag': RegExp(r'\bgit\b[^\n]*\btag\b\s+(-a\s+)?v'),
  'TestFlight 上传': RegExp(r'altool --upload-app'),
};

Directory _workflowsDir() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    final Directory candidate = Directory('${dir.path}/.github/workflows');
    if (candidate.existsSync()) return candidate;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到 .github/workflows（从 ${Directory.current.path} 向上）');
}

/// job 名 → job 文本（从 `  <job>:` 到下一个 job 头）。注释行剥掉，避免注释里提到
/// 的命令被当成动作。
Map<String, String> _jobs(String yaml) {
  final List<String> lines = yaml.replaceAll('\r\n', '\n').split('\n');
  final int jobsAt = lines.indexOf('jobs:');
  if (jobsAt == -1) throw StateError('找不到 jobs:');
  final RegExp header = RegExp(r'^  ([A-Za-z0-9_-]+):\s*$');
  final Map<String, StringBuffer> out = <String, StringBuffer>{};
  String? job;
  for (int i = jobsAt + 1; i < lines.length; i++) {
    final String line = lines[i];
    final RegExpMatch? m = header.firstMatch(line);
    if (m != null) {
      job = m.group(1);
      out[job!] = StringBuffer();
      continue;
    }
    if (job == null || line.trimLeft().startsWith('#')) continue;
    out[job]!.writeln(line);
  }
  return <String, String>{
    for (final MapEntry<String, StringBuffer> e in out.entries)
      e.key: e.value.toString(),
  };
}

bool _gated(String jobBody) => jobBody.split('\n').contains(_environmentLine);

String? _needs(String jobBody) =>
    RegExp(r'^    needs: (.+)$', multiLine: true).firstMatch(jobBody)?.group(1);

void main() {
  final Directory dir = _workflowsDir();
  final Map<String, Map<String, String>> workflows =
      <String, Map<String, String>>{
        for (final String name in <String>[
          'release.yml',
          'release-desktop.yml',
        ])
          name: _jobs(File('${dir.path}/$name').readAsStringSync()),
      };

  // 每条 workflow：哪些 job 是发布 job（必须挂门）、哪些是构建 job（绝不外发）、
  // 发布 job 必须等哪些构建 job。
  const Map<String, Map<String, String>> publishJobs =
      <String, Map<String, String>>{
        'release.yml': <String, String>{'publish-android': 'build'},
        'release-desktop.yml': <String, String>{
          'publish': '[windows, macos, ios]',
          'testflight': 'ios',
        },
      };
  const Map<String, List<String>> buildJobs = <String, List<String>>{
    'release.yml': <String>['build', 'tests'],
    'release-desktop.yml': <String>['windows', 'macos', 'ios'],
  };

  test('判据自校验：环境行与动作特征串能命中真实写法', () {
    expect(_gated('    runs-on: x\n$_environmentLine\n'), isTrue);
    expect(_gated('    environment: release-publish\n'), isFalse);
    expect(
      _outwardActions['git push']!.hasMatch(
        'git -C "\$WORK" push -q origin HEAD:refs/heads/main',
      ),
      isTrue,
    );
    expect(
      _outwardActions['gh release 改写']!.hasMatch(
        'gh release delete-asset "\$PUBLISH_TAG" "\$asset"',
      ),
      isTrue,
    );
    expect(
      _outwardActions['gh release 改写']!.hasMatch('gh release view "\$TAG"'),
      isFalse,
    );
  });

  for (final String wf in publishJobs.keys) {
    group(wf, () {
      final Map<String, String> jobs = workflows[wf]!;

      test('发布 job 存在、挂审批门、等齐构建 job', () {
        for (final MapEntry<String, String> e in publishJobs[wf]!.entries) {
          final String? body = jobs[e.key];
          expect(body, isNotNull, reason: '缺发布 job「${e.key}」');
          expect(
            _gated(body!),
            isTrue,
            reason: '发布 job「${e.key}」必须逐字带 $_environmentLine',
          );
          expect(
            _needs(body),
            e.value,
            reason: '发布 job「${e.key}」必须在构建全部完成后才进门（needs: ${e.value}）',
          );
        }
      });

      test('构建 job 不挂环境（不能让构建本身等审批，那就不是预构建了）', () {
        for (final String job in buildJobs[wf]!) {
          final String? body = jobs[job];
          expect(body, isNotNull, reason: '缺构建 job「$job」');
          expect(
            RegExp(r'^    environment:', multiLine: true).hasMatch(body!),
            isFalse,
            reason: '构建 job「$job」不得挂 environment',
          );
        }
      });

      test('对外动作只出现在挂了审批门的 job 里', () {
        final List<String> leaks = <String>[];
        int seen = 0;
        for (final MapEntry<String, String> job in jobs.entries) {
          for (final MapEntry<String, RegExp> action
              in _outwardActions.entries) {
            if (!action.value.hasMatch(job.value)) continue;
            seen++;
            if (!_gated(job.value)) leaks.add('${job.key}: ${action.key}');
          }
        }
        expect(leaks, isEmpty, reason: '这些对外动作绕过了审批门：$leaks');
        // 规模哨兵：动作特征串一个都没命中 = 判据失效，不是「全都合规」。
        expect(seen, greaterThanOrEqualTo(3), reason: '对外动作一个都没找到，特征串过期了');
      });

      test('只有发布 job 挂环境，且只用这两个具名环境', () {
        for (final MapEntry<String, String> job in jobs.entries) {
          final bool hasEnv = RegExp(
            r'^    environment:',
            multiLine: true,
          ).hasMatch(job.value);
          expect(
            hasEnv,
            publishJobs[wf]!.containsKey(job.key),
            reason: 'job「${job.key}」的 environment 与发布 job 清单不符',
          );
        }
      });
    });
  }

  test('发布 job 取包的 artifact 保留期盖住 30 天审批窗口', () {
    final String release = File('${dir.path}/release.yml').readAsStringSync();
    final String desktop = File(
      '${dir.path}/release-desktop.yml',
    ).readAsStringSync();
    const String gated30 = 'retention-days: \${{ ($_gate) && 30 || ';
    // Android：build → publish 的 APK artifact。
    expect(
      RegExp(
        r'- name: Upload APK artifacts to workflow run\n(?:.*\n){1,12}?\s+'
        '${RegExp.escape(gated30)}14 }}',
      ).hasMatch(release),
      isTrue,
      reason: 'Android APK artifact 在审批 run 下保留期必须 ≥ 30 天',
    );
    // 桌面：三个平台的 Release 资产 + 签名 TestFlight IPA。
    for (final String step in <String>[
      'Upload Windows installer artifact',
      'Upload macOS app artifact',
      'Upload iOS IPA artifact',
      'Upload signed TestFlight IPA artifact',
    ]) {
      expect(
        RegExp(
          '- name: ${RegExp.escape(step)}\\n(?:.*\\n){1,14}?\\s+'
          '${RegExp.escape(gated30)}\\d+ }}',
        ).hasMatch(desktop),
        isTrue,
        reason: '「$step」在审批 run 下保留期必须 ≥ 30 天',
      );
    }
  });

  test('Android 通道结果经 artifact 交给 publish-android，job outputs 只留开关', () {
    final Map<String, String> jobs = workflows['release.yml']!;
    final String build = jobs['build']!;
    final String publish = jobs['publish-android']!;
    final Set<String> used = RegExp(
      r'steps\.channel\.outputs\.([a-z_]+)',
    ).allMatches(publish).map((RegExpMatch m) => m.group(1)!).toSet();
    expect(used, containsAll(<String>['tag', 'publish_tag', 'files', 'body']));

    // GitHub 静默丢弃「可能含 secret 值」的 job output（2026-10-17 publish_tag / files
    // 被丢，publish 拿空 tag 去 prune）。带用户数据的值一律不许再走 job outputs。
    final RegExp outputLine = RegExp(
      r'^      ([a-z_]+): \$\{\{ steps\.channel\.outputs\.',
      multiLine: true,
    );
    final int outputsAt = build.indexOf('\n    outputs:\n');
    expect(outputsAt, isNonNegative, reason: 'build job 缺 outputs 块');
    final String outputsBlock = build.substring(
      outputsAt,
      build.indexOf('\n    steps:', outputsAt),
    );
    final Set<String> exported = outputLine
        .allMatches(outputsBlock)
        .map((RegExpMatch m) => m.group(1)!)
        .toSet();
    expect(exported, <String>{
      'channel',
      'publish_managed_release',
      'publish_manifest',
    }, reason: 'build job outputs 只许留 publish-android 的 job 级 if 要用的开关');
    expect(publish, isNot(contains('needs.build.outputs.publish_tag')));

    final String save = build.substring(
      build.indexOf('- name: Save Android release channel for publish job'),
    );
    final String load = publish.substring(
      publish.indexOf('- name: Load Android release channel from build job'),
    );
    for (final String key in used) {
      expect(
        save.contains(
          'CH_${key.toUpperCase()}: \${{ steps.channel.outputs.$key }}',
        ),
        isTrue,
        reason:
            'publish 读 steps.channel.outputs.$key，build 的 Save 步骤必须把它写进 artifact',
      );
      expect(
        RegExp('for key in [^\\n]*\\b$key\\b').hasMatch(load),
        isTrue,
        reason: 'publish 的 Load 步骤必须从 artifact 还原 $key',
      );
    }
    expect(build, contains('name: fushi-release-channel-\${{ github.sha }}'));
    expect(publish, contains('name: fushi-release-channel-\${{ github.sha }}'));
    expect(
      load,
      contains('refusing to publish'),
      reason: '空 tag 必须在 Load 步骤就拒绝，不能让 prune / 上传落到 Latest release',
    );
  });
}
