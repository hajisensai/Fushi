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

/// 仓库根（测试从 `fushi/` 下跑，与本目录其它 workflow 守卫同约定）。
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

/// 补丁里出现的文件数（`+++ b/<path>` 的条数）——用来反空转，不硬编码。
int _patchedFileCount() => RegExp(r'^\+\+\+ b/', multiLine: true)
    .allMatches(_read('$_vendorRoot/server-build.gradle.patch'))
    .length;

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

      test('$name 应用补丁时不带 --unidiff-zero（零上下文=漂移无声）', () {
        // 掩掉注释：两份脚本的注释里**必须**能写出 `--unidiff-zero` 来解释为什么
        // 不再用它，否则这条守卫会被自己的解释性注释判成假红。
        expect(
          _maskedCode(body),
          isNot(contains('--unidiff-zero')),
          reason: '$name 又给 git apply 加回了 --unidiff-zero —— 零上下文补丁的'
              '纯插入 hunk 无内容可校验，`git apply --check` 对上游漂移 exit 0，'
              '真 apply 时按行号盲插到错误位置（BUG-1428）',
        );
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

      test('$name 钉的 sha256 必须正好 64 位十六进制（多一位就永远校验不过）', () {
        // BUG-1661：#850 把 macOS 的 pinned JDK 从 Temurin 换成 Corretto 时，
        // x64 归档的 sha256 抄成了 65 位（真值末尾多了一个字符）。`shasum -a 256
        // --check` 对这种长度不合法的期望值只会不停地判 FAILED，于是脚本完整下完
        // 193MB、重试三次、每次都 mismatch，最后整条 macos job 挂在
        // 「failed to download the pinned macOS JDK archives」——报出来的现象是
        // 「下载失败」，真因却是**抄错了一个字符**，把人往网络问题上带。
        //
        // 长度是这类笔误唯一稳定可测的不变式：内容对不对要下 193MB 才知道，
        // 位数对不对本地零成本。40 位的 git commit 不在这条规则内，故只看
        // `..._sha256 = "..."` 这种显式命名的赋值。
        final RegExp pinned = RegExp(
          r'''sha256\s*=\s*['"]([0-9a-zA-Z]+)['"]''',
          caseSensitive: false,
        );
        final Iterable<RegExpMatch> hits = pinned.allMatches(_maskedCode(body));
        expect(hits, isNotEmpty,
            reason: '$name 里找不到任何钉定的 sha256 —— 校验被整段拿掉了？');
        for (final RegExpMatch hit in hits) {
          final String value = hit.group(1)!;
          expect(
            value.length,
            64,
            reason: '$name 里 ${hit.group(0)} 不是 64 位 sha256（实际 '
                '${value.length} 位）。多一位/少一位都会让 shasum --check 恒红，'
                '而现象会伪装成「下载失败」。',
          );
          expect(
            RegExp(r'^[0-9a-f]{64}$').hasMatch(value),
            isTrue,
            reason: '$name 里 ${hit.group(0)} 含非小写十六进制字符',
          );
        }
      });

      test('$name 显式设置 ProductRevision（vendored 树无 .git，否则 revision 退化成空）', () {
        expect(_maskedCode(body), contains('ProductRevision'));
      });
    });
  });

  test('server-build.gradle.patch 仍能干净地打在 vendored 树上', () {
    // 两处刻意的调用形态，少一个这条守卫就变成空转（BUG-1428）：
    //
    // ① **不带** `--unidiff-zero` —— 见下面「补丁必须带上下文」那条。
    // ② 从**仓库根** + `--directory=`，而不是 cd 进 upstream_src 直接跑。
    //    `git apply` 在仓库内把补丁路径解释成**相对仓库根**，再丢掉落在当前
    //    目录之外的条目。在 upstream_src 里跑时，补丁里的 `gradle/...` /
    //    `server/...` 被当成 `<repo>/gradle/...`，全部落在 cwd 之外 ——
    //    git 打印 7 行 "Skipped patch" 然后 exit 0。实测：upstream_src 被改坏
    //    也照样绿。构建脚本没这个问题（它在仓库外的临时目录里跑）。
    final ProcessResult result = Process.runSync(
      'git',
      <String>[
        'apply',
        '--check',
        '--verbose',
        '--directory=third_party/m_extension_server/upstream_src',
        'third_party/m_extension_server/server-build.gradle.patch',
      ],
      workingDirectory: _repositoryRoot,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    final String log = '${result.stdout}\n${result.stderr}';

    // 反空转：git 必须真的逐个检查了补丁里的每个文件。
    expect(
      log,
      isNot(contains('Skipped patch')),
      reason: 'git apply 跳过了补丁条目 —— 这条守卫在空转，改坏 upstream_src 也会绿；'
          '路径解释方式又错了：\n$log',
    );
    final int checkedFiles = 'Checking patch'.allMatches(log).length;
    final int expectedFiles = _patchedFileCount();
    expect(
      checkedFiles,
      expectedFiles,
      reason: 'git apply 只检查了 $checkedFiles 个文件，补丁里有 $expectedFiles 个'
          ' —— 守卫覆盖不全：\n$log',
    );

    expect(
      result.exitCode,
      0,
      reason: 'git apply --check 失败，upstream_src 与 server-build.gradle.patch '
          '已经漂开，CI 上构建会挂：\n$log',
    );
  });

  // 这条是本文件里唯一能让 `git apply --check` **真的**挡住上游漂移的前提
  // （BUG-1428）。
  //
  // 实测：零上下文补丁里纯插入的 hunk（`@@ -69,0 +70 @@`）没有任何可校验内容，
  // 在 upstream_src 已漂移的树上 `git apply --check --unidiff-zero` 仍 exit 0，
  // 真 apply 时按行号把新代码盲插到错误位置 —— JGroupFilter 的 `stateString`
  // 落在 `name` 与 `type` 之间，Kotlin data class 的字段顺序是位置语义，编译照
  // 过、行为已错。带上下文之后，上游整体位移由 git 自动重定位，内容真变了硬失败。
  //
  // 所以补丁必须保持默认 3 行上下文：重新生成用 `git diff`，**不能**用
  // `git diff -U0`；应用它的地方（两份构建脚本 + 上面那条守卫）都不能带
  // `--unidiff-zero`。
  test('server-build.gradle.patch 必须带上下文（零上下文=漂移无声）', () {
    final List<String> patch =
        File('$_vendorRoot/server-build.gradle.patch').readAsLinesSync();
    final RegExp hunkHeader = RegExp(r'^@@ -\S+ \+\S+ @@');
    final List<String> headers =
        patch.where(hunkHeader.hasMatch).toList(growable: false);
    expect(headers, isNotEmpty, reason: '补丁里一个 hunk 都没有 —— 解析失效');

    // 零上下文 hunk 的形态：单行 `@@ -N +M @@`，或 `,0`（纯插入的旧侧长度 0）。
    final RegExp zeroContext = RegExp(r'^@@ -\d+(?: |,0 )\+|\+\d+(?: |,0) @@');
    final List<String> offenders =
        headers.where(zeroContext.hasMatch).toList(growable: false);
    expect(
      offenders,
      isEmpty,
      reason: '这些 hunk 是零上下文形态，补丁又被 `git diff -U0` 重新生成了：\n'
          '${offenders.join('\n')}\n'
          '零上下文的纯插入 hunk 无内容可校验，`git apply --check` 对上游漂移'
          ' exit 0，然后按行号盲插到错误位置（BUG-1428）',
    );

    // 正向证据：确实存在 ` ` 开头的上下文行（只看 hunk 头会被空补丁骗过）。
    final int contextLines =
        patch.where((String l) => l.startsWith(' ')).length;
    expect(contextLines, greaterThan(20),
        reason: '只有 $contextLines 行上下文 —— 补丁实际上仍是零上下文的');
  });

  // `git apply` 允许 hunk 带 offset 重定位：上游整体位移时它 exit 0 并打在正确
  // 位置。那对构建是好事，但意味着「补丁的行号仍与 upstream_src 对齐」这件事
  // 本身不再被 `--check` 保证。vendored 树是钉死的，补丁与它必须逐行对齐，所以
  // 这里自解析补丁，把 `-` 行**和** ` ` 上下文行都核到 upstream_src 的实际行上。
  test('server-build.gradle.patch 的删除行与上下文行都对得上 vendored 树的实际内容', () {
    final List<String> patch =
        File('$_vendorRoot/server-build.gradle.patch').readAsLinesSync();
    final RegExp fileHeader = RegExp(r'^\+\+\+ b/(.+)$');
    final RegExp hunkHeader =
        RegExp(r'^@@ -(\d+)(?:,(\d+))? \+\d+(?:,\d+)? @@');

    String? currentPath;
    List<String>? currentLines;
    int sourceLine = 0;
    int deletionsChecked = 0;
    int contextChecked = 0;

    /// 把补丁里一条旧侧的行（`-` 删除行或 ` ` 上下文行）核到 upstream_src 的实
    /// 际内容上。[lines] 是当前文件的全部行，[kind] 只进错误信息，用来区分是哪
    /// 一类行对不上。
    void verifyOldSideLine(List<String> lines, String expected, String kind) {
      expect(
        sourceLine <= lines.length ? lines[sourceLine - 1] : null,
        expected,
        reason: 'upstream_src/$currentPath 第 $sourceLine 行与补丁的$kind不一致 —— '
            'upstream_src 与 server-build.gradle.patch 必须同步更新'
            '（补丁重新生成用 `git diff`，不要用 `-U0`）',
      );
    }

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
      // `\ No newline at end of file` 不占旧侧行号。
      if (line.startsWith(r'\')) continue;
      if (line.startsWith('+')) continue;
      if (line.startsWith('-')) {
        verifyOldSideLine(currentLines, line.substring(1), '删除行');
        deletionsChecked++;
        sourceLine++;
        continue;
      }
      if (line.startsWith(' ')) {
        verifyOldSideLine(currentLines, line.substring(1), '上下文行');
        contextChecked++;
        sourceLine++;
      }
    }

    // 自校验：解析器失效（补丁格式变了 / 路径错了）必须红，不能静默扫空。
    expect(deletionsChecked, greaterThan(10),
        reason: '只核对到 $deletionsChecked 条删除行 —— 补丁解析很可能已经失效');
    expect(contextChecked, greaterThan(50),
        reason: '只核对到 $contextChecked 条上下文行 —— 补丁很可能又变回零上下文，'
            '或补丁解析已经失效');
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
      contains('FUSHI_MIHON_TOKEN'),
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
    expect(controller, contains('fushiMihonBridge'));
  });

  // ==========================================================================
  // /inspect 必须是「只读元数据」路径
  //
  // 时序才是要害：宿主在 _prepareInstallBytes 里就调 /inspect，弹「第三方扩展会以
  // Hibiki 权限执行代码」信任对话框在那之后。所以 /inspect 一旦经过
  // MExtensionServerLoader（Class.forName + newInstance + createSources），用户
  // 点“取消”时代码早就跑完了——警告变成过去式。加载是 /dalvik 的职责。
  //
  // 断言全部打在**剥掉注释**的源码上：这两个文件的注释里必须能写出
  // "MExtensionServerLoader" / "Class.forName" 来解释为什么不那么做。
  // ==========================================================================
  test('/inspect 不加载扩展代码（元数据闭包里没有任何执行原语）', () {
    const String inspectPath = '$_vendorRoot/overlay/server/src/main/kotlin/'
        'mextensionserver/controller/InspectHandler.kt';
    final String inspectCode = maskComments(_read(inspectPath));

    // ① InspectHandler 自己不碰加载器。
    for (final String primitive in _codeExecutionPrimitives) {
      expect(
        inspectCode,
        isNot(contains(primitive)),
        reason: 'InspectHandler 里出现了 $primitive —— /inspect 在信任对话框弹出'
            '之前就会执行扩展的静态初始化 / 构造器 / createSources()',
      );
    }
    expect(
      inspectCode,
      contains('PackageTools.getPackageInfo('),
      reason: '/inspect 必须只走 apk-parser 的元数据读取；换成别的读法就得重新'
          '证明那条路径不构造类',
    );

    // ② 闭包的另一端：getPackageInfo 的函数体本身也不能含执行原语。
    //    这两步合起来才是「从 /inspect 可达的代码里没有执行原语」的完整证据，
    //    而不是「我读了 InspectHandler 觉得没问题」。
    const String packageToolsPath = '$_upstreamSource/server/src/main/kotlin/'
        'mextensionserver/util/PackageTools.kt';
    expect(
      File(packageToolsPath).existsSync(),
      isTrue,
      reason: 'PackageTools.kt 不在了 —— overlay 里的 getPackageInfo 调用会悬空',
    );
    final String body = _kotlinFunctionBody(
      _read(packageToolsPath),
      'fun getPackageInfo(',
    );
    // 反空转：函数体解析一旦失效（改名 / 花括号匹配错），下面的 isNot(contains)
    // 会在空串上全部通过，变成假绿。
    expect(
      body.length,
      greaterThan(200),
      reason: 'getPackageInfo 函数体只解析到 ${body.length} 字符 —— 花括号匹配'
          '很可能已经失效，下面的断言会在空串上假绿',
    );
    expect(
      body,
      contains('ApkParsers.getMetaInfo'),
      reason: '解析出来的函数体不像 getPackageInfo —— 锚点串对错了位置',
    );
    for (final String primitive in _codeExecutionPrimitives) {
      expect(
        body,
        isNot(contains(primitive)),
        reason: 'PackageTools.getPackageInfo 里出现了 $primitive —— /inspect 的'
            '“只读元数据”闭包被击穿，上游漂移把执行路径带回来了',
      );
    }
  });

  test('sidecar 端口由子进程自报（token 不会发给陌生进程）', () {
    final String controller = maskComments(_read(
      '$_vendorRoot/overlay/server/src/main/kotlin/mextensionserver/'
      'controller/MExtensionServerController.kt',
    ));
    final String runtime = maskComments(_read(
      '$_repositoryRoot/fushi/lib/src/media/manga/mihon/'
      'desktop_mihon_runtime.dart',
    ));

    // 契约两端必须是同一个字面量，否则宿主永远等不到就绪行。
    expect(controller, contains(_readyLinePrefix));
    expect(
      runtime,
      contains(_readyLinePrefix),
      reason: '宿主侧的就绪行前缀与 controller 对不上 —— 启动会退化成 20s 超时',
    );

    // 子进程必须先 bind 再报端口。
    final int bind = controller.indexOf('server?.start(');
    final int announce = controller.indexOf('announceReady(');
    expect(bind, greaterThan(-1), reason: 'controller 里的 NanoHTTPD 启动不见了');
    expect(announce, greaterThan(-1), reason: '就绪行播报不见了');
    expect(
      bind,
      lessThan(announce),
      reason: '端口必须在 NanoHTTPD 已经 bind 之后才播报；提前播报等于又回到'
          '「报出来的端口未必归自己」',
    );

    // 宿主不许自己挑端口：bind→close→把号交给子进程之间存在 TOCTOU 窗口，
    // 期间任何本机进程都能抢走该端口，宿主随后把 Bearer token 发给陌生人。
    expect(
      runtime,
      isNot(contains('ServerSocket.bind')),
      reason: '宿主又开始自己预选端口了 —— token 可能发给抢占该端口的陌生进程',
    );

    // token 必须在拿到「子进程自报的端口」之后才可能发出。
    final int awaitPort = runtime.indexOf('await announced.future');
    final int assignPort = runtime.indexOf('_port = readyPort;');
    final int firstRequest = runtime.indexOf('await _readCapabilities()');
    expect(awaitPort, greaterThan(-1), reason: '等待就绪行的地方不见了');
    expect(assignPort, greaterThan(-1), reason: '_port 的赋值点不见了');
    expect(firstRequest, greaterThan(-1), reason: '就绪探测请求不见了');
    expect(awaitPort, lessThan(assignPort));
    expect(
      assignPort,
      lessThan(firstRequest),
      reason: '_port 必须在第一次带 token 的请求之前、且只能由子进程自报的值赋出',
    );

    // 就绪循环：先查子进程死没死，再发认证请求。
    final int loopExited =
        runtime.indexOf('await _hasExited(process)', awaitPort);
    expect(loopExited, greaterThan(-1), reason: '就绪循环里的存活检查不见了');
    expect(
      loopExited,
      lessThan(firstRequest),
      reason: '存活检查必须在请求之前；放在 catch 里等于每轮都先朝一个可能已经'
          '不是自家子进程的端口发一次带 token 的请求',
    );
  });

  test('/source-image 的响应缓冲有硬上限（敌意源不能 OOM 掉 sidecar）', () {
    final String handler = maskComments(_read(
      '$_vendorRoot/overlay/server/src/main/kotlin/mextensionserver/'
      'controller/SourceImageHandler.kt',
    ));
    expect(
      handler,
      isNot(contains('body.bytes()')),
      reason: 'body.bytes() 是无上限全量缓冲，sidecar 只有 -Xmx512m；'
          '源站点控制的 URL 返回超大响应就能把整个 JVM 打死',
    );
    expect(handler, contains('MAX_IMAGE_BYTES'));
    expect(
      handler,
      contains('body.byteStream()'),
      reason: '必须边读边计数；只看 Content-Length 会被 chunked 响应绕过',
    );
  });
}

/// 会让第三方 APK 里的代码真正跑起来的原语。
///
/// 前四个是加载器入口，后四个是「把 APK 里的类变成活对象」本身；`/inspect` 的
/// 可达闭包里出现任意一个，都意味着「用户点确认之前不执行扩展代码」这条不变式
/// 已经破了。
///
/// 刻意**不**收裸 `newInstance`：`DocumentBuilderFactory.newInstance()` 这类
/// JAXP 静态工厂同名，收了就是纯子串假阳（实测 getPackageInfo 里就有一处）。
/// 闭包不因此漏 —— 想拿到扩展类的 `Class` 对象，只能经过 `Class.forName` 或者
/// 自建 ClassLoader，两条都在下面。
const List<String> _codeExecutionPrimitives = <String>[
  'MExtensionServerLoader',
  'invokeWithExtension',
  'loadExtensionSources',
  'dex2jar',
  'URLClassLoader',
  'Class.forName',
  'getDeclaredConstructor',
  'defineClass',
  'createSources',
];

/// 宿主与 sidecar 之间的就绪行契约（两端必须共用同一个字面量）。
const String _readyLinePrefix = 'FUSHI_MIHON_READY port=';

/// 取 [source] 里以 [anchor] 开头的 Kotlin 函数体（含外层花括号）。
///
/// 花括号配对走 [maskCommentsAndStrings]（注释与字符串里的花括号不参与配对），
/// 再用同下标切回**只剥注释**的版本 —— 两者等长，所以下标通用；返回值里字符串
/// 字面量原样保留，调用方的 contains 断言才能看到真实代码。
String _kotlinFunctionBody(String source, String anchor) {
  final String structural = maskCommentsAndStrings(source);
  final String readable = maskComments(source);
  final int start = structural.indexOf(anchor);
  if (start < 0) return '';
  final int open = structural.indexOf('{', start);
  if (open < 0) return '';
  int depth = 0;
  for (int i = open; i < structural.length; i++) {
    final String c = structural[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return readable.substring(open, i + 1);
    }
  }
  return '';
}
