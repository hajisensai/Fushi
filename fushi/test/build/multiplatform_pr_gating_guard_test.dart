import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫（2026-09-30）：build-multiplatform.yml 的 PR 路径门。
///
/// 所有者拍板两件事：① 不再在 CI 构建 Linux **app**，Linux 只剩无头服务端随包原生库的
/// `linux-server` job；② PR 上的平台 job 只在改到该平台的原生 / 打包输入时才跑
/// （upstream 09-20..09-30 的 232 条 PR 里，153 条只改 Dart / 文档的 PR 吃掉平台 job
/// 约 62% 的分钟数、零真拦截；3 次真拦截全在改原生代码的 PR 上）。
///
/// 路径门的失效全是静默的：
/// * job 多读了一个目录，却没进它的路由正则——改那个目录的 PR 从此不编这个平台，全绿；
/// * workflow 级 `paths:` 把某条路由的输入挡在外面（例：`!packages/fushi_server/**`
///   会让只改服务端的 PR 连 changes job 都走不到）；
/// * 有人把 `needs: changes` / `if:` 从某个平台 job 上删掉，或让 push / dispatch 也吃路径门。
///
/// 所以这里：按行解析 workflow（同 native_store_names_single_source_guard_test，不引入
/// package:yaml），从 changes job 的脚本里取出**真正生效的**正则与路由，用 Dart RegExp
/// 回放（这几条正则只用 `^ $ | () [^/] \.`，ERE 与 Dart 语义一致），再对账每个平台
/// job 正文调用到的仓库路径与它 restore 的持久库件的输入目录（names.sh）。
void main() {
  final File workflowFile = File(
    '../.github/workflows/build-multiplatform.yml',
  );
  final File namesScript = File(
    '../.github/actions/native-store-names/names.sh',
  );
  final String workflow = workflowFile.existsSync()
      ? workflowFile.readAsStringSync().replaceAll('\r\n', '\n')
      : '';
  final Map<String, String> jobs = _parseJobs(workflow);
  final String changesJob = jobs['changes'] ?? '';
  final Map<String, String> regexSources = _regexDefinitions(changesJob);
  final Map<String, List<String>> routeVars = _routeDefinitions(changesJob);
  final Map<String, RegExp> routes = <String, RegExp>{
    for (final MapEntry<String, List<String>> r in routeVars.entries)
      r.key: RegExp(
        r.value.map((String v) => regexSources[v] ?? '(?!)').join('|'),
      ),
  };

  /// 路由输出名 -> 被它门控的 job。
  const Map<String, String> gatedJobs = <String, String>{
    'windows': 'windows',
    'macos': 'macos',
    'ios': 'ios',
    'server': 'linux-server',
  };

  Set<String> routed(String path) => <String>{
    for (final MapEntry<String, RegExp> r in routes.entries)
      if (r.value.hasMatch(path)) r.key,
  };

  test('前置：解析到 changes job、六组正则与四条路由（守卫没跑空）', () {
    expect(workflow, isNotEmpty, reason: workflowFile.absolute.path);
    expect(
      changesJob,
      isNotEmpty,
      reason: 'build-multiplatform.yml 没有 changes job',
    );
    expect(
      regexSources.keys.toSet(),
      containsAll(<String>[
        'app_common',
        'smoke',
        'windows_only',
        'macos_only',
        'ios_only',
        'server_only',
      ]),
    );
    expect(routeVars.keys.toSet(), gatedJobs.keys.toSet());
    for (final MapEntry<String, List<String>> r in routeVars.entries) {
      for (final String v in r.value) {
        expect(
          regexSources.containsKey(v),
          isTrue,
          reason: 'route ${r.key} 引用了未定义的正则变量 $v',
        );
      }
    }
  });

  test('PR 上每个平台 job 都挂在 changes job 的对应输出上', () {
    for (final MapEntry<String, String> g in gatedJobs.entries) {
      final String? body = jobs[g.value];
      expect(body, isNotNull, reason: '找不到 job ${g.value}');
      final List<String> header = _jobLevelLines(body!);
      expect(
        header,
        contains('    needs: changes'),
        reason: '${g.value} 没挂 needs: changes',
      );
      expect(
        header,
        contains("    if: needs.changes.outputs.${g.key} == 'true'"),
        reason:
            '${g.value} 的 if 必须恰好是 changes 的 ${g.key} 输出'
            '（别加 always() / 别换成别的输出）',
      );
    }
    // changes job 必须声明这四个输出。
    for (final String key in gatedJobs.keys) {
      expect(
        changesJob,
        contains('      $key: \${{ steps.classify.outputs.$key }}'),
      );
    }
  });

  test('push / workflow_dispatch 整轮全开；PR 按 merge commit 取改动；schedule 只派发', () {
    final String prArm = _caseArm(changesJob, 'pull_request');
    final String scheduleArm = _caseArm(changesJob, 'schedule');
    final String defaultArm = _caseArm(changesJob, '*');
    expect(
      prArm,
      contains('git diff --name-only --no-renames HEAD^1 HEAD'),
      reason: 'PR 的改动清单 = merge commit 对它的第一个父提交（与平台 job 构建同一提交）',
    );
    expect(prArm, isNot(contains('all=true')));
    expect(scheduleArm, isNot(contains('all=true')));
    expect(
      defaultArm,
      contains('all=true'),
      reason: 'push（main）与手动 dispatch 必须整轮全开，行为与加路径门之前一致',
    );
    expect(changesJob, contains('fetch-depth: 2'));
    expect(
      changesJob,
      contains(r'''if [ "$all" = true ] || grep -Eq "$re" "$files"; then'''),
    );

    final String nightly = jobs['nightly-develop'] ?? '';
    expect(nightly, contains("if: github.event_name == 'schedule'"));
    expect(nightly, contains('actions: write'));
    expect(
      nightly,
      contains('gh workflow run build-multiplatform.yml'),
      reason: '定时 run 只能在 main 上跑，必须派发到 develop 而不是就地构建',
    );
    expect(nightly, contains('--ref develop'));
    final String on = workflow.substring(0, workflow.indexOf('\njobs:'));
    expect(on, contains('  schedule:'));
    expect(on, contains('      nightly:'));

    // Android appSmoke 仍只在人手动 dispatch 时跑，夜间整轮与 PR 都不带它。
    final List<String> androidHeader = _jobLevelLines(jobs['android'] ?? '');
    expect(
      androidHeader,
      contains(
        "    if: github.event_name == 'workflow_dispatch' && !inputs.nightly",
      ),
    );
  });

  test('路由回放：样例路径开对了 job', () {
    const Set<String> all = <String>{'windows', 'macos', 'ios', 'server'};
    const Set<String> apps = <String>{'windows', 'macos', 'ios'};
    final Map<String, Set<String>> cases = <String, Set<String>>{
      // 只改 Dart / 文档 / 版本号：一个平台 job 都不开（数据里零真拦截的那一类）。
      'fushi/lib/main.dart': <String>{},
      'fushi/lib/src/pages/implementations/reader_fushi_page.dart': <String>{},
      'fushi/test/build/some_guard_test.dart': <String>{},
      'fushi/integration_test/some_feature_itest.dart': <String>{},
      'fushi/pubspec.yaml': <String>{},
      'fushi/linux/CMakeLists.txt': <String>{},
      'docs/agent/build.md': <String>{},
      // 平台目录。
      'fushi/windows/runner/flutter_window.cpp': <String>{'windows'},
      'fushi/macos/Runner/AppDelegate.swift': <String>{'macos'},
      'fushi/ios/Runner/AppDelegate.swift': <String>{'ios'},
      'fushi/apple/FushiSystemOcr.swift': <String>{'macos', 'ios'},
      'packages/flutter_inappwebview_windows/windows/in_app_webview.cpp':
          <String>{'windows'},
      'packages/gamepads_windows/lib/gamepads_windows.dart': <String>{
        'windows',
      },
      // 原生库：进哪个包就开哪个。
      'native/fushi_p2p/src/lib.rs': all,
      'packages/fushi_p2p/lib/src/ffi/fushi_p2p_bindings.dart': all,
      'native/fushidicts/src/fushidicts.cpp': apps,
      'native/galgame_hook/src/hook.cpp': <String>{'windows'},
      'native/fushi_torrent/fushi_torrent_ffi.cpp': <String>{
        'windows',
        'macos',
        'server',
      },
      'packages/fushi_torrent/lib/src/embedded_torrent_engine.dart': <String>{
        'windows',
        'macos',
        'server',
      },
      'native/fushi_anki_sync/src/main.rs': <String>{
        'windows',
        'macos',
        'server',
      },
      // 无头服务端的 Dart 依赖闭包。
      'packages/fushi_server/lib/src/cli.dart': <String>{'server'},
      'packages/fushi_engine/lib/sync/fushi_sync_server.dart': <String>{
        'server',
      },
      'packages/fushi_core/lib/src/database/tables.dart': <String>{'server'},
      // vendored 插件：按平台子目录 / 平台名包 / pubspec。
      'third_party/media_kit_video/macos/media_kit_video.podspec': <String>{
        'macos',
      },
      'third_party/media_kit_libs_windows_video/windows/CMakeLists.txt':
          <String>{'windows'},
      'third_party/ffmpeg_kit_flutter/ios/ffmpeg_kit_flutter.podspec': <String>{
        'ios',
      },
      'third_party/media_kit_video/pubspec.yaml': apps,
      'third_party/media_kit_video/lib/media_kit_video.dart': <String>{},
      'third_party/media_kit_libs_android_video/android/build.gradle':
          <String>{},
      'third_party/m_extension_server/overlay/Server.kt': <String>{
        'windows',
        'macos',
      },
      'tool/mihon/build_desktop_runtime.sh': <String>{'windows', 'macos'},
      'tools/build_magpie_slim.ps1': <String>{'windows'},
      // appSmoke 装置。
      'fushi/integration_test/app_smoke_test.dart': <String>{
        'windows',
        'macos',
      },
      'fushi/tool/test_flow/comprehensive_test_matrix.dart': <String>{
        'windows',
        'macos',
      },
      // 基建：全开。
      'pubspec.lock': all,
      'pubspec.yaml': all,
      'ci/apply-patches.sh': all,
      '.github/workflows/build-multiplatform.yml': all,
      '.github/actions/native-store-names/names.sh': all,
      '.github/actions/native-artifact-store/action.yml': all,
      '.github/actions/provide-baked-secrets/action.yml': apps,
      '.github/scripts/verify_torrent_abi.sh': <String>{'macos', 'server'},
    };
    final List<String> wrong = <String>[
      for (final MapEntry<String, Set<String>> c in cases.entries)
        if (!_sameSet(routed(c.key), c.value))
          '${c.key}: 期望 ${c.value.toList()..sort()}，'
              '实际 ${routed(c.key).toList()..sort()}',
    ];
    expect(wrong, isEmpty, reason: wrong.join('\n'));
  });

  test('每个平台 job 调用到的仓库路径都被它的路由覆盖', () {
    final List<String> offenders = <String>[];
    int checked = 0;
    for (final MapEntry<String, String> g in gatedJobs.entries) {
      final RegExp? route = routes[g.key];
      final String body = jobs[g.value] ?? '';
      for (final String ref in _referencedRepoPaths(body)) {
        checked++;
        final String probe = _looksLikeFile(ref) ? ref : '$ref/x';
        if (route == null || !route.hasMatch(probe)) {
          offenders.add('${g.value}：$ref（路由 ${g.key} 不覆盖）');
        }
      }
    }
    expect(
      checked,
      greaterThanOrEqualTo(40),
      reason: '只对账了 $checked 个路径引用；提取正则失效了？',
    );
    expect(
      offenders,
      isEmpty,
      reason:
          '这些路径被 job 读到，但改它们的 PR 不会开这个 job——把它们加进 '
          'changes job 里对应的正则：\n${offenders.join('\n')}',
    );
  });

  test('每个平台 job restore 的持久库件，其输入目录（names.sh）都被它的路由覆盖', () {
    final String script = namesScript.readAsStringSync().replaceAll(
      '\r\n',
      '\n',
    );
    final Map<String, List<String>> arrays = <String, List<String>>{
      for (final RegExpMatch m in RegExp(
        r'^([A-Z0-9_]+)=\(([^)]*)\)$',
        multiLine: true,
      ).allMatches(script))
        m.group(1)!: m.group(2)!.trim().split(RegExp(r'\s+')),
    };
    expect(arrays.keys, containsAll(<String>['TORRENT', 'P2P', 'ANKI_SYNC']));
    final List<String> offenders = <String>[];
    int checked = 0;
    for (final MapEntry<String, String> g in gatedJobs.entries) {
      final String body = jobs[g.value] ?? '';
      final RegExpMatch? platform = RegExp(
        r'^\s+platform:\s*(\w+)\s*$',
        multiLine: true,
      ).firstMatch(body);
      expect(platform, isNotNull, reason: '${g.value} 没有 native_store 步骤');
      final String branch = _caseBranch(script, platform!.group(1)!) ?? '';
      expect(branch, isNotEmpty, reason: 'names.sh 没有 ${platform.group(1)} 分支');
      final Set<String> keys = <String>{
        for (final RegExpMatch m in RegExp(
          r'steps\.native_store\.outputs\.([a-z0-9_]+)',
        ).allMatches(body))
          if (m.group(1) != 'p2p_rust') m.group(1)!,
      };
      for (final String key in keys) {
        final RegExpMatch? line = RegExp(
          '"$key=[^\\n]*\\\$\\{([A-Z0-9_]+)\\[@\\]\\}',
        ).firstMatch(branch);
        expect(
          line,
          isNotNull,
          reason: 'names.sh ${platform.group(1)} 分支里没有 $key',
        );
        for (final String dir in arrays[line!.group(1)!] ?? <String>[]) {
          checked++;
          if (!(routes[g.key]?.hasMatch('$dir/x') ?? false)) {
            offenders.add('${g.value}：$key 的输入 $dir（路由 ${g.key} 不覆盖）');
          }
        }
      }
    }
    expect(checked, greaterThanOrEqualTo(8));
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('workflow 级 paths 不会在 changes job 之前就把路由的输入挡掉', () {
    final List<String> filter = _anchorPaths(workflow, 'multiplatform_paths');
    expect(filter, isNotEmpty, reason: '找不到 paths: &multiplatform_paths 清单');
    expect(
      workflow,
      contains('    paths: *multiplatform_paths'),
      reason: 'pull_request 必须复用同一份 paths 锚点',
    );
    final List<String> blocked = <String>[
      for (final String p in <String>[
        'packages/fushi_server/lib/src/cli.dart',
        'packages/fushi_engine/lib/sync/fushi_sync_server.dart',
        'native/fushi_p2p/src/lib.rs',
        'native/galgame_hook/src/hook.cpp',
        'fushi/windows/runner/flutter_window.cpp',
        'fushi/apple/FushiSystemOcr.swift',
        'third_party/m_extension_server/overlay/Server.kt',
        'tool/mihon/build_desktop_runtime.sh',
        'tools/build_magpie_slim.ps1',
        'ci/apply-patches.sh',
        'pubspec.lock',
        '.github/actions/native-store-names/names.sh',
        '.github/scripts/verify_torrent_abi.sh',
        '.github/workflows/build-multiplatform.yml',
      ])
        if (routed(p).isNotEmpty && !_githubPathFilterMatches(filter, p)) p,
    ];
    expect(
      blocked,
      isEmpty,
      reason:
          '这些路径会开某个平台 job，但 workflow 级 paths 过滤把整条 workflow 挡掉了'
          '（GitHub 对此零诊断）：\n${blocked.join('\n')}',
    );
  });

  test('Linux app 构建不回来；服务端随包原生库冒烟留在 linux-server', () {
    // 任何 workflow 都不再编 Linux app（所有者 2026-09-30：很长时间内不做 Linux app）。
    final List<String> linuxAppBuilds = <String>[];
    for (final File f in Directory(
      '../.github/workflows',
    ).listSync().whereType<File>()) {
      if (!f.path.endsWith('.yml') && !f.path.endsWith('.yaml')) continue;
      final List<String> lines = f.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('#')) continue;
        if (lines[i].contains('flutter build linux')) {
          linuxAppBuilds.add('${f.uri.pathSegments.last}:${i + 1}');
        }
      }
    }
    expect(linuxAppBuilds, isEmpty, reason: linuxAppBuilds.join('\n'));
    expect(jobs.containsKey('linux'), isFalse);

    final String server = jobs['linux-server'] ?? '';
    for (final String needle in <String>[
      'native/fushi_torrent/build_linux_so.sh',
      '.github/scripts/verify_torrent_abi.sh',
      'FUSHI_TORRENT_LIB:',
      'working-directory: packages/fushi_torrent',
      'native/fushi_p2p/verify_abi.sh',
      'FUSHI_P2P_LIB:',
      "grep -q 'native library not found'",
      'native/fushi_anki_sync/build.sh --debug --install-dir build/fushi_server_linux/bundle/bin',
      'dart build cli --target packages/fushi_server/bin/fushi_server.dart',
      'libonnxruntime.so',
      'fushi_server serve --config',
      '"backend":"embedded"',
      'name: fushi_server-linux-x64',
    ]) {
      expect(server, contains(needle), reason: 'linux-server 丢了：$needle');
    }
    for (final String appOnly in <String>[
      'libgtk-3-dev',
      'provide-baked-secrets',
      'fushi/build/linux',
    ]) {
      expect(
        server,
        isNot(contains(appOnly)),
        reason: 'linux-server 只做服务端，不该再有 Linux app 的 $appOnly',
      );
    }

    // server-gate.yml 仍是服务端的轻量门（analyze / 包测试 / 裸 build + --help），
    // 与 linux-server 互补：两者缺一，只改服务端的 PR 就少一层。
    final String gate = File(
      '../.github/workflows/server-gate.yml',
    ).readAsStringSync();
    expect(gate, contains('dart analyze'));
    expect(gate, contains('fushi_server --help'));
  });

  test('macOS 包带内置 torrent 引擎 dylib（BUG-2865）', () {
    // macOS 曾经从没编过 libfushi_torrent_ffi.dylib：app 把 macOS 算作支持内置引擎的
    // 平台，加载失败后内置引擎恒不可用。PR 门与发布构建都得编、出包后都得核对。
    final Map<String, String> releaseJobs = _parseJobs(
      File('../.github/workflows/release-desktop.yml').readAsStringSync(),
    );
    final Map<String, String> macJobs = <String, String>{
      'build-multiplatform.yml macos': jobs['macos'] ?? '',
      'release-desktop.yml macos': releaseJobs['macos'] ?? '',
    };
    for (final MapEntry<String, String> job in macJobs.entries) {
      for (final String needle in <String>[
        'native/fushi_torrent/build_macos_dylib.sh',
        '.github/scripts/verify_torrent_abi.sh',
        'name: \${{ steps.native_store.outputs.torrent }}',
        'Contents/Frameworks/libfushi_torrent_ffi.dylib',
      ]) {
        expect(job.value, contains(needle), reason: '${job.key} 丢了：$needle');
      }
    }
    expect(
      jobs['macos'],
      contains('working-directory: packages/fushi_torrent'),
      reason: 'PR 门要拿包里那份 dylib 跑 fushi_torrent 的真 FFI 测试',
    );
    final String pbxproj = File(
      'macos/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(pbxproj, contains('bundle_fushi_torrent.sh'));
    expect(File('macos/bundle_fushi_torrent.sh').existsSync(), isTrue);
  });
}

bool _sameSet(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

final RegExp _jobHeader = RegExp(r'^  ([A-Za-z0-9_-]+):\s*$');

/// `jobs:` 下每个 job 的原文（含 job 头那一行）。
Map<String, String> _parseJobs(String yaml) {
  final List<String> lines = yaml.split('\n');
  final int jobsAt = lines.indexOf('jobs:');
  final Map<String, String> jobs = <String, String>{};
  if (jobsAt == -1) return jobs;
  String? name;
  List<String> body = <String>[];
  void close() {
    final String? current = name;
    if (current != null) jobs[current] = body.join('\n');
  }

  for (int i = jobsAt + 1; i < lines.length; i++) {
    final String line = lines[i];
    if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) {
      break;
    }
    final RegExpMatch? m = _jobHeader.firstMatch(line);
    if (m != null) {
      close();
      name = m.group(1);
      body = <String>[line];
      continue;
    }
    body.add(line);
  }
  close();
  return jobs;
}

/// job 级（四格缩进）的键行，如 `    needs: changes`。
List<String> _jobLevelLines(String job) => <String>[
  for (final String l in job.split('\n'))
    if (l.startsWith('    ') && !l.startsWith('     ')) l.trimRight(),
];

/// changes job 脚本里的 `name='^...'` 正则定义。
Map<String, String> _regexDefinitions(String job) => <String, String>{
  for (final RegExpMatch m in RegExp(
    r"^\s+([a-z_]+)='(\^[^']*)'$",
    multiLine: true,
  ).allMatches(job))
    m.group(1)!: m.group(2)!,
};

/// changes job 脚本里的 `route <output> <var>...` 行。
Map<String, List<String>> _routeDefinitions(String job) =>
    <String, List<String>>{
      for (final RegExpMatch m in RegExp(
        r'^\s+route (\w+) ([\w ]+)$',
        multiLine: true,
      ).allMatches(job))
        m.group(1)!: m.group(2)!.trim().split(' '),
    };

/// bash `case` 里某个分支（`label)` 到它的 `;;`）的文本。
String _caseArm(String job, String label) {
  final List<String> lines = job.split('\n');
  final int at = lines.indexWhere((String l) => l.trim() == '$label)');
  if (at == -1) return '';
  final int end = lines.indexWhere((String l) => l.trim() == ';;', at);
  return lines.sublist(at, end == -1 ? lines.length : end).join('\n');
}

/// `names.sh` 里 `  <platform>)` 到下一个 `;;` 之间的文本。
String? _caseBranch(String script, String platform) {
  final int start = script.indexOf('\n  $platform)\n');
  if (start == -1) return null;
  final int end = script.indexOf(';;', start);
  return end == -1 ? null : script.substring(start, end);
}

/// job 正文（去掉注释行、反斜杠归一）里引用到的仓库路径，取到能决定路由的前两段：
/// `native/fushi_p2p`、`tool/mihon`、`tools/bundle_7za.ps1`、`.github/actions/x` ……
/// `fushi/...` 这类 app 内相对路径（构建产物、working-directory 下的相对路径）不在此列。
Set<String> _referencedRepoPaths(String job) {
  final String code = job
      .split('\n')
      .where((String l) => !l.trimLeft().startsWith('#'))
      .join('\n')
      .replaceAll(r'\', '/');
  final RegExp ref = RegExp(
    r'''(?<=^|[\s"'(=:,])'''
    r'(?:\.\.?/|\$GITHUB_WORKSPACE/|\$\{\{ github\.workspace \}\}/)?'
    r'((?:native|packages|tool|tools|ci|third_party)/[A-Za-z0-9_.-]+'
    r'|\.github/(?:actions|scripts)/[A-Za-z0-9_.-]+)',
    multiLine: true,
  );
  return <String>{
    for (final RegExpMatch m in ref.allMatches(code)) m.group(1)!,
  };
}

bool _looksLikeFile(String path) =>
    RegExp(r'\.(sh|ps1|py|dart|ya?ml|json)$').hasMatch(path);

/// `paths: &<anchor>` 下的清单项。
List<String> _anchorPaths(String yaml, String anchor) {
  final List<String> lines = yaml.split('\n');
  final int at = lines.indexWhere((String l) => l.trim() == 'paths: &$anchor');
  if (at == -1) return <String>[];
  final int indent = lines[at].length - lines[at].trimLeft().length;
  final RegExp item = RegExp(r"^\s*-\s*'([^']*)'\s*$");
  final List<String> out = <String>[];
  for (int i = at + 1; i < lines.length; i++) {
    final String l = lines[i];
    if (l.trim().isEmpty || l.trimLeft().startsWith('#')) continue;
    if (l.length - l.trimLeft().length <= indent) break;
    final RegExpMatch? m = item.firstMatch(l);
    if (m != null) out.add(m.group(1)!);
  }
  return out;
}

/// GitHub paths 过滤语义的最小实现：按顺序求值，后出现的匹配覆盖先出现的，`!` 取反。
/// 只支持本仓用到的 `**` / `*`。
bool _githubPathFilterMatches(List<String> patterns, String path) {
  bool included = false;
  for (final String raw in patterns) {
    final bool negate = raw.startsWith('!');
    final String glob = negate ? raw.substring(1) : raw;
    final StringBuffer re = StringBuffer('^');
    for (int i = 0; i < glob.length; i++) {
      final String c = glob[i];
      if (c == '*' && i + 1 < glob.length && glob[i + 1] == '*') {
        re.write('.*');
        i++;
      } else if (c == '*') {
        re.write('[^/]*');
      } else {
        re.write(RegExp.escape(c));
      }
    }
    re.write(r'$');
    if (RegExp(re.toString()).hasMatch(path)) included = !negate;
  }
  return included;
}
