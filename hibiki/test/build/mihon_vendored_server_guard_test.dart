// 守卫：Mihon 桌面 runtime 的 M-Extension-Server 源码必须来自仓库内 vendored 树，
// 且 vendored 树 + 补丁 + 安全 overlay 三者始终自洽（BUG-1415）。
//
// 背景：上游 miru-project/M-Extension-Server 已从 GitHub 删除（404）。构建脚本
// 原先 `git clone` 它，git 转去交互取凭据 → exit 128 → macos/windows job 红、
// publish job 因拿不到产物级联红。源码按 MPL-2.0 vendored 进
// third_party/m_extension_server/upstream_src/ 之后，这条守卫盯住三类回归：
//   ① 有人把 clone 加回来（外部依赖复活）；
//   ② upstream_src 或 server-build.gradle.patch 单边改动导致补丁打不上；
//   ③ overlay 与上游文件路径漂开 —— overlay 是**同名覆盖**，上游一旦改名/移动，
//      覆盖静默失效，安全边界（只绑 127.0.0.1 + 全路由 Bearer）跟着无声消失。
//      这条最危险，因为编译照样过。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 仓库根（测试从 `hibiki/` 下跑，与本目录其它 workflow 守卫同约定）。
const String _repositoryRoot = '..';
const String _vendorRoot = '$_repositoryRoot/third_party/m_extension_server';
const String _upstreamSource = '$_vendorRoot/upstream_src';

/// UPSTREAM 里钉定的上游 commit。
const String _pinnedCommit = 'ee55c65106bb18bf81a5ddc660d321b4e14ea2f9';

/// 上游 LICENSE 的 sha256 —— 同源性证据，换了源就必须重新取证。
const String _licenseSha256 =
    '3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04';

/// overlay 里覆盖上游**已有**文件的那些（相对 overlay/ 根）。
/// 这些路径必须在 upstream_src 里存在，否则覆盖打空。
const List<String> _overlayOverridesUpstream = <String>[
  'server/src/main/kotlin/mextensionserver/controller/MExtensionServerController.kt',
  'server/src/main/kotlin/mextensionserver/controller/DalvikHandler.kt',
];

/// overlay 里 Hibiki 新增、上游没有的文件。
const List<String> _overlayNewFiles = <String>[
  'server/src/main/kotlin/mextensionserver/controller/InspectHandler.kt',
  'server/src/main/kotlin/mextensionserver/controller/SourceImageHandler.kt',
  'server/src/main/kotlin/mextensionserver/controller/SourceDataHandler.kt',
];

String _read(String path) => File(path).readAsStringSync();

/// 掩掉 `#` 行注释（sh 与 ps1 同一种注释符），走共享的等长掩码原语。
///
/// 为什么必须剥：两份脚本的注释里**必须**能写出 "git clone" 这类字样来解释为什么
/// 不再那么做；不剥注释，守卫会被自己的解释性注释判成假红（并诱使后人把解释删掉）。
/// 为什么用掩码而不是删行：等长掩码保证下标与原文一致，下面「overlay 是否在补丁
/// 之后」那条位置断言拿到的偏移仍然指向真实位置。
String _maskedCode(String body) => maskHashComments(body);

void main() {
  test('vendored 上游树存在且完整（构建不再依赖任何外部仓库）', () {
    for (final String marker in <String>[
      'settings.gradle.kts',
      'build.gradle.kts',
      'gradlew',
      'gradlew.bat',
      'LICENSE',
      'server/build.gradle.kts',
      'gradle/wrapper/gradle-wrapper.jar',
      'AndroidCompat/build.gradle.kts',
    ]) {
      expect(
        File('$_upstreamSource/$marker').existsSync(),
        isTrue,
        reason: '缺 $_upstreamSource/$marker —— vendored 上游树不完整，'
            'gradle 构建会在 CI 上挂',
      );
    }
  });

  test('vendored LICENSE 与同源性证据一致，且与 MPL 通知件同一份', () {
    final String vendored = sha256
        .convert(File('$_upstreamSource/LICENSE').readAsBytesSync())
        .toString();
    expect(
      vendored,
      _licenseSha256,
      reason: 'upstream_src/LICENSE 的 sha256 变了 —— 说明 vendored 源码换了来源，'
          '必须重新做同源性取证并更新 UPSTREAM',
    );
    final String notice = sha256
        .convert(File('$_vendorRoot/LICENSE').readAsBytesSync())
        .toString();
    expect(
      notice,
      _licenseSha256,
      reason: 'third_party/m_extension_server/LICENSE 与 vendored 源码里的 LICENSE '
          '必须逐字节相同（MPL-2.0 许可正文）',
    );
  });

  test('UPSTREAM / NOTICE 记清了 commit、许可与 vendored 布局', () {
    final String upstream = _read('$_vendorRoot/UPSTREAM');
    expect(upstream, contains(_pinnedCommit));
    expect(upstream, contains('Mozilla Public License 2.0'));
    expect(upstream, contains('upstream_src/'),
        reason: 'UPSTREAM 必须说明源码 vendored 在哪、排除了什么');
    final String notice = _read('$_vendorRoot/NOTICE');
    expect(notice, contains('upstream_src/'),
        reason: 'MPL Corresponding Source 声明必须指向真正入库的源码目录');
  });

  group('构建脚本', () {
    final Map<String, String> scripts = <String, String>{
      'tool/mihon/build_desktop_runtime.sh':
          _read('$_repositoryRoot/tool/mihon/build_desktop_runtime.sh'),
      'tool/mihon/build_desktop_runtime.ps1':
          _read('$_repositoryRoot/tool/mihon/build_desktop_runtime.ps1'),
    };

    // 上游仓库已 404：任何形态的远端取源都会让 job 重新以 exit 128 挂掉。
    final RegExp remoteFetch = RegExp(
      r'''(git\s+(clone|fetch)\b|https?://\S*M-Extension-Server)''',
      caseSensitive: false,
    );

    scripts.forEach((String name, String body) {
      test('$name 不从远端取 M-Extension-Server 源码', () {
        final Iterable<RegExpMatch> hits =
            remoteFetch.allMatches(_maskedCode(body));
        expect(
          hits.map((RegExpMatch m) => m.group(0)).toList(),
          isEmpty,
          reason: '$name 又出现了远端取源 —— 上游仓库已删除，clone/fetch 会转去'
              '交互取凭据并以 exit 128 挂掉整个 job（BUG-1415）',
        );
      });

      test('$name 从 vendored 树取源并钉定 commit', () {
        final String code = _maskedCode(body);
        expect(code, contains('upstream_src'),
            reason: '$name 必须从 third_party/m_extension_server/upstream_src 取源');
        expect(code, contains(_pinnedCommit),
            reason: '$name 必须保留被 vendor 的 commit 作为产物溯源');
        expect(code, contains('server-build.gradle.patch'),
            reason: '$name 必须仍然应用 server-build.gradle.patch');
      });

      test('$name 里 overlay 在补丁之后应用（覆盖顺序即安全边界的胜负手）', () {
        final String code = _maskedCode(body);
        final int patchAt = code.indexOf('server-build.gradle.patch');
        // 拷 overlay 目录本身的那一行：sh 是 `"$overlay_root/overlay/."`，
        // ps1 是 `Copy-Tree (Join-Path $overlayRoot "overlay")`。两者都能被
        // 「overlay 后面紧跟目录分隔或右引号」这个形态匹配到，而 `$overlay_root`
        // / `$overlayRoot` 这类变量名不会（后面跟的是 `_root` / `Root`）。
        final RegExp overlayCopy = RegExp(r'overlay(/\.|")');
        final Iterable<RegExpMatch> copies = overlayCopy.allMatches(code);
        expect(copies, isNotEmpty,
            reason: '$name 里找不到把 Hibiki 安全 overlay 覆盖上去的那一步');
        expect(
          copies.first.start,
          greaterThan(patchAt),
          reason: '$name 必须先打补丁再拷 overlay；顺序反了，Hibiki 的安全'
              ' overlay 会被上游文件盖回去',
        );
      });

      test('$name 显式设置 ProductRevision（vendored 树无 .git，否则 revision 退化成空）', () {
        expect(_maskedCode(body), contains('ProductRevision'));
      });
    });
  });

  test('server-build.gradle.patch 仍能干净地打在 vendored 树上', () {
    final ProcessResult result = Process.runSync(
      'git',
      <String>[
        'apply',
        '--check',
        '--unidiff-zero',
        '../server-build.gradle.patch',
      ],
      workingDirectory: _upstreamSource,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    expect(
      result.exitCode,
      0,
      reason: 'git apply --check 失败，upstream_src 与 server-build.gradle.patch '
          '已经漂开，CI 上构建会挂：\n${result.stderr}',
    );
  });

  // `git apply --unidiff-zero`（构建脚本和上面那条守卫都用它）会**关掉**上下文
  // 校验：源文件第 N 行内容变了它照样 exit 0，然后按行号把内容盲替换掉 —— 补丁
  // 静默打歪，产物错得无声无息。所以必须自己逐条核对补丁的 `-` 行确实落在
  // upstream_src 对应行上。这才是真正能挡住漂移的那一条。
  test('server-build.gradle.patch 的每条删除行都对得上 vendored 树的实际内容', () {
    final List<String> patch =
        File('$_vendorRoot/server-build.gradle.patch').readAsLinesSync();
    final RegExp fileHeader = RegExp(r'^\+\+\+ b/(.+)$');
    final RegExp hunkHeader =
        RegExp(r'^@@ -(\d+)(?:,(\d+))? \+\d+(?:,\d+)? @@');

    String? currentPath;
    List<String>? currentLines;
    int sourceLine = 0;
    int checked = 0;

    for (final String line in patch) {
      final RegExpMatch? header = fileHeader.firstMatch(line);
      if (header != null) {
        currentPath = header.group(1)!;
        final File target = File('$_upstreamSource/$currentPath');
        expect(target.existsSync(), isTrue,
            reason: '补丁指向的 upstream_src/$currentPath 不存在');
        currentLines = target.readAsLinesSync();
        continue;
      }
      final RegExpMatch? hunk = hunkHeader.firstMatch(line);
      if (hunk != null) {
        sourceLine = int.parse(hunk.group(1)!);
        continue;
      }
      if (currentLines == null || sourceLine == 0) continue;
      if (line.startsWith('---') || line.startsWith('+++')) continue;
      if (line.startsWith('+')) continue;
      if (line.startsWith('-')) {
        final String expected = line.substring(1);
        expect(
          sourceLine <= currentLines.length
              ? currentLines[sourceLine - 1]
              : null,
          expected,
          reason: 'upstream_src/$currentPath 第 $sourceLine 行与补丁的删除行不一致；'
              '`git apply --unidiff-zero` 不会报错，只会把内容盲替换掉 —— '
              'upstream_src 与 server-build.gradle.patch 必须同步更新',
        );
        checked++;
        sourceLine++;
        continue;
      }
      if (line.startsWith(' ')) {
        sourceLine++;
      }
    }

    // 自校验：解析器失效（补丁格式变了 / 路径错了）必须红，不能静默扫空。
    expect(checked, greaterThan(10),
        reason: '只核对到 $checked 条删除行 —— 补丁解析很可能已经失效');
  });

  test('overlay 覆盖的上游文件路径仍然存在（覆盖没有打空）', () {
    for (final String relative in _overlayOverridesUpstream) {
      expect(
        File('$_vendorRoot/overlay/$relative').existsSync(),
        isTrue,
        reason: 'overlay/$relative 不见了 —— 安全 overlay 被删',
      );
      expect(
        File('$_upstreamSource/$relative').existsSync(),
        isTrue,
        reason: 'upstream_src/$relative 不存在，overlay 的同名覆盖打空了：'
            '上游文件被改名/移动时编译照样过，但 Hibiki 的安全边界会无声消失',
      );
    }
    for (final String relative in _overlayNewFiles) {
      expect(File('$_vendorRoot/overlay/$relative').existsSync(), isTrue,
          reason: 'overlay/$relative 不见了');
    }
  });

  test('安全边界仍写在 overlay 的 controller 里（只绑 loopback + 全路由 Bearer）', () {
    final String controller = _read(
      '$_vendorRoot/overlay/server/src/main/kotlin/mextensionserver/'
      'controller/MExtensionServerController.kt',
    );
    expect(
      controller,
      contains('NanoHTTPD("127.0.0.1"'),
      reason: '监听地址必须是 127.0.0.1；上游只传 port 等于监听 0.0.0.0',
    );
    expect(
      controller,
      contains('HIBIKI_MIHON_TOKEN'),
      reason: 'Bearer token 必须来自宿主按进程下发的环境变量',
    );
    expect(
      controller,
      contains('throw IllegalStateException'),
      reason: '缺 token 必须 fail-closed，服务不许起来',
    );
    expect(
      controller,
      contains('MessageDigest.isEqual'),
      reason: 'token 比较必须走常数时间比较',
    );

    // 鉴权必须在路由分发之前 —— 这是「没有任何 route 能绕过」的结构性证据。
    final int authGate = controller.indexOf('if (!authorized(session))');
    final int dispatch = controller.indexOf('when (session.uri)');
    expect(authGate, greaterThan(-1), reason: 'serve() 里的鉴权网关不见了');
    expect(dispatch, greaterThan(-1), reason: 'serve() 里的路由分发不见了');
    expect(
      authGate,
      lessThan(dispatch),
      reason: '鉴权必须早于 when(session.uri) 分发；一旦挪到分发之后，'
          '就会出现不过鉴权的 route',
    );

    // 生命周期与上游身份。
    expect(controller, contains('"/stop"'));
    expect(controller, contains('hibikiMihonBridge'));
  });
}
