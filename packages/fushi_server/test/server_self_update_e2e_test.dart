/// 远程自更新端到端（不联网）：真归档、真下载、真解包、真换包、真启动收尾。
///
/// 只替换「GitHub」这一跳：Releases JSON 由测试按归档的真实大小 / SHA-256 拼出来，
/// 下载走生产的 [downloadServerPackage]，指向本机 HTTP 服务。归档按 `release-server.yml`
/// 打包步骤的同一种方式做（Linux `tar -C stage -czf …`；Windows 用 System32 的 bsdtar
/// 出 zip，顶层同为 `fushi_server/`），解包走生产的 [extractServerArchiveWithTar]。
///
/// 安装目录里的 `bin/fushi_server(.exe)` 换包时**正在运行**（复制一个会挂住的系统程序
/// 进去再起）：Windows 不许删 / 覆盖运行中的映像，只许改名，这条测试守的就是这一点。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/sync/host_update/host_update_protocol.dart';
import 'package:fushi_server/src/self_update/server_bundle_swap.dart';
import 'package:fushi_server/src/self_update/server_release.dart';
import 'package:fushi_server/src/self_update/server_self_updater.dart';
import 'package:fushi_server/src/self_update/server_update_recovery.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final String _exeName = Platform.isWindows
    ? 'fushi_server.exe'
    : 'fushi_server';

/// 一个会一直挂着、可以复制到别处运行的系统程序，及让它挂住的参数。
({String path, List<String> args})? _hangingProgram() {
  if (Platform.isWindows) {
    final String ping = p.join(
      Platform.environment['SystemRoot'] ?? r'C:\Windows',
      'System32',
      'PING.EXE',
    );
    return File(ping).existsSync()
        ? (path: ping, args: <String>['-n', '120', '127.0.0.1'])
        : null;
  }
  for (final String c in <String>['/bin/sleep', '/usr/bin/sleep']) {
    if (File(c).existsSync()) return (path: c, args: <String>['120']);
  }
  return null;
}

/// 与 `release-server.yml` 的 Linux 打包步骤同一种 printf 写法。
String _releaseJson(int seq) =>
    '{"version":"0.1.0","sequence":$seq,"tag":"v0.1.0-beta.$seq",'
    '"channel":"beta"}\n';

void _write(String path, List<int> bytes) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);
}

Future<void> _archive(Directory stage, File out) async {
  final ProcessResult r = Platform.isWindows
      ? await Process.run(
          p.join(
            Platform.environment['SystemRoot'] ?? r'C:\Windows',
            'System32',
            'tar.exe',
          ),
          <String>['-a', '-cf', out.path, '-C', stage.path, 'fushi_server'],
        )
      : await Process.run('tar', <String>[
          '-C',
          stage.path,
          '-czf',
          out.path,
          'fushi_server',
        ]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
}

void main() {
  final ({String path, List<String> args})? hanging = _hangingProgram();
  final String? suffix = serverReleaseAssetSuffix();

  test(
    '真归档 + 运行中的旧 exe：下载、校验、解包、换包、onInstalled；重启后清掉旧文件',
    () async {
      final Directory tmp = await Directory.systemTemp.createTemp('fushi_e2e_');
      Process? running;
      HttpServer? http;
      try {
        // ── 旧安装：正在运行的 exe + 一个旧 lib + 配置 / 数据 ──
        final Directory root = Directory(p.join(tmp.path, 'install'));
        final String exe = p.join(root.path, 'bin', _exeName);
        File(exe).parent.createSync(recursive: true);
        File(hanging!.path).copySync(exe);
        if (!Platform.isWindows) {
          expect(
            (await Process.run('chmod', <String>['755', exe])).exitCode,
            0,
          );
        }
        _write(p.join(root.path, 'lib', 'libold.so'), utf8.encode('old lib'));
        _write(p.join(root.path, 'lib', 'libkeep.so'), utf8.encode('keep v1'));
        _write(
          p.join(root.path, 'release.json'),
          utf8.encode(_releaseJson(100)),
        );
        _write(p.join(root.path, 'fushi_server.yaml'), utf8.encode('config'));
        _write(
          p.join(root.path, 'data', 'support', 'fushi.db'),
          utf8.encode('db'),
        );
        running = await Process.start(exe, hanging.args);
        final List<int> oldExeBytes = File(exe).readAsBytesSync();
        if (Platform.isWindows) {
          // 前提成立：运行中的映像删不掉（换包只能靠改名）。
          expect(
            () => File(exe).deleteSync(),
            throwsA(isA<FileSystemException>()),
          );
        }

        // ── 新版发布包：按打包步骤 stage/fushi_server → 归档 ──
        final Directory stage = Directory(p.join(tmp.path, 'stage'));
        final String newBundle = p.join(stage.path, kServerBundleDirName);
        final List<int> newExeBytes = utf8.encode('new exe v120');
        _write(p.join(newBundle, 'bin', _exeName), newExeBytes);
        if (!Platform.isWindows) {
          // `dart build cli` 出的可执行文件带 x 位；归档 / 解包要原样保留。
          final String staged = p.join(newBundle, 'bin', _exeName);
          expect(
            (await Process.run('chmod', <String>['755', staged])).exitCode,
            0,
          );
        }
        _write(p.join(newBundle, 'lib', 'libkeep.so'), utf8.encode('keep v2'));
        _write(p.join(newBundle, 'lib', 'libnew.so'), utf8.encode('new lib'));
        _write(p.join(newBundle, 'README.md'), utf8.encode('readme'));
        _write(
          p.join(newBundle, 'release.json'),
          utf8.encode(_releaseJson(120)),
        );
        final String assetName = 'fushi_server-0.1.0-120$suffix';
        final File archive = File(p.join(tmp.path, 'out', assetName))
          ..parent.createSync(recursive: true);
        await _archive(stage, archive);
        final List<int> archiveBytes = archive.readAsBytesSync();
        final String digest = sha256.convert(archiveBytes).toString();

        // ── 「GitHub」：本机 HTTP 服务 ──
        http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        int downloads = 0;
        http.listen((HttpRequest req) async {
          downloads++;
          req.response.contentLength = archiveBytes.length;
          req.response.add(archiveBytes);
          await req.response.close();
        });
        final Uri local = Uri.parse('http://127.0.0.1:${http.port}/$assetName');

        final Completer<void> installed = Completer<void>();
        final ServerSelfUpdater updater = ServerSelfUpdater(
          installRoot: root,
          current: ServerReleaseInfo.readFrom(root),
          assetSuffix: suffix,
          isAllowed: () async => true,
          onInstalled: installed.complete,
          fetchReleases: (Uri url) async => <Object?>[
            <String, Object?>{
              'tag_name': 'v0.1.0-beta.120',
              'prerelease': true,
              'draft': false,
              'assets': <Object?>[
                <String, Object?>{
                  'name': assetName,
                  'browser_download_url':
                      'https://github.com/$kServerReleaseRepo/releases/'
                      'download/v0.1.0-beta.120/$assetName',
                  'size': archiveBytes.length,
                  'digest': 'sha256:$digest',
                },
              ],
            },
          ],
          download:
              (
                Uri url,
                File into, {
                required void Function(double) onProgress,
                int? expectedSize,
              }) {
                expect(isServerReleaseDownloadUrl(url), isTrue);
                return downloadServerPackage(
                  local,
                  into,
                  onProgress: onProgress,
                  expectedSize: expectedSize,
                );
              },
        );

        final HostUpdateStatus before = await updater.status(refresh: true);
        expect(before.supported, isTrue);
        expect(before.currentVersion, '0.1.0-beta.100');
        expect(before.latestVersion, '0.1.0-beta.120');
        await updater.startUpdate();
        // 安装在后台跑：等 onInstalled，失败态 / 超时即判红（等完就停，不留挂着的轮询）。
        final Stopwatch waited = Stopwatch()..start();
        while (!installed.isCompleted) {
          final HostUpdateStatus s = await updater.status();
          if (s.phase == HostUpdatePhase.failed) {
            fail('update failed: ${s.error}');
          }
          if (waited.elapsed > const Duration(seconds: 60)) {
            fail('no onInstalled after 60s (phase ${s.phase.name})');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        // ── 换包后：旧进程照跑，盘上已是新版 ──
        expect(downloads, 1);
        expect(File(exe).readAsBytesSync(), newExeBytes);
        expect(
          File('$exe$kServerUpdateOldSuffix').readAsBytesSync(),
          oldExeBytes,
        );
        expect(ServerReleaseInfo.readFrom(root)!.sequence, 120);
        expect(
          File(p.join(root.path, 'lib', 'libkeep.so')).readAsStringSync(),
          'keep v2',
        );
        expect(
          File(p.join(root.path, 'lib', 'libnew.so')).existsSync(),
          isTrue,
        );
        // 新包里没有的文件不动。
        expect(
          File(p.join(root.path, 'lib', 'libold.so')).readAsStringSync(),
          'old lib',
        );
        expect(
          File(p.join(root.path, 'fushi_server.yaml')).readAsStringSync(),
          'config',
        );
        expect(
          File(
            p.join(root.path, 'data', 'support', 'fushi.db'),
          ).readAsStringSync(),
          'db',
        );
        expect(
          File(p.join(root.path, kServerUpdateJournalFile)).existsSync(),
          isFalse,
        );
        if (!Platform.isWindows) {
          // tar 保留可执行位。
          final ProcessResult mode = await Process.run('stat', <String>[
            '-c',
            '%a',
            exe,
          ]);
          expect((mode.stdout as String).trim(), '755');
        }

        // ── 旧进程退出（serve 收到 onInstalled 后以 75 退出），服务管理器拉起新版 ──
        running.kill(ProcessSignal.sigkill);
        await running.exitCode;
        running = null;
        final ServerUpdateRecovery recovery = await recoverServerSelfUpdate(
          installRoot: root,
          runningExecutable: exe,
        );
        expect(recovery, ServerUpdateRecovery.proceed);
        final List<String> leftovers = <String>[
          for (final FileSystemEntity e in root.listSync(recursive: true))
            if (e.path.endsWith(kServerUpdateOldSuffix) ||
                e.path.endsWith(kServerUpdateRollbackSuffix))
              e.path,
        ];
        expect(leftovers, isEmpty);
        expect(
          File(p.join(root.path, kServerUpdateCleanupFile)).existsSync(),
          isFalse,
        );
        expect(
          Directory(p.join(root.path, kServerUpdateStagingDir)).existsSync(),
          isFalse,
        );
        expect(File(exe).readAsBytesSync(), newExeBytes);
      } finally {
        running?.kill(ProcessSignal.sigkill);
        if (running != null) await running.exitCode;
        await http?.close(force: true);
        await tmp.delete(recursive: true);
      }
    },
    skip: hanging == null || suffix == null
        ? 'needs a copyable long-running system program and a platform with '
              'server release packages (Linux / Windows x64)'
        : false,
  );
}
