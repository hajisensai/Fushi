// 卡面视频片段 + 片段登记处：音频序列经 SrsCardVideoChannel 在卡面那段画面上从头播到尾。
// 钉住：没挂片段时 playToEnd 返回 null（调用方退回只播音频）；挂上后从 0 开播、按复习
// 音量、自然播完 = true；stopAll / 卸载 / 用户点按 = false；登记是同步的（文件还在解析时
// 就能排队）；缺文件什么也不画也不登记；点按画面切换播放 / 暂停。
// 播放器换成假实现（测试里加载不了 libmpv）。
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_video_clip.dart';
import 'package:fushi/src/srs/srs_card_video_channel.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:material_ui/material_ui.dart';

class _FakePlayer implements SrsCardVideoPlayer {
  final List<String> calls = <String>[];
  final StreamController<bool> playing = StreamController<bool>.broadcast(
    sync: true,
  );
  final StreamController<bool> completed = StreamController<bool>.broadcast(
    sync: true,
  );
  final StreamController<Size> size = StreamController<Size>.broadcast(
    sync: true,
  );
  bool atEnd = false;
  bool disposed = false;

  void emitPlaying(bool v) => playing.add(v);

  void emitCompleted() {
    atEnd = true;
    completed.add(true);
  }

  @override
  Future<void> open(String path) async =>
      calls.add('open:${path.split(RegExp(r'[\\/]')).last}');

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seek(Duration position) async {
    atEnd = false;
    calls.add('seek:${position.inMilliseconds}');
  }

  @override
  Future<void> setVolume(double volume) async => calls.add('volume:$volume');

  @override
  Stream<bool> get playingStream => playing.stream;

  @override
  Stream<bool> get completedStream => completed.stream;

  @override
  Stream<Size> get videoSizeStream => size.stream;

  @override
  bool get isCompleted => atEnd;

  @override
  Widget buildView() =>
      const SizedBox.expand(key: ValueKey<String>('fake-video-view'));

  @override
  Future<void> dispose() async {
    disposed = true;
    calls.add('dispose');
  }
}

class _FakeHandle implements SrsCardVideoHandle {
  int plays = 0;
  int stops = 0;

  @override
  Future<bool> playFromStart() {
    plays++;
    return Future<bool>.value(true);
  }

  @override
  Future<void> stop() async => stops++;
}

final StateProvider<double> _volume = StateProvider<double>((Ref ref) => 0.5);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('SrsCardVideoChannel', () {
    test('没挂片段时 playToEnd 返回 null；挂上后交给最后挂上的那个', () async {
      final SrsCardVideoChannel channel = SrsCardVideoChannel();
      expect(channel.playToEnd('a.webm'), isNull);
      final _FakeHandle first = _FakeHandle();
      final _FakeHandle second = _FakeHandle();
      final _FakeHandle other = _FakeHandle();
      channel
        ..attach('a.webm', first)
        ..attach('a.webm', second)
        ..attach('b.webm', other);
      expect(await channel.playToEnd('a.webm'), isTrue);
      expect(second.plays, 1);
      expect(first.plays, 0);
      // 同一时刻只让一段出声：别的片段先停。
      expect(first.stops, 1);
      expect(other.stops, 1);
      channel
        ..detach('a.webm', second)
        ..detach('a.webm', first);
      expect(channel.playToEnd('a.webm'), isNull);
      expect(channel.isAttached('b.webm'), isTrue);
      await channel.stopAll();
      expect(other.stops, 2);
    });
  });

  group('SrsCardVideoClip', () {
    late Directory dir;
    late SrsCardVideoChannel channel;
    late List<_FakePlayer> players;
    late ProviderContainer container;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('srs_card_video_clip_');
      await File('${dir.path}/clip.webm').writeAsBytes(<int>[1, 2, 3]);
      channel = SrsCardVideoChannel();
      players = <_FakePlayer>[];
      container = ProviderContainer(
        overrides: <Override>[
          srsMediaStoreProvider.overrideWith(
            (Ref ref) async => SrsMediaStore(dir),
          ),
          srsCardVideoChannelProvider.overrideWithValue(channel),
          srsReviewVolumeProvider.overrideWith((Ref ref) => ref.watch(_volume)),
          srsCardVideoPlayerFactoryProvider.overrideWithValue(() {
            final _FakePlayer p = _FakePlayer();
            players.add(p);
            return p;
          }),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await dir.delete(recursive: true);
    });

    Widget host(String? name) => UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: name == null
                  ? const SizedBox()
                  : SrsCardVideoClip(
                      name: name,
                      maxWidth: 300,
                      maxHeight: 120,
                      radius: 8,
                    ),
            ),
          ),
        ),
      ),
    );

    /// 让真实 IO（文件存在检查）与随后的微任务跑完，再重建一帧。
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }

    Future<void> mount(WidgetTester tester, [String name = 'clip.webm']) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(host(name));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
    }

    testWidgets('挂上后 playToEnd 按音量从 0 开播，自然播完 = true', (
      WidgetTester tester,
    ) async {
      await mount(tester);
      expect(find.byKey(const ValueKey<String>('fake-video-view')), findsOne);
      final _FakePlayer p = players.single;
      expect(p.calls, <String>['volume:0.5', 'open:clip.webm']);
      // 打开即停在第一帧，自己不开播。
      expect(p.calls, isNot(contains('play')));

      container.read(_volume.notifier).state = 0.8;
      await tester.pump();
      expect(p.calls.last, 'volume:0.8');
      p.calls.clear();

      bool? result;
      await tester.runAsync(() async {
        final Future<bool>? run = channel.playToEnd('clip.webm');
        expect(run, isNotNull);
        unawaited(run!.then((bool v) => result = v));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(p.calls, <String>['volume:0.8', 'seek:0', 'play']);
        expect(result, isNull);
        p.emitPlaying(true);
        p.emitCompleted();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      expect(result, isTrue);
    });

    testWidgets('stopAll 打断 = false 并暂停', (WidgetTester tester) async {
      await mount(tester);
      final _FakePlayer p = players.single;
      bool? result;
      await tester.runAsync(() async {
        unawaited(channel.playToEnd('clip.webm')!.then((bool v) => result = v));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await channel.stopAll();
        // 打断之后到来的结尾不算这次播放的。
        p.emitCompleted();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      expect(result, isFalse);
      expect(p.calls.last, 'pause');
    });

    testWidgets('登记是同步的：文件还在解析时排队，stopAll 后不再开播', (WidgetTester tester) async {
      bool? queued;
      bool? cancelled;
      await tester.runAsync(() async {
        await tester.pumpWidget(host('clip.webm'));
        // 还没跑完文件检查，播放器都没建。
        expect(players, isEmpty);
        final Future<bool>? run = channel.playToEnd('clip.webm');
        expect(run, isNotNull);
        unawaited(run!.then((bool v) => queued = v));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(players.single.calls, contains('play'));
        players.single.emitCompleted();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      expect(queued, isTrue);

      // 卸载重挂，打开前就 stopAll：之后打开好了也不开播。
      await tester.runAsync(() async {
        await tester.pumpWidget(host(null));
        await tester.pumpWidget(host('clip.webm'));
        unawaited(
          channel.playToEnd('clip.webm')!.then((bool v) => cancelled = v),
        );
        await channel.stopAll();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      expect(cancelled, isFalse);
      expect(players.last.calls, isNot(contains('play')));
    });

    testWidgets('卸载 = false，撤销登记并释放播放器', (WidgetTester tester) async {
      await mount(tester);
      final _FakePlayer p = players.single;
      bool? result;
      await tester.runAsync(() async {
        unawaited(channel.playToEnd('clip.webm')!.then((bool v) => result = v));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pumpWidget(host(null));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      expect(result, isFalse);
      expect(p.disposed, isTrue);
      expect(channel.isAttached('clip.webm'), isFalse);
      expect(channel.playToEnd('clip.webm'), isNull);
    });

    testWidgets('缺文件：什么也不画、不登记、不建播放器', (WidgetTester tester) async {
      await mount(tester, 'missing.webm');
      expect(
        find.byKey(const ValueKey<String>('srs-card-video-toggle')),
        findsNothing,
      );
      expect(find.byType(SizedBox), findsWidgets);
      expect(players, isEmpty);
      expect(channel.playToEnd('missing.webm'), isNull);
    });

    testWidgets('点按画面切换播放 / 暂停，并打断序列播放；重播从 0 开始', (WidgetTester tester) async {
      await mount(tester);
      final _FakePlayer p = players.single;
      bool? result;
      await tester.runAsync(() async {
        unawaited(channel.playToEnd('clip.webm')!.then((bool v) => result = v));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      p.emitPlaying(true);
      await tester.pump();
      p.calls.clear();

      // 正在播 → 点按 = 暂停，序列就此停下。
      await tester.tap(
        find.byKey(const ValueKey<String>('srs-card-video-toggle')),
      );
      await tester.pump();
      await settle(tester);
      expect(p.calls, <String>['pause']);
      expect(result, isFalse);
      p.emitPlaying(false);
      await tester.pump();

      // 暂停中 → 点按 = 接着播（没到结尾不回 0）。
      p.calls.clear();
      await tester.tap(
        find.byKey(const ValueKey<String>('srs-card-video-toggle')),
      );
      await tester.pump();
      expect(p.calls, <String>['volume:0.5', 'play']);

      // 播到结尾后点按 = 从头播。
      p.emitCompleted();
      p.emitPlaying(false);
      await tester.pump();
      p.calls.clear();
      await tester.tap(
        find.byKey(const ValueKey<String>('srs-card-video-toggle')),
      );
      await tester.pump();
      expect(p.calls, <String>['volume:0.5', 'seek:0', 'play']);

      // 重播按钮：从 0 开始。
      p.calls.clear();
      await tester.tap(
        find.byKey(const ValueKey<String>('srs-card-video-replay')),
      );
      await tester.pump();
      expect(p.calls, <String>['volume:0.5', 'seek:0', 'play']);
      expect(find.byTooltip(t.srs_card_video_replay), findsOne);
    });

    testWidgets('按视频比例缩放进约束', (WidgetTester tester) async {
      await mount(tester);
      final Finder box = find.byKey(
        const ValueKey<String>('srs-card-video-toggle'),
      );
      // 尺寸未知先按 16:9：受 maxHeight 120 限制 → 213.3 × 120。
      expect(tester.getSize(box).height, moreOrLessEquals(120));
      expect(tester.getSize(box).width, moreOrLessEquals(120 * 16 / 9));
      players.single.size.add(const Size(1000, 1000));
      await tester.pump();
      expect(tester.getSize(box), const Size(120, 120));
    });
  });

  test('srsCardVideoClipSize：宽受限 / 高受限 / 无宽度上限', () {
    expect(
      srsCardVideoClipSize(aspect: 2, maxWidth: 100, maxHeight: 220),
      const Size(100, 50),
    );
    expect(
      srsCardVideoClipSize(aspect: 2, maxWidth: 1000, maxHeight: 100),
      const Size(200, 100),
    );
    expect(
      srsCardVideoClipSize(
        aspect: 0.5,
        maxWidth: double.infinity,
        maxHeight: 100,
      ),
      const Size(50, 100),
    );
  });
}
