import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_read_aloud_controller.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_pronunciation.dart';
import 'package:fushi_engine/tts/tts_retry.dart';
import 'package:fushi_engine/tts/tts_synthesis_scheduler.dart';
import 'package:fushi_engine/tts/tts_types.dart';

const Map<String, Object?> _identity = <String, Object?>{'voice': 'test'};

/// 一页：每句一个竖排气泡，列表顺序 = RTL 阅读顺序（越靠前越靠右），彼此远离。
MokuroImage _image(List<String> sentences) => MokuroImage(
  url: 'p.png',
  size: const MokuroSize(1000, 1400),
  blocks: <MokuroBlock>[
    for (int i = 0; i < sentences.length; i++)
      MokuroBlock(
        rectangle: MokuroRect.fromLTRB(
          900 - i * 200.0,
          100,
          940 - i * 200.0,
          400,
        ),
        isVertical: true,
        fontSize: 34,
        zIndex: i,
        lines: <String>[sentences[i]],
      ),
  ],
);

Uint8List _wav() {
  const int dataBytes = 1600;
  final BytesBuilder b = BytesBuilder();
  void ascii(String s) => b.add(s.codeUnits);
  void u32(int v) =>
      b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u16(int v) =>
      b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
  ascii('RIFF');
  u32(36 + dataBytes);
  ascii('WAVE');
  ascii('fmt ');
  u32(16);
  u16(1);
  u16(1);
  u32(8000);
  u32(16000);
  u16(2);
  u16(16);
  ascii('data');
  u32(dataBytes);
  b.add(Uint8List(dataBytes));
  return b.toBytes();
}

class _FakeProvider extends TtsProvider {
  final List<String> calls = <String>[];
  final Set<String> failing = <String>{};

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
  );

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    calls.add(text);
    if (failing.contains(text)) {
      throw const TtsFailure(TtsFailureCode.serverError, 'HTTP 500');
    }
    await File(outputPath).writeAsBytes(_wav());
    return const TtsResult(format: TtsAudioFormat.wav);
  }
}

class _Rig implements MangaReadAloudVoiceRig {
  _Rig(this.provider, this.cache);
  final _FakeProvider provider;
  final TtsAudioCache cache;
  bool disposed = false;

  @override
  int get maxInputLength => 100;

  @override
  TtsSynthesisScheduler createScheduler(List<String> texts) =>
      TtsSynthesisScheduler(
        provider: provider,
        cache: cache,
        texts: texts,
        audioIdentity: _identity,
        retryPolicy: TtsRetryPolicy.none,
      );

  @override
  Future<void> dispose() async => disposed = true;
}

/// 假宿主：spread 两页一组（0-1、2-3…）；[show] 翻到别的 spread 时像真页面一样
/// 同步回报页变化（[onPageChanged]）。
class _Host implements MangaReadAloudHost {
  _Host(this.pages);

  final Map<int, MangaPageTextResult> pages;
  final Map<int, Completer<MangaPageTextResult>> gates =
      <int, Completer<MangaPageTextResult>>{};
  final List<int> ensureCalls = <int>[];
  final List<(int, int)> shown = <(int, int)>[];
  int clears = 0;
  int activity = 0;
  int visible = 0;
  void Function(int page)? onPageChanged;

  @override
  int get pageCount => pages.length;

  @override
  bool get rightToLeft => true;

  @override
  int get visiblePage => visible;

  @override
  bool isSameSpread(int a, int b) => a ~/ 2 == b ~/ 2;

  @override
  Future<MangaPageTextResult> ensurePageText(int pageIndex) {
    ensureCalls.add(pageIndex);
    final Completer<MangaPageTextResult>? gate = gates[pageIndex];
    if (gate != null) return gate.future;
    return Future<MangaPageTextResult>.value(pages[pageIndex]);
  }

  @override
  Future<void> show(int pageIndex, int group) async {
    shown.add((pageIndex, group));
    if (!isSameSpread(pageIndex, visible)) {
      visible = pageIndex - pageIndex % 2;
      onPageChanged?.call(visible);
    }
  }

  @override
  Future<void> clearHighlight() async => clears++;

  @override
  void markStudyActivity() => activity++;
}

class _Player {
  final List<(String, double)> played = <(String, double)>[];
  Completer<bool>? _current;
  int stops = 0;

  bool get playing => _current != null && !_current!.isCompleted;

  Future<bool> playToEnd(String path, double speed) {
    played.add((path, speed));
    final Completer<bool> c = Completer<bool>();
    _current = c;
    return c.future;
  }

  Future<void> stop() async {
    stops++;
    _end(false);
  }

  /// 自然播完。
  void finish() => _end(true);

  /// 别处的播放（查词发音）顶掉了这段。
  void interruptExternally() => _end(false);

  void _end(bool value) {
    final Completer<bool>? c = _current;
    if (c != null && !c.isCompleted) c.complete(value);
  }
}

Future<void> _waitFor(bool Function() condition) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > const Duration(seconds: 5)) {
      throw TimeoutException('condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 80));

void main() {
  late Directory temp;
  late TtsAudioCache cache;
  late _FakeProvider provider;
  late _Rig rig;
  late _Player player;
  late double storedSpeed;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('manga-read-aloud-');
    cache = TtsAudioCache(root: Directory('${temp.path}/cache'));
    provider = _FakeProvider();
    rig = _Rig(provider, cache);
    player = _Player();
    storedSpeed = 1.0;
  });

  tearDown(() async {
    await _settle();
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上缓存文件偶尔还被占着；临时目录由系统清理。
    }
  });

  String pathOf(String text) =>
      cache.audioPathFor(TtsAudioCache.keyFor(_identity, text));

  List<String> playedTexts(List<String> candidates) => <String>[
    for (final (String path, double _) in player.played)
      candidates.firstWhere((String t) => pathOf(t) == path),
  ];

  MangaReadAloudController controllerFor(_Host host) {
    final MangaReadAloudController c = MangaReadAloudController(
      host: host,
      rig: rig,
      pronunciation: const <TtsPronunciationRule>[],
      playToEnd: player.playToEnd,
      stopPlayback: player.stop,
      readSpeed: () => storedSpeed,
      writeSpeed: (double v) async => storedSpeed = v,
    );
    host.onPageChanged = c.onPageChanged;
    return c;
  }

  const List<String> all = <String>['あ。', 'い。', 'う。', 'え。'];

  _Host threePages() => _Host(<int, MangaPageTextResult>{
    0: MangaPageTextReady(_image(<String>['あ。', 'い。'])),
    1: MangaPageTextReady(_image(const <String>[])),
    2: MangaPageTextReady(_image(<String>['う。'])),
  });

  test('跨页按顺序读、程序翻页不重新定位、每句喂学习时钟、倍速透传、章末停下', () async {
    storedSpeed = 1.5;
    final _Host host = threePages();
    final MangaReadAloudController c = controllerFor(host);
    c.start(fromPage: 0);
    await _waitFor(() => player.playing);
    // 开始读第 0 页时就对第 1 页要了文字（预取）。
    expect(host.ensureCalls.take(2), <int>[0, 1]);
    expect(c.state, MangaReadAloudState.playing);
    player.finish();
    await _waitFor(() => player.played.length == 2 && player.playing);
    player.finish();
    await _waitFor(() => player.played.length == 3 && player.playing);
    // 第 2 页在下一个 spread：show 翻过去并回报了页变化，但那是自己翻的。
    expect(host.visible, 2);
    expect(c.state, MangaReadAloudState.playing);
    player.finish();
    await _waitFor(() => c.state == MangaReadAloudState.finished);

    expect(playedTexts(all), <String>['あ。', 'い。', 'う。']);
    expect(host.shown.map(((int, int) s) => s.$1), <int>[0, 0, 2]);
    expect(player.played.map(((String, double) p) => p.$2), <double>[
      1.5,
      1.5,
      1.5,
    ]);
    expect(host.activity, 3);
    expect(c.finish, MangaReadAloudFinish.chapterEnd);
    expect(player.stops, 0);
    c.dispose();
  });

  for (final MangaPageTextUnavailableReason reason
      in MangaPageTextUnavailableReason.values) {
    test('拿不到文字（$reason）就停下并带上原因', () async {
      final _Host host = _Host(<int, MangaPageTextResult>{
        0: MangaPageTextUnavailable(reason),
      });
      final MangaReadAloudController c = controllerFor(host);
      c.start(fromPage: 0);
      await _waitFor(() => c.state == MangaReadAloudState.failed);
      expect((c.problem! as MangaReadAloudTextProblem).reason, reason);
      expect(player.played, isEmpty);
      c.dispose();
    });
  }

  test('未识别页先等文字，识别完再读', () async {
    final _Host host = threePages();
    host.gates[0] = Completer<MangaPageTextResult>();
    final MangaReadAloudController c = controllerFor(host);
    c.start(fromPage: 0);
    await _settle();
    expect(c.state, MangaReadAloudState.preparingText);
    expect(player.played, isEmpty);
    host.gates[0]!.complete(MangaPageTextReady(_image(<String>['あ。'])));
    await _waitFor(() => player.playing);
    expect(playedTexts(all), <String>['あ。']);
    c.stop();
  });

  test('自己 next 打断的 false 不算暂停；外部打断才转 paused 且不前进', () async {
    final _Host host = threePages();
    final MangaReadAloudController c = controllerFor(host);
    c.start(fromPage: 0);
    await _waitFor(() => player.playing);
    c.next();
    // 自己停了全局播放器（正在播自己的句子）。
    expect(player.stops, 1);
    await _waitFor(() => player.played.length == 2 && player.playing);
    expect(c.state, MangaReadAloudState.playing);
    expect(playedTexts(all), <String>['あ。', 'い。']);

    player.interruptExternally();
    await _waitFor(() => c.state == MangaReadAloudState.paused);
    await _settle();
    expect(player.played, hasLength(2));
    expect(c.currentUtterance!.displayText, 'い。');
    // 外部打断时没去 stop 全局播放器（别人的发音不能掐）。
    expect(player.stops, 1);
    c.stop();
  });

  test('用户翻到 spread 之外才重新定位；同 spread 内的页变化忽略', () async {
    final _Host host = threePages();
    final MangaReadAloudController c = controllerFor(host);
    c.start(fromPage: 0);
    await _waitFor(() => player.playing);
    c.onPageChanged(1);
    await _settle();
    expect(player.stops, 0);
    expect(player.played, hasLength(1));

    host.visible = 2;
    c.onPageChanged(2);
    await _waitFor(() => player.played.length == 2 && player.playing);
    expect(playedTexts(all), <String>['あ。', 'う。']);
    expect(c.state, MangaReadAloudState.playing);
    c.stop();
  });

  test('阻塞性合成失败停在当前句，重试后重读同一句', () async {
    provider.failing.add('い。');
    final _Host host = threePages();
    final MangaReadAloudController c = controllerFor(host);
    c.start(fromPage: 0);
    await _waitFor(() => player.playing);
    player.finish();
    await _waitFor(() => c.state == MangaReadAloudState.failed);
    final MangaReadAloudProblem? problem = c.problem;
    expect(problem, isA<MangaReadAloudSynthesisProblem>());
    expect(
      (problem! as MangaReadAloudSynthesisProblem).failure.code,
      TtsFailureCode.serverError,
    );
    expect(c.currentUtterance!.displayText, 'い。');
    expect(player.played, hasLength(1));

    provider.failing.clear();
    c.resume();
    await _waitFor(() => player.played.length == 2 && player.playing);
    expect(playedTexts(all), <String>['あ。', 'い。']);
    c.stop();
  });

  test('暂停 / 继续从当前句开头重读', () async {
    final _Host host = threePages();
    final MangaReadAloudController c = controllerFor(host);
    c.start(fromPage: 0);
    await _waitFor(() => player.playing);
    c.pause();
    expect(c.state, MangaReadAloudState.paused);
    expect(player.stops, 1);
    await _settle();
    expect(c.state, MangaReadAloudState.paused);
    c.resume();
    await _waitFor(() => player.played.length == 2 && player.playing);
    expect(playedTexts(all), <String>['あ。', 'あ。']);
    c.stop();
  });

  test('上一句 / 下一句跨页（跳过没有可读句的页）', () async {
    final _Host host = threePages();
    final MangaReadAloudController c = controllerFor(host);
    c.start(fromPage: 0);
    await _waitFor(() => player.playing);
    c.previous(); // 第一页第一句：原地重读
    await _waitFor(() => player.played.length == 2 && player.playing);
    c.next();
    await _waitFor(() => player.played.length == 3 && player.playing);
    c.next(); // い → 跨过空的第 1 页到第 2 页
    await _waitFor(() => player.played.length == 4 && player.playing);
    c.previous(); // う → 往回跨过空页回到 い
    await _waitFor(() => player.played.length == 5 && player.playing);
    expect(playedTexts(all), <String>['あ。', 'あ。', 'い。', 'う。', 'い。']);
    c.stop();
  });

  test('只有自己在播时 stop 才停全局播放器；dispose 释放调度器与声音', () async {
    final _Host host = threePages();
    host.gates[0] = Completer<MangaPageTextResult>();
    final MangaReadAloudController c = controllerFor(host);
    c.start(fromPage: 0);
    await _settle();
    c.stop();
    expect(player.stops, 0, reason: '还在等文字，没在播，不能掐别人的发音');
    expect(c.state, MangaReadAloudState.idle);

    host.gates.clear();
    c.start(fromPage: 0);
    await _waitFor(() => player.playing);
    expect(c.debugPlanCount, greaterThan(0));
    c.dispose();
    expect(player.stops, 1);
    expect(c.debugPlanCount, 0);
    await _waitFor(() => rig.disposed);
  });

  test('setSpeed 写回全局倍速，下一段起生效', () async {
    final _Host host = threePages();
    final MangaReadAloudController c = controllerFor(host);
    c.start(fromPage: 0);
    await _waitFor(() => player.playing);
    await c.setSpeed(2.0);
    expect(storedSpeed, 2.0);
    player.finish();
    await _waitFor(() => player.played.length == 2);
    expect(player.played.last.$2, 2.0);
    c.stop();
  });

  test('整章没有可读句：finished(noText)', () async {
    final _Host host = _Host(<int, MangaPageTextResult>{
      0: MangaPageTextReady(_image(const <String>['……'])),
      1: MangaPageTextReady(_image(const <String>[])),
    });
    final MangaReadAloudController c = controllerFor(host);
    c.start(fromPage: 0);
    await _waitFor(() => c.state == MangaReadAloudState.finished);
    expect(c.finish, MangaReadAloudFinish.noText);
    c.dispose();
  });
}
