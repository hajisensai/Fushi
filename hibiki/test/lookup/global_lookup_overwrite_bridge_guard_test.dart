import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1225 — app-external global lookup overlay: the ⤺ overwrite-card action
/// (✓↩ "latest editable") did nothing. TODO-1188 wired the ➕ new-card + query
/// (mineEntry / duplicateCheck) bridges, but left the OTHER half of the in-app
/// popup's overwrite panel unwired: popup.js awaits a real note id from
/// callHandler('overwriteTargetNoteId', ...) to promote an existing card to the
/// editable ✓↩ state, and a real {ankiConnect,noteId} from
/// callHandler('updateEntry', {noteId, fields}) to overwrite that note in place.
/// The app-external controller had NO Dart branch for either and C++ immediately
/// null-resolved them (overwriteTargetNoteId → null → never promoted; updateEntry
/// → parseMineResult(null) → overwrite silently did nothing).
///
/// Fix (two layers, mirrors the 1188 mine bridge):
///  - C++ (global_lookup_window.cpp) DEFERS overwriteTargetNoteId + updateEntry so
///    Dart's real reply is authoritative instead of an immediate null.
///  - Dart (global_lookup_controller.dart) handles both through the SAME
///    AnkiConnect/AnkiDroid repo path the in-app DictionaryPageMixin uses
///    (repo.findOverwriteTargetNoteId / repo.updateMinedNote) and resolves the
///    bridge — reusing the in-app contract, not a new protocol.
///  - minedCardAction (the action SHEET) intentionally stays NON-deferred: it
///    needs a foreground Flutter bottom sheet the backgrounded main window cannot
///    present over the external app, so app-external overwrite is the ✓↩ path only.
///
/// The behaviour itself needs a visible Windows desktop + a real hotkey lookup +
/// a running Anki backend, which no unit test can exercise; this source-scan guard
/// defends the wiring against a silent regression.
void main() {
  String read(String p) => File(p).readAsStringSync();

  group('Dart controller: overwriteTargetNoteId + updateEntry bridge branches',
      () {
    late String src;
    setUpAll(() {
      src = read('lib/src/lookup/global_lookup_controller.dart');
    });

    test('_onJsMessage routes overwriteTargetNoteId / updateEntry to handlers',
        () {
      expect(src.contains("if (handler == 'overwriteTargetNoteId')"), isTrue,
          reason: '_onJsMessage 必须有覆写目标探测分支（否则已存在卡永不进 ✓↩）');
      expect(src.contains('_handleOverwriteTargetBridge('), isTrue,
          reason: '覆写目标探测走独立 deferred 处理器');
      expect(src.contains("if (handler == 'updateEntry')"), isTrue,
          reason: '_onJsMessage 必须有覆写执行分支（否则点 ✓↩ 覆写静默失败）');
      expect(src.contains('_handleUpdateBridge('), isTrue,
          reason: '覆写执行走独立 deferred 处理器');
    });

    test('overwrite handlers reuse the in-app Anki repo contract', () {
      // 真走 AnkiConnect/AnkiDroid repo，与 in-app findOverwriteTargetNoteId /
      // onUpdateEntry 同路径（复用契约，别发明新协议）。
      expect(src.contains('repo.findOverwriteTargetNoteId('), isTrue,
          reason: '覆写目标探测走 repo.findOverwriteTargetNoteId（与 in-app 同路径）');
      expect(src.contains('repo.updateMinedNote('), isTrue,
          reason: '覆写执行走 repo.updateMinedNote 按 id 覆盖（不新增卡、不查重）');
      // 覆写前同样落盘词典 gaiji 媒体字节（与新建 mineEntry 一致，外字不退化）。
      expect(src.contains('writeDictionaryMediaCache('), isTrue,
          reason: '覆写前必须落盘词典外字媒体缓存');
      // 覆写不记账：不得在覆写路径调 _recordMinedStats（与 in-app overwrite=true 一致）。
      final int updateStart =
          src.indexOf('Future<Map<String, Object?>> _updateEntry(');
      expect(updateStart, greaterThan(0), reason: '必须有 _updateEntry 覆写辅助方法');
      final int updateEnd = src.indexOf('\n  }', updateStart);
      final String updateBody = src.substring(updateStart, updateEnd);
      expect(updateBody.contains('_recordMinedStats('), isFalse,
          reason: '覆写不得计入制卡统计（overwrite 修正已存在卡，不记账）');
    });

    test('overwrite bridge replies are pushed back via resolveBridge', () {
      // overwriteTargetNoteId 回裸 int?，updateEntry 回 {ankiConnect,noteId}，都必须
      // resolveBridge 回传 iframe（popup.js 据此升 ✓↩ / 刷新覆写结果）。
      expect(
        src.contains('overwriteTargetNoteId -> reply=\$reply (id=\$id)'),
        isTrue,
        reason: '覆写目标探测结果必须 resolveBridge 回传',
      );
      expect(
        src.contains('updateEntry -> reply=\$reply (id=\$id)'),
        isTrue,
        reason: '覆写执行结果必须 resolveBridge 回传',
      );
    });
  });

  test('C++ overlay DEFERS overwriteTargetNoteId / updateEntry (not sheet)',
      () {
    final String cpp = read('windows/runner/global_lookup_window.cpp');
    // 否则 C++ 即时 null-resolve → Dart 真回复被忽略 → 已存在卡不进 ✓↩、覆写不落。
    expect(cpp.contains('body.find("\\"overwriteTargetNoteId\\"")'), isTrue,
        reason: 'overwriteTargetNoteId 必须纳入 deferred（不即时 null-resolve）');
    expect(cpp.contains('body.find("\\"updateEntry\\"")'), isTrue,
        reason: 'updateEntry 必须纳入 deferred');
    // minedCardAction 仍保持即时 null（需前台底栏，后台主窗无法呈现）——不得纳入 deferred。
    expect(cpp.contains('body.find("\\"minedCardAction\\"")'), isFalse,
        reason: 'minedCardAction 动作面板需前台 Flutter 底栏，app 外保持即时 null 降级');
  });
}
