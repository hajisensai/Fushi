import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1772 源码扫描守卫：内置 torrent 引擎的 libtorrent 版本必须钉死。
///
/// 病灶：CI 原来跑的是 classic 模式的裸 `vcpkg install libtorrent:x64-windows`
/// / `libtorrent:arm64-android` —— 装到哪个版本完全由 runner 镜像内固化的 vcpkg
/// 修订决定，仓库这边一个字都管不着。vcpkg 在 e90cc0982b（2026-08-12）把
/// ports/libtorrent 从 2.0.11 升到 2.1.1，镜像 20260818.277.1 跟进，于是
/// fushi_torrent_ffi.cpp 里五处 2.0-only API（torrent_info::files() /
/// lt::add_files / create_torrent(file_storage) / lt::from_span / peer_info::ip）
/// 同时编不过，Windows 4 个 DLL 和 Android .so 一起断供 —— 而
/// build_windows_dll.ps1 对 Release 校验那 4 个 DLL 缺一即 throw，等于 Windows
/// 正式包直接出不来。develop 上连红，且不是任何一个 commit 引入的。
///
/// 修复是 native/fushi_torrent/vcpkg.json（manifest + overrides 钉 2.0.11）。
/// 这个守卫钉住让它继续生效的三个条件；任何一条被破坏，都会重演一次同款断供。
///
/// BUG-2021 起本文件还钉住第二件事：**这条 native 构建链在 PR 上必须有门**。
/// 版本钉得再准，也挡不住「Android 侧的交叉编译从来没在合并前跑过」——
/// build_android_so.sh 此前只被 release.yml 消费，而那个 workflow 没有
/// pull_request 触发、push 的 paths 里也没有 native/**。
/// 详见 docs/bugs/BUG-2021-libtorrent-ci-compile-gate.md。

/// 去掉整行注释（`#` 开头）。判据必须剥注释：本仓注释极其详尽，
/// 「release.yml 没有 pull_request 触发」这种说明文字本身就含判据字面量，
/// 不剥的话每个 workflow 看起来都像有 PR 触发。
String _stripComments(String text) {
  return const LineSplitter()
      .convert(text)
      .where((String line) => !line.trimLeft().startsWith('#'))
      .join('\n');
}

/// workflow 是否真有 `pull_request:` 触发。
///
/// 只认 `on:` 块里缩进 1~4 空格的独立 key，不做全文 contains：
/// 全文里 `pull_request` 还会出现在 `if: github.event_name == 'pull_request'`、
/// `cancel-in-progress` 表达式和步骤名里，那些都不是触发器。
bool hasPullRequestTrigger(String workflowText) {
  final List<String> lines =
      const LineSplitter().convert(_stripComments(workflowText));
  bool inOnBlock = false;
  for (final String line in lines) {
    if (line.trim().isEmpty) continue;
    final bool topLevel = !line.startsWith(' ') && !line.startsWith('\t');
    if (topLevel) {
      // `on:` / `on: [push]` / YAML 1.1 里没引号的 on 会被解析成 true，但文本层
      // 看到的仍是 `on:`。遇到下一个顶格 key 就退出 on 块。
      inOnBlock = RegExp(r'^(on|"on"|true):').hasMatch(line.trim());
      continue;
    }
    if (!inOnBlock) continue;
    if (RegExp(r'^ {1,4}pull_request:').hasMatch(line)) return true;
  }
  return false;
}

/// workflow 是否消费了某个构建脚本（按仓库相对路径匹配，剥注释后）。
bool consumesScript(String workflowText, String scriptRepoPath) {
  return _stripComments(workflowText).contains(scriptRepoPath);
}

void main() {
  const String nativeDir = '../native/fushi_torrent';
  const String workflowDir = '../.github/workflows';

  test('vcpkg.json 把 libtorrent 钉在 2.0.x（overrides + builtin-baseline）', () {
    final File manifest = File('$nativeDir/vcpkg.json');
    expect(manifest.existsSync(), isTrue,
        reason: 'native/fushi_torrent/vcpkg.json 是版本钉定的唯一真相源，删掉它'
            '就退回「装到哪版看 runner 心情」的不可重现构建');

    final Map<String, dynamic> json =
        jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;

    final Object? baseline = json['builtin-baseline'];
    expect(baseline, isA<String>(),
        reason: 'overrides 只有在 versioning 生效时才被考虑，而 builtin-baseline '
            '是启用 versioning 的必填项；缺了它 overrides 会被静默忽略');
    expect((baseline! as String).length, 40,
        reason: 'builtin-baseline 必须是完整 40 位 commit sha');

    final List<dynamic> overrides =
        (json['overrides'] as List<dynamic>?) ?? <dynamic>[];
    final Map<String, dynamic> pin = overrides
        .cast<Map<String, dynamic>>()
        .firstWhere((Map<String, dynamic> o) => o['name'] == 'libtorrent',
            orElse: () => <String, dynamic>{});
    expect(pin['version'], isNotNull,
        reason: 'libtorrent 必须显式钉版；注意字段名是 version（2.0.11 的 port 用的是 '
            'relaxed scheme），写成 version-string / version-semver 会被 vcpkg 拒掉');
    expect((pin['version']! as String).startsWith('2.0.'), isTrue,
        reason: 'bridge 用的是 2.0 API；要升 2.1 得先改 fushi_torrent_ffi.cpp '
            '那五处调用，不能只动这里');
  });

  test('CI 不得退回 classic vcpkg install（版本会重新随 runner 镜像漂）', () {
    for (final String name in <String>[
      'build-multiplatform.yml',
      'release-desktop.yml',
      'release.yml',
    ]) {
      final File wf = File('../.github/workflows/$name');
      if (!wf.existsSync()) continue;
      final String text = wf.readAsStringSync();
      for (final String line in const LineSplitter().convert(text)) {
        final String bare = line.trim();
        if (bare.startsWith('#')) continue;
        expect(bare.contains('install libtorrent'), isFalse,
            reason: '$name 又出现 classic `vcpkg install libtorrent`：manifest 模式'
                '下依赖由 cmake 工具链按 vcpkg.json 装，classic 装的是 ports 当下'
                '的版本，会把 2.0 的钉定绕过去（BUG-1772）');
      }
    }
  });

  test('Android 构建脚本把 overlay triplets 传给 cmake（否则静默降到 API 28）', () {
    for (final String name in <String>[
      'build_android_so.sh',
      'build_android_so.ps1',
    ]) {
      final String text = File('$nativeDir/$name').readAsStringSync();
      expect(text.contains('VCPKG_OVERLAY_TRIPLETS'), isTrue,
          reason: '$name 必须给 cmake 传 -DVCPKG_OVERLAY_TRIPLETS：manifest 模式下'
              '装依赖的是 vcpkg 工具链而不是命令行，overlay 不参与就会退回 vcpkg '
              '自带的 arm64-android（钉 API 28），boost.asio 会引用 API 28 才有的 '
              'aligned_alloc，bridge 按 minSdk 24 链接直接 undefined symbol');
    }
  });

  test('bridge 仍在用 2.0-only API —— 钉版和源码必须同进退', () {
    final String cpp =
        File('$nativeDir/fushi_torrent_ffi.cpp').readAsStringSync();
    // 这几处是 2.1 移除/改名的：只要还在，vcpkg.json 就必须钉 2.0.x（上一条测试保证）。
    // 真迁到 2.1 后它们会一起消失，这条断言自然失效 —— 那时才允许动 overrides。
    final List<String> markers = <String>[
      'lt::add_files',
      'lt::from_span',
      'pi.ip',
    ];
    final List<String> present =
        markers.where((String m) => cpp.contains(m)).toList();
    expect(present, isNotEmpty,
        reason: 'fushi_torrent_ffi.cpp 已经不含任何 2.0-only 调用了？如果 bridge 真的'
            '迁到了 2.1 API，请同时把 vcpkg.json 的 libtorrent overrides 一起改掉，'
            '并删掉这条断言 —— 否则钉定和源码会各说各话（BUG-1772）');
  });

  // ── BUG-2021：构建链必须在 PR 上有门 ───────────────────────────────────────
  //
  // 钉版守住的是「装哪个版本」，守不住「有没有人在合并前编过一次」。
  // build_android_so.sh 曾经只被 release.yml 消费，而那个 workflow 没有
  // pull_request 触发 —— 改 native/fushi_torrent 的 PR 从来没被交叉编译验证过。

  test('build_android_so.sh 必须被至少一个带 pull_request 触发的 workflow 消费', () {
    final Directory dir = Directory(workflowDir);
    expect(dir.existsSync(), isTrue, reason: '$workflowDir 不存在？');

    final List<File> workflows = dir
        .listSync()
        .whereType<File>()
        .where((File f) =>
            f.path.endsWith('.yml') || f.path.endsWith('.yaml'))
        .toList();

    // 扫描规模哨兵：枚举塌了的话下面的 firstWhere 会变成「没找到 = 没门」的假红，
    // 或者反过来在别的断言里变成空转。实测 develop 上是 13 个 workflow。
    expect(workflows.length, greaterThanOrEqualTo(10),
        reason: '只枚举到 ${workflows.length} 个 workflow 文件，扫描面塌了');

    const String script = 'native/fushi_torrent/build_android_so.sh';
    final List<String> gates = <String>[];
    for (final File wf in workflows) {
      final String text = wf.readAsStringSync();
      if (!consumesScript(text, script)) continue;
      if (!hasPullRequestTrigger(text)) continue;
      gates.add(wf.uri.pathSegments.last);
    }

    expect(gates, isNotEmpty,
        reason: '没有任何带 pull_request 触发的 workflow 跑 $script。'
            '这正是 BUG-2021 的原状：Android 侧的 vcpkg 交叉编译只在 release.yml '
            '里跑，而它是发布路径（无 PR 触发，push 的 paths 里也没有 native/**）——'
            '改 C ABI bridge 或 overlay 的 PR 合并前一次都没编过。'
            '新的门在 .github/workflows/native-torrent-gate.yml，别把它删了或把它的 '
            'pull_request 触发去掉。');
  });

  test('overlay ports 存在时，三个构建脚本都必须把它传给 cmake', () {
    final Directory ports = Directory('$nativeDir/vcpkg-ports');
    if (!ports.existsSync() || ports.listSync().isEmpty) {
      // 目前 develop 上没有 overlay ports（只有 overlay triplets）。这条断言是给
      // 「引入 overlay port 补丁」的那条 PR 准备的：漏给 CI 消费的 .sh 版传
      // OVERLAY_PORTS，Windows 本机编得出、Android CI 编的却是没打补丁的上游 port。
      return;
    }
    for (final String name in <String>[
      'build_android_so.sh',
      'build_android_so.ps1',
      'build_windows_dll.ps1',
    ]) {
      final String text = File('$nativeDir/$name').readAsStringSync();
      expect(text.contains('VCPKG_OVERLAY_PORTS'), isTrue,
          reason: '$nativeDir/vcpkg-ports 里有 overlay port，但 $name 没给 cmake 传 '
              '-DVCPKG_OVERLAY_PORTS。与 OVERLAY_TRIPLETS 同一个坑：manifest 模式下'
              '装依赖的是 cmake 工具链，overlay 不传就静默装上游未打补丁的 port，'
              '而三个入口里恰恰是 CI 消费的 .sh 版最容易漏。');
    }
  });

  test('native-torrent-gate 只读、不发布、不得 continue-on-error', () {
    final File gate = File('$workflowDir/native-torrent-gate.yml');
    expect(gate.existsSync(), isTrue,
        reason: 'BUG-2021 的门文件不见了');
    final String text = gate.readAsStringSync();
    final String body = _stripComments(text);

    expect(body.contains('contents: read'), isTrue,
        reason: '门必须只读（permissions: contents: read）');
    expect(body.contains('continue-on-error'), isFalse,
        reason: 'continue-on-error 会让失败不打红，门就不是门了');
    for (final String publish in <String>[
      'action-gh-release',
      'gh release',
      'softprops',
    ]) {
      expect(body.contains(publish), isFalse,
          reason: '门里出现发布动作 $publish：仓库硬规则禁止 push/PR 路径创建或更新 '
              'release');
    }
    for (final String path in <String>[
      'native/fushi_torrent/**',
      'packages/fushi_torrent/**',
      '.github/workflows/native-torrent-gate.yml',
    ]) {
      expect(body.contains(path), isTrue,
          reason: '门的 paths 必须覆盖 $path，否则改动它的 PR 触发不了它自己');
    }
  });

  test('判据自校验：hasPullRequestTrigger / consumesScript 认得出合成语料', () {
    // 禁止型/存在型判据在健康仓库里对真实文件永远是同一个答案，判据本身坏掉时
    // 扫盘那条路检验不到。合成语料与磁盘扫描互不依赖，独立枚举。
    const String withTrigger = '''
name: x
on:
  workflow_dispatch:
  pull_request:
    branches: ['develop']
jobs:
  a:
    steps:
      - run: bash native/fushi_torrent/build_android_so.sh a b c
''';
    const String pushOnly = '''
name: y
# 这个 workflow 没有 pull_request 触发（注释里出现判据字面量，必须被剥掉）
on:
  push:
    branches: ['develop']
jobs:
  a:
    if: github.event_name == 'pull_request'
    steps:
      - name: something about pull_request:
        run: bash native/fushi_torrent/build_android_so.sh a b c
''';
    const String triggerButNoScript = '''
name: z
on:
  pull_request:
    branches: ['develop']
jobs:
  a:
    steps:
      # 只在注释里提到 native/fushi_torrent/build_android_so.sh
      - run: echo hi
''';

    expect(hasPullRequestTrigger(withTrigger), isTrue);
    expect(hasPullRequestTrigger(pushOnly), isFalse,
        reason: '注释、job 级 if 表达式和步骤名里的 pull_request 都不是触发器；'
            '判到 true 说明判据退化成了全文 contains');
    expect(hasPullRequestTrigger(triggerButNoScript), isTrue);

    expect(
        consumesScript(withTrigger, 'native/fushi_torrent/build_android_so.sh'),
        isTrue);
    expect(
        consumesScript(
            triggerButNoScript, 'native/fushi_torrent/build_android_so.sh'),
        isFalse,
        reason: '只在注释里出现不算消费；判到 true 说明没剥注释');
  });
}
