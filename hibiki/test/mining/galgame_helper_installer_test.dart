import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_helper_installer.dart';
import 'package:path/path.dart' as p;

/// 绕过当前 zone 的 [IOOverrides]，用于测试里给某一个路径套读取观察器，其余路径仍走真实 IO。
base class _DirectIoOverrides extends IOOverrides {}

class _ReadInterceptingFile implements File {
  _ReadInterceptingFile({
    required File delegate,
    required this.afterRead,
  }) : _delegate = delegate;

  final File _delegate;
  final Future<void> Function(File file, Uint8List bytes) afterRead;

  @override
  String get path => _delegate.path;

  @override
  bool existsSync() => _delegate.existsSync();

  @override
  Future<Uint8List> readAsBytes() async {
    final Uint8List bytes = await _delegate.readAsBytes();
    await afterRead(_delegate, bytes);
    return bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

    List<int> bundleBytes(
      String arch, {
      String contentPrefix = 'fixture',
      Set<String> omittedFiles = const <String>{},
    }) {
      final Archive archive = Archive();
      for (final String name in galgameHelperRequiredFiles(arch)) {
        if (omittedFiles.contains(name)) continue;
        final List<int> content = utf8.encode('$contentPrefix:$arch:$name');
        archive.addFile(ArchiveFile(name, content.length, content));
      }
      return ZipEncoder().encode(archive)!;
    }

    Future<void> writeBundle(
      String arch, {
      bool corruptSha = false,
      Set<String> omittedFiles = const <String>{},
    }) async {
      final List<int> bytes = bundleBytes(
        arch,
        omittedFiles: omittedFiles,
      );
      final File zip = File(p.join(bundle.path, galgameHelperZipName(arch)));
      await zip.writeAsBytes(bytes, flush: true);
      final String digest = corruptSha
          ? List<String>.filled(64, '0').join()
          : sha256.convert(bytes).toString();
      await File('${zip.path}.sha256').writeAsString(digest, flush: true);
    }

    Future<void> writeInstalled(
      String arch, {
      String? marker,
      String contentPrefix = 'old',
    }) async {
      final Directory installed = Directory(p.join(installRoot.path, arch))
        ..createSync(recursive: true);
      for (final String name in galgameHelperRequiredFiles(arch)) {
        final File file = File(p.join(installed.path, name));
        file.parent.createSync(recursive: true);
        await file.writeAsString('$contentPrefix:$arch:$name', flush: true);
      }
      if (marker != null) {
        await File(p.join(installed.path, galgameHelperMarkerName()))
            .writeAsString(marker, flush: true);
      }
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

    test('bundle 路径在首次读取后被替换也只安装已校验的同一份字节', () async {
      await writeBundle('x86');
      final File zip = File(p.join(bundle.path, galgameHelperZipName('x86')));
      final Uint8List replacement = Uint8List.fromList(
        bundleBytes('x86', contentPrefix: 'attacker'),
      );
      final _DirectIoOverrides directIo = _DirectIoOverrides();
      int zipReads = 0;
      bool replacedAfterFirstRead = false;

      final bool installed = await IOOverrides.runZoned<Future<bool>>(
        () => installer().installBundledHelperForTesting('x86'),
        createFile: (String path) {
          final File file = directIo.createFile(path);
          if (!p.equals(path, zip.path)) return file;
          return _ReadInterceptingFile(
            delegate: file,
            afterRead: (File observed, Uint8List _) async {
              zipReads++;
              if (!replacedAfterFirstRead) {
                await observed.writeAsBytes(replacement, flush: true);
                replacedAfterFirstRead = true;
              }
            },
          );
        },
      );

      expect(installed, isTrue);
      expect(replacedAfterFirstRead, isTrue);
      expect(zipReads, 1, reason: '校验和解压不得二次读取可替换的 bundle 路径');
      expect(
        File(
          p.join(
            installRoot.path,
            'x86',
            'hibiki_voice_injector.exe',
          ),
        ).readAsStringSync(),
        'fixture:x86:hibiki_voice_injector.exe',
        reason: '摘要校验与解压必须消费同一只读快照',
      );
    });

    test('marker 相同 fast path 校验 bundle 但不重装', () async {
      await writeBundle('x64');
      final File zip = File(p.join(bundle.path, galgameHelperZipName('x64')));
      final String digest = sha256.convert(zip.readAsBytesSync()).toString();
      await writeInstalled('x64', marker: digest);
      final File injector = File(
        p.join(
          installRoot.path,
          'x64',
          'hibiki_voice_injector.exe',
        ),
      );
      final File marker = File(
        p.join(
          installRoot.path,
          'x64',
          galgameHelperMarkerName(),
        ),
      );
      final DateTime oldTime = DateTime.utc(2001, 2, 3, 4, 5, 6);
      injector.setLastModifiedSync(oldTime);
      marker.setLastModifiedSync(oldTime);
      final DateTime injectorMtimeBefore = injector.lastModifiedSync();
      final DateTime markerMtimeBefore = marker.lastModifiedSync();
      final _DirectIoOverrides directIo = _DirectIoOverrides();
      int zipReads = 0;

      final bool ensured = await IOOverrides.runZoned<Future<bool>>(
        () => installer().ensureBundledVersionForTesting('x64'),
        createFile: (String path) {
          final File file = directIo.createFile(path);
          if (!p.equals(path, zip.path)) return file;
          return _ReadInterceptingFile(
            delegate: file,
            afterRead: (File _, Uint8List __) async {
              zipReads++;
            },
          );
        },
      );

      expect(ensured, isTrue);
      expect(zipReads, 1, reason: 'fast path 仍须核当前随包 zip 摘要');
      expect(
        injector.readAsStringSync(),
        'old:x64:hibiki_voice_injector.exe',
      );
      expect(injector.lastModifiedSync(), injectorMtimeBefore);
      expect(marker.lastModifiedSync(), markerMtimeBefore);
    });

    test('BUG-1246：完整旧安装的 marker 与随包版本不同时仍原子换入新版', () async {
      await writeInstalled(
        'x86',
        marker: List<String>.filled(64, 'a').join(),
      );
      await writeBundle('x86');

      expect(
        await installer().ensureBundledVersionForTesting('x86'),
        isTrue,
      );

      final Directory installed = Directory(p.join(installRoot.path, 'x86'));
      expect(
        File(p.join(installed.path, 'hibiki_voice_injector.exe'))
            .readAsStringSync(),
        'fixture:x86:hibiki_voice_injector.exe',
      );
      final File zip = File(p.join(bundle.path, galgameHelperZipName('x86')));
      expect(
        File(p.join(installed.path, galgameHelperMarkerName()))
            .readAsStringSync(),
        sha256.convert(zip.readAsBytesSync()).toString(),
      );
    });

    for (final MapEntry<String, String?> markerCase in <String, String?>{
      '缺失': null,
      '非法': 'not-a-sha256',
      '不同': List<String>.filled(64, 'a').join(),
    }.entries) {
      test('marker ${markerCase.key}时重装已校验 bundle', () async {
        await writeInstalled('x86', marker: markerCase.value);
        await writeBundle('x86');

        expect(
          await installer().ensureBundledVersionForTesting('x86'),
          isTrue,
        );

        final File zip = File(p.join(bundle.path, galgameHelperZipName('x86')));
        expect(
          File(
            p.join(
              installRoot.path,
              'x86',
              'hibiki_voice_injector.exe',
            ),
          ).readAsStringSync(),
          'fixture:x86:hibiki_voice_injector.exe',
        );
        expect(
          File(
            p.join(
              installRoot.path,
              'x86',
              galgameHelperMarkerName(),
            ),
          ).readAsStringSync(),
          sha256.convert(zip.readAsBytesSync()).toString(),
        );
      });
    }

    test('没有随包资产的开发构建继续使用完整现有安装', () async {
      final String oldMarker = List<String>.filled(64, 'b').join();
      await writeInstalled('x64', marker: oldMarker);

      expect(
        await installer().ensureBundledVersionForTesting('x64'),
        isTrue,
      );
      expect(
        File(
          p.join(
            installRoot.path,
            'x64',
            'hibiki_voice_injector.exe',
          ),
        ).readAsStringSync(),
        'old:x64:hibiki_voice_injector.exe',
      );
      expect(
        File(
          p.join(
            installRoot.path,
            'x64',
            galgameHelperMarkerName(),
          ),
        ).readAsStringSync(),
        oldMarker,
      );
    });

    test('没有随包资产且现有安装残缺时拒绝启动并保留现场', () async {
      final File injector = File(
        p.join(
          installRoot.path,
          'x86',
          'hibiki_voice_injector.exe',
        ),
      );
      injector.parent.createSync(recursive: true);
      injector.writeAsStringSync('only-old-injector');

      expect(
        await installer().ensureBundledVersionForTesting('x86'),
        isFalse,
      );
      expect(injector.readAsStringSync(), 'only-old-injector');
      expect(
        galgameHelperMissingFiles(
          'x86',
          <String>['hibiki_voice_injector.exe'],
        ),
        isNotEmpty,
      );
    });

    for (final String presentAsset in <String>['zip-only', 'sidecar-only']) {
      test('$presentAsset 不是 both absent：完整旧安装也 fail closed', () async {
        final String oldMarker = List<String>.filled(64, 'b').join();
        await writeInstalled('x86', marker: oldMarker);
        await writeBundle('x86');
        final File zip = File(p.join(bundle.path, galgameHelperZipName('x86')));
        final File sidecar = File('${zip.path}.sha256');
        if (presentAsset == 'zip-only') {
          sidecar.deleteSync();
        } else {
          zip.deleteSync();
        }

        await expectLater(
          installer().ensureBundledVersionForTesting('x86'),
          throwsA(
            isA<GalgameHelperInstallException>().having(
              (GalgameHelperInstallException e) => e.failure,
              'failure',
              GalgameHelperInstallFailure.verificationFailed,
            ),
          ),
        );
        expect(
          File(
            p.join(
              installRoot.path,
              'x86',
              'hibiki_voice_injector.exe',
            ),
          ).readAsStringSync(),
          'old:x86:hibiki_voice_injector.exe',
        );
        expect(
          File(
            p.join(
              installRoot.path,
              'x86',
              galgameHelperMarkerName(),
            ),
          ).readAsStringSync(),
          oldMarker,
        );
      });
    }

    test('开发/旧包没有随附归档时安装入口明确返回 false', () async {
      expect(
        await installer().installBundledHelperForTesting('x86'),
        isFalse,
      );
      expect(installRoot.existsSync(), isFalse);
    });

    test('随包归档摘要不符时拒绝安装且保留完整旧目录', () async {
      final String oldMarker = List<String>.filled(64, 'c').join();
      await writeInstalled('x86', marker: oldMarker);
      await writeBundle('x86', corruptSha: true);

      await expectLater(
        installer().ensureBundledVersionForTesting('x86'),
        throwsA(isA<GalgameHelperInstallException>().having(
          (GalgameHelperInstallException e) => e.failure,
          'failure',
          GalgameHelperInstallFailure.verificationFailed,
        )),
      );
      expect(
        File(
          p.join(
            installRoot.path,
            'x86',
            'hibiki_voice_injector.exe',
          ),
        ).readAsStringSync(),
        'old:x86:hibiki_voice_injector.exe',
      );
      expect(
        File(
          p.join(
            installRoot.path,
            'x86',
            galgameHelperMarkerName(),
          ),
        ).readAsStringSync(),
        oldMarker,
      );
    });

    test('marker 虽与侧车相同但 zip 摘要不符仍 fail closed', () async {
      final String sidecarSha = List<String>.filled(64, '0').join();
      await writeInstalled('x86', marker: sidecarSha);
      await writeBundle('x86', corruptSha: true);

      await expectLater(
        installer().ensureBundledVersionForTesting('x86'),
        throwsA(
          isA<GalgameHelperInstallException>().having(
            (GalgameHelperInstallException e) => e.failure,
            'failure',
            GalgameHelperInstallFailure.verificationFailed,
          ),
        ),
      );
      expect(
        File(
          p.join(
            installRoot.path,
            'x86',
            'hibiki_voice_injector.exe',
          ),
        ).readAsStringSync(),
        'old:x86:hibiki_voice_injector.exe',
      );
      expect(
        File(
          p.join(
            installRoot.path,
            'x86',
            galgameHelperMarkerName(),
          ),
        ).readAsStringSync(),
        sidecarSha,
      );
    });

    test('已验摘要但清单缺失时拒绝换入并保留完整旧目录', () async {
      final String oldMarker = List<String>.filled(64, 'd').join();
      await writeInstalled('x64', marker: oldMarker);
      await writeBundle(
        'x64',
        omittedFiles: <String>{'hibiki_voice_hook.dll'},
      );

      await expectLater(
        installer().ensureBundledVersionForTesting('x64'),
        throwsA(
          isA<GalgameHelperInstallException>().having(
            (GalgameHelperInstallException e) => e.failure,
            'failure',
            GalgameHelperInstallFailure.installFailed,
          ),
        ),
      );
      expect(
        File(
          p.join(
            installRoot.path,
            'x64',
            'hibiki_voice_injector.exe',
          ),
        ).readAsStringSync(),
        'old:x64:hibiki_voice_injector.exe',
      );
      expect(
        File(
          p.join(
            installRoot.path,
            'x64',
            galgameHelperMarkerName(),
          ),
        ).readAsStringSync(),
        oldMarker,
      );
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
