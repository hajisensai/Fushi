import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/analysis/music_audio_analysis_models.dart';
import 'package:fushi/src/media/music/analysis/music_audio_analysis_service.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/pages/implementations/music/music_analysis_models_dialog.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart'
    show musicAudioAnalysisTargetOf;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

void main() {
  group('musicAudioAnalysisTargetOf', () {
    test('local file → target; CUE range → start + length', () {
      final MusicAudioAnalysisTarget? plain = musicAudioAnalysisTargetOf(
        const MusicPlayItem(
          trackUid: 'a',
          path: r'D:\music\a.flac',
          title: 'a',
        ),
      );
      expect(plain?.path, r'D:\music\a.flac');
      expect(plain?.cueStartMs, isNull);
      expect(plain?.durationMs, isNull);

      final MusicAudioAnalysisTarget? cue = musicAudioAnalysisTargetOf(
        const MusicPlayItem(
          trackUid: 'c',
          path: '/music/disc.flac',
          title: 'c',
          startMs: 60000,
          endMs: 300000,
        ),
      );
      expect(cue?.cueStartMs, 60000);
      expect(cue?.durationMs, 240000);
    });

    test('nothing to analyse locally → null', () {
      expect(musicAudioAnalysisTargetOf(null), isNull);
      expect(
        musicAudioAnalysisTargetOf(
          const MusicPlayItem(
            trackUid: 'p',
            path: '/music/p.flac',
            title: 'p',
            isPreview: true,
          ),
        ),
        isNull,
      );
      expect(
        musicAudioAnalysisTargetOf(
          const MusicPlayItem(
            trackUid: 'h',
            path: 'https://server/library/h.flac',
            title: 'h',
          ),
        ),
        isNull,
      );
      expect(
        musicAudioAnalysisTargetOf(
          const MusicPlayItem(
            trackUid: 's',
            path: 'sftp://nas/s.flac',
            title: 's',
            sourceId: 3,
          ),
        ),
        isNull,
      );
    });
  });

  testWidgets('models dialog: missing → download → installed → delete', (
    WidgetTester tester,
  ) async {
    LocaleSettings.setLocale(AppLocale.en);
    final Directory root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('mana_models_dialog'),
    ))!;
    addTearDown(() => root.deleteSync(recursive: true));
    final MusicAudioAnalysisService service = MusicAudioAnalysisService(
      cacheDir: () async => Directory(p.join(root.path, 'cache')),
      modelsDir: () async => Directory(p.join(root.path, 'models')),
      tempDir: () async => Directory(p.join(root.path, 'tmp')),
      engine: () => throw UnsupportedError('no engine in this test'),
      desktop: false,
      threads: 1,
      download:
          (
            Directory dir,
            List<MusicAnalysisModelFile> files,
            onProgress,
          ) async {
            dir.createSync(recursive: true);
            for (final MusicAnalysisModelFile f in files) {
              final RandomAccessFile raf = File(
                p.join(dir.path, f.fileName),
              ).openSync(mode: FileMode.write);
              raf
                ..truncateSync(f.expectedBytes)
                ..closeSync();
            }
          },
    );
    await tester.runAsync(service.refreshModels);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MusicAnalysisModelsDialog(service: service)),
      ),
    );
    expect(
      find.text(
        t.music_visualizer_models_missing(
          size: _bytes(service.requiredModelBytes),
        ),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('music_analysis_models_download')),
    );
    await tester.pumpAndSettle();
    // 确认框
    await tester.tap(find.text(t.music_visualizer_models_download).last);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(service.models.value.installed, isTrue);
    expect(find.text(t.music_visualizer_models_installed), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('music_analysis_models_delete')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.music_visualizer_models_delete).last);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(service.models.value.installed, isFalse);
    expect(
      find.byKey(const ValueKey<String>('music_analysis_models_download')),
      findsOneWidget,
    );
  });
}

String _bytes(int n) => FushiByteFormat.bytes(n);
