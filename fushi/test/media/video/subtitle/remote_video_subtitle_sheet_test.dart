import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/remote_video_subtitle_service.dart';
import 'package:fushi/src/media/video/subtitle/remote_video_subtitle_sheet.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_generate_sheet.dart';
import 'package:fushi/src/sync/interconnect_job_client.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:material_ui/material_ui.dart';

class _Prefs implements VideoSubtitleGeneratePrefs {
  @override
  bool proofread = false;

  @override
  bool consented = true;

  @override
  bool frames = false;

  @override
  bool framesConsented = false;

  @override
  Future<void> setFrames(bool value) async => frames = value;

  @override
  Future<void> setFramesConsented(bool value) async => framesConsented = value;

  @override
  VideoSubtitleSegmenterMode segmenter = VideoSubtitleSegmenterMode.auto;

  @override
  bool saveBesideVideo = true;

  @override
  Future<void> setSaveBesideVideo(bool value) async => saveBesideVideo = value;

  @override
  MossBackendPreference get mossBackend => MossBackendPreference.auto;

  @override
  Future<void> setProofread(bool value) async => proofread = value;

  @override
  Future<void> setConsented(bool value) async => consented = value;

  @override
  Future<void> setSegmenter(VideoSubtitleSegmenterMode value) async =>
      segmenter = value;

  @override
  Future<void> ensureWebSearchPageFetchDecided(BuildContext context) async {}
}

class _Host implements RemoteVideoSubtitleHostPort {
  _Host(this.kinds, {this.error, this.capability = const <String, Object?>{}});

  final List<String>? kinds;
  final Object? error;
  final Map<String, Object?> capability;

  /// 每次提交带的参数。
  final List<Map<String, Object?>> runs = <Map<String, Object?>>[];

  @override
  Future<HostJobTarget?> probe() async => kinds == null
      ? null
      : HostJobTarget(
          baseUrl: 'http://pc.invalid',
          deviceName: 'Desk PC',
          kinds: kinds!,
          capability: capability,
        );

  @override
  Stream<HostJobEvent> run({
    required HostJobTarget target,
    required Map<String, Object?> params,
    required Directory outputDir,
  }) {
    runs.add(params);
    return Stream<HostJobEvent>.error(error ?? StateError('no script'));
  }
}

void main() {
  const RemoteVideoSubtitleTarget target = RemoteVideoSubtitleTarget(
    title: 'K-ON 01',
    episodes: <RemoteVideoSubtitleEpisode>[
      RemoteVideoSubtitleEpisode(videoId: 'v1', title: 'K-ON 01'),
    ],
  );

  RemoteVideoSubtitleService service(_Host host) => RemoteVideoSubtitleService(
    host: host,
    workRoot: () async => Directory.systemTemp,
    subtitlesDir: () async => Directory.systemTemp,
  );

  Future<void> pump(
    WidgetTester tester,
    RemoteVideoSubtitleService svc, {
    _Prefs? prefs,
    VideoSubtitleInAppTranscribe? onTranscribeInApp,
  }) async {
    tester.view
      ..physicalSize = const Size(900, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RemoteVideoSubtitleSheet(
            service: svc,
            target: target,
            prefs: prefs ?? _Prefs(),
            onTranscribeInApp: onTranscribeInApp,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  VoidCallback? startPressed(WidgetTester tester) => tester
      .widget<FushiFilledButton>(
        find.byKey(const ValueKey<String>('remote-subtitle-start')),
      )
      .onPressed;

  testWidgets('老 host（capability 没有 video_subtitle）：明确提示版本不支持，「开始」不可点', (
    WidgetTester tester,
  ) async {
    await pump(tester, service(_Host(<String>['asr'])));
    expect(
      find.byKey(const ValueKey<String>('remote-subtitle-unsupported')),
      findsOneWidget,
    );
    expect(
      find.textContaining(t.video_subtitle_ai_remote_unsupported),
      findsOneWidget,
    );
    expect(startPressed(tester), isNull);
  });

  // 反馈 6Tj3ECtB0Q：合并入口下关掉保存 = 本机转录 host 裁回的音轨，不需要 host 支持
  // video_subtitle 任务。
  testWidgets('合并入口关掉保存：不看 host 任务能力，「开始」交给本机转录', (WidgetTester tester) async {
    final _Prefs prefs = _Prefs();
    final List<bool> handedOff = <bool>[];
    await pump(
      tester,
      service(_Host(const <String>['asr'])),
      prefs: prefs,
      onTranscribeInApp: ({required bool proofread}) =>
          handedOff.add(proofread),
    );
    expect(find.text(t.video_subtitle_ai_generate_title), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('remote-subtitle-unsupported')),
      findsOneWidget,
    );
    expect(startPressed(tester), isNull);

    await tester.tap(
      find.byKey(const ValueKey<String>('remote-subtitle-save-beside')),
    );
    await tester.pumpAndSettle();
    expect(prefs.saveBesideVideo, isFalse);
    expect(
      find.byKey(const ValueKey<String>('remote-subtitle-unsupported')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('remote-subtitle-segmenter')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('remote-subtitle-transcribe-start')),
    );
    await tester.pumpAndSettle();
    expect(handedOff, <bool>[false]);
  });

  testWidgets('不传回调（整季入口）：没有保存开关', (WidgetTester tester) async {
    await pump(tester, service(_Host(const <String>['video_subtitle'])));
    expect(
      find.byKey(const ValueKey<String>('remote-subtitle-save-beside')),
      findsNothing,
    );
    expect(find.text(t.video_subtitle_ai_title), findsOneWidget);
  });

  testWidgets('连不上 host：提示，「开始」不可点', (WidgetTester tester) async {
    await pump(tester, service(_Host(null)));
    expect(
      find.byKey(const ValueKey<String>('remote-subtitle-unreachable')),
      findsOneWidget,
    );
    expect(startPressed(tester), isNull);
  });

  group('参考画面', () {
    _Host hostWith({bool? framesAvailable}) => _Host(
      <String>['video_subtitle'],
      capability: <String, Object?>{
        'video_subtitle': <String, Object?>{
          'supported': true,
          'framesAvailable': ?framesAvailable,
        },
      },
    );
    final Finder toggle = find.byKey(
      const ValueKey<String>('remote-subtitle-frames'),
    );
    final Finder unsupported = find.byKey(
      const ValueKey<String>('remote-subtitle-frames-unsupported'),
    );
    Future<void> start(WidgetTester tester) async {
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('remote-subtitle-start')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('remote-subtitle-start')),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('老 host（没报 framesAvailable）：不显示开关，提交不带 frames', (
      WidgetTester tester,
    ) async {
      final _Host host = hostWith();
      final _Prefs prefs = _Prefs()
        ..proofread = true
        ..frames = true
        ..framesConsented = true;
      await pump(tester, service(host), prefs: prefs);
      expect(toggle, findsNothing);
      await start(tester);
      expect(host.runs.single.containsKey('frames'), isFalse);
    });

    testWidgets('host 能收图、开关开着且看过说明：提交带 frames=true；没开 AI 校对时不显示也不带', (
      WidgetTester tester,
    ) async {
      final _Host host = hostWith(framesAvailable: true);
      final _Prefs prefs = _Prefs()
        ..proofread = true
        ..frames = true
        ..framesConsented = true;
      await pump(tester, service(host), prefs: prefs);
      expect(toggle, findsOneWidget);
      expect(unsupported, findsNothing);
      await start(tester);
      expect(host.runs.single['frames'], isTrue);

      // 面板每次打开都是新 State（initState 读 prefs）；同结构再 pumpWidget 会复用
      // 上一份 State、沿用上一份 prefs 的 proofread，所以先卸载再开第二个场景。
      await tester.pumpWidget(const SizedBox.shrink());
      final _Host plain = hostWith(framesAvailable: true);
      await pump(
        tester,
        service(plain),
        prefs: _Prefs()
          ..frames = true
          ..framesConsented = true,
      );
      expect(toggle, findsNothing);
      await start(tester);
      expect(plain.runs.single.containsKey('frames'), isFalse);
    });

    testWidgets('host 的提供商收不了图：直说画面不会发送，提交不带 frames', (
      WidgetTester tester,
    ) async {
      final _Host host = hostWith(framesAvailable: false);
      final _Prefs prefs = _Prefs()
        ..proofread = true
        ..frames = true
        ..framesConsented = true;
      await pump(tester, service(host), prefs: prefs);
      expect(toggle, findsOneWidget);
      expect(unsupported, findsOneWidget);
      await start(tester);
      expect(host.runs.single.containsKey('frames'), isFalse);
      // 没发生任何发送，不需要打扰用户，开关也不动。
      expect(prefs.frames, isTrue);
    });

    testWidgets('在旧说明下同意过的用户：第一次真要发画面前补看一次，点「不发画面」就关掉开关、'
        '任务照常提交', (WidgetTester tester) async {
      final _Host host = hostWith(framesAvailable: true);
      final _Prefs prefs = _Prefs()
        ..proofread = true
        ..frames = true;
      await pump(tester, service(host), prefs: prefs);
      await start(tester);
      expect(find.text(t.video_subtitle_ai_frames_consent_title), findsOne);
      expect(host.runs, isEmpty);
      await tester.tap(find.text(t.video_subtitle_ai_frames_consent_decline));
      await tester.pumpAndSettle();
      expect(prefs.frames, isFalse);
      expect(prefs.framesConsented, isFalse);
      expect(host.runs.single.containsKey('frames'), isFalse);
    });

    testWidgets('首次开 AI 校对的说明写明了画面：同意即两样都记下', (WidgetTester tester) async {
      final _Prefs prefs = _Prefs()
        ..consented = false
        ..frames = true;
      await pump(
        tester,
        service(hostWith(framesAvailable: true)),
        prefs: prefs,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('remote-subtitle-proofread')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.video_subtitle_ai_consent_confirm));
      await tester.pumpAndSettle();
      expect(prefs.consented, isTrue);
      expect(prefs.framesConsented, isTrue);
      expect(toggle, findsOneWidget);
    });
  });

  testWidgets('支持的 host：显示在哪台上运行，「开始」可点', (WidgetTester tester) async {
    await pump(tester, service(_Host(<String>['video_subtitle'])));
    expect(
      find.text(t.video_subtitle_ai_remote_host(host: 'Desk PC')),
      findsOneWidget,
    );
    expect(startPressed(tester), isNotNull);
  });

  testWidgets('host 报错的任务：重开面板接回，报错原样显示并可「继续」', (WidgetTester tester) async {
    final RemoteVideoSubtitleService svc = service(
      _Host(
        <String>['video_subtitle'],
        error: const HostJobRemoteException(
          'http_400',
          '{"error":"video_subtitle: proofread needs an AI provider"}',
        ),
      ),
    );
    await tester.runAsync(() async {
      await svc
          .start(target, const RemoteVideoSubtitleOptions(proofread: true))
          .done;
    });
    await pump(tester, svc);
    expect(
      find.text(
        t.video_subtitle_ai_remote_host_error(
          reason: 'video_subtitle: proofread needs an AI provider',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('remote-subtitle-resume')),
      findsOneWidget,
    );
  });
}
