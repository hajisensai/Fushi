import 'dart:io';

import 'package:test/test.dart';

/// drift 运行时与 drift_dev 生成器必须成对钉住（BUG-5615）。
///
/// `packages/fushi_core/lib/src/database/database.g.dart` 是 drift_dev 生成的，里面调用
/// drift 运行时的内部 API（`$_getPrefetchedDataByColumns` 之类）。drift_dev 自己声明的
/// drift 约束并不可靠：drift_dev 2.35.3 声明 `drift >=2.30.0 <2.36.0`，生成的码却在
/// 本仓钉住的 drift 2.33.0 上 61 处编不过。从前 drift_dev 写的是 `^2.23.0`，工作区一解析
/// 就拿到 2.35.3，普通的 `dart run build_runner build` 产物不可用，只能在隔离副本里换
/// 版本生成再拷回 `.g.dart`。
///
/// 守的事实：
/// 1. 全仓（根 + app + packages/*）的 `drift:` 约束只有一个值，且是单个 minor 系列；
/// 2. `drift_dev` 只在 `packages/fushi_core` 声明（唯一带 Drift 表的包），钉精确版本；
/// 3. 这个精确版本就是 [verifiedDriftDevForDrift] 里为该 drift 系列登记过的那一版——
///    登记的意思是「在这对版本上跑过 codegen，产物与入库的 `.g.dart` 一致且
///    `dart analyze packages/fushi_core` 零错误」；
/// 4. `pubspec.lock` 实际解析结果与上面一致。
///
/// 升 drift：先改 drift 约束，在 packages/fushi_core 下跑 codegen + analyze，选出能编过的
/// drift_dev，再同时改 fushi_core 的 drift_dev 钉版与这里的登记表。
void main() {
  /// drift minor 系列 → 在该系列上验证过 codegen 的 drift_dev 精确版本。
  const Map<String, String> verifiedDriftDevForDrift = <String, String>{
    // drift_dev 2.33.x 要 analyzer <13，与工作区 analyzer 13 冲突；2.35.x 生成的码
    // 依赖 drift 2.35 运行时。
    '2.33': '2.34.5',
  };

  /// 测试的 cwd 恒为 `fushi/`，仓库根就是它的父目录（理由见
  /// git_dep_sha_single_source_guard_test.dart 的 repoRoot）。
  final Directory root = Directory.current.parent;

  String rel(File file) =>
      file.path.replaceAll(r'\', '/').substring(root.path.length + 1);

  List<File> workspacePubspecs() {
    final List<File> files = <File>[
      File('${root.path}/pubspec.yaml'),
      File('${root.path}/fushi/pubspec.yaml'),
    ];
    final Directory packages = Directory('${root.path}/packages');
    for (final FileSystemEntity entity in packages.listSync()) {
      if (entity is! Directory) continue;
      final File pubspec = File('${entity.path}/pubspec.yaml');
      if (pubspec.existsSync()) files.add(pubspec);
    }
    return files;
  }

  /// 抽出 pubspec 里 `  <name>: <约束>` 这种直接声明（含 dependency_overrides）。
  List<String> constraintsFor(File pubspec, String name) {
    final RegExp line = RegExp('^\\s+$name:\\s*(.+?)\\s*\$');
    final List<String> out = <String>[];
    for (final String raw in pubspec.readAsLinesSync()) {
      final RegExpMatch? m = line.firstMatch(raw);
      if (m == null) continue;
      out.add(m.group(1)!.replaceAll('"', '').replaceAll("'", ''));
    }
    return out;
  }

  /// `pubspec.lock` 里 [name] 解析到的版本。
  String lockedVersion(String name) {
    final List<String> lines = File(
      '${root.path}/pubspec.lock',
    ).readAsLinesSync();
    final int start = lines.indexOf('  $name:');
    expect(start, isNot(-1), reason: 'pubspec.lock 里没有 $name');
    for (int i = start + 1; i < lines.length; i++) {
      final String l = lines[i];
      if (!l.startsWith('    ')) break;
      final RegExpMatch? m = RegExp(
        r'^\s+version:\s*"?([^"\s]+)"?',
      ).firstMatch(l);
      if (m != null) return m.group(1)!;
    }
    fail('pubspec.lock 里 $name 没有 version 行');
  }

  test('drift 约束全仓单一值，且是单个 minor 系列', () {
    final Map<String, List<String>> byFile = <String, List<String>>{};
    for (final File pubspec in workspacePubspecs()) {
      final List<String> c = constraintsFor(pubspec, 'drift');
      if (c.isNotEmpty) byFile[rel(pubspec)] = c;
    }
    expect(byFile, isNotEmpty, reason: '一条 drift 声明都没扫到——扫描面空了');
    final Set<String> distinct = byFile.values
        .expand((List<String> c) => c)
        .toSet();
    expect(
      distinct,
      hasLength(1),
      reason: 'drift 约束不一致：\n$byFile\n生成码只对一个 drift 系列验证过。',
    );
    expect(
      RegExp(r'^>=(\d+)\.(\d+)\.0 <\1\.(\d+)\.0$').hasMatch(distinct.single),
      isTrue,
      reason:
          'drift 约束 `${distinct.single}` 不是 `>=X.Y.0 <X.(Y+1).0` 形式——'
          '必须锁在单个 minor 系列，drift_dev 才有确定的配对版本。',
    );
  });

  test('drift_dev 只在 fushi_core 声明，钉精确版本且与 drift 系列配对', () {
    final Map<String, List<String>> byFile = <String, List<String>>{};
    for (final File pubspec in workspacePubspecs()) {
      final List<String> c = constraintsFor(pubspec, 'drift_dev');
      if (c.isNotEmpty) byFile[rel(pubspec)] = c;
    }
    expect(
      byFile.keys,
      <String>['packages/fushi_core/pubspec.yaml'],
      reason:
          'drift_dev 只能在 packages/fushi_core 声明一次（唯一带 Drift 表的包），'
          '实际：$byFile',
    );
    final String pin = byFile.values.single.single;
    expect(
      RegExp(r'^\d+\.\d+\.\d+(\+\d+)?$').hasMatch(pin),
      isTrue,
      reason:
          'drift_dev 必须钉精确版本，不能写 `$pin`：宽松约束会解析到与钉住的 drift '
          '运行时不兼容的生成器（2.35.3 生成的码在 drift 2.33 上编不过）。',
    );

    final String driftConstraint = constraintsFor(
      File('${root.path}/packages/fushi_core/pubspec.yaml'),
      'drift',
    ).single;
    final String series = RegExp(
      r'^>=(\d+\.\d+)\.0',
    ).firstMatch(driftConstraint)!.group(1)!;
    expect(
      verifiedDriftDevForDrift[series],
      pin,
      reason:
          'drift $series 系列登记的已验证 drift_dev 是 '
          '${verifiedDriftDevForDrift[series]}，pubspec 钉的却是 $pin。'
          '换了版本就在 packages/fushi_core 下跑一次 build_runner + dart analyze，'
          '确认生成码能编过后再同步登记表。',
    );
  });

  test('pubspec.lock 的实际解析与钉版一致', () {
    final String pin = constraintsFor(
      File('${root.path}/packages/fushi_core/pubspec.yaml'),
      'drift_dev',
    ).single;
    expect(lockedVersion('drift_dev'), pin);

    final String driftConstraint = constraintsFor(
      File('${root.path}/packages/fushi_core/pubspec.yaml'),
      'drift',
    ).single;
    final String series = RegExp(
      r'^>=(\d+\.\d+)\.0',
    ).firstMatch(driftConstraint)!.group(1)!;
    expect(lockedVersion('drift'), startsWith('$series.'));
  });
}
