import 'dart:io';

import 'package:test/test.dart';

/// F6 棘轮：`AppModel.dispose()` 里手写的进程级收尾清单只减不增。
///
/// 绑某一代主库连接的资源已全部改由 `DatabaseSession` 在创建处登记、逆序收尾
/// （`lib/src/startup/database_session.dart`）；dispose 里剩下的是迁移前的进程级存量。
/// 新的常驻服务在创建处用 `ownForProcess`（`ProcessLifetime`）登记，绑库的用
/// `DatabaseSession.own`，都不再往 dispose 里加手写行。从 dispose 里迁走一行时把它从
/// [_baseline] 删掉即可。
///
/// 判据：dispose 方法体里每条语句（去掉首尾空白、跳过注释与收尾括号）必须在 [_baseline]
/// 或 [_lifecycleLines] 里；[_baseline] 里已不在 dispose 的行也要删掉，让棘轮收紧。
const List<String> _baseline = <String>[
  'unawaited(_extensionImageOcr?.close());',
  '_extensionImageOcr = null;',
  '_trackingAnimeIdsOrNull?.close();',
  '_trackingAnimeIdsOrNull = null;',
  'if (_isInitialised) {',
  'unawaited(syncServerController.stop());',
  'syncServerController.dispose();',
  'unawaited(videoRemoteHost.dispose());',
  'unawaited(TexthookerWsClientManager.instance.stop());',
  'unawaited(stopFushiApiServer());',
  '_disposeOnDemandSubtitleRegistry();',
  '_audiobookshelfApis?.close();',
  '_mihonManager?.dispose();',
  '_mihonManager = null;',
  '_animeMihonManager?.dispose();',
  '_animeMihonManager = null;',
  '_lnReaderManager?.dispose();',
  '_lnReaderManager = null;',
  'unawaited(_musicPluginManager?.dispose());',
  '_musicPluginManager = null;',
  '_musicPluginRelay?.dispose();',
  '_musicPluginRelay = null;',
  '_trackingPluginManager?.changes.removeListener(_applyTrackingProviders);',
  'unawaited(_trackingPluginManager?.dispose());',
  '_trackingPluginManager = null;',
  '_trackingPluginProviders = null;',
  '_appleMusicAccount?.dispose();',
  '_appleMusicAccount = null;',
  'final ExitFlushCallback? mihonExitShutdown = _mihonRuntimeExitShutdown;',
  '_mihonRuntimeExitShutdown = null;',
  'if (mihonExitShutdown != null) {',
  'ExitFlushRegistry.instance.unregister(mihonExitShutdown);',
  'unawaited(_shutdownMihonRuntime());',
  '_mihonRuntime = null;',
  'if (_themeListenerAdded) {',
  'themeNotifier.dispose();',
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
  '_remoteDictionaryReachability.dispose();',
  '_remoteDictionaryCatalogLifecycle?.dispose();',
  '_remoteDictionaryCatalogLifecycle = null;',
  '_remoteLookupHttpClient?.close();',
  '_remoteLookupHttpClient = null;',
  '_stopTorrentNetworkMonitor();',
  '_unregisterEmbeddedTorrentExitFlush();',
  'final Set<String>? keepIds = _animeDownloadPlanIds;',
  '_embeddedTorrentHostSlot.take().then(',
  'torrentNetworkIssue.dispose();',
];

/// 生命周期统一收尾的几行（不算手写清单）。
const List<String> _lifecycleLines = <String>[
  '_disposing = true;',
  'unawaited(',
  'unawaited(_processLifetime.close());',
  '_closeDatabaseSession(closeConnection: false).catchError((',
  'Object e,',
  'StackTrace stack,',
  "ErrorLogService.instance.log('AppModel.dispose.session', e, stack);",
  'super.dispose();',
];

List<String> _disposeStatements(String source) {
  const String marker = '  @override\n  void dispose() {';
  final int start = source.indexOf(marker);
  expect(
    start,
    greaterThanOrEqualTo(0),
    reason: 'AppModel.dispose() not found',
  );
  final int end = source.indexOf('\n  }\n', start);
  final List<String> out = <String>[];
  for (final String raw in source.substring(start, end).split('\n').skip(2)) {
    final String line = raw.trim();
    if (line.isEmpty || line.startsWith('//')) continue;
    if (RegExp(r'^[})\]]').hasMatch(line)) continue;
    if (!RegExp(r'[;{(]$').hasMatch(line)) continue;
    out.add(line);
  }
  return out;
}

void main() {
  test('AppModel.dispose 的手写收尾清单只减不增（F6 棘轮）', () {
    final String source = File(
      'lib/src/models/app_model.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final List<String> statements = _disposeStatements(source);
    final Set<String> allowed = <String>{..._baseline, ..._lifecycleLines};
    final List<String> added = <String>[
      for (final String s in statements)
        if (!allowed.contains(s)) s,
    ];
    expect(
      added,
      isEmpty,
      reason:
          'dispose 里新增了手写收尾：绑库资源改在创建处 DatabaseSession.own，'
          '进程级常驻服务改在创建处 ownForProcess（ProcessLifetime）',
    );
    final Set<String> present = statements.toSet();
    final List<String> stale = <String>[
      for (final String s in _baseline)
        if (!present.contains(s)) s,
    ];
    expect(stale, isEmpty, reason: '这些行已从 dispose 迁走：把它们从 _baseline 删掉，让棘轮收紧');
  });
}
