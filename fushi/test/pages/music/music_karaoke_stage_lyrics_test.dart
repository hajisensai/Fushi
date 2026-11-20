import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_lyrics_view.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_mv_page.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

/// PR #3577 遗留：MV / 卡拉 OK 舞台页的结构化歌词曾用 `ref.read` 取「模糊非当前行」，
/// 页面开着时偏好变了（AI 操作 / 其他窗口）不刷新。现在由 [MusicKaraokeStageLyrics]
/// 订阅偏好，改了即时生效。
class _Clock implements FushiPlaybackClock {
  @override
  Duration get position => Duration.zero;

  @override
  Duration get duration => const Duration(minutes: 4);
}

class _AppModel extends AppModel {
  _AppModel({required PreferencesRepository prefs, required Directory dir})
    : super(testPlatformServices()) {
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dir);
    // 同正式 initialise：偏好变了经 AppModel 转发。
    prefs.addListener(notifyListeners);
  }
}

LyricTimeline _timeline() => LyricTimeline(
  format: 'ttml',
  timingQuality: LyricTimingQuality.syllable,
  lines: <LyricLine>[
    for (int i = 0; i < 3; i++)
      LyricLine(
        startMs: i * 1000,
        endMs: i * 1000 + 900,
        syllables: <LyricSyllable>[
          LyricSyllable(
            text: 'line$i',
            startMs: i * 1000,
            endMs: i * 1000 + 900,
          ),
        ],
      ),
  ],
);

void main() {
  late FushiDatabase db;
  late Directory dir;
  late _AppModel app;
  late ProviderContainer container;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('fushi_karaoke_stage_lyrics_');
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    app = _AppModel(prefs: prefs, dir: dir);
    container = ProviderContainer(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => app)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    dir.deleteSync(recursive: true);
  });

  testWidgets('舞台页歌词：页面开着时切换「模糊非当前行」即时生效', (WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 220,
              child: MusicKaraokeStageLyrics(
                timeline: _timeline(),
                clock: _Clock(),
                playing: false,
                offsetMs: 0,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    bool viewBlurs() => tester
        .widget<KaraokeLyricsView>(find.byType(KaraokeLyricsView))
        .appearance
        .blurInactive;
    expect(viewBlurs(), isTrue, reason: '默认开');

    await tester.runAsync(() => app.setMusicLyricsBlurInactive(false));
    await tester.pump();
    expect(viewBlurs(), isFalse, reason: '页面开着时关掉，不必退出重进');

    await tester.runAsync(() => app.setMusicLyricsBlurInactive(true));
    await tester.pump();
    expect(viewBlurs(), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
