import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// TODO-766 / BUG: 查词能播放出声但制卡卡片无音频。
//
// 根因：远端 host 给词音频文件 URL 签一个 5 分钟过期的 token
// (hibiki_sync_server.dart `_pruneAudioTokens`)。查词点 ♪ 播放走
// resolveCachedAudioUrl → 立即播，token 新鲜成功；但制卡 buildMinePayload 原本
// 也走 resolveCachedAudioUrl，命中播放缓存后直接返回那个旧 URL，制卡可能发生在
// 播放很久之后 → token 已被 prune → repo 裸 HttpClient GET 拿到 404 → 静默返
// null → 卡片落空 `[sound:]`。
//
// 修复：buildMinePayload 的制卡取音频路径 **绕过播放缓存**，直接走 fetchAudioUrl
// (重新经 resolveWordAudio handler 让 host 重签一个新鲜 token 的 URL)，把新 URL
// 写进 payload.audio；播放路径 (createAudioButton / resolveCachedAudioUrl) 不动。
//
// 两层守护：
// ① 行为级——hibiki/test/utils/misc/popup_asset_behavior_test.js 的
//    testMiningResolvesFreshAudioEvenWhenCacheHoldsSameWord 用 Node 真执行
//    buildMinePayload，断言播放缓存同词后制卡仍发第二次 resolveWordAudio（撤修复
//    复用缓存则只 1 次 → 转红）。本文件用 Node 跑该 harness。
// ② 源码级——静态扫描 popup.js，锁定制卡分支调 fetchAudioUrl 做 fresh resolve，
//    且 NOT 在该分支复用 resolveCachedAudioUrl（即便无 node 也能在 CI 守住回归）。
void main() {
  late String source;
  late String mineBlock;

  setUpAll(() {
    source = File('assets/popup/popup.js').readAsStringSync();
    // Bound the buildMinePayload audio-resolution block: from the audio var
    // declaration to the payload return.
    final int start =
        source.indexOf('const audioReading = reading || expression;');
    expect(start, greaterThanOrEqualTo(0),
        reason: 'buildMinePayload audio block not found');
    final int end = source.indexOf('return {', start);
    expect(end, greaterThan(start),
        reason: 'buildMinePayload return not found after audio block');
    mineBlock = source.substring(start, end);
  });

  test('mining resolves fresh audio (bypasses the playback cache)', () {
    // The mining audio path must call fetchAudioUrl directly (re-sign a token).
    expect(
      mineBlock.contains('await fetchAudioUrl(expression, audioReading)'),
      isTrue,
      reason:
          'buildMinePayload must do a fresh fetchAudioUrl so the host re-signs a '
          'non-expired token URL for the card (TODO-766)',
    );
    // And it must NOT reuse the playback cache via resolveCachedAudioUrl in the
    // mining branch — that is exactly the stale-token bug.
    expect(
      mineBlock.contains('resolveCachedAudioUrl'),
      isFalse,
      reason: 'buildMinePayload must NOT reuse the playback cache '
          '(resolveCachedAudioUrl) for mining audio — it returns an expired '
          'token URL that 404s into an empty [sound:]',
    );
  });

  test('playback path still uses the cached resolver (unchanged)', () {
    // The play button must keep using resolveCachedAudioUrl: playback resolves
    // and plays immediately while the token is fresh, so caching is correct
    // there. Only mining was decoupled.
    expect(
      source.contains(
          'const audioUrl = await resolveCachedAudioUrl(expression, reading || expression, entryIndex);'),
      isTrue,
      reason:
          'createAudioButton (playback) must keep resolveCachedAudioUrl; only '
          'the mining path was changed to a fresh resolve',
    );
  });

  test('mining JS behavior executes via node (fresh resolve on cache hit)',
      () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    final File jsTest = File('test/utils/misc/popup_asset_behavior_test.js');
    expect(jsTest.existsSync(), isTrue,
        reason: 'behavior harness ${jsTest.path} must exist');
    final ProcessResult result = await Process.run(
      nodeExe,
      <String>[jsTest.path],
      workingDirectory: Directory.current.path,
    );
    expect(
      result.exitCode,
      0,
      reason: 'popup audio-fresh-resolve JS behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) {
        return name;
      }
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}
