import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1188 follow-up — app-external global lookup overlay: the ➕ (mine to Anki)
/// button did nothing. Same shape as the favorite/audio bridge (see
/// global_lookup_favorite_audio_bridge_guard_test.dart): popup.js awaits the real
/// {ankiConnect,noteId} from callHandler('mineEntry', fields) and then a real bool
/// from callHandler('duplicateCheck', ...) to flip ➕→✓, but the app-external
/// controller had NO Dart branch for either and C++ immediately null-resolved them
/// (mineEntry → parseMineResult(null) → no card; duplicateCheck → null → never ✓).
///
/// Fix (two layers, mirrors 1188 favorite):
///  - C++ (global_lookup_window.cpp) DEFERS mineEntry + duplicateCheck so Dart's
///    real reply is authoritative instead of an immediate null.
///  - Dart (global_lookup_controller.dart) handles both through the same
///    AnkiConnect/AnkiDroid repo path the in-app DictionaryPageMixin uses
///    (repo.mineEntry / repo.isDuplicate) and resolves the bridge.
///
/// The behaviour itself needs a visible Windows desktop + a real hotkey lookup +
/// a running Anki backend, which no unit test can exercise; this source-scan guard
/// defends the wiring against a silent regression.
void main() {
  String read(String p) => File(p).readAsStringSync();

  group('Dart controller: mine + duplicate bridge branches', () {
    late String src;
    setUpAll(() {
      // spec 2026-07-10: 桥 handler 抽到 overlay_bridge_handlers.dart 与剪贴板
      // 面板共享（红线：两表面不复制不漂移）；守卫扫 controller+共享实现拼接。
      src = read('lib/src/lookup/global_lookup_controller.dart') +
          read('lib/src/lookup/overlay_bridge_handlers.dart');
    });

    test('_onJsMessage routes mineEntry / duplicateCheck to deferred handlers',
        () {
      expect(src.contains("case 'mineEntry':"), isTrue,
          reason: '_onJsMessage 必须有制卡分支（过去根本没有 → ➕ 按钮永挂）');
      expect(src.contains('_handleMineBridge('), isTrue,
          reason: '制卡走独立 deferred 处理器');
      expect(src.contains("case 'duplicateCheck':"), isTrue,
          reason: '_onJsMessage 必须有查重分支（否则 ➕→✓ 永不切换）');
      expect(src.contains('_handleDuplicateBridge('), isTrue,
          reason: '查重走独立 deferred 处理器');
    });

    test('mine handler goes through the real Anki repo and resolves the bridge',
        () {
      // 真走 AnkiConnect/AnkiDroid repo（非 UI 假动作），与 in-app onMineEntry 同路径。
      expect(src.contains('createAnkiRepository()'), isTrue,
          reason: '制卡/查重必须调真 Anki repo');
      expect(src.contains('repo.mineEntry('), isTrue,
          reason: '制卡走 repo.mineEntry（AnkiConnect/AnkiDroid）');
      expect(src.contains('repo.isDuplicate('), isTrue,
          reason: '查重走 repo.isDuplicate（与 in-app checkDuplicate 同路径）');
      // 制卡前落盘词典 gaiji 媒体字节（否则外字退化成 alt 文本），与 in-app 一致。
      expect(src.contains('writeDictionaryMediaCache('), isTrue,
          reason: '制卡前必须落盘词典外字媒体缓存');
      // 回传 {ankiConnect,noteId} / bool 给 iframe（popup.js parseMineResult / ✓ 涂色）。
      expect(src.contains('resolveBridge(id, reply)'), isTrue,
          reason: '制卡/查重结果必须 resolveBridge 回传');
    });
  });

  test('C++ overlay DEFERS mineEntry / duplicateCheck', () {
    final String cpp = read('windows/runner/global_lookup_window.cpp');
    // 否则 C++ 会即时 null-resolve，Dart 的真回复被忽略、➕ 不落卡、✓ 不切换。
    expect(cpp.contains('body.find("\\"mineEntry\\"")'), isTrue,
        reason: 'mineEntry 必须纳入 deferred（不即时 null-resolve）');
    expect(cpp.contains('body.find("\\"duplicateCheck\\"")'), isTrue,
        reason: 'duplicateCheck 必须纳入 deferred');
  });
}
