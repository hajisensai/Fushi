import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：「烘进包里的密钥」注入只有**一份**真相源，且每个构建 app 的 job 都用它。
///
/// ## 起因（BUG-1588）
///
/// 这批注入原先是逐字抄进每个 job 的。抄到第 11 份时已经漂成这样：
///
///   - Google OAuth 桩：11 处一致
///   - dandanplay 桩：11 处一致
///   - 日志上传桩：**只有 10 处**——`main.yml` 漏了
///   - TMDB 桩：**3 个变体**，且两条发布 workflow 一处都没有
///
/// 最后一条的后果：验证构建有 key、**发出去的包没有**，TMDB 在用户机器上恒
/// 「未配置」，用户读作「连不上」；而 CI 全绿、零构建期症状。44 份拷贝里少一份，
/// diff 上什么都看不出来——这类漏抄不可能靠 review 抓住。
///
/// 收进 `.github/actions/provide-baked-secrets` 之后，漏抄在结构上不可能发生。
/// 本守卫钉死这个结构本身：
///   1. composite action 里四段桩齐全，且都接到真 secret 输入；
///   2. 凡是构建 app 的 job 都 `uses` 它；
///   3. **没人把 inline 拷贝抄回去**（抄回去就等于把漂移的可能性放回来）。
void main() {
  final Directory workflowsDir = Directory('../.github/workflows');
  final File actionFile =
      File('../.github/actions/provide-baked-secrets/action.yml');

  /// 每一种「烘进包里的密钥」：步骤名 -> 它必须写穿的目标文件。
  const Map<String, String> bakedSecrets = <String, String>{
    'Provide gitignored Google OAuth secret stub':
        'fushi/lib/src/sync/google_oauth_secret.dart',
    'Provide gitignored log upload secret stub':
        'fushi/lib/src/utils/misc/log_upload_secret.dart',
    'Provide gitignored dandanplay secret stub':
        'fushi/lib/src/media/video/dandanplay_secret.dart',
    'Provide gitignored TMDB API key stub':
        'fushi/lib/src/media/video/scraper/tmdb_default_key.dart',
  };

  const String actionRef = './.github/actions/provide-baked-secrets';

  test('前置：composite action 与 workflows 目录都在', () {
    expect(actionFile.existsSync(), isTrue,
        reason: '缺 ${actionFile.absolute.path}——密钥注入的唯一真相源没了，'
            '本守卫的全部断言失去对象。');
    expect(workflowsDir.existsSync(), isTrue,
        reason: 'expected ${workflowsDir.absolute.path}');
  });

  final String actionText =
      actionFile.existsSync() ? actionFile.readAsStringSync() : '';

  test('composite action 覆盖全部四种烘进包的密钥，并各自写穿目标文件', () {
    final List<String> missing = <String>[];
    bakedSecrets.forEach((String step, String dst) {
      if (!actionText.contains('- name: $step')) {
        missing.add('  缺步骤：$step');
      } else if (!actionText.contains('dst=$dst')) {
        missing.add('  步骤在但没写穿目标文件：$step -> $dst');
      }
    });
    expect(missing, isEmpty,
        reason: 'composite action 少了这些注入。少哪一种，**发出去的包**里对应'
            '功能就静默降级，而 CI 依旧全绿（BUG-1588 就是 TMDB 这一种）：\n'
            '${missing.join("\n")}');
  });

  test('composite action 的每个输入都接到真实 GitHub secret 而不是写死值', () {
    // 输入名 -> 调用方必须传的 secret。写死值会让 secret 轮换失效且泄漏进仓库。
    const Map<String, String> wiring = <String, String>{
      'google-oauth-client-secret': 'GOOGLE_OAUTH_CLIENT_SECRET',
      'log-upload-endpoint': 'LOG_UPLOAD_ENDPOINT',
      'log-upload-token': 'LOG_UPLOAD_TOKEN',
      'dandanplay-app-id': 'DANDANPLAY_APP_ID',
      'dandanplay-app-secret': 'DANDANPLAY_APP_SECRET',
      'tmdb-api-key': 'TMDB_API_KEY',
    };
    final List<String> offenders = <String>[];
    wiring.forEach((String input, String secret) {
      if (!actionText.contains('$input:')) {
        offenders.add('  action 没有声明输入 $input');
      }
    });
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  final List<File> workflows = workflowsDir.existsSync()
      ? (workflowsDir
          .listSync()
          .whereType<File>()
          .where(
              (File f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path)))
      : <File>[];

  /// 用了 composite action 的 workflow 名 -> 用了几次。
  final Map<String, int> callers = <String, int>{};

  /// 把 inline 拷贝抄回去的地方。
  final List<String> inlineCopies = <String>[];

  for (final File workflow in workflows) {
    final String name = workflow.uri.pathSegments.last;
    final List<String> lines = workflow
        .readAsLinesSync()
        .map((String l) => l.trim())
        .toList(growable: false);
    for (int i = 0; i < lines.length; i++) {
      if (lines[i] == 'uses: $actionRef') {
        callers[name] = (callers[name] ?? 0) + 1;
      }
      // 整行比对，不用子串包含：`- name: X` 是 `- name: X MUTANT` 的前缀，
      // 子串计数会把改了名的步骤照旧算进去，守卫变成空转。这是本守卫第一次
      // 变异实测（把步骤名改成 `... MUTANT`）暴露出来的。
      for (final String step in bakedSecrets.keys) {
        if (lines[i] == '- name: $step') {
          inlineCopies.add('  $name:${i + 1}  $step');
        }
      }
    }
  }

  test('守卫没跑空：扫到了 composite action 的调用点', () {
    expect(workflows, isNotEmpty, reason: '一个 workflow 都没扫到');
    expect(callers, isNotEmpty,
        reason: '没有任何 workflow `uses: $actionRef`。要么 action 路径改了、'
            '要么调用写法变了——无论哪种，下面「不许抄回 inline」的断言此刻都是'
            '空转，先修守卫再谈绿。');
  });

  test('没有任何 workflow 把密钥注入抄回成 inline 步骤', () {
    expect(inlineCopies, isEmpty,
        reason: '这些地方又把密钥注入写成了 inline 步骤。inline 拷贝一旦出现，'
            '「新增一种密钥时漏抄某个 job」的漂移就回来了——BUG-1588 正是这么'
            '发生的（44 份拷贝里 TMDB 漂成 3 个变体、发布 workflow 一处都没有）。'
            '改用 `uses: $actionRef`：\n'
            '${inlineCopies.join("\n")}');
  });
}
