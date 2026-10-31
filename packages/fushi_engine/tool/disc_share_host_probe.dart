// 开发取证用：起一台**只共享一张原盘**的互联 host（远端原盘第二期），签发一次盘目录
// 共享会话，打印会话根 URL，供 `tool/bluray/verify_menu_render.py --remote-disc` /
// `--remote-dvd` 让 libmpv 经 HTTP 读这张盘的原盘菜单。
//
//   dart run tool/disc_share_host_probe.dart --disc "D:/video/<盘>" [--port N] [--minutes N]
//
// 明文 http、只听 loopback（取证链里不需要 TLS——生产路径的 TLS 由 app 中继终结，
// libmpv 永远只看到 loopback 明文）。打印一行 JSON（baseUrl / device / manifest 概要），
// 随后一直跑到 --minutes 到期或 Ctrl+C。只读盘，从不写盘根下任何文件。纯 Dart。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/video/disc/disc_share_manifest.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';

const String kToken = 'disc-share-host-probe-token';
const String kVideoId = 'video/probe-disc';

Future<void> main(List<String> args) async {
  String? disc;
  int port = 0;
  int minutes = 30;
  String? valueFor(int i, String flag) {
    if (i + 1 < args.length) return args[i + 1];
    stderr.writeln('$flag 需要一个值');
    exit(2);
  }

  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--disc':
        disc = valueFor(i, '--disc');
        i++;
      case '--port':
        port = int.parse(valueFor(i, '--port')!);
        i++;
      case '--minutes':
        minutes = int.parse(valueFor(i, '--minutes')!);
        i++;
    }
  }
  if (disc == null ||
      FileSystemEntity.typeSync(disc) == FileSystemEntityType.notFound) {
    stderr.writeln(
      'usage: --disc <disc root or .iso> [--port N] [--minutes N]',
    );
    exit(2);
  }
  final Directory dataDir = Directory.systemTemp.createTempSync(
    'fushi_disc_share_probe_',
  );
  final FushiSyncServer server = FushiSyncServer(
    syncDataDir: dataDir.path,
    port: port,
    token: kToken,
    libraryService: _SingleDiscHost(disc),
  );
  await server.start();
  final HttpClient client = HttpClient();
  final HttpClientRequest request = await client.getUrl(
    Uri.parse(
      'http://127.0.0.1:${server.port}/api/library/videos/'
      '${Uri.encodeComponent(kVideoId)}/disc',
    ),
  );
  request.headers.set(
    'authorization',
    'Basic ${base64Encode(utf8.encode('hibiki:$kToken'))}',
  );
  final HttpClientResponse response = await request.close();
  final String body = await response.transform(utf8.decoder).join();
  client.close();
  if (response.statusCode != 200) {
    stderr.writeln('issue failed: ${response.statusCode} $body');
    await server.stop();
    exit(1);
  }
  final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
  final DiscShareManifest manifest = DiscShareManifest.fromJson(
    json['manifest'],
  )!;
  final String baseUrl = json['baseUrl'] as String;
  stdout.writeln(
    jsonEncode(<String, Object?>{
      'baseUrl': baseUrl,
      'device': manifest.layout == DiscShareLayout.image
          ? '${baseUrl}files/${Uri.encodeComponent(manifest.files.single.path)}'
          : baseUrl,
      'format': manifest.format.name,
      'layout': manifest.layout.name,
      'aacs': manifest.aacs,
      'files': manifest.files.length,
      'totalBytes': manifest.totalBytes,
    }),
  );
  await stdout.flush();
  final Completer<void> done = Completer<void>();
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  ProcessSignal.sigint.watch().listen((_) => finish());
  Timer(Duration(minutes: minutes), finish);
  await done.future;
  await server.stop();
  dataDir.deleteSync(recursive: true);
}

class _SingleDiscHost implements FushiLibraryHostService, VideoDiscShareHost {
  _SingleDiscHost(this.root);

  final String root;

  @override
  Future<String?> resolveVideoDiscRoot(String id) async =>
      id == kVideoId ? root : null;

  @override
  Future<List<({String id, String path})>> videoTitlesOnDisc(
    String discRoot,
  ) async => const <({String id, String path})>[];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
