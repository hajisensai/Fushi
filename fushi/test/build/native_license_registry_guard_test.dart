import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/asset_licenses.dart';

import '../../tool/native_licenses.dart';

/// 原生依赖许可汇编（`assets/licenses/native/`）与开源许可页注册的守卫。
///
/// 为什么钉死：原生 Rust crate / C++ 库没有 pub 那样的自动收录，以前靠手工往
/// `injectAssetLicenses()` 的名字清单里加，`native/fushi_p2p` 一整棵 iroh 依赖树
/// （数百个 crate）就这样一个都没进许可页。现在由 `tool/native_licenses.dart` 生成，
/// 生成时把每个输入（`native/*/Cargo.lock`、`Cargo.toml`、手写清单与它引用的许可原文）
/// 的指纹写进 `index.json`；这里只比指纹、不需要 cargo——改了依赖却没重跑生成就红。
void main() {
  final Directory repoRoot = Directory('..');
  final Directory outDir = Directory(kNativeLicenseAssetDir);
  final File indexFile = File(
    '$kNativeLicenseAssetDir/$kNativeLicenseIndexName',
  );

  Map<String, dynamic> readIndex() =>
      jsonDecode(indexFile.readAsStringSync()) as Map<String, dynamic>;

  test('native/*/Cargo.lock 能被发现（防止扫描路径失效变成空壳）', () {
    expect(
      discoverNativeCargoCrates(repoRoot),
      containsAll(<String>['fushi_fsrs', 'fushi_p2p']),
    );
  });

  test('生成产物与当前 Cargo.lock / Cargo.toml / 手写清单一致', () {
    expect(indexFile.existsSync(), isTrue, reason: '缺 ${indexFile.path}');
    final Map<String, String> recorded = (readIndex()['inputs'] as Map)
        .cast<String, String>();
    final Map<String, String> current = computeNativeLicenseInputs(repoRoot);
    final List<String> drift = <String>[
      for (final String p in <String>{...recorded.keys, ...current.keys})
        if (recorded[p] != current[p])
          '$p（${recorded.containsKey(p) ? (current.containsKey(p) ? '内容变了' : '已删除') : '新增'}）',
    ]..sort();
    expect(
      drift,
      isEmpty,
      reason:
          '原生依赖许可汇编过期了。重跑生成（需要 cargo 与网络）并提交 '
          'fushi/assets/licenses/native/：\n  $kNativeLicenseRegenerateCommand\n'
          '变化的输入：\n  ${drift.join('\n  ')}',
    );
  });

  test('许可文本文件与索引一一对应，且未被手改', () {
    final Map<String, dynamic> index = readIndex();
    final Set<String> referenced = <String>{
      for (final dynamic l in index['licenses'] as List<dynamic>)
        (l as Map<String, dynamic>)['file'] as String,
    };
    final Set<String> onDisk = <String>{
      for (final FileSystemEntity e in outDir.listSync())
        if (e is File && e.path.endsWith('.txt')) e.uri.pathSegments.last,
    };
    expect(onDisk, referenced, reason: '重跑 $kNativeLicenseRegenerateCommand');
    for (final String name in onDisk) {
      final String text = File('${outDir.path}/$name').readAsStringSync();
      // 抓许可原文时撞上反爬挑战页 / 404 页，存下来的是 HTML 而不是许可。
      expect(
        text.toLowerCase(),
        isNot(anyOf(contains('<!doctype html'), contains('<html'))),
        reason: '$name 是网页不是许可原文；检查 native/third_party_licenses/ 里对应的来源文件',
      );
      expect(
        nativeLicenseFingerprint(text).substring(0, 16),
        name.substring(0, name.length - '.txt'.length),
        reason: '$name 内容与文件名指纹不符（被手改了？）；重跑 $kNativeLicenseRegenerateCommand',
      );
    }
    for (final dynamic raw in index['components'] as List<dynamic>) {
      final Map<String, dynamic> c = raw as Map<String, dynamic>;
      final List<String> texts = (c['texts'] as List<dynamic>).cast<String>();
      expect(texts, isNotEmpty, reason: '${c['name']} 没有任何许可文本');
      expect(referenced, containsAll(texts));
    }
  });

  test('pubspec 登记了 assets/licenses/native/', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('    - $kNativeLicenseAssetDir/\n'),
    );
  });

  test('injectAssetLicenses 走 registerAssetLicenses（不再手写名字清单）', () {
    final String src = File(
      'lib/src/models/app_model.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final int start = src.indexOf('Future<void> injectAssetLicenses()');
    expect(start, isNot(-1));
    final String body = src.substring(start, src.indexOf('\n  }\n', start));
    expect(body, contains('registerAssetLicenses(rootBundle)'));
  });

  test('资产许可装配覆盖全部顶层许可文件与全部原生许可汇编', () async {
    final Directory licenses = Directory('assets/licenses');
    final List<String> keys = <String>[
      for (final FileSystemEntity e in licenses.listSync(recursive: true))
        if (e is File) e.path.replaceAll('\\', '/'),
    ];
    final List<LicenseEntry> entries = await loadAssetLicenseEntries(
      assetKeys: keys,
      loadString: (String key) async => File(key).readAsStringSync(),
    );
    final List<String> topLevel = keys.where(isTopLevelAssetLicense).toList();
    final Map<String, dynamic> index = readIndex();
    expect(topLevel, isNotEmpty);
    expect(
      entries,
      hasLength(topLevel.length + (index['licenses'] as List<dynamic>).length),
    );
    final Set<String> packages = <String>{
      for (final LicenseEntry e in entries) ...e.packages,
    };
    expect(packages, containsAll(topLevel.map(assetLicensePackageName)));
    expect(
      packages,
      containsAll(<String>['fsrs', 'ruzstd', 'iroh', 'libtorrent']),
    );
    expect(
      packages,
      containsAll(<String>{
        for (final dynamic c in index['components'] as List<dynamic>)
          (c as Map<String, dynamic>)['name'] as String,
      }),
    );
    for (final LicenseEntry e in entries) {
      expect(
        e.paragraphs.map((LicenseParagraph p) => p.text).join().trim(),
        isNotEmpty,
        reason: '${e.packages} 的许可文本为空',
      );
    }
  });
}
