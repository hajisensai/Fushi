import 'dart:io';

import 'package:test/test.dart';

/// F6 棘轮：`AppModel` 里还没迁到 `DatabaseSession` / `ProcessLifetime` 的手写生命周期代码
/// 只减不增（`lib/src/startup/database_session.dart`）。三道：
///
/// 1. `dispose()` 方法体与 [_disposeBaseline] 逐行相同（按出现次数比，重复行也计数；注释与
///    空行除外，括号收尾行照样算）。里面剩下的是迁移前的进程级存量；新的常驻服务在创建处
///    用 `OwnedSlot.obtain(_processLifetime, …)` 登记，绑库的登记在当前这一代上，都不再往
///    dispose 里加行。迁走一行就把它从基线删掉。
/// 2. 每条关库路径（[_closePaths]）的方法体里不出现任何手写收尾，只调
///    `_closeDatabaseSession`：绑库资源的收尾全在各自的登记处。
/// 3. `app_model.dart` 里的 `??=` 懒建缓存与 [_lazyCacheBaseline] 相同：新的懒建缓存一律用
///    `OwnedSlot`（写槽位与登记是同一步），不再新写 `_x ??= X(database: database)` 这种
///    「建了却没人收、换库后还握着旧连接」的裸字段。
const List<String> _disposeBaseline = <String>[
  'unawaited(_session?.detach());',
  'unawaited(_processLifetime.close());',
  'if (_isInitialised) {',
  'unawaited(syncServerController.stop());',
  'syncServerController.dispose();',
  'unawaited(videoRemoteHost.dispose());',
  '}',
  'unawaited(TexthookerWsClientManager.instance.stop());',
  'unawaited(stopFushiApiServer());',
  '_disposeOnDemandSubtitleRegistry();',
  'unawaited(_musicPluginManager?.dispose());',
  '_musicPluginManager = null;',
  '_musicPluginRelay?.dispose();',
  '_musicPluginRelay = null;',
  '_trackingPluginManager?.changes.removeListener(_applyTrackingProviders);',
  'unawaited(_trackingPluginManager?.dispose());',
  '_trackingPluginManager = null;',
  '_trackingPluginProviders = null;',
  'final ExitFlushCallback? mihonExitShutdown = _mihonRuntimeExitShutdown;',
  '_mihonRuntimeExitShutdown = null;',
  'if (mihonExitShutdown != null) {',
  'ExitFlushRegistry.instance.unregister(mihonExitShutdown);',
  '}',
  'unawaited(_shutdownMihonRuntime());',
  '_mihonRuntime = null;',
  'if (_themeListenerAdded) {',
  'themeNotifier.dispose();',
  '}',
  'dictionaryDownloadController.dispose();',
  'recommendedPackDownloadController.dispose();',
  'dictionaryEntriesNotifier.dispose();',
  'dictionarySearchAgainNotifier.dispose();',
  'dictionaryMenuNotifier.dispose();',
  'incognitoNotifier.dispose();',
  'databaseCloseNotifier.dispose();',
  'homeDictionaryTabRequest.dispose();',
  'mediaOpenNotifier.dispose();',
  'audiobookSession.dispose();',
  'audioCtrl.dispose();',
  'gamepadService.dispose();',
  '_prefsRepo?.dispose();',
  'if (_isInitialised) {',
  'mediaHistoryRepo.dispose();',
  '}',
  '_remoteDictionaryReachability.dispose();',
  '_remoteDictionaryCatalogLifecycle?.dispose();',
  '_remoteDictionaryCatalogLifecycle = null;',
  '_remoteLookupHttpClient?.close();',
  '_remoteLookupHttpClient = null;',
  '_stopTorrentNetworkMonitor();',
  '_unregisterEmbeddedTorrentExitFlush();',
  'final Set<String>? keepIds = _animeDownloadPlanIds;',
  'unawaited(',
  '_embeddedTorrentHostSlot.take().then(',
  '(EmbeddedTorrentHostClient? host) => host?.dispose(keepIds: keepIds),',
  '),',
  ');',
  'torrentNetworkIssue.dispose();',
  'super.dispose();',
];

/// 关库路径 → 方法体里允许出现的「看起来像收尾」的语句（逐字）。
const Map<String, List<String>> _closePaths = <String, List<String>>{
  'Future<void> _closeDatabaseSession(': <String>[
    'await _session?.close(drainTimeout: drainTimeout);',
  ],
  'Future<void> closeDatabase(': <String>[],
  'Future<void> closeForSrsWriteHost(': <String>[],
  // 词典引擎实例是进程级的（不绑这一代连接）：弹窗进程随后结束，在这里一并释放。
  'Future<void> closeForPopup(': <String>['FushiDicts.disposeInstance();'],
  'Future<void> retryInitialise(': <String>[],
};

/// 手写收尾的形状：对某个对象调 dispose / close / stop / cancel / detach / 撤订阅 / quiesce，
/// 调模块级的 uninstall，或把排空上界写死。
final RegExp _handWrittenTeardown = RegExp(
  r'\.(dispose|disposeInstance|close|stop|stopAll|cancel|detach|removeListener'
  r'|quiesce\w*)\('
  r'|\buninstall\w*\('
  r'|stopDrainTimeout',
);

/// `app_model.dart` 里现存的 `??=`（赋值目标 → 出现次数）。都不握某一代连接：要么与库无关，
/// 要么经闭包现取（`() => database`）。
const Map<String, int> _lazyCacheBaseline = <String, int>{
  '_relaySrsNoteWriter': 1,
  '_systemNotifier': 1,
  'musicRemoteMediaResolver': 1,
  'musicServerBindingLoader': 1,
  'InterconnectMusicHosts.instance': 1,
  'musicFushiHostTrackOpener': 1,
  'musicServerLoudnessResolver': 1,
  '_appleMusicRatingsClient': 1,
  'musicServerDownloadLyricsSaver': 1,
  'musicServerDownloadHostLyricsSaver': 1,
  '_musicPluginManager': 1,
  '_cacheManager': 1,
  '_emojiRegexInstance': 1,
  '_mihonRuntimeShutdown': 1,
  '_trackerSubscriptionService': 1,
  '_embeddedTorrentExitFlush': 1,
  '_audiobookMaterialService': 1,
  '_remoteDictionaryCatalogLifecycle': 1,
  'segmentedText': 1,
  'all[noteTypeId]': 1,
  '_remoteLookupHttpClient': 1,
  '_extensionApiCore': 1,
};

String _appModelSource() => File(
  'lib/src/models/app_model.dart',
).readAsStringSync().replaceAll('\r\n', '\n');

/// 去掉行注释（含行尾注释；字符串里没有 `//` 的方法才用得上，这几个方法都满足）。
String _stripLineComment(String line) {
  final int at = line.indexOf('//');
  return (at < 0 ? line : line.substring(0, at)).trim();
}

/// 方法体的语句行：去首尾空白、去注释、去空行；其余（含括号收尾行）一行不漏。
List<String> _bodyLines(String body) => <String>[
  for (final String raw in body.split('\n'))
    if (_stripLineComment(raw).isNotEmpty) _stripLineComment(raw),
];

/// [signature]（到参数表的左括号为止）对应方法的方法体：块体取花括号内，箭头体取到分号。
String _methodBody(String source, String signature) {
  final int start = source.indexOf('  $signature');
  expect(start, greaterThanOrEqualTo(0), reason: '$signature not found');
  expect(
    source.indexOf('  $signature', start + 1),
    -1,
    reason: '$signature is ambiguous',
  );
  int i = source.indexOf('(', start);
  int depth = 0;
  // 跳过参数表。
  for (; i < source.length; i++) {
    final String c = source[i];
    if (c == '(' || c == '{' || c == '[') depth++;
    if (c == ')' || c == '}' || c == ']') depth--;
    if (depth == 0) break;
  }
  final int brace = source.indexOf('{', i);
  final int arrow = source.indexOf('=>', i);
  if (arrow >= 0 && (brace < 0 || arrow < brace)) {
    return source.substring(arrow + 2, source.indexOf(';', arrow) + 1);
  }
  depth = 0;
  for (int j = brace; j < source.length; j++) {
    final String c = source[j];
    if (c == '{') depth++;
    if (c == '}') depth--;
    if (depth == 0) return source.substring(brace + 1, j);
  }
  fail('unterminated body: $signature');
}

Map<String, int> _counts(Iterable<String> items) {
  final Map<String, int> out = <String, int>{};
  for (final String item in items) {
    out[item] = (out[item] ?? 0) + 1;
  }
  return out;
}

/// [actual] 比 [baseline] 多出来的（带多出的次数）。
List<String> _surplus(Map<String, int> actual, Map<String, int> baseline) =>
    <String>[
      for (final MapEntry<String, int> e in actual.entries)
        if (e.value > (baseline[e.key] ?? 0))
          '${e.key}  ×${e.value - (baseline[e.key] ?? 0)}',
    ];

void main() {
  final String source = _appModelSource();

  test('AppModel.dispose 的手写收尾清单只减不增（按行、按次数）', () {
    final Map<String, int> actual = _counts(
      _bodyLines(_methodBody(source, 'void dispose(')),
    );
    final Map<String, int> baseline = _counts(_disposeBaseline);
    expect(
      _surplus(actual, baseline),
      isEmpty,
      reason:
          'dispose 里新增了手写收尾：绑库资源登记在当前这一代 DatabaseSession 上，'
          '进程级常驻服务用 OwnedSlot.obtain(_processLifetime, …)',
    );
    expect(
      _surplus(baseline, actual),
      isEmpty,
      reason: '这些行已从 dispose 迁走：把它们从 _disposeBaseline 删掉，让棘轮收紧',
    );
  });

  test('每条关库路径里没有手写收尾，只调 _closeDatabaseSession', () {
    for (final MapEntry<String, List<String>> path in _closePaths.entries) {
      final String body = _methodBody(source, path.key);
      final List<String> offending = <String>[
        for (final String line in _bodyLines(body))
          if (_handWrittenTeardown.hasMatch(line) && !path.value.contains(line))
            line,
      ];
      expect(
        offending,
        isEmpty,
        reason:
            '${path.key}…) 里出现了手写收尾：绑库资源的收尾写在它的登记处'
            '（DatabaseSession.own / OwnedSlot），关库路径只有一个动作',
      );
      if (!path.key.contains('_closeDatabaseSession')) {
        expect(
          body,
          contains('_closeDatabaseSession('),
          reason: '${path.key}…) 必须经 _closeDatabaseSession 关掉这一代',
        );
      }
    }
  });

  test('棘轮自检：它认得出折行的 unawaited、重复的块、关库路径里的手写清理', () {
    const String body = '''
    unawaited(_session?.detach());
    unawaited(
      _newService.close(),
    );
    if (_isInitialised) {
      _another.dispose();
    }
''';
    final Map<String, int> baseline = _counts(<String>[
      'unawaited(_session?.detach());',
      'unawaited(',
      ');',
      'if (_isInitialised) {',
      '}',
    ]);
    expect(_surplus(_counts(_bodyLines(body)), baseline), <String>[
      '_newService.close(),  ×1',
      '_another.dispose();  ×1',
    ]);
    expect(
      _surplus(
        _counts(_bodyLines('if (_isInitialised) {\n}\nif (_isInitialised) {')),
        _counts(<String>['if (_isInitialised) {', '}']),
      ),
      <String>['if (_isInitialised) {  ×1'],
    );
    for (final String line in <String>[
      '_prefsRepo?.removeListener(notifyListeners);',
      'uninstallCollectionsSyncWatcher();',
      'await _database.close();',
      '_animeDownloadService?.stop();',
      'await _browserVideoStudyBridge?.stopAll();',
      'await database.quiesceBackgroundWork();',
      'drainTimeout: VideoDownloadPipelineService.stopDrainTimeout,',
    ]) {
      expect(_handWrittenTeardown.hasMatch(line), isTrue, reason: line);
    }
  });

  test('AppModel 的 ??= 懒建缓存只减不增：新的缓存字段用 OwnedSlot', () {
    final Map<String, int> actual = _counts(<String>[
      for (final String raw in source.split('\n'))
        for (final RegExpMatch m in RegExp(
          r'([\w.\[\]]+)\s*\?\?=',
        ).allMatches(_stripLineComment(raw)))
          m.group(1)!,
    ]);
    expect(
      _surplus(actual, _lazyCacheBaseline),
      isEmpty,
      reason:
          '新的懒建缓存：握着某一代连接（或它的仓库）就用 '
          'OwnedSlot.obtain(_requireSession(), …)，进程级的用 '
          'OwnedSlot.obtain(_processLifetime, …)——写槽位与登记是同一步',
    );
    expect(
      _surplus(_lazyCacheBaseline, actual),
      isEmpty,
      reason: '这些 ??= 已经迁走：把它们从 _lazyCacheBaseline 删掉，让棘轮收紧',
    );
  });
}
