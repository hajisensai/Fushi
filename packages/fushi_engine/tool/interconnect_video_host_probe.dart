// 开发取证用：起一台**只提供一条视频**的互联 host（自签 TLS + 指纹 + token），
// 让另一台设备 / 模拟器上的 client 连过来真播（含按档转码的 HLS 路径）。
//
//   FUSHI_FFMPEG=/opt/homebrew/bin/ffmpeg FUSHI_FFPROBE=/opt/homebrew/bin/ffprobe \
//     dart run tool/interconnect_video_host_probe.dart --video /path/clip.mp4 --port 45777
//
// 打印一行 JSON（url / fingerprint / token / videoId），随后一直跑到 stdin 关闭或
// --minutes 到期。纯 Dart，不需要 Flutter。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/video/live_transcode.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';

const String kToken = 'interconnect-video-host-probe-token';
const String kVideoId = 'video/probe-clip';

Future<void> main(List<String> args) async {
  String? video;
  int port = 45777;
  int minutes = 30;
  // `--plain`：明文 http、不建 TLS 身份（用来把 TLS / 中继从取证链里摘掉）。
  bool plain = false;
  // 带值的开关落在最后一个参数位时（`--video` 打完就回车），`args[++i]` 会抛
  // RangeError 而不是报用法，所以先取值再判。
  String? valueFor(int i, String flag) {
    if (i + 1 < args.length) return args[i + 1];
    stderr.writeln('$flag 需要一个值');
    exit(2);
  }

  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--plain':
        plain = true;
      case '--video':
        video = valueFor(i, '--video');
        i++;
      case '--port':
        port = int.parse(valueFor(i, '--port')!);
        i++;
      case '--minutes':
        minutes = int.parse(valueFor(i, '--minutes')!);
        i++;
    }
  }
  if (video == null || !File(video).existsSync()) {
    stderr.writeln('usage: --video <mp4> [--port N] [--minutes N] [--plain]');
    exit(2);
  }
  final Directory dataDir = Directory.systemTemp.createTempSync(
    'fushi_video_host_probe_',
  );
  final FushiTlsIdentity? identity = plain
      ? null
      : await FushiTlsIdentityStore(dataDir: dataDir.path).loadOrCreate();
  final SecurityContext? context = identity == null
      ? null
      : (SecurityContext()
          ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
          ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem)));
  final FushiSyncServer server = FushiSyncServer(
    syncDataDir: dataDir.path,
    port: port,
    token: kToken,
    allowLan: true,
    libraryService: _SingleClipLibraryService(File(video)),
    securityContext: context,
    hostFingerprint: identity?.fingerprintSha256,
  );
  await server.start();
  stdout.writeln(
    jsonEncode(<String, Object?>{
      'url': '${plain ? 'http' : 'https'}://127.0.0.1:${server.port}',
      'fingerprint': identity?.fingerprintSha256,
      'token': kToken,
      'videoId': kVideoId,
      'transcodeAvailable': transcodeAvailable(),
    }),
  );
  await stdout.flush();
  // 存活到 --minutes 到期或收到 SIGINT / SIGTERM；不看 stdin（nohup 起时 stdin 是
  // /dev/null，一上来就 EOF）。
  final Completer<void> done = Completer<void>();
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  ProcessSignal.sigint.watch().listen((_) => finish());
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => finish());
  }
  Timer(Duration(minutes: minutes), finish);
  await done.future;
  await server.stop();
  dataDir.deleteSync(recursive: true);
}

class _SingleClipLibraryService implements FushiLibraryHostService {
  _SingleClipLibraryService(this.clip);

  final File clip;
  ({int positionMs, int updatedAtMs}) _position = (
    positionMs: 0,
    updatedAtMs: 0,
  );

  @override
  Future<List<RemoteVideoInfo>> listVideos() async => <RemoteVideoInfo>[
    RemoteVideoInfo(
      id: kVideoId,
      title: 'probe clip',
      sizeBytes: clip.lengthSync(),
    ),
  ];

  @override
  Future<bool> videoExists(String id) async => id == kVideoId;

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      id == kVideoId ? clip : null;

  @override
  Future<File?> resolveVideoSubtitle(
    String id, {
    String langCode = 'ja',
    int episodeIndex = 0,
  }) async => null;

  @override
  Future<String?> videoCoverPath(String id) async => null;

  @override
  Future<List<RemoteActivityEvent>> listActivityEvents({
    int limit = 100,
  }) async => const <RemoteActivityEvent>[];

  @override
  Future<({int positionMs, int updatedAtMs})> getVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async => _position;

  @override
  Future<void> putVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {
    _position = (positionMs: positionMs, updatedAtMs: updatedAtMs);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}
