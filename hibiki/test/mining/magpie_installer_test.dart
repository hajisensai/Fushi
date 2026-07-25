import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_helper_installer.dart'
    show galgameHelperCandidateUrls, kGalgameHelperProxyPrefixes;
import 'package:hibiki/src/mining/magpie_installer.dart';
import 'package:path/path.dart' as p;

/// 造一个内存 zip：`entries` 是 `zip 内相对路径 -> 内容字节`。
List<int> _buildZip(Map<String, List<int>> entries) {
  final Archive archive = Archive();
  entries.forEach((String name, List<int> bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive)!;
}

void main() {
  group('架构判定', () {
    test('PROCESSOR_ARCHITEW6432=ARM64（x64 模拟进程）→ ARM64', () {
      expect(magpieArchForProcessorArchitecture('AMD64', 'ARM64'), 'ARM64');
    });

    test('PROCESSOR_ARCHITECTURE=ARM64（原生 ARM64 进程）→ ARM64', () {
      expect(magpieArchForProcessorArchitecture('ARM64', null), 'ARM64');
    });

    test('大小写/空白无关', () {
      expect(magpieArchForProcessorArchitecture(' arm64 ', null), 'ARM64');
    });

    test('普通 x64 机器 → x64', () {
      expect(magpieArchForProcessorArchitecture('AMD64', null), 'x64');
    });

    test('认不出来（全空）→ 回落 x64，绝不因此装不上', () {
      expect(magpieArchForProcessorArchitecture(null, null), 'x64');
      expect(magpieArchForProcessorArchitecture('', ''), 'x64');
    });

    test('magpieCurrentArch 可注入环境', () {
      expect(
        magpieCurrentArch(
            environment: <String, String>{'PROCESSOR_ARCHITEW6432': 'ARM64'}),
        'ARM64',
      );
      expect(magpieCurrentArch(environment: <String, String>{}), 'x64');
    });
  });

  group('zip 名与 URL 拼装', () {
    test('zip 名不含版本号（固定 tag 直链必须稳定）', () {
      expect(magpieZipName('x64'), 'Magpie-hibiki-x64.zip');
      expect(magpieZipName('ARM64'), 'Magpie-hibiki-ARM64.zip');
      expect(magpieZipName('x64'), isNot(contains(kMagpieUpstreamVersion)));
    });

    test('未知架构被拒', () {
      expect(() => magpieZipName('x86'), throwsArgumentError);
      expect(() => magpieZipName('arm64'), throwsArgumentError); // 大小写敏感
    });

    test('下载 URL 按固定 tag 拼接（非 run 号、非 Release API）', () {
      final String url = magpieDownloadUrl('x64');
      expect(url, contains('/releases/download/'));
      expect(url, contains('/$kMagpieReleaseTag/'));
      expect(url, endsWith('/Magpie-hibiki-x64.zip'));
      expect(url, isNot(contains('api.github.com')));
    });

    test('默认走我们自建的 fork 仓库（非上游 Blinue/Magpie）', () {
      expect(kMagpieRepo, 'hajisensai/Magpie');
      expect(magpieDownloadUrl('x64'),
          startsWith('https://github.com/hajisensai/Magpie/'));
      expect(magpieDownloadUrl('x64'), isNot(contains('Blinue')));
    });

    test('sha256 侧车 URL = zip URL + .sha256', () {
      expect(magpieSha256Url('ARM64'), '${magpieDownloadUrl('ARM64')}.sha256');
    });

    test('自定义 repo/tag 可注入', () {
      expect(
        magpieDownloadUrl('x64', repo: 'foo/bar', tag: 'zzz'),
        'https://github.com/foo/bar/releases/download/zzz/Magpie-hibiki-x64.zip',
      );
    });

    test('镜像候选：直连恒首位，随后每个镜像前缀套一份，无重复', () {
      final List<String> urls =
          galgameHelperCandidateUrls(magpieDownloadUrl('x64'));
      expect(urls.first, magpieDownloadUrl('x64'));
      expect(urls.length, 1 + kGalgameHelperProxyPrefixes.length);
      expect(urls.toSet().length, urls.length);
    });
  });

  group('安装完整性清单', () {
    test('必需根文件只含缩放真正需要的三个（不含 TouchHelper/Updater）', () {
      expect(
        kMagpieRequiredRootFiles,
        containsAll(
            <String>['Magpie.exe', 'Microsoft.UI.Xaml.dll', 'resources.pri']),
      );
      expect(kMagpieRequiredRootFiles, isNot(contains('TouchHelper.exe')));
      expect(kMagpieRequiredRootFiles, isNot(contains('Updater.exe')));
    });

    test('effects 目录是必需的（缺了等于没装）', () {
      expect(kMagpieRequiredDirs, contains('effects'));
    });

    test('缺文件检测忽略大小写', () {
      expect(
        magpieMissingFiles(<String>[
          'magpie.EXE',
          'microsoft.ui.xaml.DLL',
          'RESOURCES.PRI',
        ]),
        isEmpty,
      );
    });

    test('缺哪个报哪个', () {
      expect(
        magpieMissingFiles(<String>['Magpie.exe', 'resources.pri']),
        <String>['Microsoft.UI.Xaml.dll'],
      );
    });
  });

  group('自动更新判据', () {
    const String shaA =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    const String shaB =
        'da39a3ee5e6b4b0d3255bfef95601890afd80709da39a3ee5e6b4b0d32551234';

    test('标记文件名稳定', () {
      expect(magpieMarkerName(), 'installed.sha256');
    });

    test('本地与远端 sha 不同 → 需要更新', () {
      expect(magpieNeedsUpdate(shaA, shaB), isTrue);
    });

    test('相同（大小写/空白无关）→ 不更新', () {
      expect(magpieNeedsUpdate(shaA, ' ${shaA.toUpperCase()} '), isFalse);
    });

    test('无本地标记（手动放置/旧装）→ 不自动更新（保守）', () {
      expect(magpieNeedsUpdate(null, shaB), isFalse);
    });

    test('远端取不到（离线）→ 不更新（不阻塞启动）', () {
      expect(magpieNeedsUpdate(shaA, null), isFalse);
      expect(magpieNeedsUpdate(null, null), isFalse);
    });
  });

  group('安装包元数据解析', () {
    test('完整元数据', () {
      final MagpiePackageMetadata? meta = MagpiePackageMetadata.parse(
        jsonEncode(<String, Object?>{
          'upstreamVersion': 'v0.12.1',
          'forkCommit': 'deadbeef',
          'configVersion': 4,
        }),
      );
      expect(meta, isNotNull);
      expect(meta!.upstreamVersion, 'v0.12.1');
      expect(meta.forkCommit, 'deadbeef');
      expect(meta.configVersion, 4);
    });

    test('configVersion 是字符串时也能解析（workflow 注入偶发字符串化）', () {
      expect(
        MagpiePackageMetadata.parse('{"configVersion":"4"}')?.configVersion,
        4,
      );
    });

    test('缺字段 → 空串 / null，不抛', () {
      final MagpiePackageMetadata? meta = MagpiePackageMetadata.parse('{}');
      expect(meta, isNotNull);
      expect(meta!.upstreamVersion, '');
      expect(meta.forkCommit, '');
      expect(meta.configVersion, isNull);
    });

    test('null / 空白 / 坏 JSON / 非对象 → null，绝不抛', () {
      expect(MagpiePackageMetadata.parse(null), isNull);
      expect(MagpiePackageMetadata.parse('   '), isNull);
      expect(MagpiePackageMetadata.parse('{ not json'), isNull);
      expect(MagpiePackageMetadata.parse('[1,2,3]'), isNull);
      expect(MagpiePackageMetadata.parse('"just a string"'), isNull);
    });
  });

  group('便携模式标记（config.json）', () {
    test('内容必须是空的：写 {} 会让 Magpie 读到「没有 scalingModes 的有效配置」', () {
      // 这不是风格问题：Magpie 只在 configText 为空时才灌默认 scalingModes；
      // 一个 "{}" 会让 scalingModes 保持空数组 → profile.scalingMode 钳到 -1
      // → 缩放报 InvalidScalingMode。空文件同时实现「隔离」与「零 schema 猜测」。
      expect(magpiePortableConfigContent(), isEmpty);
      expect(magpiePortableConfigContent(), isNot(contains('{')));
    });

    test('只有 configVersion 与已验证值一致才写配置', () {
      expect(
        magpieCanWritePortableConfig(const MagpiePackageMetadata(
          upstreamVersion: 'v0.12.1',
          forkCommit: 'x',
          configVersion: kMagpieKnownConfigVersion,
        )),
        isTrue,
      );
    });

    test('元数据缺失 / configVersion 不一致或为 null → 只装不配', () {
      expect(magpieCanWritePortableConfig(null), isFalse);
      expect(
        magpieCanWritePortableConfig(const MagpiePackageMetadata(
          upstreamVersion: '',
          forkCommit: '',
          configVersion: kMagpieKnownConfigVersion + 1,
        )),
        isFalse,
      );
      expect(
        magpieCanWritePortableConfig(const MagpiePackageMetadata(
          upstreamVersion: '',
          forkCommit: '',
          configVersion: null,
        )),
        isFalse,
      );
    });

    test('版本一致 → 真的写出空的 config/config.json', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('magpie_cfg_ok_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bool wrote = await MagpieInstaller().ensurePortableConfig(
        metadata: const MagpiePackageMetadata(
          upstreamVersion: 'v0.12.1',
          forkCommit: 'x',
          configVersion: kMagpieKnownConfigVersion,
        ),
        installDir: dir,
      );
      expect(wrote, isTrue);
      final File cfg = File(p.join(dir.path, 'config', 'config.json'));
      expect(cfg.existsSync(), isTrue);
      expect(cfg.lengthSync(), 0);
    });

    test('版本不一致 → 一个字节都不写（只装不配）', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('magpie_cfg_skip_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bool wrote = await MagpieInstaller().ensurePortableConfig(
        metadata: const MagpiePackageMetadata(
          upstreamVersion: '',
          forkCommit: '',
          configVersion: 99,
        ),
        installDir: dir,
      );
      expect(wrote, isFalse);
      expect(Directory(p.join(dir.path, 'config')).existsSync(), isFalse);
    });

    test('已存在 config.json → 绝不覆盖（用户/Magpie 的真实配置）', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('magpie_cfg_keep_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File cfg = File(p.join(dir.path, 'config', 'config.json'));
      cfg.parent.createSync(recursive: true);
      cfg.writeAsStringSync('{"theme":1}');
      final bool wrote = await MagpieInstaller().ensurePortableConfig(
        metadata: const MagpiePackageMetadata(
          upstreamVersion: '',
          forkCommit: '',
          configVersion: kMagpieKnownConfigVersion,
        ),
        installDir: dir,
      );
      expect(wrote, isFalse);
      expect(cfg.readAsStringSync(), '{"theme":1}');
    });
  });

  group('解压：目录结构与 zip-slip 防护', () {
    test('保留 effects/ 子目录结构，只回报根层文件名', () async {
      final Directory out =
          Directory.systemTemp.createTempSync('magpie_unzip_ok_');
      addTearDown(() => out.deleteSync(recursive: true));
      final File zip = File(p.join(out.path, 'in.zip'))
        ..writeAsBytesSync(_buildZip(<String, List<int>>{
          'Magpie.exe': utf8.encode('exe'),
          'Microsoft.UI.Xaml.dll': utf8.encode('dll'),
          'resources.pri': utf8.encode('pri'),
          'hibiki-magpie.json': utf8.encode('{}'),
          'effects/Lanczos.hlsl': utf8.encode('shader'),
          'effects/Anime4K/Anime4K_Upscale_L.hlsl': utf8.encode('shader2'),
        }));
      final Directory target = Directory(p.join(out.path, 'target'));

      final Set<String> rootFiles =
          await MagpieInstaller().extractZip(zip, target);

      expect(
        rootFiles,
        <String>{
          'Magpie.exe',
          'Microsoft.UI.Xaml.dll',
          'resources.pri',
          'hibiki-magpie.json',
        },
      );
      expect(magpieMissingFiles(rootFiles), isEmpty);
      expect(
        File(p.join(
                target.path, 'effects', 'Anime4K', 'Anime4K_Upscale_L.hlsl'))
            .readAsStringSync(),
        'shader2',
      );
      // 内容真的写进去了（archive 3.6.1 的 decompress() 会写 0 字节，故取 content）。
      expect(File(p.join(target.path, 'Magpie.exe')).lengthSync(), 3);
    });

    test('zip-slip：../ 逃逸条目被丢弃，目标目录外不留文件', () async {
      final Directory out =
          Directory.systemTemp.createTempSync('magpie_unzip_slip_');
      addTearDown(() => out.deleteSync(recursive: true));
      final File zip = File(p.join(out.path, 'evil.zip'))
        ..writeAsBytesSync(_buildZip(<String, List<int>>{
          'Magpie.exe': utf8.encode('ok'),
          '../pwned.txt': utf8.encode('pwned'),
          '../../pwned2.txt': utf8.encode('pwned'),
          'effects/../../pwned3.txt': utf8.encode('pwned'),
        }));
      final Directory target = Directory(p.join(out.path, 'target'));

      final Set<String> rootFiles =
          await MagpieInstaller().extractZip(zip, target);

      expect(rootFiles, <String>{'Magpie.exe'});
      expect(File(p.join(out.path, 'pwned.txt')).existsSync(), isFalse);
      expect(File(p.join(p.dirname(out.path), 'pwned2.txt')).existsSync(),
          isFalse);
      expect(File(p.join(out.path, 'pwned3.txt')).existsSync(), isFalse);
    });

    test('绝对路径条目被丢弃', () async {
      final Directory out =
          Directory.systemTemp.createTempSync('magpie_unzip_abs_');
      addTearDown(() => out.deleteSync(recursive: true));
      final String absName = Platform.isWindows
          ? 'C:/Windows/Temp/hibiki_magpie_abs_probe.txt'
          : '/tmp/hibiki_magpie_abs_probe.txt';
      final File zip = File(p.join(out.path, 'abs.zip'))
        ..writeAsBytesSync(_buildZip(<String, List<int>>{
          'Magpie.exe': utf8.encode('ok'),
          absName: utf8.encode('pwned'),
        }));
      final Directory target = Directory(p.join(out.path, 'target'));

      final Set<String> rootFiles =
          await MagpieInstaller().extractZip(zip, target);

      expect(rootFiles, <String>{'Magpie.exe'});
      expect(File(absName).existsSync(), isFalse);
    });
  });

  group('staging 元数据读取', () {
    test('读到并解析', () async {
      final Directory staging =
          Directory.systemTemp.createTempSync('magpie_meta_ok_');
      addTearDown(() => staging.deleteSync(recursive: true));
      File(p.join(staging.path, kMagpieMetadataName)).writeAsStringSync(
        jsonEncode(<String, Object?>{'configVersion': 4}),
      );
      final MagpiePackageMetadata? meta =
          await MagpieInstaller().readStagedMetadata(staging);
      expect(meta?.configVersion, 4);
    });

    test('元数据缺失 → null（不抛，降级只装不配）', () async {
      final Directory staging =
          Directory.systemTemp.createTempSync('magpie_meta_none_');
      addTearDown(() => staging.deleteSync(recursive: true));
      expect(await MagpieInstaller().readStagedMetadata(staging), isNull);
    });

    test('元数据损坏 → null（不抛）', () async {
      final Directory staging =
          Directory.systemTemp.createTempSync('magpie_meta_bad_');
      addTearDown(() => staging.deleteSync(recursive: true));
      File(p.join(staging.path, kMagpieMetadataName))
          .writeAsStringSync('{ broken');
      expect(await MagpieInstaller().readStagedMetadata(staging), isNull);
    });
  });

  group('平台边界', () {
    test('非 Windows 一律 unsupportedPlatform，绝不发网络请求', () async {
      final MagpieInstallResult result =
          await MagpieInstaller().ensureInstalled(
        confirm: (MagpieDownloadPrompt _) async => fail('非 Windows 不该走到确认回调'),
      );
      expect(result, MagpieInstallResult.unsupportedPlatform);
    }, skip: Platform.isWindows ? 'Windows 上走真实安装路径，见源码守卫' : false);

    test('非 Windows 后台自更新直接返回（不碰文件系统）', () async {
      await MagpieInstaller.updateInstalledMagpieInBackground();
    }, skip: Platform.isWindows ? 'Windows 上会读安装目录' : false);
  });

  // 交互路径的时序契约（BUG-1076 的教训）无法在 Linux CI 上跑真实安装路径验证，
  // 故在源码层加守卫：确认回调必须在任何 await 探测之前被调用；已装完整时必须
  // 零网络直接返回。改坏这两条会直接把测试打红。
  group('源码守卫：BUG-1076 时序契约', () {
    late final String src =
        File('lib/src/mining/magpie_installer.dart').readAsStringSync();

    test('大小探测发起后不 await，直接进 confirm 回调', () {
      final int probeAt =
          src.indexOf('final Future<int?> sizeProbe = _probeSize(');
      final int confirmAt = src.indexOf('final bool ok = await confirm(');
      expect(probeAt, greaterThan(0));
      expect(confirmAt, greaterThan(probeAt));
      final String between = src.substring(probeAt, confirmAt);
      expect(between, isNot(contains('await sizeProbe')));
      expect(between, contains('unawaited(sizeProbe'));
    });

    test('已完整安装时零网络直接返回 alreadyInstalled', () {
      final int checkAt =
          src.indexOf('if (missingInstalledEntries().isEmpty) {');
      final int probeAt =
          src.indexOf('final Future<int?> sizeProbe = _probeSize(');
      expect(checkAt, greaterThan(0));
      expect(probeAt, greaterThan(checkAt));
      expect(
        src.substring(checkAt, probeAt),
        contains('MagpieInstallResult.alreadyInstalled'),
      );
    });

    test('后台自更新只对「已装且有标记」生效', () {
      expect(src, contains('if (!marker.existsSync()) return;'));
      expect(
          src, contains('if (missingInstalledEntries().isNotEmpty) return;'));
    });

    test('换入前先在 staging 校验包清单，标记在换入成功后才写', () {
      // 用调用点而非 import show 列表里的同名符号定位。
      const String swapCall =
          '_serializeInstall(() => galgameHelperSwapInstall(';
      expect(src.indexOf(swapCall), greaterThan(0));
      expect(
          src.indexOf('missingFromPackage'), lessThan(src.indexOf(swapCall)));
      expect(src.indexOf(swapCall),
          lessThan(src.indexOf('_markerFile().writeAsString')));
    });
  });
}
