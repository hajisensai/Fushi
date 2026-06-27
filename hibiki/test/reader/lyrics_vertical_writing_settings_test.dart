import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
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

  // TODO-907: 歌词竖排默认 false（横排），向后兼容历史行为。
  test('lyrics vertical writing defaults to false (horizontal)', () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    expect(settings.lyricsVerticalWriting, isFalse);
    expect(ReaderHibikiSource.instance.lyricsVerticalWriting, isFalse);
  });

  test('lyrics vertical writing persists through ReaderSettings', () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setLyricsVerticalWriting(true);

    final ReaderSettings restored = ReaderSettings(db);
    await restored.refreshFromDb();

    expect(restored.lyricsVerticalWriting, isTrue);
  });

  // 铁律：歌词竖排必须用独立 key lyrics_vertical_writing，不得复用正文真值
  // ttu_writing_mode（它默认 vertical-rl，复用会连坐正文默认竖排）。
  test('lyrics vertical uses its own key, never touches ttu_writing_mode',
      () async {
    await ReaderHibikiSource.instance.setLyricsVerticalWriting(true);

    final Map<String, String> prefs = await db.getAllPrefs();
    expect(prefs.containsKey('src:reader_ttu:lyrics_vertical_writing'), isTrue);
    // ttu_writing_mode must NOT be written by the lyrics toggle.
    expect(prefs.containsKey('src:reader_ttu:ttu_writing_mode'), isFalse);
  });
}
