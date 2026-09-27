// `.strm` 起播链路（stream_video_launch.dart）与直播断点门：
// - isStreamVideoBook：`.strm`（本地 / 网络）与 rtsp 等直播协议都走流播分支；
// - resolveStrmStreamTarget：本地读文件、远端带「读 .strm 用」的头 GET、AList
//   解析器换直链；本地路径 / 空文件 / 未知协议给类型化失败；
// - 读 `.strm` 的认证头只用于 `.strm` 本身，不外溢到目标地址（由调用方按目标
//   地址重新解析，见 video_fushi_page 的 STRM 分支）；
// - shouldPersistStreamPosition：直播（无时长）不写断点。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/stream_url_resolver.dart';
import 'package:fushi/src/media/video/stream_video_launch.dart';
import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/media/video/video_watch_tracker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

class _PrefixResolver implements StreamUrlResolver {
  final List<String> seen = <String>[];

  @override
  Future<String> resolve(String url) async {
    seen.add(url);
    return '$url&signed=1';
  }

  @override
  void close() {}
}

Future<VideoBookRow> _row(FushiDatabase db, String videoPath) async {
  final VideoBookRepository repo = VideoBookRepository(db);
  final String uid = 'video/${p.basename(videoPath)}';
  await repo.saveVideoBook(VideoBooksCompanion(
    bookUid: Value(uid),
    title: const Value('t'),
    videoPath: Value(videoPath),
    importedAt: const Value(1),
  ));
  return (await repo.getByBookUid(uid))!;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('strm_launch_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('isStreamVideoBook：.strm 与直播协议走流播，本地视频不走', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(isStreamVideoBook(await _row(db, r'D:\lib\a.strm')), isTrue);
    expect(isStreamVideoBook(await _row(db, 'https://nas/dav/b.strm')), isTrue);
    expect(isStreamVideoBook(await _row(db, 'rtsp://cam/live')), isTrue);
    expect(isStreamVideoBook(await _row(db, 'https://a/v.mp4')), isTrue);
    expect(isStreamVideoBook(await _row(db, r'D:\lib\c.mkv')), isFalse);
  });

  group('resolveStrmStreamTarget', () {
    test('本地 .strm：读文件取首条地址', () async {
      final File f = File(p.join(tmp.path, 'Show S01E01.strm'))
        ..writeAsStringSync(
            '\uFEFF# comment\r\nhttps://cdn.example/e1.m3u8\r\n');
      expect(
          await resolveStrmStreamTarget(f.path), 'https://cdn.example/e1.m3u8');
    });

    test('本地目标 / 空文件 / 未知协议 / 文件不存在：类型化失败', () async {
      Future<StrmResolveFailure> failureOf(String content) async {
        final File f = File(p.join(tmp.path, 'x.strm'))
          ..writeAsStringSync(content);
        try {
          await resolveStrmStreamTarget(f.path);
        } on StrmResolveException catch (e) {
          return e.failure;
        }
        fail('expected StrmResolveException');
      }

      expect(
          await failureOf(r'D:\Movies\a.mkv'), StrmResolveFailure.localTarget);
      expect(await failureOf('# nothing\n'), StrmResolveFailure.empty);
      expect(await failureOf('plugin://x/?id=1'),
          StrmResolveFailure.unsupportedTarget);
      await expectLater(
        resolveStrmStreamTarget(p.join(tmp.path, 'missing.strm')),
        throwsA(isA<StrmResolveException>().having(
            (StrmResolveException e) => e.failure,
            'failure',
            StrmResolveFailure.unreadable)),
      );
    });

    test('远端 .strm：经解析器换直链、带读 .strm 的头 GET', () async {
      final List<http.Request> requests = <http.Request>[];
      final MockClient client = MockClient((http.Request req) async {
        requests.add(req);
        return http.Response('rtsp://third-party.example/live\n', 200);
      });
      final _PrefixResolver resolver = _PrefixResolver();
      final String target = await resolveStrmStreamTarget(
        'https://nas.example/d/tv/ch.strm?x=0',
        strmHttpHeaders: const <String, String>{'Authorization': 'Basic abc'},
        urlResolver: resolver,
        httpClient: client,
      );
      expect(target, 'rtsp://third-party.example/live');
      expect(resolver.seen, <String>['https://nas.example/d/tv/ch.strm?x=0']);
      expect(requests.single.url.toString(),
          'https://nas.example/d/tv/ch.strm?x=0&signed=1');
      expect(requests.single.headers['Authorization'], 'Basic abc');
    });

    test('远端 .strm 非 2xx：unreadable', () async {
      final MockClient client =
          MockClient((http.Request req) async => http.Response('no', 404));
      await expectLater(
        resolveStrmStreamTarget('https://nas.example/a.strm',
            httpClient: client),
        throwsA(isA<StrmResolveException>().having(
            (StrmResolveException e) => e.failure,
            'failure',
            StrmResolveFailure.unreadable)),
      );
    });
  });

  test('buildStreamVideoLaunch：STRM 目标行不带来源凭据（按目标地址收口后为空）', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final VideoBookRow strmRow = await _row(db, 'https://nas/dav/c.strm');
    // 页面把 videoPath 换成目标地址后再建客户端；来源头按目标地址解析，
    // 第三方主机拿到的是空 map。
    final ({UrlStreamVideoClient client, RemoteVideoInfo info}) launch =
        await buildStreamVideoLaunch(
      strmRow.copyWith(videoPath: 'https://cdn.other.example/c.m3u8'),
    );
    addTearDown(launch.client.close);
    expect(launch.client.streamUrl, 'https://cdn.other.example/c.m3u8');
    expect(launch.client.httpHeaderFields, isEmpty);
    expect(launch.info.id, strmRow.bookUid);
  });

  test('shouldPersistStreamPosition：直播（时长未知 / 0）不写断点', () {
    expect(shouldPersistStreamPosition(durationMs: null), isFalse);
    expect(shouldPersistStreamPosition(durationMs: 0), isFalse);
    expect(shouldPersistStreamPosition(durationMs: 1), isTrue);
  });
}
