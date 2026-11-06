// 原生依赖（Rust crate + 手写清单里的 C/C++ 库）许可汇编生成器。
//
// App 的「开源许可」页走 Flutter `LicenseRegistry`：pub 包自动收录，原生库没有自动机制。
// 本工具把**实际随包**的原生第三方许可原文汇编进 `assets/licenses/native/`，
// `injectAssetLicenses()`（`lib/src/models/asset_licenses.dart`）按生成的 `index.json` 注册。
//
// 用法（在 `fushi/` 下，需要 cargo 与网络——cargo metadata 要拉 crate 源码）：
//   dart run tool/native_licenses.dart
//
// 输入：
//   * `native/*/Cargo.lock`（自动发现：新加一个 Rust 原生模块，重跑即覆盖，无需改本工具）；
//   * `native/third_party_licenses/manifest.json`：
//     - `rust`：目标平台 / 预备步骤配置，以及 `licenseTexts`（crates.io 包内没有许可文件的
//       crate，登记从上游对应提交取来的原文；没登记的退到 SPDX 标准文本并在产物
//       `pendingUpstreamLicense` 与运行输出里列出）；
//     - `cxx`：本仓 native 模块编进去的 C/C++ 库手写清单；
//     - `prebuilt`：pub 包下载 / 打包进 app 的预编译原生库（libmpv 及其依赖、onnxruntime、
//       sqlite3、pdfium 等）——Flutter `LicenseRegistry` 只收 pub 包自己的 LICENSE，不含这些；
//     许可原文路径指向 vendored 源码或 `native/third_party_licenses/texts/`。
//
// Rust「随包」的判定：从每个 native crate 根出发，只沿 **normal** 依赖边走
// （`cargo metadata` 的 `dep_kinds[].kind == null`），且按随包的 target triple
// 过滤（`--filter-platform`）。不走 dev 边（只编测试）、不走 build 边（build.rs 的依赖
// 只在宿主上编译运行、不链进产物）；遇到过程宏（target kind `proc-macro`）不收录也不
// 往下走——过程宏是编译期在宿主上加载的插件，产物里只有它展开出的代码，不含它本身。
// `native/<模块>/` 自身（本仓第一方代码）不收录。
//
// 产物里记下每个输入文件的 sha256（`inputs`），守卫
// `test/build/native_license_registry_guard_test.dart` 不需要 cargo，只比哈希：
// Cargo.lock / Cargo.toml / 清单 / 清单引用的许可原文任何一个变了，守卫就红并提示重跑本工具。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 生成产物所在目录（相对 `fushi/`）。
const String kNativeLicenseAssetDir = 'assets/licenses/native';

/// 生成的索引文件名。
const String kNativeLicenseIndexName = 'index.json';

/// 手写清单（相对仓库根）。
const String kNativeLicenseManifestPath =
    'native/third_party_licenses/manifest.json';

/// 守卫与报错里提示的重跑命令。
const String kNativeLicenseRegenerateCommand =
    'cd fushi && dart run tool/native_licenses.dart';

/// 文件内容指纹：统一换行后取 sha256（Windows 检出可能是 CRLF，CI 是 LF）。
String nativeLicenseFingerprint(String content) =>
    sha256.convert(utf8.encode(content.replaceAll('\r\n', '\n'))).toString();

/// 列出参与指纹的全部输入文件（相对仓库根、`/` 分隔、已排序）。
///
/// `native/*/Cargo.lock` 及其同目录 `Cargo.toml` 自动发现；外加手写清单本身与
/// 清单里每条 C/C++ 条目引用的许可原文。
List<String> nativeLicenseInputPaths(Directory repoRoot) {
  final Set<String> paths = <String>{kNativeLicenseManifestPath};
  for (final String crate in discoverNativeCargoCrates(repoRoot)) {
    paths
      ..add('native/$crate/Cargo.lock')
      ..add('native/$crate/Cargo.toml');
  }
  final Map<String, dynamic> manifest = _readManifest(repoRoot);
  for (final String section in kNativeLicenseManualSections) {
    for (final dynamic raw
        in (manifest[section] as List<dynamic>?) ?? const <dynamic>[]) {
      for (final dynamic text
          in (raw as Map<String, dynamic>)['texts'] as List<dynamic>) {
        paths.add(text as String);
      }
    }
  }
  for (final dynamic raw in _rustLicenseTexts(manifest).values) {
    for (final dynamic text
        in ((raw as Map<String, dynamic>)['texts'] as List<dynamic>?) ??
            const <dynamic>[]) {
      paths.add(text as String);
    }
  }
  return paths.toList()..sort();
}

/// 清单里手写条目的分节：`cxx` 是本仓 native 模块编进去的 C/C++ 库，`prebuilt` 是
/// pub 包下载 / 打包进 app 的预编译原生库（Flutter `LicenseRegistry` 只收 pub 包自己的
/// LICENSE，不含它们随带的二进制）。两节条目格式相同。
const List<String> kNativeLicenseManualSections = <String>['cxx', 'prebuilt'];

/// 清单 `rust.licenseTexts`：crates.io 包内没有许可文件的 crate，按 `name@version`
/// 登记从上游仓库对应提交取来的许可原文（`texts`）；上游原文缺许可正文时
/// `appendSpdx: true` 追加 SPDX 标准正文。
Map<String, dynamic> _rustLicenseTexts(Map<String, dynamic> manifest) =>
    ((manifest['rust'] as Map<String, dynamic>)['licenseTexts']
        as Map<String, dynamic>?) ??
    <String, dynamic>{};

/// 读许可原文。个别上游文件不是 UTF-8（例如 Windows-1252 的弯引号），按 Windows-1252 兜底解码。
String readNativeLicenseText(File file) {
  final List<int> bytes = file.readAsBytesSync();
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return String.fromCharCodes(<int>[
      for (final int b in bytes)
        b >= 0x80 && b < 0xA0 ? _cp1252High[b - 0x80] : b,
    ]);
  }
}

/// Windows-1252 的 0x80–0x9F（未定义的位置按 Latin-1 原样保留）。
const List<int> _cp1252High = <int>[
  0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F, //
  0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, //
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178, //
];

/// `native/` 下带 `Cargo.lock` 的一级目录名（已排序）。
List<String> discoverNativeCargoCrates(Directory repoRoot) {
  final Directory native = Directory('${repoRoot.path}/native');
  final List<String> crates = <String>[
    for (final FileSystemEntity e in native.listSync())
      if (e is Directory && File('${e.path}/Cargo.lock').existsSync())
        e.uri.pathSegments.where((String s) => s.isNotEmpty).last,
  ]..sort();
  return crates;
}

/// 当前各输入文件的指纹。
Map<String, String> computeNativeLicenseInputs(Directory repoRoot) =>
    <String, String>{
      for (final String p in nativeLicenseInputPaths(repoRoot))
        p: nativeLicenseFingerprint(
          readNativeLicenseText(File('${repoRoot.path}/$p')),
        ),
    };

Map<String, dynamic> _readManifest(Directory repoRoot) =>
    jsonDecode(
          File(
            '${repoRoot.path}/$kNativeLicenseManifestPath',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

/// 一个随包第三方组件（crate 或 C/C++ 库）。
class _Component {
  _Component({
    required this.name,
    required this.version,
    required this.license,
    required this.origin,
  });

  final String name;
  final String version;
  final String license;
  final Set<String> origin;
  final List<String> textHashes = <String>[];
  String textSource = 'package';
  String? note;
  String? source;
  List<String>? platforms;
}

final RegExp _licenseFileName = RegExp(
  r'^(un)?licen[cs]e|^copying|^copyright|^notice',
  caseSensitive: false,
);

String _normalizeText(String text) {
  final List<String> lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((String l) => l.trimRight())
      .toList();
  return '${lines.join('\n').trim()}\n';
}

Future<void> main(List<String> args) async {
  final Directory fushiDir = Directory.current;
  final Directory repoRoot = fushiDir.parent;
  if (!File('${repoRoot.path}/$kNativeLicenseManifestPath').existsSync()) {
    stderr.writeln('请在 fushi/ 下运行（找不到 $kNativeLicenseManifestPath）。');
    exitCode = 2;
    return;
  }
  final Map<String, dynamic> manifest = _readManifest(repoRoot);
  final Map<String, dynamic> rust = manifest['rust'] as Map<String, dynamic>;
  final List<String> defaultTargets = (rust['defaultTargets'] as List<dynamic>)
      .cast<String>();
  final Map<String, dynamic> crateConfig =
      (rust['crates'] as Map<String, dynamic>?) ?? <String, dynamic>{};

  final Map<String, String> texts = <String, String>{};
  final Map<String, _Component> components = <String, _Component>{};
  final List<String> missingSpdx = <String>[];
  final Map<String, dynamic> licenseTexts = _rustLicenseTexts(manifest);
  final Set<String> usedLicenseTexts = <String>{};
  final List<String> pendingUpstream = <String>[];

  String addText(String raw) {
    final String text = _normalizeText(raw);
    final String hash = nativeLicenseFingerprint(text).substring(0, 16);
    texts[hash] = text;
    return hash;
  }

  final List<String> crates = discoverNativeCargoCrates(repoRoot);
  final Set<String> firstPartyManifests = <String>{
    for (final String c in crates)
      _canon('${repoRoot.path}/native/$c/Cargo.toml'),
  };

  for (final String crate in crates) {
    final Directory crateDir = Directory('${repoRoot.path}/native/$crate');
    final Map<String, dynamic> cfg =
        (crateConfig[crate] as Map<String, dynamic>?) ?? <String, dynamic>{};
    await _runPrepare(crateDir, cfg['prepare'] as Map<String, dynamic>?);
    final List<String> targets =
        (cfg['targets'] as List<dynamic>?)?.cast<String>() ?? defaultTargets;
    stdout.writeln('[rust] $crate  targets=${targets.join(',')}');
    final ProcessResult res = await Process.run('cargo', <String>[
      'metadata',
      '--locked',
      '--format-version',
      '1',
      for (final String t in targets) ...<String>['--filter-platform', t],
    ], workingDirectory: crateDir.path);
    if (res.exitCode != 0) {
      stderr.writeln('cargo metadata 失败（$crate）：\n${res.stderr}');
      exitCode = 1;
      return;
    }
    final Map<String, dynamic> meta =
        jsonDecode(res.stdout as String) as Map<String, dynamic>;
    final Map<String, Map<String, dynamic>> packages =
        <String, Map<String, dynamic>>{
          for (final dynamic p in meta['packages'] as List<dynamic>)
            (p as Map<String, dynamic>)['id'] as String: p,
        };
    final Map<String, dynamic> resolve =
        meta['resolve'] as Map<String, dynamic>;
    final Map<String, Map<String, dynamic>> nodes =
        <String, Map<String, dynamic>>{
          for (final dynamic n in resolve['nodes'] as List<dynamic>)
            (n as Map<String, dynamic>)['id'] as String: n,
        };
    final String root = resolve['root'] as String;
    final Set<String> seen = <String>{root};
    final List<String> queue = <String>[root];
    while (queue.isNotEmpty) {
      final String id = queue.removeLast();
      for (final dynamic d in nodes[id]!['deps'] as List<dynamic>) {
        final Map<String, dynamic> dep = d as Map<String, dynamic>;
        final bool normal = (dep['dep_kinds'] as List<dynamic>).any(
          (dynamic k) => (k as Map<String, dynamic>)['kind'] == null,
        );
        if (!normal) continue;
        final String pkgId = dep['pkg'] as String;
        final Map<String, dynamic> pkg = packages[pkgId]!;
        final bool procMacro = (pkg['targets'] as List<dynamic>).any(
          (dynamic t) => ((t as Map<String, dynamic>)['kind'] as List<dynamic>)
              .contains('proc-macro'),
        );
        if (procMacro) continue;
        if (seen.add(pkgId)) queue.add(pkgId);
      }
    }
    for (final String id in seen) {
      final Map<String, dynamic> pkg = packages[id]!;
      final String manifestPath = pkg['manifest_path'] as String;
      if (firstPartyManifests.contains(_canon(manifestPath))) continue;
      final String name = pkg['name'] as String;
      final String version = pkg['version'] as String;
      final String key = 'rust:$name@$version';
      final _Component? existing = components[key];
      if (existing != null) {
        existing.origin.add(crate);
        continue;
      }
      final _Component c = _Component(
        name: name,
        version: version,
        license: (pkg['license'] as String?) ?? '',
        origin: <String>{crate},
      );
      components[key] = c;
      final List<File> files = _rustLicenseFiles(pkg);
      if (files.isNotEmpty) {
        for (final File f in files) {
          c.textHashes.add(addText(readNativeLicenseText(f)));
        }
        continue;
      }
      // 包内没有许可文件：先找清单里登记的上游原文，没有才退到 SPDX 标准文本。
      final String authors = (pkg['authors'] as List<dynamic>).join(', ');
      final Map<String, dynamic>? upstream =
          licenseTexts['$name@$version'] as Map<String, dynamic>?;
      bool appendSpdx = true;
      if (upstream != null) {
        usedLicenseTexts.add('$name@$version');
        final List<String> paths =
            ((upstream['texts'] as List<dynamic>?) ?? const <dynamic>[])
                .cast<String>();
        for (final String t in paths) {
          c.textHashes.add(
            addText(readNativeLicenseText(File('${repoRoot.path}/$t'))),
          );
        }
        appendSpdx = upstream['appendSpdx'] == true || paths.isEmpty;
        c.textSource = paths.isEmpty
            ? 'spdx'
            : (appendSpdx ? 'upstream+spdx' : 'upstream');
        c.note = <String>[
          if (upstream['upstream'] != null && paths.isNotEmpty)
            'crate 包内没有许可文件；原文取自上游 ${upstream['upstream']}',
          if (upstream['note'] != null) upstream['note'] as String,
          if (appendSpdx) '附 ${c.license} 的 SPDX 标准正文；crate 作者：$authors',
        ].join('。');
      } else {
        c.textSource = 'spdx-fallback';
        c.note =
            'crate 包内没有许可文件；以下是 ${c.license} 的标准文本，'
            '版权人见 crate 作者：$authors';
        pendingUpstream.add('$name@$version');
      }
      if (!appendSpdx) continue;
      for (final String id in _spdxIds(c.license)) {
        final File spdx = File(
          '${repoRoot.path}/native/third_party_licenses/spdx/$id.txt',
        );
        if (!spdx.existsSync()) {
          missingSpdx.add(
            '$name $version 需要 native/third_party_licenses/spdx/$id.txt',
          );
          continue;
        }
        c.textHashes.add(addText(readNativeLicenseText(spdx)));
      }
    }
  }

  final List<String> staleLicenseTexts =
      licenseTexts.keys
          .where((String k) => !usedLicenseTexts.contains(k))
          .toList()
        ..sort();
  if (staleLicenseTexts.isNotEmpty) {
    stderr.writeln(
      '清单 rust.licenseTexts 里这些条目没有对上任何「包内无许可文件」的 crate'
      '（版本升了或 crate 已移除 / 新版本包内已带许可）；更新或删掉后重跑：\n'
      '  ${staleLicenseTexts.join('\n  ')}',
    );
    exitCode = 1;
    return;
  }

  if (missingSpdx.isNotEmpty) {
    stderr.writeln(
      '以下 crate 包内没有许可文件，且缺对应的 SPDX 标准文本；补齐后重跑：\n'
      '${missingSpdx.join('\n')}',
    );
    exitCode = 1;
    return;
  }

  for (final String section in kNativeLicenseManualSections) {
    for (final dynamic raw
        in (manifest[section] as List<dynamic>?) ?? const <dynamic>[]) {
      final Map<String, dynamic> e = raw as Map<String, dynamic>;
      final String name = e['name'] as String;
      final String component = e['component'] as String;
      final _Component c = _Component(
        name: name,
        version: e['version'] as String,
        license: e['license'] as String,
        origin: <String>{component},
      )..textSource = 'manifest';
      c.note = e['note'] as String?;
      c.source = e['source'] as String?;
      c.platforms = (e['platforms'] as List<dynamic>?)?.cast<String>();
      for (final dynamic t in e['texts'] as List<dynamic>) {
        final File f = File('${repoRoot.path}/$t');
        if (!f.existsSync()) {
          stderr.writeln('清单条目 $name 引用的许可原文不存在：$t');
          exitCode = 1;
          return;
        }
        c.textHashes.add(addText(readNativeLicenseText(f)));
      }
      final String key = '$section:$component:$name@${c.version}';
      if (components.containsKey(key)) {
        stderr.writeln('清单 $section 里有重复条目：$component $name ${c.version}');
        exitCode = 1;
        return;
      }
      components[key] = c;
    }
  }

  // 按许可文本分组：一份文本一个文件，列出用它的全部组件名。
  final Map<String, Set<String>> byText = <String, Set<String>>{};
  for (final _Component c in components.values) {
    for (final String h in c.textHashes) {
      (byText[h] ??= <String>{}).add(c.name);
    }
  }

  final Directory outDir = Directory(
    '${fushiDir.path}/$kNativeLicenseAssetDir',
  );
  if (outDir.existsSync()) outDir.deleteSync(recursive: true);
  outDir.createSync(recursive: true);
  final List<String> hashes = texts.keys.toList()..sort();
  for (final String h in hashes) {
    File('${outDir.path}/$h.txt').writeAsStringSync(texts[h]!);
  }

  final List<_Component> sorted = components.values.toList()
    ..sort((_Component a, _Component b) {
      final int n = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (n != 0) return n;
      final int v = a.version.compareTo(b.version);
      return v != 0 ? v : a.origin.join(',').compareTo(b.origin.join(','));
    });
  final Map<String, dynamic> index = <String, dynamic>{
    'schema': 1,
    'generatedBy': 'fushi/tool/native_licenses.dart',
    'regenerate': kNativeLicenseRegenerateCommand,
    'inputs': computeNativeLicenseInputs(repoRoot),
    // 包内没有许可文件、清单 rust.licenseTexts 也还没登记上游原文的 crate：
    // 目前只附 SPDX 标准文本（缺版权行）。补法见清单的 `$comment`。
    'pendingUpstreamLicense': (pendingUpstream..sort()),
    'licenses': <Map<String, dynamic>>[
      for (final String h in hashes)
        <String, dynamic>{
          'file': '$h.txt',
          'packages': (byText[h]!.toList()
            ..sort(
              (String a, String b) =>
                  a.toLowerCase().compareTo(b.toLowerCase()),
            )),
        },
    ],
    'components': <Map<String, dynamic>>[
      for (final _Component c in sorted)
        <String, dynamic>{
          'name': c.name,
          'version': c.version,
          'license': c.license,
          'origin': (c.origin.toList()..sort()),
          'textSource': c.textSource,
          'texts': <String>{
            for (final String h in c.textHashes) '$h.txt',
          }.toList(),
          if (c.platforms != null) 'platforms': c.platforms,
          if (c.source != null) 'source': c.source,
          if (c.note != null) 'note': c.note,
        },
    ],
  };
  File(
    '${outDir.path}/$kNativeLicenseIndexName',
  ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(index)}\n');

  int count(String prefix) =>
      components.keys.where((String k) => k.startsWith(prefix)).length;
  stdout.writeln(
    '完成：Rust crate ${count('rust:')} 个、C/C++ 条目 ${count('cxx:')} 个、'
    'pub 包预编译库条目 ${count('prebuilt:')} 个、去重后许可文本 ${hashes.length} 份。',
  );
  if (pendingUpstream.isNotEmpty) {
    stdout.writeln(
      '注意：${pendingUpstream.length} 个 crate 包内没有许可文件、只附了 SPDX 标准文本'
      '（缺版权行）。从上游对应提交取原文放进 native/third_party_licenses/texts/crates/，'
      '再登记到清单 rust.licenseTexts：\n  ${pendingUpstream.join('\n  ')}',
    );
  }
}

/// 某些 native crate 依赖构建时才检出的源码（例如 fushi_anki_sync 的 `.anki-src`）。
/// 清单里写 `prepare: {ifMissing, command}`，缺目录时先执行 command（在 crate 目录下）。
Future<void> _runPrepare(
  Directory crateDir,
  Map<String, dynamic>? prepare,
) async {
  if (prepare == null) return;
  final String marker = prepare['ifMissing'] as String;
  if (Directory('${crateDir.path}/$marker').existsSync()) return;
  final List<String> cmd = (prepare['command'] as List<dynamic>).cast<String>();
  stdout.writeln('[prepare] ${crateDir.path}: ${cmd.join(' ')}');
  final Process p = await Process.start(
    cmd.first,
    cmd.sublist(1),
    workingDirectory: crateDir.path,
    mode: ProcessStartMode.inheritStdio,
  );
  if (await p.exitCode != 0) {
    throw ProcessException(cmd.first, cmd.sublist(1), 'prepare 失败');
  }
}

/// crate 自带的许可文件：crate 目录顶层与 `LICENSES/` 下的 LICENSE* / COPYING* /
/// COPYRIGHT* / NOTICE*，外加 `license_file`。git / path 依赖若子目录里没有，往上找到
/// 仓库检出根（含 `.git` 的目录）为止——workspace 成员的许可常只放在仓库根。
List<File> _rustLicenseFiles(Map<String, dynamic> pkg) {
  final File manifest = File(pkg['manifest_path'] as String);
  Directory dir = manifest.parent;
  final String? licenseFile = pkg['license_file'] as String?;
  final bool registry = ((pkg['source'] as String?) ?? '').startsWith(
    'registry+',
  );
  for (int depth = 0; depth < 6; depth++) {
    final List<File> found = <File>[
      if (licenseFile != null && depth == 0)
        if (File('${dir.path}/$licenseFile').existsSync())
          File('${dir.path}/$licenseFile'),
      ..._licenseFilesIn(dir),
      if (Directory('${dir.path}/LICENSES').existsSync())
        ..._licenseFilesIn(Directory('${dir.path}/LICENSES'), any: true),
    ];
    final Map<String, File> unique = <String, File>{
      for (final File f in found) _canon(f.path): f,
    };
    if (unique.isNotEmpty) {
      return unique.values.toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
    }
    if (registry) break;
    if (Directory('${dir.path}/.git').existsSync() ||
        File('${dir.path}/.git').existsSync()) {
      break;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return <File>[];
}

List<File> _licenseFilesIn(Directory dir, {bool any = false}) => <File>[
  for (final FileSystemEntity e in dir.listSync())
    if (e is File &&
        (any || _licenseFileName.hasMatch(e.uri.pathSegments.last)))
      e,
];

/// 从 SPDX 表达式里取出许可 ID（去掉 OR / AND / WITH 与括号）。
List<String> _spdxIds(String expression) => expression
    .replaceAll('(', ' ')
    .replaceAll(')', ' ')
    .replaceAll('/', ' OR ')
    .split(RegExp(r'\s+'))
    .where((String s) => s.isNotEmpty && s != 'OR' && s != 'AND' && s != 'WITH')
    .toSet()
    .toList();

String _canon(String path) =>
    File(path).absolute.path.replaceAll('\\', '/').toLowerCase();
