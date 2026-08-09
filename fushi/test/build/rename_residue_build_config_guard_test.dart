import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fushi 改名收尾守卫（构建/打包/运维**脚本与配置**面）。
//
// 与 test/tools/fushi_rename_guard_test.dart 的分工：那条守卫扫 Dart 代码位与
// native 路径形态；这条扫**脚本和构建配置**——旧代号在这类文件里失效时既不会让
// flutter analyze 红、也不会让 flutter test 红、更不会让编译失败，只在真机运行、
// 发版或本地跑脚本时炸。实际发生过的三批：
//   * proguard-rules.pro 的 -keep class <旧包名>.**：R8 对匹配零个类的 keep
//     规则不告警 → release 包启动即闪退（见 android_app_package_keep_rule_guard_test）；
//   * run.sh / run.ps1 / 根 .bat 指向已被 git mv 掉的旧应用目录；
//   * ci/*.sh 的 PKG 默认值、tool/*_sweep.sh 的 REPO 默认值仍是旧身份 →
//     adb / gh 全部打空。
//
// 三条禁模式全部**真相源驱动**，不硬编码新身份：
//   A. applicationId：从 android/app/build.gradle 读出唯一真值，扫描面里出现的
//      每个 app.<x>.reader 字面量都必须等于它。
//   B. GitHub 仓库 slug：从 lib/src/utils/misc/update_checker_release.dart 的
//      kGitHubRepo 读出（app 自身查更新用的那一个），扫描面里出现的每个
//      <owner>/<repo> 都必须是同一个仓库（大小写不敏感，GitHub 本身如此）。
//   C. 旧代号词根：构建/打包配置里不得再出现 hibiki / hoshi。
//
// 白名单一条一个理由，且带**过期豁免检测**：某条豁免不再有真实命中时测试转红，
// 逼着连豁免一起删掉，防止白名单退化成永久盲区。
// ---------------------------------------------------------------------------

/// 一条豁免：文件路径后缀 + 只在**该行**同时匹配 [context] 时才放行。
///
/// 行级 context 是刻意的：整文件豁免会让同一文件里**新长出来**的失效引用也一起
/// 静默通过，那正是这套守卫要防的事。
class _Exemption {
  const _Exemption({
    required this.pathSuffix,
    required this.context,
    required this.reason,
  });

  /// 归一（正斜杠）路径后缀。
  final String pathSuffix;

  /// 命中所在**整行**必须匹配的上下文；null = 整文件豁免（只给旧名清理脚本）。
  final RegExp? context;

  final String reason;
}

/// 扫描面：目录（按扩展名过滤）或单文件，路径相对 fushi/（flutter test 的 cwd）。
class _ScanRoot {
  const _ScanRoot(this.path, {this.extensions});

  final String path;

  /// null = 单文件；否则只收这些扩展名。
  final Set<String>? extensions;
}

/// 构建 / 打包 / 平台工程配置：产物身份就在这里定，A/B/C 三条都扫。
const List<_ScanRoot> _buildConfigRoots = <_ScanRoot>[
  _ScanRoot('android/app/build.gradle'),
  _ScanRoot('android/app/proguard-rules.pro'),
  _ScanRoot('android/app/src/main/AndroidManifest.xml'),
  _ScanRoot('android/fastlane/Fastfile'),
  _ScanRoot('linux/CMakeLists.txt'),
  _ScanRoot('linux/runner/my_application.cc'),
  _ScanRoot('windows/CMakeLists.txt'),
  _ScanRoot('windows/installer/fushi.iss'),
  _ScanRoot('ios/Runner.xcodeproj/project.pbxproj'),
  _ScanRoot('macos/Runner/Configs/AppInfo.xcconfig'),
  _ScanRoot('../melos.yaml'),
];

/// 运维 / 测试 / 发布脚本：只扫 A（应用身份）与 B（仓库身份）——这两条是「打空」
/// 的根源；C 不扫，因为这些脚本里合法存在大量外部真名（Magpie 资产、临时目录、
/// 远端 Mac 克隆根等），逐条豁免只会把守卫变成豁免表。
const List<_ScanRoot> _scriptRoots = <_ScanRoot>[
  _ScanRoot('../ci', extensions: <String>{'.sh'}),
  _ScanRoot('../tool', extensions: <String>{'.sh', '.ps1', '.py'}),
  _ScanRoot('../tools', extensions: <String>{'.sh', '.ps1'}),
  _ScanRoot('../scripts', extensions: <String>{'.py'}),
  _ScanRoot('../.codex-test/tools', extensions: <String>{'.ps1'}),
  _ScanRoot('tool', extensions: <String>{'.ps1', '.sh'}),
  _ScanRoot('../run.sh'),
  _ScanRoot('../run.ps1'),
];

/// A：非当前 applicationId 的 app.<x>.reader 字面量。
final List<_Exemption> _appIdExemptions = <_Exemption>[
  _Exemption(
    pathSuffix: 'android/app/src/main/AndroidManifest.xml',
    context: null,
    reason: 'queries/package 声明的是**旧包**：Android 11+ 包可见性下，迁移导入器要 '
        'getPackageInfo 查到老包才能探测/拉起/引导卸载。这里写新包名等于自己查自己。',
  ),
  _Exemption(
    pathSuffix: 'android/app/proguard-rules.pro',
    context: null,
    reason: 'keep 规则上方记载「旧包名 keep 规则匹配零个类 → R8 混淆全 app → 启动即'
        '闪退」的根因叙述，旧包名是叙述本体；规则本身由 '
        'android_app_package_keep_rule_guard_test 从 build.gradle 反推校验。',
  ),
];

/// B：owner 相同但仓库不是当前仓库的 slug。
final List<_Exemption> _repoSlugExemptions = <_Exemption>[
  _Exemption(
    pathSuffix: 'tools/build_magpie_slim.ps1',
    context: null,
    reason: 'hajisensai/Magpie 是外部 fork 仓库真名（slim 包从它的 release 下载），'
        '与本仓改名无关。',
  ),
];

/// C：构建/打包配置里的旧代号词根。
final List<_Exemption> _legacyWordExemptions = <_Exemption>[
  _Exemption(
    pathSuffix: 'android/app/src/main/AndroidManifest.xml',
    context: null,
    reason: '同 A：queries 的旧包声明与其说明注释。',
  ),
  _Exemption(
    pathSuffix: 'android/app/proguard-rules.pro',
    context: null,
    reason: '同 A：keep 规则的根因叙述注释。',
  ),
  _Exemption(
    pathSuffix: 'windows/installer/fushi.iss',
    context: null,
    reason: '安装器的**旧名清理**段：删旧 exe / 旧快捷方式 / 旧 ProgID / 旧互斥量，'
        '旧字面量正是这件事本身。其正确性由 '
        'windows_installer_legacy_cleanup_guard_test 单独守。',
  ),
  _Exemption(
    pathSuffix: 'windows/CMakeLists.txt',
    context: RegExp('Magpie-hibiki-slim'),
    reason: 'Magpie-hibiki-slim-x64.zip 是外部 fork 仓库的 release 资产真名（随包'
        '归档），不是本仓产物名。',
  ),
];

/// listSync 在 Windows 上回 \ 分隔的路径；豁免表与报错统一用正斜杠。
String _normalize(String path) => path.replaceAll(Platform.pathSeparator, '/');

Iterable<File> _filesOf(List<_ScanRoot> roots) sync* {
  for (final _ScanRoot root in roots) {
    if (root.extensions == null) {
      final File file = File(root.path);
      if (!file.existsSync()) {
        throw StateError('扫描面缺失：${root.path}（文件被改名/移动了？请同步更新本守卫——'
            '静默跳过等于把这个文件永久移出守卫范围）');
      }
      yield file;
      continue;
    }
    final Directory dir = Directory(root.path);
    if (!dir.existsSync()) {
      throw StateError('扫描根缺失：${root.path}（目录被改名/移动了？请同步更新本守卫——'
          '静默跳过等于把整棵目录永久移出守卫范围）');
    }
    yield* dir.listSync(recursive: true).whereType<File>().where((File f) {
      final String path = _normalize(f.path);
      final int dot = path.lastIndexOf('.');
      return dot >= 0 && root.extensions!.contains(path.substring(dot));
    });
  }
}

/// 一次命中：文件、行号、整行文本（行级 context 判定用）、匹配串。
class _Hit {
  const _Hit(this.path, this.line, this.text, this.match);

  final String path;
  final int line;
  final String text;
  final String match;

  @override
  String toString() => '$path:$line -> $match    | $text';
}

List<_Hit> _collect(Iterable<File> files, RegExp pattern,
    {bool Function(String match)? isViolation}) {
  final List<_Hit> hits = <_Hit>[];
  for (final File f in files) {
    final String path = _normalize(f.path);
    final List<String> lines = f.readAsStringSync().split('\n');
    for (int i = 0; i < lines.length; i++) {
      for (final RegExpMatch m in pattern.allMatches(lines[i])) {
        final String matched = m.group(0)!;
        if (isViolation != null && !isViolation(matched)) continue;
        hits.add(_Hit(path, i + 1, lines[i].trim(), matched));
      }
    }
  }
  return hits;
}

/// 按豁免表分流：违规清单 + 每条豁免的真实命中数（过期检测用）。
class _Partition {
  const _Partition(this.violations, this.exemptionHits);

  final List<_Hit> violations;
  final List<int> exemptionHits;
}

_Partition _partition(List<_Hit> hits, List<_Exemption> exemptions) {
  final List<_Hit> violations = <_Hit>[];
  final List<int> counts = List<int>.filled(exemptions.length, 0);
  for (final _Hit hit in hits) {
    bool exempted = false;
    for (int i = 0; i < exemptions.length; i++) {
      final _Exemption e = exemptions[i];
      if (!hit.path.endsWith(e.pathSuffix)) continue;
      if (e.context != null && !e.context!.hasMatch(hit.text)) continue;
      counts[i]++;
      exempted = true;
      break;
    }
    if (!exempted) violations.add(hit);
  }
  return _Partition(violations, counts);
}

void _expectNoStaleExemptions(
    List<_Exemption> exemptions, List<int> counts, String label) {
  final List<String> stale = <String>[];
  for (int i = 0; i < exemptions.length; i++) {
    if (counts[i] != 0) continue;
    final _Exemption e = exemptions[i];
    final String ctx = e.context == null ? '' : ' / ${e.context!.pattern}';
    stale.add('[$label] ${e.pathSuffix}$ctx（已无真实命中）'
        '\n        原豁免理由：${e.reason}');
  }
  expect(stale, isEmpty,
      reason: '白名单条目已无真实命中，请连同豁免一起删掉（防止豁免退化成盲区）：\n'
          '${stale.join('\n')}');
}

String _requiredMatch(File file, RegExp pattern, String what) {
  final RegExpMatch? m = pattern.firstMatch(file.readAsStringSync());
  if (m == null) {
    throw StateError('真相源 ${_normalize(file.path)} 里读不到 $what——它被改格式/挪走了？'
        '本守卫的全部断言都从它反推，读不到就必须停下来修守卫，而不是放行。');
  }
  return m.group(1)!;
}

void main() {
  // ---- 真相源 ----------------------------------------------------------
  final String applicationId = _requiredMatch(
    File('android/app/build.gradle'),
    RegExp(r'^\s*applicationId\s+"([^"]+)"', multiLine: true),
    'applicationId',
  );
  final String repoSlug = _requiredMatch(
    File('lib/src/utils/misc/update_checker_release.dart'),
    RegExp(r"kGitHubRepo\s*=\s*'([^']+)'"),
    'kGitHubRepo',
  );
  final String repoOwner = repoSlug.split('/').first;
  final String repoName = repoSlug.split('/').last;

  late final List<File> buildConfigFiles;
  late final List<File> scriptFiles;

  setUpAll(() {
    buildConfigFiles = _filesOf(_buildConfigRoots).toList();
    scriptFiles = _filesOf(_scriptRoots).toList();
  });

  test('真相源自洽：applicationId 是 app.<brand>.reader，且与仓库名同 brand', () {
    // 三条禁模式都靠这两个真值反推；它们自己变形了守卫就失去意义。
    expect(
        RegExp(r'^app\.[A-Za-z0-9_]+\.reader$').hasMatch(applicationId), isTrue,
        reason: 'applicationId 形态变了（当前 $applicationId），A 条的正则窗口需要同步。');
    expect(repoSlug.split('/'), hasLength(2),
        reason: 'kGitHubRepo 必须是 owner/repo（当前 $repoSlug）。');
    expect(applicationId.split('.')[1].toLowerCase(), repoName.toLowerCase(),
        reason: 'applicationId 的品牌段（${applicationId.split('.')[1]}）与 GitHub 仓库名'
            '（$repoName）不一致——改名只做了一半，或本守卫的真相源选错了。');
  });

  test('A：脚本与构建配置里不得出现失效的 app.<x>.reader 包名', () {
    final List<_Hit> hits = _collect(
      <File>[...buildConfigFiles, ...scriptFiles],
      RegExp(r'app\.[A-Za-z0-9_]+\.reader'),
      isViolation: (String m) => m != applicationId,
    );
    final _Partition result = _partition(hits, _appIdExemptions);
    expect(result.violations, isEmpty,
        reason: '这些位置命名的应用包不是当前 applicationId（$applicationId）。adb '
            'run-as / pm / am、MethodChannel 前缀、R8 keep 规则都按包名精确匹配，'
            '错一个字就是「不报错但一个都匹配不到」：\n'
            '${result.violations.join('\n')}');
    _expectNoStaleExemptions(_appIdExemptions, result.exemptionHits, 'A');
  });

  test('B：脚本与构建配置里的 GitHub 仓库 slug 必须是当前仓库', () {
    final List<_Hit> hits = _collect(
      <File>[...buildConfigFiles, ...scriptFiles],
      RegExp('$repoOwner/[A-Za-z0-9_.-]+'),
      isViolation: (String m) =>
          m.split('/').last.toLowerCase() != repoName.toLowerCase(),
    );
    final _Partition result = _partition(hits, _repoSlugExemptions);
    expect(result.violations, isEmpty,
        reason: '这些位置引用的仓库不是当前仓库（$repoSlug）。gh / curl 打到改名前的 '
            'slug 只会拿到 404 或重定向，发版与巡检脚本会静默空跑：\n'
            '${result.violations.join('\n')}');
    _expectNoStaleExemptions(_repoSlugExemptions, result.exemptionHits, 'B');
  });

  test('C：构建/打包配置里不得残留旧代号词根', () {
    final List<_Hit> hits = _collect(
      buildConfigFiles,
      RegExp('hibiki|hoshi', caseSensitive: false),
    );
    final _Partition result = _partition(hits, _legacyWordExemptions);
    expect(result.violations, isEmpty,
        reason: '产物名、二进制名、窗口标题、application id、安装器与 workspace 元数据'
            '都在这些文件里定；旧代号留在这里不会让编译或测试红，只会让发出去的包'
            '带着旧身份。如属冻结契约/外部真名，请按「文件 + 行级 context」加豁免'
            '并写理由：\n${result.violations.join('\n')}');
    _expectNoStaleExemptions(_legacyWordExemptions, result.exemptionHits, 'C');
  });
}
