import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the BUG-483 fix: "添加本地音频数据库" must support referencing the
/// original file instead of unconditionally copying it into AppData. These are
/// source-level guards so a future refactor can't silently drop the reference
/// branch or the external-path deletion safety.
void main() {
  group('local audio reference-original contract (BUG-483)', () {
    final String manager =
        File('lib/src/models/local_audio_manager.dart').readAsStringSync();
    final String appModel =
        File('lib/src/models/app_model.dart').readAsStringSync();
    final String dialog = File(
            'lib/src/pages/implementations/dictionary_settings_dialog_page.dart')
        .readAsStringSync();
    final String schema =
        File('lib/src/settings/settings_schema_lookup.dart').readAsStringSync();

    test('importFile takes a reference flag and has a no-copy early return',
        () {
      expect(manager, contains('bool reference = false'),
          reason: 'importFile must accept a reference flag (default false).');
      expect(manager, contains('if (reference) {'),
          reason: 'reference=true must short-circuit before the copy path.');
      // The reference branch must return the original sourcePath, not a copy.
      expect(manager, contains('path: sourcePath'),
          reason: 'reference mode must return an entry pointing at the '
              'original source path (no copy into the store).');
    });

    test('cleanup never deletes external referenced files', () {
      expect(manager, contains('_isInternalCopy'),
          reason: 'A path-inside-store predicate must gate deletions so '
              'external referenced paths are never removed.');
      // remove() must guard deletion behind the internal-copy predicate.
      final RegExp removeGuard = RegExp(
          r'if \(_isInternalCopy\(entry\.path\)\) \{\s*await deleteFiles');
      expect(removeGuard.hasMatch(manager), isTrue,
          reason: 'remove() must only deleteFiles when the path is an '
              'internal copy, never a user-referenced external file.');
    });

    test('reference flag is threaded through app model and UI', () {
      expect(appModel, contains('bool reference = false'),
          reason: 'AppModel.importLocalAudioDbFile must forward reference.');
      expect(appModel, contains('reference: reference'),
          reason: 'AppModel must pass reference into the manager.');
      expect(dialog, contains('isDesktopPlatform'),
          reason: 'The reference toggle must be desktop-gated.');
      expect(dialog, contains('local_audio_reference_original'),
          reason: 'The dialog must surface the reference toggle label.');
      expect(dialog, contains('Function(bool reference)?'),
          reason: 'onPickLocalDb must receive the reference flag.');
      expect(schema, contains('reference: reference'),
          reason: 'The lookup settings wiring must forward the flag.');
    });
  });
}
