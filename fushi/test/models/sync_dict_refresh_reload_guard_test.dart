// BUG-2752 source-scan guard.
//
// Root cause: after an interconnect sync imported dictionaries,
// `AppModel.refreshAfterSyncRun` called `dictRepo.clearDictionariesCache()`
// and then `_rebuildDictPathsCacheAsync()`, which reads the (now empty)
// in-memory cache to build the FFI engine. The engine was reloaded with zero
// dictionaries: the management list emptied and every lookup returned nothing,
// looking like "downloading from the server deleted all local dictionaries"
// until a restart ran `loadFromDb()` again. The DB rows and files were intact.
//
// Fix: the sync-import branch reloads the repository from the DB
// (`reloadDictionariesFromDb` → `dictRepo.loadFromDb()` before the engine
// rebuild). The sync importer writes `dictionary_metadata` directly, so merely
// dropping the clear would leave the newly pulled dictionaries invisible.
//
// Layer rationale: the rebuild drives the native fushidicts engine that
// flutter_test cannot link, and `refreshAfterSyncRun` is an `AppModel` member
// wired to the live DB + filesystem + FFI; the strongest landable guard is a
// source scan over the control flow (same as BUG-171's
// dictionary_delete_engine_reload_guard_test).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  late String src;

  setUpAll(() {
    final File f = File('lib/src/models/app_model.dart');
    expect(f.existsSync(), isTrue,
        reason: 'app_model.dart not found at ${f.absolute.path}');
    src = f.readAsStringSync();
  });

  String dictImportBranch() {
    final String body = maskComments(methodBody(
        src, 'Future<void> refreshAfterSyncRun(SyncRunReport report)'));
    final int start = body.indexOf('report.dictionariesImported > 0');
    expect(start, greaterThanOrEqualTo(0),
        reason: 'refreshAfterSyncRun must handle dictionariesImported');
    final int open = body.indexOf('{', start);
    int depth = 0;
    for (int i = open; i < body.length; i++) {
      if (body[i] == '{') depth++;
      if (body[i] == '}' && --depth == 0) return body.substring(open, i + 1);
    }
    fail('unbalanced braces in dictionariesImported branch');
  }

  test(
      'BUG-2752: sync dictionary import reloads the repository from the DB '
      'instead of rebuilding the engine off an emptied cache', () {
    final String branch = dictImportBranch();
    expect(branch.contains('clearDictionariesCache('), isFalse,
        reason: 'clearing the in-memory cache here rebuilds the engine with '
            'zero dictionaries — every local dictionary disappears');
    expect(
      branch.contains('reloadDictionariesFromDb(') ||
          branch.contains('dictRepo.loadFromDb('),
      isTrue,
      reason: 'the importer wrote dictionary_metadata directly; the cache '
          'must be reloaded from the DB so local + pulled dicts are loaded',
    );
    expect(branch.contains('dictionaryMenuNotifier.notifyListeners('), isTrue,
        reason: 'the dictionary management list must refresh');
  });

  test('BUG-2752: reloadDictionariesFromDb loads the DB before the rebuild',
      () {
    final String body = maskComments(
        methodBody(src, 'Future<void> reloadDictionariesFromDb()'));
    final int load = body.indexOf('dictRepo.loadFromDb(');
    final int rebuild = body.indexOf('_rebuildDictPathsCacheAsync(');
    expect(load, greaterThanOrEqualTo(0));
    expect(rebuild, greaterThan(load),
        reason: 'the engine must be rebuilt from the freshly loaded cache');
    expect(body.contains('dictionarySearchAgainNotifier.notifyListeners('),
        isTrue);
  });
}
