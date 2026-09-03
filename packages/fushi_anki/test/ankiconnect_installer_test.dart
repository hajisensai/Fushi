import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/src/ankiconnect/ankiconnect_installer.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 造一个「AnkiWeb 下发的裸包」——只有源码，**没有** manifest.json。
/// 这正是实测下来 AnkiConnect 包的形状（`__init__.py`/`config.json`/…）。
Uint8List _bareAddonZip({Map<String, String>? extra}) {
  final Archive archive = Archive();
  final Map<String, String> files = <String, String>{
    '__init__.py': 'from . import web\n',
    'config.json': '{"webBindPort": 8765}\n',
    ...?extra,
  };
  files.forEach((String name, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  final List<int>? encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded!);
}

Map<String, ArchiveFile> _entries(List<int> zip) {
  return <String, ArchiveFile>{
    for (final ArchiveFile file in ZipDecoder().decodeBytes(zip))
      file.name: file,
  };
}

const AnkiWebAddonBranch _branch = AnkiWebAddonBranch(
  modTime: 1762717231,
  minPointVersion: 45,
  maxPointVersion: 45,
  branchIndex: 1,
);

void main() {
  group('下载地址', () {
    // 这条不是形式主义：实测不带 p 时 AnkiWeb 回的是 minpt=0&maxpt=-44 的老分支，
    // 而 max_point_version 为负在 Anki 里是**硬上限**，现代 Anki 会判不兼容并禁用。
    // 少了 p 这个功能就是「装上了但被禁用」，且没有任何报错。
    test('必须带上点版本参数，否则会拿到被现代 Anki 判为不兼容的老分支', () {
      final Uri uri = AnkiConnectInstaller.buildDownloadUri(
        addonId: AnkiConnectInstaller.ankiConnectAddonId,
        pointVersion: 250600,
      );
      expect(uri.queryParameters['p'], '250600');
      expect(uri.queryParameters['v'], '2.1');
      expect(uri.path, endsWith('/2055492159'));
      expect(uri.host, 'ankiweb.net');
    });
  });

  group('分支元信息解析', () {
    test('从重定向后的地址取出 t / minpt / maxpt / bidx', () {
      final AnkiWebAddonBranch branch = AnkiWebAddonBranch.fromDownloadUri(
        Uri.parse(
          'https://ankiweb.net/svc/shared/download-addon/2055492159'
          '?t=1762717231&minpt=45&maxpt=45&bidx=1',
        ),
      );
      expect(branch.modTime, 1762717231);
      expect(branch.minPointVersion, 45);
      expect(branch.maxPointVersion, 45);
      expect(branch.branchIndex, 1);
    });

    test('负的 maxpt 原样保留——它是硬上限，不能被归一化掉', () {
      final AnkiWebAddonBranch branch = AnkiWebAddonBranch.fromDownloadUri(
        Uri.parse('https://x/y?t=1&minpt=0&maxpt=-44&bidx=0'),
      );
      expect(branch.maxPointVersion, -44);
    });

    // 缺字段时宁可失败：猜一个默认值写进 manifest 会让 Anki 拿错误的兼容区间
    // 去判定，症状是「装上了却被静默禁用」，比当场报错难查得多。
    test('缺字段或非整数一律抛，不静默兜底', () {
      expect(
        () => AnkiWebAddonBranch.fromDownloadUri(
          Uri.parse('https://x/y?t=1&minpt=45&bidx=1'),
        ),
        throwsFormatException,
      );
      expect(
        () => AnkiWebAddonBranch.fromDownloadUri(
          Uri.parse('https://x/y?t=1&minpt=45&maxpt=x&bidx=1'),
        ),
        throwsFormatException,
      );
    });
  });

  group('重新打包', () {
    test('给裸包补上 manifest.json，且原有文件一个不少', () {
      final Uint8List repacked = AnkiConnectInstaller.repackWithManifest(
        downloadedZip: _bareAddonZip(),
        manifest: AnkiConnectInstaller.buildManifest(
          addonId: AnkiConnectInstaller.ankiConnectAddonId,
          addonName: AnkiConnectInstaller.ankiConnectAddonName,
          branch: _branch,
        ),
      );

      final Map<String, ArchiveFile> entries = _entries(repacked);
      expect(entries.keys, containsAll(<String>['__init__.py', 'config.json']));
      expect(entries['manifest.json'], isNotNull,
          reason: 'AnkiWeb 裸包没有 manifest，不补 Anki 会直接 InstallError("manifest")');

      // 原文件内容必须原样带过去，不能被重新打包弄坏。
      expect(
        utf8.decode(entries['__init__.py']!.content as List<int>),
        'from . import web\n',
      );

      final Map<String, Object?> manifest = jsonDecode(
        utf8.decode(entries['manifest.json']!.content as List<int>),
      ) as Map<String, Object?>;
      // package 同时是安装目录名，错了 AnkiConnect 就找不到自己的配置。
      expect(manifest['package'], '2055492159');
      expect(manifest['name'], 'AnkiConnect');
      expect(manifest['mod'], 1762717231);
      expect(manifest['min_point_version'], 45);
      expect(manifest['max_point_version'], 45);
      expect(manifest['branch_index'], 1);
    });

    test('包内已有 manifest.json 时原样保留，不被我们复刻的版本覆盖', () {
      final Uint8List repacked = AnkiConnectInstaller.repackWithManifest(
        downloadedZip: _bareAddonZip(
          extra: <String, String>{
            'manifest.json': '{"package":"upstream","name":"Upstream"}',
          },
        ),
        manifest: AnkiConnectInstaller.buildManifest(
          addonId: 'ours',
          addonName: 'Ours',
          branch: _branch,
        ),
      );

      final Map<String, Object?> manifest = jsonDecode(
        utf8.decode(_entries(repacked)['manifest.json']!.content as List<int>),
      ) as Map<String, Object?>;
      expect(manifest['package'], 'upstream');
      expect(manifest['name'], 'Upstream');
    });

    test('空包直接失败，不产出一个只有 manifest 的壳', () {
      final List<int> emptyZip = ZipEncoder().encode(Archive())!;
      expect(
        () => AnkiConnectInstaller.repackWithManifest(
          downloadedZip: emptyZip,
          manifest: const <String, Object?>{'package': 'x', 'name': 'x'},
        ),
        throwsFormatException,
      );
    });
  });

  group('下载与重定向', () {
    // 这组守的是整个功能的前提：分支元信息（t/minpt/maxpt/bidx）**只**存在于
    // 重定向之后那个 URL 的 query 里。用 package:http 的自动跟随会把最终 URL
    // 丢掉，于是只能去猜兼容区间——猜错的症状是「装上了却被 Anki 静默禁用」。
    test('跟随 303，把重定向后的最终地址（带分支 query）交回来', () async {
      final List<String> visited = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        visited.add(req.url.toString());
        if (req.url.path.startsWith('/shared/download')) {
          return http.Response(
            '',
            303,
            headers: <String, String>{
              'location': '/svc/shared/download-addon/2055492159'
                  '?t=1762717231&minpt=45&maxpt=45&bidx=1',
            },
            isRedirect: true,
          );
        }
        return http.Response.bytes(<int>[1, 2, 3], 200);
      });

      final AnkiWebAddonDownload download = await downloadFollowingRedirects(
        client,
        Uri.parse(
          'https://ankiweb.net/shared/download/2055492159?v=2.1&p=250600',
        ),
        maxBytes: 1024,
      );

      expect(download.bytes, <int>[1, 2, 3]);
      // 相对 Location 必须被解析成绝对地址，主机不能丢。
      expect(download.resolvedUri.host, 'ankiweb.net');
      expect(download.resolvedUri.queryParameters['bidx'], '1');
      expect(download.resolvedUri.queryParameters['minpt'], '45');
      expect(visited.length, 2);

      // 解析出来的分支元信息要能直接喂给 manifest。
      final AnkiWebAddonBranch branch =
          AnkiWebAddonBranch.fromDownloadUri(download.resolvedUri);
      expect(branch.modTime, 1762717231);
      expect(branch.branchIndex, 1);
    });

    test('非 200 直接失败，不把错误页当插件包', () async {
      final MockClient client =
          MockClient((http.Request req) async => http.Response('nope', 404));

      expect(
        () => downloadFollowingRedirects(
          client,
          Uri.parse('https://ankiweb.net/shared/download/1'),
          maxBytes: 1024,
        ),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('超出体积上限时中断，不把内存吃光', () async {
      final MockClient client = MockClient(
        (http.Request req) async =>
            http.Response.bytes(List<int>.filled(4096, 7), 200),
      );

      expect(
        () => downloadFollowingRedirects(
          client,
          Uri.parse('https://ankiweb.net/shared/download/1'),
          maxBytes: 16,
        ),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('重定向成环时有上限，不无限跟下去', () async {
      int hops = 0;
      final MockClient client = MockClient((http.Request req) async {
        hops++;
        return http.Response(
          '',
          303,
          headers: <String, String>{'location': '/loop'},
          isRedirect: true,
        );
      });

      await expectLater(
        downloadFollowingRedirects(
          client,
          Uri.parse('https://ankiweb.net/loop'),
          maxBytes: 1024,
          maxRedirects: 3,
        ),
        throwsA(isA<http.ClientException>()),
      );
      expect(hops, 4);
    });
  });

  group('安装编排', () {
    tearDown(() => AnkiConnectInstaller.debugHost = null);

    test('Anki 没在运行时不下载、不落盘、不起进程', () async {
      final _FakeHost host = _FakeHost(ankiExecutable: null);
      AnkiConnectInstaller.debugHost = host;

      final AnkiAddonInstallResult result =
          await AnkiConnectInstaller.install();

      expect(result.status, AnkiAddonInstallStatus.ankiNotRunning);
      expect(host.events, isEmpty);
    });

    test('成功路径：把补好 manifest 的包交给正在运行的那个 anki.exe', () async {
      final _FakeHost host = _FakeHost(
        ankiExecutable: r'C:\Program Files\Anki\anki.exe',
      );
      AnkiConnectInstaller.debugHost = host;

      final AnkiAddonInstallResult result =
          await AnkiConnectInstaller.install();

      expect(result.status, AnkiAddonInstallStatus.handedToAnki);
      expect(result.isHandedToAnki, isTrue);
      expect(host.events, <String>['download', 'write', 'launch']);
      // 必须用进程自己报出来的路径，不能是别处猜的。
      expect(host.launchedExecutable, r'C:\Program Files\Anki\anki.exe');
      // 扩展名必须是 .ankiaddon：Anki 的 _isAddon 只认 exts[0]，用 .zip 会被
      // 当成牌组导入走错分支。
      expect(host.writtenFileName, endsWith('.ankiaddon'));
      expect(host.launchedPath, endsWith('.ankiaddon'));

      // 交出去的确实是补过 manifest 的包，不是原样转发。
      expect(_entries(host.writtenBytes!)['manifest.json'], isNotNull);
    });

    test('下载失败时如实返回，不继续往下走', () async {
      final _FakeHost host = _FakeHost(
        ankiExecutable: r'C:\Anki\anki.exe',
        downloadError: StateError('boom'),
      );
      AnkiConnectInstaller.debugHost = host;

      final AnkiAddonInstallResult result =
          await AnkiConnectInstaller.install();

      expect(result.status, AnkiAddonInstallStatus.downloadFailed);
      expect(result.detail, contains('boom'));
      expect(host.events, <String>['download']);
    });

    test('下载到的不是插件包时报 invalidPackage', () async {
      final _FakeHost host = _FakeHost(
        ankiExecutable: r'C:\Anki\anki.exe',
        payload: Uint8List.fromList(utf8.encode('<html>404</html>')),
      );
      AnkiConnectInstaller.debugHost = host;

      final AnkiAddonInstallResult result =
          await AnkiConnectInstaller.install();

      expect(result.status, AnkiAddonInstallStatus.invalidPackage);
      expect(host.events, <String>['download']);
    });

    test('重定向地址缺分支参数时也算 invalidPackage，不会交出错误 manifest', () async {
      final _FakeHost host = _FakeHost(
        ankiExecutable: r'C:\Anki\anki.exe',
        resolvedUri: Uri.parse('https://ankiweb.net/no-query'),
      );
      AnkiConnectInstaller.debugHost = host;

      final AnkiAddonInstallResult result =
          await AnkiConnectInstaller.install();

      expect(result.status, AnkiAddonInstallStatus.invalidPackage);
      expect(host.events, <String>['download']);
    });

    test('起进程失败时报 launchFailed', () async {
      final _FakeHost host = _FakeHost(
        ankiExecutable: r'C:\Anki\anki.exe',
        launchError: ProcessException('anki.exe', <String>[], 'denied'),
      );
      AnkiConnectInstaller.debugHost = host;

      final AnkiAddonInstallResult result =
          await AnkiConnectInstaller.install();

      expect(result.status, AnkiAddonInstallStatus.launchFailed);
      expect(host.events, <String>['download', 'write', 'launch']);
    });
  });
}

class _FakeHost implements AnkiConnectInstallerHost {
  _FakeHost({
    required this.ankiExecutable,
    Uint8List? payload,
    Uri? resolvedUri,
    this.downloadError,
    this.launchError,
  })  : payload = payload ?? _bareAddonZip(),
        resolvedUri = resolvedUri ??
            Uri.parse(
              'https://ankiweb.net/svc/shared/download-addon/2055492159'
              '?t=1762717231&minpt=45&maxpt=45&bidx=1',
            );

  final String? ankiExecutable;
  final Uint8List payload;
  final Uri resolvedUri;
  final Object? downloadError;
  final Object? launchError;

  final List<String> events = <String>[];
  Uint8List? writtenBytes;
  String? writtenFileName;
  String? launchedExecutable;
  String? launchedPath;

  @override
  String? findRunningAnkiExecutable() => ankiExecutable;

  @override
  Future<AnkiWebAddonDownload> download(Uri uri,
      {required int maxBytes}) async {
    events.add('download');
    if (downloadError != null) throw downloadError!;
    return AnkiWebAddonDownload(bytes: payload, resolvedUri: resolvedUri);
  }

  @override
  Future<String> writeTempAddon(String fileName, Uint8List bytes) async {
    events.add('write');
    writtenFileName = fileName;
    writtenBytes = bytes;
    return 'C:\\Temp\\$fileName';
  }

  @override
  Future<void> launch(String executable, String addonPath) async {
    events.add('launch');
    launchedExecutable = executable;
    launchedPath = addonPath;
    if (launchError != null) throw launchError!;
  }
}
