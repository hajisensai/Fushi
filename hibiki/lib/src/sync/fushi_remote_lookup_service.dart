import 'dart:typed_data';

import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/src/sync/forwarded_mine_payload.dart';
import 'package:fushi/src/sync/immersion_mine_payload.dart';

abstract class FushiRemoteLookupService {
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  });

  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  });
}

/// 浏览器扩展挖词的窄接口（与查词分离，避免 server 直接依赖 AnkiRepository）。
abstract class FushiRemoteMiningService {
  /// 返回 [RemoteMineResult]（结果名 + 失败/部分成功诊断）。
  Future<RemoteMineResult> mineEntry({
    required Map<String, String> fields,
    required String sentence,
  });

  /// TODO-1000：沉浸制卡（截图/GIF/音频 + 不回放）。实现方持 AnkiRepository，可调后台软解
  /// 实例（2B）；server 只解析 body 成 [ImmersionMinePayload] 后转发，不 new 引擎、不碰 repo。
  /// TODO-1303：返回 [RemoteMineResult]——除结果名外还带 [RemoteMineResult.message]/
  /// [RemoteMineResult.detail]（失败原因 / 音频落空警告），实现方须同时把失败写进错误日志，
  /// 终结「制卡失败报成功 + 诊断黑洞」。
  Future<RemoteMineResult> mineImmersion(ImmersionMinePayload payload);

  /// 互联「制卡到服务端」：客户端把**未渲染**的制卡请求（rawPayloadJson + context 文本 +
  /// 全部本地媒体字节）转发过来，本机用**自己的** Anki 后端 + 字段映射/牌组渲染并落卡
  /// （服务端拥有制卡配置）。实现方须把 [ForwardedMinePayload] 的媒体字节落成本机临时文件/
  /// 词典缓存、重建 `AnkiMiningContext` 后调 `repo.mineEntry`，与 app 内本地制卡同一渲染链路。
  /// 与 [mineEntry]（浏览器扩展纯文本，已渲染 fields）是独立路径，互不影响契约。
  Future<RemoteMineResult> mineForwarded(ForwardedMinePayload payload);

  /// TODO-1176：浏览器扩展查词弹窗制卡按钮真查重（`+`→`✓`，与 app 内一致）。经 Anki 后端
  /// （AnkiConnect `findNotes` / AnkiDroid `findDuplicateNotes`）判断 [expression]/[reading]
  /// 是否已在当前牌组+笔记类型存在。与 app 内 `dictionary_page_mixin.checkDuplicate` 同一
  /// `repo.isDuplicate` 路径，fail-soft（后端不可用/未配置 → false，绝不让查重探测阻断查词）。
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  });
}

/// 把一次查词结果写入 Hibiki 查词历史（无 UI 副作用）。浏览器扩展 record 用。
abstract class FushiRemoteHistoryService {
  void recordHistory(DictionarySearchResult result);
}

/// 对端 host 返回的单词音频查询结果（原始字节 + Content-Type，wire DTO）。
class RemoteAudioLookup {
  const RemoteAudioLookup({
    required this.bytes,
    required this.contentType,
  });

  final Uint8List bytes;
  final String contentType;
}

/// TODO-1303：远端制卡结果 + 诊断。此前挖词接口只回 `MineResult.name`，把
/// [MineOutcome.errorDetail]/[MineOutcome.audioWarning] 和引擎中止原因全丢了 → 扩展
/// 只能盲判「非 success 就重试」，用户看到「制卡失败报成功」而无从排查。
///
/// * [result]：`MineResult.name`（`'success'|'duplicate'|'notConfigured'|'error'`）。
/// * [message]：人类可读的简短原因。`error` 时是失败文案；`success` 且单词音频落空
///   （部分成功）时是音频警告——让扩展区分「真成功」与「卡建了但没音频」。
/// * [detail]：更长的技术细节（如引擎中止原因 / errorDetail 原文），可空。
///
/// 由 [buildRemoteMineResponse] 摊进 `/api/mine` 响应体（`{result, message?, detail?}`），
/// 浏览器扩展 content.js 读 `resp.data.message` 弹 toast 显因。
class RemoteMineResult {
  const RemoteMineResult({
    required this.result,
    this.message,
    this.detail,
  });

  final String result;
  final String? message;
  final String? detail;
}
