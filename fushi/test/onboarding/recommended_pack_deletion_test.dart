import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/onboarding/recommended_pack.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_controller.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_row.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_mini_bar.dart';
import 'package:fushi/utils.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('pack_deletion'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File artifact(String suffix, [String content = 'partial']) =>
      File('${dir.path}/$kRecommendedPackFileName$suffix')
        ..writeAsStringSync(content);

  test('pause-delete-start race holds lock until deletion finishes', () async {
    final Completer<bool> deletion = Completer<bool>();
    int downloads = 0;
    int deletions = 0;
    final RecommendedPackDownloadController controller =
        RecommendedPackDownloadController(
          packDirectory: () => dir,
          deletionRunner: (Directory _) {
            deletions++;
            return deletion.future;
          },
          runner:
              ({
                required Directory packDir,
                required ValueNotifier<double> progress,
                required ValueNotifier<int> receivedBytes,
                required CancelToken cancelToken,
              }) async {
                downloads++;
                if (downloads == 1) {
                  await cancelToken.whenCancel;
                  artifact('.part');
                  throw DioError(
                    requestOptions: RequestOptions(path: '/pack'),
                    type: DioErrorType.cancel,
                  );
                }
                packDir.createSync(recursive: true);
                return artifact('');
              },
          showOutcome: (String _, ToastSeverity __) {},
        );
    addTearDown(controller.dispose);
    final Future<File?> download = controller.start();
    controller.requestCancel();
    expect(await controller.discardPartialDownload(), isFalse);
    await download;
    expect(controller.isPaused, isTrue);
    final Future<bool> discarded = controller.discardPartialDownload();
    expect(controller.isDeleting.value, isTrue);
    expect(await controller.start(), isNull);
    expect(await controller.discardPartialDownload(), isFalse);
    // Legacy migration would rename this file if prepare could enter the lock.
    final File legacy = File('${dir.path}/download.part')
      ..writeAsStringSync('x');
    await controller.prepareDiskState();
    controller.syncStageWithDisk();
    expect(legacy.existsSync(), isTrue);
    expect(controller.isPaused, isTrue);
    expect(downloads, 1);
    expect(deletions, 1);
    dir.deleteSync(recursive: true);
    deletion.complete(true);
    expect(await discarded, isTrue);
    expect(controller.isDeleting.value, isFalse);
    expect(controller.stage.value, RecommendedPackDownloadStage.idle);
    expect(await controller.start(), isNotNull);
    expect(downloads, 2);
  });

  test(
    'prepare excludes start and deletion until its async work settles',
    () async {
      artifact('.part');
      int deletions = 0;
      final RecommendedPackDownloadController controller =
          RecommendedPackDownloadController(
            packDirectory: () => dir,
            deletionRunner: (Directory _) async {
              deletions++;
              return true;
            },
            showOutcome: (String _, ToastSeverity __) {},
          );
      addTearDown(controller.dispose);
      controller.syncStageWithDisk();
      final Future<void> preparing = controller.prepareDiskState();
      expect(await controller.start(), isNull);
      // Invoke while preparing, before awaiting completion.
      await preparing;
      final Future<void> preparingAgain = controller.prepareDiskState();
      expect(await controller.discardPartialDownload(), isFalse);
      await preparingAgain;
      expect(deletions, 0);
    },
  );

  test(
    'partial delete failure keeps orphan mpart visible and retryable',
    () async {
      final File body = artifact('.mpart', 'preallocated body');
      final File metadata = artifact('.mpart.json', '{"parts":{"0":5}}');
      final List<String> outcomes = <String>[];
      int attempts = 0;
      final RecommendedPackDownloadController controller =
          RecommendedPackDownloadController(
            packDirectory: () => dir,
            deletionRunner: (Directory packDir) async {
              attempts++;
              if (attempts == 1) {
                metadata.deleteSync();
                return false;
              }
              await packDir.delete(recursive: true);
              return true;
            },
            showOutcome: (String message, ToastSeverity _) =>
                outcomes.add(message),
          );
      addTearDown(controller.dispose);
      controller.syncStageWithDisk();
      controller.progress.value = 0.5;
      controller.dismissMiniBar();
      expect(await controller.discardPartialDownload(), isFalse);
      expect(body.existsSync(), isTrue);
      expect(controller.isActive, isTrue);
      expect(controller.isPaused, isTrue);
      expect(controller.receivedBytes.value, 0);
      expect(controller.progress.value, 0);
      expect(controller.failureMessage, t.onboarding_pack_discard_failed);
      expect(outcomes, <String>[t.onboarding_pack_discard_failed]);
      expect(controller.miniBarDismissed.value, isFalse);
      final RecommendedPackDownloadController restarted =
          RecommendedPackDownloadController(packDirectory: () => dir);
      addTearDown(restarted.dispose);
      await restarted.prepareDiskState();
      expect(restarted.isPaused, isTrue);
      expect(restarted.receivedBytes.value, 0);
      expect(await controller.discardPartialDownload(), isTrue);
      expect(controller.error.value, isNull);
      expect(controller.isActive, isFalse);
    },
  );

  test(
    'thrown deletion error releases lock and exposes deletion outcome',
    () async {
      artifact('.part');
      final RecommendedPackDownloadController controller =
          RecommendedPackDownloadController(
            packDirectory: () => dir,
            deletionRunner: (Directory _) async =>
                throw const FileSystemException('locked'),
            showOutcome: (String _, ToastSeverity __) {},
          );
      addTearDown(controller.dispose);
      controller.syncStageWithDisk();
      expect(await controller.discardPartialDownload(), isFalse);
      expect(controller.isDeleting.value, isFalse);
      expect(controller.failureMessage, t.onboarding_pack_discard_failed);
      expect(controller.isPaused, isTrue);
    },
  );

  for (final bool miniBar in <bool>[false, true]) {
    testWidgets('deleting disables conflicting actions: miniBar=$miniBar', (
      WidgetTester tester,
    ) async {
      artifact('.mpart');
      final Completer<bool> deletion = Completer<bool>();
      final RecommendedPackDownloadController controller =
          RecommendedPackDownloadController(
            packDirectory: () => dir,
            deletionRunner: (Directory _) => deletion.future,
            showOutcome: (String _, ToastSeverity __) {},
          );
      addTearDown(controller.dispose);
      controller.syncStageWithDisk();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: miniBar
                ? RecommendedPackDownloadMiniBarView(
                    controller: controller,
                    onImport: () {},
                    onDiscard: () {},
                  )
                : RecommendedPackDownloadRow(
                    controller: controller,
                    onImport: () {},
                    onDiscard: () {},
                  ),
          ),
        ),
      );
      final Future<bool> discarded = controller.discardPartialDownload();
      await tester.pump();
      expect(find.text(t.onboarding_pack_discard_running), findsOneWidget);
      for (final String label in <String>[
        t.onboarding_pack_download_discard,
        t.onboarding_pack_download_resume,
      ]) {
        final Finder button = find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate(
            (Widget w) => w is ButtonStyleButton,
          ),
        );
        expect(tester.widget<ButtonStyleButton>(button).onPressed, isNull);
      }
      deletion.complete(false);
      await discarded;
      await tester.pump();
      expect(
        find.textContaining(t.onboarding_pack_discard_failed),
        findsOneWidget,
      );
      final Finder resume = find.ancestor(
        of: find.text(t.onboarding_pack_download_resume),
        matching: find.byType(FilledButton),
      );
      expect(tester.widget<FilledButton>(resume).onPressed, isNotNull);
    });
  }
}
