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
/// 清单 `prebuilt` 节登记 pub 包随带的预编译原生库（libmpv / onnxruntime / sqlite3 / pdfium 等），
/// `rust.licenseTexts` 登记包内无许可文件的 crate 的上游原文，同样受指纹约束。
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
      // BUG-4694：core.symlinks=false 的 git 检出把符号链接写成内容为目标路径的文本，
      // 生成器若读了它，产物里就是「../LICENSE-MIT」这样一行相对路径。
      expect(
        RegExp(r'^\.\.?[/\\]\S+$').hasMatch(text.trim()),
        isFalse,
        reason:
            '$name 只有一行相对路径（${text.trim()}），是 git 符号链接占位文本不是许可原文；'
            '检查 resolveNativeLicenseSymlink 接线后重跑 $kNativeLicenseRegenerateCommand',
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

  test('手写清单的 cxx / prebuilt 条目字段完整', () {
    final Map<String, dynamic> manifest =
        jsonDecode(File('../$kNativeLicenseManifestPath').readAsStringSync())
            as Map<String, dynamic>;
    const Set<String> platforms = <String>{
      'android',
      'ios',
      'macos',
      'windows',
      'linux',
    };
    for (final String section in kNativeLicenseManualSections) {
      for (final dynamic raw in manifest[section] as List<dynamic>) {
        final Map<String, dynamic> e = raw as Map<String, dynamic>;
        final String id = '$section: ${e['component']} ${e['name']}';
        for (final String field in <String>[
          'name',
          'version',
          'license',
          'component',
        ]) {
          expect(e[field], isA<String>(), reason: '$id 缺 $field');
          expect(
            (e[field] as String).trim(),
            isNotEmpty,
            reason: '$id 的 $field 为空',
          );
        }
        expect(e['texts'] as List<dynamic>, isNotEmpty, reason: '$id 没有许可原文');
        expect(
          platforms,
          containsAll(e['platforms'] as List<dynamic>),
          reason: '$id 的 platforms 只能取 $platforms',
        );
        if (section == 'prebuilt') {
          // 预编译二进制的版本 / 许可必须能追溯到产物来源（下载 URL 的 tag、配方、内嵌版本串）。
          expect(e['source'], isA<String>(), reason: '$id 缺 source（版本与许可的证据）');
        }
      }
    }
  });

  // BUG-4772：发布流程（release-desktop.yml → tools/bundle_7za.ps1）往 Windows 包里放的
  // 7-Zip（7z.exe + 7z.dll，含 unRAR 派生代码）不是 pub 包带的，以前没进这份清单，开源许可页
  // 里看不到它。钉住：脚本钉的版本必须有一条对应的 prebuilt 条目，并带上安装包里的 License.txt。
  test('tools/bundle_7za.ps1 随包的 7-Zip 登记在 prebuilt 里且版本与脚本一致', () {
    final String script = File('../tools/bundle_7za.ps1').readAsStringSync();
    final RegExpMatch? pinned = RegExp(
      r"^\$Version = '([^']+)'",
      multiLine: true,
    ).firstMatch(script);
    expect(pinned, isNotNull, reason: 'tools/bundle_7za.ps1 里找不到 \$Version');
    final Map<String, dynamic> manifest =
        jsonDecode(File('../$kNativeLicenseManifestPath').readAsStringSync())
            as Map<String, dynamic>;
    final List<Map<String, dynamic>> entries = <Map<String, dynamic>>[
      for (final dynamic raw in manifest['prebuilt'] as List<dynamic>)
        if (((raw as Map<String, dynamic>)['component'] as String).contains(
          'tools/bundle_7za.ps1',
        ))
          raw,
    ];
    expect(entries, hasLength(1), reason: '7-Zip 没有（或重复）登记在手写清单的 prebuilt 节');
    final Map<String, dynamic> entry = entries.single;
    expect(entry['version'], pinned!.group(1), reason: '清单版本与脚本钉的版本不一致');
    expect(entry['platforms'], <String>['windows']);
    expect(entry['license'] as String, contains('LGPL-2.1'));
    expect(entry['license'] as String, contains('unRAR'));
    final List<String> texts = (entry['texts'] as List<dynamic>).cast<String>();
    final String licenseTxt = texts.firstWhere(
      (String t) => t.endsWith('/License.txt'),
      orElse: () => '',
    );
    expect(licenseTxt, isNotEmpty, reason: '缺 7-Zip 安装包里的 License.txt 原文');
    expect(
      File('../$licenseTxt').readAsStringSync(),
      contains('unRAR license restriction'),
    );
  });

  // 拍板 left3635（PR #3635 遗留）：新加的随包 crate 包内没有许可文件时，生成器以前只打印
  // 提示、守卫不红，6 个 crate 就这样只附了 SPDX 标准正文、缺版权行。现在 pending 必须为空：
  // 能补上游原文的补原文，上游确实没有版权声明的（rusty-chromaprint、selectors、seahash 等）
  // 在清单 rust.licenseTexts 里显式登记并写明依据，见下一条。
  test('包内无许可文件的 crate 都已登记上游原文或显式豁免（pendingUpstreamLicense 为空）', () {
    final Map<String, dynamic> index = readIndex();
    final List<String> pending =
        (index['pendingUpstreamLicense'] as List<dynamic>).cast<String>();
    expect(
      pending,
      <String>[
        for (final dynamic raw in index['components'] as List<dynamic>)
          if ((raw as Map<String, dynamic>)['textSource'] == 'spdx-fallback')
            '${raw['name']}@${raw['version']}',
      ]..sort(),
      reason:
          'pendingUpstreamLicense 与 components 的 spdx-fallback 条目对不上（产物被手改了？）',
    );
    expect(pending, isEmpty, reason: nativeLicensePendingFixHint(pending));
  });

  test('rust.licenseTexts 每条都写明上游出处；没有版权行可抄的豁免条目必须写依据', () {
    final Map<String, dynamic> manifest =
        jsonDecode(File('../$kNativeLicenseManifestPath').readAsStringSync())
            as Map<String, dynamic>;
    final Map<String, dynamic> licenseTexts =
        ((manifest['rust'] as Map<String, dynamic>)['licenseTexts']
            as Map<String, dynamic>?) ??
        <String, dynamic>{};
    final List<String> problems = <String>[];
    licenseTexts.forEach((String crate, dynamic raw) {
      final Map<String, dynamic> e = raw as Map<String, dynamic>;
      String field(String k) => (e[k] is String) ? (e[k] as String).trim() : '';
      final List<dynamic> texts = (e['texts'] as List<dynamic>?) ?? <dynamic>[];
      if (field('upstream').isEmpty) {
        problems.add('$crate 缺 upstream（查证许可的上游仓库 / 提交）');
      }
      // texts 为空 = 只附 SPDX 标准正文；appendSpdx = 上游文件不带正文。两种都没有现成的
      // 版权行，是显式豁免，必须写清查过什么、为什么没有版权行可抄。
      if ((texts.isEmpty || e['appendSpdx'] == true) && field('note').isEmpty) {
        problems.add('$crate 是豁免条目（texts 为空或 appendSpdx），缺 note 写明依据');
      }
    });
    expect(problems, isEmpty, reason: problems.join('\n'));
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
      containsAll(<String>[
        'fsrs',
        'ruzstd',
        'iroh',
        'libtorrent',
        'mpv (libmpv)',
        'FFmpeg',
      ]),
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
