import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/magpie_installer.dart';
import 'package:path/path.dart' as p;

import 'offline_installer_guard.dart';

List<int> _buildZip(Map<String, List<int>> entries) {
  final Archive archive = Archive();
  entries.forEach((String name, List<int> bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive)!;
}

void main() {
  group('架构与随包契约', () {
    test('随包只有 x64 一个切片，安装路径恒取它', () {
      // 只剩一个切片之后，「探测机器架构」没有任何消费者（ARM64 走系统 x64 模拟）。
      // 恢复架构分发必须先恢复第二个随包产物，不是在客户端加一个探测函数。
      expect(kMagpieBundledArch, 'x64');
      expect(magpieBundledZipName(kMagpieBundledArch),
          'Magpie-hibiki-slim-x64.zip');
      expect(
        File('lib/src/mining/magpie_installer.dart').readAsStringSync(),
        isNot(contains('PROCESSOR_ARCHITECTURE')),
        reason: '架构探测是下载链路的遗留物，随下载一起删掉了',
      );
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

  group('零网络源码守卫（BUG-1292）', () {
    // 判据是 import 白名单 + 归一化后的能力名扫描，不是几个字面串 ——
    // 理由与实测的绕过写法见 offline_installer_guard.dart 顶部。
    test('安装器的依赖面与符号面都不含任何网络通道', () {
      expectOfflineInstaller(
        path: 'lib/src/mining/magpie_installer.dart',
        allowedImports: kMagpieInstallerImports,
      );
    });

    test('跨模块复用只 show 四个纯工具函数，不给旁路留口子', () {
      // helper 安装器是 Magpie 唯一的项目内依赖。这里若退化成整包 import（或多 show
      // 一个符号），对面新加的任何东西都会自动出现在 Magpie 的可达面上。
      // 折掉换行/缩进再比，免得 dart format 的换行策略变一次就假红。
      final String source = File('lib/src/mining/magpie_installer.dart')
          .readAsStringSync()
          .replaceAll(RegExp(r'\s+'), ' ');
      expect(
        source,
        contains(
            "import 'package:fushi/src/mining/galgame_helper_installer.dart' "
            'show galgameHelperSwapInstall, galgameHelperSweepStaleFiles, '
            'parseSha256Sidecar, sha256Matches;'),
        reason: '复用面必须逐个点名；退化成整包 import 就等于把对面的全部符号拉进来',
      );
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
