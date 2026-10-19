import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/remote_video_subtitle_service.dart';
import 'package:fushi/src/media/video/subtitle/remote_video_subtitle_sheet.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_generate_sheet.dart';
import 'package:fushi/src/sync/interconnect_job_client.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:material_ui/material_ui.dart';

class _Prefs implements VideoSubtitleGeneratePrefs {
  @override
  bool proofread = false;

  @override
  bool consented = true;

  @override
  VideoSubtitleSegmenterMode segmenter = VideoSubtitleSegmenterMode.auto;

  @override
  MossBackendPreference get mossBackend => MossBackendPreference.auto;

  @override
  Future<void> setProofread(bool value) async => proofread = value;

  @override
  Future<void> setConsented(bool value) async => consented = value;

  @override
  Future<void> setSegmenter(VideoSubtitleSegmenterMode value) async =>
      segmenter = value;
}

class _Host implements RemoteVideoSubtitleHostPort {
  _Host(this.kinds, {this.error});

  final List<String>? kinds;
  final Object? error;

  @override
  Future<HostJobTarget?> probe() async => kinds == null
      ? null
      : HostJobTarget(
          baseUrl: 'http://pc.invalid',
          deviceName: 'Desk PC',
          kinds: kinds!,
          capability: const <String, Object?>{},
        );

  @override
  Stream<HostJobEvent> run({
    required HostJobTarget target,
    required Map<String, Object?> params,
    required Directory outputDir,
  }) => Stream<HostJobEvent>.error(error ?? StateError('no script'));
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

  Future<void> pump(WidgetTester tester, RemoteVideoSubtitleService svc) async {
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
            prefs: _Prefs(),
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

  testWidgets('连不上 host：提示，「开始」不可点', (WidgetTester tester) async {
    await pump(tester, service(_Host(null)));
    expect(
      find.byKey(const ValueKey<String>('remote-subtitle-unreachable')),
      findsOneWidget,
    );
    expect(startPressed(tester), isNull);
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
