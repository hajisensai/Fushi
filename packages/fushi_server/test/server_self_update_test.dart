import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/sync/host_update/host_update_protocol.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/self_update/server_bundle_swap.dart';
import 'package:fushi_server/src/self_update/server_release.dart';
import 'package:fushi_server/src/self_update/server_self_updater.dart';
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

      expect(await cleanupAfterServerUpdate(root), 0);
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

    test('中途失败按原样还原', () async {
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
    }) => ServerSelfUpdater(
      installRoot: root,
      current: current,
      assetSuffix: _suffix,
      platform: 'linux',
      isAllowed: () async => allowed,
      onInstalled: onInstalled,
      fetchReleases: (Uri url) async {
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
