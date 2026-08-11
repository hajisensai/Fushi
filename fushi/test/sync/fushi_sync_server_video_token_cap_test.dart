import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';

/// BUG-1568（BUG-908(a) 的视频同形问题）：视频流 token 签发侧必须有上限 + 过期清理。
///
/// 此前 `_pruneVideoTokens` 只挂在 GET /stream **消费侧**——只 GET /streamurl 却
/// 从不取流的调用者（爬清单的脚本 / 反复进出视频页的 client）会让
/// `_videoStreamTokens` 无界堆积：6 小时 TTL 内每次签发都是净增长，prune 永远等
/// 不到。修法对照 audio token：签发前先 TTL prune、再淘汰最旧者收束到上限内。
///
/// 只实现 streamurl 路径需要的两个方法，其余经 noSuchMethod 抛（本测试不该触达）。
class _StreamOnlyLibraryService implements FushiLibraryHostService {
  _StreamOnlyLibraryService(this.videoFile);

  final File videoFile;

  Future<File?> _resolve() async => videoFile;

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) =>
      _resolve();

  @override
  Future<File?> resolveVideoSubtitle(
    String id, {
    String langCode = '',
    int episodeIndex = 0,
  }) async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('BUG-1568 视频流 token 签发侧上限', () {
    late FushiSyncServer server;
    late Directory tempDir;
    const String token = 'bug1568-video-cap';
    late String base;
    final DateTime clock = DateTime(2026, 1, 1, 12, 0, 0);

    String authHeader() =>
        'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('hbk_video_cap');
      final File video = File('${tempDir.path}/sample.mp4')
        ..writeAsBytesSync(<int>[0, 1, 2, 3]);
      server = FushiSyncServer(
        syncDataDir: tempDir.path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: _StreamOnlyLibraryService(video),
        // 时钟固定：所有 token 都在 6 小时 TTL 内，TTL prune 清不掉任何 token，
        // 数量收束只能来自签发侧 cap 逐出——这才真正验证 cap 生效。
        now: () => clock,
      );
      await server.start();
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async {
      await server.stop();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<void> mintOne(int i) async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req = await c.getUrl(
        Uri.parse('$base/api/library/videos/vid-$i/streamurl'),
      );
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 200);
      await res.drain<void>();
      c.close();
    }

    test('狂发 streamurl 签发时 token 数被上限约束（最旧被逐出）', () async {
      // 连发超过上限（128）的签发请求，全在 TTL 内（时钟不动）。每次签发都会
      // 附带一次内嵌字幕枚举（ffmpeg -i，失败降级空表），故迭代数取「必然越界」
      // 的最小量级并放宽超时。
      for (int i = 0; i < 150; i++) {
        await mintOne(i);
      }
      expect(server.videoStreamTokenCount, lessThanOrEqualTo(128),
          reason: '签发侧必须先 prune 再 enforce cap，'
              '否则 _videoStreamTokens 无界膨胀（BUG-1568）');
      expect(server.videoStreamTokenCount, greaterThan(0));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
