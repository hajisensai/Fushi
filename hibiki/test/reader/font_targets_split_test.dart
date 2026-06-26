import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-225 / TODO-221A: custom fonts are stored as one shared catalog plus
/// per-target membership/order/enabled rows. The old public list API remains
/// intact while legacy `custom_fonts` / `app_ui_fonts` / `dict_fonts` data can
/// be read as the new model.
HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

const String _prefPrefix = 'src:reader_ttu:';
const String _catalogPref = '${_prefPrefix}font_catalog';
const String _targetsPref = '${_prefPrefix}font_targets';

Map<String, dynamic> _font(
  String name, {
  String? path,
  bool enabled = true,
}) =>
    <String, dynamic>{
      'name': name,
      'path': path,
      'enabled': enabled,
    };

List<Map<String, dynamic>> _fonts(
  Map<String, dynamic> first, [
  Map<String, dynamic>? second,
]) =>
    <Map<String, dynamic>>[
      first,
      if (second != null) second,
    ];

Future<Map<String, dynamic>> _storedJson(
  HibikiDatabase db,
  String key,
) async {
  final Map<String, String> prefs = await db.getAllPrefs();
  return jsonDecode(prefs[key]!) as Map<String, dynamic>;
}

List<dynamic> _targetRows(Map<String, dynamic> targets, String key) {
  final Map<String, dynamic> rows =
      (targets['targets'] as Map<dynamic, dynamic>).cast<String, dynamic>();
  return rows[key] as List<dynamic>;
}

Map<String, String> _catalogIdsByPath(Map<String, dynamic> catalog) {
  final List<dynamic> fonts = catalog['fonts'] as List<dynamic>;
  return <String, String>{
    for (final dynamic row in fonts)
      (row as Map<dynamic, dynamic>)['path'] as String: row['id'] as String,
  };
}

void main() {
  late HibikiDatabase db;

  setUp(() {
    db = _testDb();
  });

  tearDown(() async {
    await db.close();
  });

  test('exposes the new catalog preference keys alongside legacy target keys',
      () {
    expect(ReaderSettings.fontKeyForTarget(FontTarget.body), 'custom_fonts');
    expect(ReaderSettings.fontKeyForTarget(FontTarget.appUi), 'app_ui_fonts');
    expect(
      ReaderSettings.fontKeyForTarget(FontTarget.dictionary),
      'dict_fonts',
    );
    // Body key must stay the legacy value verbatim (backward-compat ironclad).
    expect(ReaderSettings.fontKeyBody, 'custom_fonts');
    // TODO-864: video subtitle target maps to its own key, equally ironclad.
    expect(
      ReaderSettings.fontKeyForTarget(FontTarget.videoSubtitle),
      'video_sub_fonts',
    );
    expect(ReaderSettings.fontKeyVideoSubtitle, 'video_sub_fonts');
  });

  test('video subtitle target reads/writes independently of other targets',
      () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setCustomFonts(
      _fonts(_font('BodyFont', path: '/fonts/body.ttf')),
    );
    await settings.setFontsForTarget(
      FontTarget.videoSubtitle,
      _fonts(_font('SubFont', path: '/fonts/sub.ttf')),
    );

    final ReaderSettings restored = ReaderSettings(db);
    await restored.refreshFromDb();

    expect(restored.videoSubtitleFonts.single['name'], 'SubFont');
    expect(restored.videoSubtitleFonts.single['path'], '/fonts/sub.ttf');
    // Other targets untouched by the subtitle write.
    expect(restored.customFonts.single['name'], 'BodyFont');
    expect(
      restored.fontsForTarget(FontTarget.videoSubtitle).single['name'],
      'SubFont',
    );
  });

  test('video subtitle target is NOT body-seeded (defaults empty)', () async {
    // Critical TODO-864 backward-compat: unlike the historical appUi/dictionary
    // body-seed compat, the new video subtitle target must stay empty when the
    // user has only ever set the body list -> overlay falls back to platform
    // default (null fontFamily), matching the pre-split visuals.
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setCustomFonts(
      _fonts(_font('BodySeed', path: '/fonts/body-seed.ttf')),
    );

    final ReaderSettings restored = ReaderSettings(db);
    await restored.refreshFromDb();

    // appUi/dictionary still inherit body (historical compat preserved)...
    expect(restored.appUiFonts.single['name'], 'BodySeed');
    expect(restored.dictionaryFonts.single['name'], 'BodySeed');
    // ...but video subtitle does not.
    expect(restored.videoSubtitleFonts, isEmpty);
  });

  test('setting body fonts first still seeds untouched targets from body',
      () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setCustomFonts(
      _fonts(_font('BodySeed', path: '/fonts/body-seed.ttf')),
    );

    final Map<String, String> prefsAfterBodyWrite = await db.getAllPrefs();
    expect(prefsAfterBodyWrite, contains('${_prefPrefix}custom_fonts'));
    expect(prefsAfterBodyWrite, isNot(contains('${_prefPrefix}app_ui_fonts')));
    expect(prefsAfterBodyWrite, isNot(contains('${_prefPrefix}dict_fonts')));
    final Map<String, dynamic> targetsAfterBodyWrite =
        jsonDecode(prefsAfterBodyWrite[_targetsPref]!) as Map<String, dynamic>;
    expect(
      (targetsAfterBodyWrite['targets'] as Map<dynamic, dynamic>).keys,
      <String>['custom_fonts'],
    );

    final ReaderSettings restored = ReaderSettings(db);
    await restored.refreshFromDb();

    expect(restored.customFonts.single['name'], 'BodySeed');
    expect(restored.appUiFonts.single['name'], 'BodySeed');
    expect(restored.dictionaryFonts.single['name'], 'BodySeed');
    expect(restored.appUiFonts.single['path'], '/fonts/body-seed.ttf');
    expect(restored.dictionaryFonts.single['path'], '/fonts/body-seed.ttf');
  });

  test('explicit empty targets do not re-seed after body changes', () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setCustomFonts(
      _fonts(_font('InitialBody', path: '/fonts/initial-body.ttf')),
    );
    await settings.setFontsForTarget(
      FontTarget.appUi,
      <Map<String, dynamic>>[],
    );
    await settings.setFontsForTarget(
      FontTarget.dictionary,
      <Map<String, dynamic>>[],
    );

    await settings.setCustomFonts(
      _fonts(_font('ChangedBody', path: '/fonts/changed-body.ttf')),
    );

    final ReaderSettings restored = ReaderSettings(db);
    await restored.refreshFromDb();

    expect(restored.customFonts.single['name'], 'ChangedBody');
    expect(restored.appUiFonts, isEmpty);
    expect(restored.dictionaryFonts, isEmpty);

    final Map<String, dynamic> targets = await _storedJson(db, _targetsPref);
    expect(_targetRows(targets, 'app_ui_fonts'), isEmpty);
    expect(_targetRows(targets, 'dict_fonts'), isEmpty);
  });

  test('legacy three keys merge into a de-duplicated catalog', () async {
    final Map<String, dynamic> mincho =
        _font('Mincho', path: '/fonts/mincho.ttf', enabled: true);
    final Map<String, dynamic> gothic =
        _font('Gothic', path: '/fonts/gothic.ttf', enabled: false);
    await db.setPref(
      '${_prefPrefix}custom_fonts',
      jsonEncode(_fonts(mincho, gothic)),
    );
    await db.setPref(
      '${_prefPrefix}app_ui_fonts',
      jsonEncode(_fonts(gothic, mincho)),
    );
    await db.setPref(
      '${_prefPrefix}dict_fonts',
      jsonEncode(_fonts(_font(
        'Mincho',
        path: '/fonts/mincho.ttf',
        enabled: false,
      ))),
    );

    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    expect(
      settings.customFonts.map((Map<String, dynamic> e) => e['name']),
      <String>['Mincho', 'Gothic'],
    );
    expect(
      settings.appUiFonts.map((Map<String, dynamic> e) => e['name']),
      <String>['Gothic', 'Mincho'],
    );
    expect(settings.dictionaryFonts.single['enabled'], isFalse);

    final Map<String, dynamic> catalog = await _storedJson(db, _catalogPref);
    final Map<String, dynamic> targets = await _storedJson(db, _targetsPref);
    expect(catalog['version'], 1);
    expect(targets['version'], 1);
    expect(catalog['fonts'], hasLength(2));

    final Map<String, String> idByPath = _catalogIdsByPath(catalog);
    expect(
        idByPath.keys,
        containsAll(<String>[
          '/fonts/mincho.ttf',
          '/fonts/gothic.ttf',
        ]));
    expect(
      (_targetRows(targets, 'app_ui_fonts').first
          as Map<dynamic, dynamic>)['fontId'],
      idByPath['/fonts/gothic.ttf'],
    );
  });

  test('same catalog font can appear in multiple targets independently',
      () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setFontsForTarget(
      FontTarget.body,
      _fonts(
        _font('Shared', path: '/fonts/shared.ttf'),
        _font('BodyOnly', path: '/fonts/body.ttf'),
      ),
    );
    await settings.setFontsForTarget(
      FontTarget.appUi,
      _fonts(_font('Shared', path: '/fonts/shared.ttf', enabled: false)),
    );
    await settings.setFontsForTarget(
      FontTarget.dictionary,
      _fonts(
        _font('BodyOnly', path: '/fonts/body.ttf', enabled: false),
        _font('Shared', path: '/fonts/shared.ttf', enabled: true),
      ),
    );

    final ReaderSettings restored = ReaderSettings(db);
    await restored.refreshFromDb();

    expect(restored.customFonts.map((Map<String, dynamic> e) => e['name']),
        <String>['Shared', 'BodyOnly']);
    expect(restored.appUiFonts.single['enabled'], isFalse);
    expect(restored.dictionaryFonts.first['name'], 'BodyOnly');
    expect(restored.dictionaryFonts.first['enabled'], isFalse);

    final Map<String, dynamic> catalog = await _storedJson(db, _catalogPref);
    expect(catalog['fonts'], hasLength(2));
    final Map<String, dynamic> targets = await _storedJson(db, _targetsPref);
    expect(_targetRows(targets, 'custom_fonts'), hasLength(2));
    expect(_targetRows(targets, 'app_ui_fonts'), hasLength(1));
    expect(_targetRows(targets, 'dict_fonts'), hasLength(2));
  });

  test('bad catalog json falls back to legacy keys and repairs the model',
      () async {
    await db.setPref(_catalogPref, '{not json');
    await db.setPref(_targetsPref, '{"version":1,"targets":false}');
    await db.setPref(
      '${_prefPrefix}custom_fonts',
      jsonEncode(_fonts(_font('Body', path: r'C:\fonts\body.ttf'))),
    );
    await db.setPref(
      '${_prefPrefix}app_ui_fonts',
      jsonEncode(_fonts(_font('UI', path: r'C:\fonts\ui.ttf'))),
    );
    await db.setPref(
      '${_prefPrefix}dict_fonts',
      jsonEncode(_fonts(_font('Dict', path: r'C:\fonts\dict.ttf'))),
    );

    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    expect(settings.customFonts.single['path'], r'C:\fonts\body.ttf');
    expect(settings.appUiFonts.single['path'], r'C:\fonts\ui.ttf');
    expect(settings.dictionaryFonts.single['path'], r'C:\fonts\dict.ttf');

    final Map<String, dynamic> repaired = await _storedJson(db, _catalogPref);
    expect(repaired['fonts'], hasLength(3));
    expect(_catalogIdsByPath(repaired).keys, contains(r'C:\fonts\dict.ttf'));
  });

  test('catalog de-duplication preserves distinct paths for the same name',
      () async {
    await db.setPref(
      '${_prefPrefix}custom_fonts',
      jsonEncode(_fonts(
        _font('Noto', path: '/fonts/noto-jp.ttf'),
        _font('Noto', path: '/fonts/noto-serif.ttf'),
      )),
    );

    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    expect(
      settings.customFonts.map((Map<String, dynamic> e) => e['path']),
      <String>['/fonts/noto-jp.ttf', '/fonts/noto-serif.ttf'],
    );
    final Map<String, dynamic> catalog = await _storedJson(db, _catalogPref);
    expect(catalog['fonts'], hasLength(2));
    expect(
      _catalogIdsByPath(catalog).keys,
      containsAll(<String>['/fonts/noto-jp.ttf', '/fonts/noto-serif.ttf']),
    );
  });
}
