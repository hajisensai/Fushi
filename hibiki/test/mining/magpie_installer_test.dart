import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/magpie_installer.dart';
import 'package:path/path.dart' as p;

List<int> _buildZip(Map<String, List<int>> entries) {
  final Archive archive = Archive();
  entries.forEach((String name, List<int> bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive)!;
}

void main() {
  group('架构与随包契约', () {
    test('机器架构探测仍可诊断 ARM64，但生产随包固定使用 x64', () {
      expect(magpieArchForProcessorArchitecture('AMD64', 'ARM64'), 'ARM64');
      expect(magpieArchForProcessorArchitecture('ARM64', null), 'ARM64');
      expect(magpieArchForProcessorArchitecture('AMD64', null), 'x64');
      expect(kMagpieBundledArch, 'x64');
      expect(magpieBundledZipName(kMagpieBundledArch),
          'Magpie-hibiki-slim-x64.zip');
    });

    test('随包目录与安装目录分开', () {
      expect(kMagpieBundledDirectoryName, isNot(kMagpieInstallDirName));
    });
  });

  group('安装完整性清单', () {
    test('根文件只含缩放必需项，effects 目录必需', () {
      expect(
        kMagpieRequiredRootFiles,
        <String>['Magpie.exe', 'Microsoft.UI.Xaml.dll', 'resources.pri'],
      );
      expect(kMagpieRequiredDirs, <String>['effects']);
    });

    test('缺文件检测忽略大小写', () {
      expect(
        magpieMissingFiles(<String>[
          'MAGPIE.EXE',
          'microsoft.ui.xaml.DLL',
          'Resources.PRI',
        ]),
        isEmpty,
      );
      expect(
        magpieMissingFiles(<String>['Magpie.exe']),
        containsAll(<String>['Microsoft.UI.Xaml.dll', 'resources.pri']),
      );
    });
  });

  group('安装包元数据与便携配置', () {
    test('完整元数据与 UTF-8 BOM 都能解析', () {
      const String body =
          '{"upstreamVersion":"v0.12.1","forkCommit":"abc","configVersion":4}';
      for (final String raw in <String>[body, '\uFEFF$body']) {
        final MagpiePackageMetadata metadata =
            MagpiePackageMetadata.parse(raw)!;
        expect(metadata.upstreamVersion, 'v0.12.1');
        expect(metadata.forkCommit, 'abc');
        expect(metadata.configVersion, 4);
      }
    });

    test('坏元数据只降级，不抛', () {
      expect(MagpiePackageMetadata.parse(null), isNull);
      expect(MagpiePackageMetadata.parse(''), isNull);
      expect(MagpiePackageMetadata.parse('{broken'), isNull);
      expect(MagpiePackageMetadata.parse('[]'), isNull);
    });

    test('只有已验证 configVersion 才写 0 字节便携配置', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('magpie_cfg_ok_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bool wrote = await MagpieInstaller().ensurePortableConfig(
        metadata: const MagpiePackageMetadata(
          upstreamVersion: 'v0.12.1',
          forkCommit: 'abc',
          configVersion: kMagpieKnownConfigVersion,
        ),
        installDir: dir,
      );
      expect(wrote, isTrue);
      final File config = File(p.join(dir.path, 'config', 'config.json'));
      expect(config.existsSync(), isTrue);
      expect(config.lengthSync(), 0);
    });

    test('版本不符或配置已存在时绝不覆盖', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('magpie_cfg_keep_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File config = File(p.join(dir.path, 'config', 'config.json'));
      config.parent.createSync(recursive: true);
      config.writeAsStringSync('{"theme":1}');
      final bool wrote = await MagpieInstaller().ensurePortableConfig(
        metadata: const MagpiePackageMetadata(
          upstreamVersion: '',
          forkCommit: '',
          configVersion: kMagpieKnownConfigVersion,
        ),
        installDir: dir,
      );
      expect(wrote, isFalse);
      expect(config.readAsStringSync(), '{"theme":1}');
    });
  });

  group('解压防护', () {
    test('保留 effects 子目录并拒绝 zip-slip', () async {
      final Directory out =
          Directory.systemTemp.createTempSync('magpie_unzip_');
      addTearDown(() => out.deleteSync(recursive: true));
      final File zip = File(p.join(out.path, 'in.zip'))
        ..writeAsBytesSync(_buildZip(<String, List<int>>{
          'Magpie.exe': utf8.encode('exe'),
          'Microsoft.UI.Xaml.dll': utf8.encode('dll'),
          'resources.pri': utf8.encode('pri'),
          'effects/Lanczos.hlsl': utf8.encode('shader'),
          '../pwned.txt': utf8.encode('pwned'),
        }));
      final Directory target = Directory(p.join(out.path, 'target'));

      final Set<String> rootFiles =
          await MagpieInstaller().extractZip(zip, target);

      expect(magpieMissingFiles(rootFiles), isEmpty);
      expect(
        File(p.join(target.path, 'effects', 'Lanczos.hlsl')).readAsStringSync(),
        'shader',
      );
      expect(File(p.join(out.path, 'pwned.txt')).existsSync(), isFalse);
    });
  });

  group('零网络源码守卫（BUG-1246）', () {
    test('安装器没有 HTTP、下载器、远端 URL 或后台更新入口', () {
      final String source =
          File('lib/src/mining/magpie_installer.dart').readAsStringSync();
      for (final String forbidden in <String>[
        'HttpClient',
        'ResumableDownload',
        'applyUpdateProxy',
        'https://',
        'confirmDownload',
        'updateInstalledMagpieInBackground',
        'magpieDownloadUrl',
      ]) {
        expect(source, isNot(contains(forbidden)), reason: forbidden);
      }
    });

    test('ensureInstalled 只调用随包安装，缺包明确返回 bundleMissing', () {
      final String source =
          File('lib/src/mining/magpie_installer.dart').readAsStringSync();
      expect(source, contains('_installBundledMagpie(targetArch)'));
      expect(source, contains('MagpieInstallResult.bundleMissing'));
      expect(source, isNot(contains('fallback')));
    });

    test('非 Windows 直接 unsupportedPlatform', () async {
      if (Platform.isWindows) return;
      expect(
        await MagpieInstaller().ensureInstalled(),
        MagpieInstallResult.unsupportedPlatform,
      );
    });
  });
}
