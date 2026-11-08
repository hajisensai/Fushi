import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/sync/host_update/host_update_protocol.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/self_update/server_bundle_swap.dart';
import 'package:fushi_server/src/self_update/server_release.dart';
import 'package:fushi_server/src/self_update/server_self_updater.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const ServerReleaseInfo _beta = ServerReleaseInfo(
  version: '0.1.0',
  sequence: 100,
  tag: 'v0.1.0-beta.100',
  channel: 'beta',
);

const ServerReleaseInfo _formal = ServerReleaseInfo(
  version: '0.1.0',
  sequence: 100,
  tag: 'v0.1.0',
  channel: 'formal',
);

const String _suffix = '-linux-x64.tar.gz';

Map<String, Object?> _release(
  String tag,
  int seq, {
  bool prerelease = true,
  bool draft = false,
  String suffix = _suffix,
  String? digest,
  String? url,
}) => <String, Object?>{
  'tag_name': tag,
  'prerelease': prerelease,
  'draft': draft,
  'assets': <Object?>[
    <String, Object?>{
      'name': 'fushi_server-0.1.0-$seq$suffix',
      'browser_download_url':
          url ??
          'https://github.com/$kServerReleaseRepo/releases/download/$tag/'
              'fushi_server-0.1.0-$seq$suffix',
      'size': 3,
      'digest': digest ?? 'sha256:${'a' * 64}',
    },
  ],
};

void _write(String path, String content) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);
}

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('release.json', () {
    test('解析发布包版本身份；缺字段当成不是发布包', () {
      final ServerReleaseInfo? info = ServerReleaseInfo.tryParse(
        '{"version":"0.1.0","sequence":12,"tag":"v0.1.0-beta.12","channel":"beta"}',
      );
      expect(info!.sequence, 12);
      expect(info.isBeta, isTrue);
      expect(info.displayVersion, '0.1.0-beta.12');
      expect(ServerReleaseInfo.tryParse('{"version":"0.1.0"}'), isNull);
      expect(ServerReleaseInfo.tryParse('not json'), isNull);
    });

    test('只有 bin/ 下的可执行文件才算发布包布局', () {
      expect(
        currentBundleRoot(
          executablePath: p.join('opt', 'fs', 'bin', 'x'),
        )!.path,
        p.join('opt', 'fs'),
      );
      expect(currentBundleRoot(executablePath: p.join('sdk', 'dart')), isNull);
    });

    test('dart run / dart test（SDK 的 bin/dart）不算发布包：不当安装目录清理', () async {
      final Directory tmp = await Directory.systemTemp.createTemp('fushi_rel_');
      addTearDown(() => tmp.delete(recursive: true));
      final String sdkDart = p.join(tmp.path, 'dart-sdk', 'bin', 'dart.exe');
      _write(sdkDart, 'dart');
      // SDK 根下碰巧有同名暂存目录也不能被删。
      final Directory sdkStaging = Directory(
        p.join(tmp.path, 'dart-sdk', kServerUpdateStagingDir),
      )..createSync();
      expect(currentBundleRoot(executablePath: sdkDart), isNotNull);
      expect(currentReleaseBundleRoot(executablePath: sdkDart), isNull);
      expect(sdkStaging.existsSync(), isTrue);

      final String bundleExe = p.join(tmp.path, 'fs', 'bin', 'fushi_server');
      _write(bundleExe, 'exe');
      _write(p.join(tmp.path, 'fs', kServerReleaseInfoFile), '{}');
      expect(
        currentReleaseBundleRoot(executablePath: bundleExe)!.path,
        p.join(tmp.path, 'fs'),
      );
    });
  });

  group('pickServerUpdate', () {
    test('beta 通道：在 beta 与 formal 里挑序号最高、比本机新的本平台包', () {
      final ServerReleaseCandidate? c = pickServerUpdate(
        releasesJson: <Object?>[
          _release('v0.1.0-beta.90', 90),
          _release('v0.1.0-beta.120', 120),
          _release('v0.1.1', 110, prerelease: false),
          _release('v0.1.0-beta.130', 130, draft: true),
          _release('v0.1.0-beta.140', 140, suffix: '-windows-x64.zip'),
        ],
        current: _beta,
        assetSuffix: _suffix,
      );
      expect(c!.sequence, 120);
      expect(c.displayVersion, '0.1.0-beta.120');
      expect(c.sha256, 'a' * 64);
    });

    test('formal 通道不收 prerelease；没有更新 → null', () {
      expect(
        pickServerUpdate(
          releasesJson: _release('v0.1.0-beta.120', 120),
          current: _formal,
          assetSuffix: _suffix,
        ),
        isNull,
      );
      expect(
        pickServerUpdate(
          releasesJson: _release('v0.1.1', 101, prerelease: false),
          current: _formal,
          assetSuffix: _suffix,
        )!.tag,
        'v0.1.1',
      );
      expect(
        pickServerUpdate(
          releasesJson: _release('v0.1.0', 100, prerelease: false),
          current: _formal,
          assetSuffix: _suffix,
        ),
        isNull,
        reason: '同序号不算新',
      );
    });

    test('digest 不是 sha256 hex → 候选不带校验值（之后拒装）', () {
      final ServerReleaseCandidate? c = pickServerUpdate(
        releasesJson: _release('v0.1.0-beta.120', 120, digest: 'md5:abc'),
        current: _beta,
        assetSuffix: _suffix,
      );
      expect(c!.sha256, isNull);
    });

    test('下载地址不是本发布仓的 release 资产 → 不算候选', () {
      for (final String url in <String>[
        'https://example.test/fushi_server-0.1.0-120-linux-x64.tar.gz',
        'http://github.com/hajisensai/fushi-server/releases/download/v/x',
        'https://github.com/someone/fushi-server/releases/download/v/x',
        'https://github.com:8443/hajisensai/fushi-server/releases/download/v/x',
        'https://github.com/hajisensai/fushi-server/releases/download/../../evil/x',
      ]) {
        expect(
          pickServerUpdate(
            releasesJson: _release('v0.1.0-beta.120', 120, url: url),
            current: _beta,
            assetSuffix: _suffix,
          ),
          isNull,
          reason: url,
        );
      }
    });
  });

  group('swapServerBundle', () {
    late Directory tmp;
    late Directory root;
    late Directory bundle;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fushi_swap_');
      root = Directory(p.join(tmp.path, 'install'))..createSync();
      bundle = Directory(
        p.join(root.path, '.fushi_update', 'x', 'fushi_server'),
      )..createSync(recursive: true);
      _write(p.join(root.path, 'bin', 'fushi_server'), 'old exe');
      _write(p.join(root.path, 'lib', 'a.so'), 'old a');
      _write(p.join(root.path, 'fushi_server.yaml'), 'config');
      _write(p.join(root.path, 'data', 'db.sqlite'), 'data');
    });

    tearDown(() => tmp.delete(recursive: true));

    test('换进新文件，配置与数据不动；下次启动清掉旧文件', () async {
      _write(p.join(bundle.path, 'bin', 'fushi_server'), 'new exe');
      _write(p.join(bundle.path, 'lib', 'a.so'), 'new a');
      _write(p.join(bundle.path, 'lib', 'b.so'), 'new b');
      _write(p.join(bundle.path, 'release.json'), '{}');

      await swapServerBundle(newBundle: bundle, installRoot: root);

      expect(_read(p.join(root.path, 'bin', 'fushi_server')), 'new exe');
      expect(_read(p.join(root.path, 'lib', 'a.so')), 'new a');
      expect(_read(p.join(root.path, 'lib', 'b.so')), 'new b');
      expect(_read(p.join(root.path, 'fushi_server.yaml')), 'config');
      expect(_read(p.join(root.path, 'data', 'db.sqlite')), 'data');
      final String oldExe = p.join(root.path, 'bin', 'fushi_server.fushi-old');
      expect(_read(oldExe), 'old exe');

      expect(
        File(p.join(root.path, kServerUpdateJournalFile)).existsSync(),
        isFalse,
      );
      final ServerUpdateCleanup c = await cleanupAfterServerUpdate(root);
      expect(c.failed, 0);
      expect(c.rolledBack, isFalse);
      expect(c.restartRequired, isFalse);
      expect(File(oldExe).existsSync(), isFalse);
      expect(
        File(p.join(root.path, 'lib', 'a.so.fushi-old')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(root.path, kServerUpdateCleanupFile)).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(root.path, kServerUpdateStagingDir)).existsSync(),
        isFalse,
      );
      expect(_read(p.join(root.path, 'fushi_server.yaml')), 'config');
    });

    test('目标位置是目录 → 什么都不动直接拒', () async {
      _write(p.join(bundle.path, 'bin', 'fushi_server'), 'new exe');
      // 安装目录里同名的是目录：这一步换不进去 → 整体回滚。
      Directory(p.join(root.path, 'share', 'x')).createSync(recursive: true);
      _write(p.join(bundle.path, 'share', 'x'), 'file');

      await expectLater(
        swapServerBundle(newBundle: bundle, installRoot: root),
        throwsA(isA<ServerUpdateException>()),
      );
      expect(_read(p.join(root.path, 'bin', 'fushi_server')), 'old exe');
      expect(
        File(p.join(root.path, 'bin', 'fushi_server.fushi-old')).existsSync(),
        isFalse,
      );
      expect(Directory(p.join(root.path, 'share', 'x')).existsSync(), isTrue);
    });

    void writeNewBundle() {
      _write(p.join(bundle.path, 'bin', 'fushi_server'), 'new exe');
      _write(p.join(bundle.path, 'lib', 'a.so'), 'new a');
      _write(p.join(bundle.path, 'lib', 'b.so'), 'new b');
      _write(p.join(bundle.path, 'release.json'), '{}');
    }

    void expectOldInstall() {
      expect(_read(p.join(root.path, 'bin', 'fushi_server')), 'old exe');
      expect(_read(p.join(root.path, 'lib', 'a.so')), 'old a');
      expect(File(p.join(root.path, 'lib', 'b.so')).existsSync(), isFalse);
      expect(File(p.join(root.path, 'release.json')).existsSync(), isFalse);
      final List<String> leftovers = <String>[
        for (final FileSystemEntity e in root.listSync(recursive: true))
          if (e.path.endsWith(kServerUpdateOldSuffix) ||
              e.path.endsWith(kServerUpdateRollbackSuffix))
            e.path,
      ];
      expect(leftovers, isEmpty);
      expect(_read(p.join(root.path, 'fushi_server.yaml')), 'config');
      expect(_read(p.join(root.path, 'data', 'db.sqlite')), 'data');
    }

    test('换到一半抛错 → 进程内按日志逆序还原，日志删掉', () async {
      writeNewBundle();
      await expectLater(
        swapServerBundle(
          newBundle: bundle,
          installRoot: root,
          debugAfterStep: (int i) async {
            if (i == 2) throw const FileSystemException('disk full');
          },
        ),
        throwsA(
          isA<ServerUpdateException>().having(
            (ServerUpdateException e) => e.code,
            'code',
            'install_failed',
          ),
        ),
      );
      expectOldInstall();
      expect(
        File(p.join(root.path, kServerUpdateJournalFile)).existsSync(),
        isFalse,
      );
    });

    /// 让换包停在第 [step] 步之后再也不往下走（等同进程在那一刻被杀）。
    Future<void> swapKilledAfter(int step) async {
      final Completer<void> reached = Completer<void>();
      unawaited(
        swapServerBundle(
          newBundle: bundle,
          installRoot: root,
          debugAfterStep: (int i) {
            if (i < step) return Future<void>.value();
            reached.complete();
            return Completer<void>().future; // 永不返回
          },
        ),
      );
      await reached.future.timeout(const Duration(seconds: 10));
    }

    test('换到一半进程被杀 → 下次启动按日志逆序还原、删暂存，跑的是新 exe 就要求重启', () async {
      writeNewBundle();
      await swapKilledAfter(1);
      // 被杀那一刻：bin 与 lib/a.so 已是新版，旧的挂在 *.fushi-old，日志在。
      expect(_read(p.join(root.path, 'bin', 'fushi_server')), 'new exe');
      expect(_read(p.join(root.path, 'lib', 'a.so')), 'new a');
      expect(
        File(p.join(root.path, kServerUpdateJournalFile)).existsSync(),
        isTrue,
      );

      final ServerUpdateCleanup c = await cleanupAfterServerUpdate(
        root,
        runningExecutable: p.join(root.path, 'bin', 'fushi_server'),
      );
      expect(c.failed, 0);
      expect(c.rolledBack, isTrue);
      expect(c.restartRequired, isTrue);
      expectOldInstall();
      expect(
        File(p.join(root.path, kServerUpdateJournalFile)).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(root.path, kServerUpdateStagingDir)).existsSync(),
        isFalse,
      );
      // 再启动一次：无事可做，幂等。
      final ServerUpdateCleanup again = await cleanupAfterServerUpdate(root);
      expect(again.rolledBack, isFalse);
      expect(again.failed, 0);
      expectOldInstall();
    });

    test('还原没动到正在运行的可执行文件 → 不要求重启', () async {
      writeNewBundle();
      await swapKilledAfter(0);
      final ServerUpdateCleanup c = await cleanupAfterServerUpdate(
        root,
        runningExecutable: p.join(tmp.path, 'elsewhere', 'bin', 'dart'),
      );
      expect(c.rolledBack, isTrue);
      expect(c.restartRequired, isFalse);
      expectOldInstall();
    });

    test('上次没删掉的陈旧 *.fushi-old 换前先删：还原不会放回更早的版本', () async {
      writeNewBundle();
      _write(p.join(root.path, 'lib', 'a.so.fushi-old'), 'ancient a');
      await swapKilledAfter(0); // bin 换完就被杀，lib/a.so 还没动
      await cleanupAfterServerUpdate(
        root,
        runningExecutable: p.join(root.path, 'bin', 'fushi_server'),
      );
      expectOldInstall();
    });

    test('读不懂 / 越出安装目录的日志：不还原、不删暂存，只报出来', () async {
      final File journal = File(p.join(root.path, kServerUpdateJournalFile));
      for (final String bad in <String>[
        'not json',
        jsonEncode(<String, Object?>{
          'version': 1,
          'steps': <Object?>[
            <String, Object?>{
              'rel': p.join('..', 'outside.txt'),
              'had_old': false,
            },
          ],
        }),
      ]) {
        journal.writeAsStringSync(bad);
        _write(p.join(tmp.path, 'outside.txt'), 'keep');
        final ServerUpdateCleanup c = await cleanupAfterServerUpdate(root);
        expect(c.failed, 1);
        expect(c.rolledBack, isFalse);
        expect(journal.existsSync(), isTrue);
        expect(bundle.existsSync(), isTrue);
        expect(_read(p.join(tmp.path, 'outside.txt')), 'keep');
      }
    });

    test('清单里不在安装目录内或不带旧文件后缀的条目一律不删', () async {
      final String outside = p.join(tmp.path, 'outside.fushi-old');
      _write(outside, 'keep');
      _write(
        p.join(root.path, kServerUpdateCleanupFile),
        jsonEncode(<String>[outside, p.join(root.path, 'fushi_server.yaml')]),
      );
      await cleanupAfterServerUpdate(root);
      expect(File(outside).existsSync(), isTrue);
      expect(_read(p.join(root.path, 'fushi_server.yaml')), 'config');
    });
  });

  group('ServerSelfUpdater', () {
    late Directory tmp;
    late Directory root;
    final List<int> package = utf8.encode('pkg');
    final String goodDigest = sha256.convert(utf8.encode('pkg')).toString();

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fushi_selfupd_');
      root = Directory(p.join(tmp.path, 'install'))..createSync();
      _write(p.join(root.path, 'bin', 'fushi_server'), 'old exe');
      if (Platform.isWindows) {
        _write(p.join(root.path, 'bin', 'fushi_server.exe'), 'old exe');
      }
    });

    tearDown(() => tmp.delete(recursive: true));

    ServerSelfUpdater build({
      required void Function() onInstalled,
      String? digest,
      int remoteSeq = 120,
      int extractedSeq = 120,
      bool allowed = true,
      ServerReleaseInfo? current = _beta,
      ServerReleaseFetcher? fetch,
      ServerPackageDownloader? download,
    }) => ServerSelfUpdater(
      installRoot: root,
      current: current,
      assetSuffix: _suffix,
      platform: 'linux',
      isAllowed: () async => allowed,
      onInstalled: onInstalled,
      fetchReleases:
          fetch ??
          (Uri url) async {
            expect(url.path, '/repos/hajisensai/fushi-server/releases');
            return <Object?>[
              _release(
                'v0.1.0-beta.$remoteSeq',
                remoteSeq,
                digest: 'sha256:${digest ?? goodDigest}',
              ),
            ];
          },
      download:
          download ??
          (
            Uri url,
            File into, {
            required void Function(double) onProgress,
            int? expectedSize,
          }) async {
            await into.writeAsBytes(package);
            onProgress(1);
          },
      extract: (File archive, Directory dest) async {
        final String b = p.join(dest.path, 'fushi_server');
        _write(p.join(b, 'bin', 'fushi_server'), 'new exe');
        _write(p.join(b, 'bin', 'fushi_server.exe'), 'new exe');
        _write(
          p.join(b, 'release.json'),
          jsonEncode(<String, Object?>{
            'version': '0.1.0',
            'sequence': extractedSeq,
            'tag': 'v0.1.0-beta.$extractedSeq',
            'channel': 'beta',
          }),
        );
      },
    );

    test('查到新版 → 下载、校验、换包、通知 serve 退出', () async {
      final Completer<void> installed = Completer<void>();
      final ServerSelfUpdater u = build(onInstalled: installed.complete);
      final HostUpdateStatus s = await u.status(refresh: true);
      expect(s.supported, isTrue);
      expect(s.currentVersion, '0.1.0-beta.100');
      expect(s.latestVersion, '0.1.0-beta.120');
      expect(s.canTrigger, isTrue);

      final HostUpdateStatus accepted = await u.startUpdate();
      expect(accepted.phase, HostUpdatePhase.downloading);
      await installed.future.timeout(const Duration(seconds: 10));
      expect(_read(p.join(root.path, 'bin', 'fushi_server')), 'new exe');
      expect((await u.status()).phase, HostUpdatePhase.installing);
    });

    test('校验值对不上 → failed / digest_mismatch，安装目录不动', () async {
      bool installed = false;
      final ServerSelfUpdater u = build(
        onInstalled: () => installed = true,
        digest: 'b' * 64,
      );
      await u.startUpdate();
      await _waitFor(() async => (await u.status()).phase.isBusy == false);
      final HostUpdateStatus s = await u.status();
      expect(s.phase, HostUpdatePhase.failed);
      expect(s.error, 'digest_mismatch');
      expect(installed, isFalse);
      expect(_read(p.join(root.path, 'bin', 'fushi_server')), 'old exe');
      expect(
        Directory(p.join(root.path, kServerUpdateStagingDir)).existsSync(),
        isFalse,
      );
    });

    test('解出来的包序号不对 → bad_package，不换', () async {
      final ServerSelfUpdater u = build(onInstalled: () {}, extractedSeq: 119);
      await u.startUpdate();
      await _waitFor(() async => (await u.status()).phase.isBusy == false);
      expect((await u.status()).error, 'bad_package');
      expect(_read(p.join(root.path, 'bin', 'fushi_server')), 'old exe');
    });

    Object? releasesOf(int seq) => <Object?>[
      _release('v0.1.0-beta.$seq', seq, digest: 'sha256:$goodDigest'),
    ];

    test('并发触发：第一次还在查更新源时第二次回 busy，只下载、换包一次', () async {
      final Completer<void> gate = Completer<void>();
      int fetches = 0;
      int downloads = 0;
      final Completer<void> installed = Completer<void>();
      final ServerSelfUpdater u = build(
        onInstalled: installed.complete,
        fetch: (Uri _) async {
          fetches++;
          await gate.future;
          return releasesOf(120);
        },
        download:
            (
              Uri url,
              File into, {
              required void Function(double) onProgress,
              int? expectedSize,
            }) async {
              downloads++;
              await into.writeAsBytes(package);
            },
      );
      final Future<HostUpdateStatus> first = u.startUpdate();
      // 第一次卡在 await 查更新源（还没进 downloading）时第二次进来。
      await expectLater(
        u.startUpdate(),
        throwsA(
          isA<HostUpdateRejected>().having(
            (HostUpdateRejected e) => e.denial,
            'denial',
            HostUpdateDenial.busy,
          ),
        ),
      );
      gate.complete();
      expect((await first).phase, HostUpdatePhase.downloading);
      await installed.future.timeout(const Duration(seconds: 10));
      expect(fetches, 1);
      expect(downloads, 1);
      expect(_read(p.join(root.path, 'bin', 'fushi_server')), 'new exe');
    });

    test('查询失败 / 没有更新时占位复位，之后可以再触发', () async {
      int call = 0;
      final Completer<void> installed = Completer<void>();
      final ServerSelfUpdater u = build(
        onInstalled: installed.complete,
        fetch: (Uri _) async => switch (call++) {
          0 => throw const SocketException('offline'),
          1 => releasesOf(100),
          _ => releasesOf(120),
        },
      );
      Matcher denied(HostUpdateDenial d) => throwsA(
        isA<HostUpdateRejected>().having(
          (HostUpdateRejected e) => e.denial,
          'denial',
          d,
        ),
      );
      await expectLater(u.startUpdate(), denied(HostUpdateDenial.noUpdate));
      await expectLater(u.startUpdate(), denied(HostUpdateDenial.noUpdate));
      expect((await u.status()).phase, HostUpdatePhase.idle);
      expect((await u.startUpdate()).phase, HostUpdatePhase.downloading);
      await installed.future.timeout(const Duration(seconds: 10));
    });

    test('下载卡死（有响应头、正文不再来数据）→ 空闲超时进 failed，清掉暂存', () async {
      final StreamController<List<int>> body = StreamController<List<int>>();
      addTearDown(body.close);
      final MockClient stalled = MockClient.streaming((
        http.BaseRequest _,
        http.ByteStream _,
      ) async {
        body.add(<int>[1]);
        return http.StreamedResponse(body.stream, 200, contentLength: 3);
      });
      bool installed = false;
      final ServerSelfUpdater u = build(
        onInstalled: () => installed = true,
        download:
            (
              Uri url,
              File into, {
              required void Function(double) onProgress,
              int? expectedSize,
            }) => downloadServerPackage(
              url,
              into,
              onProgress: onProgress,
              expectedSize: expectedSize,
              client: stalled,
              idleTimeout: const Duration(milliseconds: 200),
            ),
      );
      await u.startUpdate();
      await _waitFor(() async => (await u.status()).phase.isBusy == false);
      final HostUpdateStatus s = await u.status();
      expect(s.phase, HostUpdatePhase.failed);
      expect(s.error, 'download_stalled');
      expect(installed, isFalse);
      expect(_read(p.join(root.path, 'bin', 'fushi_server')), 'old exe');
      expect(
        Directory(p.join(root.path, kServerUpdateStagingDir)).existsSync(),
        isFalse,
      );
      // 失败后可以再触发（不会永远卡在 downloading）。
      expect(s.canTrigger, isTrue);
    });

    test('没有更新 → noUpdate；不是发布包 → unsupported 且不查更新源', () async {
      final ServerSelfUpdater latest = build(
        onInstalled: () {},
        remoteSeq: 100,
      );
      await expectLater(
        latest.startUpdate(),
        throwsA(
          isA<HostUpdateRejected>().having(
            (HostUpdateRejected e) => e.denial,
            'denial',
            HostUpdateDenial.noUpdate,
          ),
        ),
      );

      final ServerSelfUpdater dev = ServerSelfUpdater(
        installRoot: null,
        current: null,
        assetSuffix: _suffix,
        isAllowed: () async => true,
        onInstalled: () {},
        fetchReleases: (Uri _) => fail('dev build must not hit GitHub'),
      );
      final HostUpdateStatus s = await dev.status(refresh: true);
      expect(dev.platformSupported, isFalse);
      expect(s.supported, isFalse);
      expect(s.currentVersion, 'dev');
    });
  });

  group('downloadServerPackage', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fushi_dl_');
    });
    tearDown(() => tmp.delete(recursive: true));

    final Uri url = Uri.parse(
      'https://github.com/$kServerReleaseRepo/releases/download/v1/x.tar.gz',
    );

    Matcher code(String c) => throwsA(
      isA<ServerUpdateException>().having(
        (ServerUpdateException e) => e.code,
        'code',
        c,
      ),
    );

    test('空闲超时只看两块数据之间的空档：慢而不断的下载照常完成', () async {
      final MockClient slow = MockClient.streaming((
        http.BaseRequest _,
        http.ByteStream _,
      ) async {
        Stream<List<int>> chunks() async* {
          for (int i = 0; i < 8; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 40));
            yield <int>[i];
          }
        }

        return http.StreamedResponse(chunks(), 200, contentLength: 8);
      });
      final File into = File(p.join(tmp.path, 'pkg'));
      final List<double> progress = <double>[];
      // 总时长 ~320ms > 空闲超时 150ms，但每块间隔只有 ~40ms。
      await downloadServerPackage(
        url,
        into,
        onProgress: progress.add,
        client: slow,
        idleTimeout: const Duration(milliseconds: 150),
      );
      expect(into.readAsBytesSync(), <int>[0, 1, 2, 3, 4, 5, 6, 7]);
      expect(progress.last, 1);
    });

    test('正文中途不再来数据 → download_stalled', () async {
      final StreamController<List<int>> body = StreamController<List<int>>();
      addTearDown(body.close);
      final MockClient stalled = MockClient.streaming((
        http.BaseRequest _,
        http.ByteStream _,
      ) async {
        body.add(<int>[1, 2]);
        return http.StreamedResponse(body.stream, 200, contentLength: 10);
      });
      await expectLater(
        downloadServerPackage(
          url,
          File(p.join(tmp.path, 'pkg')),
          onProgress: (double _) {},
          client: stalled,
          idleTimeout: const Duration(milliseconds: 100),
        ),
        code('download_stalled'),
      );
    });

    test('响应头迟迟不来 → download_timeout', () async {
      final MockClient silent = MockClient.streaming(
        (http.BaseRequest _, http.ByteStream _) =>
            Completer<http.StreamedResponse>().future,
      );
      await expectLater(
        downloadServerPackage(
          url,
          File(p.join(tmp.path, 'pkg')),
          onProgress: (double _) {},
          client: silent,
          headerTimeout: const Duration(milliseconds: 100),
        ),
        code('download_timeout'),
      );
    });
  });

  test('配置 remote_update 默认关，读写往返', () {
    final ServerConfig def = ServerConfig.defaults(dataDir: 'data');
    expect(def.remoteUpdate, isFalse);
    final ServerConfig on = def.copyWith(remoteUpdate: true);
    final ServerConfig parsed = ServerConfig.parse(on.toYaml(), configDir: '.');
    expect(parsed.remoteUpdate, isTrue);
  });
}

Future<void> _waitFor(Future<bool> Function() done) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
