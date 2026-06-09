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

  test('lookup audio volume defaults to 100 percent', () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    expect(settings.lookupAudioVolume, 100);
    expect(ReaderHibikiSource.instance.lookupAudioVolume, 100);
    expect(ReaderHibikiSource.instance.lookupAudioVolumeGain, 1.0);
  });

  test('lookup audio volume persists through ReaderSettings', () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setLookupAudioVolume(35);

    final ReaderSettings restored = ReaderSettings(db);
    await restored.refreshFromDb();

    expect(restored.lookupAudioVolume, 35);
  });

  test('lookup audio volume source fallback clamps and persists', () async {
    await ReaderHibikiSource.instance.setLookupAudioVolume(125);

    expect(ReaderHibikiSource.instance.lookupAudioVolume, 100);
    expect(ReaderHibikiSource.instance.lookupAudioVolumeGain, 1.0);

    await ReaderHibikiSource.instance.setLookupAudioVolume(-5);
    expect(ReaderHibikiSource.instance.lookupAudioVolume, 0);
    expect(ReaderHibikiSource.instance.lookupAudioVolumeGain, 0.0);

    final Map<String, String> prefs = await db.getAllPrefs();
    expect(prefs['src:reader_ttu:lookup_audio_volume'], 'i:0');
  });
}
