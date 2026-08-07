import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1188 — app-external global lookup overlay: the audio (♪ pronunciation)
/// and favorite (☆/★) buttons did nothing. Two root causes, three layers wired
/// here; this source-scan guard defends all of them against a silent regression
/// (the behaviour itself needs a visible Windows desktop + a real hotkey lookup,
/// which no unit test can exercise — see the cross-iframe ExecuteScript round-trip
/// in global_lookup_host_test.mjs for the JS-level proof).
///
/// Root cause 1 — bridge round-trip could not reach the source iframe: popup.js
/// runs inside a CHILD iframe (global_lookup_host.js hosts N popup.html iframes),
/// so its callHandler Promise lives in THAT iframe's popup_bridge_adapter realm.
/// Native (global_lookup_window.cpp) only ExecuteScripts the TOP-LEVEL document,
/// whose window.__hibikiBridgeResolve is a different realm — the reply never
/// reached the iframe and every awaited callHandler (audio + favorite) hung. Fix:
/// the host rewrites each outbound frame-local __bridgeId to a host-global id +
/// records a route, and the top-level __hibikiBridgeResolve forwards the reply to
/// the SOURCE iframe's adapter (installBridgeRouter).
///
/// Root cause 2 — favorite had NO Dart branch and was immediately null-resolved by
/// C++. The controller now handles favoriteEntry/favoriteCheck against the
/// FavoriteWords table and resolves the new state via resolveBridge; C++ DEFERS
/// the two handlers (like the audio handlers) so Dart's real reply is authoritative
/// instead of an immediate null.
void main() {
  String read(String p) => File(p).readAsStringSync();

  group('Dart controller: favorite bridge branch (root cause 2)', () {
    late String src;
    setUpAll(() {
      // spec 2026-07-10: 桥 handler 抽到 overlay_bridge_handlers.dart 与剪贴板
      // 面板共享（红线：两表面不复制不漂移）；守卫扫 controller+共享实现拼接。
      src = read('lib/src/lookup/global_lookup_controller.dart') +
          read('lib/src/lookup/overlay_bridge_handlers.dart');
    });

    test(
        '_onJsMessage routes favoriteEntry / favoriteCheck to a deferred handler',
        () {
      expect(
        src.contains("case 'favoriteEntry':") &&
            src.contains("case 'favoriteCheck':"),
        isTrue,
        reason: '_onJsMessage 必须有收藏分支（过去根本没有 → 按钮永挂）',
      );
      expect(src.contains('_handleFavoriteBridge('), isTrue,
          reason: '收藏走独立 deferred 处理器');
    });

    test(
        'favorite handler writes through FavoriteWords and resolves the bridge',
        () {
      // 真写穿 DB（非 UI 假动作），与 in-app DictionaryPageMixin 一致。
      expect(src.contains('isFavoriteWord('), isTrue);
      expect(src.contains('addFavoriteWord('), isTrue);
      expect(src.contains('removeFavoriteWord('), isTrue);
      // 回传新收藏态给 iframe（星标切换）。
      expect(src.contains('resolveBridge(id, reply)'), isTrue,
          reason: '收藏落库后必须 resolveBridge 回传布尔态');
      // 与 in-app 词典默认来源一致，(expression, reading, sourceType) 唯一键共享。
      expect(src.contains('kStatSourceBook'), isTrue,
          reason: '收藏归书籍来源，与在书内弹窗收藏同一行');
    });
  });

  test('C++ overlay DEFERS favoriteEntry / favoriteCheck (root cause 2)', () {
    final String cpp = read('windows/runner/global_lookup_window.cpp');
    // 否则 C++ 会即时 null-resolve，Dart 的真回复被忽略、星标不翻。
    expect(cpp.contains('body.find("\\"favoriteEntry\\"")'), isTrue,
        reason: 'favoriteEntry 必须纳入 deferred（不即时 null-resolve）');
    expect(cpp.contains('body.find("\\"favoriteCheck\\"")'), isTrue,
        reason: 'favoriteCheck 必须纳入 deferred');
  });

  test(
      'host.js routes the bridge reply back to the SOURCE iframe (root cause 1)',
      () {
    final String host = read('assets/popup/global_lookup_host.js');
    // 每条 callHandler 的帧内 id 重写为全局 id + 记录路由（防跨帧撞 id）。
    expect(host.contains('bridgeRoutes'), isTrue,
        reason: '必须维护 globalId -> {frameId, localId} 路由表');
    expect(host.contains('installBridgeRouter'), isTrue,
        reason: '必须安装顶层 __hibikiBridgeResolve 路由器');
    // 顶层收到 native 回复后转发到源 iframe 的 contentWindow.__hibikiBridgeResolve。
    expect(host.contains('window.__hibikiBridgeResolve = function'), isTrue,
        reason: '路由器必须覆写顶层 __hibikiBridgeResolve');
    expect(host.contains('win.__hibikiBridgeResolve(route.localId'), isTrue,
        reason: '必须用源帧原始 localId 转发回 iframe adapter');
  });
}
