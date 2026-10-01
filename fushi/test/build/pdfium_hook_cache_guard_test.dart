import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：pdfium_dart 的 native-assets 构建钩子下载 PDFium，CI 必须缓存它。
///
/// pdfrx -> pdfrx_engine -> pdfium_dart 的 `hook/build.dart` 在每次
/// `flutter test` / `flutter build`（Android / Windows / macOS / Linux，iOS 不）时，
/// 直接从 GitHub release 资源下载 `pdfium-<平台>-<架构>.tgz`，非 200 就抛
/// `Failed to download PDFium`。全新 runner 每次都下，于是 GitHub 下载一抖就整片红：
/// 2026-10-01 13:0x develop 最新提交的 Windows、macOS（run 36865627262）和 Android
/// （run 36865627415）三条发布构建同时死在 `Building native assets failed`。
/// 钩子在目标文件已存在时跳过下载，所以缓存
/// `.dart_tool/hooks_runner/shared/pdfium_dart/build/chromium_*` 就把网络从构建里拿掉了
/// （`.github/actions/pdfium-hook-cache`）。
///
/// 这条守卫钉住：凡是跑 app 的 Flutter 测试 / 非 iOS 构建的 job 都挂了这个缓存，且排在
/// 第一条测试 / 构建命令之前——新加的 job 漏挂会在这里红，而不是等 GitHub 下次抖动。
void main() {
  const String actionPath = '../.github/actions/pdfium-hook-cache/action.yml';
  const Set<String> purposes = <String>{'test', 'android', 'windows', 'macos'};

  /// 跑 app 的 Flutter 测试或非 iOS 构建（都会触发 pdfium_dart 的钩子）。
  /// `flutter` 后可以先跟全局选项（release.yml 是 `flutter --verbose build apk`）；
  /// 集成测试执行器底下是 `flutter drive`，同样要构建 app。
  final RegExp appFlutterRun = RegExp(
    r'flutter (?:-\S+ +)*(?:test\b|drive\b|'
    r'build (?:apk|appbundle|windows|macos|linux)\b)|'
    r'flutter_test_failures\.dart|comprehensive_test_runner\.dart',
  );

  String stripComments(String text) => text
      .split('\n')
      .where((String l) => !l.trimLeft().startsWith('#'))
      .join('\n');

  /// workflow 里每个 job 的源码（剥注释后）。
  Map<String, String> jobsOf(String workflow) {
    final List<String> lines = stripComments(workflow).split('\n');
    final int start = lines.indexWhere((String l) => l.startsWith('jobs:'));
    final Map<String, String> out = <String, String>{};
    if (start < 0) return out;
    final RegExp head = RegExp(r'^  ([A-Za-z0-9_-]+):\s*$');
    String? name;
    final StringBuffer body = StringBuffer();
    for (final String l in lines.skip(start + 1)) {
      final RegExpMatch? m = head.firstMatch(l);
      if (m != null) {
        if (name != null) out[name] = body.toString();
        name = m.group(1);
        body.clear();
      }
      body.writeln(l);
    }
    if (name != null) out[name] = body.toString();
    return out;
  }

  test('复合 action 缓存钩子的共享输出目录，key 带用途 / 系统 / 架构 / 版本', () {
    final String action = File(actionPath).readAsStringSync();
    expect(
      action,
      contains(
        'path: .dart_tool/hooks_runner/shared/pdfium_dart/build/chromium_*',
      ),
    );
    expect(action, contains('uses: actions/cache@'));
    for (final String part in <String>[
      r'${{ inputs.purpose }}',
      r'${{ runner.os }}',
      r'${{ runner.arch }}',
      r'${{ steps.version.outputs.pdfium_dart }}',
    ]) {
      expect(action, contains(part), reason: 'key 缺 $part');
    }
    // 版本取自 pubspec.lock 里的 pdfium_dart：下载的 release 按它钉死。
    expect(action, contains('/^  pdfium_dart:\$/'));
  });

  test('每个跑 app Flutter 测试 / 非 iOS 构建的 job 都先挂 PDFium 缓存', () {
    final List<File> workflows = Directory('../.github/workflows')
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.yml'))
        .toList();
    expect(workflows, isNotEmpty);

    final List<String> covered = <String>[];
    final List<String> offenders = <String>[];
    for (final File wf in workflows) {
      final String file = wf.uri.pathSegments.last;
      jobsOf(wf.readAsStringSync()).forEach((String job, String body) {
        final RegExpMatch? run = appFlutterRun.firstMatch(body);
        if (run == null) return;
        final int cache = body.indexOf(
          'uses: ./.github/actions/pdfium-hook-cache',
        );
        final int checkout = body.indexOf('uses: actions/checkout@');
        if (cache < 0) {
          offenders.add('$file :: $job 跑 `${run.group(0)}` 却没挂 PDFium 缓存');
        } else if (cache > run.start) {
          offenders.add('$file :: $job 的 PDFium 缓存排在 `${run.group(0)}` 之后');
        } else if (checkout < 0 || checkout > cache) {
          offenders.add('$file :: $job 的 PDFium 缓存（本地 action）排在 checkout 之前');
        } else {
          final RegExpMatch? p = RegExp(
            r'purpose: (\S+)',
          ).firstMatch(body.substring(cache));
          if (p == null || !purposes.contains(p.group(1))) {
            offenders.add('$file :: $job 的 purpose 不在 $purposes 里');
          } else {
            covered.add('$file :: $job');
          }
        }
      });
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
    // 判据自校验：扫描面没塌（2026-10-01 共 11 个 job）。
    expect(
      covered.length,
      greaterThanOrEqualTo(10),
      reason: covered.join('\n'),
    );
  });
}
