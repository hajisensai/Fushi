import 'dart:io';

import 'package:test/test.dart';

/// 守卫：`ci-config-gate.yml` 的 `guards` job 跑测试前先编好 fushi_web_core（硬依赖）。
///
/// 那个 job 按「文件里引用了 `.github/` / `../tool/`」**整文件**枚举测试，于是会收进
/// import `package:fushi`、pump 真页面的组件测试（例如 `test/reader/continuous_*_test.dart`
/// 里有一条断言 `tool/reader_pitch_headless/*.mjs` 探针存在，同文件另有构建设置 schema 的
/// 组件测试）。设置 schema 的「广告拦截」分区在顶层取 `AdblockCore.catalog()`，缺库就抛
/// `FushiWebCoreLibraryMissing`——2026-11-15 develop 上这个 job 因此连红（PR #3277
/// 把浏览器一级分类并进 `buildSettingsSchema()` 之后）。
///
/// 原生库是硬依赖、测试不 skip，所以修法是让 job 像 main.yml unit-tests 一样备好库。
void main() {
  // 测试 cwd 是 `fushi/`。
  final File workflow = File('../.github/workflows/ci-config-gate.yml');

  /// `guards:` job 的正文（到下一个两格缩进的 job 头或文件尾）。
  String guardsJob() {
    expect(workflow.existsSync(), isTrue, reason: workflow.absolute.path);
    final List<String> lines = workflow
        .readAsStringSync()
        .replaceAll('\r\n', '\n')
        .split('\n');
    final int start = lines.indexOf('  guards:');
    expect(start, isNot(-1), reason: 'ci-config-gate.yml 没有 guards job');
    final RegExp header = RegExp(r'^  [A-Za-z0-9_-]+:\s*$');
    final StringBuffer body = StringBuffer();
    for (int i = start + 1; i < lines.length; i++) {
      if (header.hasMatch(lines[i])) break;
      // 去掉整行注释，免得注释里提到 action 名就算数。
      if (lines[i].trimLeft().startsWith('#')) continue;
      body.writeln(lines[i]);
    }
    return body.toString();
  }

  test('guards job 在跑测试之前编好 fushi_web_core', () {
    final String job = guardsJob();
    final int build = job.indexOf(
      'uses: ./.github/actions/fushi-web-core-linux',
    );
    final int run = job.indexOf('flutter test --no-pub');
    expect(build, isNot(-1), reason: 'guards 缺 fushi-web-core-linux 步骤');
    expect(run, isNot(-1), reason: '找不到 guards 的测试命令，判据过期');
    expect(build, lessThan(run), reason: '库必须在测试之前编好');
  });

  test('guards 的测试步骤把 FUSHI_WEB_CORE_LIB 指向编好的 .so', () {
    expect(
      guardsJob(),
      contains(
        r'FUSHI_WEB_CORE_LIB: ${{ github.workspace }}/native/fushi_web_core/prebuilt/linux-x64/libfushi_web_core.so',
      ),
    );
  });
}
