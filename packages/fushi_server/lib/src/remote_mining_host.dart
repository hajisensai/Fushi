/// 互联「制卡到服务端」：对端（手机 / 浏览器扩展）把制卡请求发到 `/api/mine`、
/// `/api/mine/forward`，服务端用**自己的** Anki 设置渲染并写进本机的 Anki 同步客户端
/// 库（[ServerAnkiLanding] 那一份 `fushi-anki-sync` 会话），再随常规同步上到 AnkiWeb /
/// 自建同步服务器。
///
/// 与 app 的 `_AppModelRemoteLookupService` 的挖词部分一一对应；差别都是服务端的
/// 真实能力边界：
/// * 沉浸制卡（截图 / 动图 / 句子音频要从视频流现裁）依赖 app 里的
///   `ImmersionMiningEngine`，服务端不做 —— 回明确的失败原因；
/// * 没有 Anki 桌面程序：「在 Anki 中打开这个词」恒 failed，笔记类型模板读写与
///   collection.media 去重同 app 的同步客户端后端一样不支持（null / false）。
library;

import 'dart:convert';

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/anki_sync/anki_sync_miner.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/forwarded_mine_materialize.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/immersion_mine_payload.dart';
import 'package:fushi_server/src/anki_landing.dart';
import 'package:fushi_server/src/dictionary_host.dart';

/// 落一张卡：未渲染的载荷 JSON + 制卡上下文 → 结果。
typedef ServerMineCard = Future<MineOutcome> Function(String rawPayloadJson, AnkiMiningContext context);

/// 沉浸制卡在服务端不可用时回给对端的原因。
const String kServerImmersionMiningUnsupported = '服务端不支持沉浸制卡（截图 / 动图 / 句子音频需在客户端裁好后用「制卡到服务端」转发）';

/// 把一次 [MineOutcome] 映射成 wire 结果，失败写进服务端日志（与 app 的
/// `remoteMineResultFromOutcome` 同一语义：error 带原因、success 带部分成功的音频警告与
/// 实际落卡牌组）。
RemoteMineResult serverRemoteMineResult(MineOutcome outcome, {String source = 'ServerMining'}) {
  switch (outcome.result) {
    case MineResult.error:
      final String reason = outcome.errorDetail ?? 'Mining failed';
      engineLog.log(source, outcome.error ?? reason, outcome.stackTrace);
      return RemoteMineResult(result: outcome.result.name, message: reason, detail: outcome.errorDetail);
    case MineResult.success:
      final String? warn = outcome.audioWarning;
      return RemoteMineResult(
        result: outcome.result.name,
        message: warn != null && warn.isNotEmpty ? warn : null,
        deckName: outcome.deckName,
      );
    case MineResult.duplicate:
    case MineResult.notConfigured:
    case MineResult.queued:
      return RemoteMineResult(result: outcome.result.name);
  }
}

class ServerRemoteMiningService implements FushiRemoteMiningService {
  ServerRemoteMiningService({
    required ServerMineCard mineCard,
    required Future<bool> Function(String expression) isDuplicateExpression,
    Future<void> Function(String dictionaryMediaJson)? writeDictionaryMedia,
  }) : _mineCard = mineCard,
       _isDuplicateExpression = isDuplicateExpression,
       _writeDictionaryMedia = writeDictionaryMedia;

  /// 生产装配：落卡走 [landing] 的同步客户端会话；词典外字从 [dictionaries]
  /// （服务端装了词典引擎时）落进 Anki 媒体缓存。
  factory ServerRemoteMiningService.forLanding(ServerAnkiLanding landing, {ServerDictionaryHost? dictionaries}) =>
      ServerRemoteMiningService(
        mineCard: landing.mineCard,
        isDuplicateExpression: (String expression) => landingIsDuplicate(landing, expression),
        writeDictionaryMedia: dictionaries != null && dictionaries.available
            ? dictionaries.writeDictionaryMediaCache
            : null,
      );

  final ServerMineCard _mineCard;
  final Future<bool> Function(String expression) _isDuplicateExpression;
  final Future<void> Function(String dictionaryMediaJson)? _writeDictionaryMedia;

  @override
  Future<RemoteMineResult> mineEntry({required Map<String, String> fields, required String sentence}) async {
    // 弹窗把外字登记进 fields.dictionaryMedia 并渲染成占位 <img>；先把字节落缓存，
    // 渲染时才替换得上（与 app 的 BUG-2190 同一步骤）。
    await _writeDictionaryMedia?.call(fields['dictionaryMedia'] ?? '');
    return serverRemoteMineResult(
      await _mineCard(jsonEncode(fields), AnkiMiningContext(sentence: sentence)),
      source: 'ServerMining.mineEntry',
    );
  }

  @override
  Future<RemoteMineResult> mineForwarded(ForwardedMinePayload payload) async {
    try {
      return await withMaterializedMiningContext<RemoteMineResult>(
        payload,
        (String raw, AnkiMiningContext context) async =>
            serverRemoteMineResult(await _mineCard(raw, context), source: 'ServerMining.mineForwarded'),
      );
    } catch (e, st) {
      engineLog.log('ServerMining.mineForwarded', e, st);
      return RemoteMineResult(result: MineResult.error.name, message: '服务端制卡失败', detail: '$e');
    }
  }

  @override
  Future<RemoteMineResult> mineImmersion(ImmersionMinePayload payload) async {
    engineLog.logDiagnostic('ServerMining.mineImmersion', kServerImmersionMiningUnsupported);
    return RemoteMineResult(
      result: MineResult.error.name,
      message: kServerImmersionMiningUnsupported,
      detail: 'immersion mining needs the app-side media pipeline',
    );
  }

  @override
  Future<bool> isDuplicate({required String expression, required String reading}) async {
    if (expression.isEmpty) return false;
    try {
      return await _isDuplicateExpression(expression);
    } catch (e, st) {
      // 查重是每次查词都跑的高频探测：后端没登录 / helper 起不来回「不重复」，真正制卡时
      // mineEntry 会把原因报给用户（与 app 的同步客户端后端同口径）。
      engineLog.log('ServerMining.isDuplicate', e, st);
      return false;
    }
  }

  @override
  Future<AnkiOpenWordOutcome> openWordInAnki({required String expression, required String reading}) async =>
      AnkiOpenWordOutcome.failed;

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(String modelName) async => null;

  @override
  Future<bool> updateNoteTypeStyling(String modelName, String css) async => false;

  @override
  Future<bool> updateNoteTypeTemplates(String modelName, List<AnkiCardTemplate> templates) async => false;

  @override
  Future<bool> probeMediaMaintenance() async => false;

  @override
  Future<AnkiMediaDedupReport?> runMediaDedup({bool dryRun = true}) async => null;
}

/// 用落地会话查重：按服务端设置选中的笔记类型、以表记为首字段（与 app 的
/// `AnkiSyncClientRepository.isDuplicate` 同口径）。没有 helper / 没选笔记类型 → false。
Future<bool> landingIsDuplicate(ServerAnkiLanding landing, String expression) async {
  final AnkiSyncMiner? miner = landing.miner;
  if (miner == null || expression.isEmpty) return false;
  final AnkiNoteType? noteType = miner.selectedNoteType(landing.settings);
  if (noteType == null) return false;
  return miner.session.isDuplicate(notetype: noteType.name, firstField: expression);
}
