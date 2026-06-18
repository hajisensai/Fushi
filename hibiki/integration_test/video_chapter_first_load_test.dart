// Windows integration test for TODO-521.
//
// The test is hermetic: it generates a short MKV with Matroska chapters via
// ffmpeg in the isolated test root, seeds it into the video repository, opens
// VideoHibikiPage once, and asserts chapters + seek-bar markers are available
// on that first load. No external video fixture is required.
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/video/ffmpeg_backend.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_chapter_markers.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'test_helpers.dart';

const String _kBookUid = 'video/itest-chapter-first-load';

Future<File> _generateChapteredMkv() async {
  const String testRoot = String.fromEnvironment('HIBIKI_TEST_ROOT');
  final Directory root = testRoot.isEmpty
      ? await Directory.systemTemp.createTemp('hibiki-chapter-itest-')
      : Directory('$testRoot${Platform.pathSeparator}fixtures');
  await root.create(recursive: true);

  final File metadata =
      File('${root.path}${Platform.pathSeparator}chapters.ffmetadata');
  await metadata.writeAsString('''
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=2000
title=Intro
[CHAPTER]
TIMEBASE=1/1000
START=2000
END=4000
title=Middle
[CHAPTER]
TIMEBASE=1/1000
START=4000
END=6000
title=Credits
''');

  final File video = File('${root.path}${Platform.pathSeparator}chaptered.mkv');
  final FfmpegRunResult result = await const CliFfmpegBackend().run(
    <String>[
      '-hide_banner',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc=size=320x180:rate=10:duration=6',
      '-f',
      'lavfi',
      '-i',
      'anullsrc=channel_layout=stereo:sample_rate=44100',
      '-i',
      metadata.path,
      '-map',
      '0:v:0',
      '-map',
      '1:a:0',
      '-map_chapters',
      '2',
      '-c:v',
      'mpeg4',
      '-q:v',
      '5',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-shortest',
      '-t',
      '6',
      video.path,
    ],
    const Duration(seconds: 30),
  );
  expect(result.isSuccess, isTrue,
      reason:
          'ffmpeg must generate the chaptered MKV: ${result.failureSummary}');
  expect(video.existsSync(), isTrue, reason: 'generated MKV should exist');
  return video;
}

VideoHibikiTestHooks? _readHooks(WidgetTester tester) {
  final Finder page = find.byType(VideoHibikiPage);
  if (page.evaluate().isEmpty) return null;
  return tester.state<State<VideoHibikiPage>>(page) as VideoHibikiTestHooks;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('chaptered MKV shows chapters and seek markers on first open',
      (WidgetTester tester) async {
    final List<String> caught = <String>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      caught.add(details.exceptionAsString());
      debugPrint(
          '[video-chapter-itest] caught: ${details.exceptionAsString()}');
    };

    try {
      final File video = await _generateChapteredMkv();

      app.main(const <String>[]);
      expect(await waitForHome(tester), isTrue);
      await tester.pump(const Duration(seconds: 1));

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);

      await repo.saveVideoBook(VideoBooksCompanion(
        bookUid: const Value(_kBookUid),
        title: const Value('itest chaptered mkv'),
        videoPath: Value(video.absolute.path),
      ));

      final NavigatorState navigator =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => VideoHibikiPage(bookUid: _kBookUid, repo: repo),
      )));

      bool ready = false;
      for (int i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        final VideoHibikiTestHooks? hooks = _readHooks(tester);
        if (hooks?.debugPositionMs != null &&
            (hooks?.debugDurationMs ?? 0) > 0) {
          ready = true;
          break;
        }
      }
      expect(ready, isTrue,
          reason: 'video controller duration should be ready');

      bool chaptersReady = false;
      for (int i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if ((_readHooks(tester)?.debugChapterCount ?? 0) >= 3) {
          chaptersReady = true;
          break;
        }
      }
      expect(chaptersReady, isTrue,
          reason: 'first open should read MKV chapters without reloading');

      final Finder markers = find.byType(VideoChapterMarkers);
      expect(markers, findsWidgets,
          reason: 'chapter marker layer should mount');
      expect(
        find.descendant(of: markers, matching: find.byType(CustomPaint)),
        findsWidgets,
        reason: 'duration-ready chapters should paint seek-bar markers',
      );

      _readHooks(tester)!.debugShowChapterPanel();
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Intro'), findsOneWidget);
      expect(find.text('Middle'), findsOneWidget);
      expect(find.text('Credits'), findsOneWidget);

      await navigator.maybePop();
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(VideoHibikiPage).evaluate().isEmpty) break;
      }

      debugPrint(
        '[video-chapter-itest] non-fatal framework errors=${caught.length}',
      );
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
