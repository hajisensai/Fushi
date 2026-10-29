// 卡面视频片段 + 片段登记处：音频序列经 SrsCardVideoChannel 在卡面那段画面上从头播到尾。
// 钉住：没挂片段时 playToEnd 返回 null（调用方退回只播音频）；挂上后从 0 开播、按复习
// 音量、自然播完 = true；stopAll / 卸载 / 用户点按 = false；登记是同步的（文件还在解析时
// 就能排队）；缺文件什么也不画也不登记；点按画面切换播放 / 暂停。
// 先起播放、后挂片段（翻面 setState 后同步起序列，片段下一帧才构建）：playToEndOrElse 等这轮
// 构建跑完，挂上了就在画面里播、没挂上才退回只播音频，等待中 stopAll = false 且什么也不开播。
// 播放器换成假实现（测试里加载不了 libmpv）。
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart'
    show SrsBlankTapRegion;
import 'package:fushi/src/pages/implementations/srs/srs_card_video_clip.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart'
    show SrsPictureLimits, srsPictureLimits;
import 'package:fushi/src/srs/srs_card_video_channel.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_layout.dart' show SrsReviewImageSize;
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

  group('SrsCardVideoChannel.playToEndOrElse', () {
    late bool pending;
    late Completer<void> settled;
    late SrsCardVideoChannel channel;
    late int fallbacks;

    setUp(() {
      pending = true;
      settled = Completer<void>();
      channel = SrsCardVideoChannel(
        buildPending: () => pending,
        buildSettled: () => settled.future,
      );
      fallbacks = 0;
    });

    Future<bool> audio() async {
      fallbacks++;
      return true;
    }

    test('已挂上：直接交给片段，不走音频', () async {
      final _FakeHandle h = _FakeHandle();
      channel.attach('clip.webm', h);
      expect(await channel.playToEndOrElse('clip.webm', audio), isTrue);
      expect(h.plays, 1);
      expect(fallbacks, 0);
    });

    test('不是视频文件 / 没有待跑的构建：立刻走音频，不等', () async {
      expect(await channel.playToEndOrElse('word.mp3', audio), isTrue);
      expect(fallbacks, 1);
      pending = false;
      expect(await channel.playToEndOrElse('clip.webm', audio), isTrue);
      expect(fallbacks, 2);
      expect(settled.isCompleted, isFalse);
    });

    test('先播放后挂片段：等构建跑完，交给挂上的片段', () async {
      bool? result;
      unawaited(
        channel
            .playToEndOrElse('clip.webm', audio)
            .then((bool v) => result = v),
      );
      await Future<void>.delayed(Duration.zero);
      // 构建还没跑完：既不退回音频，也没结束。
      expect(result, isNull);
      expect(fallbacks, 0);
      final _FakeHandle h = _FakeHandle();
      channel.attach('clip.webm', h);
      settled.complete();
      await Future<void>.delayed(Duration.zero);
      expect(result, isTrue);
      expect(h.plays, 1);
      expect(fallbacks, 0);
    });

    test('构建跑完仍没挂上（这一面没画片段）：退回音频', () async {
      final Future<bool> run = channel.playToEndOrElse('clip.webm', audio);
      settled.complete();
      expect(await run, isTrue);
      expect(fallbacks, 1);
    });

    test('等待中 stopAll：以 false 结束，之后挂上 / 构建跑完都不再开播', () async {
      final Future<bool> run = channel.playToEndOrElse('clip.webm', audio);
      await channel.stopAll();
      expect(await run, isFalse);
      final _FakeHandle h = _FakeHandle();
      channel.attach('clip.webm', h);
      settled.complete();
      await Future<void>.delayed(Duration.zero);
      expect(h.plays, 0);
      expect(fallbacks, 0);
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

    Widget host(
      String? name, {
      bool fillWidth = false,
      double? maxFillHeight,
    }) => UncontrolledProviderScope(
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
                      fillWidth: fillWidth,
                      maxFillHeight: maxFillHeight,
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

    Future<void> mount(
      WidgetTester tester, [
      String name = 'clip.webm',
      bool fillWidth = false,
      double? maxFillHeight,
    ]) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          host(name, fillWidth: fillWidth, maxFillHeight: maxFillHeight),
        );
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

    /// 卡面那一面：[show] 翻成 true 才构建片段（复习页翻面 setState 的形态）。
    Widget flipHost(ValueNotifier<bool> show) => UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: ValueListenableBuilder<bool>(
                valueListenable: show,
                builder: (BuildContext context, bool on, Widget? _) => on
                    ? const SrsCardVideoClip(
                        name: 'clip.webm',
                        maxWidth: 300,
                        maxHeight: 120,
                        radius: 8,
                      )
                    : const SizedBox(),
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('翻面后同步起播放、片段下一帧才挂上：在画面里播，不退回只播音频', (WidgetTester tester) async {
      final ValueNotifier<bool> show = ValueNotifier<bool>(false);
      addTearDown(show.dispose);
      await tester.pumpWidget(flipHost(show));
      int fallbacks = 0;
      bool? result;
      await tester.runAsync(() async {
        // 与复习页 _showAnswer 同一时序：先 setState，紧接着同步起序列。
        show.value = true;
        expect(channel.isAttached('clip.webm'), isFalse);
        unawaited(
          channel
              .playToEndOrElse('clip.webm', () async {
                fallbacks++;
                return true;
              })
              .then((bool v) => result = v),
        );
        await Future<void>.delayed(Duration.zero);
        expect(fallbacks, 0, reason: '片段那一帧还没构建，不能先退回只播音频');
        await tester.pump();
        expect(channel.isAttached('clip.webm'), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(
          players.single.calls,
          containsAllInOrder(<String>['seek:0', 'play']),
        );
        expect(result, isNull);
        players.single
          ..emitPlaying(true)
          ..emitCompleted();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      expect(result, isTrue);
      expect(fallbacks, 0);
    });

    testWidgets('这一面构建完也没有片段：退回只播音频', (WidgetTester tester) async {
      final ValueNotifier<bool> show = ValueNotifier<bool>(false);
      addTearDown(show.dispose);
      await tester.pumpWidget(flipHost(show));
      int fallbacks = 0;
      bool? result;
      await tester.runAsync(() async {
        // 有一轮构建待跑，但它不画片段。
        tester.binding.scheduleFrame();
        unawaited(
          channel
              .playToEndOrElse('clip.webm', () async {
                fallbacks++;
                return true;
              })
              .then((bool v) => result = v),
        );
        await tester.pump();
        await Future<void>.delayed(Duration.zero);
      });
      expect(fallbacks, 1);
      expect(result, isTrue);
      expect(players, isEmpty);
    });

    testWidgets('等片段时换卡 / 翻回（stopAll）：false，随后挂上的片段也不开播', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<bool> show = ValueNotifier<bool>(false);
      addTearDown(show.dispose);
      await tester.pumpWidget(flipHost(show));
      int fallbacks = 0;
      bool? result;
      await tester.runAsync(() async {
        show.value = true;
        unawaited(
          channel
              .playToEndOrElse('clip.webm', () async {
                fallbacks++;
                return true;
              })
              .then((bool v) => result = v),
        );
        await channel.stopAll();
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      expect(result, isFalse);
      expect(fallbacks, 0);
      expect(players.single.calls, isNot(contains('play')));
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

    testWidgets('缺文件（媒体还没同步过来）：画同尺寸「视频未同步」占位，不登记、不建播放器', (
      WidgetTester tester,
    ) async {
      await mount(tester, 'missing.webm');
      expect(
        find.byKey(const ValueKey<String>('srs-card-video-toggle')),
        findsNothing,
      );
      final Finder placeholder = find.byKey(
        const ValueKey<String>('srs-card-video-missing'),
      );
      expect(placeholder, findsOne);
      expect(find.text(t.srs_card_media_missing_video), findsOne);
      // 与片段正常显示时同尺寸（16:9，受 maxHeight 120 限制），不是零尺寸。
      expect(tester.getSize(placeholder).height, moreOrLessEquals(120));
      expect(tester.getSize(placeholder).width, moreOrLessEquals(120 * 16 / 9));
      expect(players, isEmpty);
      expect(channel.playToEnd('missing.webm'), isNull);
    });

    testWidgets('铺满模式：16:9 片段宽 = 父级宽度（300），高不超过铺满上限', (
      WidgetTester tester,
    ) async {
      await mount(tester, 'clip.webm', true, 400);
      final Finder box = find.byKey(
        const ValueKey<String>('srs-card-video-toggle'),
      );
      expect(tester.getSize(box).width, moreOrLessEquals(300));
      expect(tester.getSize(box).height, moreOrLessEquals(300 * 9 / 16));

      // 上限 120：等比缩小到高 120，不裁切。
      await mount(tester, 'clip.webm', true, 120);
      expect(tester.getSize(box).height, moreOrLessEquals(120));
      expect(tester.getSize(box).width, moreOrLessEquals(120 * 16 / 9));
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

    testWidgets('点画面 / 全屏 / 重播都不算点卡面空白（不切换复习页悬浮顶栏）', (
      WidgetTester tester,
    ) async {
      final List<String> blank = <String>[];
      await tester.runAsync(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: TranslationProvider(
              child: MaterialApp(
                home: Scaffold(
                  body: SrsBlankTapRegion(
                    onTapEmpty: () => blank.add('empty'),
                    tapTookLookup: () => false,
                    child: const ColoredBox(
                      key: ValueKey<String>('blank'),
                      color: Color(0xFFFFFFFF),
                      child: Center(
                        child: SrsCardVideoClip(
                          name: 'clip.webm',
                          maxWidth: 300,
                          maxHeight: 120,
                          radius: 8,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();

      for (final String key in <String>[
        'srs-card-video-toggle',
        'srs-card-video-replay',
        'srs-card-video-expand',
      ]) {
        await tester.tap(find.byKey(ValueKey<String>(key)));
        await tester.pump();
        expect(blank, isEmpty, reason: key);
      }
      // 放大视图是对话框：关掉再点卡面空白，空白照常回报。
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      expect(blank, <String>['empty']);
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

  test('srsCardMediaBoxSize：宽版式 16:9 视频与图片同规则铺满栏宽、高不超上限', () {
    // 宽版式左栏 560 宽、视口 800、「原样」档：铺满上限 = 视口 40% = 320。
    final SrsPictureLimits limits = srsPictureLimits(
      SrsReviewImageSize.original,
      viewport: 800,
    );
    expect(limits.fillWidth, isTrue);
    Size box(double aspect, {double column = 560}) => srsCardMediaBoxSize(
      aspect: aspect,
      maxWidth: column,
      maxHeight: limits.maxHeight,
      fillWidth: limits.fillWidth,
      maxFillHeight: limits.maxFillHeight,
    );
    final Size video = box(16 / 9);
    expect(video.width, 560);
    expect(video.height, lessThanOrEqualTo(limits.maxFillHeight));
    expect(video.height, moreOrLessEquals(560 * 9 / 16));
    // 栏更宽、按比例高超过上限：整段等比缩小到上限高度。
    final Size capped = box(16 / 9, column: 640);
    expect(capped.height, moreOrLessEquals(limits.maxFillHeight));
    expect(capped.width, moreOrLessEquals(limits.maxFillHeight * 16 / 9));
    // 超出 0.9–2.5 的比例退回写死限高（220）。
    expect(box(3).height, lessThanOrEqualTo(limits.maxHeight));
    expect(box(0.5).height, moreOrLessEquals(limits.maxHeight));
    // 矮视口 +「原样」档：图片不铺满，视频同样不铺满（同一份 limits）。
    final SrsPictureLimits short = srsPictureLimits(
      SrsReviewImageSize.original,
      viewport: 500,
    );
    expect(short.fillWidth, isFalse);
    expect(
      srsCardMediaBoxSize(
        aspect: 16 / 9,
        maxWidth: 560,
        maxHeight: short.maxHeight,
        fillWidth: short.fillWidth,
        maxFillHeight: short.maxFillHeight,
      ).height,
      moreOrLessEquals(short.maxHeight),
    );
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
