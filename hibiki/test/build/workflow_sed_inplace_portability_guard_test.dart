import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1353 守卫：跑在 macOS runner 上的 workflow 作业不得使用裸 `sed -i`。
///
/// BSD/macOS 的 sed 与 GNU sed 在 `-i` 上语义不同：BSD 的 `-i` **必须**带备份
/// 后缀，写成 `sed -i "脚本" 文件` 时它会把紧跟的脚本吃成后缀、再把文件名当成
/// 脚本执行，于是固定报
/// `sed: 1: "hibiki/lib/src/media/vi ...": extra characters at the end of h command`
/// 并以 1 退出。develop 上的 `Build and Test` / `Build Desktop and Apple` 两个
/// workflow 的 macos + ios 作业就是这样在「Provide gitignored TMDB API key stub」
/// 步骤上固定红的（run 30708854995 / 30706194279）。
///
/// 唯一两边都接受的就地编辑写法是后缀紧贴的 `-i.bak`（再自行 rm 掉备份）。
/// 这条守卫只管 macOS 作业：ubuntu / windows-gitbash 上的 GNU sed 裸 `-i` 本身
/// 合法，没必要为了统一去churn 无关 workflow。
void main() {
  final Directory workflowsDir = Directory('../.github/workflows');

  /// 把一个 workflow 文件按顶层 `jobs:` 下的作业切成 (作业名, 作业正文) 列表。
  ///
  /// 作业头的形状是 2 空格缩进的 `  <id>:`；作业正文一直延伸到下一个作业头或
  /// 文件末尾。这里不引 YAML 解析器——本仓其余 workflow 守卫（例如
  /// `log_upload_workflow_injection_guard_test.dart`）都是纯文本扫描，保持一致。
  List<MapEntry<String, String>> splitJobs(String source) {
    final List<String> lines = source.split('\n');
    final int jobsAt = lines.indexWhere((String l) => l.trimRight() == 'jobs:');
    if (jobsAt < 0) return const <MapEntry<String, String>>[];

    final RegExp jobHeader = RegExp(r'^  ([A-Za-z0-9_-]+):\s*$');
    final List<MapEntry<String, String>> jobs = <MapEntry<String, String>>[];
    String? currentName;
    final StringBuffer body = StringBuffer();

    void flush() {
      if (currentName != null) {
        jobs.add(MapEntry<String, String>(currentName, body.toString()));
      }
      body.clear();
    }

    for (int i = jobsAt + 1; i < lines.length; i++) {
      final String line = lines[i];
      final RegExpMatch? header = jobHeader.firstMatch(line);
      if (header != null) {
        flush();
        currentName = header.group(1);
        continue;
      }
      // 顶层 key（零缩进非空行）代表 jobs: 段结束。
      if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) {
        flush();
        currentName = null;
        break;
      }
      body.writeln(line);
    }
    flush();
    return jobs;
  }

  /// 该作业是否可能落到 macOS runner 上。`runs-on` 写成 matrix 表达式时无法静态
  /// 判定，一律按「可能是 macOS」处理——守卫宁可严，不可漏。
  bool mayRunOnMacos(String jobBody) {
    final RegExp runsOn = RegExp(r'runs-on:\s*(.+)');
    for (final RegExpMatch m in runsOn.allMatches(jobBody)) {
      final String value = m.group(1)!.trim();
      if (value.contains(r'${{')) return true;
      if (value.toLowerCase().contains('macos')) return true;
    }
    return false;
  }

  /// 裸 `-i`：`sed` 后面（允许中间夹别的短选项）出现 `-i` 且其后紧跟空白或行尾。
  /// `-i.bak` / `-i''` 这类带后缀的写法不匹配。
  final RegExp bareInPlace = RegExp(r'\bsed\b[^\n|;&]*?\s-i(?=\s|$)');

  test('workflows 目录存在', () {
    expect(workflowsDir.existsSync(), isTrue,
        reason: 'expected ${workflowsDir.absolute.path}');
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

  for (final File workflow in workflows) {
    final String name = workflow.uri.pathSegments.last;
    test('$name: macOS 作业不得用裸 sed -i（BSD sed 会把文件名当脚本）', () {
      final String source = workflow.readAsStringSync();
      final List<String> offenders = <String>[];

      for (final MapEntry<String, String> job in splitJobs(source)) {
        if (!mayRunOnMacos(job.value)) continue;
        for (final String line in job.value.split('\n')) {
          // 注释行不算实际命令。
          if (line.trimLeft().startsWith('#')) continue;
          if (bareInPlace.hasMatch(line)) {
            offenders.add('${job.key}: ${line.trim()}');
          }
        }
      }

      expect(offenders, isEmpty,
          reason: '这些 macOS 作业里的裸 `sed -i` 在 BSD sed 下必然失败，'
              '改成后缀紧贴的 `sed -i.bak ...` 并随后 `rm -f <file>.bak`：\n'
              '${offenders.join('\n')}');
    });
  }

  test('TMDB key 注入步骤在所有 workflow 里都用可移植的 sed -i.bak', () {
    const String marker = "kBuiltinTmdbApiKey = '\$TMDB_API_KEY'";
    int injectionSites = 0;
    final List<String> offenders = <String>[];

    for (final File workflow in workflows) {
      for (final String line in workflow.readAsStringSync().split('\n')) {
        if (!line.contains(marker)) continue;
        if (line.trimLeft().startsWith('#')) continue;
        injectionSites++;
        if (!line.contains('sed -i.bak ')) {
          offenders.add('${workflow.uri.pathSegments.last}: ${line.trim()}');
        }
      }
    }

    expect(injectionSites, greaterThan(0),
        reason: 'TMDB key 注入步骤消失了？若注入方式改版请同步更新本守卫');
    expect(offenders, isEmpty,
        reason: 'TMDB key 注入必须用 GNU/BSD 通用的 `sed -i.bak`：\n'
            '${offenders.join('\n')}');
  });
}
