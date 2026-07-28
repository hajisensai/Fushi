import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_helper_installer.dart';
import 'package:path/path.dart' as p;

void main() {
  group('galgameHelperArch', () {
    test('32 位游戏选 x86，否则 x64', () {
      expect(galgameHelperArch(is32Bit: true), 'x86');
      expect(galgameHelperArch(is32Bit: false), 'x64');
    });
  });

  group('parseSha256Sidecar', () {
    const String hash =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

    test('纯摘要', () {
      expect(parseSha256Sidecar(hash), hash);
    });

    test('大写归一化为小写', () {
      expect(parseSha256Sidecar(hash.toUpperCase()), hash);
    });

    test('<hash>  <filename> 形式取第一个 64-hex', () {
      expect(parseSha256Sidecar('$hash  voice_hook_x64.zip\n'), hash);
    });

    test('前后空白/换行容错', () {
      expect(parseSha256Sidecar('  \n$hash\n  '), hash);
    });

    test('无合法摘要返回 null', () {
      expect(parseSha256Sidecar('not-a-hash'), isNull);
      expect(parseSha256Sidecar('deadbeef'), isNull); // 非 64 位
    });
  });

  group('sha256Matches', () {
    test('去空白、大小写无关相等', () {
      expect(sha256Matches('ABCdef', ' abcdef '), isTrue);
      expect(sha256Matches('abc', 'abd'), isFalse);
    });
  });

  group('helper release manifest', () {
    test('x86 requires locale runtime and license', () {
      expect(
        galgameHelperRequiredFiles('x86'),
        containsAll(<String>[
          'hibiki_voice_injector.exe',
          'hibiki_voice_hook.dll',
          'LunaHook32.dll',
          'LunaHost32.dll',
          'LoaderDll.dll',
          'LocaleEmulator.dll',
          'LocaleEmulator-LGPL-3.0.txt',
        ]),
      );
    });

    test('x64 uses its own Luna binaries and does not require x86 locale DLLs',
        () {
      final List<String> required = galgameHelperRequiredFiles('x64');
      expect(
          required,
          containsAll(<String>[
            'hibiki_voice_injector.exe',
            'hibiki_voice_hook.dll',
            'LunaHook64.dll',
            'LunaHost64.dll',
            'unity_audio_runtime/hibiki_unity_audio_extract.exe',
            'unity_audio_runtime/classdata.tpk',
            'unity_audio_runtime/vgmstream-cli.exe',
          ]));
      expect(required, isNot(contains('LoaderDll.dll')));
      expect(required, isNot(contains('LocaleEmulator.dll')));
    });

    test('missing-file detection is case-insensitive and complete', () {
      final List<String> present =
          List<String>.from(galgameHelperRequiredFiles('x86'))
            ..remove('LocaleEmulator.dll')
            ..remove('LocaleEmulator-LGPL-3.0.txt')
            ..add('localeemulator-lgpl-3.0.TXT');
      expect(
        galgameHelperMissingFiles('x86', present),
        <String>['LocaleEmulator.dll'],
      );
    });

    test('unknown architecture is rejected', () {
      expect(
        () => galgameHelperRequiredFiles('arm64'),
        throwsArgumentError,
      );
    });
  });

  test('残缺安装用随包归档修复，且清单复检早于写装机标记', () {
    final String source = File(
      'lib/src/mining/galgame_helper_installer.dart',
    ).readAsStringSync();
    // BUG-1196：修复路径不再下载，与首装共用随包归档这一条来源。
    expect(source, contains('_installBundledHelper(arch)'));
    expect(source, isNot(contains('_downloadAndExtract')));
    expect(source, contains('missingFromPackage'));
    expect(
      source.indexOf('missingFromPackage'),
      lessThan(source.indexOf('_markerFile(arch).writeAsString')),
    );
  });

  group('BUG-1103 校验缺失/不符 → 硬失败，绝不安装', () {
    const String sha =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

    test('侧车取不到（null）→ 抛 verificationFailed，而不是降级为只校验 size', () {
      for (final String arch in <String>['x86', 'x64']) {
        expect(
          () => galgameHelperRequireVerifiedSha(null, arch),
          throwsA(isA<GalgameHelperInstallException>().having(
            (GalgameHelperInstallException e) => e.failure,
            'failure',
            GalgameHelperInstallFailure.verificationFailed,
          )),
          reason: arch,
        );
      }
    });

    test('侧车内容不是合法摘要（镜像错误页 / 空 body）→ 同样硬失败', () {
      for (final String junk in <String>['', '   ', 'Not Found', 'deadbeef']) {
        expect(
          () => galgameHelperRequireVerifiedSha(junk, 'x64'),
          throwsA(isA<GalgameHelperInstallException>()),
          reason: 'junk=$junk',
        );
      }
    });

    test('合法摘要 → 归一化为小写返回', () {
      expect(
        galgameHelperRequireVerifiedSha(' ${sha.toUpperCase()} \n', 'x64'),
        sha,
      );
    });
  });

  group('随主包归档离线安装', () {
    late Directory tmp;
    late Directory bundle;
    late Directory installRoot;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('gal_helper_bundle_test_');
      bundle = Directory(p.join(tmp.path, kGalgameHelperBundledDirectoryName))
        ..createSync(recursive: true);
      installRoot = Directory(p.join(tmp.path, 'voice_hook'));
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<void> writeBundle(String arch, {bool corruptSha = false}) async {
      final Archive archive = Archive();
      for (final String name in galgameHelperRequiredFiles(arch)) {
        final List<int> content = utf8.encode('fixture:$arch:$name');
        archive.addFile(ArchiveFile(name, content.length, content));
      }
      final List<int> bytes = ZipEncoder().encode(archive)!;
      final File zip = File(p.join(bundle.path, galgameHelperZipName(arch)));
      await zip.writeAsBytes(bytes, flush: true);
      final String digest = corruptSha
          ? List<String>.filled(64, '0').join()
          : sha256.convert(bytes).toString();
      await File('${zip.path}.sha256').writeAsString(digest, flush: true);
    }

    GalgameHelperInstaller installer() => GalgameHelperInstaller(
          bundledDirectory: bundle,
          installDirectory: (String arch) =>
              Directory(p.join(installRoot.path, arch)),
        );

    test('主包含 zip + 侧车时零网络完成校验、换入和版本标记', () async {
      await writeBundle('x64');

      expect(
        await installer().installBundledHelperForTesting('x64'),
        isTrue,
      );

      final Directory installed = Directory(p.join(installRoot.path, 'x64'));
      expect(
        galgameHelperMissingFiles(
          'x64',
          installed
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .map((File file) => p
                  .relative(file.path, from: installed.path)
                  .replaceAll('\\', '/')),
        ),
        isEmpty,
      );
      final String marker = File(
        p.join(installed.path, galgameHelperMarkerName()),
      ).readAsStringSync();
      final File zip = File(p.join(bundle.path, galgameHelperZipName('x64')));
      expect(marker, sha256.convert(zip.readAsBytesSync()).toString());
      expect(zip.existsSync(), isTrue, reason: '随包归档要保留，供修复/另一会话继续使用');
    });

    test('开发/旧包没有随附归档时明确返回 false，允许网络兜底', () async {
      expect(
        await installer().installBundledHelperForTesting('x86'),
        isFalse,
      );
      expect(installRoot.existsSync(), isFalse);
    });

    test('随包归档摘要不符时拒绝安装且不触碰目标目录', () async {
      await writeBundle('x86', corruptSha: true);

      await expectLater(
        installer().installBundledHelperForTesting('x86'),
        throwsA(isA<GalgameHelperInstallException>().having(
          (GalgameHelperInstallException e) => e.failure,
          'failure',
          GalgameHelperInstallFailure.verificationFailed,
        )),
      );
      expect(Directory(p.join(installRoot.path, 'x86')).existsSync(), isFalse);
    });
  });

  group('Windows 主包离线资产构建契约', () {
    final String packScript = File(
      '../native/galgame_hook/tools/build_distribution.ps1',
    ).readAsStringSync();
    final String debugWorkflow = File(
      '../.github/workflows/build-multiplatform.yml',
    ).readAsStringSync();
    final String releaseWorkflow = File(
      '../.github/workflows/release-desktop.yml',
    ).readAsStringSync();
    final String installer =
        File('windows/installer/hibiki.iss').readAsStringSync();

    test('组包脚本清单与 Dart 安装清单逐文件一致', () {
      for (final String arch in <String>['x64', 'x86']) {
        for (final String file in galgameHelperRequiredFiles(arch)) {
          expect(packScript, contains("'$file'"));
        }
        expect(packScript, contains('"voice_hook_\$arch.zip"'));
        expect(packScript, contains('"\$zip.sha256"'));
      }
    });

    test('debug 与 release 都调用统一脚本并复制到 galgame_helper', () {
      for (final String workflow in <String>[
        debugWorkflow,
        releaseWorkflow,
      ]) {
        expect(
          workflow,
          contains(
            'native/galgame_hook/tools/build_distribution.ps1 -RunTests',
          ),
        );
        expect(workflow, contains(r'\galgame_helper'));
        for (final String arch in <String>['x64', 'x86']) {
          expect(workflow, contains("'voice_hook_$arch.zip'"));
          expect(workflow, contains("'voice_hook_$arch.zip.sha256'"));
        }
      }
    });

    test('Inno Setup 递归收进 helper 子目录', () {
      expect(installer, contains('Flags: ignoreversion recursesubdirs'));
    });
  });
}
