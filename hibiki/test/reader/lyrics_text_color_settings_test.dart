import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _testDb() {
  return FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  late FushiDatabase db;

  setUp(() {
    db = _testDb();
    MediaSource.setDatabase(db);
    ReaderHibikiSource.readerSettings = null;
  });

  tearDown(() async {
    ReaderHibikiSource.readerSettings = null;
    await db.close();
  });

  // TODO-368: 歌词字幕色独立可调。哨兵 0 = 未设置（跟随主题，向后兼容）。
  test('lyrics text color defaults to sentinel 0 (follow theme)', () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    expect(settings.lyricsTextColor, 0);
    expect(ReaderHibikiSource.instance.lyricsTextColor, 0);
  });

  test('lyrics text color persists through ReaderSettings', () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setLyricsTextColor(0xFF112233);

    final ReaderSettings restored = ReaderSettings(db);
    await restored.refreshFromDb();

    expect(restored.lyricsTextColor, 0xFF112233);
  });

  test('clearing lyrics text color returns to sentinel 0', () async {
    await ReaderHibikiSource.instance.setLyricsTextColor(0xFFAABBCC);
    expect(ReaderHibikiSource.instance.lyricsTextColor, 0xFFAABBCC);

    await ReaderHibikiSource.instance.clearLyricsTextColor();
    expect(ReaderHibikiSource.instance.lyricsTextColor, 0);

    final Map<String, String> prefs = await db.getAllPrefs();
    expect(prefs['src:reader_ttu:lyrics_text_color'], 'i:0');
  });
}
