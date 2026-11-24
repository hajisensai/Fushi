import 'dart:io';

import 'package:test/test.dart';

/// 守卫：`flutter analyze` 之前先编出 Flutter GPU 着色器包。
///
/// 镜台的着色器包 `build/shaderbundles/*.shaderbundle` 是 hook/build.dart 经
/// flutter_gpu_shaders 调引擎自带 impellerc 编出的产物（与引擎版本绑定，不入库），
/// 而 pubspec.yaml 的 flutter.assets 登记了它。`flutter run|build|test` 会先跑构建钩子，
/// `flutter analyze` 不跑：干净检出（CI、新 worktree、dist worker）上分析器就报
/// `asset_does_not_exist`（2026-11-23 develop 的 analyze 因此变红）。
/// 这里钉死：每条在 fushi/ 跑 `flutter analyze` 的 CI job、本地重活入口 heavy.dart、
/// dist worker 的 analyze 都先跑 `fushi/tool/gen_shader_bundles.dart`，
/// 而它跑的就是 hook/build.dart 本身（产物路径与 impellerc 参数只此一处）。
void main() {
  const String genScript = 'tool/gen_shader_bundles.dart';
  const String genAction = 'uses: ./.github/actions/gen-shader-bundles';

  String stripComments(String text) => text
      .split('\n')
      .where((String l) => !l.trimLeft().startsWith('#'))
      .join('\n');

  String read(String repoPath) =>
      File('../$repoPath').readAsStringSync().replaceAll('\r\n', '\n');

  test('pubspec 登记的每个 shaderbundle 都由 hook/build.dart 的清单编出', () {
    final String pubspec = stripComments(read('fushi/pubspec.yaml'));
    final List<String> assets = RegExp(
      r'^\s*-\s*(build/shaderbundles/[\w.-]+\.shaderbundle)\s*$',
      multiLine: true,
    ).allMatches(pubspec).map((RegExpMatch m) => m.group(1)!).toList();
    expect(assets, isNotEmpty, reason: 'pubspec 里没有登记 shaderbundle 资源了？');
    final String hook = read('fushi/hook/build.dart');
    for (final String asset in assets) {
      final String name = asset.split('/').last;
      expect(
        hook,
        contains("manifestFileName: 'shaders/$name.json'"),
        reason: '$asset 没有对应的 shaders/$name.json 清单交给 buildShaderBundleJson',
      );
      expect(
        File('shaders/$name.json').existsSync(),
        isTrue,
        reason: '清单 fushi/shaders/$name.json 不存在',
      );
    }
  });

  test('生成入口跑的是 hook/build.dart 本身', () {
    final String gen = stripComments(read('fushi/$genScript'));
    expect(gen, contains("import '../hook/build.dart' as hook;"));
    expect(gen, contains('mainMethod: hook.main'));
    final String action = stripComments(
      read('.github/actions/gen-shader-bundles/action.yml'),
    );
    expect(action, contains('fushi/$genScript'));
  });

  test('本地 heavy.dart 与 dist worker 的 analyze 先生成', () {
    final String heavy = read('fushi/tool/heavy.dart');
    expect(heavy, contains('heavyCommandAnalyzesApp('));
    expect(heavy, contains("'\$checkout/fushi/$genScript'"));
    final String worker = stripComments(
      read('fushi/tool/dist_test/worker_analyze.sh'),
    );
    final int gen = worker.indexOf(genScript);
    final int analyze = worker.indexOf('flutter analyze --no-pub');
    expect(gen, greaterThanOrEqualTo(0), reason: 'worker_analyze.sh 没有生成');
    expect(analyze, greaterThan(gen), reason: '生成必须在 flutter analyze 之前');
  });

  test('每个在 fushi/ 跑 flutter analyze 的 workflow job 都先调 gen-shader-bundles', () {
    final List<File> workflows =
        Directory('../.github/workflows')
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.yml'))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));
    final List<String> covered = <String>[];
    final List<String> problems = <String>[];
    final RegExp jobHeader = RegExp(r'^  ([\w-]+):\s*$');
    final RegExp analyze = RegExp(r'(^|[\s;&|(])flutter\s+analyze\b');
    for (final File wf in workflows) {
      final String name = wf.uri.pathSegments.last;
      final List<String> lines = stripComments(
        wf.readAsStringSync().replaceAll('\r\n', '\n'),
      ).split('\n');
      final int jobsAt = lines.indexOf('jobs:');
      if (jobsAt < 0) continue;
      String? job;
      int? genLine;
      for (int i = jobsAt + 1; i < lines.length; i++) {
        final String line = lines[i];
        final RegExpMatch? h = jobHeader.firstMatch(line);
        if (h != null) {
          job = h.group(1);
          genLine = null;
          continue;
        }
        if (job == null) continue;
        if (line.contains(genAction)) genLine = i;
        // 只认真正执行的 run 行：跳过 echo / 文字里提到的 flutter analyze。
        final String code = line.trim();
        if (code.startsWith('echo') || code.startsWith('printf')) continue;
        if (!analyze.hasMatch(code)) continue;
        covered.add('$name: $job');
        if (genLine == null) {
          problems.add(
            '$name: $job 跑 flutter analyze 之前没有 $genAction'
            '（pubspec 资源 build/shaderbundles/*.shaderbundle 不存在 → asset_does_not_exist）',
          );
        }
      }
    }
    expect(covered, isNotEmpty, reason: '一个 flutter analyze 的 job 都没找到，解析器失效了');
    expect(problems, isEmpty);
  });
}
