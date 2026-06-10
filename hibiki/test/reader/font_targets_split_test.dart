import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-049: the three font targets (software UI / novel body / dictionary) must
/// be three independent persisted lists. These tests pin: each target keys to
/// its own pref, mutating one never touches the others, the new targets lazily
/// seed from the legacy `custom_fonts` body list (no user font lost), and once
/// seeded they diverge independently.
HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

List<Map<String, dynamic>> _font(String name, {String? path}) =>
    <Map<String, dynamic>>[
      <String, dynamic>{'name': name, 'path': path, 'enabled': true},
    ];

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

  test('three targets back distinct preference keys', () {
    expect(ReaderSettings.fontKeyForTarget(FontTarget.body), 'custom_fonts');
    expect(ReaderSettings.fontKeyForTarget(FontTarget.appUi), 'app_ui_fonts');
    expect(
      ReaderSettings.fontKeyForTarget(FontTarget.dictionary),
      'dict_fonts',
    );
    // Body key must stay the legacy value verbatim (backward-compat ironclad).
    expect(ReaderSettings.fontKeyBody, 'custom_fonts');
  });

  test('each target persists independently of the others', () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    await settings.setFontsForTarget(FontTarget.body, _font('BodyFont'));
    await settings.setFontsForTarget(FontTarget.appUi, _font('UiFont'));
    await settings.setFontsForTarget(
      FontTarget.dictionary,
      _font('DictFont'),
    );

    final ReaderSettings restored = ReaderSettings(db);
    await restored.refreshFromDb();

    expect(restored.customFonts.single['name'], 'BodyFont');
    expect(restored.appUiFonts.single['name'], 'UiFont');
    expect(restored.dictionaryFonts.single['name'], 'DictFont');
  });

  test('changing the dictionary target does not touch body or UI', () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setFontsForTarget(FontTarget.body, _font('BodyFont'));
    await settings.setFontsForTarget(FontTarget.appUi, _font('UiFont'));
    // Touch the migrated getters so the new targets are materialised.
    settings.dictionaryFonts;

    await settings.setFontsForTarget(
      FontTarget.dictionary,
      _font('OnlyDict'),
    );

    expect(settings.customFonts.single['name'], 'BodyFont');
    expect(settings.appUiFonts.single['name'], 'UiFont');
    expect(settings.dictionaryFonts.single['name'], 'OnlyDict');
  });

  test('new targets lazily seed from the legacy body list', () async {
    // Simulate pre-split user data: only the legacy `custom_fonts` key is set.
    final ReaderSettings legacy = ReaderSettings(db);
    await legacy.refreshFromDb();
    await legacy.setCustomFonts(_font('LegacyChoice', path: '/tmp/x.ttf'));

    // A fresh load (post-upgrade) must surface that choice on all three targets.
    final ReaderSettings upgraded = ReaderSettings(db);
    await upgraded.refreshFromDb();

    expect(upgraded.customFonts.single['name'], 'LegacyChoice');
    expect(upgraded.appUiFonts.single['name'], 'LegacyChoice');
    expect(upgraded.dictionaryFonts.single['name'], 'LegacyChoice');
  });

  test('after seeding, targets diverge without re-seeding from body', () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setCustomFonts(_font('Seed'));

    // Materialise + diverge the UI target.
    expect(settings.appUiFonts.single['name'], 'Seed');
    await settings.setFontsForTarget(FontTarget.appUi, _font('UiOnly'));

    // Now change the body. The already-seeded UI target must NOT follow it.
    await settings.setCustomFonts(_font('BodyChanged'));

    final ReaderSettings restored = ReaderSettings(db);
    await restored.refreshFromDb();
    expect(restored.customFonts.single['name'], 'BodyChanged');
    expect(restored.appUiFonts.single['name'], 'UiOnly');
  });

  test('empty body seeds an empty (independent) new target', () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    // No body fonts set at all.
    expect(settings.dictionaryFonts, isEmpty);

    // Later set a body font: the already-seeded (empty) dict target stays empty.
    await settings.setCustomFonts(_font('BodyLater'));
    final ReaderSettings restored = ReaderSettings(db);
    await restored.refreshFromDb();
    expect(restored.customFonts.single['name'], 'BodyLater');
    expect(restored.dictionaryFonts, isEmpty);
  });
}
