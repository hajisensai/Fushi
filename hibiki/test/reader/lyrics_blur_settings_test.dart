import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/media/audiobook/lyrics_mode_html.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

AudioCue _cue(int i) {
  return AudioCue()
    ..id = i + 1
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = i
    ..textFragmentId = 'frag-$i'
    ..text = 'cue $i'
    ..startMs = i * 1000
    ..endMs = i * 1000 + 900
    ..audioFileIndex = 0;
}

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

String _generate({required bool blur, bool vertical = false}) {
  return LyricsModeHtml.generate(
    cues: <AudioCue>[_cue(0), _cue(1)],
    currentIndex: 0,
    backgroundColor: 'rgba(255,255,255,1.00)',
    textColor: 'rgba(0,0,0,1.00)',
    accentColor: 'rgba(255,220,0,1.00)',
    fontSize: 20,
    blur: blur,
    vertical: vertical,
  );
}

void main() {
  group('LyricsModeHtml blur (TODO-908)', () {
    test(
        'blur=true emits filter:blur on current cue + setBlur hook + body class',
        () {
      final String html = _generate(blur: true);

      expect(html, contains('filter: blur(8px)'));
      expect(html, contains('class="lyrics-blur"'));
      expect(html, contains('body.lyrics-blur .cue.current'));
      expect(html, contains('body.lyrics-blur .cue.current:hover'));
      expect(html, contains('.cue.current.revealed'));
      expect(html, contains('window.__lyricsSetBlur'));
    });

    test('blur hook is always present (live toggle), body class gated by flag',
        () {
      final String off = _generate(blur: false);
      expect(off, contains('window.__lyricsSetBlur'));
      expect(off, isNot(contains('class="lyrics-blur"')));
    });

    test('blur is orthogonal to vertical writing-mode', () {
      final String html = _generate(blur: true, vertical: true);
      expect(html, contains('writing-mode: vertical-rl;'));
      expect(html, contains('class="lyrics-blur"'));
      expect(html, contains('filter: blur(8px)'));
    });
  });

  group('lyrics blur setting (TODO-908)', () {
    late HibikiDatabase db;

    setUp(() {
      db = _testDb();
      MediaSource.setDatabase(db);
      ReaderHibikiSource.readerSettings = null;
    });

    tearDown(() async {
      ReaderHibikiSource.readerSettings = null;
      await db.close();
    });

    test('lyrics blur defaults to false', () async {
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();

      expect(settings.lyricsBlur, isFalse);
      expect(ReaderHibikiSource.instance.lyricsBlur, isFalse);
    });

    test('lyrics blur persists through ReaderSettings', () async {
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setLyricsBlur(true);

      final ReaderSettings restored = ReaderSettings(db);
      await restored.refreshFromDb();

      expect(restored.lyricsBlur, isTrue);
    });

    test('lyrics blur uses its own independent key', () async {
      await ReaderHibikiSource.instance.setLyricsBlur(true);

      final Map<String, String> prefs = await db.getAllPrefs();
      expect(prefs.containsKey('src:reader_ttu:lyrics_blur'), isTrue);
    });
  });
}
