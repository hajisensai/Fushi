// BUG-1217：随主包发行精简版 Magpie，超分首次使用不再下载 10.79 MB。
//
// 这组测试钉住三件事，每一件都对应一个「不测就会静默坏掉」的点：
// 1. 随包归档的校验强度必须与网络路径**完全一致** —— 随包不等于可信，主包本身可能被改；
// 2. 随包装完必须写来源标记，且该标记必须真的让自更新早退 —— 否则每次开 app 都会下载
//    完整包覆盖精简包，内置的意义当场归零；
// 3. 网络装的要清掉来源标记 —— 否则它会伪装成随包版，从此再也不更新。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/magpie_installer.dart';
import 'package:path/path.dart' as p;

/// 造一个内容合法的最小 Magpie 包：三个必需根文件 + effects 目录。
List<int> _buildFakeMagpieZip() {
  final Archive archive = Archive();
  for (final String name in <String>[
    'Magpie.exe',
    'Microsoft.UI.Xaml.dll',
    'resources.pri',
  ]) {
    final List<int> bytes = utf8.encode('fake-$name');
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  // effects/ 至少要有一个文件，否则解压后目录不存在 → 完整性判据不过。
  final List<int> eff = utf8.encode('// fake effect');
  archive.addFile(ArchiveFile('effects/Lanczos.hlsl', eff.length, eff));
  return ZipEncoder().encode(archive)!;
}

void main() {
  late Directory tmp;
  late Directory bundleDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('magpie_bundle_test_');
    bundleDir = Directory(p.join(tmp.path, kMagpieBundledDirectoryName))
      ..createSync(recursive: true);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  void writeBundle({required String arch, String? shaOverride}) {
    final List<int> zip = _buildFakeMagpieZip();
    final File zipFile =
        File(p.join(bundleDir.path, magpieBundledZipName(arch)))
          ..writeAsBytesSync(zip);
    File('${zipFile.path}.sha256')
        .writeAsStringSync(shaOverride ?? sha256.convert(zip).toString());
  }

  group('随包归档命名与常量契约', () {
    test('随包目录与安装落点不同名', () {
      // 同名会让「发行介质」和「装好的东西」在一个目录里纠缠。
      expect(kMagpieBundledDirectoryName, isNot(kMagpieInstallDirName));
    });

    test('随包文件名带 slim，与 fork release 的完整包区分开', () {
      expect(magpieBundledZipName('x64'), 'Magpie-hibiki-slim-x64.zip');
      expect(magpieBundledZipName('x64'), isNot(magpieZipName('x64')));
    });

    test('来源标记与 sha 标记是两个文件', () {
      expect(magpieSourceMarkerName(), isNot(magpieMarkerName()));
    });
  });

  group('随包安装的校验强度', () {
    test('没有随包归档 → 返回 false（让调用方回退网络），不抛', () async {
      final MagpieInstaller installer =
          MagpieInstaller(bundledDirectory: bundleDir);
      expect(await installer.installBundledMagpieForTesting('x64'), isFalse);
    });

    test('只有 zip 没有侧车 → 硬失败，绝不装无法证明来源的包', () async {
      final List<int> zip = _buildFakeMagpieZip();
      File(p.join(bundleDir.path, magpieBundledZipName('x64')))
          .writeAsBytesSync(zip);
      final MagpieInstaller installer =
          MagpieInstaller(bundledDirectory: bundleDir);
      await expectLater(
        installer.installBundledMagpieForTesting('x64'),
        throwsA(isA<MagpieInstallException>()),
      );
    });

    test('侧车摘要与 zip 不符 → 硬失败（主包也可能被改）', () async {
      writeBundle(arch: 'x64', shaOverride: 'a' * 64);
      final MagpieInstaller installer =
          MagpieInstaller(bundledDirectory: bundleDir);
      await expectLater(
        installer.installBundledMagpieForTesting('x64'),
        throwsA(isA<MagpieInstallException>()),
      );
    });

    test('侧车不是合法摘要 → 硬失败，不降级成「文件在就装」', () async {
      writeBundle(arch: 'x64', shaOverride: 'not-a-digest');
      final MagpieInstaller installer =
          MagpieInstaller(bundledDirectory: bundleDir);
      await expectLater(
        installer.installBundledMagpieForTesting('x64'),
        throwsA(isA<MagpieInstallException>()),
      );
    });
  });

  group('源码守卫：自更新熔断', () {
    late String source;

    setUpAll(() {
      source = File('lib/src/mining/magpie_installer.dart').readAsStringSync();
    });

    test('_updateSilently 必须在读标记之前就对随包版早退', () {
      final int guard = source.indexOf('if (installedFromBundle()) return;');
      expect(guard, greaterThanOrEqualTo(0),
          reason: '随包精简版的 sha 必然不等于 release 完整包，不早退就会每次开 app '
              '都下载 10.79 MB 覆盖掉 4.72 MB 的精简包');
      final int updateStart = source.indexOf('Future<void> _updateSilently()');
      final int markerRead =
          source.indexOf('final File marker = _markerFile();', updateStart);
      expect(updateStart, greaterThanOrEqualTo(0));
      expect(guard, greaterThan(updateStart));
      expect(guard, lessThan(markerRead), reason: '早退必须在任何网络/标记判据之前');
    });

    test('随包路径写 bundle 来源，网络路径清掉它', () {
      // 网络装的若留着旧的 bundle 标记，会伪装成随包版从此不再更新。
      expect(source, contains('source: kMagpieBundleSource'));
      expect(source, contains('source: null'));
      expect(source, contains('await sourceMarker.delete()'));
    });

    test('随包归档装完不得删除归档（另一次修复还要用）', () {
      final int bundleCall = source.indexOf('source: kMagpieBundleSource');
      final int before =
          source.lastIndexOf('deleteArchiveOnSuccess: false', bundleCall);
      expect(before, greaterThanOrEqualTo(0), reason: '随包归档是主包的一部分，删了就没法再修复安装');
    });
  });

  group('组包脚本契约', () {
    late String script;

    setUpAll(() {
      script = File('../tools/build_magpie_slim.ps1').readAsStringSync();
    });

    test('产出文件名与 Dart 侧随包命名一致', () {
      expect(script, contains('Magpie-hibiki-slim-'));
      expect(magpieBundledZipName('x64'), contains('Magpie-hibiki-slim-'));
    });

    test('裁剪前必须先校验上游完整包', () {
      // 裁剪 = 重新打包 = 重新签名。不先验源包，我们的侧车就成了污染产物的背书。
      final int verify = script.indexOf(r'$expected -ne $actual');
      final int repack = script.indexOf('ZipArchiveMode]::Create');
      expect(verify, greaterThanOrEqualTo(0));
      expect(repack, greaterThan(verify), reason: '校验必须早于重新打包');
    });

    test('保留清单覆盖 Magpie 默认 7 个 scalingMode 引用的全部 effect', () {
      // 来源 src/Magpie/AppSettings.cpp:1182-1252，少一个用户切过去就拿到「文件不存在」。
      for (final String effect in <String>[
        'Lanczos',
        'FSR/FSR_EASU',
        'FSR/FSR_RCAS',
        'FSRCNNX/FSRCNNX',
        'CuNNy2/CuNNy-4x12-NVL',
        'Anime4K/Anime4K_Upscale_Denoise_L',
        'CRT/CRT_Geom',
        'Nearest',
      ]) {
        expect(script, contains("'$effect'"),
            reason: '$effect 是默认 scalingMode 引用的 effect，不能裁');
      }
    });

    test('共享 include（*.hlsli）一律保留', () {
      expect(script, contains('hlsli'),
          reason: '删掉共享 include 会让保留下来的 effect 编译失败');
    });
  });

  group('Windows 主包随包资产构建契约', () {
    test('debug 与 release 都跑组包脚本并复制到 magpie_bundle', () {
      for (final String path in <String>[
        '../.github/workflows/build-multiplatform.yml',
        '../.github/workflows/release-desktop.yml',
      ]) {
        final String workflow = File(path).readAsStringSync();
        expect(workflow, contains('tools/build_magpie_slim.ps1'));
        expect(workflow, contains('magpie_bundle'));
        expect(workflow, contains("'Magpie-hibiki-slim-x64.zip'"));
        expect(workflow, contains("'Magpie-hibiki-slim-x64.zip.sha256'"));
      }
    });

    test('Inno Setup 递归收目录，随包资产无需单独列条目', () {
      final String installer =
          File('windows/installer/hibiki.iss').readAsStringSync();
      expect(installer, contains('recursesubdirs'));
    });
  });
}
