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

import '../helpers/source_guard.dart';

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

Iterable<File> _workflowFiles() sync* {
  final Directory workflowDirectory = Directory('../.github/workflows');
  for (final FileSystemEntity entity
      in workflowDirectory.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final String extension = p.extension(entity.path).toLowerCase();
    if (extension == '.yml' || extension == '.yaml') {
      yield entity;
    }
  }
}

String _repoRelativePath(File file) =>
    p.relative(file.path, from: '..').replaceAll(r'\', '/');

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

    test('随包文件名带 slim，明确是精简归档', () {
      expect(magpieBundledZipName('x64'), 'Magpie-hibiki-slim-x64.zip');
      expect(magpieBundledZipName('x64'), contains('slim'));
    });
  });

  group('随包安装的校验强度', () {
    test('没有随包归档 → 返回 false，由调用方提示更新 Hibiki，不抛', () async {
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

  group('组包脚本契约', () {
    late File scriptFile;
    late String script;

    setUpAll(() {
      scriptFile = File('../tools/build_magpie_slim.ps1');
      script = scriptFile.readAsStringSync();
    });

    test('源文件保留 UTF-8 BOM，避免 Windows PowerShell 5.1 按代码页误解码', () {
      final List<int> bytes = scriptFile.readAsBytesSync();
      expect(bytes.length, greaterThanOrEqualTo(3));
      expect(bytes.take(3), <int>[0xEF, 0xBB, 0xBF],
          reason: 'BUG-1217 脚本含中文；无 BOM 时 Windows PowerShell 5.1 '
              '会按系统代码页读取并在执行前 parser error');
    });

    test(
      'Windows PowerShell 5.1 Parser.ParseFile 对脚本零错误',
      () {
        final String escapedPath =
            scriptFile.absolute.path.replaceAll("'", "''");
        final String command = r'$tokens = $null; $errors = $null; '
            '[System.Management.Automation.Language.Parser]::ParseFile('
            "'$escapedPath'"
            r', [ref]$tokens, [ref]$errors) | Out-Null; '
            r'if ($errors.Count -ne 0) { '
            r'$errors | ForEach-Object { Write-Error $_.Message }; exit 1 }';
        final ProcessResult result = Process.runSync(
          'powershell.exe',
          <String>[
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            command,
          ],
        );
        expect(
          result.exitCode,
          0,
          reason: 'Windows PowerShell 5.1 parse failed:\n'
              '${result.stdout}\n${result.stderr}',
        );
      },
      skip: !Platform.isWindows,
    );

    test('裁剪计数、zip 与 sha256 侧车仍由脚本真实产出', () {
      expect(script, contains(r'$kept = 0; $dropped = 0'));
      expect(
        script,
        contains(r'Write-Host "  保留 $kept 个文件，裁掉 $dropped 个"'),
      );
      expect(
        script,
        contains(r'Set-Content -LiteralPath "${slimZip}.sha256"'),
      );
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
    test('递归扫描 workflow，Magpie slim 只有两个规范 pwsh 调用点', () {
      const String scriptPath = 'tools/build_magpie_slim.ps1';
      const String canonicalInvocation =
          'pwsh -NoProfile -ExecutionPolicy Bypass -File $scriptPath';
      final List<String> callers = <String>[];

      for (final File file in _workflowFiles()) {
        // 注释判定走共享等长掩码（YAML / PowerShell 的 `#`）：行号与列宽同原文
        // 一一对应，下面按行号定位 step 边界的逻辑不受影响。
        final List<String> lines =
            maskHashComments(file.readAsStringSync()).split('\n');
        for (int index = 0; index < lines.length; index++) {
          final String line = lines[index];
          if (!line.contains(scriptPath)) continue;
          final String trimmed = line.trim();
          if (trimmed == "- '$scriptPath'" || trimmed == '- "$scriptPath"') {
            continue;
          }
          callers.add('${_repoRelativePath(file)}:${index + 1}');
          expect(trimmed, canonicalInvocation,
              reason: 'Magpie slim 禁止回退到 Windows PowerShell 5.1：'
                  '${_repoRelativePath(file)}:${index + 1}');

          int stepStart = index;
          while (stepStart >= 0 &&
              !RegExp(r'^ {6}- name:').hasMatch(lines[stepStart])) {
            stepStart--;
          }
          expect(stepStart, greaterThanOrEqualTo(0),
              reason: '调用必须位于可审计的 named step');

          int stepEnd = index + 1;
          while (stepEnd < lines.length &&
              !RegExp(r'^ {6}- name:').hasMatch(lines[stepEnd])) {
            stepEnd++;
          }
          final List<String> step = lines.sublist(stepStart, stepEnd);
          expect(
              step.any((String value) => value.trim() == 'shell: pwsh'), isTrue,
              reason: '外层 step 也必须显式 shell: pwsh');

          int nextCommand = index + 1;
          while (nextCommand < stepEnd) {
            final String candidate = lines[nextCommand].trim();
            // 掩码后整行注释只剩空白，故「非空」即「是真命令行」。
            if (candidate.isNotEmpty) break;
            nextCommand++;
          }
          expect(nextCommand, lessThan(stepEnd),
              reason: 'pwsh 子进程后必须紧邻检查 LASTEXITCODE');
          expect(
            lines[nextCommand].trim(),
            matches(RegExp(
              r'^if \(\$LASTEXITCODE -ne 0\) \{ throw '
              r'"build_magpie_slim\.ps1 failed \(\$LASTEXITCODE\)" \}$',
            )),
            reason: '下载、哈希或裁剪失败必须由外层 step 继续非零退出',
          );
        }
      }

      expect(
        callers.map((String value) => value.split(':').first).toSet(),
        <String>{
          '.github/workflows/build-multiplatform.yml',
          '.github/workflows/release-desktop.yml',
        },
      );
      expect(callers, hasLength(2), reason: '新增或删除调用点时必须同步审查全部 Windows 组包链');
    });

    test('debug 与 release 的脚本单改都触发构建并复制 zip + sha256', () {
      for (final String path in <String>[
        '../.github/workflows/build-multiplatform.yml',
        '../.github/workflows/release-desktop.yml',
      ]) {
        final String workflow = File(path).readAsStringSync();
        expect(
          workflow,
          contains("- 'tools/build_magpie_slim.ps1'"),
          reason: '$path 必须在 push paths 中精确监听组包脚本',
        );
        expect(workflow, contains('magpie_bundle'));
        expect(workflow, contains("'Magpie-hibiki-slim-x64.zip'"));
        expect(workflow, contains("'Magpie-hibiki-slim-x64.zip.sha256'"));
      }

      final String buildWorkflow =
          File('../.github/workflows/build-multiplatform.yml')
              .readAsStringSync();
      expect(buildWorkflow, contains('paths: &multiplatform_paths'));
      expect(buildWorkflow, contains('paths: *multiplatform_paths'),
          reason: '共享 paths anchor 必须同时覆盖 push 与 pull_request');
    });

    test('Inno Setup 递归收目录，随包资产无需单独列条目', () {
      final String installer =
          File('windows/installer/hibiki.iss').readAsStringSync();
      expect(installer, contains('recursesubdirs'));
    });
  });
}
