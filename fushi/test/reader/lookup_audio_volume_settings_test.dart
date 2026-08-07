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
    ReaderFushiSource.readerSettings = null;
  });

  tearDown(() async {
    ReaderFushiSource.readerSettings = null;
    await db.close();
  });

  test('lookup audio volume defaults to 100 percent', () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    expect(settings.lookupAudioVolume, 100);
    expect(ReaderFushiSource.instance.lookupAudioVolume, 100);
    expect(ReaderFushiSource.instance.lookupAudioVolumeGain, 1.0);
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
    await ReaderFushiSource.instance.setLookupAudioVolume(125);

    expect(ReaderFushiSource.instance.lookupAudioVolume, 100);
    expect(ReaderFushiSource.instance.lookupAudioVolumeGain, 1.0);

    await ReaderFushiSource.instance.setLookupAudioVolume(-5);
    expect(ReaderFushiSource.instance.lookupAudioVolume, 0);
    expect(ReaderFushiSource.instance.lookupAudioVolumeGain, 0.0);

    final Map<String, String> prefs = await db.getAllPrefs();
    expect(prefs['src:reader_fushi:lookup_audio_volume'], 'i:0');
  });
}
