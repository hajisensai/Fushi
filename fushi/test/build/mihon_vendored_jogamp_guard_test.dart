// 守卫：Mihon 桌面 runtime 构建期解析 `org.jogamp` 时不得再依赖那两台不可靠主机。
//
// 背景（实测，不是预防性洁癖）：
//   `:server` → `:AndroidCompat` → `dev.datlag:kcef` → `dev.datlag:jcef`
//   → `org.jogamp.gluegen:gluegen-rt:2.5.0` + `org.jogamp.jogl:jogl-all:2.5.0`
//   这两个构件**只**存在于 jogamp.org 与 maven.scijava.org 上，Maven Central 根本
//   没有 2.5.0（只有 <=2.3.2 和 2.6.0）。而且它不是可以 exclude 的死重量：
//   `AndroidCompatInitializer` 把 `KcefWebViewProvider` 注册成 WebView provider，
//   后者用 `CefRendering.OFFSCREEN`，JCEF 的离屏路径走 JOGL `GLCanvas` —— 排除它
//   只会把「CI 可见的红」换成「某个漫画源真要用 WebView 时才炸的 NoClassDefFound」。
//
//   2026-08-09 jogamp.org 整站宕机打断 CI，处置是「再加一个镜像」（scijava）。
//   2026-08-25 scijava `Read timed out`，同一晚把 develop 与 PR #1017 / #1018 三条
//   CI 一起弄红 —— 证明「再加一个不可靠主机」不是修复。现在 4 个构件按字节
//   vendored 进 third_party/jogamp（~4.1 MB），构建脚本把它搬进构建树，Gradle 优先
//   离线解析，两个远端镜像只作为**版本升级时**的回落。
//
// 本守卫盯住四类回归：
//   ① 有人删掉/改坏 vendored 构件（sha256 对照，字节级）；
//   ② 补丁里那段仓库声明被改掉，或本地仓库掉到远端镜像后面（顺序即优先级）；
//   ③ 两个构建脚本里任一忘了搬运，或忘了在缺失时硬失败（静默回落到远端 = 病灶复活）；
//   ④ 远端镜像的 content filter 被拿掉（那会让 jogamp 主机的故障重新污染无关坐标的解析）。
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 仓库根（测试从 `fushi/` 下跑，与本目录其它 build 守卫同约定）。
const String _repositoryRoot = '..';
const String _jogampRoot = '$_repositoryRoot/third_party/jogamp';
const String _vendorRoot = '$_repositoryRoot/third_party/m_extension_server';
const String _patchPath = '$_vendorRoot/server-build.gradle.patch';
const String _psScript = '$_repositoryRoot/tool/mihon/build_desktop_runtime.ps1';
const String _shScript = '$_repositoryRoot/tool/mihon/build_desktop_runtime.sh';

/// 补丁与两个构建脚本必须逐字共用的构建树内路径。任何一处改了而另两处没改，
/// Gradle 就找不到本地仓库、静默回落到远端 —— 正是本守卫要拦的静默失效。
const String _inTreeRepoPath = 'hibiki-offline-maven/jogamp';

/// vendored 构件的字节取证。SHA-256 变了就是「不再是上游那批字节」，必须重新取证
/// 并更新 third_party/jogamp/UPSTREAM 里的表。
const Map<String, String> _artifactSha256 = <String, String>{
  'org/jogamp/gluegen/gluegen-rt/2.5.0/gluegen-rt-2.5.0.jar':
      '3620c18536a8671fcb1c595d7448e9d31226b824117af6a4c6d45c657f4dabe3',
  'org/jogamp/gluegen/gluegen-rt/2.5.0/gluegen-rt-2.5.0.pom':
      'e92ee0c91986153579d2a7e1e5025068c2c24a53527372fe56baa4d990b018f3',
  'org/jogamp/jogl/jogl-all/2.5.0/jogl-all-2.5.0.jar':
      '245717cceabca264a210a899f8839d47bd127f50f80892ead2277dd89cbcd301',
  'org/jogamp/jogl/jogl-all/2.5.0/jogl-all-2.5.0.pom':
      '6b086a2e461d7b7911a1c165ffcbde2ab79b00c54c360cf191ca00f5f784db6a',
};

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('vendored org.jogamp 离线仓库', () {
    test('4 个构件存在且字节与上游一致', () {
      expect(Directory(_jogampRoot).existsSync(), isTrue,
          reason: '$_jogampRoot 不存在 —— vendored 仓库被删了？'
              '删掉它构建就会退回 jogamp.org / scijava，'
              '那正是 2026-08-09 与 2026-08-25 两次 CI 红的病灶。');

      _artifactSha256.forEach((String relative, String expected) {
        final File file = File('$_jogampRoot/$relative');
        expect(file.existsSync(), isTrue, reason: '缺构件：$relative');
        final String actual =
            sha256.convert(file.readAsBytesSync()).toString();
        expect(actual, expected,
            reason: '$relative 的字节变了（实际 $actual）。vendored 构件必须与上游'
                '逐字节一致；真要升级请按 third_party/jogamp/UPSTREAM 的步骤'
                '重新取证并同步更新本表。');
      });
    });

    test('.sha1 伴生文件与构件自洽（Gradle 解析本地仓库时会自校验）', () {
      _artifactSha256.forEach((String relative, String _) {
        final File file = File('$_jogampRoot/$relative');
        final File sidecar = File('$_jogampRoot/$relative.sha1');
        expect(sidecar.existsSync(), isTrue, reason: '缺 .sha1：$relative.sha1');
        final String declared = sidecar.readAsStringSync().trim().toLowerCase();
        final String actual = sha1.convert(file.readAsBytesSync()).toString();
        expect(declared, actual,
            reason: '$relative.sha1 与实际不符（声明 $declared / 实际 $actual）。'
                '不一致会让 Gradle 拒绝这个本地仓库并静默回落到远端。');
      });
    });

    test('没有夹带 native classifier jar（依赖链里没有它们，多带就是白占体积）', () {
      final List<String> unexpected = Directory(_jogampRoot)
          .listSync(recursive: true)
          .whereType<File>()
          .map((File f) => f.path.replaceAll(r'\', '/'))
          .where((String p) => p.endsWith('.jar'))
          .where((String p) => p.contains('-natives-'))
          .toList();
      expect(unexpected, isEmpty,
          reason: 'jcef 的 POM 只声明 gluegen-rt 与 jogl-all 两个主构件，'
              '实测解析结果也只有 4 个文件。多出来的 natives jar 没人要：\n'
              '${unexpected.join("\n")}');
    });
  });

  group('构建补丁的仓库声明', () {
    late final String patch = _read(_patchPath);

    test('声明了构建树内的本地仓库，路径与脚本逐字一致', () {
      expect(patch.contains(_inTreeRepoPath), isTrue,
          reason: '补丁里找不到 "$_inTreeRepoPath"。补丁、ps1、sh 三处路径必须逐字'
              '相同，否则 Gradle 找不到本地仓库、静默回落远端。');
      expect(patch.contains('rootProject.file("$_inTreeRepoPath")'), isTrue,
          reason: '本地仓库必须用 rootProject.file("$_inTreeRepoPath") 定位；'
              '换成别的定位方式请同步更新本守卫与两个构建脚本。');
    });

    test('本地仓库排在两个远端镜像之前（顺序即优先级）', () {
      // 只在**新增行**上判序，而且用完整声明串而不是裸主机名。两个坑都实测踩过：
      //   ① 裸主机名会先命中补丁自己的解释性注释（注释里必须写得出
      //      "maven.scijava.org" 才说得清为什么要 vendored）；
      //   ② 补丁开头那条被删除的 `-  maven("https://jogamp.org/...")` 位置更靠前，
      //      拿它判序永远为假红。顺序只对补丁**产出的结果文件**有意义。
      final String added = patch
          .split('\n')
          .where((String l) => l.startsWith('+') && !l.startsWith('+++'))
          .join('\n');
      final int local = added.indexOf('rootProject.file("$_inTreeRepoPath")');
      final int scijava = added
          .indexOf('maven("https://maven.scijava.org/content/groups/public")');
      final int jogamp =
          added.indexOf('maven("https://jogamp.org/deployment/maven")');
      expect(local, greaterThanOrEqualTo(0), reason: '找不到本地仓库声明');
      expect(scijava, greaterThanOrEqualTo(0),
          reason: '找不到 scijava 镜像 —— 回落路径被删了？'
              '删掉它，将来升级 kcef/jcef 时新版本 org.jogamp 将无处解析。');
      expect(jogamp, greaterThanOrEqualTo(0),
          reason: '找不到 jogamp.org 镜像 —— 同上，回落路径不能删。');
      expect(local, lessThan(scijava),
          reason: '本地仓库必须排在 scijava 之前，否则每次构建仍然先打那台'
              '2026-08-25 超时过的主机，vendored 就白做了。');
      expect(local, lessThan(jogamp),
          reason: '本地仓库必须排在 jogamp.org 之前（同上）。');
    });

    test('三个 org.jogamp 仓库都带 content filter', () {
      // 没有 filter 时，jogamp 主机的故障会污染无关坐标的解析（历史上 jitpack 的
      // injekt-core 就被 Gradle 拿去打 jogamp.org）。
      final int filters =
          RegExp(r'includeGroupByRegex').allMatches(patch).length;
      expect(filters, 3,
          reason: '期望本地 + scijava + jogamp.org 三处各有一个 content filter，'
              '实际 $filters 处。');
    });
  });

  group('两个构建脚本的搬运', () {
    late final String ps = maskHashComments(_read(_psScript));
    late final String sh = maskHashComments(_read(_shScript));

    test('ps1 把 third_party/jogamp 搬进构建树，并在缺失时硬失败', () {
      expect(ps.contains(r'third_party\jogamp'), isTrue,
          reason: 'ps1 里找不到源目录 third_party\\jogamp（已剥注释，'
              '所以不是被解释性注释骗到的）。');
      expect(ps.contains(r'hibiki-offline-maven\jogamp'), isTrue,
          reason: 'ps1 里找不到目标路径 hibiki-offline-maven\\jogamp；'
              '它必须与补丁里的 "$_inTreeRepoPath" 指同一处。');
      expect(ps.contains('throw "Vendored org.jogamp repository is missing'),
          isTrue,
          reason: 'ps1 必须在 vendored 仓库缺失时 throw。静默继续 = 悄悄回落到'
              '那两台主机，病灶复活且没人看得见。');
    });

    test('sh 把 third_party/jogamp 搬进构建树，并在缺失时硬失败', () {
      expect(sh.contains('third_party/jogamp'), isTrue,
          reason: 'sh 里找不到源目录 third_party/jogamp（已剥注释）。');
      expect(sh.contains('hibiki-offline-maven/jogamp'), isTrue,
          reason: 'sh 里找不到目标路径 hibiki-offline-maven/jogamp。');
      expect(sh.contains('exit 1'), isTrue,
          reason: 'sh 必须在 vendored 仓库缺失时非零退出（同 ps1 的理由）。');
    });

    test('搬运发生在打补丁之后（补丁引用的是构建树里的路径）', () {
      final int psApply = ps.indexOf('server-build.gradle.patch');
      final int psCopy = ps.indexOf(r'hibiki-offline-maven\jogamp');
      expect(psApply, greaterThanOrEqualTo(0), reason: 'ps1 找不到 apply 补丁那步');
      expect(psCopy, greaterThan(psApply),
          reason: 'ps1 的搬运必须排在 apply 补丁之后，与 overlay 同一阶段。');

      final int shApply = sh.indexOf('server-build.gradle.patch');
      final int shCopy = sh.indexOf('hibiki-offline-maven/jogamp');
      expect(shApply, greaterThanOrEqualTo(0), reason: 'sh 找不到 apply 补丁那步');
      expect(shCopy, greaterThan(shApply),
          reason: 'sh 的搬运必须排在 apply 补丁之后（同上）。');
    });
  });
}
