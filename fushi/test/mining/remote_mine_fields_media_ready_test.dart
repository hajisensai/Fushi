import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression, FfmpegFailureReporter;

import '../helpers/source_guard.dart';

/// 手机遥控制卡：词典媒体缓存在冻结播放器输入**之后**才开写。
///
/// 旧实现先 `await writeDictionaryMediaCache(...)` 再调 `_mineVideoCard`，而后者才冻结
/// `_controller`（媒体源 / 音轨 / 集号）。那段 await 里手机 `openFavorite` 或电脑本地
/// 换集，卡片就用旧集字幕的时间去裁新集的音频和画面。现在写缓存作为
/// [ImmersionMiningRequest.fieldsMediaReady] 挂进已冻结的请求，引擎在队列里等它写完
/// 才抽媒体、落卡。本文件钉引擎这一侧的等待语义与页面这一侧「宿主调用到冻结之间
/// 没有 await」的接线。
class _CountingRepo implements BaseAnkiRepository {
  int mines = 0;

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    mines++;
    return const MineOutcome.success(noteId: 1);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Spy {
  final List<String> calls = <String>[];

  Future<String?> takeGif({
    required String inputPath,
    required int startMs,
    required int endMs,
    required String outputPath,
    int fps = 8,
    int width = 320,
    MiningAnimatedFormat format = MiningAnimatedFormat.gif,
    bool diagnosticOnly = false,
    FfmpegFailureReporter? onFailure,
    String? tlsPinSha256,
    Map<String, String> httpHeaders = const {},
  }) async {
    calls.add('gif');
    return outputPath;
  }

  Future<String?> takeAudio({
    required String inputPath,
    required int startMs,
    required int endMs,
    required String outputPath,
    int? audioStreamIndex,
    int? audioStreamCount,
    FfmpegFailureReporter? onFailure,
    int audioChannels = 1,
    String audioBitrate = '64k',
    String? tlsPinSha256,
    Map<String, String> httpHeaders = const {},
  }) async {
    calls.add('audio');
    return outputPath;
  }

  Future<String?> takeFrame({
    required String inputPath,
    required String outputPath,
    double atSeconds = 10.0,
    FfmpegFailureReporter? onFailure,
    String? tlsPinSha256,
    Map<String, String> httpHeaders = const {},
    bool diagnosticOnly = false,
  }) async {
    calls.add('frame');
    return outputPath;
  }
}

Future<String?> _noMaterialize({
  required String audioUrl,
  required String outputPath,
  FfmpegFailureReporter? onFailure,
}) async => null;

ImmersionMiningRequest _request(Future<void>? fieldsMediaReady) =>
    ImmersionMiningRequest(
      fields: const <String, String>{'expression': 'x'},
      mediaSource: 'http://cdn.example-hoster.net:443/hls/index',
      clipStartMs: 1000,
      clipEndMs: 3000,
      sentence: 's',
      documentTitle: 'Episode 1',
      source: AnkiMiningSource.video,
      requireAudio: true,
      fieldsMediaReady: fieldsMediaReady,
    );

Future<ImmersionMiningResult> _mine(
  _Spy spy,
  _CountingRepo repo,
  Directory tmp,
  Future<void>? fieldsMediaReady,
) =>
    ImmersionMiningEngine(
      gifExtractor: spy.takeGif,
      audioExtractor: spy.takeAudio,
      frameExtractor: spy.takeFrame,
      audioMaterializer: _noMaterialize,
    ).mine(
      _request(fieldsMediaReady),
      compression: MiningMediaCompression.resolve(
        imageTier: 1,
        audioTier: 0,
        format: MiningAnimatedFormat.gif,
      ),
      tempDir: tmp.path,
      repo: repo,
    );

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mining_fields_media');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('词典媒体缓存写完之前，引擎不抽媒体、不落卡', () async {
    final _Spy spy = _Spy();
    final _CountingRepo repo = _CountingRepo();
    final Completer<void> written = Completer<void>();
    final Future<ImmersionMiningResult> mining = _mine(
      spy,
      repo,
      tmp,
      written.future,
    );
    for (int i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(spy.calls, isEmpty, reason: '缓存没写完就抽取 = 落卡时读不到外字字节');
    expect(repo.mines, 0);

    written.complete();
    await mining;
    expect(spy.calls, contains('audio'));
  });

  test('写缓存失败：本次制卡按失败结束，排队期间先失败也不成未处理错误', () async {
    final _Spy spy = _Spy();
    final _CountingRepo repo = _CountingRepo();
    // 已失败的 Future 在入队当下就交给引擎；引擎必须同步挂上错误处理。
    final Future<void> failed = Future<void>.error(StateError('cache write'));
    final Future<ImmersionMiningResult> mining = _mine(spy, repo, tmp, failed);
    await expectLater(mining, throwsA(isA<StateError>()));
    expect(spy.calls, isEmpty);
    expect(repo.mines, 0);
  });

  test('frozen() 保留写缓存信号', () {
    final Future<void> ready = Future<void>.value();
    expect(_request(ready).frozen().fieldsMediaReady, same(ready));
    expect(
      _request(ready)
          .withCachedSnapshot(
            const CachedMediaSnapshot(path: '/tmp/snapshot.mkv', zeroMs: 0),
          )
          .fieldsMediaReady,
      same(ready),
    );
  });

  group('源码扫描守卫：遥控制卡在冻结之后才写缓存', () {
    // `_mineRemoteVideoCue` / `_mineVideoCard` 是页面 State 的私有方法，没有可注入的
    // 缝；与 `remote_mining_relay_route_test.dart` 的接线守卫同形。
    late String remote;
    late String mining;
    setUpAll(() {
      remote = maskComments(
        File(
          'lib/src/pages/implementations/video_fushi/remote_control.part.dart',
        ).readAsStringSync(),
      );
      mining = maskComments(
        File(
          'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart',
        ).readAsStringSync(),
      );
    });

    test('宿主调用到 _mineVideoCard 冻结之间没有任何 await', () {
      final String body = methodBody(
        remote,
        'Future<Map<String, Object?>> _mineRemoteVideoCue(',
      );
      final int call = body.indexOf('await _mineVideoCard(');
      expect(call, greaterThanOrEqualTo(0));
      expect(
        RegExp(r'\bawait\b').allMatches(body.substring(0, call)),
        isEmpty,
        reason: '这段 await 里换集，卡片会裁到新一集',
      );
    });

    test('写缓存只作为 writeFieldsMedia 交给 _mineVideoCard', () {
      final String body = methodBody(
        remote,
        'Future<Map<String, Object?>> _mineRemoteVideoCue(',
      );
      expect(
        compactCode(body),
        contains('writeFieldsMedia:()=>writeDictionaryMediaCache('),
      );
      expect(body, isNot(contains('await writeDictionaryMediaCache(')));
    });

    test('_mineVideoCard 把写缓存挂进已冻结的请求', () {
      expect(
        compactCode(methodBody(mining, 'ImmersionMiningRequest(')),
        contains('fieldsMediaReady:writeFieldsMedia?.call()'),
      );
    });
  });
}
